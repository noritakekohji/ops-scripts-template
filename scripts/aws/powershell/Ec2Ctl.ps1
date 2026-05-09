#Requires -Version 7
<#
.SYNOPSIS
    EC2 lifecycle control: start / stop / restart / status (idempotent).

.DESCRIPTION
    Usage: Ec2Ctl.ps1 <action> <instanceId[,instanceId,...]> [options]

      start    : start instance(s); already-running ones are skipped
      stop     : stop instance(s);  already-stopped ones are skipped
      restart  : reboot running instance(s) via AWS Reboot API
      status   : show current state (read-only; no -Wait / no idempotency)

    Behavior parameters (Region / Wait / WaitTimeoutSec / ForceStop) can
    be set in config/<env>/Ec2Ctl.conf.

    Authentication: default AWS credential chain.

.EXAMPLE
    .\Ec2Ctl.ps1 start i-0abc -Wait
    .\Ec2Ctl.ps1 stop  i-0abc,i-0def -ForceStop
    .\Ec2Ctl.ps1 restart i-0abc
    .\Ec2Ctl.ps1 status i-0abc,i-0def
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('start', 'stop', 'restart', 'status')]
    [string]$Action,

    [Parameter(Mandatory, Position = 1)]
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

# --- Phase 2: lib + config --------------------------------------------------
$libPath = Join-Path $PSScriptRoot '..' '..' '..' 'lib' 'powershell' 'Logging.psm1'
if (-not (Test-Path $libPath)) { throw "Logging module not found at $libPath" }
Import-Module (Resolve-Path $libPath).Path -Force

$configModulePath = Join-Path $PSScriptRoot '..' '..' '..' 'lib' 'powershell' 'Config.psm1'
Import-Module (Resolve-Path $configModulePath).Path -Force
$cfg = Get-OpsConfig -Name 'ec2ctl'
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
$acted = @()
$skipped = @()

try {
    do {
        Write-OpsLog -Level INFO -Message "Config loaded: env=$cfgEnv keys=$($cfg.Count)"
        Write-OpsLog -Level INFO -Message "Args validated: action=$Action instanceCount=$($InstanceId.Count) region=$Region wait=$Wait timeoutSec=$WaitTimeoutSec forceStop=$ForceStop"

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

        # status action: read-only, just report and exit
        if ($Action -eq 'status') {
            foreach ($inst in $instances) {
                Write-OpsLog -Level INFO -Message "Status: instanceId=$($inst.InstanceId) state=$($inst.State.Name) az=$($inst.Placement.AvailabilityZone) launchTime=$($inst.LaunchTime)"
            }
            $status = 'success'; break
        }

        # action-specific filtering
        $toAct = @()
        $stateInvalid = $false
        foreach ($inst in $instances) {
            $st = $inst.State.Name
            switch ($Action) {
                'start' {
                    switch ($st) {
                        'running'       { $skipped += $inst.InstanceId; Write-OpsLog -Level INFO  -Message "Skipped (idempotent): instanceId=$($inst.InstanceId) state=running" }
                        'pending'       { $skipped += $inst.InstanceId; Write-OpsLog -Level INFO  -Message "Skipped (idempotent): instanceId=$($inst.InstanceId) state=pending" }
                        'stopped'       { $toAct   += $inst.InstanceId }
                        'stopping'      { Write-OpsLog -Level WARN  -Message "Cannot start (stopping): instanceId=$($inst.InstanceId)" }
                        default         { Write-OpsLog -Level ERROR -Message "Cannot start (state=$st): instanceId=$($inst.InstanceId)"; $stateInvalid = $true }
                    }
                }
                'stop' {
                    switch ($st) {
                        'stopped'       { $skipped += $inst.InstanceId; Write-OpsLog -Level INFO  -Message "Skipped (idempotent): instanceId=$($inst.InstanceId) state=stopped" }
                        'stopping'      { $skipped += $inst.InstanceId; Write-OpsLog -Level INFO  -Message "Skipped (idempotent): instanceId=$($inst.InstanceId) state=stopping" }
                        'running'       { $toAct   += $inst.InstanceId }
                        'pending'       { Write-OpsLog -Level WARN  -Message "Cannot stop (pending): instanceId=$($inst.InstanceId)" }
                        default         { Write-OpsLog -Level ERROR -Message "Cannot stop (state=$st): instanceId=$($inst.InstanceId)"; $stateInvalid = $true }
                    }
                }
                'restart' {
                    switch ($st) {
                        'running'       { $toAct   += $inst.InstanceId }
                        default         { Write-OpsLog -Level ERROR -Message "Cannot restart (state=$st, must be running): instanceId=$($inst.InstanceId)"; $stateInvalid = $true }
                    }
                }
            }
        }
        if ($stateInvalid) { $exitCode = 3; $status = 'failed'; break }

        if ($toAct.Count -eq 0) {
            Write-OpsLog -Level INFO -Message "Skipped (idempotent): reason=all_already_in_target_state action=$Action count=$($skipped.Count)"
            $exitCode = 0; $status = 'skipped'; break
        }

        Write-OpsLog -Level INFO -Message "Pre-check passed: action=$Action toAct=$($toAct.Count) skipped=$($skipped.Count)"

        # --- Phase 4: main processing ---------------------------------------
        Write-OpsLog -Level INFO -Message 'Main start'

        if ($PSCmdlet.ShouldProcess(($toAct -join ','), "EC2 $Action")) {
            switch ($Action) {
                'start' {
                    $result = Start-EC2Instance -InstanceId $toAct @aws
                    $acted = @($result | ForEach-Object { $_.InstanceId })
                    Write-OpsLog -Level INFO -Message "Start initiated: instanceIds=$($acted -join ',') count=$($acted.Count)"
                }
                'stop' {
                    $stopArgs = @{ InstanceId = $toAct }
                    if ($ForceStop) { $stopArgs.ForceStop = $true }
                    $result = Stop-EC2Instance @stopArgs @aws
                    $acted = @($result | ForEach-Object { $_.InstanceId })
                    Write-OpsLog -Level INFO -Message "Stop initiated: instanceIds=$($acted -join ',') count=$($acted.Count) force=$ForceStop"
                }
                'restart' {
                    Restart-EC2Instance -InstanceId $toAct @aws | Out-Null
                    $acted = $toAct
                    Write-OpsLog -Level INFO -Message "Restart (reboot) initiated: instanceIds=$($acted -join ',') count=$($acted.Count)"
                }
            }
        }

        # Wait (start/stop only; restart doesn't change observable state)
        if ($Wait -and $acted.Count -gt 0 -and $Action -ne 'restart') {
            $targetState = if ($Action -eq 'start') { 'running' } else { 'stopped' }
            Write-OpsLog -Level INFO -Message "Waiting for '$targetState': count=$($acted.Count) timeoutSec=$WaitTimeoutSec"
            $deadline = (Get-Date).AddSeconds($WaitTimeoutSec)
            while ((Get-Date) -lt $deadline) {
                $current = @((Get-EC2Instance -InstanceId $acted @aws).Instances)
                $pending = @($current | Where-Object { $_.State.Name -ne $targetState })
                if ($pending.Count -eq 0) { break }
                Start-Sleep -Seconds 10
            }
            $final = @((Get-EC2Instance -InstanceId $acted @aws).Instances)
            $notReached = @($final | Where-Object { $_.State.Name -ne $targetState })
            if ($notReached.Count -gt 0) {
                Write-OpsLog -Level ERROR -Message "Did not reach '$targetState' within timeout: instanceIds=$(($notReached.InstanceId -join ',')) timeoutSec=$WaitTimeoutSec"
                $exitCode = 3; $status = 'failed'; break
            }
            Write-OpsLog -Level INFO -Message "All instances reached '$targetState'"
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
    Write-OpsLog -Level INFO -Message "Script end: status=$status exitCode=$exitCode action=$Action acted=$($acted.Count) skipped=$($skipped.Count)"
}

exit $exitCode
