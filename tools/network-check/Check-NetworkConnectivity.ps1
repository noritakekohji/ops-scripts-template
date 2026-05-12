#Requires -Version 5.1
<#
.SYNOPSIS
    Check network connectivity (DNS / Ping / TCP port) for multiple targets.

.PARAMETER TargetList
    Path to the target list file.
    Format: <host>, <port>, <description>

.PARAMETER PingCount
    Number of ping attempts per target. Default: 3

.PARAMETER TimeoutSec
    Timeout in seconds for ping and TCP checks. Default: 3

.PARAMETER HtmlReport
    Path for the HTML report file. If omitted, console output only.

.PARAMETER FailOnly
    Show only targets that have at least one failure or warning.

.EXAMPLE
    .\Check-NetworkConnectivity.ps1 -TargetList targets.lst
    .\Check-NetworkConnectivity.ps1 -TargetList targets.lst -HtmlReport report.html
    .\Check-NetworkConnectivity.ps1 -TargetList targets.lst -FailOnly
    .\Check-NetworkConnectivity.ps1 -TargetList targets.lst -PingCount 5 -TimeoutSec 5
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TargetList,
    [int]$PingCount    = 3,
    [int]$TimeoutSec   = 3,
    [string]$HtmlReport = '',
    [switch]$FailOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Start log transcript if launched from the .bat file (OPS_LOG_FILE env var)
if ($env:OPS_LOG_FILE) {
    Start-Transcript -Path $env:OPS_LOG_FILE -Force -Append -ErrorAction SilentlyContinue | Out-Null
}

# ============================================================
# List file parser
# ============================================================

function Read-TargetList([string]$Path) {
    $targets = @()
    Get-Content $Path -Encoding UTF8 | ForEach-Object {
        $line = ($_ -replace '#.*$', '').Trim()   # strip inline comments
        if (-not $line) { return }
        $parts = $line -split ',', 3
        $h     = $parts[0].Trim()
        $p     = if ($parts.Count -ge 2) { $parts[1].Trim() } else { '' }
        $d     = if ($parts.Count -ge 3) { $parts[2].Trim() } else { $h }
        if (-not $h) { return }
        $portNum = $null
        if ($p -and $p -ne '-') {
            $n = 0
            if ([int]::TryParse($p, [ref]$n) -and $n -gt 0 -and $n -le 65535) { $portNum = $n }
        }
        $targets += @{ host = $h; port = $portNum; description = if ($d) { $d } else { $h } }
    }
    return $targets
}

# ============================================================
# Check functions
# ============================================================

function Test-DnsHost([string]$Target) {
    # Skip if IP address
    $ipObj = $null
    if ([System.Net.IPAddress]::TryParse($Target, [ref]$ipObj)) {
        return @{ status = 'na'; addresses = @($Target); error = '' }
    }
    try {
        $addrs = @([System.Net.Dns]::GetHostAddresses($Target) |
            ForEach-Object { $_.ToString() } | Sort-Object -Unique)
        return @{ status = 'ok'; addresses = $addrs; error = '' }
    } catch {
        $msg = $_.Exception.Message -replace '\r?\n', ' '
        return @{ status = 'fail'; addresses = @(); error = $msg }
    }
}

function Test-PingHost([string]$Target, [int]$Count, [int]$TimeoutMs) {
    $sent  = $Count
    $recv  = 0
    $rtts  = @()
    $pinger = New-Object System.Net.NetworkInformation.Ping
    for ($i = 0; $i -lt $Count; $i++) {
        try {
            $reply = $pinger.Send($Target, $TimeoutMs)
            if ($reply -and $reply.Status -eq 'Success') {
                $recv++
                $rtts += $reply.RoundtripTime
            }
        } catch {}
    }
    $pinger.Dispose()
    $avgRtt = if ($rtts.Count -gt 0) { [math]::Round(($rtts | Measure-Object -Average).Average, 0) } else { $null }
    $st = if ($recv -eq $sent) { 'ok' } elseif ($recv -gt 0) { 'partial' } else { 'fail' }
    return @{ status = $st; sent = $sent; recv = $recv; avg_rtt = $avgRtt }
}

function Test-TcpHost([string]$Target, [int]$Port, [int]$TimeoutMs) {
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $ar   = $tcp.BeginConnect($Target, $Port, $null, $null)
        $done = $ar.AsyncWaitHandle.WaitOne($TimeoutMs)
        if ($done) {
            try { $tcp.EndConnect($ar) } catch {
                return @{ status = 'fail'; error = $_.Exception.Message -replace '\r?\n', ' ' }
            }
            return @{ status = 'ok'; error = '' }
        } else {
            return @{ status = 'fail'; error = 'Timeout' }
        }
    } catch {
        return @{ status = 'fail'; error = $_.Exception.Message -replace '\r?\n', ' ' }
    } finally {
        $tcp.Close()
    }
}

# ============================================================
# Overall status
# ============================================================

function Get-OverallStatus($dns, $ping, $tcp) {
    $statuses = @($dns.status, $ping.status)
    if ($null -ne $tcp) { $statuses += $tcp.status }
    $statuses = $statuses | Where-Object { $_ -ne 'na' }
    if ($statuses -contains 'fail')    { return 'fail' }
    if ($statuses -contains 'partial') { return 'warn' }
    return 'ok'
}

# ============================================================
# Console output
# ============================================================

function Write-ResultConsole($r) {
    $overall = $r.overall
    $badge   = switch ($overall) { 'ok' { 'OK  ' } 'warn' { 'WARN' } 'fail' { 'FAIL' } }
    $color   = switch ($overall) { 'ok' { 'Green' } 'warn' { 'Yellow' } 'fail' { 'Red' } }

    Write-Host ("[{0}] {1,-25} {2}" -f $badge, $r.host, $r.description) -ForegroundColor $color

    # DNS
    $dns = $r.dns
    $dnsLine = switch ($dns.status) {
        'ok'   { "✓  $($dns.addresses -join ', ')" }
        'fail' { "✗  $($dns.error)" }
        'na'   { "─  N/A (IP address)" }
    }
    $dnsColor = switch ($dns.status) { 'ok' { 'Green' } 'fail' { 'Red' } default { 'DarkGray' } }
    Write-Host "       DNS  : $dnsLine" -ForegroundColor $dnsColor

    # Ping
    $ping = $r.ping
    $pingRtt = if ($null -ne $ping.avg_rtt) { "$($ping.avg_rtt)ms avg " } else { '' }
    $pingLine = switch ($ping.status) {
        'ok'      { "✓  $($pingRtt)($($ping.recv)/$($ping.sent))" }
        'partial' { "⚠  $($pingRtt)($($ping.recv)/$($ping.sent))" }
        'fail'    { "✗  ($($ping.recv)/$($ping.sent))" }
    }
    $pingColor = switch ($ping.status) { 'ok' { 'Green' } 'partial' { 'Yellow' } 'fail' { 'Red' } }
    Write-Host "       Ping : $pingLine" -ForegroundColor $pingColor

    # TCP
    if ($null -ne $r.tcp) {
        $tcp = $r.tcp
        $tcpLine = switch ($tcp.status) {
            'ok'   { "✓  $($r.port)/TCP connected" }
            'fail' { "✗  $($r.port)/TCP - $($tcp.error)" }
        }
        $tcpColor = if ($tcp.status -eq 'ok') { 'Green' } else { 'Red' }
        Write-Host "       Port : $tcpLine" -ForegroundColor $tcpColor
    } else {
        Write-Host "       Port : ─  N/A" -ForegroundColor DarkGray
    }
}

# ============================================================
# HTML report
# ============================================================

function New-HtmlReport($results, $meta) {
    $ok      = @($results | Where-Object { $_.overall -eq 'ok'   }).Count
    $warn    = @($results | Where-Object { $_.overall -eq 'warn' }).Count
    $fail    = @($results | Where-Object { $_.overall -eq 'fail' }).Count
    $total   = $results.Count
    $genTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    function Status-Badge([string]$st) {
        switch ($st) {
            'ok'      { "<span class='badge ok'>OK</span>" }
            'partial' { "<span class='badge warn'>PARTIAL</span>" }
            'fail'    { "<span class='badge fail'>FAIL</span>" }
            'na'      { "<span class='badge na'>N/A</span>" }
            default   { "<span class='badge na'>$st</span>" }
        }
    }

    function HE([string]$s) {
        try { [System.Net.WebUtility]::HtmlEncode($s) }
        catch { $s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' }
    }

    $rows = foreach ($r in $results) {
        $overallBadge = switch ($r.overall) {
            'ok'   { "<span class='badge ok'>OK</span>" }
            'warn' { "<span class='badge warn'>WARN</span>" }
            'fail' { "<span class='badge fail'>FAIL</span>" }
        }
        $rowClass = switch ($r.overall) { 'ok' { 'row-ok' } 'warn' { 'row-warn' } 'fail' { 'row-fail' } }

        # DNS cell
        $dnsCell = switch ($r.dns.status) {
            'ok'   { (Status-Badge 'ok')   + " " + (HE ($r.dns.addresses -join ', ')) }
            'fail' { (Status-Badge 'fail') + " " + (HE $r.dns.error) }
            'na'   { (Status-Badge 'na')   + " IP address" }
        }

        # Ping cell
        $pingRtt = if ($null -ne $r.ping.avg_rtt) { "$($r.ping.avg_rtt)ms " } else { '' }
        $pingCell = switch ($r.ping.status) {
            'ok'      { (Status-Badge 'ok')      + " $($pingRtt)($($r.ping.recv)/$($r.ping.sent))" }
            'partial' { (Status-Badge 'partial') + " $($pingRtt)($($r.ping.recv)/$($r.ping.sent))" }
            'fail'    { (Status-Badge 'fail')    + " ($($r.ping.recv)/$($r.ping.sent))" }
        }

        # TCP cell
        $tcpCell = if ($null -ne $r.tcp) {
            switch ($r.tcp.status) {
                'ok'   { (Status-Badge 'ok')   + " $($r.port)/TCP" }
                'fail' { (Status-Badge 'fail') + " $($r.port)/TCP $(HE $r.tcp.error)" }
            }
        } else {
            Status-Badge 'na'
        }

        "<tr class='$rowClass'><td>$(HE $r.host)</td><td>$(HE $r.description)</td><td>$dnsCell</td><td>$pingCell</td><td>$tcpCell</td><td>$overallBadge</td></tr>"
    }

    return @"
<!DOCTYPE html><html lang="ja"><head><meta charset="UTF-8">
<title>Network Connectivity Check</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Segoe UI',Arial,sans-serif;font-size:13px;background:#f0f2f5;color:#222}
.header{background:#1e293b;color:#fff;padding:20px 24px}
.header h1{font-size:20px;font-weight:600}
.header .sub{font-size:12px;color:#94a3b8;margin-top:4px}
.meta{display:flex;gap:12px;padding:16px 24px;flex-wrap:wrap}
.meta-item{background:#fff;border-radius:8px;padding:10px 16px;font-size:12px;box-shadow:0 1px 3px rgba(0,0,0,.1)}
.meta-item .label{color:#64748b;margin-right:6px}
.summary{display:flex;gap:12px;padding:0 24px 16px;flex-wrap:wrap}
.card{background:#fff;border-radius:8px;padding:16px 20px;text-align:center;flex:1;min-width:100px;box-shadow:0 1px 3px rgba(0,0,0,.1)}
.card .num{font-size:28px;font-weight:700}.card .lbl{font-size:11px;color:#64748b;margin-top:2px}
.card.total .num{color:#1e293b}.card.ok .num{color:#16a34a}.card.warn .num{color:#d97706}.card.fail .num{color:#dc2626}
.filter-bar{padding:8px 24px;display:flex;gap:8px;align-items:center}
.filter-bar label{font-size:12px;color:#64748b;margin-right:4px}
.filter-bar button{font-size:12px;padding:4px 12px;border:1px solid #cbd5e1;border-radius:4px;background:#fff;cursor:pointer}
.filter-bar button.active{background:#1e293b;color:#fff;border-color:#1e293b}
.table-wrap{margin:0 24px 24px;background:#fff;border-radius:8px;box-shadow:0 1px 3px rgba(0,0,0,.1);overflow-x:auto}
table{width:100%;border-collapse:collapse;font-size:12px}
th{background:#f1f5f9;padding:8px 12px;text-align:left;font-weight:600;color:#475569;border-bottom:2px solid #e2e8f0}
td{padding:7px 12px;border-bottom:1px solid #f1f5f9;vertical-align:middle}
tr:last-child td{border-bottom:none}
tr.row-ok{background:#fff}
tr.row-warn{background:#fffbeb}
tr.row-fail{background:#fff1f2}
.badge{display:inline-block;font-size:11px;padding:2px 7px;border-radius:4px;font-weight:600;white-space:nowrap}
.badge.ok{background:#dcfce7;color:#15803d}
.badge.warn{background:#fef3c7;color:#92400e}
.badge.fail{background:#fee2e2;color:#b91c1c}
.badge.na{background:#f1f5f9;color:#64748b}
td:first-child{font-family:monospace;font-weight:600}
.footer{text-align:center;padding:16px;font-size:11px;color:#94a3b8}
.hidden{display:none}
</style></head><body>
<div class="header">
  <h1>&#127760; Network Connectivity Check</h1>
  <div class="sub">Generated: $genTime</div>
</div>
<div class="meta">
  <div class="meta-item"><span class="label">Target list:</span>$(HE $meta.listFile)</div>
  <div class="meta-item"><span class="label">Ping count:</span>$($meta.pingCount)</div>
  <div class="meta-item"><span class="label">Timeout:</span>$($meta.timeout)s</div>
  <div class="meta-item"><span class="label">Executed:</span>$(HE $meta.hostname)</div>
</div>
<div class="summary">
  <div class="card total"><div class="num">$total</div><div class="lbl">Total</div></div>
  <div class="card ok">   <div class="num">$ok</div><div class="lbl">OK</div></div>
  <div class="card warn"> <div class="num">$warn</div><div class="lbl">Warning</div></div>
  <div class="card fail"> <div class="num">$fail</div><div class="lbl">Failed</div></div>
</div>
<div class="filter-bar">
  <label>Show:</label>
  <button class="active" onclick="filter('all',this)">All</button>
  <button onclick="filter('ok',this)">OK</button>
  <button onclick="filter('warn',this)">Warning</button>
  <button onclick="filter('fail',this)">Failed</button>
</div>
<div class="table-wrap">
<table>
  <thead><tr><th>Host</th><th>Description</th><th>DNS</th><th>Ping</th><th>Port (TCP)</th><th>Status</th></tr></thead>
  <tbody>$($rows -join "`n")</tbody>
</table>
</div>
<div class="footer">Check-NetworkConnectivity.ps1 &bull; $genTime</div>
<script>
function filter(mode,btn){
  document.querySelectorAll('.filter-bar button').forEach(b=>b.classList.remove('active'));
  btn.classList.add('active');
  document.querySelectorAll('tbody tr').forEach(row=>{
    var show = mode==='all'
      || (mode==='ok'   && row.classList.contains('row-ok'))
      || (mode==='warn' && row.classList.contains('row-warn'))
      || (mode==='fail' && row.classList.contains('row-fail'));
    row.classList.toggle('hidden',!show);
  });
}
</script></body></html>
"@
}

# ============================================================
# Main
# ============================================================
try {
    if (-not (Test-Path -LiteralPath $TargetList)) {
        Write-Error "Target list not found: $TargetList"
        exit 2
    }

    $targets = Read-TargetList $TargetList
    if ($targets.Count -eq 0) {
        Write-Warning "No targets found in $TargetList"
        exit 0
    }

    $timeoutMs = $TimeoutSec * 1000

    Write-Host ''
    Write-Host '=== Network Connectivity Check ===' -ForegroundColor Cyan
    Write-Host "  List    : $TargetList"
    Write-Host "  Targets : $($targets.Count)"
    Write-Host "  Ping    : $PingCount packets / ${TimeoutSec}s timeout"
    Write-Host ''

    $results = @()
    foreach ($t in $targets) {
        $dns  = Test-DnsHost $t.host
        # Use resolved IP for ping/TCP if DNS succeeded and original is hostname
        $pingTarget = if ($dns.status -eq 'ok' -and $dns.addresses.Count -gt 0) { $dns.addresses[0] } else { $t.host }
        $ping = Test-PingHost $pingTarget $PingCount $timeoutMs
        $tcp  = if ($null -ne $t.port) { Test-TcpHost $pingTarget $t.port $timeoutMs } else { $null }

        $r = @{
            host        = $t.host
            port        = $t.port
            description = $t.description
            dns         = $dns
            ping        = $ping
            tcp         = $tcp
            overall     = (Get-OverallStatus $dns $ping $tcp)
        }
        $results += $r

        if (-not $FailOnly -or $r.overall -ne 'ok') {
            Write-ResultConsole $r
        }
    }

    # Summary
    $okCount   = @($results | Where-Object { $_.overall -eq 'ok'   }).Count
    $warnCount = @($results | Where-Object { $_.overall -eq 'warn' }).Count
    $failCount = @($results | Where-Object { $_.overall -eq 'fail' }).Count

    Write-Host ''
    Write-Host ('─' * 50)
    Write-Host "  Total: $($results.Count)   " -NoNewline
    Write-Host "OK: $okCount   " -ForegroundColor Green -NoNewline
    Write-Host "Warning: $warnCount   " -ForegroundColor Yellow -NoNewline
    Write-Host "Failed: $failCount" -ForegroundColor Red
    Write-Host ''

    # HTML
    if ($HtmlReport) {
        $htmlDir = Split-Path -Parent $HtmlReport
        if ($htmlDir -and -not (Test-Path $htmlDir)) { New-Item -ItemType Directory -Path $htmlDir -Force | Out-Null }
        $meta = @{
            listFile  = $TargetList
            pingCount = $PingCount
            timeout   = $TimeoutSec
            hostname  = $env:COMPUTERNAME
        }
        $html = New-HtmlReport $results $meta
        [System.IO.File]::WriteAllText($HtmlReport, $html, [System.Text.Encoding]::UTF8)
        Write-Host "  HTML report: $HtmlReport" -ForegroundColor Green
    }

    exit $(if ($failCount -gt 0) { 1 } else { 0 })
}
catch {
    Write-Error "Failed: $($_.Exception.Message)"
    exit 4
}
