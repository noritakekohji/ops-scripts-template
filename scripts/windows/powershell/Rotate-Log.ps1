#Requires -Version 5.1
<#
.SYNOPSIS
    繝ｭ繧ｰ繝輔ぃ繧､繝ｫ繧偵し繧､繧ｺ縺ｾ縺溘・邨碁℃譎る俣縺ｧ繝ｭ繝ｼ繝・・繝医☆繧具ｼ井ｻｻ諢上〒 gzip 蝨ｧ邵ｮ・峨・
.DESCRIPTION
    蟇ｾ雎｡縺ｯ -Path・亥腰荳繝輔ぃ繧､繝ｫ or 繝・ぅ繝ｬ繧ｯ繝医Μ・峨♀繧医・/縺ｾ縺溘・
    -PathList・医Μ繧ｹ繝医ヵ繧｡繧､繝ｫ・峨°繧芽ｧ｣豎ｺ縲ゅΜ繧ｹ繝亥推陦後〒蟇ｾ雎｡縺斐→縺ｮ
    荳頑嶌縺阪ｒ `Key=Value` 蠖｢蠑上〒謖・ｮ壼庄閭ｽ:

        /var/log/myapp/app.log
        /var/log/critical/audit.log MaxSizeMB=200 RetentionCount=90
        /opt/tomcat/logs/catalina.out MaxSizeMB=500 CopyTruncate=true RetentionCount=14
        /var/log/nginx Pattern=access*.log MaxAgeDays=1 RetentionCount=30

    蜿励￠莉倥￠繧九く繝ｼ: Pattern, MaxSizeMB, MaxAgeDays, Compress,
    RetentionCount, CopyTruncate縲りｧ｣豎ｺ鬆・ｽ・ 陦悟・ > CLI > config >
    譌｢螳壼､縲ゆｸ肴・縺ｪ繧ｭ繝ｼ繝ｻ荳肴ｭ｣縺ｪ蛟､縺ｯ WARN 繧貞・縺励※縺昴・繧ｭ繝ｼ縺縺代せ繧ｭ繝・・
    ・医お繝ｳ繝医Μ閾ｪ菴薙・邯呎価蛟､縺ｧ螳溯｡後＆繧後ｋ・峨・
    繝ｭ繝ｼ繝・・繝亥ｾ後・繝輔ぃ繧､繝ｫ蜷・ <name>.YYYYMMDD-HHMMSS [.gz]・・ST・峨・
    繝輔Ο繝ｼ・・hell-specification.md 貅匁侠・・
      1. 蠑墓焚繝舌Μ繝・・繧ｷ繝ｧ繝ｳ
      2. 迺ｰ蠅・そ繝・ヨ繧｢繝・・ (繝ｭ繧ｬ繝ｼ / config)
      3. 繝励Ξ繝√ぉ繝・け            (蟇ｾ雎｡隗｣豎ｺ縲∝・遲・= 蟇ｾ雎｡縺ｪ縺・
      4. 繝｡繧､繝ｳ蜃ｦ逅・             (蟇ｾ雎｡縺斐→縺ｫ rotate / compress / prune)
      5. 蠕悟・逅・                 (譛邨・status 繝ｭ繧ｰ)
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Path,
    [string]$PathList,
    [string]$Pattern = '*.log',
    [ValidateRange(0, 1048576)][int]$MaxSizeMB = 0,
    [ValidateRange(0, 3650)][int]$MaxAgeDays = 0,
    [switch]$Compress,
    [ValidateRange(0, 10000)][int]$RetentionCount = 0,
    [switch]$CopyTruncate
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- 繝輔ぉ繝ｼ繧ｺ 2: 蜈ｱ騾壹Ο繧ｬ繝ｼ -------------------------------------------------
$libPath = [IO.Path]::Combine($PSScriptRoot, '..', '..', '..', 'lib', 'powershell', 'Logging.psm1')
if (-not (Test-Path $libPath)) { throw "Logging module not found at $libPath" }
Import-Module (Resolve-Path $libPath).Path -Force

# --- 繝輔ぉ繝ｼ繧ｺ 2: 險ｭ螳壹ヵ繧｡繧､繝ｫ隱ｭ霎ｼ縺ｿ縲∵悴謖・ｮ壹ヱ繝ｩ繝｡繝ｼ繧ｿ縺ｸ蜿肴丐 ---------------
$configModulePath = [IO.Path]::Combine($PSScriptRoot, '..', '..', '..', 'lib', 'powershell', 'Config.psm1')
Import-Module (Resolve-Path $configModulePath).Path -Force
$cfg = Get-OpsConfig -Name 'rotate_log'
$cfgEnv = if ($env:OPS_ENV) { $env:OPS_ENV } else { 'default' }
if (-not $PSBoundParameters.ContainsKey('Pattern')        -and $cfg.ContainsKey('Pattern'))        { $Pattern        = [string]$cfg['Pattern'] }
if (-not $PSBoundParameters.ContainsKey('MaxSizeMB')      -and $cfg.ContainsKey('MaxSizeMB'))      { $MaxSizeMB      = [int]$cfg['MaxSizeMB'] }
if (-not $PSBoundParameters.ContainsKey('MaxAgeDays')     -and $cfg.ContainsKey('MaxAgeDays'))     { $MaxAgeDays     = [int]$cfg['MaxAgeDays'] }
if (-not $PSBoundParameters.ContainsKey('RetentionCount') -and $cfg.ContainsKey('RetentionCount')) { $RetentionCount = [int]$cfg['RetentionCount'] }
if (-not $PSBoundParameters.ContainsKey('Compress')       -and $cfg.ContainsKey('Compress')) {
    if ([System.Convert]::ToBoolean($cfg['Compress'])) { $Compress = $true }
}
if (-not $PSBoundParameters.ContainsKey('CopyTruncate')   -and $cfg.ContainsKey('CopyTruncate')) {
    if ([System.Convert]::ToBoolean($cfg['CopyTruncate'])) { $CopyTruncate = $true }
}
# CLI 縺ｧ -PathList 譛ｪ謖・ｮ壹↑繧・config 縺ｮ PathList 繧呈治逕ｨ縲ら嶌蟇ｾ繝代せ縺ｯ repo root 襍ｷ轤ｹ縺ｧ邨ｶ蟇ｾ蛹悶・if (-not $PSBoundParameters.ContainsKey('PathList') -and $cfg.ContainsKey('PathList')) {
    $PathList = [string]$cfg['PathList']
    if ($PathList -and -not [System.IO.Path]::IsPathRooted($PathList)) {
        $PathList = Join-Path (Get-OpsRepoRoot) $PathList
    }
}

# Defaults inherited by each list entry
$defaults = @{
    Pattern        = $Pattern
    MaxSizeMB      = $MaxSizeMB
    MaxAgeDays     = $MaxAgeDays
    Compress       = [bool]$Compress
    RetentionCount = $RetentionCount
    CopyTruncate   = [bool]$CopyTruncate
}

function ConvertFrom-OpsListLine {
    param([string]$Line, [hashtable]$Defaults)
    # Trim and split on whitespace; first token = path, rest = Key=Value tokens
    $trimmed = $Line.Trim()
    $tokens = $trimmed -split '\s+'
    $entry = @{
        Path           = $tokens[0]
        Pattern        = $Defaults.Pattern
        MaxSizeMB      = $Defaults.MaxSizeMB
        MaxAgeDays     = $Defaults.MaxAgeDays
        Compress       = [bool]$Defaults.Compress
        RetentionCount = $Defaults.RetentionCount
        CopyTruncate   = [bool]$Defaults.CopyTruncate
    }
    for ($i = 1; $i -lt $tokens.Count; $i++) {
        $tok = $tokens[$i]
        $eq = $tok.IndexOf('=')
        if ($eq -lt 1) {
            Write-OpsLog -Level WARN -Message "Invalid token in list line: line='$trimmed' token='$tok'"
            continue
        }
        $key = $tok.Substring(0, $eq)
        $val = $tok.Substring($eq + 1)
        if ($val -match '^"(.*)"$' -or $val -match "^'(.*)'$") { $val = $Matches[1] }
        switch -CaseSensitive ($key) {
            'Pattern'        { $entry.Pattern = $val }
            'MaxSizeMB'      {
                if ($val -match '^\d+$' -and [int]$val -le 1048576) { $entry.MaxSizeMB = [int]$val }
                else { Write-OpsLog -Level WARN -Message "Invalid MaxSizeMB: line='$trimmed' value='$val'" }
            }
            'MaxAgeDays'     {
                if ($val -match '^\d+$' -and [int]$val -le 3650) { $entry.MaxAgeDays = [int]$val }
                else { Write-OpsLog -Level WARN -Message "Invalid MaxAgeDays: line='$trimmed' value='$val'" }
            }
            'RetentionCount' {
                if ($val -match '^\d+$' -and [int]$val -le 10000) { $entry.RetentionCount = [int]$val }
                else { Write-OpsLog -Level WARN -Message "Invalid RetentionCount: line='$trimmed' value='$val'" }
            }
            'Compress' {
                try { $entry.Compress = [System.Convert]::ToBoolean($val) }
                catch { Write-OpsLog -Level WARN -Message "Invalid Compress: line='$trimmed' value='$val'" }
            }
            'CopyTruncate' {
                try { $entry.CopyTruncate = [System.Convert]::ToBoolean($val) }
                catch { Write-OpsLog -Level WARN -Message "Invalid CopyTruncate: line='$trimmed' value='$val'" }
            }
            default {
                Write-OpsLog -Level WARN -Message "Unknown key in list line: line='$trimmed' key='$key'"
            }
        }
    }
    return $entry
}

$exitCode = 0
$status = 'unknown'
$rotated = 0
$skipped = 0

try {
    do {
        Write-OpsLog -Level INFO -Message "Config loaded: env=$cfgEnv keys=$($cfg.Count)"
        Write-OpsLog -Level INFO -Message "Args validated: path='$Path' pathList='$PathList' pattern=$Pattern maxSizeMB=$MaxSizeMB maxAgeDays=$MaxAgeDays compress=$Compress retention=$RetentionCount copyTruncate=$CopyTruncate"

        # --- 繝輔ぉ繝ｼ繧ｺ 3: 繝励Ξ繝√ぉ繝・け・亥ｯｾ雎｡蜿朱寔・・---------------------------
        Write-OpsLog -Level INFO -Message 'Pre-check start'

        $targets = [System.Collections.Generic.List[hashtable]]::new()

        if ($Path) {
            $targets.Add((ConvertFrom-OpsListLine -Line $Path -Defaults $defaults))
        }

        if ($PathList) {
            if (-not (Test-Path -LiteralPath $PathList -PathType Leaf)) {
                Write-OpsLog -Level ERROR -Message "Path list file not found: pathList=$PathList"
                $exitCode = 2; $status = 'failed'; break
            }
            $listLines = Get-Content -LiteralPath $PathList -Encoding UTF8 |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ -and -not $_.StartsWith('#') }
            foreach ($l in $listLines) { $targets.Add((ConvertFrom-OpsListLine -Line $l -Defaults $defaults)) }
            Write-OpsLog -Level INFO -Message "Loaded entries from list: pathList=$PathList count=$($listLines.Count)"
        }

        if ($targets.Count -eq 0) {
            Write-OpsLog -Level ERROR -Message 'Specify -Path or -PathList (or both)'
            $exitCode = 1; $status = 'failed'; break
        }

        Write-OpsLog -Level INFO -Message "Pre-check passed: targetCount=$($targets.Count)"

        # --- 繝輔ぉ繝ｼ繧ｺ 4: 繝｡繧､繝ｳ蜃ｦ逅・ｼ亥ｯｾ雎｡縺斐→・・--------------------------
        Write-OpsLog -Level INFO -Message 'Main start'

        foreach ($t in $targets) {
            if (-not (Test-Path -LiteralPath $t.Path)) {
                Write-OpsLog -Level WARN -Message "Path not found, skipping: path=$($t.Path)"
                continue
            }
            if ($t.MaxSizeMB -le 0 -and $t.MaxAgeDays -le 0) {
                Write-OpsLog -Level WARN -Message "No trigger for target (MaxSizeMB and MaxAgeDays both 0), skipping: path=$($t.Path)"
                continue
            }

            $files = @()
            if (Test-Path -LiteralPath $t.Path -PathType Container) {
                $files = @(Get-ChildItem -LiteralPath $t.Path -Filter $t.Pattern -File)
                Write-OpsLog -Level DEBUG -Message "Resolved directory: path=$($t.Path) pattern=$($t.Pattern) matched=$($files.Count)"
            }
            else {
                $files = @(Get-Item -LiteralPath $t.Path)
            }
            if ($files.Count -eq 0) { continue }

            $cutoff = if ($t.MaxAgeDays -gt 0) { (Get-Date).AddDays(-$t.MaxAgeDays) } else { $null }

            foreach ($f in $files) {
                if ($f.Length -eq 0) {
                    Write-OpsLog -Level DEBUG -Message "Skip empty: file=$($f.FullName)"
                    $skipped++
                    continue
                }

                $needRotate = $false
                $reason = ''
                if ($t.MaxSizeMB -gt 0 -and $f.Length -ge $t.MaxSizeMB * 1MB) {
                    $needRotate = $true
                    $reason = "size=$([math]::Round($f.Length / 1MB, 2))MB>=$($t.MaxSizeMB)"
                }
                if (-not $needRotate -and $cutoff -and $f.LastWriteTime -lt $cutoff) {
                    $needRotate = $true
                    $reason = "mtime=$($f.LastWriteTime.ToString('yyyy-MM-dd_HH:mm:ss'))_older_than_$($t.MaxAgeDays)d"
                }
                if (-not $needRotate) {
                    Write-OpsLog -Level DEBUG -Message "Skip: file=$($f.FullName) size=$($f.Length)"
                    $skipped++
                    continue
                }

                $stamp = Get-OpsJstStamp
                $rotatedPath = "$($f.FullName).$stamp"
                if (-not $PSCmdlet.ShouldProcess($f.FullName, "Rotate to $rotatedPath ($reason)")) { continue }

                try {
                    if ($t.CopyTruncate) {
                        Copy-Item -LiteralPath $f.FullName -Destination $rotatedPath -Force
                        [System.IO.File]::Create($f.FullName).Close()
                        Write-OpsLog -Level INFO -Message "Rotated (copytruncate): from=$($f.FullName) to=$rotatedPath reason=$reason"
                    }
                    else {
                        Move-Item -LiteralPath $f.FullName -Destination $rotatedPath -Force
                        New-Item -ItemType File -Path $f.FullName -Force | Out-Null
                        Write-OpsLog -Level INFO -Message "Rotated (rename): from=$($f.FullName) to=$rotatedPath reason=$reason"
                    }
                    $rotated++
                }
                catch {
                    Write-OpsLog -Level ERROR -Message "Rotation failed: file=$($f.FullName) error=$($_.Exception.Message)"
                    continue
                }

                if ($t.Compress) {
                    $gz = "$rotatedPath.gz"
                    try {
                        $in = [System.IO.File]::OpenRead($rotatedPath)
                        try {
                            $out = [System.IO.File]::Create($gz)
                            try {
                                $gzs = New-Object System.IO.Compression.GZipStream($out, [System.IO.Compression.CompressionLevel]::Optimal)
                                try { $in.CopyTo($gzs) } finally { $gzs.Dispose() }
                            }
                            finally { $out.Dispose() }
                        }
                        finally { $in.Dispose() }
                        Remove-Item -LiteralPath $rotatedPath -Force
                        Write-OpsLog -Level INFO -Message "Compressed: file=$gz"
                    }
                    catch {
                        Write-OpsLog -Level WARN -Message "Compression failed: file=$rotatedPath error=$($_.Exception.Message)"
                    }
                }
            }

            # 蟇ｾ雎｡縺斐→縺ｮ荳紋ｻ｣菫晄戟・亥商縺・ｂ縺ｮ縺九ｉ蜑企勁・・            if ($t.RetentionCount -gt 0) {
                foreach ($f in $files) {
                    $dir = Split-Path -Parent $f.FullName
                    $name = Split-Path -Leaf $f.FullName
                    $regex = "^$([regex]::Escape($name))\.[0-9]{8}-[0-9]{6}(\.gz)?$"
                    $peers = @(
                        Get-ChildItem -LiteralPath $dir -File |
                            Where-Object { $_.Name -match $regex } |
                            Sort-Object Name -Descending
                    )
                    if ($peers.Count -gt $t.RetentionCount) {
                        $toDelete = $peers | Select-Object -Skip $t.RetentionCount
                        foreach ($d in $toDelete) {
                            if ($PSCmdlet.ShouldProcess($d.FullName, 'Delete (retention)')) {
                                try {
                                    Remove-Item -LiteralPath $d.FullName -Force
                                    Write-OpsLog -Level INFO -Message "Pruned: file=$($d.FullName)"
                                }
                                catch {
                                    Write-OpsLog -Level WARN -Message "Prune failed: file=$($d.FullName) error=$($_.Exception.Message)"
                                }
                            }
                        }
                    }
                }
            }
        }

        if ($rotated -eq 0 -and $skipped -gt 0) {
            Write-OpsLog -Level INFO -Message 'Skipped (idempotent): reason=no_files_required_rotation'
            $status = 'skipped'
        }
        else {
            Write-OpsLog -Level INFO -Message 'Main complete'
            $status = 'success'
        }
    } while ($false)
}
catch {
    Write-OpsLog -Level ERROR -Message "Operation failed: error=$($_.Exception.Message)"
    if ($exitCode -eq 0) { $exitCode = 4 }
    $status = 'failed'
}
finally {
    Write-OpsLog -Level INFO -Message "Script end: status=$status exitCode=$exitCode rotated=$rotated skipped=$skipped"
}

exit $exitCode
