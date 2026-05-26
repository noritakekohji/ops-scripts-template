#Requires -Version 5.1
<#
.SYNOPSIS
    Check network connectivity (DNS / Ping / TCP port) for multiple targets.

.DESCRIPTION
    Lines in the target list are grouped by host.
    DNS and Ping run ONCE per unique host.
    TCP port checks run once per service (line).

.PARAMETER TargetList
    Path to the target list file.

    4-field format (with evaluation):
      <host>, <port>, <expected>, <description>
      <expected>: ok (expect reachable) / ng (expect unreachable) / - (no eval)

    3-field format (backward compatible, no evaluation):
      <host>, <port>, <description>

.PARAMETER PingCount
    Number of ping attempts per host. Default: 3

.PARAMETER TimeoutSec
    Timeout in seconds for ping and TCP checks. Default: 3

.PARAMETER HtmlReport
    Path for the HTML report file. If omitted, console output only.

.PARAMETER FailOnly
    Show only services with failure/warning, or evaluation FAIL.

.EXAMPLE
    .\Check-NetworkConnectivity.ps1 -TargetList targets.lst
    .\Check-NetworkConnectivity.ps1 -TargetList targets.lst -HtmlReport report.html
    .\Check-NetworkConnectivity.ps1 -TargetList targets.lst -FailOnly
    .\Check-NetworkConnectivity.ps1 -TargetList targets.lst -PingCount 5 -TimeoutSec 5

.NOTES
    DNS fail -> Ping SKIP, TCP SKIP for all services under that host.
    Evaluation when DNS failed: expected=ok -> FAIL, expected=ng -> SKIP.

    When any service is NG/WARN, an investigation file is automatically generated:
      network_investigation_<timestamp>.txt
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
# List file parser — returns ordered list of host entries
# ============================================================

function Read-TargetList([string]$Path) {
    $hostMap   = [ordered]@{}
    $hostOrder = [System.Collections.Generic.List[string]]::new()

    Get-Content $Path -Encoding UTF8 | ForEach-Object {
        $line = ($_ -replace '#.*$', '').Trim()
        if (-not $line) { return }

        $parts = $line -split ',', 4
        $h = $parts[0].Trim()
        if (-not $h) { return }

        $p = if ($parts.Count -ge 2) { $parts[1].Trim() } else { '' }

        # Detect 3-field vs 4-field
        $expected = '-'
        $d        = $h

        if ($parts.Count -ge 4) {
            # 4-field: host, port, expected, description
            $rawExp  = $parts[2].Trim().ToLower()
            $expected = if ($rawExp -in @('ok','ng','-')) { $rawExp } else { '-' }
            $d = $parts[3].Trim()
        } elseif ($parts.Count -ge 3) {
            $rawF3 = $parts[2].Trim().ToLower()
            if ($rawF3 -in @('ok','ng','-')) {
                # keyword only, description omitted
                $expected = $rawF3
                $d = ''
            } else {
                # 3-field: description
                $d = $parts[2].Trim()
            }
        }
        if (-not $d) { $d = $h }

        # Parse port
        $portNum = $null
        if ($p -and $p -ne '-') {
            $n = 0
            if ([int]::TryParse($p, [ref]$n) -and $n -gt 0 -and $n -le 65535) { $portNum = $n }
        }

        # Register host if new
        if (-not $hostMap.Contains($h)) {
            $hostMap[$h] = @{
                host     = $h
                services = [System.Collections.Generic.List[hashtable]]::new()
            }
            $hostOrder.Add($h)
        }
        $hostMap[$h].services.Add(@{
            port        = $portNum
            expected    = $expected
            description = $d
        })
    }

    return @($hostOrder | ForEach-Object { $hostMap[$_] })
}

# ============================================================
# Check functions
# ============================================================

function Test-DnsHost([string]$Target) {
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
    $sent   = $Count
    $recv   = 0
    $rtts   = @()
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
# Per-service overall status and evaluation
# ============================================================

function Get-ServiceOverall([string]$DnsSt, $Ping, $Tcp) {
    if ($DnsSt -eq 'fail') { return 'fail' }
    $statuses = @($Ping.status)
    if ($null -ne $Tcp) { $statuses += $Tcp.status }
    $statuses = $statuses | Where-Object { $_ -notin @('na','skip') }
    if ($statuses -contains 'fail')    { return 'fail' }
    if ($statuses -contains 'partial') { return 'warn' }
    return 'ok'
}

# Evaluation truth table — see .NOTES
function Get-EvalResult([string]$DnsSt, [string]$Expected, $Tcp, $Ping, $Port) {
    if (-not $Expected -or $Expected -eq '-') { return '-' }

    # DNS failed
    if ($DnsSt -eq 'fail') {
        if ($Expected -eq 'ok') { return 'FAIL' } else { return 'SKIP' }
    }

    # For ping-only lines (no port), evaluate against ping; otherwise TCP
    $checkSt = if ($null -ne $Port) {
        if ($null -ne $Tcp) { $Tcp.status } else { 'skip' }
    } else {
        $Ping.status
    }

    if ($Expected -eq 'ok') {
        if ($checkSt -eq 'ok') { return 'PASS' } else { return 'FAIL' }
    } else {
        # ng: PASS when NOT reachable
        if ($checkSt -ne 'ok') { return 'PASS' } else { return 'FAIL' }
    }
}

# ============================================================
# HTML report
# ============================================================

function New-HtmlReport($hostResults, $meta, [bool]$HasEval) {
    $allSvcs = @(
        foreach ($h in $hostResults) {
            foreach ($svc in $h.services) { @{ h = $h; svc = $svc } }
        }
    )

    $ok            = @($allSvcs | Where-Object { $_.svc.overall -eq 'ok'   }).Count
    $warn          = @($allSvcs | Where-Object { $_.svc.overall -eq 'warn' }).Count
    $fail          = @($allSvcs | Where-Object { $_.svc.overall -eq 'fail' }).Count
    $total         = $allSvcs.Count
    $passCount     = @($allSvcs | Where-Object { $_.svc.eval_result -eq 'PASS' }).Count
    $evalFailCount = @($allSvcs | Where-Object { $_.svc.eval_result -eq 'FAIL' }).Count
    $evalSkipCount = @($allSvcs | Where-Object { $_.svc.eval_result -eq 'SKIP' }).Count
    $genTime       = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    function SB([string]$st) {
        switch ($st) {
            'ok'      { "<span class='badge ok'>OK</span>" }
            'partial' { "<span class='badge warn'>PARTIAL</span>" }
            'fail'    { "<span class='badge fail'>FAIL</span>" }
            'skip'    { "<span class='badge na'>SKIP</span>" }
            default   { "<span class='badge na'>N/A</span>" }
        }
    }
    function EB([string]$er) {
        switch ($er) {
            'PASS' { "<span class='badge eval-pass'>PASS ✓</span>" }
            'FAIL' { "<span class='badge eval-fail'>FAIL ✗</span>" }
            'SKIP' { "<span class='badge eval-skip'>SKIP</span>" }
            default { "<span class='badge na'>—</span>" }
        }
    }
    function HE([string]$s) {
        try { [System.Net.WebUtility]::HtmlEncode($s) }
        catch { $s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' }
    }

    $rows = foreach ($pair in $allSvcs) {
        $h   = $pair.h
        $svc = $pair.svc
        $dns  = $h.dns
        $ping = $h.ping
        $rc   = switch ($svc.overall) { 'ok' {'row-ok'} 'warn' {'row-warn'} 'fail' {'row-fail'} default {''} }

        # DNS cell (host-level, shared for all services of this host)
        $dnsCell = switch ($dns.status) {
            'ok'   { (SB 'ok')   + ' ' + (HE ($dns.addresses -join ', ')) }
            'fail' { (SB 'fail') + ' ' + (HE $dns.error) }
            default { (SB 'na') + ' IP address' }
        }

        # Ping cell (host-level)
        $pRtt  = if ($null -ne $ping.avg_rtt) { "$($ping.avg_rtt)ms " } else { '' }
        $pingCell = switch ($ping.status) {
            'ok'      { (SB 'ok')      + " $($pRtt)($($ping.recv)/$($ping.sent))" }
            'partial' { (SB 'partial') + " $($pRtt)($($ping.recv)/$($ping.sent))" }
            'fail'    { (SB 'fail')    + " ($($ping.recv)/$($ping.sent))" }
            default   { SB 'skip' }
        }

        # TCP cell (service-level)
        $tcpCell = if ($null -ne $svc.tcp) {
            switch ($svc.tcp.status) {
                'ok'   { (SB 'ok')   + " port $($svc.port)/TCP" }
                'fail' { (SB 'fail') + " port $($svc.port)/TCP &nbsp;$(HE $svc.tcp.error)" }
                default { (SB 'skip') + ' DNS failed' }
            }
        } else { SB 'na' }

        $obadge = switch ($svc.overall) {
            'ok'   { "<span class='badge ok'>OK</span>" }
            'warn' { "<span class='badge warn'>WARN</span>" }
            'fail' { "<span class='badge fail'>FAIL</span>" }
            default { "<span class='badge na'>$($svc.overall)</span>" }
        }

        $evalCols = if ($HasEval) {
            $expHtml = if ($svc.expected -and $svc.expected -ne '-') { HE $svc.expected.ToUpper() } else { '—' }
            "<td>$expHtml</td><td>$(EB $svc.eval_result)</td>"
        } else { '' }

        "<tr class='$rc'><td>$(HE $h.host)</td><td>$(HE $svc.description)</td>" +
        "<td>$dnsCell</td><td>$pingCell</td><td>$tcpCell</td><td>$obadge</td>$evalCols</tr>"
    }

    $evalHeaders = if ($HasEval) { '<th>Expected</th><th>Evaluation</th>' } else { '' }
    $evalCards   = if ($HasEval) {
        "  <div class='card eval-pass'><div class='num'>$passCount</div><div class='lbl'>PASS</div></div>`n" +
        "  <div class='card eval-fail'><div class='num'>$evalFailCount</div><div class='lbl'>Eval FAIL</div></div>`n" +
        "  <div class='card eval-skip'><div class='num'>$evalSkipCount</div><div class='lbl'>Eval SKIP</div></div>"
    } else { '' }
    $evalFilterBtn = if ($HasEval) { '<button onclick="filterEvalFail(this)">Eval FAIL</button>' } else { '' }

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
.card.eval-pass .num{color:#16a34a}.card.eval-fail .num{color:#dc2626}.card.eval-skip .num{color:#94a3b8}
.filter-bar{padding:8px 24px;display:flex;gap:8px;align-items:center;flex-wrap:wrap}
.filter-bar label{font-size:12px;color:#64748b;margin-right:4px}
.filter-bar button{font-size:12px;padding:4px 12px;border:1px solid #cbd5e1;border-radius:4px;background:#fff;cursor:pointer}
.filter-bar button.active{background:#1e293b;color:#fff;border-color:#1e293b}
.table-wrap{margin:0 24px 24px;background:#fff;border-radius:8px;box-shadow:0 1px 3px rgba(0,0,0,.1);overflow-x:auto}
table{width:100%;border-collapse:collapse;font-size:12px}
th{background:#f1f5f9;padding:8px 12px;text-align:left;font-weight:600;color:#475569;border-bottom:2px solid #e2e8f0}
td{padding:7px 12px;border-bottom:1px solid #f1f5f9;vertical-align:middle}
tr:last-child td{border-bottom:none}
tr.row-ok{background:#fff}tr.row-warn{background:#fffbeb}tr.row-fail{background:#fff1f2}
.badge{display:inline-block;font-size:11px;padding:2px 7px;border-radius:4px;font-weight:600;white-space:nowrap}
.badge.ok{background:#dcfce7;color:#15803d}.badge.warn{background:#fef3c7;color:#92400e}
.badge.fail{background:#fee2e2;color:#b91c1c}.badge.na{background:#f1f5f9;color:#64748b}
.badge.eval-pass{background:#dcfce7;color:#15803d}
.badge.eval-fail{background:#fee2e2;color:#b91c1c}
.badge.eval-skip{background:#f1f5f9;color:#64748b}
td:first-child{font-family:monospace;font-weight:600}
.footer{text-align:center;padding:16px;font-size:11px;color:#94a3b8}.hidden{display:none}
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
$evalCards
</div>
<div class="filter-bar">
  <label>Show:</label>
  <button class="active" onclick="filterAll(this)">All</button>
  <button onclick="filterStatus('row-ok',this)">OK</button>
  <button onclick="filterStatus('row-warn',this)">Warning</button>
  <button onclick="filterStatus('row-fail',this)">Failed</button>
  $evalFilterBtn
</div>
<div class="table-wrap">
<table>
  <thead><tr><th>Host</th><th>Description</th><th>DNS</th><th>Ping</th><th>Port (TCP)</th><th>Status</th>$evalHeaders</tr></thead>
  <tbody>$($rows -join "`n")</tbody>
</table>
</div>
<div class="footer">Check-NetworkConnectivity.ps1 &bull; $genTime</div>
<script>
function filterAll(btn){
  document.querySelectorAll('.filter-bar button').forEach(b=>b.classList.remove('active'));
  btn.classList.add('active');
  document.querySelectorAll('tbody tr').forEach(r=>r.classList.remove('hidden'));
}
function filterStatus(cls,btn){
  document.querySelectorAll('.filter-bar button').forEach(b=>b.classList.remove('active'));
  btn.classList.add('active');
  document.querySelectorAll('tbody tr').forEach(r=>r.classList.toggle('hidden',!r.classList.contains(cls)));
}
function filterEvalFail(btn){
  document.querySelectorAll('.filter-bar button').forEach(b=>b.classList.remove('active'));
  btn.classList.add('active');
  document.querySelectorAll('tbody tr').forEach(r=>r.classList.toggle('hidden',!r.querySelector('.badge.eval-fail')));
}
</script></body></html>
"@
}

# ============================================================
# Investigation (called automatically for NG/WARN services)
# ============================================================

function Invoke-Investigation($hostResults, $outFile, $timeoutSec) {
    # Flatten NG/WARN services across all hosts
    $ngEntries = @(
        foreach ($h in $hostResults) {
            $pt = if ($h.dns.addresses.Count -gt 0) { $h.dns.addresses[0] } else { $h.host }
            foreach ($svc in $h.services) {
                if ($svc.overall -in @('fail','warn')) {
                    @{ host = $h.host; dns = $h.dns; ping = $h.ping; pt = $pt; svc = $svc }
                }
            }
        }
    )
    if ($ngEntries.Count -eq 0) { return }

    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host ''
    Write-Host "=== Collecting Investigation Info ($($ngEntries.Count) NG service(s)) ===" -ForegroundColor Cyan
    Write-Host "  Output: $outFile"
    Write-Host "  (tracert may take a while per host...)"

    $sep   = '=' * 64
    $dash  = '-' * 64
    $lines = [System.Collections.Generic.List[string]]::new()

    $lines.Add($sep)
    $lines.Add('  Network Investigation Report')
    $lines.Add("  Generated : $ts")
    $lines.Add("  Hostname  : $env:COMPUTERNAME")
    $lines.Add($sep)
    $lines.Add('')
    $lines.Add('## System Network Information')
    $lines.Add('')
    $lines.Add('### Network Adapters (ipconfig /all)')
    try   { $lines.Add((ipconfig /all 2>&1 | Out-String).TrimEnd()) }
    catch { $lines.Add('(Not available)') }
    $lines.Add('')
    $lines.Add('### Routing Table (route print)')
    try   { $lines.Add((route print 2>&1 | Out-String).TrimEnd()) }
    catch { $lines.Add('(Not available)') }
    $lines.Add('')
    $lines.Add('### DNS Client Server Addresses')
    try   { $lines.Add((Get-DnsClientServerAddress | Format-Table InterfaceAlias, ServerAddresses -AutoSize | Out-String).TrimEnd()) }
    catch { $lines.Add('(Not available)') }
    $lines.Add('')

    $idx = 0
    foreach ($entry in $ngEntries) {
        $idx++
        $dns  = $entry.dns
        $ping = $entry.ping
        $pt   = $entry.pt
        $svc  = $entry.svc

        $failLabels = [System.Collections.Generic.List[string]]::new()
        if ($dns.status  -eq 'fail')    { $failLabels.Add('DNS') }
        if ($ping.status -eq 'fail')    { $failLabels.Add('Ping') }
        if ($ping.status -eq 'partial') { $failLabels.Add('Ping(partial)') }
        if ($null -ne $svc.tcp -and $svc.tcp.status -eq 'fail') { $failLabels.Add('Port') }

        $lines.Add($sep)
        $lines.Add("[$idx] HOST: $($entry.host)  ($($svc.description))")
        $lines.Add("     Status: $($svc.overall.ToUpper())  NG items: $($failLabels -join ', ')")
        $lines.Add($dash)
        $lines.Add('')

        # DNS NG
        if ($dns.status -eq 'fail') {
            $lines.Add('### DNS Failure Investigation')
            $lines.Add("  Error: $($dns.error)")
            $lines.Add('')
            $hostsPath = [IO.Path]::Combine($env:SystemRoot, 'System32', 'drivers', 'etc', 'hosts')
            $lines.Add("#### hosts file ($hostsPath)")
            try   { $lines.Add((Get-Content $hostsPath -Encoding UTF8 -ErrorAction Stop | Out-String).TrimEnd()) }
            catch { $lines.Add('(Could not read hosts file)') }
            $lines.Add('')
            $lines.Add("#### nslookup: $($entry.host)")
            try   { $lines.Add((nslookup $entry.host 2>&1 | Out-String).TrimEnd()) }
            catch { $lines.Add('(nslookup failed)') }
            $lines.Add('')
        }

        # Ping NG
        if ($ping.status -in @('fail','partial')) {
            $waitMs = $timeoutSec * 1000
            $lines.Add('### Ping NG Investigation')
            $lines.Add('')
            $lines.Add("#### tracert: $pt")
            try   { $lines.Add((tracert -d -h 20 -w $waitMs $pt 2>&1 | Out-String).TrimEnd()) }
            catch { $lines.Add('(tracert failed)') }
            $lines.Add('')
        }

        # Port NG
        if ($null -ne $svc.tcp -and $svc.tcp.status -eq 'fail' -and $null -ne $svc.port) {
            $lines.Add('### Port NG Investigation')
            $lines.Add('')
            $lines.Add("#### Test-NetConnection: $pt port $($svc.port)")
            try {
                $tnc = Test-NetConnection -ComputerName $pt -Port $svc.port `
                    -InformationLevel Detailed -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
                $lines.Add(($tnc | Format-List | Out-String).TrimEnd())
            } catch {
                $lines.Add("(Test-NetConnection failed: $($_.Exception.Message))")
            }
            $lines.Add('')
        }
    }

    $lines.Add($sep)
    $lines.Add('  End of Investigation Report')
    $lines.Add($sep)

    $outDir = Split-Path -Parent $outFile
    if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    [System.IO.File]::WriteAllText(
        $outFile,
        ($lines -join [Environment]::NewLine) + [Environment]::NewLine,
        [System.Text.Encoding]::UTF8
    )
    Write-Host "  Investigation saved: $outFile" -ForegroundColor Green
}

# ============================================================
# Main
# ============================================================
try {
    if (-not (Test-Path -LiteralPath $TargetList)) {
        # $ErrorActionPreference = 'Stop' 下で Write-Error は throw するため、
        # 後続の exit 2 が実行されず終了コードが 1 になってしまう。
        # 直接 stderr に書いて exit 2 を確実に返す。
        [Console]::Error.WriteLine("[ERROR] Target list not found: $TargetList")
        exit 2
    }

    $hostEntries = Read-TargetList $TargetList
    if ($hostEntries.Count -eq 0) { Write-Warning "No targets found in $TargetList"; exit 0 }

    $timeoutMs     = $TimeoutSec * 1000
    $okCount       = 0; $warnCount  = 0; $failCount     = 0; $totalCount = 0
    $passCount     = 0; $evalFailCount = 0; $evalSkipCount = 0
    $hasEval       = $false

    Write-Host ''
    Write-Host '=== Network Connectivity Check ===' -ForegroundColor Cyan
    Write-Host "  List    : $TargetList"
    Write-Host "  Hosts   : $($hostEntries.Count)"
    Write-Host "  Ping    : $PingCount packets / ${TimeoutSec}s timeout"
    Write-Host ''

    $hostResults = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($hEntry in $hostEntries) {
        $hName = $hEntry.host   # NOTE: $Host is a PS automatic variable (read-only); use $hName

        # DNS — once per host
        $dns = Test-DnsHost $hName
        $pingTarget = if ($dns.status -eq 'ok' -and $dns.addresses.Count -gt 0) { $dns.addresses[0] } else { $hName }

        # Ping — once per host (skip if DNS failed)
        $ping = if ($dns.status -ne 'fail') {
            Test-PingHost $pingTarget $PingCount $timeoutMs
        } else {
            @{ status = 'skip'; sent = $PingCount; recv = 0; avg_rtt = $null }
        }

        # Console: HOST header
        Write-Host ''
        Write-Host "[HOST] $hName" -ForegroundColor White

        # DNS line
        switch ($dns.status) {
            'ok'   { Write-Host "       DNS  : $($dns.addresses -join ', ')" -ForegroundColor Green }
            'fail' { Write-Host "       DNS  : $($dns.error)" -ForegroundColor Red }
            'na'   { Write-Host "       DNS  : N/A (IP address)" -ForegroundColor DarkGray }
        }

        # Ping line
        $pRtt = if ($null -ne $ping.avg_rtt) { "$($ping.avg_rtt)ms avg " } else { '' }
        switch ($ping.status) {
            'ok'      { Write-Host "       Ping : $($pRtt)($($ping.recv)/$($ping.sent))" -ForegroundColor Green }
            'partial' { Write-Host "       Ping : $($pRtt)($($ping.recv)/$($ping.sent))" -ForegroundColor Yellow }
            'fail'    { Write-Host "       Ping : ($($ping.recv)/$($ping.sent))" -ForegroundColor Red }
            'skip'    { Write-Host "       Ping : Skip (DNS failed)" -ForegroundColor DarkGray }
        }

        $svcResults = [System.Collections.Generic.List[hashtable]]::new()

        foreach ($svc in $hEntry.services) {
            $totalCount++

            # TCP — per service (skip if DNS failed, null if ping-only)
            $tcp = if ($dns.status -eq 'fail') {
                @{ status = 'skip'; error = 'DNS failed' }
            } elseif ($null -ne $svc.port) {
                Test-TcpHost $pingTarget $svc.port $timeoutMs
            } else {
                $null
            }

            $overall    = Get-ServiceOverall $dns.status $ping $tcp
            $evalResult = Get-EvalResult $dns.status $svc.expected $tcp $ping $svc.port

            switch ($overall) { 'ok' { $okCount++ } 'warn' { $warnCount++ } 'fail' { $failCount++ } }
            if ($evalResult -ne '-') {
                $hasEval = $true
                switch ($evalResult) { 'PASS' { $passCount++ } 'FAIL' { $evalFailCount++ } 'SKIP' { $evalSkipCount++ } }
            }

            # Console service line
            $showLine = -not ($FailOnly -and $overall -eq 'ok' -and $evalResult -ne 'FAIL')
            if ($showLine) {
                $tcpText  = if ($null -eq $tcp)               { '[N/A ] Ping only' }
                            elseif ($tcp.status -eq 'ok')     { '[OK  ] Connected' }
                            elseif ($tcp.status -eq 'skip')   { '[SKIP] DNS failed' }
                            else                               { "[FAIL] $($tcp.error)" }
                $tcpColor = if ($null -eq $tcp -or $tcp.status -eq 'skip') { 'DarkGray' }
                            elseif ($tcp.status -eq 'ok')     { 'Green' }
                            else                               { 'Red' }

                $portLabel = if ($null -ne $svc.port) { "Port $($svc.port)/TCP " } else { 'Ping-only   ' }
                $lineText  = "       $portLabel $tcpText"

                if ($svc.expected -and $svc.expected -ne '-') {
                    $evalColor = switch ($evalResult) { 'PASS' { 'Green' } 'FAIL' { 'Red' } default { 'DarkGray' } }
                    Write-Host $lineText -ForegroundColor $tcpColor -NoNewline
                    Write-Host "    Expected $($svc.expected.ToUpper()) -> $evalResult" -ForegroundColor $evalColor -NoNewline
                    Write-Host "   $($svc.description)"
                } else {
                    Write-Host "$lineText   $($svc.description)" -ForegroundColor $tcpColor
                }
            }

            $svcResults.Add(@{
                port        = $svc.port
                description = $svc.description
                expected    = $svc.expected
                tcp         = $tcp
                overall     = $overall
                eval_result = $evalResult
            })
        }

        $hostResults.Add(@{
            host     = $hName
            dns      = $dns
            ping     = $ping
            services = $svcResults
        })
    }

    # Summary
    Write-Host ''
    Write-Host ('─' * 50)
    Write-Host "  Total: $totalCount   " -NoNewline
    Write-Host "OK: $okCount   "      -ForegroundColor Green  -NoNewline
    Write-Host "Warning: $warnCount   " -ForegroundColor Yellow -NoNewline
    Write-Host "Failed: $failCount"    -ForegroundColor Red
    if ($hasEval) {
        Write-Host '  Evaluation: ' -NoNewline
        Write-Host "PASS: $passCount"      -ForegroundColor Green   -NoNewline
        Write-Host ' / '                   -NoNewline
        Write-Host "FAIL: $evalFailCount"  -ForegroundColor Red     -NoNewline
        Write-Host ' / '                   -NoNewline
        Write-Host "SKIP: $evalSkipCount"  -ForegroundColor DarkGray
    }
    Write-Host ''

    # HTML
    if ($HtmlReport) {
        $htmlDir = Split-Path -Parent $HtmlReport
        if ($htmlDir -and -not (Test-Path $htmlDir)) { New-Item -ItemType Directory -Path $htmlDir -Force | Out-Null }
        $meta = @{ listFile = $TargetList; pingCount = $PingCount; timeout = $TimeoutSec; hostname = $env:COMPUTERNAME }
        $html = New-HtmlReport $hostResults $meta $hasEval
        [System.IO.File]::WriteAllText($HtmlReport, $html, [System.Text.Encoding]::UTF8)
        Write-Host "  HTML report: $HtmlReport" -ForegroundColor Green
    }

    # Investigation
    if ($failCount -gt 0 -or $warnCount -gt 0) {
        $investTs  = Get-Date -Format 'yyyyMMdd-HHmmss'
        $investDir = if ($env:TEMP) { $env:TEMP } elseif ($env:TMPDIR) { $env:TMPDIR } else { '/tmp' }
        $investFile = Join-Path $investDir "network_investigation_${investTs}.txt"
        try { Invoke-Investigation $hostResults $investFile $TimeoutSec }
        catch { Write-Warning "Investigation collection failed: $($_.Exception.Message)" }
    }

    exit $(if ($failCount -gt 0) { 1 } else { 0 })
}
catch {
    Write-Error "Failed: $($_.Exception.Message)"
    exit 4
}
