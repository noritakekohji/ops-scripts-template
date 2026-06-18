#Requires -Version 5.1
<#
.SYNOPSIS
    Check TLS certificate expiry for multiple targets.

.DESCRIPTION
    Reads a target list file and checks each host's TLS certificate
    using .NET SslStream. Reports subject, issuer, expiry date,
    days remaining, SAN, and status (OK / WARN / NG).

    Target list format (one entry per line):
      <host>, <port>, <warn_days>, <description>
      - port defaults to 443 if omitted or "-"
      - warn_days defaults to 30 if omitted or "-"
      - Lines starting with "#" are comments; blank lines skipped
      - Section comments like "# ---- Section Name ----" group output

.PARAMETER TargetList
    Path to the target list file (cert_targets.lst).

.PARAMETER TimeoutSec
    TCP connection timeout in seconds. Default: 10

.PARAMETER HtmlReport
    Path for an HTML report file. If omitted, no HTML output.

.PARAMETER Json
    Output results as a JSON array instead of a console table.

.PARAMETER FailOnly
    Show only WARN and NG entries (hide OK).

.EXAMPLE
    .\CertCheck.ps1 -TargetList cert_targets.lst
    .\CertCheck.ps1 -TargetList cert_targets.lst -Json
    .\CertCheck.ps1 -TargetList cert_targets.lst -HtmlReport report.html -FailOnly

.NOTES
    Exit codes:
      0  = All certificates OK
      1  = One or more WARN or NG found
      2  = Target list file not found
      10 = Prerequisite missing
#>
[CmdletBinding()]
param(
    [string]$TargetList = '',
    [int]$TimeoutSec    = 10,
    [string]$HtmlReport = '',
    [string]$FromJson   = '',
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
# Phase 2: Target list parser
# ============================================================

function Read-CertTargetList([string]$Path) {
    $entries  = [System.Collections.Generic.List[hashtable]]::new()
    $section  = ''

    foreach ($raw in (Get-Content $Path -Encoding UTF8)) {
        $trimmed = $raw.Trim()
        if (-not $trimmed) { continue }

        # Section comment: # ---- Section Name ----
        if ($trimmed -match '^\s*#\s*-{2,}\s*(.+?)\s*-{2,}\s*$') {
            $section = $Matches[1].Trim()
            continue
        }

        # Regular comment
        if ($trimmed -match '^\s*#') { continue }

        $parts = $trimmed -split ',', 4
        $host_ = $parts[0].Trim()
        if (-not $host_) { continue }

        # Port
        $port = 443
        if ($parts.Count -ge 2) {
            $rawPort = $parts[1].Trim()
            if ($rawPort -and $rawPort -ne '-') {
                $n = 0
                if ([int]::TryParse($rawPort, [ref]$n) -and $n -gt 0 -and $n -le 65535) {
                    $port = $n
                }
            }
        }

        # WarnDays
        $warnDays = 30
        if ($parts.Count -ge 3) {
            $rawWarn = $parts[2].Trim()
            if ($rawWarn -and $rawWarn -ne '-') {
                $w = 0
                if ([int]::TryParse($rawWarn, [ref]$w) -and $w -gt 0) {
                    $warnDays = $w
                }
            }
        }

        # Description
        $desc = $host_
        if ($parts.Count -ge 4) {
            $rawDesc = $parts[3].Trim()
            if ($rawDesc) { $desc = $rawDesc }
        }

        $entries.Add(@{
            host      = $host_
            port      = $port
            warn_days = $warnDays
            desc      = $desc
            section   = $section
        })
    }

    return , @($entries)
}

# ============================================================
# Phase 3: TLS certificate checker
# ============================================================

function Test-Certificate([string]$HostName, [int]$Port, [int]$Timeout) {
    $result = [ordered]@{
        host           = $HostName
        port           = $Port
        subject        = ''
        issuer         = ''
        not_after      = ''
        days_remaining = -1
        san            = @()
        status         = 'NG'
        message        = ''
    }

    $tcp = $null
    $ssl = $null
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $ar  = $tcp.BeginConnect($HostName, $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($Timeout * 1000)) {
            $tcp.Close()
            $result.message = 'Connection timed out'
            return $result
        }
        $tcp.EndConnect($ar)

        # Accept all certs to gather info even when chain is invalid
        $callback = [System.Net.Security.RemoteCertificateValidationCallback]{
            param($sender, $certificate, $chain, $sslPolicyErrors)
            return $true
        }

        $ssl = New-Object System.Net.Security.SslStream(
            $tcp.GetStream(),
            $false,
            $callback
        )
        $ssl.AuthenticateAsClient($HostName)   # SNI support

        $remoteCert = $ssl.RemoteCertificate
        if ($null -eq $remoteCert) {
            $result.message = 'No remote certificate returned'
            return $result
        }

        $cert2 = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($remoteCert)

        $result.subject        = $cert2.Subject
        $result.issuer         = $cert2.Issuer
        $result.not_after      = $cert2.NotAfter.ToString('yyyy-MM-dd HH:mm:ss')
        $result.days_remaining = [math]::Floor(($cert2.NotAfter - [datetime]::Now).TotalDays)

        # Extract SAN
        foreach ($ext in $cert2.Extensions) {
            if ($ext.Oid.Value -eq '2.5.29.17') {
                $formatted = $ext.Format($false)
                $result.san = @(
                    $formatted -split ',\s*' |
                        ForEach-Object { ($_ -replace '^(DNS Name|DNS.*)=', '').Trim() } |
                        Where-Object { $_ }
                )
                break
            }
        }
    }
    catch {
        $result.message = $_.Exception.Message -replace '\r?\n', ' '
        return $result
    }
    finally {
        if ($null -ne $ssl) {
            try { $ssl.Close() } catch {}
        }
        if ($null -ne $tcp) {
            try { $tcp.Close() } catch {}
        }
    }

    return $result
}

# ============================================================
# HTML report generator
# ============================================================

function New-CertHtmlReport($results, $meta) {
    $ok    = @($results | Where-Object { $_.status -eq 'OK'   }).Count
    $warn  = @($results | Where-Object { $_.status -eq 'WARN' }).Count
    $ng    = @($results | Where-Object { $_.status -eq 'NG'   }).Count
    $total = $results.Count
    $genTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    function HE([string]$s) {
        try { [System.Net.WebUtility]::HtmlEncode($s) }
        catch { $s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' }
    }

    $currentSection = ''
    $rows = foreach ($r in $results) {
        $sectionRow = ''
        if ($r.section -and $r.section -ne $currentSection) {
            $currentSection = $r.section
            $sectionRow = "<tr class='section-row'><td colspan='8'>$(HE $currentSection)</td></tr>`n"
        }

        $rc = switch ($r.status) {
            'OK'   { 'row-ok'   }
            'WARN' { 'row-warn' }
            'NG'   { 'row-fail' }
            default { '' }
        }
        $badge = switch ($r.status) {
            'OK'   { "<span class='badge ok'>OK</span>" }
            'WARN' { "<span class='badge warn'>WARN</span>" }
            'NG'   { "<span class='badge fail'>NG</span>" }
            default { "<span class='badge na'>$($r.status)</span>" }
        }

        $daysCell = if ($r.days_remaining -ge 0) { "$($r.days_remaining)" } else { '-' }
        $msgCell  = if ($r.message) { "<br/><small>$(HE $r.message)</small>" } else { '' }

        "${sectionRow}<tr class='$rc'>" +
            "<td>$(HE $r.host)</td>" +
            "<td>$($r.port)</td>" +
            "<td>$(HE $r.desc)</td>" +
            "<td>$(HE $r.subject)</td>" +
            "<td>$(HE $r.issuer)</td>" +
            "<td>$(HE $r.not_after)</td>" +
            "<td>$daysCell</td>" +
            "<td>$badge$msgCell</td>" +
        '</tr>'
    }

    return @"
<!DOCTYPE html><html lang="ja"><head><meta charset="UTF-8">
<title>TLS Certificate Check</title>
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
tr.section-row{background:#e2e8f0;font-weight:700;color:#334155}
.badge{display:inline-block;font-size:11px;padding:2px 7px;border-radius:4px;font-weight:600;white-space:nowrap}
.badge.ok{background:#dcfce7;color:#15803d}.badge.warn{background:#fef3c7;color:#92400e}
.badge.fail{background:#fee2e2;color:#b91c1c}.badge.na{background:#f1f5f9;color:#64748b}
td:first-child{font-family:monospace;font-weight:600}
.footer{text-align:center;padding:16px;font-size:11px;color:#94a3b8}.hidden{display:none}
</style></head><body>
<div class="header">
  <h1>&#128274; TLS Certificate Check</h1>
  <div class="sub">Generated: $genTime</div>
</div>
<div class="meta">
  <div class="meta-item"><span class="label">Target list:</span>$(HE $meta.listFile)</div>
  <div class="meta-item"><span class="label">Timeout:</span>$($meta.timeout)s</div>
  <div class="meta-item"><span class="label">Executed on:</span>$(HE $meta.hostname)</div>
</div>
<div class="summary">
  <div class="card total"><div class="num">$total</div><div class="lbl">Total</div></div>
  <div class="card ok">   <div class="num">$ok</div><div class="lbl">OK</div></div>
  <div class="card warn"> <div class="num">$warn</div><div class="lbl">Warning</div></div>
  <div class="card fail"> <div class="num">$ng</div><div class="lbl">NG</div></div>
</div>
<div class="filter-bar">
  <label>Filter:</label>
  <button class="active" onclick="filterRows('all',this)">All</button>
  <button onclick="filterRows('row-ok',this)">OK</button>
  <button onclick="filterRows('row-warn',this)">WARN</button>
  <button onclick="filterRows('row-fail',this)">NG</button>
</div>
<div class="table-wrap">
<table id="tbl">
<thead><tr>
  <th>Host</th><th>Port</th><th>Description</th>
  <th>Subject</th><th>Issuer</th><th>Expiry</th><th>Days</th><th>Status</th>
</tr></thead>
<tbody>
$($rows -join "`n")
</tbody>
</table>
</div>
<div class="footer">CertCheck.ps1 &mdash; TLS Certificate Expiry Checker</div>
<script>
function filterRows(cls,btn){
  var rows=document.querySelectorAll('#tbl tbody tr');
  for(var i=0;i<rows.length;i++){
    if(cls==='all'||rows[i].classList.contains(cls)||rows[i].classList.contains('section-row')){
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
# Phase 4: Main processing (collection or FromJson restore)
# ============================================================

$results = [System.Collections.Generic.List[hashtable]]::new()

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
    foreach ($o in @($rawJson)) {
        $portVal = Get-JsonProp $o 'port'
        $drVal   = Get-JsonProp $o 'days_remaining'
        $wdVal   = Get-JsonProp $o 'warn_days'
        $results.Add(@{
            host           = [string](Get-JsonProp $o 'host')
            port           = if ($null -ne $portVal) { [int]$portVal } else { 0 }
            desc           = [string](Get-JsonProp $o 'description')
            subject        = [string](Get-JsonProp $o 'subject')
            issuer         = [string](Get-JsonProp $o 'issuer')
            not_after      = [string](Get-JsonProp $o 'not_after')
            days_remaining = if ($null -ne $drVal) { [int]$drVal } else { -1 }
            warn_days      = if ($null -ne $wdVal) { [int]$wdVal } else { 30 }
            san            = @(Get-JsonProp $o 'san')
            status         = [string](Get-JsonProp $o 'status')
            message        = [string](Get-JsonProp $o 'message')
            section        = ''
        })
    }
}
else {
    if (-not $TargetList) {
        Write-Host 'ERROR: Either -TargetList or -FromJson is required' -ForegroundColor Red
        exit 1
    }
    if (-not (Test-Path $TargetList)) {
        Write-Host "ERROR: Target list not found: $TargetList" -ForegroundColor Red
        exit 2
    }

    # Resolve to absolute path
    $TargetList = (Resolve-Path $TargetList).Path

    $targets = Read-CertTargetList $TargetList

    if ($targets.Count -eq 0) {
        Write-Host 'WARNING: No targets found in the list file.' -ForegroundColor Yellow
        exit 0
    }

    Write-Host ''
    Write-Host "TLS Certificate Check - $($targets.Count) target(s)" -ForegroundColor Cyan
    Write-Host ('=' * 60)

    $currentSection = ''

    foreach ($t in $targets) {
        if ($t.section -and $t.section -ne $currentSection) {
            $currentSection = $t.section
            Write-Host ''
            Write-Host "  ---- $currentSection ----" -ForegroundColor DarkCyan
        }

        $hostPort = "$($t.host):$($t.port)"
        Write-Host -NoNewline "  Checking $hostPort ... "

        $certResult = Test-Certificate -HostName $t.host -Port $t.port -Timeout $TimeoutSec

        # Apply judgment using per-target warn_days
        if ($certResult.days_remaining -lt 0 -and -not $certResult.subject) {
            # Connection failed or no cert retrieved
            $certResult.status = 'NG'
        }
        elseif ($certResult.days_remaining -lt 0) {
            # Cert expired
            $certResult.status = 'NG'
            if (-not $certResult.message) { $certResult.message = 'Certificate expired' }
        }
        elseif ($certResult.days_remaining -lt $t.warn_days) {
            $certResult.status = 'WARN'
            $certResult.message = "Expires in $($certResult.days_remaining) days (threshold: $($t.warn_days))"
        }
        else {
            $certResult.status = 'OK'
        }

        # Attach target metadata
        $certResult.desc      = $t.desc
        $certResult.warn_days = $t.warn_days
        $certResult.section   = $t.section

        # Console progress
        $color = switch ($certResult.status) {
            'OK'   { 'Green'  }
            'WARN' { 'Yellow' }
            'NG'   { 'Red'    }
            default { 'White' }
        }
        $daysText = if ($certResult.days_remaining -ge 0) { "$($certResult.days_remaining) days" } else { 'N/A' }
        Write-Host "$($certResult.status) ($daysText)" -ForegroundColor $color

        $results.Add($certResult)
    }
}

# ============================================================
# Phase 5: Output and cleanup
# ============================================================

# Apply FailOnly filter for display
$displayResults = if ($FailOnly) {
    @($results | Where-Object { $_.status -ne 'OK' })
} else {
    @($results)
}

if (-not $Json) {
    Write-Host ''
    Write-Host ('=' * 60)
}

if ($Json) {
    # JSON output
    $jsonArr = @(
        foreach ($r in $displayResults) {
            [ordered]@{
                host           = $r.host
                port           = $r.port
                description    = $r.desc
                subject        = $r.subject
                issuer         = $r.issuer
                not_after      = $r.not_after
                days_remaining = $r.days_remaining
                warn_days      = $r.warn_days
                san            = $r.san
                status         = $r.status
                message        = $r.message
            }
        }
    )
    ConvertTo-Json $jsonArr -Depth 3
}
else {
    # Console table output
    if ($displayResults.Count -eq 0) {
        Write-Host '  (No entries to display)' -ForegroundColor DarkGray
    }
    else {
        $fmt = '{0,-30} {1,5} {2,-28} {3,-20} {4,6} {5,4}'
        Write-Host ''
        Write-Host ($fmt -f 'HOST', 'PORT', 'SUBJECT', 'EXPIRY', 'DAYS', 'STAT') -ForegroundColor DarkGray
        Write-Host ($fmt -f ('=' * 30), ('=' * 5), ('=' * 28), ('=' * 20), ('=' * 6), ('=' * 4)) -ForegroundColor DarkGray

        $tableSection = ''
        foreach ($r in $displayResults) {
            if ($r.section -and $r.section -ne $tableSection) {
                $tableSection = $r.section
                Write-Host ''
                Write-Host "  ---- $tableSection ----" -ForegroundColor DarkCyan
            }

            # Truncate subject CN for display
            $subj = $r.subject
            if ($subj -match 'CN=([^,]+)') { $subj = $Matches[1] }
            if ($subj.Length -gt 28) { $subj = $subj.Substring(0, 25) + '...' }

            $daysStr  = if ($r.days_remaining -ge 0) { "$($r.days_remaining)" } else { '-' }
            $expiryStr = if ($r.not_after) {
                ($r.not_after -split ' ')[0]   # date part only
            } else { '-' }

            $color = switch ($r.status) {
                'OK'   { 'Green'  }
                'WARN' { 'Yellow' }
                'NG'   { 'Red'    }
                default { 'White' }
            }

            $line = $fmt -f $r.host, $r.port, $subj, $expiryStr, $daysStr, $r.status
            Write-Host $line -ForegroundColor $color
            if ($r.message) {
                Write-Host "    -> $($r.message)" -ForegroundColor DarkGray
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
        listFile = if ($FromJson) { [System.IO.Path]::GetFileName($FromJson) } else { [System.IO.Path]::GetFileName($TargetList) }
        timeout  = $TimeoutSec
        hostname = $env:COMPUTERNAME
    }
    $htmlContent = New-CertHtmlReport $displayResults $meta
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($htmlPath, $htmlContent, $utf8NoBom)
    Write-Host ''
    Write-Host "  HTML report: $htmlPath" -ForegroundColor Green
}

# Summary
$okCount   = @($results | Where-Object { $_.status -eq 'OK'   }).Count
$warnCount = @($results | Where-Object { $_.status -eq 'WARN' }).Count
$ngCount   = @($results | Where-Object { $_.status -eq 'NG'   }).Count

if (-not $Json) {
    Write-Host ''
    Write-Host "Summary: $($results.Count) checked / OK=$okCount / WARN=$warnCount / NG=$ngCount"
    Write-Host ''
}

if ($warnCount -gt 0 -or $ngCount -gt 0) {
    exit 1
}
exit 0
