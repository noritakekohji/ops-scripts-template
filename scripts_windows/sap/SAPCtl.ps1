#Requires -Version 5.1
<#
.SYNOPSIS
    SAP システム（S/4HANA / NetWeaver / ECC）ライフサイクル統合制御：start / stop / restart / status を 1 本で。
.DESCRIPTION
    SAP システム（S/4HANA / NetWeaver / ECC）ライフサイクル統合制御：start / stop / restart / status を 1 本で。

    制御方法（優先順位）:
      1. sapcontrol.exe -nr <NN> -function Start/Stop/RestartInstance/GetProcessList
         （SAP Host Agent / SAPCAR インストール済み環境で利用可能）
      2. Windows サービス経由（Get-Service / Start-Service / Stop-Service）
         SAP インスタンスは "SAP<SID>_<NN>" の形式でサービス登録される

    Usage: SAPCtl.ps1 <action> -SID <SID> -InstanceNumber <NN> [-Wait] [-WaitTimeoutSec N]
           SAPCtl.ps1 <action> -ServiceName <service> [-Wait] [-WaitTimeoutSec N]

    SID + InstanceNumber で指定する場合:
      start    SAP システムを起動（既に Running ならスキップ）
      stop     SAP システムを停止（既に Stopped ならスキップ）
      restart  停止してから起動
      status   プロセスリストを表示（read-only）

.EXAMPLE
    .\SAPCtl.ps1 start   -SID S4H -InstanceNumber 00 -Wait
    .\SAPCtl.ps1 stop    -SID S4H -InstanceNumber 00 -Wait -WaitTimeoutSec 600
    .\SAPCtl.ps1 restart -SID S4H -InstanceNumber 00 -Wait
    .\SAPCtl.ps1 status  -SID S4H -InstanceNumber 00
    # サービス名で直接指定する場合
    .\SAPCtl.ps1 start   -ServiceName SAPS4H_00 -Wait
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'BySID')]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('start', 'stop', 'restart', 'status')]
    [string]$Action,

    # --- BySID ---
    [Parameter(Mandatory, ParameterSetName = 'BySID')]
    [ValidatePattern('^[A-Z][A-Z0-9]{2}$')]
    [string]$SID,

    [Parameter(Mandatory, ParameterSetName = 'BySID')]
    [ValidatePattern('^\d{2}$')]
    [string]$InstanceNumber,

    # --- ByServiceName ---
    [Parameter(Mandatory, ParameterSetName = 'ByServiceName')]
    [ValidatePattern('^[A-Za-z0-9._\-\$ ]{1,64}$')]
    [string]$ServiceName,

    [switch]$Wait,

    [ValidateRange(30, 3600)]
    [int]$WaitTimeoutSec = 600
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- Phase 2: lib + config --------------------------------------------------
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
$cfg = Get-OpsConfig -Name 'sapctl'
$cfgEnv = if ($env:OPS_ENV) { $env:OPS_ENV } else { 'default' }
$logFile  = if ($cfg.ContainsKey('LogFile'))  { [string]$cfg['LogFile'] }  else { '' }
$logLevel = if ($cfg.ContainsKey('LogLevel')) { [string]$cfg['LogLevel'] } else { 'INFO' }
Set-OpsLogConfig -LogFile $logFile -LogLevel $logLevel
if (-not $PSBoundParameters.ContainsKey('WaitTimeoutSec') -and $cfg.ContainsKey('WaitTimeoutSec')) { $WaitTimeoutSec = [int]$cfg['WaitTimeoutSec'] }
if (-not $PSBoundParameters.ContainsKey('Wait')           -and $cfg.ContainsKey('Wait')) {
    if ([System.Convert]::ToBoolean($cfg['Wait'])) { $Wait = $true }
}

# --- SID/NN から必要な値を解決 -----------------------------------------------
$instNr      = ''
$ctrlMethod  = 'service'   # "sapcontrol" or "service"
$svcName     = ''

if ($PSCmdlet.ParameterSetName -eq 'BySID') {
    $instNr  = $InstanceNumber
    $svcName = "SAP${SID}_${InstanceNumber}"
} else {
    $svcName = $ServiceName
    # SID と NR をサービス名から推測（SAP<SID>_<NN> パターン）
    if ($ServiceName -match '^SAP([A-Z0-9]{3})_(\d{2})$') {
        $SID    = $Matches[1]
        $instNr = $Matches[2]
    }
}

# sapcontrol.exe の検索
$sapcontrolExe = $null
$sapcontrolCandidates = @(
    'sapcontrol',
    'C:\Program Files\SAP\hostctrl\exe\sapcontrol.exe',
    'C:\usr\sap\hostctrl\exe\sapcontrol.exe'
)
foreach ($candidate in $sapcontrolCandidates) {
    if (Get-Command $candidate -ErrorAction SilentlyContinue) {
        $sapcontrolExe = $candidate; break
    }
}
if ($sapcontrolExe -and $instNr) {
    $ctrlMethod = 'sapcontrol'
}

$exitCode    = 0
$status      = 'unknown'
$beforeState = ''
$afterState  = ''

function Get-SAPState {
    if ($ctrlMethod -eq 'sapcontrol') {
        try {
            $out = & $sapcontrolExe -nr $instNr -function GetSystemInstanceList 2>$null
            if ($out -match 'GREEN|RUNNING') { return 'Running' }
            if ($out -match 'GRAY|STOPPED')  { return 'Stopped' }
        } catch {}
        return 'Unknown'
    } else {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if (-not $svc) { return 'Unknown' }
        return $svc.Status.ToString()
    }
}

try {
    do {
        Write-OpsLog -Level INFO -Message "Config loaded: env=$cfgEnv keys=$($cfg.Count)"
        Write-OpsLog -Level INFO -Message "Args: action=$Action SID=$SID NR=$instNr service=$svcName ctrlMethod=$ctrlMethod wait=$Wait timeoutSec=$WaitTimeoutSec"

        # --- Phase 3: Pre-checks ---------------------------------------------
        Write-OpsLog -Level INFO -Message 'Pre-check start'

        if ($ctrlMethod -eq 'service') {
            $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
            if (-not $svc) {
                Write-OpsLog -Level ERROR -Message "SAP service not found: service=$svcName"
                $exitCode = 2; $status = 'failed'; break
            }
        }

        $beforeState = Get-SAPState
        Write-OpsLog -Level INFO -Message "Current state: SID=$SID NR=$instNr state=$beforeState"

        if ($Action -eq 'status') {
            if ($ctrlMethod -eq 'sapcontrol') {
                Write-OpsLog -Level INFO -Message '--- GetProcessList ---'
                & $sapcontrolExe -nr $instNr -function GetProcessList 2>$null | ForEach-Object { Write-OpsLog -Level INFO -Message $_ }
                Write-OpsLog -Level INFO -Message '--- GetSystemInstanceList ---'
                & $sapcontrolExe -nr $instNr -function GetSystemInstanceList 2>$null | ForEach-Object { Write-OpsLog -Level INFO -Message $_ }
            } else {
                $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
                if ($svc) {
                    Write-OpsLog -Level INFO -Message "Status: service=$svcName state=$($svc.Status) startType=$($svc.StartType) displayName='$($svc.DisplayName)'"
                }
            }
            $afterState = $beforeState; $status = 'success'; break
        }

        if ($Action -eq 'start' -and $beforeState -eq 'Running') {
            Write-OpsLog -Level INFO -Message "Skipped (idempotent): SID=$SID state=Running"
            $afterState = $beforeState; $status = 'skipped'; break
        }
        if ($Action -eq 'stop' -and $beforeState -eq 'Stopped') {
            Write-OpsLog -Level INFO -Message "Skipped (idempotent): SID=$SID state=Stopped"
            $afterState = $beforeState; $status = 'skipped'; break
        }

        Write-OpsLog -Level INFO -Message 'Pre-check passed'

        # --- Phase 4: Main processing ----------------------------------------
        Write-OpsLog -Level INFO -Message 'Main start'

        if (-not $PSCmdlet.ShouldProcess("$SID/$instNr", "SAP $Action")) { break }

        if ($ctrlMethod -eq 'sapcontrol') {
            $sapFunc = switch ($Action) {
                'start'   { 'Start' }
                'stop'    { 'Stop' }
                'restart' { 'RestartInstance' }
            }
            $rc = & $sapcontrolExe -nr $instNr -function $sapFunc 2>$null
            if ($LASTEXITCODE -notin @(0, 1)) {   # sapcontrol: 0=OK, 1=already running/stopped
                Write-OpsLog -Level ERROR -Message "sapcontrol $sapFunc failed: SID=$SID NR=$instNr rc=$LASTEXITCODE"
                $exitCode = 4; $status = 'failed'; break
            }
        } else {
            switch ($Action) {
                'start'   { Start-Service   -Name $svcName }
                'stop'    { Stop-Service    -Name $svcName -Force }
                'restart' {
                    Stop-Service    -Name $svcName -Force -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 5
                    Start-Service   -Name $svcName
                }
            }
        }
        Write-OpsLog -Level INFO -Message "$Action initiated: SID=$SID NR=$instNr"

        if ($Wait) {
            $targetState = if ($Action -eq 'stop') { 'Stopped' } else { 'Running' }
            Write-OpsLog -Level INFO -Message "Waiting for state: SID=$SID target=$targetState timeoutSec=$WaitTimeoutSec"
            $deadline = [datetime]::UtcNow.AddSeconds($WaitTimeoutSec)
            while ([datetime]::UtcNow -lt $deadline) {
                $current = Get-SAPState
                if ($current -eq $targetState) {
                    Write-OpsLog -Level INFO -Message "Reached target state: SID=$SID state=$current"
                    break
                }
                Start-Sleep -Seconds 15
            }
            $current = Get-SAPState
            if ($current -ne $targetState) {
                Write-OpsLog -Level ERROR -Message "Timeout waiting for state: SID=$SID target=$targetState actual=$current timeoutSec=$WaitTimeoutSec"
                $afterState = $current; $exitCode = 3; $status = 'failed'; break
            }
        }

        $afterState = Get-SAPState
        Write-OpsLog -Level INFO -Message 'Main complete'
        $status = 'success'
    } while ($false)
}
catch {
    Write-OpsLog -Level ERROR -Message "Operation failed: error=$($_.Exception.Message)"
    if ($exitCode -eq 0) { $exitCode = 4 }
    $status = 'failed'
}
finally {
    Write-OpsLog -Level INFO -Message "Script end: status=$status exitCode=$exitCode action=$Action SID=$SID NR=$instNr before=$beforeState after=$afterState"
}

exit $exitCode
