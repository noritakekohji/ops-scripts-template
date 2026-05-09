#Requires -Version 7
<#
.SYNOPSIS
    Creates an AMI backup of an EC2 instance and optionally prunes old AMIs.

.DESCRIPTION
    Behavior parameters can be set in CLI args, in config files, or fall
    back to script defaults. Resolution order (high -> low):
        CLI -> config/<env>/Backup-Ami.conf -> config/<env>/ops.conf
            -> config/common/Backup-Ami.conf -> config/common/ops.conf
            -> script default

    Per-run targets (-InstanceId / -NamePrefix) are CLI-only.

    Authentication: relies on the default AWS credential chain.

    Flow (per shell-specification.md):
      1. Argument validation
      2. Environment setup (logger, config, strict mode)
      3. Pre-check               (module / instance / idempotency)
      4. Main processing         (create AMI / wait / prune)
      5. Post-processing         (final status log)
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidatePattern('^i-[0-9a-f]{8,17}$')]
    [string]$InstanceId,

    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{1,120}$')]
    [string]$NamePrefix,

    [string]$Region,
    [bool]$NoReboot = $true,

    [ValidateRange(0, 3650)]
    [int]$RetentionDays = 0,

    [ValidateRange(0, 1440)]
    [int]$MinIntervalMinutes = 5,

    [switch]$Wait
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- Phase 2: shared logger -------------------------------------------------
$libPath = Join-Path $PSScriptRoot '..' '..' '..' 'lib' 'powershell' 'Logging.psm1'
if (-not (Test-Path $libPath)) {
    throw "Logging module not found at $libPath"
}
Import-Module (Resolve-Path $libPath).Path -Force

# --- Phase 2: load config and apply to unspecified parameters ---------------
$configModulePath = Join-Path $PSScriptRoot '..' '..' '..' 'lib' 'powershell' 'Config.psm1'
Import-Module (Resolve-Path $configModulePath).Path -Force
$cfg = Get-OpsConfig -Name 'backup_ami'
$cfgEnv = if ($env:OPS_ENV) { $env:OPS_ENV } else { 'common' }
if (-not $PSBoundParameters.ContainsKey('Region')             -and $cfg.ContainsKey('Region'))             { $Region             = [string]$cfg['Region'] }
if (-not $PSBoundParameters.ContainsKey('NoReboot')           -and $cfg.ContainsKey('NoReboot'))           { $NoReboot           = [System.Convert]::ToBoolean($cfg['NoReboot']) }
if (-not $PSBoundParameters.ContainsKey('RetentionDays')      -and $cfg.ContainsKey('RetentionDays'))      { $RetentionDays      = [int]$cfg['RetentionDays'] }
if (-not $PSBoundParameters.ContainsKey('MinIntervalMinutes') -and $cfg.ContainsKey('MinIntervalMinutes')) { $MinIntervalMinutes = [int]$cfg['MinIntervalMinutes'] }
if (-not $PSBoundParameters.ContainsKey('Wait')               -and $cfg.ContainsKey('Wait')) {
    if ([System.Convert]::ToBoolean($cfg['Wait'])) { $Wait = [switch]::Present }
}

$exitCode = 0
$status = 'unknown'
$imageId = $null

try {
    do {
        Write-OpsLog -Level INFO -Message "Config loaded: env=$cfgEnv keys=$($cfg.Count)"
        Write-OpsLog -Level INFO -Message "Args validated: instanceId=$InstanceId namePrefix=$NamePrefix region=$Region noReboot=$NoReboot retentionDays=$RetentionDays minIntervalMin=$MinIntervalMinutes"

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
            $instance = (Get-EC2Instance -InstanceId $InstanceId @aws).Instances[0]
        }
        catch {
            $errMsg = $_.Exception.Message
            if ($errMsg -match 'NotFound|does not exist|InvalidInstanceID') {
                Write-OpsLog -Level ERROR -Message "Instance not found: instanceId=$InstanceId error=$errMsg"
                $exitCode = 2
            }
            else {
                Write-OpsLog -Level ERROR -Message "AWS API call failed (auth?): instanceId=$InstanceId error=$errMsg"
                $exitCode = 20
            }
            $status = 'failed'; break
        }
        if (-not $instance) {
            Write-OpsLog -Level ERROR -Message "Instance not found: instanceId=$InstanceId"
            $exitCode = 2; $status = 'failed'; break
        }

        if ($MinIntervalMinutes -gt 0) {
            $idempCutoff = (Get-Date).ToUniversalTime().AddMinutes(-$MinIntervalMinutes)
            $idempFilter = @(
                @{ Name = 'tag:CreatedBy';  Values = 'ops-scripts' },
                @{ Name = 'tag:NamePrefix'; Values = $NamePrefix }
            )
            $recent = Get-EC2Image -Owner self -Filter $idempFilter @aws |
                Where-Object { ([datetime]$_.CreationDate).ToUniversalTime() -ge $idempCutoff } |
                Sort-Object CreationDate -Descending |
                Select-Object -First 1
            if ($recent) {
                Write-OpsLog -Level INFO -Message "Skipped (idempotent): reason=recent_ami_exists amiId=$($recent.ImageId) createdAt=$($recent.CreationDate) minIntervalMin=$MinIntervalMinutes"
                $exitCode = 0; $status = 'skipped'; break
            }
        }

        Write-OpsLog -Level INFO -Message 'Pre-check passed'

        # --- Phase 4: main processing ---------------------------------------
        Write-OpsLog -Level INFO -Message 'Main start'

        $ts = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
        $amiName = "${NamePrefix}-${ts}"
        $description = "Automated backup of $InstanceId at $ts UTC"

        $tagSpec = [Amazon.EC2.Model.TagSpecification]::new()
        $tagSpec.ResourceType = 'image'
        $tagSpec.Tags = @(
            @{ Key = 'Name';             Value = $amiName },
            @{ Key = 'CreatedBy';        Value = 'ops-scripts' },
            @{ Key = 'CreatedAt';        Value = $ts },
            @{ Key = 'SourceInstanceId'; Value = $InstanceId },
            @{ Key = 'NamePrefix';       Value = $NamePrefix },
            @{ Key = 'RetentionDays';    Value = [string]$RetentionDays }
        )

        if ($PSCmdlet.ShouldProcess($InstanceId, "Create AMI '$amiName'")) {
            $imageId = New-EC2Image `
                -InstanceId $InstanceId `
                -Name $amiName `
                -Description $description `
                -NoReboot $NoReboot `
                -TagSpecification $tagSpec `
                @aws
            Write-OpsLog -Level INFO -Message "AMI creation initiated: amiId=$imageId amiName=$amiName"
        }

        if ($Wait -and $imageId) {
            Write-OpsLog -Level INFO -Message "Waiting for AMI to become available: amiId=$imageId"
            $waitOk = $false
            while ($true) {
                Start-Sleep -Seconds 30
                $img = Get-EC2Image -ImageId $imageId @aws
                Write-OpsLog -Level INFO -Message "AMI state polled: amiId=$imageId state=$($img.State)"
                if ($img.State -eq 'available') { $waitOk = $true; break }
                if ($img.State -ne 'pending') {
                    Write-OpsLog -Level ERROR -Message "AMI did not reach available state: amiId=$imageId state=$($img.State)"
                    $exitCode = 3; $status = 'failed'
                    break
                }
            }
            if (-not $waitOk -and $exitCode -ne 0) { break }
        }

        if ($RetentionDays -gt 0) {
            Write-OpsLog -Level INFO -Message "Pruning old AMIs: namePrefix=$NamePrefix retentionDays=$RetentionDays"
            $cutoff = (Get-Date).ToUniversalTime().AddDays(-$RetentionDays)
            $pruneFilter = @(
                @{ Name = 'tag:CreatedBy';  Values = 'ops-scripts' },
                @{ Name = 'tag:NamePrefix'; Values = $NamePrefix }
            )
            $oldImages = Get-EC2Image -Owner self -Filter $pruneFilter @aws |
                Where-Object { ([datetime]$_.CreationDate).ToUniversalTime() -lt $cutoff } |
                Where-Object { $_.ImageId -ne $imageId }

            foreach ($old in $oldImages) {
                $snapIds = $old.BlockDeviceMappings |
                    Where-Object { $_.Ebs } |
                    ForEach-Object { $_.Ebs.SnapshotId }

                if ($PSCmdlet.ShouldProcess($old.ImageId, "Deregister AMI (created $($old.CreationDate))")) {
                    try {
                        Unregister-EC2Image -ImageId $old.ImageId @aws | Out-Null
                        Write-OpsLog -Level INFO -Message "Deregistered AMI: amiId=$($old.ImageId) createdAt=$($old.CreationDate)"
                    }
                    catch {
                        Write-OpsLog -Level WARN -Message "Deregister failed: amiId=$($old.ImageId) error=$($_.Exception.Message)"
                        continue
                    }
                    foreach ($snap in $snapIds) {
                        try {
                            Remove-EC2Snapshot -SnapshotId $snap -Force @aws | Out-Null
                            Write-OpsLog -Level INFO -Message "Deleted snapshot: snapshotId=$snap"
                        }
                        catch {
                            Write-OpsLog -Level WARN -Message "Snapshot delete failed: snapshotId=$snap error=$($_.Exception.Message)"
                        }
                    }
                }
            }
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
    Write-OpsLog -Level INFO -Message "Script end: status=$status exitCode=$exitCode amiId=$imageId"
}

exit $exitCode
