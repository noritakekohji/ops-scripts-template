#Requires -Version 5.1
<#
.SYNOPSIS
    Unified server snapshot tool: collect, compare, and detect changes.
.DESCRIPTION
    Consolidates server-compare (Get-ServerInfo + Compare-ServerInfo) and
    change-detect into a single self-contained tool.

    Subcommands:
      collect  Collect server configuration snapshot as JSON
      before   Collect labeled "before" snapshot (pre-change)
      after    Collect labeled "after" snapshot + auto-compare with latest before
      compare  Compare two existing snapshot JSON files
      list     List stored snapshots in current directory
.NOTES
    Exit codes: 0=success, 1=bad args, 2=file not found, 4=processing error, 10=prerequisite missing
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('collect','before','after','compare','list')]
    [string]$Command = 'collect',

    [string[]]$Category = @('all'),
    [string]$OutputPath = '',
    [string]$Label = '',

    [string]$BeforePath = '',
    [string]$AfterPath = '',
    [string]$HtmlReport = '',
    [switch]$DiffOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Normalize -Category: accept comma-separated values (e.g. "os,network" from the
# .bat wrapper) the same way the Bash tool does, then validate against the known set.
$validCategories = @('all','os','network','services','packages','users','filesystem','environment','security','patches','tuning','scheduled','middleware')
$Category = @($Category | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ } | Select-Object -Unique)
if (-not $Category) { $Category = @('all') }
foreach ($c in $Category) {
    if ($validCategories -notcontains $c) {
        [Console]::Error.WriteLine("[ERROR] Invalid -Category '$c'. Valid: $($validCategories -join ', ')")
        exit 1
    }
}

# ============================================================
# Section 1: Helpers
# ============================================================

function Safe-Exec([scriptblock]$Block, [string]$Label) {
    try { & $Block }
    catch { Write-Warning "$Label : $($_.Exception.Message)"; $null }
}

function Invoke-BoundedExe {
    # Run an external exe with a HARD timeout. PS5.1 has no native subprocess timeout,
    # so use Start-Process + WaitForExit and kill on overrun. Returns captured stdout as
    # a single string ('' on timeout/failure). Used by the middleware collectors (SAP
    # sapcontrol / SQL Server sqlcmd / Tomcat version.bat) so a wedged external tool can
    # never hang an unattended snapshot. Parity with the python side's subprocess timeout=.
    param([string]$FilePath, [string[]]$Arguments = @(), [int]$TimeoutMs = 15000)
    $outTmp = [IO.Path]::GetTempFileName(); $errTmp = [IO.Path]::GetTempFileName()
    try {
        $startArgs = @{ FilePath = $FilePath; NoNewWindow = $true; PassThru = $true
                        RedirectStandardOutput = $outTmp; RedirectStandardError = $errTmp }
        if ($Arguments.Count) { $startArgs['ArgumentList'] = $Arguments }
        $p = Start-Process @startArgs
        if (-not $p.WaitForExit($TimeoutMs)) { try { $p.Kill() } catch {}; return '' }
        return (Get-Content -LiteralPath $outTmp -Raw)
    } catch { return '' }
    finally { Remove-Item -LiteralPath $outTmp, $errTmp -Force -ErrorAction SilentlyContinue }
}

# ============================================================
# Section 2: Collection functions
# ============================================================

function Get-OsInfo {
    Write-Host "  Collecting: os ..."
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
        hardware          = (Safe-Exec -Label 'os.hardware' -Block {
            $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
            $model = if ($cs) { "$($cs.Model)" } else { '' }
            $manu  = if ($cs) { "$($cs.Manufacturer)" } else { '' }
            $virt = 'physical'
            if ($model -match 'Virtual|VMware|KVM|HVM' -or $manu -match 'VMware|Xen|QEMU|innotek|Microsoft Corporation') { $virt = 'virtual' }
            @{
                manufacturer   = $manu
                model          = $model
                bios_version   = if ($bios) { "$($bios.SMBIOSBIOSVersion)" } else { '' }
                serial         = if ($bios) { "$($bios.SerialNumber)" } else { '' }
                virtualization = $virt
            }
        })
        locale_detail     = (Safe-Exec -Label 'os.locale' -Block {
            $cp = (chcp) 2>$null
            @{
                system_locale = (Get-WinSystemLocale -ErrorAction SilentlyContinue).Name
                code_page     = if ($cp) { ("$cp" -replace '[^0-9]','') } else { '' }
                culture       = (Get-Culture -ErrorAction SilentlyContinue).Name
            }
        })
        reboot_pending    = (Safe-Exec -Label 'os.reboot' -Block {
            $reasons = @()
            if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $reasons += 'CBS' }
            if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reasons += 'WindowsUpdate' }
            $pfr = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
            if ($pfr) { $reasons += 'PendingFileRename' }
            @{ pending = ($reasons.Count -gt 0); reasons = $reasons }
        })
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
    $proxy = Safe-Exec -Label 'network.proxy' -Block {
        $enabled = $false; $server = ''
        $reg = Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
        if ($reg) {
            $pe = $reg.PSObject.Properties['ProxyEnable']; if ($pe) { $enabled = [bool]$pe.Value }
            $ps = $reg.PSObject.Properties['ProxyServer']; if ($ps) { $server = "$($ps.Value)" }
        }
        @{ enabled = $enabled; server = $server }
    }
    $timeSync = Safe-Exec -Label 'network.time' -Block {
        $servers = @(); $synchronized = $false
        $status = (w32tm /query /status) 2>$null
        if ($status) {
            foreach ($line in $status) {
                if ($line -match 'Source:\s*(.+)') { $servers += $Matches[1].Trim(); $synchronized = $true }
            }
        }
        @{ servers = $servers; synchronized = $synchronized; _volatile = @{ last_sync = '' } }
    }
    @{ interfaces = $interfaces; routes = $routes; dns_servers = $dns; hosts = $hosts; proxy = $proxy; time_sync = $timeSync }
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
                $drv   = $_
                $total = $drv.Used + $drv.Free
                $vol   = Get-Volume -DriveLetter $drv.Name -ErrorAction SilentlyContinue
                $mOpts = ''
                if ($vol) {
                    $dt = $vol.PSObject.Properties['DriveType']
                    if ($dt) { $mOpts = "$($dt.Value)" }
                }
                @{
                    drive         = $drv.Name
                    root          = $drv.Root
                    label         = if ($vol) { "$($vol.FileSystemLabel)" } else { '' }
                    fstype        = if ($vol) { "$($vol.FileSystem)"       } else { '' }
                    used_gb       = [math]::Round($drv.Used  / 1GB, 2)
                    free_gb       = [math]::Round($drv.Free  / 1GB, 2)
                    total_gb      = [math]::Round($total      / 1GB, 2)
                    used_pct      = if ($total -gt 0) { [math]::Round($drv.Used / $total * 100, 1) } else { 0 }
                    mount_options = $mOpts
                }
            } | Sort-Object { $_['drive'] }
    })
    @{ drives = $drives }
}

function Get-EnvironmentInfo {
    Write-Host "  Collecting: environment ..."
    $machine = @{}
    $user    = @{}
    try { [System.Environment]::GetEnvironmentVariables('Machine').GetEnumerator() | ForEach-Object { $machine[$_.Key] = $_.Value } } catch {}
    try { [System.Environment]::GetEnvironmentVariables('User').GetEnumerator()    | ForEach-Object { $user[$_.Key]    = $_.Value } } catch {}
    @{ machine = $machine; user = $user }
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
    $r['uac'] = Safe-Exec -Label 'security.uac' -Block {
        $p = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
        $item = Get-ItemProperty -Path $p -ErrorAction SilentlyContinue
        $h = @{}
        foreach ($k in 'EnableLUA','ConsentPromptBehaviorAdmin') {
            $pp = $item.PSObject.Properties[$k]; if ($pp) { $h[$k] = [int]$pp.Value }
        }
        $h
    }
    $r
}

function Get-MiddlewareInfo {
    Write-Host '  Collecting: middleware ...'
    $conf = Read-MwConf
    if ($env:_OPS_MW_PROBE) {
        return @{ _probe = (Read-MwConfigFile -Path $env:_OPS_MW_PROBE -MaskPatterns $conf['mask_patterns'] -MaxFileKb $conf['max_file_kb']) }
    }
    $r = [ordered]@{}
    $hana = @(Get-MwHana      $conf); if ($hana.Count) { $r['hana']      = $hana }
    $sap  = @(Get-MwSap       $conf); if ($sap.Count)  { $r['sap']       = $sap }
    $sql  = @(Get-MwSqlServer $conf); if ($sql.Count)  { $r['sqlserver'] = $sql }
    $tom  = @(Get-MwTomcat    $conf); if ($tom.Count)  { $r['tomcat']    = $tom }
    $r
}

# Stubs (real impl in later tasks)
function Get-MwHana($conf) {
    # SAP HANA DB is Linux-only; on Windows nothing is detected and Get-MiddlewareInfo omits the key.
    @()
}
function Get-MwSap($conf) {
    $sids = @($conf['sap_sids'])
    $profileDirs = @{}   # sid -> profile dir
    # 1) explicit absolute globs from conf (Windows paths), expand %SID%.
    #    NOTE: requires sap.sids to be set (the glob's %SID% needs the SID list to expand).
    #    An absolute glob with empty sap.sids is skipped here and falls through to auto-detect.
    foreach ($g in @($conf['sap_profile_globs'])) {
        if ($g -match '[:\\]' -and $sids.Count) {
            foreach ($sid in $sids) {
                $dir = Split-Path -Parent ($g -replace '%SID%', $sid)
                if (Test-Path -LiteralPath $dir) { $profileDirs[$sid] = $dir }
            }
        }
    }
    # 2) auto-detect: scan filesystem drive roots for \usr\sap\<SID>\SYS\profile
    if (-not $profileDirs.Count) {
        Safe-Exec -Label 'mw.sap.detect' -Block {
            Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | ForEach-Object {
                $base = Join-Path $_.Root 'usr\sap'
                if (Test-Path -LiteralPath $base) {
                    Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                        if ($_.Name -eq 'trans') { return }
                        if ($sids.Count -and ($sids -notcontains $_.Name)) { return }
                        $pdir = Join-Path $_.FullName 'SYS\profile'
                        if ((Test-Path -LiteralPath $pdir) -and -not $profileDirs.ContainsKey($_.Name)) {
                            $profileDirs[$_.Name] = $pdir
                        }
                    }
                }
            }
        } | Out-Null
    }
    $result = @()
    foreach ($sid in $profileDirs.Keys) {
        $pdir = $profileDirs[$sid]
        $inst = @{ sid = "$sid"; instance = ''; instance_no = ''; type = ''; kernel_version = ''; state = ''; ports = @(); profiles = @{} }
        $sidRoot = Split-Path -Parent (Split-Path -Parent $pdir)   # ...\usr\sap\<SID>
        Safe-Exec -Label 'mw.sap.inst' -Block {
            # First instance dir only; a multi-instance SID (ASCS+ERS+PAS) reports just the first here.
            Get-ChildItem -LiteralPath $sidRoot -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^[A-Z]+\d\d$' } | Select-Object -First 1 | ForEach-Object {
                    $inst.instance = $_.Name
                    $inst.instance_no = $_.Name.Substring($_.Name.Length - 2)
                    if ($_.Name -match '^([A-Z]+)\d\d$') { $inst.type = $Matches[1] }
                }
        } | Out-Null
        $inst.kernel_version = Safe-Exec -Label 'mw.sap.kernel' -Block {
            # disp+work -v just prints the kernel banner and exits; no block risk, so no timeout guard.
            $dw = Get-Command 'disp+work.exe' -ErrorAction SilentlyContinue
            if ($dw) {
                $o = (& $dw.Source -v) 2>$null
                $line = ($o | Where-Object { $_ -match 'kernel release\s+(\S+)' } | Select-Object -First 1)
                if ($line -and $line -match 'kernel release\s+(\S+)') { return $Matches[1] }
            }
            ''
        }
        if ($inst.instance_no) {
            $inst.state = Safe-Exec -Label 'mw.sap.state' -Block {
                # sapcontrol connects to the local sapstartsrv and can block if the instance is hung;
                # Invoke-BoundedExe caps the runtime (parity with the python side's timeout=15).
                $sc = Get-Command 'sapcontrol.exe' -ErrorAction SilentlyContinue
                if (-not $sc) { return '' }
                $txt = Invoke-BoundedExe -FilePath $sc.Source -Arguments @('-nr', $inst.instance_no, '-function', 'GetProcessList') -TimeoutMs 15000
                if ($txt -match 'GREEN') { return 'GREEN' } elseif ($txt -match 'YELLOW') { return 'YELLOW' } elseif ($txt -match 'GRAY') { return 'GRAY' }
                ''
            }
        }
        Safe-Exec -Label 'mw.sap.profiles' -Block {
            Get-ChildItem -LiteralPath $pdir -File -ErrorAction SilentlyContinue | ForEach-Object {
                $inst.profiles["$($_.FullName)"] = Read-MwConfigFile -Path $_.FullName -MaskPatterns $conf['mask_patterns'] -MaxFileKb $conf['max_file_kb']
            }
        } | Out-Null
        $result += $inst
    }
    return $result
}
function Get-MwSqlServer($conf) {
    $result = @()
    $instances = @($conf['sqlserver_instances'])
    if (-not $instances.Count) {
        Safe-Exec -Label 'mw.sql.instances' -Block {
            $p = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
            $item = Get-ItemProperty -Path $p -ErrorAction SilentlyContinue
            if ($item) {
                $item.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object { $instances += $_.Name }
            }
        } | Out-Null
    }
    foreach ($name in $instances) {
        if (-not $name) { continue }
        $inst = @{
            instance_name = "$name"; version = ''; edition = ''; state = ''; port = 0
            config_files = @{}; sp_configure = $null; sp_configure_available = $false
        }
        $svcName = if ($name -eq 'MSSQLSERVER') { 'MSSQLSERVER' } else { "MSSQL`$$name" }
        $inst.state = Safe-Exec -Label 'mw.sql.svc' -Block {
            $s = Get-Service -Name $svcName -ErrorAction SilentlyContinue
            if ($s) { $s.Status.ToString().ToLower() } else { '' }
        }
        # connect='auto' (default) and 'on' both attempt integrated-auth; only 'off' skips.
        if ($conf['sqlserver_connect'] -ne 'off') {
            $sqlcmd = Get-Command sqlcmd -ErrorAction SilentlyContinue
            if ($sqlcmd) {
                $target = if ($name -eq 'MSSQLSERVER') { '.' } else { ".\$name" }
                # -l 15 caps login wait; Invoke-BoundedExe caps total runtime so a hung
                # instance can't stall the snapshot (integrated auth only, no stored creds).
                $cfg = Safe-Exec -Label 'mw.sql.spcfg' -Block {
                    Invoke-BoundedExe -FilePath $sqlcmd.Source -TimeoutMs 30000 -Arguments @(
                        '-S', $target, '-E', '-l', '15', '-h', '-1', '-W', '-s', '|',
                        '-Q', 'SET NOCOUNT ON; EXEC sp_configure;')
                }
                if ($cfg) {
                    $h = @{}
                    foreach ($row in ($cfg -split "`r?`n")) {
                        # sp_configure columns: name|minimum|maximum|config_value|run_value
                        $cols = "$row" -split '\|'
                        if ($cols.Count -ge 5) {
                            $cn = $cols[0].Trim()
                            if ($cn -and $cn -ne 'name' -and $cn -notmatch '^-+$') { $h[$cn] = $cols[4].Trim() }
                        }
                    }
                    if ($h.Count) { $inst.sp_configure = $h; $inst.sp_configure_available = $true }
                }
                $verEd = Safe-Exec -Label 'mw.sql.ver' -Block {
                    Invoke-BoundedExe -FilePath $sqlcmd.Source -TimeoutMs 20000 -Arguments @(
                        '-S', $target, '-E', '-l', '15', '-h', '-1', '-W',
                        '-Q', "SET NOCOUNT ON; SELECT CONVERT(varchar,SERVERPROPERTY('ProductVersion')) + '|' + CONVERT(varchar,SERVERPROPERTY('Edition'));")
                }
                if ($verEd) {
                    $line = ($verEd -split "`r?`n" | Where-Object { $_ -match '^\d+\.' } | Select-Object -First 1)
                    if ($line) {
                        $parts = "$line".Trim() -split '\|'
                        $inst.version = $parts[0].Trim()
                        if ($parts.Count -ge 2) { $inst.edition = $parts[1].Trim() }
                    }
                }
            }
        }
        $inst.port = Safe-Exec -Label 'mw.sql.port' -Block {
            $instId = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction SilentlyContinue).$name
            if (-not $instId) { return 0 }
            $tp = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instId\MSSQLServer\SuperSocketNetLib\Tcp\IPAll"
            $props = Get-ItemProperty -Path $tp -ErrorAction SilentlyContinue
            # TcpPort may be empty (dynamic-port instances use TcpDynamicPorts) or a comma list.
            $tpProp = if ($props) { $props.PSObject.Properties['TcpPort'] } else { $null }
            $v = if ($tpProp) { "$($tpProp.Value)" } else { '' }
            if (-not $v) {
                $dynProp = if ($props) { $props.PSObject.Properties['TcpDynamicPorts'] } else { $null }
                if ($dynProp) { $v = "$($dynProp.Value)" }
            }
            $first = ($v -split ',' | Where-Object { $_.Trim() } | Select-Object -First 1)
            $n = 0
            if ($first -and [int]::TryParse($first.Trim(), [ref]$n)) { $n } else { 0 }
        }
        $result += $inst
    }
    return $result
}
function Get-MwTomcat($conf) {
    $bases = New-Object System.Collections.Generic.List[string]
    foreach ($b in @($conf['tomcat_bases'])) { if ($b) { $bases.Add($b) } }
    foreach ($e in @($env:CATALINA_BASE, $env:CATALINA_HOME)) { if ($e) { $bases.Add($e) } }
    Safe-Exec -Label 'mw.tomcat.proc' -Block {
        Get-CimInstance Win32_Process -Filter "Name='java.exe'" -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.CommandLine -and $_.CommandLine -match '-Dcatalina\.base=([^ "]+)') { $bases.Add($Matches[1]) }
        }
    } | Out-Null
    $seen = @{}; $result = @()
    foreach ($base in $bases) {
        $norm = $base.TrimEnd('\','/')
        if (-not $norm -or $seen[$norm.ToLower()]) { continue }
        $serverXml = Join-Path $norm 'conf\server.xml'
        if (-not (Test-Path -LiteralPath $serverXml)) { continue }
        $seen[$norm.ToLower()] = $true
        $inst = @{
            name = (Split-Path $norm -Leaf); catalina_base = $norm
            # jvm_opts/state/pid are best-effort fields reserved for a later MW task; left empty here.
            version = ''; java_version = ''; jvm_opts = ''; state = ''; pid = 0; connector_ports = @()
            config_files = @{}
        }
        $inst.version = Safe-Exec -Label 'mw.tomcat.ver' -Block {
            # Prefer RELEASE-NOTES (plain text, no JVM, no hang risk); only fall back to
            # version.bat (which spawns a JVM) with a bounded wait so an unattended run can't hang.
            $rel = Join-Path $norm 'RELEASE-NOTES'
            if (Test-Path -LiteralPath $rel) {
                $line = (Get-Content -LiteralPath $rel | Where-Object { $_ -match 'Apache Tomcat Version' } | Select-Object -First 1)
                if ($line) { return $line.Trim() }
            }
            $bat = Join-Path $norm 'bin\version.bat'
            if (Test-Path -LiteralPath $bat) {
                $o = Invoke-BoundedExe -FilePath 'cmd.exe' -Arguments @('/c', $bat) -TimeoutMs 15000
                if ($o -and $o -match 'Server version:\s*(.+)') { return $Matches[1].Trim() }
            }
            ''
        }
        $inst.java_version = Safe-Exec -Label 'mw.tomcat.java' -Block {
            $java = Get-Command 'java.exe' -ErrorAction SilentlyContinue
            if (-not $java) { $java = Get-Command 'java' -ErrorAction SilentlyContinue }
            if ($java) {
                $o = (& $java.Source -version 2>&1) -join "`n"
                if ($o -match 'version "([^"]+)"') { return $Matches[1] }
            }
            ''
        }
        $inst.connector_ports = @(Safe-Exec -Label 'mw.tomcat.ports' -Block {
            $ports = @()
            [regex]::Matches((Get-Content -LiteralPath $serverXml -Raw), '<Connector[^>]*\bport="(\d+)"') | ForEach-Object { $ports += [int]$_.Groups[1].Value }
            $ports
        })
        foreach ($name in @($conf['tomcat_config_names'])) {
            $p = Join-Path (Join-Path $norm 'conf') $name
            if ($name -like 'setenv*') { $p = Join-Path (Join-Path $norm 'bin') $name }
            if (Test-Path -LiteralPath $p) {
                $inst.config_files["$p"] = Read-MwConfigFile -Path $p -MaskPatterns $conf['mask_patterns'] -MaxFileKb $conf['max_file_kb']
            }
        }
        $result += $inst
    }
    return $result
}

function Read-MwConf {
    $conf = @{
        hana_sids = @(); hana_config_globs = @('/usr/sap/%SID%/SYS/global/hdb/custom/config/*.ini')
        sap_sids = @();  sap_profile_globs = @('/usr/sap/%SID%/SYS/profile/*')
        sqlserver_instances = @(); sqlserver_connect = 'auto'
        tomcat_bases = @(); tomcat_config_names = @('server.xml','web.xml','context.xml','catalina.properties','setenv.sh','setenv.bat')
        mask_patterns = @('password','passwd','pwd','secret','key','credential','token','connectionstring')
        max_file_kb = 256
    }
    # Honor _OPS_MW_CONF override (symmetric with the sh side; enables conf-driven tests).
    $path = if ($env:_OPS_MW_CONF) { $env:_OPS_MW_CONF } else { Join-Path $PSScriptRoot 'middleware.conf' }
    if (-not (Test-Path -LiteralPath $path)) { return $conf }
    $section = ''
    foreach ($line in (Get-Content -LiteralPath $path -ErrorAction SilentlyContinue)) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        if ($t -match '^\[(.+)\]$') { $section = $Matches[1].Trim().ToLower(); continue }
        $kv = $t -split '=', 2
        if ($kv.Count -lt 2) { continue }
        $key = $kv[0].Trim().ToLower(); $val = $kv[1].Trim()
        $list = @($val -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        switch ("$section.$key") {
            'hana.sids'              { $conf.hana_sids = $list }
            'hana.config_globs'      { if ($list.Count) { $conf.hana_config_globs = $list } }
            'sap.sids'               { $conf.sap_sids = $list }
            'sap.profile_globs'      { if ($list.Count) { $conf.sap_profile_globs = $list } }
            'sqlserver.instances'    { $conf.sqlserver_instances = $list }
            'sqlserver.connect'      { if ($val) { $conf.sqlserver_connect = $val.ToLower() } }
            'tomcat.bases'           { $conf.tomcat_bases = $list }
            'tomcat.config_names'    { if ($list.Count) { $conf.tomcat_config_names = $list } }
            'masking.patterns'       { if ($list.Count) { $conf.mask_patterns = $list } }
            'limits.max_file_kb'     { $n = 0; if ([int]::TryParse($val, [ref]$n) -and $n -gt 0) { $conf.max_file_kb = $n } }
        }
    }
    return $conf
}

function Mask-MwSecrets {
    param([string]$Text, [string[]]$Patterns)
    if (-not $Text -or -not $Patterns -or $Patterns.Count -eq 0) { return @{ Text = "$Text"; Masked = $false } }
    $alt = ($Patterns | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $didMask = $false
    $lines = "$Text" -split "`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -imatch $alt) {
            # XML attribute form: key="value"
            $new = [regex]::Replace($line, '(?i)((?:' + $alt + ')[A-Za-z0-9_.-]*\s*=\s*")[^"]*(")', '${1}***${2}')
            # JSON form: "key": "value"
            $new = [regex]::Replace($new, '(?i)("[A-Za-z0-9_.\-/]*(?:' + $alt + ')[A-Za-z0-9_.\-/]*"\s*:\s*")[^"]*(")', '${1}***${2}')
            # key = value / key: value form (unquoted keys)
            $new = [regex]::Replace($new, '(?i)^(\s*[A-Za-z0-9_.\-/]*(?:' + $alt + ')[A-Za-z0-9_.\-/]*\s*[:=]\s*)\S.*$', '${1}***')
            if ($new -ne $line) { $didMask = $true; $lines[$i] = $new }
        }
    }
    return @{ Text = ($lines -join "`n"); Masked = $didMask }
}

function Read-MwConfigFile {
    param([string]$Path, [string[]]$MaskPatterns, [int]$MaxFileKb)
    if (-not $MaxFileKb) { $MaxFileKb = 256 }
    $entry = @{ content = ''; masked = $false; size_bytes = 0; sha256 = ''; readable = $true; reason = '' }
    try {
        if (-not (Test-Path -LiteralPath $Path)) { $entry.readable = $false; $entry.reason = 'not_found'; return $entry }
        $fi = Get-Item -LiteralPath $Path -ErrorAction Stop
        $entry.size_bytes = [int]$fi.Length
        try { $entry.sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLower() } catch {}
        if ($fi.Length -gt ($MaxFileKb * 1024)) { $entry.reason = 'too_large'; return $entry }
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        $m = Mask-MwSecrets -Text $raw -Patterns $MaskPatterns
        $entry.content = $m.Text; $entry.masked = $m.Masked
    } catch {
        $entry.readable = $false; $entry.reason = 'permission_denied'; $entry.content = ''; $entry.sha256 = ''
    }
    return $entry
}

function Get-PatchesInfo {
    Write-Host '  Collecting: patches ...'
    @(Safe-Exec -Label 'patches' -Block {
        $hotfixes = $null
        try { $hotfixes = Get-HotFix -ErrorAction Stop }
        catch { try { $hotfixes = Get-CimInstance Win32_QuickFixEngineering -ErrorAction Stop } catch {} }
        if ($null -eq $hotfixes) { return @() }
        $hotfixes | ForEach-Object {
            $installed = ''
            try { if ($_.InstalledOn) { $installed = ([datetime]$_.InstalledOn).ToString('yyyy-MM-dd') } } catch {}
            @{
                id          = "$($_.HotFixID)"
                description = "$($_.Description)"
                installed_on = $installed
            }
        } | Sort-Object { $_['id'] }
    })
}
function Get-TuningInfo {
    Write-Host '  Collecting: tuning ...'
    $r = @{}
    $r['pagefile'] = @(Safe-Exec -Label 'tuning.pagefile' -Block {
        Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue |
            ForEach-Object { @{ path = "$($_.Name)"; initial_mb = [int]$_.InitialSize; maximum_mb = [int]$_.MaximumSize } }
    })
    $r['registry'] = Safe-Exec -Label 'tuning.registry' -Block {
        $p = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
        $keys = 'TcpTimedWaitDelay','MaxUserPort','MaxFreeTcbs'
        $h = @{}
        $item = Get-ItemProperty -Path $p -ErrorAction SilentlyContinue
        foreach ($k in $keys) {
            $pp = $item.PSObject.Properties[$k]
            if ($pp) { $h[$k] = "$($pp.Value)" }
        }
        $h
    }
    $r['power_scheme'] = Safe-Exec -Label 'tuning.power' -Block {
        $o = (powercfg /getactivescheme) 2>$null
        if ($o) { "$o".Trim() } else { '' }
    }
    $r
}
function Get-ScheduledInfo {
    Write-Host '  Collecting: scheduled ...'
    $r = @{}
    $r['scheduled_tasks'] = @(Safe-Exec -Label 'scheduled.tasks' -Block {
        Get-ScheduledTask -ErrorAction SilentlyContinue |
            Where-Object { $_.State -in @('Ready','Running') } |
            ForEach-Object { @{ name = "$($_.TaskName)"; path = "$($_.TaskPath)"; state = "$($_.State)" } } |
            Sort-Object { $_['path'] + $_['name'] }
    })
    $r['startup'] = @(Safe-Exec -Label 'scheduled.startup' -Block {
        $items = @()
        foreach ($hive in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
                            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run')) {
            $scope = if ($hive -like 'HKLM*') { 'machine' } else { 'user' }
            $props = Get-ItemProperty -Path $hive -ErrorAction SilentlyContinue
            if ($props) {
                $props.PSObject.Properties |
                    Where-Object { $_.Name -notlike 'PS*' } |
                    ForEach-Object { $items += @{ name = $_.Name; command = "$($_.Value)"; scope = $scope } }
            }
        }
        $items
    })
    $r
}

# ============================================================
# Section 3: Invoke-Collect
# ============================================================

function Invoke-Collect {
    param(
        [string]$Mode,           # 'collect', 'before', or 'after'
        [string[]]$Categories,
        [string]$OutFile,
        [string]$SnapLabel
    )
    # Resolve categories
    $allCategories = @('os','network','services','packages','users','filesystem','environment','security','patches','tuning','scheduled','middleware')
    $resolved = if ($Categories -contains 'all') { $allCategories } else {
        $Categories | Where-Object { $allCategories -contains $_ }
    }

    # Build output filename if not specified
    if (-not $OutFile) {
        $hostName = $env:COMPUTERNAME
        $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
        $labelPart = if ($SnapLabel) { "_$SnapLabel" } else { '' }
        $OutFile = Join-Path (Get-Location) "${hostName}_${Mode}${labelPart}_${ts}.json"
    }

    $outputDir = Split-Path -Parent $OutFile
    if ($outputDir -and -not (Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }

    Write-Host "Collecting server info ($Mode): $($resolved -join ', ')"

    $result = [ordered]@{
        meta = @{
            hostname     = $env:COMPUTERNAME
            os_type      = 'windows'
            collected_at = [DateTimeOffset]::Now.ToString('yyyy-MM-ddTHH:mm:sszzz')
            categories   = @($resolved)
        }
    }

    foreach ($cat in $resolved) {
        $result[$cat] = switch ($cat) {
            'os'          { Get-OsInfo }
            'network'     { Get-NetworkInfo }
            'services'    { Get-ServicesInfo }
            'packages'    { Get-PackagesInfo }
            'users'       { Get-UsersInfo }
            'filesystem'  { Get-FilesystemInfo }
            'environment' { Get-EnvironmentInfo }
            'security'    { Get-SecurityInfo }
            'patches'     { Get-PatchesInfo }
            'tuning'      { Get-TuningInfo }
            'scheduled'   { Get-ScheduledInfo }
            'middleware'  { Get-MiddlewareInfo }
        }
    }

    $json = $result | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($OutFile, $json, [System.Text.Encoding]::UTF8)

    Write-Host ''
    Write-Host "Done."
    Write-Host "  Hostname : $($env:COMPUTERNAME)"
    Write-Host "  Output   : $OutFile"

    return $OutFile
}

# ============================================================
# Section 4: Comparison infrastructure
# ============================================================

class CompareItem {
    [string]$State
    [string]$Key
    [string]$BeforeValue
    [string]$AfterValue
}

class CategoryResult {
    [string]$Name
    [System.Collections.Generic.List[CompareItem]]$Items
    [int]$SameCount; [int]$ChangedCount; [int]$RemovedCount; [int]$AddedCount
    CategoryResult([string]$n) {
        $this.Name = $n
        $this.Items = [System.Collections.Generic.List[CompareItem]]::new()
        $this.SameCount = 0; $this.ChangedCount = 0; $this.RemovedCount = 0; $this.AddedCount = 0
    }
    [void] Add([string]$state, [string]$key, [string]$bv, [string]$av) {
        $i = [CompareItem]::new()
        $i.State = $state; $i.Key = $key; $i.BeforeValue = $bv; $i.AfterValue = $av
        $this.Items.Add($i)
        switch ($state) {
            'same'    { $this.SameCount++ }
            'changed' { $this.ChangedCount++ }
            'removed' { $this.RemovedCount++ }
            'added'   { $this.AddedCount++ }
        }
    }
}

# ============================================================
# Helpers
# ============================================================

function Format-Val([object]$v) {
    if ($null -eq $v) { return '' }
    if ($v -is [System.Collections.IDictionary]) { return ($v.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ' }
    if ($v -is [System.Collections.IEnumerable] -and $v -isnot [string]) { return ($v | ForEach-Object { "$_" }) -join ', ' }
    return "$v"
}

function Compare-Dict([hashtable]$bDict, [hashtable]$aDict, [string]$catName) {
    $result = [CategoryResult]::new($catName)
    $allKeys = @($bDict.Keys) + @($aDict.Keys) | Sort-Object -Unique
    foreach ($k in $allKeys) {
        $bv = Format-Val $bDict[$k]
        $av = Format-Val $aDict[$k]
        if (-not $bDict.ContainsKey($k))     { $result.Add('added',   $k, '',  $av) }
        elseif (-not $aDict.ContainsKey($k)) { $result.Add('removed', $k, $bv, '')  }
        elseif ($bv -eq $av)                 { $result.Add('same',    $k, $bv, $av) }
        else                                 { $result.Add('changed', $k, $bv, $av) }
    }
    return $result
}

function Compare-List([object[]]$bList, [object[]]$aList, [string]$keyField, [string[]]$valueFields, [string]$catName) {
    $result = [CategoryResult]::new($catName)
    $bDict  = @{}
    $aDict  = @{}
    foreach ($item in $bList) { $kv = $item[$keyField]; if ($kv) { $bDict["$kv"] = $item } }
    foreach ($item in $aList) { $kv = $item[$keyField]; if ($kv) { $aDict["$kv"] = $item } }
    $allKeys = @($bDict.Keys) + @($aDict.Keys) | Sort-Object -Unique
    foreach ($k in $allKeys) {
        if (-not $bDict.ContainsKey($k)) {
            $av = ($valueFields | ForEach-Object { "$_=$(Format-Val $aDict[$k][$_])" }) -join ', '
            $result.Add('added', $k, '', $av)
        } elseif (-not $aDict.ContainsKey($k)) {
            $bv = ($valueFields | ForEach-Object { "$_=$(Format-Val $bDict[$k][$_])" }) -join ', '
            $result.Add('removed', $k, $bv, '')
        } else {
            $bv = ($valueFields | ForEach-Object { "$_=$(Format-Val $bDict[$k][$_])" }) -join ', '
            $av = ($valueFields | ForEach-Object { "$_=$(Format-Val $aDict[$k][$_])" }) -join ', '
            if ($bv -eq $av) { $result.Add('same', $k, $bv, $av) }
            else             { $result.Add('changed', $k, $bv, $av) }
        }
    }
    return $result
}

function Get-Prop([object]$obj, [string]$key) {
    if ($null -eq $obj) { return $null }
    if ($obj -is [System.Collections.IDictionary]) { return $obj[$key] }
    return $obj.$key
}

function As-Array([object]$v) {
    if ($null -eq $v) { return @() }
    if ($v -is [System.Collections.IEnumerable] -and $v -isnot [string]) { return @($v) }
    return @($v)
}

function Obj-To-Dict([object]$obj) {
    if ($null -eq $obj) { return @{} }
    if ($obj -is [System.Collections.IDictionary]) {
        $h = @{}; foreach ($k in $obj.Keys) { $h[$k] = Obj-To-Dict $obj[$k] }; return $h
    }
    if ($obj -is [System.Collections.IEnumerable] -and $obj -isnot [string]) {
        return @($obj | ForEach-Object { Obj-To-Dict $_ })
    }
    if ($obj -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}; $obj.PSObject.Properties | ForEach-Object { $h[$_.Name] = Obj-To-Dict $_.Value }; return $h
    }
    return $obj
}

# ============================================================
# Category comparators
# ============================================================

function Compare-Os($b, $a) {
    # Exclude instantaneous/volatile metrics — they fluctuate between any two
    # snapshots and do not indicate a meaningful configuration change.
    $volatile = @('free_memory_gb','used_memory_gb','swap_free_gb')
    $bd = Obj-To-Dict $b; $ad = Obj-To-Dict $a
    foreach ($k in $volatile) { $bd.Remove($k) | Out-Null; $ad.Remove($k) | Out-Null }
    Compare-Dict $bd $ad 'os'
}

function Compare-Network($b, $a) {
    $results = [System.Collections.Generic.List[CategoryResult]]::new()
    $conv = { param($src, $key) @(As-Array (Get-Prop $src $key) | ForEach-Object { Obj-To-Dict $_ }) }
    $results.Add((Compare-List (& $conv $b 'interfaces')  (& $conv $a 'interfaces')  'name'        @('address','prefix')                  'network/interfaces'))
    $results.Add((Compare-List (& $conv $b 'routes')      (& $conv $a 'routes')      'destination' @('gateway','interface')               'network/routes'))
    $results.Add((Compare-List (& $conv $b 'dns_servers') (& $conv $a 'dns_servers') 'interface'   @('servers')                           'network/dns'))
    $results.Add((Compare-List (& $conv $b 'hosts')       (& $conv $a 'hosts')       'ip'          @('hostnames')                         'network/hosts'))
    # time_sync: strip _volatile before comparing
    $bTs = Get-Prop $b 'time_sync'; $aTs = Get-Prop $a 'time_sync'
    if ($null -ne $bTs -or $null -ne $aTs) {
        $bd = if ($null -ne $bTs) { Obj-To-Dict $bTs } else { @{} }
        $ad = if ($null -ne $aTs) { Obj-To-Dict $aTs } else { @{} }
        $bd.Remove('_volatile') | Out-Null
        $ad.Remove('_volatile') | Out-Null
        $results.Add((Compare-Dict $bd $ad 'network/time_sync'))
    }
    # proxy
    $bP = Get-Prop $b 'proxy'; $aP = Get-Prop $a 'proxy'
    if ($null -ne $bP -or $null -ne $aP) {
        $bd2 = if ($null -ne $bP) { Obj-To-Dict $bP } else { @{} }
        $ad2 = if ($null -ne $aP) { Obj-To-Dict $aP } else { @{} }
        $results.Add((Compare-Dict $bd2 $ad2 'network/proxy'))
    }
    return $results
}

function Compare-Services($b, $a) {
    $bl = @(As-Array $b | ForEach-Object { Obj-To-Dict $_ })
    $al = @(As-Array $a | ForEach-Object { Obj-To-Dict $_ })
    Compare-List $bl $al 'name' @('status','start_type') 'services'
}

function Compare-Packages($b, $a) {
    $bl = @(As-Array $b | ForEach-Object { Obj-To-Dict $_ })
    $al = @(As-Array $a | ForEach-Object { Obj-To-Dict $_ })
    Compare-List $bl $al 'name' @('version','vendor') 'packages'
}

function Compare-Users($b, $a) {
    $results = [System.Collections.Generic.List[CategoryResult]]::new()
    $bU = @(As-Array (Get-Prop $b 'local_users')  | ForEach-Object { Obj-To-Dict $_ })
    $aU = @(As-Array (Get-Prop $a 'local_users')  | ForEach-Object { Obj-To-Dict $_ })
    $bG = @(As-Array (Get-Prop $b 'local_groups') | ForEach-Object { Obj-To-Dict $_ })
    $aG = @(As-Array (Get-Prop $a 'local_groups') | ForEach-Object { Obj-To-Dict $_ })
    $results.Add((Compare-List $bU $aU 'name' @('enabled','shell','full_name') 'users/local_users'))
    $results.Add((Compare-List $bG $aG 'name' @('members')                     'users/local_groups'))
    return $results
}

function Compare-Filesystem($b, $a) {
    # Compare only stable drive attributes (total size, filesystem type, label).
    # used_gb / free_gb / used_pct fluctuate continuously and are not meaningful
    # indicators of a configuration change.
    $bd = @(As-Array (Get-Prop $b 'drives') | ForEach-Object { Obj-To-Dict $_ })
    $ad = @(As-Array (Get-Prop $a 'drives') | ForEach-Object { Obj-To-Dict $_ })
    Compare-List $bd $ad 'drive' @('total_gb','fstype','label') 'filesystem'
}

function Compare-Environment($b, $a) {
    $results = [System.Collections.Generic.List[CategoryResult]]::new()
    $bm = if ($null -ne (Get-Prop $b 'machine')) { Obj-To-Dict (Get-Prop $b 'machine') } else { @{} }
    $am = if ($null -ne (Get-Prop $a 'machine')) { Obj-To-Dict (Get-Prop $a 'machine') } else { @{} }
    $results.Add((Compare-Dict $bm $am 'environment/machine'))
    $bu = if ($null -ne (Get-Prop $b 'user')) { Obj-To-Dict (Get-Prop $b 'user') } else { @{} }
    $au = if ($null -ne (Get-Prop $a 'user')) { Obj-To-Dict (Get-Prop $a 'user') } else { @{} }
    if ($bu.Count -gt 0 -or $au.Count -gt 0) {
        $results.Add((Compare-Dict $bu $au 'environment/user'))
    }
    return $results
}

function Compare-Security($b, $a) {
    $results = [System.Collections.Generic.List[CategoryResult]]::new()
    $bp = @(As-Array (Get-Prop $b 'firewall_profiles') | ForEach-Object { Obj-To-Dict $_ })
    $ap = @(As-Array (Get-Prop $a 'firewall_profiles') | ForEach-Object { Obj-To-Dict $_ })
    if ($bp.Count -gt 0 -or $ap.Count -gt 0) {
        $results.Add((Compare-List $bp $ap 'name' @('enabled','inbound_action','outbound_action') 'security/firewall_profiles'))
    }
    $br = @(As-Array (Get-Prop $b 'firewall_rules') | ForEach-Object { Obj-To-Dict $_ })
    $ar = @(As-Array (Get-Prop $a 'firewall_rules') | ForEach-Object { Obj-To-Dict $_ })
    $results.Add((Compare-List $br $ar 'name' @('direction','action','profile') 'security/firewall_rules'))
    return $results
}

function Compare-Patches($b, $a) {
    $bl = @(As-Array $b | ForEach-Object { Obj-To-Dict $_ })
    $al = @(As-Array $a | ForEach-Object { Obj-To-Dict $_ })
    Compare-List $bl $al 'id' @('description','installed_on') 'patches'
}

function Compare-Tuning($b, $a) {
    $bd = Obj-To-Dict $b; $ad = Obj-To-Dict $a
    Compare-Dict $bd $ad 'tuning'
}

function Compare-Scheduled($b, $a) {
    $results = [System.Collections.Generic.List[CategoryResult]]::new()
    $bt = @(As-Array (Get-Prop $b 'scheduled_tasks') | ForEach-Object { Obj-To-Dict $_ })
    $at = @(As-Array (Get-Prop $a 'scheduled_tasks') | ForEach-Object { Obj-To-Dict $_ })
    $results.Add((Compare-List $bt $at 'name' @('state','path') 'scheduled/tasks'))
    $bs = @(As-Array (Get-Prop $b 'startup') | ForEach-Object { Obj-To-Dict $_ })
    $as = @(As-Array (Get-Prop $a 'startup') | ForEach-Object { Obj-To-Dict $_ })
    $results.Add((Compare-List $bs $as 'name' @('command','scope') 'scheduled/startup'))
    return $results
}

function Compare-Middleware($b, $a) {
    $results = [System.Collections.Generic.List[CategoryResult]]::new()
    $bd = Obj-To-Dict $b; $ad = Obj-To-Dict $a
    # product -> (key builder, scalar value fields, config field name)
    $specs = @(
        @{ prod='hana';      key={ param($x) "$($x['sid'])" };                          vals=@('version','instance_no','state'); cfg='config_files' },
        @{ prod='sap';       key={ param($x) "$($x['sid'])/$($x['instance'])" };        vals=@('kernel_version','type','state'); cfg='profiles' },
        @{ prod='sqlserver'; key={ param($x) "$($x['instance_name'])" };                vals=@('version','edition','state','port','sp_configure_available'); cfg='config_files' },
        @{ prod='tomcat';    key={ param($x) "$($x['name'])@$($x['catalina_base'])" };  vals=@('version','java_version','state'); cfg='config_files' }
    )
    foreach ($s in $specs) {
        $bl = @(As-Array $bd[$s.prod] | ForEach-Object { Obj-To-Dict $_ })
        $al = @(As-Array $ad[$s.prod] | ForEach-Object { Obj-To-Dict $_ })
        if (-not $bl.Count -and -not $al.Count) { continue }
        # scalar fields: build keyed dicts carrying a 'name' field for Compare-List
        $bScalar = @($bl | ForEach-Object { $h = @{ name = (& $s.key $_) }; foreach ($v in $s.vals) { $h[$v] = $_[$v] }; $h })
        $aScalar = @($al | ForEach-Object { $h = @{ name = (& $s.key $_) }; foreach ($v in $s.vals) { $h[$v] = $_[$v] }; $h })
        $results.Add((Compare-List $bScalar $aScalar 'name' $s.vals "middleware/$($s.prod)"))
        # config files compared by sha256 (key = instanceKey::path, value = sha256)
        $bCfg = @(); $aCfg = @()
        foreach ($inst in $bl) {
            $raw = $inst[$s.cfg]
            if ($null -eq $raw) { continue }
            $files = Obj-To-Dict $raw
            foreach ($p in $files.Keys) { $bCfg += @{ name = "$(& $s.key $inst)::$p"; sha256 = (Obj-To-Dict $files[$p])['sha256'] } }
        }
        foreach ($inst in $al) {
            $raw = $inst[$s.cfg]
            if ($null -eq $raw) { continue }
            $files = Obj-To-Dict $raw
            foreach ($p in $files.Keys) { $aCfg += @{ name = "$(& $s.key $inst)::$p"; sha256 = (Obj-To-Dict $files[$p])['sha256'] } }
        }
        if ($bCfg.Count -or $aCfg.Count) {
            $results.Add((Compare-List $bCfg $aCfg 'name' @('sha256') "middleware/$($s.prod)/files"))
        }
    }
    return $results
}

# ============================================================
# Console output
# ============================================================

function Write-CategoryConsole([CategoryResult]$r, [bool]$diffOnly) {
    $diffCount = $r.ChangedCount + $r.RemovedCount + $r.AddedCount
    $color = if ($diffCount -gt 0) { 'Yellow' } else { 'Green' }
    Write-Host "`n=== $($r.Name.ToUpper()) ===" -ForegroundColor $color
    Write-Host "  same=$($r.SameCount)  changed=$($r.ChangedCount)  removed=$($r.RemovedCount)  added=$($r.AddedCount)"
    foreach ($item in $r.Items) {
        if ($diffOnly -and $item.State -eq 'same') { continue }
        $col   = switch ($item.State) { 'same' {'DarkGray'} 'changed' {'Yellow'} 'removed' {'Red'} 'added' {'Cyan'} }
        $label = switch ($item.State) { 'same' {'SAME   '} 'changed' {'CHANGED'} 'removed' {'REMOVED'} 'added' {'ADDED  '} }
        $key   = $item.Key.PadRight(40)
        Write-Host "  $label  $key" -ForegroundColor $col -NoNewline
        switch ($item.State) {
            'same'    { Write-Host " $($item.BeforeValue)" -ForegroundColor DarkGray }
            'changed' { Write-Host " before: $($item.BeforeValue)" -ForegroundColor Red -NoNewline; Write-Host "  after: $($item.AfterValue)" -ForegroundColor Green }
            'removed' { Write-Host " $($item.BeforeValue)" -ForegroundColor Red }
            'added'   { Write-Host " $($item.AfterValue)"  -ForegroundColor Cyan }
        }
    }
}

# ============================================================
# HTML generation
# ============================================================

function New-HtmlReport {
    param([hashtable]$bMeta, [hashtable]$aMeta, [System.Collections.Generic.List[CategoryResult]]$AllResults)

    $totalSame    = ($AllResults | Measure-Object SameCount    -Sum).Sum
    $totalChanged = ($AllResults | Measure-Object ChangedCount -Sum).Sum
    $totalRemoved = ($AllResults | Measure-Object RemovedCount -Sum).Sum
    $totalAdded   = ($AllResults | Measure-Object AddedCount   -Sum).Sum
    $totalDiff    = $totalChanged + $totalRemoved + $totalAdded

    $bH = if ($bMeta) { $bMeta['hostname'] }     else { 'Before' }
    $aH = if ($aMeta) { $aMeta['hostname'] }     else { 'After' }
    $bT = if ($bMeta) { $bMeta['collected_at'] } else { '' }
    $aT = if ($aMeta) { $aMeta['collected_at'] } else { '' }

    $navLinks = ($AllResults | ForEach-Object { "<a href='#$($_.Name.Replace('/','_'))'>$($_.Name)</a>" }) -join ' | '

    $catHtml = foreach ($r in $AllResults) {
        $anchorId  = $r.Name.Replace('/','_')
        $diffCount = $r.ChangedCount + $r.RemovedCount + $r.AddedCount
        $badge     = if ($diffCount -gt 0) { "<span class='badge badge-diff'>$diffCount diff</span>" } else { "<span class='badge badge-ok'>OK</span>" }
        $rows = foreach ($item in $r.Items) {
            $bvE = [System.Net.WebUtility]::HtmlEncode($item.BeforeValue)
            $avE = [System.Net.WebUtility]::HtmlEncode($item.AfterValue)
            $kE  = [System.Net.WebUtility]::HtmlEncode($item.Key)
            "<tr class='$($item.State)'><td class='key'>$kE</td><td class='val-before'>$bvE</td><td class='val-after'>$avE</td></tr>"
        }
        $stats = "same: $($r.SameCount) | <span class='txt-changed'>changed: $($r.ChangedCount)</span> | <span class='txt-removed'>removed: $($r.RemovedCount)</span> | <span class='txt-added'>added: $($r.AddedCount)</span>"
        @"
<section id="$anchorId" class="category">
  <h2>$($r.Name) $badge <small>$stats</small></h2>
  <table><thead><tr><th>Key / Name</th><th>Before ($bH)</th><th>After ($aH)</th></tr></thead>
  <tbody>$($rows -join "`n")</tbody></table>
</section>
"@
    }

    $gen = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    return @"
<!DOCTYPE html><html lang="ja"><head><meta charset="UTF-8">
<title>Server Comparison Report</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Segoe UI',Arial,sans-serif;font-size:13px;background:#f0f2f5;color:#222}
a{color:#2563eb;text-decoration:none}a:hover{text-decoration:underline}
.header{background:#1e293b;color:#fff;padding:20px 24px}
.header h1{font-size:20px;font-weight:600}
.header .sub{font-size:12px;color:#94a3b8;margin-top:4px}
.header .nav{margin-top:12px;font-size:12px}.header .nav a{color:#93c5fd;margin-right:10px}
.summary{display:flex;gap:12px;padding:16px 24px;flex-wrap:wrap}
.card{background:#fff;border-radius:8px;padding:16px 20px;text-align:center;flex:1;min-width:120px;box-shadow:0 1px 3px rgba(0,0,0,.1)}
.card .num{font-size:28px;font-weight:700}.card .lbl{font-size:11px;color:#64748b;margin-top:2px}
.card.ok .num{color:#16a34a}.card.diff .num{color:#d97706}.card.rem .num{color:#dc2626}.card.add .num{color:#2563eb}
.servers{display:flex;gap:12px;padding:0 24px 16px}
.server-card{background:#fff;border-radius:8px;padding:14px 18px;flex:1;box-shadow:0 1px 3px rgba(0,0,0,.1)}
.server-card .title{font-size:11px;font-weight:600;color:#64748b;text-transform:uppercase}
.server-card .hostname{font-size:16px;font-weight:700;margin:4px 0 2px}
.server-card .meta{font-size:11px;color:#64748b}
.filter-bar{padding:8px 24px;display:flex;gap:8px;align-items:center}
.filter-bar label{font-size:12px;color:#64748b;margin-right:4px}
.filter-bar button{font-size:12px;padding:4px 12px;border:1px solid #cbd5e1;border-radius:4px;background:#fff;cursor:pointer}
.filter-bar button.active{background:#1e293b;color:#fff;border-color:#1e293b}
.category{background:#fff;margin:0 24px 16px;border-radius:8px;padding:16px;box-shadow:0 1px 3px rgba(0,0,0,.1)}
.category h2{font-size:15px;font-weight:600;margin-bottom:10px;display:flex;align-items:center;gap:8px;flex-wrap:wrap}
.category h2 small{font-size:11px;color:#64748b;font-weight:400}
.badge{font-size:11px;padding:2px 8px;border-radius:10px;font-weight:600}
.badge-ok{background:#dcfce7;color:#16a34a}.badge-diff{background:#fef3c7;color:#d97706}
table{width:100%;border-collapse:collapse;font-size:12px}
th{background:#f1f5f9;padding:7px 10px;text-align:left;font-weight:600;color:#475569;border-bottom:2px solid #e2e8f0}
td{padding:6px 10px;border-bottom:1px solid #f1f5f9;vertical-align:top;word-break:break-all}
tr:last-child td{border-bottom:none}
tr.same td{background:#f8fafc;color:#94a3b8}
tr.changed td{background:#fffbeb}
tr.changed td.key{color:#92400e;font-weight:600}tr.changed td.val-before{color:#b91c1c}tr.changed td.val-after{color:#15803d}
tr.removed td{background:#fff1f2}tr.removed td.key{color:#9f1239;font-weight:600}tr.removed td.val-before{color:#b91c1c}
tr.added td{background:#eff6ff}tr.added td.key{color:#1e3a5f;font-weight:600}tr.added td.val-after{color:#1d4ed8}
td.key{width:28%;font-weight:500}td.val-before,td.val-after{width:36%}
.hidden{display:none}.txt-changed{color:#d97706}.txt-removed{color:#dc2626}.txt-added{color:#2563eb}
.footer{text-align:center;padding:20px;font-size:11px;color:#94a3b8}
</style></head><body>
<div class="header">
  <h1>&#128202; Server Comparison Report</h1>
  <div class="sub">Generated: $gen</div>
  <div class="nav">$navLinks</div>
</div>
<div class="summary">
  <div class="card diff"><div class="num">$totalDiff</div><div class="lbl">Total Differences</div></div>
  <div class="card ok">  <div class="num">$totalSame</div><div class="lbl">Identical</div></div>
  <div class="card diff"><div class="num">$totalChanged</div><div class="lbl">Changed</div></div>
  <div class="card rem"> <div class="num">$totalRemoved</div><div class="lbl">Removed</div></div>
  <div class="card add"> <div class="num">$totalAdded</div><div class="lbl">Added</div></div>
</div>
<div class="servers">
  <div class="server-card"><div class="title">Before</div><div class="hostname">$bH</div><div class="meta">Collected: $bT</div></div>
  <div class="server-card"><div class="title">After</div><div class="hostname">$aH</div><div class="meta">Collected: $aT</div></div>
</div>
<div class="filter-bar">
  <label>Show:</label>
  <button class="active" onclick="filterRows('all',this)">All</button>
  <button onclick="filterRows('changed',this)">Changed</button>
  <button onclick="filterRows('removed',this)">Removed</button>
  <button onclick="filterRows('added',this)">Added</button>
  <button onclick="filterRows('diff',this)">Differences only</button>
</div>
$($catHtml -join "`n")
<div class="footer">ServerSnapshot.ps1 &bull; $gen</div>
<script>
function filterRows(mode,btn){
  document.querySelectorAll('.filter-bar button').forEach(b=>b.classList.remove('active'));
  btn.classList.add('active');
  document.querySelectorAll('tbody tr').forEach(row=>{
    var show=mode==='all'||row.classList.contains(mode)||(mode==='diff'&&!row.classList.contains('same'));
    row.classList.toggle('hidden',!show);
  });
}
</script></body></html>
"@
}

# ============================================================
# Section 5: Invoke-Compare
# ============================================================

function Invoke-Compare {
    param(
        [string]$Bf,
        [string]$Af,
        [string]$Html,
        [string[]]$Categories,
        [switch]$OnlyDiff
    )

    if (-not (Test-Path -LiteralPath $Bf)) {
        [Console]::Error.WriteLine("[ERROR] Before file not found: $Bf"); exit 2
    }
    if (-not (Test-Path -LiteralPath $Af)) {
        [Console]::Error.WriteLine("[ERROR] After file not found: $Af"); exit 2
    }

    # Try Python engine first (produces identical output across platforms)
    # NOTE: use $PSScriptRoot, not $MyInvocation.MyCommand.Path — the latter
    # is empty when accessed inside a function and triggers a Split-Path error.
    $pythonComparator = Join-Path $PSScriptRoot 'compare_server_info.py'
    if ((Test-Path $pythonComparator) -and ($Categories -contains 'all' -or $Categories.Count -eq 0)) {
        $py = Get-Command python3 -ErrorAction SilentlyContinue
        if (-not $py) { $py = Get-Command python -ErrorAction SilentlyContinue }
        if (-not $py) { $py = Get-Command py     -ErrorAction SilentlyContinue }
        if ($py) {
            $pyArgs = @($pythonComparator, $Bf, $Af)
            if ($Html)     { $pyArgs += @('--html', $Html) }
            if ($OnlyDiff) { $pyArgs += '--diff-only' }
            $pyArgs += '--no-color'
            & $py.Source @pyArgs
            if ($LASTEXITCODE -eq 0) { return }
            Write-Warning "compare_server_info.py exited with $LASTEXITCODE; falling back to PS native compare"
            # Reset so the leaked non-zero Python exit code does not become the
            # script's exit code once the PS-native fallback completes successfully.
            $global:LASTEXITCODE = 0
        }
    }

    # PS-native comparison fallback
    $bRaw  = Get-Content -LiteralPath $Bf -Encoding UTF8 -Raw | ConvertFrom-Json
    $aRaw  = Get-Content -LiteralPath $Af -Encoding UTF8 -Raw | ConvertFrom-Json
    $bData = Obj-To-Dict $bRaw
    $aData = Obj-To-Dict $aRaw
    $bMeta = Obj-To-Dict ($bData['meta'])
    $aMeta = Obj-To-Dict ($aData['meta'])

    $allCats   = @('os','network','services','packages','users','filesystem','environment','security','patches','tuning','scheduled','middleware')
    $availCats = $allCats | Where-Object { $bData.ContainsKey($_) -and $aData.ContainsKey($_) }
    $compareCats = if ($Categories -contains 'all') { $availCats } else {
        $Categories | Where-Object { $availCats -contains $_ }
    }

    $allResults = [System.Collections.Generic.List[CategoryResult]]::new()

    foreach ($cat in $compareCats) {
        $bCat = $bData[$cat]
        $aCat = $aData[$cat]
        $catResults = switch ($cat) {
            'os'          { @(Compare-Os          $bCat $aCat) }
            'network'     { @(Compare-Network     $bCat $aCat) }
            'services'    { @(Compare-Services    $bCat $aCat) }
            'packages'    { @(Compare-Packages    $bCat $aCat) }
            'users'       { @(Compare-Users       $bCat $aCat) }
            'filesystem'  { @(Compare-Filesystem  $bCat $aCat) }
            'environment' { @(Compare-Environment $bCat $aCat) }
            'security'    { @(Compare-Security    $bCat $aCat) }
            'patches'     { @(Compare-Patches     $bCat $aCat) }
            'tuning'      { @(Compare-Tuning      $bCat $aCat) }
            'scheduled'   { @(Compare-Scheduled   $bCat $aCat) }
            'middleware'  { @(Compare-Middleware  $bCat $aCat) }
        }
        foreach ($cr in $catResults) { $allResults.Add($cr) }
    }

    # Console output
    Write-Host ''
    Write-Host '╔══════════════════════════════════════════╗' -ForegroundColor Cyan
    Write-Host "║  CHANGE DETECTION REPORT"                 -ForegroundColor Cyan
    Write-Host "║  Before : $($bMeta['hostname'])  ($($bMeta['collected_at']))" -ForegroundColor Cyan
    Write-Host "║  After  : $($aMeta['hostname'])  ($($aMeta['collected_at']))" -ForegroundColor Cyan
    Write-Host '╚══════════════════════════════════════════╝' -ForegroundColor Cyan

    foreach ($r in $allResults) { Write-CategoryConsole $r $OnlyDiff.IsPresent }

    $totalDiff = ($allResults | ForEach-Object { $_.ChangedCount + $_.RemovedCount + $_.AddedCount } | Measure-Object -Sum).Sum
    Write-Host "`n=== SUMMARY ===" -ForegroundColor Cyan
    foreach ($r in $allResults) {
        $d   = $r.ChangedCount + $r.RemovedCount + $r.AddedCount
        $col = if ($d -gt 0) { 'Yellow' } else { 'Green' }
        Write-Host ("  {0,-32} same={1,4}  changed={2,4}  removed={3,4}  added={4,4}" -f $r.Name, $r.SameCount, $r.ChangedCount, $r.RemovedCount, $r.AddedCount) -ForegroundColor $col
    }
    $summaryColor = if ($totalDiff -gt 0) { 'Yellow' } else { 'Green' }
    Write-Host "`n  Total differences: $totalDiff" -ForegroundColor $summaryColor
    Write-Host ''

    if ($Html) {
        $htmlDir = Split-Path -Parent $Html
        if ($htmlDir -and -not (Test-Path $htmlDir)) {
            New-Item -ItemType Directory -Path $htmlDir -Force | Out-Null
        }
        $htmlContent = New-HtmlReport -bMeta $bMeta -aMeta $aMeta -AllResults $allResults
        [System.IO.File]::WriteAllText($Html, $htmlContent, [System.Text.Encoding]::UTF8)
        Write-Host "  HTML report: $Html" -ForegroundColor Green
    }
}

# ============================================================
# Section 6: Find-LatestBefore
# ============================================================

function Find-LatestBefore {
    $hostName = $env:COMPUTERNAME
    $pattern = "${hostName}_before*.json"
    $found = Get-ChildItem -Filter $pattern -ErrorAction SilentlyContinue |
             Sort-Object Name -Descending |
             Select-Object -First 1
    if ($found) { return $found.FullName } else { return '' }
}

# ============================================================
# Section 7: Invoke-List
# ============================================================

function Invoke-List {
    $files = @(Get-ChildItem -Filter '*_collect_*.json' -ErrorAction SilentlyContinue) +
             @(Get-ChildItem -Filter '*_before_*.json'  -ErrorAction SilentlyContinue) +
             @(Get-ChildItem -Filter '*_after_*.json'   -ErrorAction SilentlyContinue) |
             Sort-Object Name -Descending
    if ($files.Count -eq 0) {
        Write-Host "No snapshots found in current directory."
        return
    }
    Write-Host ''
    Write-Host "  Snapshots in: $(Get-Location)" -ForegroundColor Cyan
    Write-Host "  $('-' * 70)"
    foreach ($f in $files) {
        $sizeKb = [math]::Round($f.Length / 1KB, 1)
        Write-Host ("  {0,-50} {1,8} KB  {2}" -f $f.Name, $sizeKb, $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))
    }
    Write-Host "  $('-' * 70)"
    Write-Host "  Total: $($files.Count) snapshot(s)"
    Write-Host ''
}

# ============================================================
# Section 8: Main dispatch
# ============================================================

# Start log transcript if launched from .bat
if ($env:OPS_LOG_FILE) {
    Start-Transcript -Path $env:OPS_LOG_FILE -Force -Append -ErrorAction SilentlyContinue | Out-Null
}

try {
    switch ($Command) {
        'collect' {
            Invoke-Collect -Mode 'collect' -Categories $Category -OutFile $OutputPath -SnapLabel $Label
        }
        'before' {
            $outFile = Invoke-Collect -Mode 'before' -Categories $Category -OutFile $OutputPath -SnapLabel $Label
            Write-Host ''
            Write-Host "  Before snapshot saved: $outFile" -ForegroundColor Green
            $afterCmd = ".\ServerSnapshot.ps1 after$(if($Label){" -Label $Label"})"
            Write-Host "  Run '$afterCmd' after making your changes." -ForegroundColor DarkGray
        }
        'after' {
            $outFile = Invoke-Collect -Mode 'after' -Categories $Category -OutFile $OutputPath -SnapLabel $Label
            Write-Host ''
            Write-Host "  After snapshot saved: $outFile" -ForegroundColor Green

            if (-not $BeforePath) {
                $BeforePath = Find-LatestBefore
                if (-not $BeforePath) {
                    [Console]::Error.WriteLine('[ERROR] No before snapshot found. Run ServerSnapshot.ps1 before first.')
                    exit 2
                }
                Write-Host "  Using before snapshot: $BeforePath" -ForegroundColor DarkGray
            }

            Invoke-Compare -Bf $BeforePath -Af $outFile -Html $HtmlReport -Categories $Category -OnlyDiff:$DiffOnly
        }
        'compare' {
            if (-not $BeforePath) { [Console]::Error.WriteLine('[ERROR] -BeforePath is required for compare'); exit 1 }
            if (-not $AfterPath)  { [Console]::Error.WriteLine('[ERROR] -AfterPath is required for compare');  exit 1 }
            Invoke-Compare -Bf $BeforePath -Af $AfterPath -Html $HtmlReport -Categories $Category -OnlyDiff:$DiffOnly
        }
        'list' {
            Invoke-List
        }
    }
} catch {
    Write-Error "Failed: $($_.Exception.Message)"
    exit 4
}
