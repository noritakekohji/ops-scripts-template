#Requires -Version 7
<#
.SYNOPSIS
    Creates EBS snapshot(s) and optionally prunes old ones.

.DESCRIPTION
    Snapshots either a single volume (-VolumeId) or all volumes attached to
    an instance (-InstanceId). Snapshots are tagged with CreatedBy /
    NamePrefix / RetentionDays for safe lifecycle management.

    Authentication: relies on the default AWS credential chain.

    Flow (per shell-specification.md):
      1. Argument validation
      2. Environment setup
      3. Pre-check               (module / source / idempotency)
      4. Main processing         (create snapshots / wait / prune)
      5. Post-processing         (final status log)

.PARAMETER VolumeId
    Single EBS volume id. Mutually exclusive with -InstanceId.

.PARAMETER InstanceId
    Snapshot every EBS volume currently attached to this instance.

.PARAMETER NamePrefix
    Prefix for snapshot Name tag and pruning filter.

.PARAMETER Region
    AWS region. Falls back to default region from env / profile.

.PARAMETER RetentionDays
    Snapshots older than this with the same NamePrefix are deleted.
    0 disables pruning.

.PARAMETER MinIntervalMinutes
    Idempotency window. If a snapshot with the same NamePrefix was created
    within this many minutes, the run is skipped (status=skipped, exit 0).
    0 disables. Default: 5.

.PARAMETER Wait
    Wait until all created snapshots reach 'completed' state.

.EXAMPLE
    .\Backup-EbsSnapshot.ps1 -VolumeId vol-0abc -NamePrefix prod-db -RetentionDays 14

.EXAMPLE
    .\Backup-EbsSnapshot.ps1 -InstanceId i-0abc -NamePrefix prod-app -Wait
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Volume')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Volume')]
    [ValidatePattern('^vol-[0-9a-f]{8,17}$')]
    [string]$VolumeId,

    [Parameter(Mandatory, ParameterSetName = 'Instance')]
    [ValidatePattern('^i-[0-9a-f]{8,17}$')]
    [string]$InstanceId,

    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{1,120}$')]
    [string]$NamePrefix,

    [string]$Region,

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

$exitCode = 0
$status = 'unknown'
$created = @()

try {
    do {
        Write-OpsLog -Level INFO -Message "Args validated: paramSet=$($PSCmdlet.ParameterSetName) namePrefix=$NamePrefix region=$Region retentionDays=$RetentionDays minIntervalMin=$MinIntervalMinutes"

        # --- Phase 3: pre-check ---------------------------------------------
        Write-OpsLog -Level INFO -Message 'Pre-check start'

        # 3-a: required AWS module
        if (-not (Get-Module -ListAvailable AWS.Tools.EC2)) {
            Write-OpsLog -Level ERROR -Message 'AWS.Tools.EC2 module is not installed; install with: Install-Module AWS.Tools.EC2 -Scope CurrentUser'
            $exitCode = 10; $status = 'failed'; break
        }
        Import-Module AWS.Tools.EC2

        $aws = @{}
        if ($Region) { $aws.Region = $Region }

        # 3-b/c: resolve volumes (combined auth + existence)
        $volumes = @()
        if ($PSCmdlet.ParameterSetName -eq 'Instance') {
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
            $volumes = @(
                $instance.BlockDeviceMappings |
                    Where-Object { $_.Ebs } |
                    ForEach-Object { $_.Ebs.VolumeId }
            )
            if ($volumes.Count -eq 0) {
                Write-OpsLog -Level ERROR -Message "No EBS volumes attached: instanceId=$InstanceId"
                $exitCode = 2; $status = 'failed'; break
            }
        }
        else {
            try {
                Get-EC2Volume -VolumeId $VolumeId @aws | Out-Null
            }
            catch {
                $errMsg = $_.Exception.Message
                if ($errMsg -match 'NotFound|does not exist|InvalidVolume') {
                    Write-OpsLog -Level ERROR -Message "Volume not found: volumeId=$VolumeId error=$errMsg"
                    $exitCode = 2
                }
                else {
                    Write-OpsLog -Level ERROR -Message "AWS API call failed (auth?): volumeId=$VolumeId error=$errMsg"
                    $exitCode = 20
                }
                $status = 'failed'; break
            }
            $volumes = @($VolumeId)
        }

        # 3-d: idempotency
        if ($MinIntervalMinutes -gt 0) {
            $idempCutoff = (Get-Date).ToUniversalTime().AddMinutes(-$MinIntervalMinutes)
            $idempFilter = @(
                @{ Name = 'tag:CreatedBy';  Values = 'ops-scripts' },
                @{ Name = 'tag:NamePrefix'; Values = $NamePrefix }
            )
            $recent = Get-EC2Snapshot -OwnerId self -Filter $idempFilter @aws |
                Where-Object { $_.StartTime.ToUniversalTime() -ge $idempCutoff } |
                Sort-Object StartTime -Descending |
                Select-Object -First 1
            if ($recent) {
                Write-OpsLog -Level INFO -Message "Skipped (idempotent): reason=recent_snapshot_exists snapshotId=$($recent.SnapshotId) startedAt=$($recent.StartTime) minIntervalMin=$MinIntervalMinutes"
                $exitCode = 0; $status = 'skipped'; break
            }
        }

        Write-OpsLog -Level INFO -Message "Pre-check passed: volumeCount=$($volumes.Count)"

        # --- Phase 4: main processing ---------------------------------------
        Write-OpsLog -Level INFO -Message 'Main start'

        $ts = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')

        foreach ($vol in $volumes) {
            $snapName = "${NamePrefix}-${vol}-${ts}"
            $description = "Automated snapshot of $vol at $ts UTC"

            $tagSpec = [Amazon.EC2.Model.TagSpecification]::new()
            $tagSpec.ResourceType = 'snapshot'
            $tagSpec.Tags = @(
                @{ Key = 'Name';           Value = $snapName },
                @{ Key = 'CreatedBy';      Value = 'ops-scripts' },
                @{ Key = 'CreatedAt';      Value = $ts },
                @{ Key = 'SourceVolumeId'; Value = $vol },
                @{ Key = 'NamePrefix';     Value = $NamePrefix },
                @{ Key = 'RetentionDays';  Value = [string]$RetentionDays }
            )

            if ($PSCmdlet.ShouldProcess($vol, "Create snapshot '$snapName'")) {
                try {
                    $snap = New-EC2Snapshot `
                        -VolumeId $vol `
                        -Description $description `
                        -TagSpecification $tagSpec `
                        @aws
                    Write-OpsLog -Level INFO -Message "Snapshot initiated: snapshotId=$($snap.SnapshotId) volumeId=$vol"
                    $created += $snap.SnapshotId
                }
                catch {
                    Write-OpsLog -Level ERROR -Message "Snapshot creation failed: volumeId=$vol error=$($_.Exception.Message)"
                    $exitCode = 4; $status = 'failed'; break
                }
            }
        }
        if ($exitCode -ne 0) { break }

        if ($Wait -and $created.Count -gt 0) {
            Write-OpsLog -Level INFO -Message "Waiting for snapshots to complete: count=$($created.Count)"
            $waitFailed = $false
            while ($true) {
                Start-Sleep -Seconds 15
                $statuses = Get-EC2Snapshot -SnapshotId $created @aws
                $errored = @($statuses | Where-Object { $_.State -eq 'error' })
                if ($errored.Count -gt 0) {
                    Write-OpsLog -Level ERROR -Message "Snapshot(s) failed: snapshotIds=$($errored.SnapshotId -join ',')"
                    $exitCode = 3; $status = 'failed'; $waitFailed = $true
                    break
                }
                $pending = @($statuses | Where-Object { $_.State -eq 'pending' })
                if ($pending.Count -eq 0) { break }
                Write-OpsLog -Level INFO -Message "Snapshots pending: count=$($pending.Count)"
            }
            if ($waitFailed) { break }
            Write-OpsLog -Level INFO -Message 'All snapshots completed'
        }

        # Pruning
        if ($RetentionDays -gt 0) {
            Write-OpsLog -Level INFO -Message "Pruning old snapshots: namePrefix=$NamePrefix retentionDays=$RetentionDays"
            $cutoff = (Get-Date).ToUniversalTime().AddDays(-$RetentionDays)
            $pruneFilter = @(
                @{ Name = 'tag:CreatedBy';  Values = 'ops-scripts' },
                @{ Name = 'tag:NamePrefix'; Values = $NamePrefix }
            )
            $oldSnaps = Get-EC2Snapshot -OwnerId self -Filter $pruneFilter @aws |
                Where-Object { $_.StartTime.ToUniversalTime() -lt $cutoff } |
                Where-Object { $created -notcontains $_.SnapshotId }

            foreach ($s in $oldSnaps) {
                if ($PSCmdlet.ShouldProcess($s.SnapshotId, "Delete snapshot (started $($s.StartTime))")) {
                    try {
                        Remove-EC2Snapshot -SnapshotId $s.SnapshotId -Force @aws | Out-Null
                        Write-OpsLog -Level INFO -Message "Deleted snapshot: snapshotId=$($s.SnapshotId) startedAt=$($s.StartTime)"
                    }
                    catch {
                        Write-OpsLog -Level WARN -Message "Snapshot delete failed: snapshotId=$($s.SnapshotId) error=$($_.Exception.Message)"
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
    # --- Phase 5: post-processing -------------------------------------------
    Write-OpsLog -Level INFO -Message "Script end: status=$status exitCode=$exitCode created=$($created.Count)"
}

exit $exitCode
