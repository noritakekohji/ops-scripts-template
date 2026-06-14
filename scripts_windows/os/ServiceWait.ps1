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

function _Default($value, $fallback) {
    if ($null -eq $value -or $value -eq '') { return $fallback }
    return $value
}

function Emit-Result {
    $elapsed = [int]((Get-Date) - $script:Start).TotalSeconds
    Write-OpsLog -Level INFO -Message ("[RESULT] status={0} rounds={1} elapsed={2}s consec={3}" -f `
        $script:Status, $script:Rounds, $elapsed, $script:Consec)
}

function Invoke-ParseFail([string]$Message) {
    Write-OpsLog -Level ERROR -Message $Message
    $script:Status = 'failed'
    Emit-Result
    exit 2
}

if (-not $TargetList) {
    Write-Error 'Usage: ServiceWait.ps1 -TargetList <path>'
    exit 1
}

$cfg = Get-OpsConfig -Name 'service_wait'

$initialWait     = [int](_Default $cfg['initial_wait_sec']      0)
$interval        = [int](_Default $cfg['interval_sec']          5)
$successN        = [int](_Default $cfg['success_threshold']     3)
$timeoutSec      = [int](_Default $cfg['timeout_sec']           600)
$defaultPerCheck = [int](_Default $cfg['per_check_timeout_sec'] 5)

# Test hooks
if ($env:OPS_OVERRIDE_INITIAL_WAIT_SEC)  { $initialWait = [int]$env:OPS_OVERRIDE_INITIAL_WAIT_SEC }
if ($env:OPS_OVERRIDE_INTERVAL_SEC)      { $interval    = [int]$env:OPS_OVERRIDE_INTERVAL_SEC }
if ($env:OPS_OVERRIDE_TIMEOUT_SEC)       { $timeoutSec  = [int]$env:OPS_OVERRIDE_TIMEOUT_SEC }
if ($env:OPS_OVERRIDE_SUCCESS_THRESHOLD) { $successN    = [int]$env:OPS_OVERRIDE_SUCCESS_THRESHOLD }

if ($cfg['LogFile']) {
    try { Set-OpsLogConfig -File $cfg['LogFile'] -Level (_Default $cfg['LogLevel'] 'INFO') } catch { }
}

if (-not (Test-Path -LiteralPath $TargetList -PathType Leaf)) {
    Invoke-ParseFail "Target list file not found: $TargetList"
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
        Invoke-ParseFail "List parse error: line=$lineno reason=need_3_cols raw='$line'"
    }
    $t = @{ type = $cols[0]; target = $cols[1]; desc = $cols[2]; per_check = $defaultPerCheck }

    if ($t.type -notin @('ping','tcp','http')) {
        Invoke-ParseFail "List parse error: line=$lineno reason=unknown_type type='$($t.type)'"
    }
    if ($t.type -eq 'tcp' -and $t.target -notmatch ':\d+$') {
        Invoke-ParseFail "List parse error: line=$lineno reason=tcp_needs_host_port target='$($t.target)'"
    }
    if ($t.type -eq 'http' -and $t.target -notmatch '^(http|https)://') {
        Invoke-ParseFail "List parse error: line=$lineno reason=http_needs_url target='$($t.target)'"
    }

    # Columns 4..end may carry key=value tokens (space-separated within a column).
    if ($cols.Count -ge 4) {
        $extra = ($cols[3..($cols.Count - 1)] -join ' ').Trim()
        foreach ($kv in ($extra -split '\s+' | Where-Object { $_ })) {
            $m = [regex]::Match($kv, '^([^=]+)=(.*)$')
            if (-not $m.Success) {
                Invoke-ParseFail "List parse error: line=$lineno reason=bad_token token='$kv'"
            }
            $key = $m.Groups[1].Value
            $val = $m.Groups[2].Value
            switch ($key) {
                'per_check_timeout_sec' {
                    if ($val -notmatch '^\d+$') {
                        Invoke-ParseFail "List parse error: line=$lineno reason=bad_per_check value='$val'"
                    }
                    $t.per_check = [int]$val
                }
                default {
                    Invoke-ParseFail "List parse error: line=$lineno reason=unknown_key key='$key'"
                }
            }
        }
    }
    $targets.Add($t) | Out-Null
}

if ($targets.Count -eq 0) {
    Invoke-ParseFail "Target list is empty: $TargetList"
}

Write-OpsLog -Level INFO -Message ("start targets={0} timeout={1} success={2} interval={3} initial={4}" -f `
    $targets.Count, $timeoutSec, $successN, $interval, $initialWait)

function Test-PingHost {
    param([string]$HostName, [int]$TimeoutSec)
    $p = $null
    try {
        $p = New-Object System.Net.NetworkInformation.Ping
        $r = $p.Send($HostName, ($TimeoutSec * 1000))
        return $r.Status -eq 'Success'
    } catch {
        return $false
    } finally {
        if ($p) { $p.Dispose() }
    }
}

function Test-TcpEndpoint {
    param([string]$Target, [int]$TimeoutSec)
    $h, $p = $Target -split ':', 2
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $task   = $client.ConnectAsync($h, [int]$p)
        if ($task.Wait([TimeSpan]::FromSeconds($TimeoutSec))) {
            return $client.Connected
        }
        return $false
    } catch {
        return $false
    } finally {
        if ($client) { $client.Dispose() }
    }
}

function Test-HttpUrl {
    param([string]$Url, [int]$TimeoutSec)
    try {
        $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
        return ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300)
    } catch {
        return $false
    }
}

function Invoke-Check {
    param([hashtable]$T)
    switch ($T.type) {
        'ping' { return (Test-PingHost     -HostName $T.target -TimeoutSec $T.per_check) }
        'tcp'  { return (Test-TcpEndpoint  -Target   $T.target -TimeoutSec $T.per_check) }
        'http' { return (Test-HttpUrl      -Url      $T.target -TimeoutSec $T.per_check) }
        default { return $false }
    }
}

Start-Sleep -Seconds $initialWait
$deadline = $script:Start.AddSeconds($timeoutSec)

try {
    while ((Get-Date) -lt $deadline) {
        $script:Rounds++
        $roundOk = $true
        foreach ($t in $targets) {
            if (Invoke-Check -T $t) {
                Write-OpsLog -Level INFO -Message ("[ROUND {0}] {1} {2} -> OK (desc={3})" -f $script:Rounds, $t.type, $t.target, $t.desc)
            } else {
                Write-OpsLog -Level WARN -Message ("[ROUND {0}] {1} {2} -> NG (desc={3})" -f $script:Rounds, $t.type, $t.target, $t.desc)
                $roundOk = $false
            }
        }

        if ($roundOk) { $script:Consec++ } else { $script:Consec = 0 }
        $verdict = if ($roundOk) { 'PASS' } else { 'FAIL' }
        Write-OpsLog -Level INFO -Message ("[ROUND {0}] {1} consec={2}/{3}" -f $script:Rounds, $verdict, $script:Consec, $successN)

        if ($script:Consec -ge $successN) {
            $script:Status = 'success'
            Emit-Result
            exit 0
        }

        $remain = ($deadline - (Get-Date)).TotalSeconds
        if ($remain -le 0) { break }
        $sleepN = [Math]::Min($interval, [int][Math]::Ceiling($remain))
        Start-Sleep -Seconds $sleepN
    }
} finally {
    if ($script:Status -eq 'unknown') { $script:Status = 'timeout' }
    Emit-Result
}
exit 3
