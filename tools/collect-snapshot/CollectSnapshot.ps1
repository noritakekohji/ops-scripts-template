#Requires -Version 5.1
<#
.SYNOPSIS
    Snapshot collection wrapper - runs server-snapshot, port-inventory,
    aws-instance-audit in sequence and packages results into a ZIP file.

.DESCRIPTION
    Phase 1: Parameter parsing / defaults
    Phase 2: Tool discovery via COLLECT_SNAPSHOT_TOOLS_DIR or sibling dirs
    Phase 3: Pre-flight validation
    Phase 4: Run each tool; continue on failure, track overall exit code
    Phase 5: Compress results, remove staging dir, report summary

.PARAMETER Label
    Optional label embedded in the archive name.
    Archive: <hostname>_<label>_<timestamp>.zip

.PARAMETER Output
    Output directory for the ZIP archive. Default: .\snapshots

.PARAMETER Menu
    Display an interactive TUI menu for label / output / tool selection.

.EXAMPLE
    .\CollectSnapshot.ps1 -Label pre-upgrade -Output C:\Snapshots
    .\CollectSnapshot.ps1 -Menu

.NOTES
    Exit codes:
      0  All tools succeeded
      1  One or more tools returned non-zero (ZIP still created)
     10  Compress-Archive cmdlet not available (PowerShell 5.1+ required)
#>
[CmdletBinding()]
param(
    [string]$Label  = '',
    [string]$Output = '',
    [switch]$Menu
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# 笏笏笏 Path resolution 笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# COLLECT_SNAPSHOT_TOOLS_DIR allows tests to inject a mock tools root.
# In production this is the parent of the script dir (tools/).
$ToolsDir = if ($env:COLLECT_SNAPSHOT_TOOLS_DIR) {
    $env:COLLECT_SNAPSHOT_TOOLS_DIR
} else {
    Split-Path -Parent $ScriptDir
}

$AllTools  = @('server-snapshot', 'port-inventory', 'aws-instance-audit')
$HostVal   = $env:COMPUTERNAME
if (-not $HostVal) { $HostVal = 'localhost' }
$Timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')

if (-not $Output) { $Output = '.\snapshots' }

# Phase 3: prerequisite check
if (-not (Get-Command 'Compress-Archive' -ErrorAction SilentlyContinue)) {
    Write-Error '[collect-snapshot] ERROR: Compress-Archive cmdlet not available (requires PowerShell 5.1+)'
    exit 10
}

# 笏笏笏 Helpers 笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏
function Get-SnapName {
    param([string]$Lbl)
    if ($Lbl) {
        return '{0}_{1}_{2}' -f $HostVal, $Lbl, $Timestamp
    } else {
        return '{0}_{1}' -f $HostVal, $Timestamp
    }
}

function Find-PsExe {
    foreach ($candidate in @('powershell.exe', 'powershell', 'pwsh')) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($null -ne $cmd) { return $cmd.Source }
    }
    return $null
}

function Invoke-SnapTool {
    param(
        [string]$ToolName,
        [string]$SnapDir,
        [string]$HostTs
    )

    $toolDir   = Join-Path $ToolsDir $ToolName
    $outSubDir = Join-Path $SnapDir  $ToolName
    [void](New-Item -ItemType Directory -Path $outSubDir -Force)
    $outJson   = Join-Path $outSubDir "${HostTs}.json"

    $psExe = Find-PsExe
    if ($null -eq $psExe) {
        Write-Warning 'PowerShell executable not found'
        return 10
    }

    switch ($ToolName) {
        'server-snapshot' {
            $script = Join-Path $toolDir 'ServerSnapshot.ps1'
            if (-not (Test-Path $script)) {
                Write-Warning "not found: $script"
                return 1
            }
            & $psExe -NoProfile -ExecutionPolicy Bypass -File $script collect -OutputPath $outJson
            $ec = $LASTEXITCODE
            if ($null -eq $ec) { $ec = 0 }
            return $ec
        }
        'port-inventory' {
            $script = Join-Path $toolDir 'PortInventory.ps1'
            if (-not (Test-Path $script)) {
                Write-Warning "not found: $script"
                return 1
            }
            $json = & $psExe -NoProfile -ExecutionPolicy Bypass -File $script -Json
            $ec = $LASTEXITCODE
            if ($null -eq $ec) { $ec = 0 }
            if ($ec -eq 0) {
                $content = if ($null -ne $json) { $json -join "`n" } else { '[]' }
                [System.IO.File]::WriteAllText(
                    $outJson,
                    $content,
                    [System.Text.UTF8Encoding]::new($false)
                )
            }
            return $ec
        }
        'aws-instance-audit' {
            $script = Join-Path $toolDir 'Get-AwsInstanceAudit.ps1'
            if (-not (Test-Path $script)) {
                Write-Warning "not found: $script"
                return 1
            }
            & $psExe -NoProfile -ExecutionPolicy Bypass -File $script -OutputPath $outJson
            $ec = $LASTEXITCODE
            if ($null -eq $ec) { $ec = 0 }
            return $ec
        }
        default {
            Write-Warning "unknown tool: $ToolName"
            return 1
        }
    }
}

function Invoke-AllTools {
    param(
        [string]$OutDir,
        [string]$SnapName,
        [string[]]$Tools
    )

    if (-not (Test-Path $OutDir)) {
        [void](New-Item -ItemType Directory -Path $OutDir -Force)
    }

    $snapDir = Join-Path $OutDir $SnapName
    [void](New-Item -ItemType Directory -Path $snapDir -Force)

    $logFile = Join-Path $snapDir 'collect-snapshot.log'
    $hostTs  = '{0}_{1}' -f $HostVal, $Timestamp
    $overall = 0
    $total   = $Tools.Count
    $n       = 0

    Write-Host ('[collect-snapshot] host={0}  start={1}' -f $HostVal, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    Write-Host ('[collect-snapshot] output={0}\' -f $snapDir)

    foreach ($tool in $Tools) {
        $n++
        Write-Host ('[{0}/{1}] {2,-22} ... ' -f $n, $total, $tool) -NoNewline
        $tStart   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $exitCode = 0
        try {
            $exitCode = Invoke-SnapTool -ToolName $tool -SnapDir $snapDir -HostTs $hostTs
            if ($null -eq $exitCode) { $exitCode = 0 }
        } catch {
            $exitCode = 1
            Add-Content -Path $logFile -Value "[$tStart] $tool ERROR: $_"
        }
        if ($exitCode -eq 0) {
            Write-Host 'done (exit=0)' -ForegroundColor Green
        } else {
            Write-Host ('WARN (exit={0})' -f $exitCode) -ForegroundColor Yellow
            $overall = 1
        }
        Add-Content -Path $logFile -Value "[$tStart] ${tool}: exit=$exitCode"
    }

    # Compress
    $zipName = '{0}.zip' -f $SnapName
    $zipPath = Join-Path $OutDir $zipName
    Write-Host '[collect-snapshot] compressing ... ' -NoNewline
    try {
        Compress-Archive -Path $snapDir -DestinationPath $zipPath -Force
        Remove-Item -LiteralPath $snapDir -Recurse -Force
        Write-Host $zipName -ForegroundColor Green
        Write-Host '[collect-snapshot] all done.'
    } catch {
        Write-Host ('ERROR: compression failed: {0}' -f $_) -ForegroundColor Red
        return 1
    }

    return $overall
}

function Invoke-TuiMenu {
    Write-Host ''
    Write-Host ('+' + ('-' * 50) + '+') -ForegroundColor Cyan
    Write-Host ('|{0,-50}|' -f '  Snapshot Collection Tool  v1.0') -ForegroundColor Cyan
    Write-Host ('+' + ('-' * 50) + '+') -ForegroundColor Cyan
    Write-Host ('  Host: {0}  |  Time: {1}' -f $HostVal, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    Write-Host ''

    # Step 1: Label
    Write-Host 'Step 1: Enter a label for this snapshot (press Enter to skip)'
    $tuiLabel = (Read-Host 'Label').Trim()

    # Step 2: Output dir
    Write-Host ''
    Write-Host ('Step 2: Output directory [Enter for {0}]' -f $Output)
    $tuiOutput = (Read-Host 'Output dir').Trim()
    if (-not $tuiOutput) { $tuiOutput = $Output }

    # Step 3: Tool selection
    Write-Host ''
    Write-Host 'Step 3: Select tools (comma-separated numbers, Enter for all)'
    for ($i = 0; $i -lt $AllTools.Count; $i++) {
        Write-Host ('  [{0}] {1}' -f ($i + 1), $AllTools[$i])
    }
    $tuiSel = (Read-Host 'Select [1,2,3]').Trim()

    $selected = if ($tuiSel -eq '') {
        $AllTools
    } else {
        $nums = $tuiSel -split ',' |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -match '^[1-3]$' }
        if ($nums.Count -eq 0) {
            $AllTools
        } else {
            $nums | ForEach-Object { $AllTools[[int]$_ - 1] }
        }
    }

    Write-Host ''
    $exitCode = Invoke-AllTools -OutDir $tuiOutput -SnapName (Get-SnapName $tuiLabel) -Tools @($selected)
    return $exitCode
}

# 笏笏笏 Main 笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏
if ($Menu) {
    $exitCode = Invoke-TuiMenu
    exit $exitCode
} else {
    $exitCode = Invoke-AllTools -OutDir $Output -SnapName (Get-SnapName $Label) -Tools $AllTools
    exit $exitCode
}
