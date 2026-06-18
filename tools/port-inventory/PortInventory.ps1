#Requires -Version 5.1
<#
.SYNOPSIS
    Collect listening TCP/UDP ports and optionally audit against an expected list.

.DESCRIPTION
    Inventories all LISTEN TCP and UDP endpoints on the local machine,
    resolving each to its owning process name and executable path.

    Primary collection uses Get-NetTCPConnection / Get-NetUDPEndpoint.
    Falls back to netstat -ano + Win32_Process CIM for restricted environments
    (AppLocker / GPO blocking the Net* cmdlets).

    When an expected_ports.lst is provided, the tool compares actual ports
    against the list and reports NG / WARN / OK / INFO statuses.
    Without the list, it outputs the raw inventory (exit 0).

    Expected list format (CSV, one entry per line):
      <port>, <proto>, <expected>, <description>
      - proto:    tcp / udp
      - expected: ok (should be listening) / ng (should NOT be listening) / - (info only)
      - Lines starting with "#" are comments; blank lines are skipped

.PARAMETER ExpectedList
    Path to the expected_ports.lst file. Optional.

.PARAMETER HtmlReport
    Path for an HTML report file. If omitted, no HTML output.

.PARAMETER Json
    Output results as a JSON array instead of a console table.

.PARAMETER FailOnly
    Show only NG and WARN entries (hide OK / INFO).

.EXAMPLE
    .\PortInventory.ps1
    .\PortInventory.ps1 -ExpectedList expected_ports.lst
    .\PortInventory.ps1 -ExpectedList expected_ports.lst -HtmlReport report.html
    .\PortInventory.ps1 -ExpectedList expected_ports.lst -Json -FailOnly

.NOTES
    Exit codes:
      0  = All OK or no evaluation (inventory only)
      1  = One or more NG / WARN found
      2  = Expected list file not found
      10 = Prerequisite missing
#>
[CmdletBinding()]
param(
    [string]$ExpectedList = '',
    [string]$HtmlReport   = '',
    [string]$FromJson     = '',
    [switch]$Json,
    [switch]$FailOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# StrictMode 下で JSON オブジェクトの欠落プロパティを安全に取得する
function Get-JsonProp($obj, [string]$name) {
    if ($null -eq $obj) { return $null }
    $pp = $obj.PSObject.Properties[$name]
    if ($pp) { return $pp.Value }
    return $null
}

# ============================================================
# Phase 2: Helper functions — port collection
# ============================================================

function Get-ProcessCache {
    $cache = @{}
    try {
        Get-Process -ErrorAction Stop | ForEach-Object {
            if (-not $cache.ContainsKey($_.Id)) {
                $procPath = ''
                try { $procPath = $_.Path } catch {}
                $cache[$_.Id] = @{ Name = $_.Name; Path = $procPath }
            }
        }
    }
    catch {
        # Fallback: CIM
        try {
            Get-CimInstance Win32_Process -ErrorAction Stop | ForEach-Object {
                $pid_ = [int]$_.ProcessId
                if (-not $cache.ContainsKey($pid_)) {
                    $cache[$pid_] = @{
                        Name = if ($_.Name) { $_.Name -replace '\.exe$', '' } else { '(unknown)' }
                        Path = if ($_.ExecutablePath) { $_.ExecutablePath } else { '' }
                    }
                }
            }
        } catch {}
    }
    return $cache
}

function Resolve-ProcessInfo([int]$ProcessId, [hashtable]$Cache) {
    if ($Cache.ContainsKey($ProcessId)) {
        return $Cache[$ProcessId]
    }
    return @{ Name = '(unknown)'; Path = '' }
}

function Get-ListeningPorts {
    $ports = [System.Collections.Generic.List[hashtable]]::new()
    try {
        # --- Primary: Get-NetTCPConnection + Get-NetUDPEndpoint ---
        $procCache = Get-ProcessCache

        $tcp = Get-NetTCPConnection -State Listen -ErrorAction Stop
        foreach ($c in $tcp) {
            $info = Resolve-ProcessInfo -ProcessId $c.OwningProcess -Cache $procCache
            $ports.Add([ordered]@{
                port    = [int]$c.LocalPort
                proto   = 'tcp'
                address = $c.LocalAddress
                pid     = [int]$c.OwningProcess
                process = $info.Name
                path    = $info.Path
            })
        }

        try {
            $udp = Get-NetUDPEndpoint -ErrorAction Stop
            foreach ($u in $udp) {
                $info = Resolve-ProcessInfo -ProcessId $u.OwningProcess -Cache $procCache
                $ports.Add([ordered]@{
                    port    = [int]$u.LocalPort
                    proto   = 'udp'
                    address = $u.LocalAddress
                    pid     = [int]$u.OwningProcess
                    process = $info.Name
                    path    = $info.Path
                })
            }
        }
        catch {
            Write-Verbose "Get-NetUDPEndpoint unavailable, UDP skipped in primary path: $_"
        }
    }
    catch {
        Write-Verbose "Primary collection failed, falling back to netstat: $_"
        $ports = Get-ListeningPortsFallback
    }

    # Deduplicate by port+proto (keep first occurrence)
    $seen   = @{}
    $unique = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($p in $ports) {
        $key = "$($p.port)_$($p.proto)"
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $unique.Add($p)
        }
    }

    # Sort by proto then port
    $sorted = @($unique | Sort-Object @{Expression={$_.proto}}, @{Expression={$_.port}})
    return $sorted
}

function Get-ListeningPortsFallback {
    # Build PID -> process map via CIM
    $pidMap = @{}
    try {
        Get-CimInstance Win32_Process -ErrorAction Stop | ForEach-Object {
            $pid_ = [int]$_.ProcessId
            if (-not $pidMap.ContainsKey($pid_)) {
                $pidMap[$pid_] = @{
                    Name = if ($_.Name) { $_.Name -replace '\.exe$', '' } else { '(unknown)' }
                    Path = if ($_.ExecutablePath) { $_.ExecutablePath } else { '' }
                }
            }
        }
    }
    catch {
        Write-Verbose "CIM Win32_Process also failed: $_"
    }

    $ports = [System.Collections.Generic.List[hashtable]]::new()
    $raw   = netstat -ano 2>&1

    foreach ($line in $raw) {
        $text = "$line".Trim()

        # TCP LISTENING
        if ($text -match '^\s*(TCP)\s+(\S+):(\d+)\s+\S+\s+LISTENING\s+(\d+)') {
            $proto   = 'tcp'
            $address = $Matches[2]
            $portNum = [int]$Matches[3]
            $pidVal  = [int]$Matches[4]

            $procInfo = if ($pidMap.ContainsKey($pidVal)) { $pidMap[$pidVal] } else { @{ Name='(unknown)'; Path='' } }
            $ports.Add([ordered]@{
                port    = $portNum
                proto   = $proto
                address = $address
                pid     = $pidVal
                process = $procInfo.Name
                path    = $procInfo.Path
            })
            continue
        }

        # UDP (no state column)
        if ($text -match '^\s*(UDP)\s+(\S+):(\d+)\s+\*:\*\s+(\d+)') {
            $proto   = 'udp'
            $address = $Matches[2]
            $portNum = [int]$Matches[3]
            $pidVal  = [int]$Matches[4]

            $procInfo = if ($pidMap.ContainsKey($pidVal)) { $pidMap[$pidVal] } else { @{ Name='(unknown)'; Path='' } }
            $ports.Add([ordered]@{
                port    = $portNum
                proto   = $proto
                address = $address
                pid     = $pidVal
                process = $procInfo.Name
                path    = $procInfo.Path
            })
        }
    }

    return $ports
}

# ============================================================
# Phase 2: Expected list parser
# ============================================================

function Read-ExpectedList([string]$Path) {
    $entries = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($raw in (Get-Content $Path -Encoding UTF8)) {
        $trimmed = $raw.Trim()
        if (-not $trimmed) { continue }
        if ($trimmed -match '^\s*#') { continue }

        $parts = $trimmed -split ',', 4
        if ($parts.Count -lt 3) { continue }

        # Port
        $portNum = 0
        $rawPort = $parts[0].Trim()
        if (-not [int]::TryParse($rawPort, [ref]$portNum)) { continue }
        if ($portNum -lt 1 -or $portNum -gt 65535) { continue }

        # Proto
        $proto = $parts[1].Trim().ToLower()
        if ($proto -notin @('tcp', 'udp')) { continue }

        # Expected
        $expected = $parts[2].Trim().ToLower()
        if ($expected -notin @('ok', 'ng', '-')) { $expected = '-' }

        # Description
        $desc = ''
        if ($parts.Count -ge 4) {
            $desc = $parts[3].Trim()
        }
        if (-not $desc) { $desc = "$portNum/$proto" }

        $entries.Add(@{
            port        = $portNum
            proto       = $proto
            expected    = $expected
            description = $desc
        })
    }

    return , @($entries)
}

# ============================================================
# Phase 2: Judgment engine
# ============================================================

function Invoke-PortAudit([hashtable[]]$Actual, [hashtable[]]$Expected) {
    $results = [System.Collections.Generic.List[hashtable]]::new()

    # Build lookup of actual listening ports: "port_proto" -> port info
    $actualMap = @{}
    foreach ($a in $Actual) {
        $key = "$($a.port)_$($a.proto)"
        if (-not $actualMap.ContainsKey($key)) {
            $actualMap[$key] = $a
        }
    }

    # Track which actual ports are covered by expected list
    $covered = @{}

    foreach ($e in $Expected) {
        $key       = "$($e.port)_$($e.proto)"
        $listening = $actualMap.ContainsKey($key)
        $covered[$key] = $true

        $row = [ordered]@{
            port        = $e.port
            proto       = $e.proto
            address     = ''
            process     = ''
            pid         = 0
            path        = ''
            status      = ''
            description = $e.description
        }

        if ($listening) {
            $ap = $actualMap[$key]
            $row.address = $ap.address
            $row.process = $ap.process
            $row.pid     = $ap.pid
            $row.path    = $ap.path
        }

        switch ($e.expected) {
            'ok' {
                if ($listening) {
                    $row.status = 'OK'
                } else {
                    $row.status = 'NG'
                }
            }
            'ng' {
                if ($listening) {
                    $row.status = 'NG'
                } else {
                    $row.status = 'OK'
                }
            }
            '-' {
                $row.status = 'INFO'
            }
        }

        $results.Add($row)
    }

    # Ports listening but not in expected list -> WARN
    foreach ($a in $Actual) {
        $key = "$($a.port)_$($a.proto)"
        if (-not $covered.ContainsKey($key)) {
            $results.Add([ordered]@{
                port        = $a.port
                proto       = $a.proto
                address     = $a.address
                process     = $a.process
                pid         = $a.pid
                path        = $a.path
                status      = 'WARN'
                description = '(unexpected)'
            })
        }
    }

    # Sort: NG first, then WARN, OK, INFO
    $order = @{ 'NG' = 0; 'WARN' = 1; 'OK' = 2; 'INFO' = 3 }
    $sorted = @($results | Sort-Object @{Expression={ $order[$_.status] }}, @{Expression={$_.proto}}, @{Expression={$_.port}})
    return $sorted
}

# ============================================================
# Phase 2: Output generators
# ============================================================

function New-PortHtmlReport($rows, $meta) {
    $ok   = @($rows | Where-Object { $_.status -eq 'OK'   }).Count
    $warn = @($rows | Where-Object { $_.status -eq 'WARN' }).Count
    $ng   = @($rows | Where-Object { $_.status -eq 'NG'   }).Count
    $info = @($rows | Where-Object { $_.status -eq 'INFO' }).Count
    $total = $rows.Count
    $genTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    function HE([string]$s) {
        try { [System.Net.WebUtility]::HtmlEncode($s) }
        catch { $s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' }
    }

    $tableRows = foreach ($r in $rows) {
        $rc = switch ($r.status) {
            'OK'   { 'row-ok'   }
            'WARN' { 'row-warn' }
            'NG'   { 'row-fail' }
            'INFO' { 'row-info' }
            default { '' }
        }
        $badge = switch ($r.status) {
            'OK'   { "<span class='badge ok'>OK</span>"     }
            'WARN' { "<span class='badge warn'>WARN</span>" }
            'NG'   { "<span class='badge fail'>NG</span>"   }
            'INFO' { "<span class='badge info'>INFO</span>" }
            default { "<span class='badge na'>$($r.status)</span>" }
        }

        "<tr class='$rc'>" +
            "<td>$($r.port)</td>" +
            "<td>$($r.proto.ToUpper())</td>" +
            "<td>$(HE $r.address)</td>" +
            "<td>$(HE $r.process)</td>" +
            "<td>$($r.pid)</td>" +
            "<td>$(HE $r.path)</td>" +
            "<td>$badge</td>" +
            "<td>$(HE $r.description)</td>" +
        '</tr>'
    }

    return @"
<!DOCTYPE html><html lang="ja"><head><meta charset="UTF-8">
<title>Port Inventory</title>
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
.card{background:#fff;border-radius:8px;padding:16px 20px;text-align:center;flex:1;min-width:90px;box-shadow:0 1px 3px rgba(0,0,0,.1)}
.card .num{font-size:28px;font-weight:700}.card .lbl{font-size:11px;color:#64748b;margin-top:2px}
.card.total .num{color:#1e293b}.card.ok .num{color:#16a34a}.card.warn .num{color:#d97706}
.card.fail .num{color:#dc2626}.card.info .num{color:#2563eb}
.filter-bar{padding:8px 24px;display:flex;gap:8px;align-items:center;flex-wrap:wrap}
.filter-bar label{font-size:12px;color:#64748b;margin-right:4px}
.filter-bar button{font-size:12px;padding:4px 12px;border:1px solid #cbd5e1;border-radius:4px;background:#fff;cursor:pointer}
.filter-bar button.active{background:#1e293b;color:#fff;border-color:#1e293b}
.table-wrap{margin:0 24px 24px;background:#fff;border-radius:8px;box-shadow:0 1px 3px rgba(0,0,0,.1);overflow-x:auto}
table{width:100%;border-collapse:collapse;font-size:12px}
th{background:#f1f5f9;padding:8px 12px;text-align:left;font-weight:600;color:#475569;border-bottom:2px solid #e2e8f0}
td{padding:7px 12px;border-bottom:1px solid #f1f5f9;vertical-align:middle}
tr:last-child td{border-bottom:none}
tr.row-ok{background:#fff}tr.row-warn{background:#fffbeb}tr.row-fail{background:#fff1f2}tr.row-info{background:#eff6ff}
.badge{display:inline-block;font-size:11px;padding:2px 7px;border-radius:4px;font-weight:600;white-space:nowrap}
.badge.ok{background:#dcfce7;color:#15803d}.badge.warn{background:#fef3c7;color:#92400e}
.badge.fail{background:#fee2e2;color:#b91c1c}.badge.info{background:#dbeafe;color:#1d4ed8}
.badge.na{background:#f1f5f9;color:#64748b}
td:first-child{font-family:monospace;font-weight:600}
.footer{text-align:center;padding:16px;font-size:11px;color:#94a3b8}.hidden{display:none}
</style></head><body>
<div class="header">
  <h1>Port Inventory Report</h1>
  <div class="sub">Generated: $genTime</div>
</div>
<div class="meta">
  <div class="meta-item"><span class="label">Host:</span>$(HE $meta.hostname)</div>
  <div class="meta-item"><span class="label">Expected list:</span>$(HE $meta.listFile)</div>
  <div class="meta-item"><span class="label">Mode:</span>$(HE $meta.mode)</div>
</div>
<div class="summary">
  <div class="card total"><div class="num">$total</div><div class="lbl">Total</div></div>
  <div class="card ok">   <div class="num">$ok</div><div class="lbl">OK</div></div>
  <div class="card warn"> <div class="num">$warn</div><div class="lbl">WARN</div></div>
  <div class="card fail"> <div class="num">$ng</div><div class="lbl">NG</div></div>
  <div class="card info"> <div class="num">$info</div><div class="lbl">INFO</div></div>
</div>
<div class="filter-bar">
  <label>Filter:</label>
  <button class="active" onclick="filterRows('all',this)">All</button>
  <button onclick="filterRows('row-ok',this)">OK</button>
  <button onclick="filterRows('row-warn',this)">WARN</button>
  <button onclick="filterRows('row-fail',this)">NG</button>
  <button onclick="filterRows('row-info',this)">INFO</button>
</div>
<div class="table-wrap">
<table id="tbl">
<thead><tr>
  <th>Port</th><th>Proto</th><th>Address</th><th>Process</th><th>PID</th><th>Path</th><th>Status</th><th>Description</th>
</tr></thead>
<tbody>
$($tableRows -join "`n")
</tbody>
</table>
</div>
<div class="footer">PortInventory.ps1 &mdash; Listening Port Inventory &amp; Audit</div>
<script>
function filterRows(cls,btn){
  var rows=document.querySelectorAll('#tbl tbody tr');
  for(var i=0;i<rows.length;i++){
    if(cls==='all'||rows[i].classList.contains(cls)){
      rows[i].style.display='';
    }else{rows[i].style.display='none';}
  }
  var btns=document.querySelectorAll('.filter-bar button');
  for(var j=0;j<btns.length;j++){btns[j].className='';}
  btn.className='active';
}
</script>
</body></html>
"@
}

# ============================================================
# Phase 3: Validation
# ============================================================

$hasExpectedList = $false

# -FromJson takes precedence: ignore collection options like -ExpectedList
if ($ExpectedList -and -not $FromJson) {
    if (-not (Test-Path $ExpectedList)) {
        Write-Host "ERROR: Expected list not found: $ExpectedList" -ForegroundColor Red
        exit 2
    }
    $ExpectedList = (Resolve-Path $ExpectedList).Path
    $hasExpectedList = $true
}

# ============================================================
# Phase 4: Main processing — collect ports
# ============================================================

$fromJsonMode = [bool]$FromJson

if ($FromJson) {
    # ── FromJson: 収集を JSON 読み込みに差し替える ──
    if (-not (Test-Path -LiteralPath $FromJson)) {
        Write-Host "ERROR: FromJson file not found: $FromJson" -ForegroundColor Red
        exit 2
    }
    try {
        $rawJson = Get-Content -LiteralPath $FromJson -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Host "ERROR: Failed to parse JSON: $FromJson" -ForegroundColor Red
        exit 1
    }
    $outputRows = @(
        foreach ($o in @($rawJson)) {
            $portVal = Get-JsonProp $o 'port'
            $pidVal  = Get-JsonProp $o 'pid'
            [ordered]@{
                port        = if ($null -ne $portVal) { [int]$portVal } else { 0 }
                proto       = [string](Get-JsonProp $o 'proto')
                address     = [string](Get-JsonProp $o 'address')
                process     = [string](Get-JsonProp $o 'process')
                pid         = if ($null -ne $pidVal) { [int]$pidVal } else { 0 }
                path        = [string](Get-JsonProp $o 'path')
                status      = [string](Get-JsonProp $o 'status')
                description = [string](Get-JsonProp $o 'description')
            }
        }
    )
}
else {
    if (-not $Json) {
        Write-Host ''
        Write-Host 'Port Inventory - Collecting listening ports...' -ForegroundColor Cyan
        Write-Host ('=' * 60)
    }

    $actual = Get-ListeningPorts

    if (-not $Json) {
        Write-Host "  Found $($actual.Count) unique listening port(s)." -ForegroundColor Green
    }

    # Audit or inventory-only
    $auditResults = $null

    if ($hasExpectedList) {
        $expected = Read-ExpectedList $ExpectedList
        if ($expected.Count -eq 0) {
            if (-not $Json) {
                Write-Host '  WARNING: Expected list is empty, showing inventory only.' -ForegroundColor Yellow
            }
        }
        else {
            if (-not $Json) {
                Write-Host "  Comparing against $($expected.Count) expected entry(ies)..." -ForegroundColor Cyan
            }
            $auditResults = Invoke-PortAudit -Actual $actual -Expected $expected
        }
    }

    # Build final row set for output
    if ($null -ne $auditResults) {
        $outputRows = $auditResults
    }
    else {
        # Inventory-only mode: wrap actual ports as INFO rows
        $outputRows = @(
            foreach ($a in $actual) {
                [ordered]@{
                    port        = $a.port
                    proto       = $a.proto
                    address     = $a.address
                    process     = $a.process
                    pid         = $a.pid
                    path        = $a.path
                    status      = 'INFO'
                    description = ''
                }
            }
        )
    }
}

# ============================================================
# Phase 5: Output and exit
# ============================================================

# Apply FailOnly filter
$displayRows = if ($FailOnly) {
    @($outputRows | Where-Object { $_.status -in @('NG', 'WARN') })
} else {
    @($outputRows)
}

if (-not $Json) {
    Write-Host ''
    Write-Host ('=' * 60)
}

if ($Json) {
    # JSON output
    $jsonArr = @(
        foreach ($r in $displayRows) {
            [ordered]@{
                port        = $r.port
                proto       = $r.proto
                address     = $r.address
                process     = $r.process
                pid         = $r.pid
                path        = $r.path
                status      = $r.status
                description = $r.description
            }
        }
    )
    ConvertTo-Json $jsonArr -Depth 3
}
else {
    # Console table
    if ($displayRows.Count -eq 0) {
        Write-Host '  (No entries to display)' -ForegroundColor DarkGray
    }
    else {
        $fmt = '{0,6} {1,5} {2,-16} {3,-20} {4,7} {5,5} {6,-12}'
        Write-Host ''
        Write-Host ($fmt -f 'PORT', 'PROTO', 'ADDRESS', 'PROCESS', 'PID', 'STAT', 'DESCRIPTION') -ForegroundColor DarkGray
        Write-Host ($fmt -f ('=' * 6), ('=' * 5), ('=' * 16), ('=' * 20), ('=' * 7), ('=' * 5), ('=' * 12)) -ForegroundColor DarkGray

        foreach ($r in $displayRows) {
            $color = switch ($r.status) {
                'OK'   { 'Green'      }
                'WARN' { 'Yellow'     }
                'NG'   { 'Red'        }
                'INFO' { 'DarkCyan'   }
                default { 'White'     }
            }

            # Truncate process and description for console
            $procDisp = $r.process
            if ($procDisp.Length -gt 20) { $procDisp = $procDisp.Substring(0, 17) + '...' }
            $descDisp = $r.description
            if ($descDisp.Length -gt 12) { $descDisp = $descDisp.Substring(0, 9) + '...' }

            # Truncate address
            $addrDisp = $r.address
            if ($addrDisp.Length -gt 16) { $addrDisp = $addrDisp.Substring(0, 13) + '...' }

            $line = $fmt -f $r.port, $r.proto.ToUpper(), $addrDisp, $procDisp, $r.pid, $r.status, $descDisp
            Write-Host $line -ForegroundColor $color

            if ($r.path) {
                Write-Host "         -> $($r.path)" -ForegroundColor DarkGray
            }
        }
    }
}

# HTML report
if ($HtmlReport) {
    $htmlPath = $HtmlReport
    if (-not [System.IO.Path]::IsPathRooted($htmlPath)) {
        $htmlPath = Join-Path (Get-Location).Path $htmlPath
    }
    $meta = @{
        hostname = $env:COMPUTERNAME
        listFile = if ($fromJsonMode) { [System.IO.Path]::GetFileName($FromJson) }
                   elseif ($hasExpectedList) { [System.IO.Path]::GetFileName($ExpectedList) }
                   else { '(none)' }
        mode     = if ($fromJsonMode) { 'FromJson' }
                   elseif ($hasExpectedList) { 'Audit' }
                   else { 'Inventory' }
    }
    $htmlContent = New-PortHtmlReport $displayRows $meta
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($htmlPath, $htmlContent, $utf8NoBom)
    Write-Host ''
    Write-Host "  HTML report: $htmlPath" -ForegroundColor Green
}

# Summary
$ngCount   = @($outputRows | Where-Object { $_.status -eq 'NG'   }).Count
$warnCount = @($outputRows | Where-Object { $_.status -eq 'WARN' }).Count
$okCount   = @($outputRows | Where-Object { $_.status -eq 'OK'   }).Count
$infoCount = @($outputRows | Where-Object { $_.status -eq 'INFO' }).Count

if (-not $Json) {
    Write-Host ''
    if ($fromJsonMode) {
        Write-Host "Summary (from JSON): $($outputRows.Count) entries / OK=$okCount / NG=$ngCount / WARN=$warnCount / INFO=$infoCount"
    }
    elseif ($hasExpectedList) {
        Write-Host "Summary: $($outputRows.Count) entries / OK=$okCount / NG=$ngCount / WARN=$warnCount / INFO=$infoCount"
    }
    else {
        Write-Host "Summary: $($actual.Count) listening port(s) discovered (inventory only)"
    }
    Write-Host ''
}

if ($ngCount -gt 0 -or $warnCount -gt 0) {
    exit 1
}
exit 0
