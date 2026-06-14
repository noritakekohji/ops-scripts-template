#Requires -Version 5.1
<#
.SYNOPSIS
    Wait until Ping/TCP/HTTP targets in a list pass N consecutive rounds.

.PARAMETER TargetList
    Path to the targets list file (CSV, '#' = comment).

.NOTES
    Exit codes: 0 success, 1 usage, 2 list parse error, 3 timeout, 10 prereq missing.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$TargetList
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:Status  = 'unknown'
$script:Rounds  = 0
$script:Consec  = 0
$script:Start   = Get-Date

# --- lib resolution -----------------------------------------------------------
function Resolve-OpsLib {
    param([string]$From)
    $d = $From
    while ($d -and (Split-Path $d -Parent)) {
        $candidate = Join-Path $d 'lib\Logging.psm1'
        if (Test-Path $candidate) { return (Join-Path $d 'lib') }
        $candidate = Join-Path $d 'lib\windows\Logging.psm1'
        if (Test-Path $candidate) { return (Join-Path $d 'lib\windows') }
        if (Test-Path (Join-Path $d '.ops-deploy-root')) { return $null }
        $parent = Split-Path $d -Parent
        if ($parent -eq $d) { return $null }
        $d = $parent
    }
    return $null
}

$opsLib = if ($env:OPS_LIB) { $env:OPS_LIB } else { Resolve-OpsLib -From $PSScriptRoot }
if (-not $opsLib) {
    Write-Error '[ERROR] lib/Logging.psm1 not found (set OPS_LIB to override)'
    exit 1
}
Import-Module (Join-Path $opsLib 'Logging.psm1') -Force
Import-Module (Join-Path $opsLib 'Config.psm1')  -Force

function Emit-Result {
    $elapsed = [int]((Get-Date) - $script:Start).TotalSeconds
    Write-OpsLog -Level INFO -Message ("[RESULT] status={0} rounds={1} elapsed={2}s consec={3}" -f `
        $script:Status, $script:Rounds, $elapsed, $script:Consec)
}

if (-not $TargetList) {
    Write-Error 'Usage: ServiceWait.ps1 -TargetList <path>'
    exit 1
}

$cfg = Get-OpsConfig -Name 'service_wait'

$initialWait = [int]($cfg['initial_wait_sec']      | ForEach-Object { if ($_) { $_ } else { 0 } })
$interval    = [int]($cfg['interval_sec']          | ForEach-Object { if ($_) { $_ } else { 5 } })
$successN    = [int]($cfg['success_threshold']     | ForEach-Object { if ($_) { $_ } else { 3 } })
$timeoutSec  = [int]($cfg['timeout_sec']           | ForEach-Object { if ($_) { $_ } else { 600 } })
$defaultPerCheck = [int]($cfg['per_check_timeout_sec'] | ForEach-Object { if ($_) { $_ } else { 5 } })

# Test hooks
if ($env:OPS_OVERRIDE_INITIAL_WAIT_SEC)  { $initialWait = [int]$env:OPS_OVERRIDE_INITIAL_WAIT_SEC }
if ($env:OPS_OVERRIDE_INTERVAL_SEC)      { $interval    = [int]$env:OPS_OVERRIDE_INTERVAL_SEC }
if ($env:OPS_OVERRIDE_TIMEOUT_SEC)       { $timeoutSec  = [int]$env:OPS_OVERRIDE_TIMEOUT_SEC }
if ($env:OPS_OVERRIDE_SUCCESS_THRESHOLD) { $successN    = [int]$env:OPS_OVERRIDE_SUCCESS_THRESHOLD }

if ($cfg['LogFile']) {
    try { Set-OpsLogConfig -File $cfg['LogFile'] -Level ($cfg['LogLevel'] | ForEach-Object { if ($_) { $_ } else { 'INFO' } }) } catch { }
}

if (-not (Test-Path -LiteralPath $TargetList -PathType Leaf)) {
    Write-OpsLog -Level ERROR -Message "Target list file not found: $TargetList"
    $script:Status = 'failed'; Emit-Result; exit 2
}

$targets = New-Object System.Collections.Generic.List[hashtable]
$lineno  = 0
foreach ($raw in (Get-Content -LiteralPath $TargetList)) {
    $lineno++
    $line = $raw.Trim()
    if (-not $line)            { continue }
    if ($line.StartsWith('#')) { continue }
    $cols = $line -split ',' | ForEach-Object { $_.Trim() }
    if ($cols.Count -lt 3) {
        Write-OpsLog -Level ERROR -Message "List parse error: line=$lineno reason=need_3_cols raw='$line'"
        $script:Status = 'failed'; Emit-Result; exit 2
    }
    $t = @{ type = $cols[0]; target = $cols[1]; desc = $cols[2]; per_check = $defaultPerCheck }

    if ($t.type -notin @('ping','tcp','http')) {
        Write-OpsLog -Level ERROR -Message "List parse error: line=$lineno reason=unknown_type type='$($t.type)'"
        $script:Status = 'failed'; Emit-Result; exit 2
    }
    if ($t.type -eq 'tcp' -and $t.target -notmatch ':\d+$') {
        Write-OpsLog -Level ERROR -Message "List parse error: line=$lineno reason=tcp_needs_host_port target='$($t.target)'"
        $script:Status = 'failed'; Emit-Result; exit 2
    }
    if ($t.type -eq 'http' -and $t.target -notmatch '^(http|https)://') {
        Write-OpsLog -Level ERROR -Message "List parse error: line=$lineno reason=http_needs_url target='$($t.target)'"
        $script:Status = 'failed'; Emit-Result; exit 2
    }

    # Columns 4..end may carry key=value tokens (space-separated within a column).
    if ($cols.Count -ge 4) {
        $extra = ($cols[3..($cols.Count - 1)] -join ' ').Trim()
        foreach ($kv in ($extra -split '\s+' | Where-Object { $_ })) {
            $m = [regex]::Match($kv, '^([^=]+)=(.*)$')
            if (-not $m.Success) {
                Write-OpsLog -Level ERROR -Message "List parse error: line=$lineno reason=bad_token token='$kv'"
                $script:Status = 'failed'; Emit-Result; exit 2
            }
            $key = $m.Groups[1].Value
            $val = $m.Groups[2].Value
            switch ($key) {
                'per_check_timeout_sec' {
                    if ($val -notmatch '^\d+$') {
                        Write-OpsLog -Level ERROR -Message "List parse error: line=$lineno reason=bad_per_check value='$val'"
                        $script:Status = 'failed'; Emit-Result; exit 2
                    }
                    $t.per_check = [int]$val
                }
                default {
                    Write-OpsLog -Level ERROR -Message "List parse error: line=$lineno reason=unknown_key key='$key'"
                    $script:Status = 'failed'; Emit-Result; exit 2
                }
            }
        }
    }
    $targets.Add($t) | Out-Null
}

if ($targets.Count -eq 0) {
    Write-OpsLog -Level ERROR -Message "Target list is empty: $TargetList"
    $script:Status = 'failed'; Emit-Result; exit 2
}

Write-OpsLog -Level INFO -Message ("start targets={0} timeout={1} success={2} interval={3} initial={4}" -f `
    $targets.Count, $timeoutSec, $successN, $interval, $initialWait)

Start-Sleep -Seconds $initialWait
$deadline = $script:Start.AddSeconds($timeoutSec)
while ((Get-Date) -lt $deadline) {
    $script:Rounds++
    Write-OpsLog -Level INFO -Message "[ROUND $($script:Rounds)] stub (not implemented)"
    Start-Sleep -Seconds $interval
}
$script:Status = 'timeout'
Emit-Result
exit 3
