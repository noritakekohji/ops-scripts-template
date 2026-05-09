#Requires -Version 7
<#
.SYNOPSIS
    Creates EBS snapshot(s) and optionally prunes old ones.

.DESCRIPTION
    Snapshots either a single volume (-VolumeId) or all volumes attached to
    an instance (-InstanceId). Snapshots are tagged with CreatedBy /
    NamePrefix / RetentionDays for safe lifecycle management.

    Authentication: relies on the default AWS credential chain.

.PARAMETER VolumeId
    Single EBS volume id (vol-...). Mutually exclusive with -InstanceId.

.PARAMETER InstanceId
    Snapshot every EBS volume currently attached to this instance.

.PARAMETER NamePrefix
    Prefix for snapshot Name tag and pruning filter. Use a stable value per
    system, e.g. "prod-db".

.PARAMETER Region
    AWS region. Falls back to default region from env / profile.

.PARAMETER RetentionDays
    Snapshots created by this script with the same NamePrefix older than
    this many days are deleted. 0 disables pruning.

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

    [switch]$Wait
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- import shared logging --------------------------------------------------
$libPath = Join-Path $PSScriptRoot '..' '..' '..' '..' 'lib' 'powershell' 'Logging.psm1'
if (-not (Test-Path $libPath)) {
    throw "Logging module not found at $libPath"
}
Import-Module (Resolve-Path $libPath).Path -Force

# --- ensure AWS module ------------------------------------------------------
if (-not (Get-Module -ListAvailable AWS.Tools.EC2)) {
    Write-OpsLog -Level ERROR -Message 'AWS.Tools.EC2 module is not installed' `
        -Properties @{ remediation = 'Install-Module AWS.Tools.EC2 -Scope CurrentUser' }
    exit 10
}
Import-Module AWS.Tools.EC2

$aws = @{}
if ($Region) { $aws.Region = $Region }

# --- resolve volumes --------------------------------------------------------
$volumes = @()
if ($PSCmdlet.ParameterSetName -eq 'Instance') {
    Write-OpsLog -Level INFO -Message 'Resolving volumes for instance' `
        -Properties @{ instanceId = $InstanceId }
    try {
        $instance = (Get-EC2Instance -InstanceId $InstanceId @aws).Instances[0]
    }
    catch {
        Write-OpsLog -Level ERROR -Message 'Instance lookup failed' `
            -Properties @{ instanceId = $InstanceId; error = $_.Exception.Message }
        exit 2
    }
    $volumes = @(
        $instance.BlockDeviceMappings |
            Where-Object { $_.Ebs } |
            ForEach-Object { $_.Ebs.VolumeId }
    )
    if ($volumes.Count -eq 0) {
        Write-OpsLog -Level ERROR -Message 'No EBS volumes attached' `
            -Properties @{ instanceId = $InstanceId }
        exit 2
    }
}
else {
    $volumes = @($VolumeId)
}

Write-OpsLog -Level INFO -Message 'EBS snapshot start' -Properties @{
    namePrefix    = $NamePrefix
    region        = $Region
    retentionDays = $RetentionDays
    volumeCount   = $volumes.Count
}

# --- create snapshots -------------------------------------------------------
$ts = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
$created = @()

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
            Write-OpsLog -Level INFO -Message 'Snapshot initiated' `
                -Properties @{ snapshotId = $snap.SnapshotId; volumeId = $vol }
            $created += $snap.SnapshotId
        }
        catch {
            Write-OpsLog -Level ERROR -Message 'Snapshot creation failed' `
                -Properties @{ volumeId = $vol; error = $_.Exception.Message }
            exit 4
        }
    }
}

# --- optional wait ----------------------------------------------------------
if ($Wait -and $created.Count -gt 0) {
    Write-OpsLog -Level INFO -Message 'Waiting for snapshots to complete' `
        -Properties @{ count = $created.Count }
    while ($true) {
        Start-Sleep -Seconds 15
        $statuses = Get-EC2Snapshot -SnapshotId $created @aws
        $errored = @($statuses | Where-Object { $_.State -eq 'error' })
        if ($errored.Count -gt 0) {
            Write-OpsLog -Level ERROR -Message 'Snapshot(s) failed' `
                -Properties @{ snapshotIds = ($errored.SnapshotId -join ',') }
            exit 3
        }
        $pending = @($statuses | Where-Object { $_.State -eq 'pending' })
        if ($pending.Count -eq 0) { break }
        Write-OpsLog -Level INFO -Message 'Snapshots pending' `
            -Properties @{ pending = $pending.Count }
    }
    Write-OpsLog -Level INFO -Message 'All snapshots completed'
}

# --- prune old snapshots ----------------------------------------------------
if ($RetentionDays -gt 0) {
    Write-OpsLog -Level INFO -Message 'Pruning old snapshots' `
        -Properties @{ namePrefix = $NamePrefix; retentionDays = $RetentionDays }

    $cutoff = (Get-Date).ToUniversalTime().AddDays(-$RetentionDays)
    $filter = @(
        @{ Name = 'tag:CreatedBy';  Values = 'ops-scripts' },
        @{ Name = 'tag:NamePrefix'; Values = $NamePrefix }
    )
    $oldSnaps = Get-EC2Snapshot -OwnerId self -Filter $filter @aws |
        Where-Object { $_.StartTime.ToUniversalTime() -lt $cutoff } |
        Where-Object { $created -notcontains $_.SnapshotId }

    foreach ($s in $oldSnaps) {
        if ($PSCmdlet.ShouldProcess($s.SnapshotId, "Delete snapshot (started $($s.StartTime))")) {
            try {
                Remove-EC2Snapshot -SnapshotId $s.SnapshotId -Force @aws | Out-Null
                Write-OpsLog -Level INFO -Message 'Deleted snapshot' `
                    -Properties @{ snapshotId = $s.SnapshotId; startedAt = $s.StartTime }
            }
            catch {
                Write-OpsLog -Level WARN -Message 'Snapshot delete failed' `
                    -Properties @{ snapshotId = $s.SnapshotId; error = $_.Exception.Message }
            }
        }
    }
}

Write-OpsLog -Level INFO -Message 'EBS snapshot backup complete' `
    -Properties @{ created = $created.Count }
exit 0
