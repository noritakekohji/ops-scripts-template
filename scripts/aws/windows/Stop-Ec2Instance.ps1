#Requires -Version 7
<#
.SYNOPSIS
    Stops one or more EC2 instances. Idempotent: already-stopped
    instances are skipped without error.

.DESCRIPTION
    Reads behavior parameters from config files (Region / Wait /
    WaitTimeoutSec / ForceStop). Per-run targets (-InstanceId) are CLI-only.

    Idempotency:
      - stopped / stopping  : skipped
      - running             : stopped
      - pending             : warned (cannot transition pending -> stopped directly)
      - shutting-down / terminated : exit 3 (invalid state)

    -ForceStop forces immediate halt without OS shutdown — use only when
    a graceful shutdown is hung. Data loss possible.

    Authentication: relies on the default AWS credential chain.

.PARAMETER InstanceId
    One or more EC2 instance IDs. Comma-separated for multiple.

.PARAMETER Region

.PARAMETER Wait
    Wait until every stopped instance reaches 'stopped'.

.PARAMETER WaitTimeoutSec
    Maximum seconds to wait when -Wait is set. Default: 600.

.PARAMETER ForceStop
    Force-stop without graceful OS shutdown.

.EXAMPLE
    .\Stop-Ec2Instance.ps1 -InstanceId i-0abc -Wait

.EXAMPLE
    .\Stop-Ec2Instance.ps1 -InstanceId i-0abc,i-0def -Region ap-northeast-1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateScript({
        foreach ($id in $_) {
            if ($id -notmatch '^i-[0-9a-f]{8,17}$') { throw "Invalid instance id: $id" }
        }
        $true
    })]
    [string[]]$InstanceId,

    [string]$Region,

    [switch]$Wait,

    [ValidateRange(30, 3600)]
    [int]$WaitTimeoutSec = 600,

    [switch]$ForceStop
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- Phase 2: shared lib ----------------------------------------------------
$libPath = Join-Path $PSScriptRoot '..' '..' '..' 'lib' 'powershell' 'Logging.psm1'
if (-not (Test-Path $libPath)) { throw "Logging module not found at $libPath" }
Import-Module (Resolve-Path $libPath).Path -Force

$configModulePath = Join-Path $PSScriptRoot '..' '..' '..' 'lib' 'powershell' 'Config.psm1'
Import-Module (Resolve-Path $configModulePath).Path -Force
$cfg = Get-OpsConfig -Name 'Stop-Ec2Instance'
$cfgEnv = if ($env:OPS_ENV) { $env:OPS_ENV } else { 'common' }
if (-not $PSBoundParameters.ContainsKey('Region')         -and $cfg.ContainsKey('Region'))         { $Region         = [string]$cfg['Region'] }
if (-not $PSBoundParameters.ContainsKey('WaitTimeoutSec') -and $cfg.ContainsKey('WaitTimeoutSec')) { $WaitTimeoutSec = [int]$cfg['WaitTimeoutSec'] }
if (-not $PSBoundParameters.ContainsKey('Wait')           -and $cfg.ContainsKey('Wait')) {
    if ([System.Convert]::ToBoolean($cfg['Wait'])) { $Wait = [switch]::Present }
}
if (-not $PSBoundParameters.ContainsKey('ForceStop')      -and $cfg.ContainsKey('ForceStop')) {
    if ([System.Convert]::ToBoolean($cfg['ForceStop'])) { $ForceStop = [switch]::Present }
}

$exitCode = 0
$status = 'unknown'
$stopped = @()
$skippedStopped = @()

try {
    do {
        Write-OpsLog -Level INFO -Message "Config loaded: env=$cfgEnv keys=$($cfg.Count)"
        Write-OpsLog -Level INFO -Message "Args validated: instanceCount=$($InstanceId.Count) region=$Region wait=$Wait timeoutSec=$WaitTimeoutSec forceStop=$ForceStop"

        # --- Phase 3: pre-check ---------------------------------------------
        Write-OpsLog -Level INFO -Message 'Pre-check start'

        if (-not (Get-Module -ListAvailable AWS.Tools.EC2)) {
            Write-OpsLog -Level ERROR -Message 'AWS.Tools.EC2 module is not installed; install with: Install-Module AWS.Tools.EC2 -Scope CurrentUser'
            $exitCode = 10; $status = 'failed'; break
        }
        Import-Module AWS.Tools.EC2

        $aws = @{}
        if ($Region) { $aws.Region = $Region }

        try {
            $instances = (Get-EC2Instance -InstanceId $InstanceId @aws).Instances
        }
        catch {
            $errMsg = $_.Exception.Message
            if ($errMsg -match 'NotFound|does not exist|InvalidInstanceID') {
                Write-OpsLog -Level ERROR -Message "Instance(s) not found: error=$errMsg"
                $exitCode = 2
            }
            else {
                Write-OpsLog -Level ERROR -Message "AWS API call failed (auth?): error=$errMsg"
                $exitCode = 20
            }
            $status = 'failed'; break
        }

        $foundIds = @($instances | ForEach-Object { $_.InstanceId })
        $missing = $InstanceId | Where-Object { $foundIds -notcontains $_ }
        if ($missing) {
            Write-OpsLog -Level ERROR -Message "Instance(s) not found: instanceIds=$($missing -join ',')"
            $exitCode = 2; $status = 'failed'; break
        }

        $toStop = @()
        foreach ($inst in $instances) {
            $state = $inst.State.Name
            switch ($state) {
                'stopped'       { $skippedStopped += $inst.InstanceId; Write-OpsLog -Level INFO  -Message "Skipped (idempotent): instanceId=$($inst.InstanceId) state=stopped" }
                'stopping'      { $skippedStopped += $inst.InstanceId; Write-OpsLog -Level INFO  -Message "Skipped (idempotent): instanceId=$($inst.InstanceId) state=stopping" }
                'running'       { $toStop         += $inst.InstanceId }
                'pending'       { Write-OpsLog -Level WARN  -Message "Instance is pending; cannot stop now: instanceId=$($inst.InstanceId)" }
                'shutting-down' { Write-OpsLog -Level ERROR -Message "Instance is shutting down: instanceId=$($inst.InstanceId)"; $exitCode = 3 }
                'terminated'    { Write-OpsLog -Level ERROR -Message "Instance is terminated: instanceId=$($inst.InstanceId)"; $exitCode = 3 }
                default         { Write-OpsLog -Level WARN  -Message "Unexpected state: instanceId=$($inst.InstanceId) state=$state" }
            }
        }
        if ($exitCode -ne 0) { $status = 'failed'; break }

        if ($toStop.Count -eq 0) {
            Write-OpsLog -Level INFO -Message "Skipped (idempotent): reason=all_already_stopped count=$($skippedStopped.Count)"
            $exitCode = 0; $status = 'skipped'; break
        }

        Write-OpsLog -Level INFO -Message "Pre-check passed: toStop=$($toStop.Count) skippedStopped=$($skippedStopped.Count)"

        # --- Phase 4: main processing ---------------------------------------
        Write-OpsLog -Level INFO -Message 'Main start'

        if ($PSCmdlet.ShouldProcess(($toStop -join ','), "Stop EC2 instance(s)$(if ($ForceStop) {' (force)'})")) {
            $stopArgs = @{ InstanceId = $toStop }
            if ($ForceStop) { $stopArgs.ForceStop = $true }
            $result = Stop-EC2Instance @stopArgs @aws
            $stopped = @($result | ForEach-Object { $_.InstanceId })
            Write-OpsLog -Level INFO -Message "Stop initiated: instanceIds=$($stopped -join ',') count=$($stopped.Count) force=$ForceStop"
        }

        if ($Wait -and $stopped.Count -gt 0) {
            Write-OpsLog -Level INFO -Message "Waiting for 'stopped': count=$($stopped.Count) timeoutSec=$WaitTimeoutSec"
            $deadline = (Get-Date).AddSeconds($WaitTimeoutSec)
            while ((Get-Date) -lt $deadline) {
                $current = @((Get-EC2Instance -InstanceId $stopped @aws).Instances)
                $pending = @($current | Where-Object { $_.State.Name -ne 'stopped' })
                if ($pending.Count -eq 0) { break }
                Write-OpsLog -Level DEBUG -Message "Polling: pending=$($pending.Count) states=$(($current.State.Name | Sort-Object -Unique) -join ',')"
                Start-Sleep -Seconds 10
            }
            $final = @((Get-EC2Instance -InstanceId $stopped @aws).Instances)
            $notStopped = @($final | Where-Object { $_.State.Name -ne 'stopped' })
            if ($notStopped.Count -gt 0) {
                Write-OpsLog -Level ERROR -Message "Did not reach 'stopped' within timeout: instanceIds=$(($notStopped.InstanceId -join ',')) timeoutSec=$WaitTimeoutSec"
                $exitCode = 3; $status = 'failed'; break
            }
            Write-OpsLog -Level INFO -Message 'All instances are stopped'
        }

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
    Write-OpsLog -Level INFO -Message "Script end: status=$status exitCode=$exitCode stopped=$($stopped.Count) skippedStopped=$($skippedStopped.Count)"
}

exit $exitCode
