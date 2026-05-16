#Requires -Version 5.1
<#
.SYNOPSIS
    Capture server state before/after a change and compare the difference.

.DESCRIPTION
    Wraps Get-ServerInfo.ps1 and Compare-ServerInfo.ps1 from the sibling
    server-compare directory to implement a before/after change detection
    workflow.

    Modes:
      before   Collect server info and save as "before" snapshot
      after    Collect, auto-find latest "before" snapshot, and compare
      compare  Compare two existing snapshot files directly

.PARAMETER Mode
    Required. One of: before, after, compare

.PARAMETER Label
    Optional label embedded in the snapshot filename (e.g. deploy-v1.2.3).

.PARAMETER Category
    Categories to collect. Default: all
    Valid: all, os, network, services, packages, users,
           filesystem, environment, security

.PARAMETER OutputPath
    Explicit path for the snapshot JSON file (auto-named if omitted).

.PARAMETER BeforePath
    Path to the "before" snapshot (for 'after' and 'compare' modes).
    In 'after' mode, the latest *_before_*.json in the current directory
    is used automatically when this is omitted.

.PARAMETER AfterPath
    Path to the "after" snapshot (for 'compare' mode only).

.PARAMETER HtmlReport
    Path for the HTML comparison report.

.EXAMPLE
    .\Change-Detect.ps1 before -Label deploy-v1.2.3
    .\Change-Detect.ps1 after  -Label deploy-v1.2.3 -HtmlReport report.html
    .\Change-Detect.ps1 compare -BeforePath before.json -AfterPath after.json

.NOTES
    Depends on ../server-compare/Get-ServerInfo.ps1
    and         ../server-compare/Compare-ServerInfo.ps1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('before','after','compare')]
    [string]$Mode,

    [string]$Label      = '',
    [string]$Category   = 'all',
    [string]$OutputPath = '',
    [string]$BeforePath = '',
    [string]$AfterPath  = '',
    [string]$HtmlReport = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Start log transcript if launched from the .bat file (OPS_LOG_FILE env var)
if ($env:OPS_LOG_FILE) {
    Start-Transcript -Path $env:OPS_LOG_FILE -Force -Append -ErrorAction SilentlyContinue | Out-Null
}

$ScriptDir   = $PSScriptRoot
$GetInfoPs1  = [IO.Path]::Combine($ScriptDir, '..', 'server-compare', 'Get-ServerInfo.ps1')
$ComparePs1  = [IO.Path]::Combine($ScriptDir, '..', 'server-compare', 'Compare-ServerInfo.ps1')

# Validate sibling scripts exist
if (-not (Test-Path $GetInfoPs1)) {
    Write-Error "Get-ServerInfo.ps1 not found: $GetInfoPs1"
    exit 1
}
if ($Mode -in @('after','compare') -and -not (Test-Path $ComparePs1)) {
    Write-Error "Compare-ServerInfo.ps1 not found: $ComparePs1"
    exit 1
}

$hostName  = $env:COMPUTERNAME
$ts        = Get-Date -Format 'yyyyMMdd-HHmmss'
$labelPart = if ($Label) { "_$Label" } else { '' }

# ============================================================
# Collect snapshot via Get-ServerInfo.ps1
# ============================================================

function Invoke-CollectSnapshot([string]$SnapType, [string]$SnapFile) {
    Write-Host ''
    Write-Host "=== Collecting $($SnapType.ToUpper()) snapshot ===" -ForegroundColor Cyan
    Write-Host "  Host       : $hostName"
    Write-Host "  Categories : $Category"
    Write-Host "  Output     : $SnapFile"
    Write-Host ''

    # Build category array for Get-ServerInfo.ps1
    $catArgs = @('-Category', $Category, '-OutputPath', $SnapFile)
    & powershell.exe -ExecutionPolicy Bypass -NoLogo -File $GetInfoPs1 @catArgs

    if (-not (Test-Path $SnapFile)) {
        Write-Error "Snapshot not created: $SnapFile"
        exit 1
    }
}

# ============================================================
# Find the latest *_before_*.json in current directory
# ============================================================

function Find-LatestBefore {
    $pattern = "${hostName}_before*.json"
    $found = Get-ChildItem -Filter $pattern -ErrorAction SilentlyContinue |
             Sort-Object Name -Descending |
             Select-Object -First 1
    if ($found) { return $found.FullName } else { return '' }
}

# ============================================================
# Run comparison via Compare-ServerInfo.ps1
# ============================================================

function Invoke-RunComparison([string]$Bf, [string]$Af, [string]$Html) {
    Write-Host ''
    Write-Host '=== Running comparison ===' -ForegroundColor Cyan
    Write-Host "  Before : $Bf"
    Write-Host "  After  : $Af"

    $compareArgs = @('-Before', $Bf, '-After', $Af)
    if ($Html) { $compareArgs += @('-HtmlReport', $Html) }

    & powershell.exe -ExecutionPolicy Bypass -NoLogo -File $ComparePs1 @compareArgs
}

# ============================================================
# Main
# ============================================================

switch ($Mode) {

    'before' {
        if (-not $OutputPath) {
            $OutputPath = "${hostName}_before${labelPart}_${ts}.json"
        }
        Invoke-CollectSnapshot 'before' $OutputPath
        Write-Host ''
        Write-Host "  Before snapshot saved: $OutputPath" -ForegroundColor Green
        $afterCmd = ".\Change-Detect.ps1 after$(if($Label){" -Label $Label"})"
        Write-Host "  Run '$afterCmd' after making your changes." -ForegroundColor DarkGray
    }

    'after' {
        if (-not $OutputPath) {
            $OutputPath = "${hostName}_after${labelPart}_${ts}.json"
        }
        Invoke-CollectSnapshot 'after' $OutputPath
        $afterFile = $OutputPath

        # Auto-find before snapshot
        if (-not $BeforePath) {
            $BeforePath = Find-LatestBefore
            if (-not $BeforePath) {
                Write-Error "No before snapshot found in current directory. Run '.\Change-Detect.ps1 before' first."
                exit 1
            }
            Write-Host "  Using before snapshot: $BeforePath" -ForegroundColor DarkGray
        }

        Invoke-RunComparison $BeforePath $afterFile $HtmlReport
    }

    'compare' {
        if (-not $BeforePath) { Write-Error '-BeforePath is required in compare mode'; exit 1 }
        if (-not $AfterPath)  { Write-Error '-AfterPath is required in compare mode';  exit 1 }
        Invoke-RunComparison $BeforePath $AfterPath $HtmlReport
    }
}
