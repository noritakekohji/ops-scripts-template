#Requires -Version 5.1
<#
.SYNOPSIS
    EBS 繧ｹ繝翫ャ繝励す繝ｧ繝・ヨ繧剃ｽ懈・縺励∝ｿ・ｦ√↓蠢懊§縺ｦ蜿､縺・ｂ縺ｮ繧剃ｸ紋ｻ｣蜑企勁縺吶ｋ縲・
.DESCRIPTION
    謖吝虚繝代Λ繝｡繝ｼ繧ｿ縺ｯ CLI縲…onfig 繝輔ぃ繧､繝ｫ縲√ｂ縺励￥縺ｯ繧ｹ繧ｯ繝ｪ繝励ヨ譌｢螳壼､縺ｧ
    謖・ｮ壼庄閭ｽ縲ょ━蜈磯・ｽ阪・ config/README.md 繧貞盾辣ｧ縲・    螳溯｡後＃縺ｨ縺ｮ蟇ｾ雎｡ (-VolumeId / -InstanceId / -NamePrefix) 縺ｯ CLI 蟆ら畑縲・
    隱崎ｨｼ: 繝・ヵ繧ｩ繝ｫ繝・AWS credential chain・育腸蠅・､画焚 / 繝励Ο繝輔ぃ繧､繝ｫ / IAM 繝ｭ繝ｼ繝ｫ・峨・
    繝輔Ο繝ｼ・・hell-specification.md 貅匁侠・・
      1. 蠑墓焚繝舌Μ繝・・繧ｷ繝ｧ繝ｳ
      2. 迺ｰ蠅・そ繝・ヨ繧｢繝・・ (繝ｭ繧ｬ繝ｼ / config)
      3. 繝励Ξ繝√ぉ繝・け            (繝｢繧ｸ繝･繝ｼ繝ｫ / 蟇ｾ雎｡ / 蜀ｪ遲画ｧ)
      4. 繝｡繧､繝ｳ蜃ｦ逅・             (繧ｹ繝翫ャ繝励す繝ｧ繝・ヨ菴懈・ / 蠕・ｩ・/ pruning)
      5. 蠕悟・逅・                 (譛邨・status 繝ｭ繧ｰ)
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

# --- 繝輔ぉ繝ｼ繧ｺ 2: 蜈ｱ騾壹Ο繧ｬ繝ｼ -------------------------------------------------
$libPath = $null
foreach ($c in @(
    [IO.Path]::Combine($PSScriptRoot, '..', 'lib', 'Logging.psm1'),
    [IO.Path]::Combine($PSScriptRoot, '..', 'lib', 'windows', 'Logging.psm1')
)) { if (Test-Path $c) { $libPath = $c; break } }
if (-not $libPath) { throw 'Logging.psm1 not found' }
Import-Module (Resolve-Path $libPath).Path -Force

# --- 繝輔ぉ繝ｼ繧ｺ 2: 險ｭ螳壹ヵ繧｡繧､繝ｫ隱ｭ霎ｼ縺ｿ縲∵悴謖・ｮ壹ヱ繝ｩ繝｡繝ｼ繧ｿ縺ｸ蜿肴丐 ---------------
$configModulePath = $null
foreach ($c in @(
    [IO.Path]::Combine($PSScriptRoot, '..', 'lib', 'Config.psm1'),
    [IO.Path]::Combine($PSScriptRoot, '..', 'lib', 'windows', 'Config.psm1')
)) { if (Test-Path $c) { $configModulePath = $c; break } }
if (-not $configModulePath) { throw 'Config.psm1 not found' }
Import-Module (Resolve-Path $configModulePath).Path -Force
$cfg = Get-OpsConfig -Name 'backup_ebs_snapshot'
$cfgEnv = if ($env:OPS_ENV) { $env:OPS_ENV } else { 'default' }
$logFile  = if ($cfg.ContainsKey('LogFile'))  { [string]$cfg['LogFile'] }  else { '' }
$logLevel = if ($cfg.ContainsKey('LogLevel')) { [string]$cfg['LogLevel'] } else { 'INFO' }
Set-OpsLogConfig -LogFile $logFile -LogLevel $logLevel
if (-not $PSBoundParameters.ContainsKey('Region')             -and $cfg.ContainsKey('Region'))             { $Region             = [string]$cfg['Region'] }
if (-not $PSBoundParameters.ContainsKey('RetentionDays')      -and $cfg.ContainsKey('RetentionDays'))      { $RetentionDays      = [int]$cfg['RetentionDays'] }
if (-not $PSBoundParameters.ContainsKey('MinIntervalMinutes') -and $cfg.ContainsKey('MinIntervalMinutes')) { $MinIntervalMinutes = [int]$cfg['MinIntervalMinutes'] }
if (-not $PSBoundParameters.ContainsKey('Wait')               -and $cfg.ContainsKey('Wait')) {
    if ([System.Convert]::ToBoolean($cfg['Wait'])) { $Wait = $true }
}

$exitCode = 0
$status = 'unknown'
$created = @()

try {
    do {
        Write-OpsLog -Level INFO -Message "Config loaded: env=$cfgEnv keys=$($cfg.Count)"
        Write-OpsLog -Level INFO -Message "Args validated: paramSet=$($PSCmdlet.ParameterSetName) namePrefix=$NamePrefix region=$Region retentionDays=$RetentionDays minIntervalMin=$MinIntervalMinutes"

        # --- 繝輔ぉ繝ｼ繧ｺ 3: 繝励Ξ繝√ぉ繝・け ---------------------------------------------
        Write-OpsLog -Level INFO -Message 'Pre-check start'

        if (-not (Get-Module -ListAvailable AWS.Tools.EC2)) {
            Write-OpsLog -Level ERROR -Message 'AWS.Tools.EC2 module is not installed; install with: Install-Module AWS.Tools.EC2 -Scope CurrentUser'
            $exitCode = 10; $status = 'failed'; break
        }
        Import-Module AWS.Tools.EC2

        $aws = @{}
        if ($Region) { $aws.Region = $Region }

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

        # --- 繝輔ぉ繝ｼ繧ｺ 4: 繝｡繧､繝ｳ蜃ｦ逅・---------------------------------------
        Write-OpsLog -Level INFO -Message 'Main start'

        $ts = Get-OpsJstStamp

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
    Write-OpsLog -Level INFO -Message "Script end: status=$status exitCode=$exitCode created=$($created.Count)"
}

exit $exitCode
