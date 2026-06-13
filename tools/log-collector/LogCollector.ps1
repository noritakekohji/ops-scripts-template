#Requires -Version 5.1
<#
.SYNOPSIS
    Evidence Log Collector: incident response log collection tool for Windows.
.DESCRIPTION
    Collects log files matching glob patterns within a time window for incident
    response evidence packaging. Files are filtered by mtime, capped by total
    size, and packaged into a ZIP archive with manifest and OS information.

    Features:
      - Preset-based target selection via collect_targets.conf
      - Time window filtering by mtime (-Since duration or -From/-To range)
      - Total size cap with newest-first prioritization
      - SHA-256 manifest for integrity verification
      - OS info snapshot (systeminfo + disk usage)
      - Permission-denied files are warned and skipped

    Usage:
      LogCollector.ps1 -Target tomcat,os
      LogCollector.ps1 -Target nginx -Since 48h
      LogCollector.ps1 -Target tomcat,postgresql -From "2026-06-01 00:00"
      LogCollector.ps1 -Target os -OutputDir C:\evidence -MaxSizeMB 1000

    Exit codes:
      0  = Success
      1  = Argument error (bad params, missing config, unknown preset)
      2  = No files collected (all skipped or none matched)
      10 = Prerequisite missing
.EXAMPLE
    .\LogCollector.ps1 -Target tomcat,os
.EXAMPLE
    .\LogCollector.ps1 -Target nginx -Since 48h -OutputDir C:\evidence
.EXAMPLE
    .\LogCollector.ps1 -Target os -From "2026-06-01 00:00" -To "2026-06-02 00:00"
#>
[CmdletBinding()]
param(
    [string[]]$Target    = @(),
    [string]$ConfigFile  = '',
    [string]$Since       = '24h',
    [string]$From        = '',
    [string]$To          = '',
    [string]$OutputDir   = '.',
    [int]$MaxSizeMB      = 500
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptPath = $MyInvocation.MyCommand.Path
$ScriptDir  = Split-Path $ScriptPath -Parent

# ============================================================================
# Phase 1: Logging helpers
# ============================================================================

function Write-Log([string]$Level, [string]$Msg) {
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $prefix = "[$ts] [$Level] (LogCollector:$PID)"
    switch ($Level) {
        'ERROR' { Write-Host "$prefix $Msg" -ForegroundColor Red }
        'WARN'  { Write-Host "$prefix $Msg" -ForegroundColor Yellow }
        default { Write-Host "$prefix $Msg" }
    }
}

# ============================================================================
# Phase 2: Config and parameter resolution
# ============================================================================

# --- Config parser -----------------------------------------------------------

function Read-CollectConfig([string]$Path) {
    <#
    .SYNOPSIS
        Parse INI-like collect_targets.conf into a hashtable of presets.
    .OUTPUTS
        Hashtable: @{ presetName = @{ paths = @('glob1','glob2'); max_file_size_mb = 100 } }
    #>
    if (-not (Test-Path $Path)) {
        Write-Log 'ERROR' "Config file not found: $Path"
        exit 1
    }

    $config = @{}
    $currentSection = $null
    $lineNum = 0

    foreach ($rawLine in @(Get-Content -Path $Path -Encoding UTF8)) {
        $lineNum++
        $line = $rawLine.Trim()

        # Skip empty lines and comments
        if ($line -eq '' -or $line.StartsWith('#')) { continue }

        # Section header: [preset_name]
        if ($line -match '^\[([a-zA-Z0-9_-]+)\]\s*$') {
            $currentSection = $Matches[1]
            if (-not $config.ContainsKey($currentSection)) {
                $config[$currentSection] = @{
                    paths            = @()
                    max_file_size_mb = 100
                }
            }
            continue
        }

        # Key = Value pair
        if ($line -match '^([a-zA-Z_]+)\s*=\s*(.+)$') {
            $key   = $Matches[1].Trim()
            $value = $Matches[2].Trim()

            if ($null -eq $currentSection) {
                Write-Log 'WARN' "config line $lineNum outside section, skipped: $line"
                continue
            }

            switch ($key) {
                'path' {
                    $config[$currentSection].paths += $value
                }
                'max_file_size_mb' {
                    $parsed = 0
                    if ([int]::TryParse($value, [ref]$parsed)) {
                        $config[$currentSection].max_file_size_mb = $parsed
                    } else {
                        Write-Log 'WARN' "Invalid max_file_size_mb at line ${lineNum}: $value"
                    }
                }
                default {
                    Write-Log 'WARN' "Unknown config key at line ${lineNum}: $key"
                }
            }
            continue
        }

        Write-Log 'WARN' "Unparseable config line ${lineNum}: $line"
    }

    return $config
}

# --- Time window parser ------------------------------------------------------

function Get-TimeWindow {
    <#
    .SYNOPSIS
        Compute the from/to datetime range based on -Since, -From, -To params.
    .OUTPUTS
        Hashtable: @{ from = [datetime]; to = [datetime] }
    #>
    param(
        [string]$SinceStr,
        [string]$FromStr,
        [string]$ToStr
    )

    $now = Get-Date
    $result = @{ from = $null; to = $now }

    # -To overrides default "now"
    if ($ToStr -ne '') {
        try {
            $result.to = [datetime]::Parse($ToStr)
        } catch {
            Write-Log 'ERROR' "Cannot parse -To datetime: $ToStr"
            exit 1
        }
    }

    # -From/-To take priority over -Since
    if ($FromStr -ne '') {
        try {
            $result.from = [datetime]::Parse($FromStr)
        } catch {
            Write-Log 'ERROR' "Cannot parse -From datetime: $FromStr"
            exit 1
        }
        return $result
    }

    # Parse -Since duration string: 24h, 7d, 1h, 30m
    if ($SinceStr -match '^(\d+)(m|h|d)$') {
        $amount = [int]$Matches[1]
        $unit   = $Matches[2]
        switch ($unit) {
            'm' { $result.from = $result.to.AddMinutes(-$amount) }
            'h' { $result.from = $result.to.AddHours(-$amount) }
            'd' { $result.from = $result.to.AddDays(-$amount) }
        }
    } else {
        Write-Log 'ERROR' "Invalid -Since format: '$SinceStr'. Use e.g. 24h, 7d, 30m"
        exit 1
    }

    return $result
}

# ============================================================================
# Phase 3: Validation
# ============================================================================

function Test-Prerequisites {
    # .NET compression assembly (should be available on PS 5.1 / .NET 4.5+)
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    } catch {
        Write-Log 'ERROR' 'System.IO.Compression.FileSystem assembly not available'
        exit 10
    }
}

# ============================================================================
# Phase 4: Core logic
# ============================================================================

# --- File discovery -----------------------------------------------------------

function Resolve-GlobPattern([string]$Pattern) {
    <#
    .SYNOPSIS
        Resolve a single glob pattern to matching file paths.
        Handles wildcards via Get-ChildItem. Returns FileInfo objects.
    #>
    $parentDir  = Split-Path $Pattern -Parent
    $leafFilter = Split-Path $Pattern -Leaf

    # Parent may contain wildcards too (e.g. C:\PostgreSQL\*\data\log\*.log)
    # Use -Path with the full pattern and let Get-ChildItem expand it
    $files = @()
    try {
        $files = @(Get-ChildItem -Path $Pattern -File -ErrorAction SilentlyContinue)
    } catch {
        # Permission denied or path not found — handled by caller
    }
    return $files
}

function Find-TargetFiles {
    <#
    .SYNOPSIS
        Discover files across all selected presets, filter by time and size,
        apply total size cap with newest-first prioritization.
    .OUTPUTS
        Array of PSCustomObject with FullName, Length, LastWriteTime, RelativePath, Preset
    #>
    param(
        [hashtable]$Presets,
        [hashtable]$TimeWindow,
        [int]$MaxTotalMB
    )

    $allFiles    = @()
    $skippedPerm = 0
    $skippedSize = 0
    $fromDt      = $TimeWindow.from
    $toDt        = $TimeWindow.to

    foreach ($presetName in $Presets.Keys) {
        $preset = $Presets[$presetName]
        $maxFileSizeBytes = [long]$preset.max_file_size_mb * 1024 * 1024

        foreach ($pattern in $preset.paths) {
            Write-Log 'INFO' "Scanning pattern: $pattern (preset=$presetName)"

            $resolved = @()
            try {
                $resolved = @(Resolve-GlobPattern $pattern)
            } catch {
                Write-Log 'WARN' "Failed to scan pattern '$pattern': $($_.Exception.Message)"
                $skippedPerm++
                continue
            }

            foreach ($f in $resolved) {
                # Time filter
                if ($f.LastWriteTime -lt $fromDt -or $f.LastWriteTime -gt $toDt) {
                    continue
                }

                # Individual file size check
                if ($f.Length -gt $maxFileSizeBytes) {
                    Write-Log 'WARN' "File exceeds max_file_size_mb ($($preset.max_file_size_mb)MB), skipped: $($f.FullName) ($([math]::Round($f.Length/1MB,2))MB)"
                    $skippedSize++
                    continue
                }

                # Check readability
                $readable = $true
                try {
                    $stream = $f.OpenRead()
                    $stream.Close()
                    $stream.Dispose()
                } catch {
                    Write-Log 'WARN' "Permission denied, skipped: $($f.FullName)"
                    $skippedPerm++
                    $readable = $false
                }
                if (-not $readable) { continue }

                $allFiles += [PSCustomObject]@{
                    FullName      = $f.FullName
                    Length        = $f.Length
                    LastWriteTime = $f.LastWriteTime
                    Preset        = $presetName
                }
            }
        }
    }

    # Sort by mtime descending (newest first) for size-cap prioritization
    $allFiles = @($allFiles | Sort-Object -Property LastWriteTime -Descending)

    # Apply total size cap
    $maxTotalBytes = [long]$MaxTotalMB * 1024 * 1024
    $accumulated   = [long]0
    $selected      = @()
    $truncated     = 0

    foreach ($f in $allFiles) {
        if (($accumulated + $f.Length) -le $maxTotalBytes) {
            $selected    += $f
            $accumulated += $f.Length
        } else {
            Write-Log 'WARN' "Total size cap (${MaxTotalMB}MB) reached, skipping older file: $($f.FullName)"
            $truncated++
        }
    }

    if ($skippedPerm -gt 0) {
        Write-Log 'WARN' "Skipped $skippedPerm file(s) due to permission errors"
    }
    if ($skippedSize -gt 0) {
        Write-Log 'WARN' "Skipped $skippedSize file(s) exceeding per-file size limit"
    }
    if ($truncated -gt 0) {
        Write-Log 'WARN' "Truncated $truncated older file(s) due to total size cap"
    }

    return $selected
}

# --- OS info collection -------------------------------------------------------

function Get-OsInfoText {
    <#
    .SYNOPSIS
        Collect basic OS information for the evidence package.
    #>
    $sb = New-Object System.Text.StringBuilder

    [void]$sb.AppendLine('=== OS Information ===')
    [void]$sb.AppendLine("Hostname: $env:COMPUTERNAME")
    [void]$sb.AppendLine("Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    [void]$sb.AppendLine("User: $env:USERNAME")
    [void]$sb.AppendLine('')

    # systeminfo — may be slow but provides comprehensive data
    try {
        $sysinfo = systeminfo 2>&1 | Out-String
        [void]$sb.AppendLine($sysinfo)
    } catch {
        [void]$sb.AppendLine('[systeminfo not available]')
    }

    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('=== Disk Usage ===')
    try {
        $drives = @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)
        foreach ($d in $drives) {
            $usedGB = [math]::Round($d.Used / 1GB, 2)
            $freeGB = [math]::Round($d.Free / 1GB, 2)
            [void]$sb.AppendLine("$($d.Name): Used=${usedGB}GB Free=${freeGB}GB")
        }
    } catch {
        [void]$sb.AppendLine('[disk info not available]')
    }

    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('=== Network Adapters ===')
    try {
        $adapters = @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration `
            -Filter "IPEnabled=True" -ErrorAction SilentlyContinue)
        foreach ($a in $adapters) {
            $ips = if ($null -ne $a.IPAddress) { $a.IPAddress -join ', ' } else { 'N/A' }
            [void]$sb.AppendLine("$($a.Description): $ips")
        }
    } catch {
        [void]$sb.AppendLine('[network info not available]')
    }

    return $sb.ToString()
}

# --- Manifest generation ------------------------------------------------------

function New-Manifest($Files) {
    <#
    .SYNOPSIS
        Generate manifest array with path, size, sha256, mtime for each file.
    .OUTPUTS
        JSON string of the manifest array.
    #>
    $manifest = @()
    $total = $Files.Count
    $idx = 0

    foreach ($f in $Files) {
        $idx++
        if ($idx % 10 -eq 0 -or $idx -eq $total) {
            Write-Log 'INFO' "Hashing file $idx/$total ..."
        }
        try {
            $hashResult = Get-FileHash -Path $f.FullName -Algorithm SHA256
            $hashValue  = $hashResult.Hash.ToLower()
        } catch {
            Write-Log 'WARN' "Cannot hash file: $($f.FullName) - $($_.Exception.Message)"
            $hashValue = 'ERROR'
        }
        $manifest += [ordered]@{
            path       = $f.RelativePath
            size_bytes = $f.Length
            sha256     = $hashValue
            mtime      = $f.LastWriteTime.ToString('yyyy-MM-ddTHH:mm:ss')
        }
    }

    return ConvertTo-Json -InputObject @($manifest) -Depth 3
}

# --- ZIP packaging ------------------------------------------------------------

function New-EvidenceZip {
    <#
    .SYNOPSIS
        Create ZIP archive from collected files, manifest, and OS info.
    .OUTPUTS
        Path to the created ZIP file.
    #>
    param(
        [array]$Files,
        [string]$ManifestJson,
        [string]$OsInfoText,
        [string]$OutDir
    )

    $timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $hostname  = $env:COMPUTERNAME
    $zipName   = "evidence_${hostname}_${timestamp}.zip"
    $zipPath   = Join-Path $OutDir $zipName

    # Create temp staging directory
    $tempBase = Join-Path ([System.IO.Path]::GetTempPath()) "logcollector_$timestamp"
    if (Test-Path $tempBase) {
        Remove-Item $tempBase -Recurse -Force -Confirm:$false
    }
    New-Item -ItemType Directory -Path $tempBase -Force | Out-Null

    try {
        # Write manifest.json
        $manifestPath = Join-Path $tempBase 'manifest.json'
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($manifestPath, $ManifestJson, $utf8NoBom)

        # Write osinfo.txt
        $osinfoPath = Join-Path $tempBase 'osinfo.txt'
        [System.IO.File]::WriteAllText($osinfoPath, $OsInfoText, $utf8NoBom)

        # Copy files preserving directory structure
        $copyCount = 0
        foreach ($f in $Files) {
            $relPath = $f.RelativePath
            $destPath = Join-Path $tempBase $relPath
            $destDir  = Split-Path $destPath -Parent

            if (-not (Test-Path $destDir)) {
                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
            }

            try {
                Copy-Item -Path $f.FullName -Destination $destPath -Force
                $copyCount++
            } catch {
                Write-Log 'WARN' "Failed to copy: $($f.FullName) - $($_.Exception.Message)"
            }
        }

        Write-Log 'INFO' "Staged $copyCount file(s) in temp directory"

        # Create ZIP
        if (Test-Path $zipPath) {
            Remove-Item $zipPath -Force -Confirm:$false
        }
        [System.IO.Compression.ZipFile]::CreateFromDirectory(
            $tempBase,
            $zipPath,
            [System.IO.Compression.CompressionLevel]::Optimal,
            $false   # includeBaseDirectory
        )

        Write-Log 'INFO' "ZIP archive created: $zipPath"

    } finally {
        # Cleanup temp directory
        if (Test-Path $tempBase) {
            try {
                Remove-Item $tempBase -Recurse -Force -Confirm:$false
            } catch {
                Write-Log 'WARN' "Failed to clean temp dir: $tempBase"
            }
        }
    }

    return $zipPath
}

# ============================================================================
# Phase 5: Main orchestration and result output
# ============================================================================

function Invoke-Main {
    Write-Log 'INFO' '=== Evidence Log Collector started ==='

    # -- Prerequisites --
    Test-Prerequisites

    # -- Validate Target --
    if ($Target.Count -eq 0) {
        Write-Log 'ERROR' 'No -Target specified. Use e.g. -Target tomcat,os'
        exit 1
    }

    # Flatten comma-separated values: -Target "tomcat,os" or -Target tomcat,os
    $targetList = @()
    foreach ($t in $Target) {
        foreach ($item in ($t -split ',')) {
            $trimmed = $item.Trim()
            if ($trimmed -ne '') {
                $targetList += $trimmed
            }
        }
    }

    if ($targetList.Count -eq 0) {
        Write-Log 'ERROR' 'No valid target presets after parsing'
        exit 1
    }

    # -- Load config --
    $confPath = $ConfigFile
    if ($confPath -eq '') {
        $confPath = Join-Path $ScriptDir 'collect_targets.conf'
    }

    Write-Log 'INFO' "Config file: $confPath"
    $config = Read-CollectConfig $confPath

    # -- Validate requested presets exist --
    $selectedPresets = @{}
    foreach ($name in $targetList) {
        if (-not $config.ContainsKey($name)) {
            Write-Log 'ERROR' "Unknown preset '$name'. Available: $($config.Keys -join ', ')"
            exit 1
        }
        $selectedPresets[$name] = $config[$name]
    }

    Write-Log 'INFO' "Selected presets: $($targetList -join ', ')"

    # -- Compute time window --
    $timeWindow = Get-TimeWindow -SinceStr $Since -FromStr $From -ToStr $To
    Write-Log 'INFO' "Time window: from=$($timeWindow.from.ToString('yyyy-MM-dd HH:mm:ss')) to=$($timeWindow.to.ToString('yyyy-MM-dd HH:mm:ss'))"

    # -- Discover files --
    Write-Log 'INFO' "Max total size: ${MaxSizeMB}MB"
    $foundFiles = @(Find-TargetFiles -Presets $selectedPresets -TimeWindow $timeWindow -MaxTotalMB $MaxSizeMB)

    if ($foundFiles.Count -eq 0) {
        Write-Log 'ERROR' 'No files matched the criteria. Nothing to collect.'
        exit 2
    }

    Write-Log 'INFO' "Matched $($foundFiles.Count) file(s)"

    # -- Build relative paths for archive structure --
    # Use drive letter + path to create unique relative paths
    foreach ($f in $foundFiles) {
        $fullPath = $f.FullName
        # Convert C:\foo\bar.log -> C\foo\bar.log (strip colon)
        if ($fullPath -match '^([A-Za-z]):\\(.+)$') {
            $f | Add-Member -NotePropertyName RelativePath -NotePropertyValue "$($Matches[1])\$($Matches[2])" -Force
        } else {
            # UNC or other path — use as-is minus leading backslashes
            $relPath = $fullPath -replace '^\\+', ''
            $f | Add-Member -NotePropertyName RelativePath -NotePropertyValue $relPath -Force
        }
    }

    # -- Collect OS info --
    Write-Log 'INFO' 'Collecting OS information...'
    $osInfoText = Get-OsInfoText

    # -- Generate manifest --
    Write-Log 'INFO' 'Generating file manifest (hashing)...'
    $manifestJson = New-Manifest $foundFiles

    # -- Resolve output directory --
    $outDir = $OutputDir
    if (-not (Test-Path $outDir)) {
        try {
            New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        } catch {
            Write-Log 'ERROR' "Cannot create output directory: $outDir"
            exit 1
        }
    }
    $outDir = (Resolve-Path $outDir).Path

    # -- Create ZIP --
    Write-Log 'INFO' 'Creating evidence ZIP archive...'
    $zipPath = New-EvidenceZip -Files $foundFiles `
        -ManifestJson $manifestJson `
        -OsInfoText $osInfoText `
        -OutDir $outDir

    # -- Summary --
    $totalSizeMB = [math]::Round(($foundFiles | Measure-Object -Property Length -Sum).Sum / 1MB, 2)
    $zipSize     = (Get-Item $zipPath).Length
    $zipSizeMB   = [math]::Round($zipSize / 1MB, 2)

    Write-Log 'INFO' '=== Collection Summary ==='
    Write-Log 'INFO' "Presets      : $($targetList -join ', ')"
    Write-Log 'INFO' "Files        : $($foundFiles.Count)"
    Write-Log 'INFO' "Total size   : ${totalSizeMB}MB (raw) -> ${zipSizeMB}MB (zip)"
    Write-Log 'INFO' "Time window  : $($timeWindow.from.ToString('yyyy-MM-dd HH:mm:ss')) - $($timeWindow.to.ToString('yyyy-MM-dd HH:mm:ss'))"
    Write-Log 'INFO' "Output       : $zipPath"
    Write-Log 'INFO' '=== Evidence Log Collector completed ==='

    exit 0
}

# ── Entry point ──────────────────────────────────────────────────────────────
Invoke-Main
