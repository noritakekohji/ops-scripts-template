#Requires -Version 7
<#
.SYNOPSIS
    <一行サマリ：このスクリプトが何をするか>

.DESCRIPTION
    <詳細説明。前提条件、副作用、認証要件、想定実行環境>

    Flow:
      1. Argument validation     ([Validate*] + cross-param checks)
      2. Environment setup       (logger / strict mode / cleanup hook)
      3. Pre-check               (prerequisites + idempotency, side-effect free)
      4. Main processing         (the actual work)
      5. Post-processing         (always runs via finally; cleanup + final log)

    This file is a runnable demonstration. Each phase is implemented with
    placeholder logic so that running the script as-is produces a complete
    end-to-end log demonstrating all five phases plus idempotent skip.
    Replace the demo logic with your real checks / work.

.PARAMETER ParamName
    Identifier used in the demo to name the per-run idempotency marker.

.EXAMPLE
    # First run: full success
    .\Template-Script.ps1 -ParamName demo

.EXAMPLE
    # Run again within 60 seconds: idempotent skip (status=skipped, exit 0)
    .\Template-Script.ps1 -ParamName demo
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    # ========================================================================
    # Phase 1: Argument validation (handled by [Validate*] attributes here)
    # Cross-parameter checks go inside the body, before Phase 3.
    # ========================================================================
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$ParamName
)

# ============================================================================
# Phase 2: Environment setup
# ============================================================================
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Import shared logger.
# TEMPLATE: adjust the number of '..' segments to your script depth.
#   scripts/aws/windows/ami/Foo.ps1   -> 4 ups
#   scripts/windows/log/Bar.ps1       -> 3 ups
$libPath = Join-Path $PSScriptRoot '..' '..' '..' '..' 'lib' 'powershell' 'Logging.psm1'
if (-not (Test-Path $libPath)) {
    throw "Logging module not found at $libPath"
}
Import-Module (Resolve-Path $libPath).Path -Force

# State for Phase 5 cleanup
$tempFile = $null
$exitCode = 0
$status = 'unknown'

# Demo-only: idempotency window in seconds. Re-runs within this window skip.
$IdempotencyWindowSec = 60

try {
    # The do/while($false) pattern lets each phase 'break' out cleanly while
    # still letting the finally block (Phase 5) run.
    do {
        # --------------------------------------------------------------------
        # Phase 1b: Cross-parameter validation
        # --------------------------------------------------------------------
        # if (-not (... cross-param condition ...)) {
        #     Write-OpsLog -Level ERROR -Message "Invalid combination: paramX=$X paramY=$Y"
        #     $exitCode = 1; $status = 'failed'; break
        # }
        Write-OpsLog -Level INFO -Message "Args validated: paramName=$ParamName"

        # --------------------------------------------------------------------
        # Phase 3: Pre-check (prerequisites + idempotency)
        # All checks here MUST be side-effect free (read-only).
        # Replace each demo check with the relevant real check for your script.
        # --------------------------------------------------------------------
        Write-OpsLog -Level INFO -Message 'Pre-check start'

        # 3-a: Required modules / CLIs present
        # DEMO: ensure Get-Date cmdlet is loadable. REAL: e.g. AWS.Tools.EC2.
        if (-not (Get-Command Get-Date -ErrorAction SilentlyContinue)) {
            Write-OpsLog -Level ERROR -Message 'Required cmdlet not found: Get-Date'
            $exitCode = 10; $status = 'failed'; break
        }

        # 3-b: Authentication usable
        # DEMO: confirm we have a username. REAL: e.g. Get-STSCallerIdentity.
        if (-not $env:USERNAME) {
            Write-OpsLog -Level ERROR -Message 'No username; cannot determine identity'
            $exitCode = 20; $status = 'failed'; break
        }

        # 3-c: Target resource exists / reachable
        # DEMO: working directory ($env:TEMP) is reachable. REAL: target file/host.
        $workDir = $env:TEMP
        if (-not (Test-Path -LiteralPath $workDir -PathType Container)) {
            Write-OpsLog -Level ERROR -Message "Working dir not found: dir=$workDir"
            $exitCode = 2; $status = 'failed'; break
        }

        # 3-d: Idempotency — already in desired state? If yes, skip cleanly.
        # DEMO: skip if a per-ParamName marker file was touched within the
        # IdempotencyWindowSec. REAL: check whether the action was recently
        # performed (e.g. AMI created in the last hour for this NamePrefix).
        $marker = Join-Path $workDir "template-demo-$ParamName.marker"
        if (Test-Path -LiteralPath $marker) {
            $ageSec = ((Get-Date) - (Get-Item -LiteralPath $marker).LastWriteTime).TotalSeconds
            if ($ageSec -lt $IdempotencyWindowSec) {
                Write-OpsLog -Level INFO -Message "Skipped (idempotent): reason=marker_recent marker=$marker ageSec=$([math]::Round($ageSec))"
                $exitCode = 0; $status = 'skipped'; break
            }
        }

        # 3-e: External dependency reachability
        # DEMO: skipped (no external dependency in the demo).
        # REAL: e.g. Test-NetConnection -ComputerName ... -Port 443 -Quiet.

        Write-OpsLog -Level INFO -Message 'Pre-check passed'

        # --------------------------------------------------------------------
        # Phase 4: Main processing (side-effects allowed)
        # --------------------------------------------------------------------
        Write-OpsLog -Level INFO -Message 'Main start'

        if ($PSCmdlet.ShouldProcess($ParamName, 'Run demo work')) {
            # DEMO: write a payload to a scratch temp file, then update the
            # idempotency marker. REAL: replace with the actual operation.

            $tempFile = New-TemporaryFile
            "Demo payload for $ParamName written at $(Get-Date)" |
                Set-Content -LiteralPath $tempFile -Encoding utf8
            $size = (Get-Item -LiteralPath $tempFile).Length
            Write-OpsLog -Level INFO -Message "Wrote scratch file: file=$($tempFile.FullName) bytes=$size"

            (Get-Date).ToString('o') | Set-Content -LiteralPath $marker -Encoding utf8
            Write-OpsLog -Level INFO -Message "Marker updated: marker=$marker"
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
    # ========================================================================
    # Phase 5: Post-processing — always runs (success / failure / skip alike)
    # ========================================================================
    if ($tempFile) {
        try {
            if (Test-Path -LiteralPath $tempFile) {
                Remove-Item -LiteralPath $tempFile -Force
                Write-OpsLog -Level INFO -Message "Cleanup: removed temp file=$tempFile"
            }
        }
        catch {
            Write-OpsLog -Level WARN -Message "Cleanup failed: file=$tempFile error=$($_.Exception.Message)"
        }
    }
    Write-OpsLog -Level INFO -Message "Script end: status=$status exitCode=$exitCode"
}

exit $exitCode
