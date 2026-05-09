#Requires -Version 7
<#
.SYNOPSIS
    ログファイルをサイズまたは経過時間でローテートする（任意で gzip 圧縮）。

.DESCRIPTION
    対象は -Path（単一ファイル or ディレクトリ）および/または
    -PathList（リストファイル）から解決。リスト各行で対象ごとの
    上書きを `Key=Value` 形式で指定可能:

        /var/log/myapp/app.log
        /var/log/critical/audit.log MaxSizeMB=200 RetentionCount=90
        /opt/tomcat/logs/catalina.out MaxSizeMB=500 CopyTruncate=true RetentionCount=14
        /var/log/nginx Pattern=access*.log MaxAgeDays=1 RetentionCount=30

    受け付けるキー: Pattern, MaxSizeMB, MaxAgeDays, Compress,
    RetentionCount, CopyTruncate。解決順位: 行内 > CLI > config >
    既定値。不明なキー・不正な値は WARN を出してそのキーだけスキップ
    （エントリ自体は継承値で実行される）。

    ローテート後のファイル名: <name>.YYYYMMDD-HHMMSS [.gz]（JST）。

    フロー（shell-specification.md 準拠）:
      1. 引数バリデーション
      2. 環境セットアップ (ロガー / config)
      3. プレチェック            (対象解決、冪等 = 対象なし)
      4. メイン処理              (対象ごとに rotate / compress / prune)
      5. 後処理                  (最終 status ログ)
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

# --- フェーズ 2: 共通ロガー -------------------------------------------------
$libPath = Join-Path $PSScriptRoot '..' '..' '..' 'lib' 'powershell' 'Logging.psm1'
if (-not (Test-Path $libPath)) { throw "Logging module not found at $libPath" }
Import-Module (Resolve-Path $libPath).Path -Force

# --- フェーズ 2: 設定ファイル読込み、未指定パラメータへ反映 ---------------
$configModulePath = Join-Path $PSScriptRoot '..' '..' '..' 'lib' 'powershell' 'Config.psm1'
Import-Module (Resolve-Path $configModulePath).Path -Force
$cfg = Get-OpsConfig -Name 'rotate_log'
$cfgEnv = if ($env:OPS_ENV) { $env:OPS_ENV } else { 'common' }
if (-not $PSBoundParameters.ContainsKey('Pattern')        -and $cfg.ContainsKey('Pattern'))        { $Pattern        = [string]$cfg['Pattern'] }
if (-not $PSBoundParameters.ContainsKey('MaxSizeMB')      -and $cfg.ContainsKey('MaxSizeMB'))      { $MaxSizeMB      = [int]$cfg['MaxSizeMB'] }
if (-not $PSBoundParameters.ContainsKey('MaxAgeDays')     -and $cfg.ContainsKey('MaxAgeDays'))     { $MaxAgeDays     = [int]$cfg['MaxAgeDays'] }
if (-not $PSBoundParameters.ContainsKey('RetentionCount') -and $cfg.ContainsKey('RetentionCount')) { $RetentionCount = [int]$cfg['RetentionCount'] }
if (-not $PSBoundParameters.ContainsKey('Compress')       -and $cfg.ContainsKey('Compress')) {
    if ([System.Convert]::ToBoolean($cfg['Compress'])) { $Compress = [switch]::Present }
}
if (-not $PSBoundParameters.ContainsKey('CopyTruncate')   -and $cfg.ContainsKey('CopyTruncate')) {
    if ([System.Convert]::ToBoolean($cfg['CopyTruncate'])) { $CopyTruncate = [switch]::Present }
}
# CLI で -PathList 未指定なら config の PathList を採用。相対パスは repo root 起点で絶対化。
if (-not $PSBoundParameters.ContainsKey('PathList') -and $cfg.ContainsKey('PathList')) {
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

        # --- フェーズ 3: プレチェック（対象収集） ---------------------------
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
            $listLines = Get-Content -LiteralPath $PathList |
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

        # --- フェーズ 4: メイン処理（対象ごと） --------------------------
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

            # 対象ごとの世代保持（古いものから削除）
            if ($t.RetentionCount -gt 0) {
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
