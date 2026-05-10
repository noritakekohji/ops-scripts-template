#Requires -Version 5.1
<#
.SYNOPSIS
    SQL Server 繝ｩ繧､繝輔し繧､繧ｯ繝ｫ蛻ｶ蠕｡・嘖tart / stop / restart / status・亥・遲会ｼ峨・
.DESCRIPTION
    Windows 繧ｵ繝ｼ繝薙せ縺ｨ縺励※遞ｼ蜒阪☆繧・SQL Server 繧・Get-Service /
    Start-Service / Stop-Service / Restart-Service 縺ｧ蛻ｶ蠕｡縺吶ｋ縲・
    繧ｵ繝ｼ繝薙せ蜷阪・萓・
      - default instance: MSSQLSERVER
      - named instance:   MSSQL$<INSTANCE>
      - SQL Agent:        SQLSERVERAGENT (default) or SQLAgent$<INSTANCE>

    Usage: SqlServerCtl.ps1 <action> <service_name> [-Wait] [-WaitTimeoutSec N]

    蜀ｪ遲画ｧ:
      start    skip if Running
      stop     skip if Stopped
      restart  always perform
      status   read-only state report

.EXAMPLE
    .\SqlServerCtl.ps1 start MSSQLSERVER -Wait
    .\SqlServerCtl.ps1 stop  'MSSQL$PROD' -Wait
    .\SqlServerCtl.ps1 restart MSSQLSERVER -Wait
    .\SqlServerCtl.ps1 status MSSQLSERVER
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
$libPath = [IO.Path]::Combine($PSScriptRoot, '..', '..', '..', 'lib', 'powershell', 'Logging.psm1')
if (-not (Test-Path $libPath)) { throw "Logging module not found at $libPath" }
Import-Module (Resolve-Path $libPath).Path -Force

$configModulePath = [IO.Path]::Combine($PSScriptRoot, '..', '..', '..', 'lib', 'powershell', 'Config.psm1')
Import-Module (Resolve-Path $configModulePath).Path -Force
$cfg = Get-OpsConfig -Name 'sqlserverctl'
$cfgEnv = if ($env:OPS_ENV) { $env:OPS_ENV } else { 'default' }
if (-not $PSBoundParameters.ContainsKey('WaitTimeoutSec') -and $cfg.ContainsKey('WaitTimeoutSec')) { $WaitTimeoutSec = [int]$cfg['WaitTimeoutSec'] }
if (-not $PSBoundParameters.ContainsKey('Wait')           -and $cfg.ContainsKey('Wait')) {
    if ([System.Convert]::ToBoolean($cfg['Wait'])) { $Wait = $true }
}

$exitCode = 0
$status = 'unknown'
$beforeState = ''
$afterState = ''

try {
    do {
        Write-OpsLog -Level INFO -Message "Config loaded: env=$cfgEnv keys=$($cfg.Count)"
        Write-OpsLog -Level INFO -Message "Args validated: action=$Action service=$ServiceName wait=$Wait timeoutSec=$WaitTimeoutSec"

        # --- 繝輔ぉ繝ｼ繧ｺ 3: 繝励Ξ繝√ぉ繝・け ---------------------------------------------
        Write-OpsLog -Level INFO -Message 'Pre-check start'

        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if (-not $svc) {
            Write-OpsLog -Level ERROR -Message "Service not found: service=$ServiceName"
            $exitCode = 2; $status = 'failed'; break
        }
        $beforeState = $svc.Status.ToString()
        Write-OpsLog -Level INFO -Message "Current state: service=$ServiceName state=$beforeState"

        if ($Action -eq 'status') {
            Write-OpsLog -Level INFO -Message "Status: service=$ServiceName state=$beforeState startType=$($svc.StartType) displayName='$($svc.DisplayName)'"
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

        # --- 繝輔ぉ繝ｼ繧ｺ 4: 繝｡繧､繝ｳ蜃ｦ逅・---------------------------------------
        Write-OpsLog -Level INFO -Message 'Main start'

        if (-not $PSCmdlet.ShouldProcess($ServiceName, "SQL Server $Action")) { break }

        switch ($Action) {
            'start'   { Start-Service   -Name $ServiceName }
            'stop'    { Stop-Service    -Name $ServiceName -Force }
            'restart' { Restart-Service -Name $ServiceName -Force }
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
