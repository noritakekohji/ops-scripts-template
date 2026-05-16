#Requires -Version 5.1
<#
.SYNOPSIS
    Docker-based test runner (PowerShell version of run_tests.sh)

.PARAMETER LinuxOnly
    Run Linux bash tests only.

.PARAMETER PsOnly
    Run PowerShell tests only.

.PARAMETER Build
    Force rebuild of Docker images.

.PARAMETER NoBuild
    Skip image build; use existing images.

.PARAMETER ShellLinux
    Drop into Linux container shell for debugging.

.PARAMETER ShellPs
    Drop into PowerShell container shell for debugging.

.EXAMPLE
    .\run_tests.ps1
    .\run_tests.ps1 -LinuxOnly
    .\run_tests.ps1 -PsOnly
    .\run_tests.ps1 -Build
    .\run_tests.ps1 -ShellLinux
#>
[CmdletBinding()]
param(
    [switch]$LinuxOnly,
    [switch]$PsOnly,
    [switch]$Build,
    [switch]$NoBuild,
    [switch]$ShellLinux,
    [switch]$ShellPs
)

$ErrorActionPreference = 'Stop'

$ScriptDir = $PSScriptRoot
$RepoRoot  = (Resolve-Path ([IO.Path]::Combine($ScriptDir, '..', '..'))).Path

$LinuxImage = 'ops-test-linux:latest'
$PsImage    = 'ops-test-powershell:latest'

$RunLinux   = -not $PsOnly
$RunPs      = -not $LinuxOnly

$Sep  = '=' * 60
$Dash = '-' * 60

# ============================================================
# Helper: colored output
# ============================================================
function Write-Pass([string]$msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green }
function Write-Fail([string]$msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red }
function Write-Sep                { Write-Host $Sep -ForegroundColor Cyan }
function Write-Title([string]$t)  { Write-Sep; Write-Host "  $t" -ForegroundColor Cyan; Write-Sep }

# ============================================================
# Header
# ============================================================
Write-Host ""
Write-Title "Docker Test Runner"
Write-Host "  Repo : $RepoRoot"
Write-Host ""

# ============================================================
# Docker availability check
# ============================================================
try {
    $dockerInfo = docker info --format '{{.ServerVersion}} [{{.OSType}} containers]' 2>$null
    if (-not $dockerInfo) { throw }
    Write-Host "  Docker : $dockerInfo"
} catch {
    Write-Host ""
    Write-Host "ERROR: Docker is not running." -ForegroundColor Red
    Write-Host "  → Start Docker Desktop (Linux containers mode) and try again."
    exit 1
}
Write-Host ""

# ============================================================
# Image build helper
# ============================================================
function Build-Image([string]$Tag, [string]$Dockerfile) {
    if ($NoBuild) { return }

    # Check if image exists without triggering PS5.1 ErrorRecord on stderr
    $imageExists = $false
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    $null = docker image inspect $Tag 2>&1
    $imageExists = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $prev

    if ($Build -or -not $imageExists) {
        Write-Host "  Building $Tag from $Dockerfile ..."
        docker build -t $Tag -f "$ScriptDir\$Dockerfile" $ScriptDir
        if ($LASTEXITCODE -ne 0) { throw "docker build failed for $Tag" }
        Write-Host ""
    } else {
        Write-Host "  Image $Tag already exists (use -Build to rebuild)"
    }
}

# ============================================================
# Build images
# ============================================================
Write-Host $Dash
Write-Host "  Building Docker images" -ForegroundColor White
Write-Host $Dash

if ($RunLinux) { Build-Image $LinuxImage 'Dockerfile.linux' }
if ($RunPs)    { Build-Image $PsImage    'Dockerfile.powershell' }
Write-Host ""

# ============================================================
# Common docker run arguments
# ============================================================
$LinuxRunArgs = @(
    '--rm',
    '--cap-add=NET_RAW',
    '-v', "${RepoRoot}:/repo:ro",
    '-e', 'TERM=xterm-256color'
)
$PsRunArgs = @(
    '--rm',
    '-v', "${RepoRoot}:/repo:ro",
    '-e', 'TERM=xterm-256color'
)

# ============================================================
# Shell debug modes
# ============================================================
if ($ShellLinux) {
    Write-Host "=== Linux container shell ===" -ForegroundColor Cyan
    Write-Host "  Run tests : bash /repo/tests/docker/linux_tests.sh"
    Write-Host ""
    docker run -it @LinuxRunArgs $LinuxImage bash
    exit $LASTEXITCODE
}
if ($ShellPs) {
    Write-Host "=== PowerShell container shell ===" -ForegroundColor Cyan
    Write-Host "  Run tests : pwsh /repo/tests/docker/powershell_tests.ps1"
    Write-Host ""
    docker run -it @PsRunArgs $PsImage pwsh
    exit $LASTEXITCODE
}

# ============================================================
# Run test suites
# ============================================================
$LinuxExit = 0
$PsExit    = 0
$TsTotal   = [int]([DateTimeOffset]::Now.ToUnixTimeSeconds())
if (-not $TsTotal) { $TsTotal = [int]([DateTimeOffset]::Now.ToUnixTimeSeconds()) }

if ($RunLinux) {
    Write-Host $Dash
    Write-Host "  Linux bash tests" -ForegroundColor White
    Write-Host $Dash
    $ts = [int]([DateTimeOffset]::Now.ToUnixTimeSeconds())
    docker run @LinuxRunArgs $LinuxImage bash /repo/tests/docker/linux_tests.sh
    $LinuxExit = $LASTEXITCODE
    $elapsed = [int]([DateTimeOffset]::Now.ToUnixTimeSeconds()) - $ts
    Write-Host "  ($($elapsed)s)" -ForegroundColor DarkGray
    Write-Host ""
}

if ($RunPs) {
    Write-Host $Dash
    Write-Host "  PowerShell tests" -ForegroundColor White
    Write-Host $Dash
    $ts = [int]([DateTimeOffset]::Now.ToUnixTimeSeconds())
    docker run @PsRunArgs $PsImage `
        pwsh -NonInteractive -File /repo/tests/docker/powershell_tests.ps1
    $PsExit = $LASTEXITCODE
    $elapsed = [int]([DateTimeOffset]::Now.ToUnixTimeSeconds()) - $ts
    Write-Host "  ($($elapsed)s)" -ForegroundColor DarkGray
    Write-Host ""
}

# ============================================================
# Final summary
# ============================================================
$TsElapsed = [int]([DateTimeOffset]::Now.ToUnixTimeSeconds()) - $TsTotal
Write-Sep
if ($LinuxExit -eq 0 -and $PsExit -eq 0) {
    Write-Host "  ✓ ALL SUITES PASSED" -ForegroundColor Green
} else {
    Write-Host "  ✗ SOME SUITES FAILED" -ForegroundColor Red
    if ($LinuxExit -ne 0) { Write-Host "    Linux bash tests : FAIL (exit $LinuxExit)" -ForegroundColor Red }
    if ($PsExit    -ne 0) { Write-Host "    PowerShell tests : FAIL (exit $PsExit)"    -ForegroundColor Red }
}
Write-Host "  Total time: $($TsElapsed)s"
Write-Sep
Write-Host ""

exit $(if ($LinuxExit -ne 0 -or $PsExit -ne 0) { 1 } else { 0 })
