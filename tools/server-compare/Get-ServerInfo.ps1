#Requires -Version 5.1
<#
.SYNOPSIS
    Collect Windows server configuration and output as JSON.

.PARAMETER Category
    Categories to collect. Default: all
    Valid: all, os, network, services, packages, users, filesystem, environment, security

.PARAMETER OutputPath
    Output JSON file path.
    Default: <hostname>_<yyyyMMdd-HHmmss>.json in the current directory.

.EXAMPLE
    .\Get-ServerInfo.ps1
    .\Get-ServerInfo.ps1 -Category os,network,services
    .\Get-ServerInfo.ps1 -OutputPath C:\temp\server-before.json
#>
[CmdletBinding()]
param(
    [ValidateSet('all','os','network','services','packages','users','filesystem','environment','security')]
    [string[]]$Category = @('all'),
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$allCategories     = @('os','network','services','packages','users','filesystem','environment','security')
$resolvedCategories = if ($Category -contains 'all') { $allCategories } else {
    $Category | Where-Object { $allCategories -contains $_ }
}

if (-not $OutputPath) {
    $ts         = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputPath = Join-Path (Get-Location) "$($env:COMPUTERNAME)_$ts.json"
}

# ============================================================
# Helpers
# ============================================================

function Safe-Exec([scriptblock]$Block, [string]$Label) {
    try { & $Block }
    catch { Write-Warning "$Label : $($_.Exception.Message)"; $null }
}

# ============================================================
# Collection functions
# ============================================================

function Get-OsInfo {
    Write-Host "  Collecting: os ..."
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $cs = Get-CimInstance Win32_ComputerSystem  -ErrorAction SilentlyContinue
    @{
        hostname        = $env:COMPUTERNAME
        domain          = if ($cs) { $cs.Domain } else { '' }
        os_name         = if ($os) { $os.Caption } else { '' }
        os_version      = if ($os) { $os.Version } else { '' }
        os_build        = if ($os) { $os.BuildNumber } else { '' }
        architecture    = if ($os) { $os.OSArchitecture } else { $env:PROCESSOR_ARCHITECTURE }
        timezone        = (Get-TimeZone -ErrorAction SilentlyContinue).Id
        locale          = (Get-WinSystemLocale -ErrorAction SilentlyContinue).Name
        install_date    = if ($os) { $os.InstallDate.ToString('yyyy-MM-dd') } else { '' }
        last_boot       = if ($os) { $os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm:ss') } else { '' }
        total_memory_gb = if ($cs) { [math]::Round($cs.TotalPhysicalMemory / 1GB, 2) } else { 0 }
    }
}

function Get-NetworkInfo {
    Write-Host "  Collecting: network ..."
    $interfaces = @(Safe-Exec -Label 'network.interfaces' -Block {
        Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceAlias -notlike 'Loopback*' } |
            ForEach-Object { @{ name = $_.InterfaceAlias; address = $_.IPAddress; prefix = $_.PrefixLength } }
    })
    $routes = @(Safe-Exec -Label 'network.routes' -Block {
        Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.DestinationPrefix -ne '255.255.255.255/32' } |
            ForEach-Object { @{ destination = $_.DestinationPrefix; gateway = $_.NextHop; interface = $_.InterfaceAlias } }
    })
    $dns = @(Safe-Exec -Label 'network.dns' -Block {
        Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.ServerAddresses } |
            ForEach-Object { @{ interface = $_.InterfaceAlias; servers = @($_.ServerAddresses) } }
    })
    $hosts = @(Safe-Exec -Label 'network.hosts' -Block {
        $p = 'C:\Windows\System32\drivers\etc\hosts'
        if (Test-Path $p) {
            Get-Content $p -Encoding UTF8 |
                Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() } |
                ForEach-Object {
                    $parts = $_.Trim() -split '\s+'
                    if ($parts.Count -ge 2) { @{ ip = $parts[0]; hostnames = @($parts[1..($parts.Count-1)]) } }
                } | Where-Object { $_ }
        }
    })
    @{ interfaces = $interfaces; routes = $routes; dns_servers = $dns; hosts = $hosts }
}

function Get-ServicesInfo {
    Write-Host "  Collecting: services ..."
    @(Safe-Exec -Label 'services' -Block {
        Get-Service -ErrorAction SilentlyContinue |
            ForEach-Object {
                @{
                    name         = $_.Name
                    display_name = $_.DisplayName
                    status       = $_.Status.ToString().ToLower()
                    start_type   = $_.StartType.ToString().ToLower()
                }
            } | Sort-Object { $_['name'] }
    })
}

function Get-PackagesInfo {
    Write-Host "  Collecting: packages ..."
    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $seen = @{}
    $pkgs = @()
    foreach ($rp in $regPaths) {
        try {
            Get-ItemProperty -Path $rp -ErrorAction SilentlyContinue |
                ForEach-Object {
                    $nameProp = $_.PSObject.Properties['DisplayName']
                    if ($null -eq $nameProp -or -not $nameProp.Value) { return }
                    $n = $nameProp.Value.Trim()
                    if (-not $seen[$n]) {
                        $seen[$n] = $true
                        $verProp = $_.PSObject.Properties['DisplayVersion']
                        $pubProp = $_.PSObject.Properties['Publisher']
                        $pkgs += @{
                            name    = $n
                            version = if ($verProp) { "$($verProp.Value)" } else { '' }
                            vendor  = if ($pubProp)  { "$($pubProp.Value)" }  else { '' }
                        }
                    }
                }
        } catch { Write-Warning "packages.registry: $($_.Exception.Message)" }
    }
    @($pkgs | Sort-Object { $_['name'] })
}

function Get-UsersInfo {
    Write-Host "  Collecting: users ..."
    $localUsers = @(Safe-Exec -Label 'users.local' -Block {
        Get-LocalUser -ErrorAction SilentlyContinue |
            ForEach-Object {
                @{ name = $_.Name; enabled = $_.Enabled; full_name = $_.FullName; description = $_.Description }
            } | Sort-Object { $_['name'] }
    })
    $localGroups = @(Safe-Exec -Label 'users.groups' -Block {
        Get-LocalGroup -ErrorAction SilentlyContinue |
            ForEach-Object {
                $gname   = $_.Name
                $members = @()
                try { $members = @(Get-LocalGroupMember -Group $gname -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) } catch {}
                @{ name = $gname; description = $_.Description; members = $members }
            } | Sort-Object { $_['name'] }
    })
    @{ local_users = $localUsers; local_groups = $localGroups }
}

function Get-FilesystemInfo {
    Write-Host "  Collecting: filesystem ..."
    $drives = @(Safe-Exec -Label 'filesystem' -Block {
        Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
            Where-Object { $null -ne $_.Used } |
            ForEach-Object {
                $total = $_.Used + $_.Free
                @{
                    drive    = $_.Name
                    root     = $_.Root
                    used_gb  = [math]::Round($_.Used  / 1GB, 2)
                    free_gb  = [math]::Round($_.Free  / 1GB, 2)
                    total_gb = [math]::Round($total   / 1GB, 2)
                    used_pct = if ($total -gt 0) { [math]::Round($_.Used / $total * 100, 1) } else { 0 }
                }
            } | Sort-Object { $_['drive'] }
    })
    @{ drives = $drives }
}

function Get-EnvironmentInfo {
    Write-Host "  Collecting: environment ..."
    $machine = @{}
    try { [System.Environment]::GetEnvironmentVariables('Machine').GetEnumerator() | ForEach-Object { $machine[$_.Key] = $_.Value } } catch {}
    @{ machine = $machine }
}

function Get-SecurityInfo {
    Write-Host "  Collecting: security ..."
    $r = @{}
    $r['firewall_profiles'] = @(Safe-Exec -Label 'fw_profiles' -Block {
        Get-NetFirewallProfile -ErrorAction SilentlyContinue |
            ForEach-Object { @{ name = $_.Name; enabled = [bool]$_.Enabled; inbound_action = $_.DefaultInboundAction.ToString(); outbound_action = $_.DefaultOutboundAction.ToString() } }
    })
    $r['firewall_rules'] = @(Safe-Exec -Label 'fw_rules' -Block {
        Get-NetFirewallRule -Enabled True -ErrorAction SilentlyContinue |
            ForEach-Object { @{ name = $_.Name; display_name = $_.DisplayName; direction = $_.Direction.ToString(); action = $_.Action.ToString(); profile = $_.Profile.ToString() } } |
            Sort-Object { $_['direction'] + $_['name'] }
    })
    $defender = Safe-Exec -Label 'defender' -Block { Get-MpComputerStatus -ErrorAction SilentlyContinue }
    if ($defender) {
        $r['defender'] = @{
            enabled             = $defender.AntivirusEnabled
            realtime_protection = $defender.RealTimeProtectionEnabled
            signature_version   = $defender.AntivirusSignatureVersion
            signature_age_days  = $defender.AntivirusSignatureAge
        }
    }
    $r
}

# ============================================================
# Main
# ============================================================
try {
    $outputDir = Split-Path -Parent $OutputPath
    if ($outputDir -and -not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

    Write-Host "Collecting server info: $($resolvedCategories -join ', ')"

    $result = [ordered]@{
        meta = @{
            hostname     = $env:COMPUTERNAME
            os_type      = 'windows'
            collected_at = [DateTimeOffset]::Now.ToString('yyyy-MM-ddTHH:mm:sszzz')
            categories   = @($resolvedCategories)
        }
    }

    foreach ($cat in $resolvedCategories) {
        $result[$cat] = switch ($cat) {
            'os'          { Get-OsInfo }
            'network'     { Get-NetworkInfo }
            'services'    { Get-ServicesInfo }
            'packages'    { Get-PackagesInfo }
            'users'       { Get-UsersInfo }
            'filesystem'  { Get-FilesystemInfo }
            'environment' { Get-EnvironmentInfo }
            'security'    { Get-SecurityInfo }
        }
    }

    $json = $result | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($OutputPath, $json, [System.Text.Encoding]::UTF8)

    Write-Host ''
    Write-Host "Done."
    Write-Host "  Hostname : $($env:COMPUTERNAME)"
    Write-Host "  Output   : $OutputPath"
}
catch {
    Write-Error "Failed: $($_.Exception.Message)"
    exit 4
}
