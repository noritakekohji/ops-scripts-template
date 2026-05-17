#Requires -Version 5.1
<#
.SYNOPSIS
    MySQL / MariaDB ライフサイクル統合制御：start / stop / restart / status を 1 本で。Windows / Linux 共通仕様。
.DESCRIPTION
    MySQL / MariaDB ライフサイクル統合制御：start / stop / restart / status を 1 本で。Windows / Linux 共通仕様。

    Windows サービスとして稼働する MySQL / MariaDB を
    Get-Service / Start-Service / Stop-Service / Restart-Service で制御する。

    サービス名の例:
      - MySQL80      (MySQL 8.0、インストーラーの既定)
      - MySQL57      (MySQL 5.7)
      - MySQL        (手動インストール / 古いバージョン)
      - MariaDB      (MariaDB)

    Usage: MySQLCtl.ps1 <action> <service_name> [-Wait] [-WaitTimeoutSec N]

      start    skip if Running
      stop     skip if Stopped
      restart  always perform
      status   read-only state report

.EXAMPLE
    .\MySQLCtl.ps1 start  MySQL80 -Wait
    .\MySQLCtl.ps1 stop   MySQL80 -Wait -WaitTimeoutSec 60
    .\MySQLCtl.ps1 restart MySQL80
    .\MySQLCtl.ps1 status  MySQL80
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('start', 'stop', 'restart', 'status')]
    [string]$Action,

    [Parameter(Mandatory, Position = 1)]
    [ValidatePattern('^[A-Za-z0-9._\-\$ ]{1,64}$')]
    [string]$ServiceName,

    [switch]$Wait,

    [ValidateRange(5, 600)]
    [int]$WaitTimeoutSec = 120
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
$cfg = Get-OpsConfig -Name 'mysqlctl'
$cfgEnv = if ($env:OPS_ENV) { $env:OPS_ENV } else { 'default' }
$logFile  = if ($cfg.ContainsKey('LogFile'))  { [string]$cfg['LogFile'] }  else { '' }
$logLevel = if ($cfg.ContainsKey('LogLevel')) { [string]$cfg['LogLevel'] } else { 'INFO' }
Set-OpsLogConfig -LogFile $logFile -LogLevel $logLevel
if (-not $PSBoundParameters.ContainsKey('WaitTimeoutSec') -and $cfg.ContainsKey('WaitTimeoutSec')) { $WaitTimeoutSec = [int]$cfg['WaitTimeoutSec'] }
if (-not $PSBoundParameters.ContainsKey('Wait')           -and $cfg.ContainsKey('Wait')) {
    if ([System.Convert]::ToBoolean($cfg['Wait'])) { $Wait = $true }
}

$exitCode    = 0
$status      = 'unknown'
$beforeState = ''
$afterState  = ''

try {
    do {
        Write-OpsLog -Level INFO -Message "Config loaded: env=$cfgEnv keys=$($cfg.Count)"
        Write-OpsLog -Level INFO -Message "Args validated: action=$Action service=$ServiceName wait=$Wait timeoutSec=$WaitTimeoutSec"

        # --- Phase 3: Pre-checks ---------------------------------------------
        Write-OpsLog -Level INFO -Message 'Pre-check start'

        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if (-not $svc) {
            Write-OpsLog -Level ERROR -Message "Service not found: service=$ServiceName"
            $exitCode = 2; $status = 'failed'; break
        }
        $beforeState = $svc.Status.ToString()
        Write-OpsLog -Level INFO -Message "Current state: service=$ServiceName state=$beforeState"

        if ($Action -eq 'status') {
            # mysql.exe のバージョン情報も付加（インストールされている場合）
            $dbVer = ''
            $mysqlExe = Get-Command mysql -ErrorAction SilentlyContinue
            if ($mysqlExe) {
                $dbVer = (& $mysqlExe.Source --version 2>$null) -join ''
            }
            Write-OpsLog -Level INFO -Message "Status: service=$ServiceName state=$beforeState startType=$($svc.StartType) displayName='$($svc.DisplayName)' version='$dbVer'"
            $afterState = $beforeState; $status = 'success'; break
        }

        if ($Action -eq 'start' -and $beforeState -eq 'Running') {
            Write-OpsLog -Level INFO -Message "Skipped (idempotent): service=$ServiceName state=Running"
            $afterState = $beforeState; $status = 'skipped'; break
        }
        if ($Action -eq 'stop' -and $beforeState -eq 'Stopped') {
            Write-OpsLog -Level INFO -Message "Skipped (idempotent): service=$ServiceName state=Stopped"
            $afterState = $beforeState; $status = 'skipped'; break
        }

        Write-OpsLog -Level INFO -Message 'Pre-check passed'

        # --- Phase 4: Main processing ----------------------------------------
        Write-OpsLog -Level INFO -Message 'Main start'

        if (-not $PSCmdlet.ShouldProcess($ServiceName, "MySQL/MariaDB $Action")) { break }

        switch ($Action) {
            'start'   { Start-Service   -Name $ServiceName }
            'stop'    { Stop-Service    -Name $ServiceName -Force }
            'restart' { Restart-Service -Name $ServiceName }
        }
        Write-OpsLog -Level INFO -Message "$Action initiated: service=$ServiceName"

        if ($Wait) {
            $targetState = if ($Action -eq 'stop') { 'Stopped' } else { 'Running' }
            Write-OpsLog -Level INFO -Message "Waiting for state: service=$ServiceName target=$targetState timeoutSec=$WaitTimeoutSec"
            try {
                (Get-Service -Name $ServiceName).WaitForStatus($targetState, [TimeSpan]::FromSeconds($WaitTimeoutSec))
            }
            catch {
                $afterState = (Get-Service -Name $ServiceName).Status.ToString()
                Write-OpsLog -Level ERROR -Message "Did not reach target state within timeout: service=$ServiceName target=$targetState actual=$afterState timeoutSec=$WaitTimeoutSec"
                $exitCode = 3; $status = 'failed'; break
            }
            Write-OpsLog -Level INFO -Message "Reached target state: service=$ServiceName state=$targetState"
        }

        $afterState = (Get-Service -Name $ServiceName).Status.ToString()
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
    Write-OpsLog -Level INFO -Message "Script end: status=$status exitCode=$exitCode action=$Action service=$ServiceName before=$beforeState after=$afterState"
}

exit $exitCode
