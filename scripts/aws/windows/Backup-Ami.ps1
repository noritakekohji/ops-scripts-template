#Requires -Version 7
<#
.SYNOPSIS
    Creates an AMI backup of an EC2 instance and optionally prunes old AMIs.

.DESCRIPTION
    Uses AWS Tools for PowerShell (AWS.Tools.EC2) to create an AMI of a
    running EC2 instance. The AMI is tagged with CreatedBy / NamePrefix /
    RetentionDays so that older AMIs created by this script with the same
    NamePrefix can be safely pruned.

    Authentication: relies on the default AWS credential chain
    (environment, profile, instance role).

.PARAMETER InstanceId
    EC2 instance to back up (e.g. i-0123456789abcdef0).

.PARAMETER NamePrefix
    Prefix used both as the AMI name (suffixed with timestamp) and as the
    tag key for pruning peer AMIs. Use a stable value per system, e.g.
    "prod-web".

.PARAMETER Region
    AWS region. Falls back to default region from env / profile.

.PARAMETER NoReboot
    When $true (default), the instance is not rebooted during AMI creation.

.PARAMETER RetentionDays
    Days to keep AMIs created by this script for the same NamePrefix.
    Older ones (and their backing snapshots) are deregistered / deleted.
    0 disables pruning.

.PARAMETER Wait
    Wait until the new AMI reaches 'available' state before returning.

.EXAMPLE
    .\Backup-Ami.ps1 -InstanceId i-0abc -NamePrefix prod-web -RetentionDays 7 -Wait
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

    [switch]$Wait
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- import shared logging --------------------------------------------------
$libPath = Join-Path $PSScriptRoot '..' '..' '..' 'lib' 'powershell' 'Logging.psm1'
if (-not (Test-Path $libPath)) {
    throw "Logging module not found at $libPath"
}
Import-Module (Resolve-Path $libPath).Path -Force

# --- ensure AWS module ------------------------------------------------------
if (-not (Get-Module -ListAvailable AWS.Tools.EC2)) {
    Write-OpsLog -Level ERROR -Message 'AWS.Tools.EC2 module is not installed; install with: Install-Module AWS.Tools.EC2 -Scope CurrentUser'
    exit 10
}
Import-Module AWS.Tools.EC2

$aws = @{}
if ($Region) { $aws.Region = $Region }

Write-OpsLog -Level INFO -Message "AMI backup start: instanceId=$InstanceId namePrefix=$NamePrefix region=$Region noReboot=$NoReboot retentionDays=$RetentionDays"

# --- validate instance ------------------------------------------------------
try {
    $instance = (Get-EC2Instance -InstanceId $InstanceId @aws).Instances[0]
}
catch {
    Write-OpsLog -Level ERROR -Message "Instance lookup failed: instanceId=$InstanceId error=$($_.Exception.Message)"
    exit 2
}
if (-not $instance) {
    Write-OpsLog -Level ERROR -Message "Instance not found: instanceId=$InstanceId"
    exit 2
}

# --- create AMI -------------------------------------------------------------
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

$imageId = $null
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

# --- optional wait ----------------------------------------------------------
if ($Wait -and $imageId) {
    Write-OpsLog -Level INFO -Message "Waiting for AMI to become available: amiId=$imageId"
    while ($true) {
        Start-Sleep -Seconds 30
        $img = Get-EC2Image -ImageId $imageId @aws
        Write-OpsLog -Level INFO -Message "AMI state polled: amiId=$imageId state=$($img.State)"
        if ($img.State -eq 'available') { break }
        if ($img.State -ne 'pending') {
            Write-OpsLog -Level ERROR -Message "AMI did not reach available state: amiId=$imageId state=$($img.State)"
            exit 3
        }
    }
}

# --- prune old AMIs ---------------------------------------------------------
if ($RetentionDays -gt 0) {
    Write-OpsLog -Level INFO -Message "Pruning old AMIs: namePrefix=$NamePrefix retentionDays=$RetentionDays"

    $cutoff = (Get-Date).ToUniversalTime().AddDays(-$RetentionDays)
    $filter = @(
        @{ Name = 'tag:CreatedBy';  Values = 'ops-scripts' },
        @{ Name = 'tag:NamePrefix'; Values = $NamePrefix }
    )
    $oldImages = Get-EC2Image -Owner self -Filter $filter @aws |
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

Write-OpsLog -Level INFO -Message "AMI backup complete: amiId=$imageId"
exit 0
