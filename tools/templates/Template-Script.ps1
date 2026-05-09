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

.PARAMETER ParamName
    <パラメータの意味と制約>

.EXAMPLE
    .\Template-Script.ps1 -ParamName value
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

try {
    # The do/while($false) pattern lets each phase 'break' out cleanly while
    # still allowing the finally block (Phase 5) to run.
    do {
        # --------------------------------------------------------------------
        # Phase 1b: Cross-parameter validation
        # --------------------------------------------------------------------
        # if (-not (... cross-param condition ...)) {
        #     Write-OpsLog -Level ERROR -Message "Invalid combination: paramX=$X paramY=$Y"
        #     $exitCode = 1; $status = 'failed'
        #     break
        # }
        Write-OpsLog -Level INFO -Message "Args validated: paramName=$ParamName"

        # --------------------------------------------------------------------
        # Phase 3: Pre-check (prerequisites + idempotency)
        # All checks here MUST be side-effect free (read-only).
        # --------------------------------------------------------------------
        Write-OpsLog -Level INFO -Message 'Pre-check start'

        # 3-a: Required modules / CLIs present
        # if (-not (Get-Module -ListAvailable AWS.Tools.EC2)) {
        #     Write-OpsLog -Level ERROR -Message 'AWS.Tools.EC2 module not installed'
        #     $exitCode = 10; $status = 'failed'
        #     break
        # }

        # 3-b: Authentication usable
        # try { Get-STSCallerIdentity | Out-Null }
        # catch {
        #     Write-OpsLog -Level ERROR -Message "Auth failed: error=$($_.Exception.Message)"
        #     $exitCode = 20; $status = 'failed'
        #     break
        # }

        # 3-c: Target resource exists / is reachable
        # if (-not (Test-Path -LiteralPath $Target)) {
        #     Write-OpsLog -Level ERROR -Message "Target not found: target=$Target"
        #     $exitCode = 2; $status = 'failed'
        #     break
        # }

        # 3-d: Idempotency — already in desired state? If yes, skip cleanly.
        # if (... already done ...) {
        #     Write-OpsLog -Level INFO -Message 'Skipped (idempotent): reason=already_completed'
        #     $exitCode = 0; $status = 'skipped'
        #     break
        # }

        # 3-e: External dependency reachability
        # if (-not (Test-NetConnection -ComputerName 'host' -Port 443 -Quiet)) {
        #     Write-OpsLog -Level ERROR -Message 'External dependency unreachable: host=...'
        #     $exitCode = 5; $status = 'failed'
        #     break
        # }

        Write-OpsLog -Level INFO -Message 'Pre-check passed'

        # --------------------------------------------------------------------
        # Phase 4: Main processing (side-effects allowed)
        # --------------------------------------------------------------------
        Write-OpsLog -Level INFO -Message 'Main start'

        if ($PSCmdlet.ShouldProcess($ParamName, 'Describe the action here')) {
            # TODO: replace with the real implementation
            # Example: $tempFile = New-TemporaryFile

            Write-OpsLog -Level INFO -Message "Doing work: paramName=$ParamName"
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
            }
        }
        catch {
            Write-OpsLog -Level WARN -Message "Cleanup failed: file=$tempFile error=$($_.Exception.Message)"
        }
    }
    Write-OpsLog -Level INFO -Message "Script end: status=$status exitCode=$exitCode"
}

exit $exitCode
