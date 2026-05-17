#Requires -Version 5.1
<#
.SYNOPSIS
    Collect Windows server configuration and output as JSON.

.DESCRIPTION
    Collects server configuration across multiple categories and saves to
    a JSON file for use with Compare-ServerInfo.ps1.

    Categories:
      os          OS version, hostname, timezone, locale, memory
      network     IP addresses, routes, DNS, hosts file
      services    Windows services (name, status, start type)
      packages    Installed software (from registry)
      users       Local users and groups
      filesystem  Drive usage
      environment Machine-level environment variables
      security    Firewall profiles/rules, Windows Defender status

.PARAMETER Category
    Categories to collect. Default: all.
    Accepts multiple values: -Category os,network or -Category os -Category network

.PARAMETER OutputPath
    Path for the JSON output file.
    Default: <hostname>_<yyyyMMdd-HHmmss>.json in the current directory.

.EXAMPLE
    .\Get-ServerInfo.ps1
    .\Get-ServerInfo.ps1 -Category os,network,services
    .\Get-ServerInfo.ps1 -OutputPath C:\temp\server-before.json
    .\Get-ServerInfo.ps1 -Category all -OutputPath C:\temp\server-after.json
#>
[CmdletBinding()]
param(
    [ValidateSet('all','os','network','services','packages','users','filesystem','environment','security')]
    [string[]]$Category = @('all'),

    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- Library ---
$libPath = $null
foreach ($c in @(
    [IO.Path]::Combine($PSScriptRoot, '..', 'lib', 'Logging.psm1'),
    [IO.Path]::Combine($PSScriptRoot, '..', 'lib', 'windows', 'Logging.psm1')
)) { if (Test-Path $c) { $libPath = $c; break } }
if (-not $libPath) { throw 'Logging.psm1 not found' }
Import-Module (Resolve-Path $libPath).Path -Force

$configModulePath = $null
foreach ($c in @(
    [IO.Path]::Combine($PSScriptRoot, '..', 'lib', 'Config.psm1'),
    [IO.Path]::Combine($PSScriptRoot, '..', 'lib', 'windows', 'Config.psm1')
)) { if (Test-Path $c) { $configModulePath = $c; break } }
if (-not $configModulePath) { throw 'Config.psm1 not found' }
Import-Module (Resolve-Path $configModulePath).Path -Force

$cfg = Get-OpsConfig -Name 'get_server_info'
$cfgEnv = if ($env:OPS_ENV) { $env:OPS_ENV } else { 'default' }
$logFile  = if ($cfg.ContainsKey('LogFile'))  { [string]$cfg['LogFile'] }  else { '' }
$logLevel = if ($cfg.ContainsKey('LogLevel')) { [string]$cfg['LogLevel'] } else { 'INFO' }
Set-OpsLogConfig -LogFile $logFile -LogLevel $logLevel

# Resolve categories
$allCategories = @('os','network','services','packages','users','filesystem','environment','security')
$resolvedCategories = if ($Category -contains 'all') { $allCategories } else {
    $Category | Where-Object { $allCategories -contains $_ }
}

Write-OpsLog -Level INFO -Message "Config loaded: env=$cfgEnv keys=$($cfg.Count)"
Write-OpsLog -Level INFO -Message "Args validated: category=$($resolvedCategories -join ',') outputPath='$OutputPath'"

# Default output path
if (-not $OutputPath) {
    $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputPath = Join-Path (Get-Location) "$($env:COMPUTERNAME)_$ts.json"
}

$exitCode = 0
$status   = 'unknown'

# ============================================================
# Helpers
# ============================================================

function Safe-Exec {
    param([scriptblock]$Block, [string]$Label)
    try { & $Block }
    catch {
        Write-OpsLog -Level WARN -Message "$Label collection error: $($_.Exception.Message)"
        $null
    }
}

# ============================================================
# Collection functions
# ============================================================

function Get-OsInfo {
    Write-OpsLog -Level INFO -Message 'Collecting: os'
    $os   = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $cs   = Get-CimInstance Win32_ComputerSystem  -ErrorAction SilentlyContinue
    $cpus = @(Get-CimInstance Win32_Processor     -ErrorAction SilentlyContinue)

    $totalMemGb  = if ($cs) { [math]::Round($cs.TotalPhysicalMemory / 1GB, 2) } else { 0.0 }
    $freeMemGb   = if ($os) { [math]::Round($os.FreePhysicalMemory * 1KB / 1GB, 2) } else { 0.0 }
    $cpuModel    = if ($cpus) { $cpus[0].Name.Trim() } else { '' }
    $cpuCores    = if ($cpus) { [int]($cpus | Measure-Object NumberOfCores             -Sum).Sum } else { 0 }
    $cpuLogical  = if ($cpus) { [int]($cpus | Measure-Object NumberOfLogicalProcessors -Sum).Sum } else { 0 }
    $cpuSpeedMhz = if ($cpus) { [int]$cpus[0].MaxClockSpeed } else { 0 }

    @{
        hostname          = $env:COMPUTERNAME
        domain            = if ($cs) { $cs.Domain } else { '' }
        os_name           = if ($os) { $os.Caption } else { '' }
        os_version        = if ($os) { $os.Version } else { '' }
        os_build          = if ($os) { $os.BuildNumber } else { '' }
        architecture      = if ($os) { $os.OSArchitecture } else { $env:PROCESSOR_ARCHITECTURE }
        timezone          = (Get-TimeZone -ErrorAction SilentlyContinue).Id
        locale            = (Get-WinSystemLocale -ErrorAction SilentlyContinue).Name
        install_date      = if ($os) { $os.InstallDate.ToString('yyyy-MM-dd') } else { '' }
        last_boot         = if ($os) { $os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm:ss') } else { '' }
        cpu_model         = $cpuModel
        cpu_sockets       = $cpus.Count
        cpu_cores         = $cpuCores
        cpu_logical_procs = $cpuLogical
        cpu_speed_mhz     = $cpuSpeedMhz
        total_memory_gb   = $totalMemGb
        free_memory_gb    = $freeMemGb
        used_memory_gb    = [math]::Round($totalMemGb - $freeMemGb, 2)
    }
}

function Get-NetworkInfo {
    Write-OpsLog -Level INFO -Message 'Collecting: network'

    $interfaces = @(Safe-Exec -Label 'network.interfaces' -Block {
        Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceAlias -notlike 'Loopback*' } |
            ForEach-Object {
                @{ name = $_.InterfaceAlias; address = $_.IPAddress; prefix = $_.PrefixLength }
            }
    })

    $routes = @(Safe-Exec -Label 'network.routes' -Block {
        Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.DestinationPrefix -ne '255.255.255.255/32' } |
            ForEach-Object {
                @{ destination = $_.DestinationPrefix; gateway = $_.NextHop; interface = $_.InterfaceAlias }
            }
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
    Write-OpsLog -Level INFO -Message 'Collecting: services'
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
    Write-OpsLog -Level INFO -Message 'Collecting: packages'
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
                    # Use PSObject.Properties to avoid StrictMode errors on missing properties
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
        } catch {
            Write-OpsLog -Level WARN -Message "packages.registry error: $($_.Exception.Message)"
        }
    }
    @($pkgs | Sort-Object { $_['name'] })
}

function Get-UsersInfo {
    Write-OpsLog -Level INFO -Message 'Collecting: users'
    $localUsers = @(Safe-Exec -Label 'users.local' -Block {
        Get-LocalUser -ErrorAction SilentlyContinue |
            ForEach-Object {
                @{
                    name        = $_.Name
                    enabled     = $_.Enabled
                    full_name   = $_.FullName
                    description = $_.Description
                }
            } | Sort-Object { $_['name'] }
    })
    $localGroups = @(Safe-Exec -Label 'users.groups' -Block {
        Get-LocalGroup -ErrorAction SilentlyContinue |
            ForEach-Object {
                $gname = $_.Name
                $members = @()
                try { $members = @(Get-LocalGroupMember -Group $gname -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) } catch {}
                @{ name = $gname; description = $_.Description; members = $members }
            } | Sort-Object { $_['name'] }
    })
    @{ local_users = $localUsers; local_groups = $localGroups }
}

function Get-FilesystemInfo {
    Write-OpsLog -Level INFO -Message 'Collecting: filesystem'
    $drives = @(Safe-Exec -Label 'filesystem' -Block {
        Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
            Where-Object { $null -ne $_.Used } |
            ForEach-Object {
                $drv   = $_
                $total = $drv.Used + $drv.Free
                $vol   = Get-Volume -DriveLetter $drv.Name -ErrorAction SilentlyContinue
                @{
                    drive    = $drv.Name
                    root     = $drv.Root
                    label    = if ($vol) { "$($vol.FileSystemLabel)" } else { '' }
                    fstype   = if ($vol) { "$($vol.FileSystem)"       } else { '' }
                    used_gb  = [math]::Round($drv.Used / 1GB, 2)
                    free_gb  = [math]::Round($drv.Free / 1GB, 2)
                    total_gb = [math]::Round($total    / 1GB, 2)
                    used_pct = if ($total -gt 0) { [math]::Round($drv.Used / $total * 100, 1) } else { 0 }
                }
            } | Sort-Object { $_['drive'] }
    })
    @{ drives = $drives }
}

function Get-EnvironmentInfo {
    Write-OpsLog -Level INFO -Message 'Collecting: environment'
    $machine = @{}
    $user    = @{}
    Safe-Exec -Label 'environment.machine' -Block {
        [System.Environment]::GetEnvironmentVariables('Machine').GetEnumerator() |
            ForEach-Object { $machine[$_.Key] = $_.Value }
    } | Out-Null
    Safe-Exec -Label 'environment.user' -Block {
        [System.Environment]::GetEnvironmentVariables('User').GetEnumerator() |
            ForEach-Object { $user[$_.Key] = $_.Value }
    } | Out-Null
    @{ machine = $machine; user = $user }
}

function Get-SecurityInfo {
    Write-OpsLog -Level INFO -Message 'Collecting: security'
    $r = @{}

    $r['firewall_profiles'] = @(Safe-Exec -Label 'security.fw_profiles' -Block {
        Get-NetFirewallProfile -ErrorAction SilentlyContinue |
            ForEach-Object {
                @{
                    name            = $_.Name
                    enabled         = [bool]$_.Enabled
                    inbound_action  = $_.DefaultInboundAction.ToString()
                    outbound_action = $_.DefaultOutboundAction.ToString()
                }
            }
    })

    $r['firewall_rules'] = @(Safe-Exec -Label 'security.fw_rules' -Block {
        Get-NetFirewallRule -Enabled True -ErrorAction SilentlyContinue |
            ForEach-Object {
                @{
                    name         = $_.Name
                    display_name = $_.DisplayName
                    direction    = $_.Direction.ToString()
                    action       = $_.Action.ToString()
                    profile      = $_.Profile.ToString()
                }
            } | Sort-Object { $_['direction'] + $_['name'] }
    })

    $defender = Safe-Exec -Label 'security.defender' -Block { Get-MpComputerStatus -ErrorAction SilentlyContinue }
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
    Write-OpsLog -Level INFO -Message 'Pre-check start'

    $outputDir = Split-Path -Parent $OutputPath
    if ($outputDir -and -not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

    Write-OpsLog -Level INFO -Message "Pre-check passed: categories=$($resolvedCategories -join ',') output=$OutputPath"
    Write-OpsLog -Level INFO -Message 'Main start'

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
        Write-OpsLog -Level INFO -Message "Collected: $cat"
    }

    $json = $result | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($OutputPath, $json, [System.Text.Encoding]::UTF8)

    Write-OpsLog -Level INFO -Message 'Main complete'

    Write-Host ''
    Write-Host '=== Collection Complete ===' -ForegroundColor Cyan
    Write-Host "  Hostname   : $($env:COMPUTERNAME)"
    Write-Host "  OS Type    : windows"
    Write-Host "  Categories : $($resolvedCategories -join ', ')"
    Write-Host "  Output     : $OutputPath"
    Write-Host ''

    $status = 'success'
}
catch {
    Write-OpsLog -Level ERROR -Message "Operation failed: error=$($_.Exception.Message)"
    $exitCode = 4; $status = 'failed'
}
finally {
    Write-OpsLog -Level INFO -Message "Script end: status=$status exitCode=$exitCode"
}

exit $exitCode
