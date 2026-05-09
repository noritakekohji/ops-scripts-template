#Requires -Version 7
<#
.SYNOPSIS
    Rotate log files based on size or age, with optional gzip compression.

.DESCRIPTION
    Targets are resolved from -Path (single file or directory) and / or
    -PathList (text file listing multiple paths, one per line).

    For each resolved file, rotates when:
      - size >= MaxSizeMB    (if specified), OR
      - mtime older than MaxAgeDays (if specified).
    At least one trigger must be specified.

    Rotated files are renamed with a UTC timestamp suffix:
        app.log -> app.log.20260509-031405
    Optionally gzipped to .gz. Old rotated files exceeding -RetentionCount
    are deleted (oldest first).

    Flow (per shell-specification.md):
      1. Argument validation
      2. Environment setup
      3. Pre-check               (resolve paths; idempotency = no targets)
      4. Main processing         (rotate / compress / prune)
      5. Post-processing         (final status log)

.PARAMETER Path
    Single log file path OR a directory containing log files.

.PARAMETER PathList
    Text file with one target path per line. Lines starting with "#" and
    blank lines are ignored. Whitespace is trimmed.

.PARAMETER Pattern
    Glob pattern when a target is a directory. Default: *.log

.PARAMETER MaxSizeMB
    Rotate when size >= this many MB. 0 disables.

.PARAMETER MaxAgeDays
    Rotate when mtime older than this many days. 0 disables.

.PARAMETER Compress
    Gzip the rotated file.

.PARAMETER RetentionCount
    Keep at most this many rotated files per source. 0 disables.

.PARAMETER CopyTruncate
    Use copy+truncate instead of rename. Safer for files held open.

.EXAMPLE
    .\Rotate-Log.ps1 -Path C:\logs\app.log -MaxSizeMB 100 -Compress -RetentionCount 7

.EXAMPLE
    .\Rotate-Log.ps1 -PathList C:\ops\logs.txt -MaxAgeDays 1 -Compress -RetentionCount 30
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

# --- Phase 2: shared logger -------------------------------------------------
$libPath = Join-Path $PSScriptRoot '..' '..' 'lib' 'powershell' 'Logging.psm1'
if (-not (Test-Path $libPath)) {
    throw "Logging module not found at $libPath"
}
Import-Module (Resolve-Path $libPath).Path -Force

$exitCode = 0
$status = 'unknown'
$rotated = 0
$skipped = 0

try {
    do {
        # --- Phase 1b: cross-validation ---
        if ($MaxSizeMB -le 0 -and $MaxAgeDays -le 0) {
            Write-OpsLog -Level ERROR -Message 'At least one of -MaxSizeMB or -MaxAgeDays must be > 0'
            $exitCode = 1; $status = 'failed'; break
        }

        Write-OpsLog -Level INFO -Message "Args validated: path='$Path' pathList='$PathList' pattern=$Pattern maxSizeMB=$MaxSizeMB maxAgeDays=$MaxAgeDays compress=$Compress retention=$RetentionCount copyTruncate=$CopyTruncate"

        # --- Phase 3: pre-check (collect targets) ---------------------------
        Write-OpsLog -Level INFO -Message 'Pre-check start'

        $targetPaths = [System.Collections.Generic.List[string]]::new()
        if ($Path) { $targetPaths.Add($Path) }

        if ($PathList) {
            if (-not (Test-Path -LiteralPath $PathList -PathType Leaf)) {
                Write-OpsLog -Level ERROR -Message "Path list file not found: pathList=$PathList"
                $exitCode = 2; $status = 'failed'; break
            }
            $listLines = Get-Content -LiteralPath $PathList |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ -and -not $_.StartsWith('#') }
            foreach ($l in $listLines) { $targetPaths.Add($l) }
            Write-OpsLog -Level INFO -Message "Loaded paths from list: pathList=$PathList count=$($listLines.Count)"
        }

        if ($targetPaths.Count -eq 0) {
            Write-OpsLog -Level ERROR -Message 'Specify -Path or -PathList (or both)'
            $exitCode = 1; $status = 'failed'; break
        }

        $files = @()
        foreach ($p in $targetPaths) {
            if (-not (Test-Path -LiteralPath $p)) {
                Write-OpsLog -Level WARN -Message "Path not found, skipping: path=$p"
                continue
            }
            if (Test-Path -LiteralPath $p -PathType Container) {
                $matched = @(Get-ChildItem -LiteralPath $p -Filter $Pattern -File)
                $files += $matched
                Write-OpsLog -Level DEBUG -Message "Resolved directory: path=$p matched=$($matched.Count)"
            }
            else {
                $files += @(Get-Item -LiteralPath $p)
            }
        }
        $files = @($files | Sort-Object FullName -Unique)

        # 3-d: idempotency — no targets means nothing to do
        if ($files.Count -eq 0) {
            Write-OpsLog -Level INFO -Message 'Skipped (idempotent): reason=no_matching_files'
            $exitCode = 0; $status = 'skipped'; break
        }

        Write-OpsLog -Level INFO -Message "Pre-check passed: matched=$($files.Count)"

        # --- Phase 4: main processing ---------------------------------------
        Write-OpsLog -Level INFO -Message 'Main start'

        $cutoff = if ($MaxAgeDays -gt 0) { (Get-Date).AddDays(-$MaxAgeDays) } else { $null }

        foreach ($f in $files) {
            if ($f.Length -eq 0) {
                Write-OpsLog -Level DEBUG -Message "Skip empty: file=$($f.FullName)"
                $skipped++
                continue
            }

            $needRotate = $false
            $reason = ''
            if ($MaxSizeMB -gt 0 -and $f.Length -ge $MaxSizeMB * 1MB) {
                $needRotate = $true
                $reason = "size=$([math]::Round($f.Length / 1MB, 2))MB>=$MaxSizeMB"
            }
            if (-not $needRotate -and $cutoff -and $f.LastWriteTime -lt $cutoff) {
                $needRotate = $true
                $reason = "mtime=$($f.LastWriteTime.ToString('yyyy-MM-dd_HH:mm:ss'))_older_than_${MaxAgeDays}d"
            }

            if (-not $needRotate) {
                Write-OpsLog -Level DEBUG -Message "Skip: file=$($f.FullName) size=$($f.Length) mtime=$($f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))"
                $skipped++
                continue
            }

            $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
            $rotatedPath = "$($f.FullName).$stamp"

            if (-not $PSCmdlet.ShouldProcess($f.FullName, "Rotate to $rotatedPath ($reason)")) {
                continue
            }

            try {
                if ($CopyTruncate) {
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

            if ($Compress) {
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

        # Retention pruning
        if ($RetentionCount -gt 0) {
            foreach ($f in $files) {
                $dir = Split-Path -Parent $f.FullName
                $name = Split-Path -Leaf $f.FullName
                $regex = "^$([regex]::Escape($name))\.[0-9]{8}-[0-9]{6}(\.gz)?$"
                $peers = @(
                    Get-ChildItem -LiteralPath $dir -File |
                        Where-Object { $_.Name -match $regex } |
                        Sort-Object Name -Descending
                )
                if ($peers.Count -gt $RetentionCount) {
                    $toDelete = $peers | Select-Object -Skip $RetentionCount
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
    Write-OpsLog -Level INFO -Message "Script end: status=$status exitCode=$exitCode rotated=$rotated skipped=$skipped"
}

exit $exitCode
