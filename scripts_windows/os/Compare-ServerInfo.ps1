#Requires -Version 5.1
<#
.SYNOPSIS
    Compare two server configuration JSON files (before/after).

.DESCRIPTION
    Reads two JSON files produced by Get-ServerInfo.ps1 or get_server_info.sh
    and shows the differences on the console and/or in an HTML report.

    Supported categories: os, network, services, packages, users,
                          filesystem, environment, security

.PARAMETER Before
    Path to the JSON file of the original (before) server.

.PARAMETER After
    Path to the JSON file of the new (after) server.

.PARAMETER HtmlReport
    Path for the HTML report file. If omitted, only console output is shown.

.PARAMETER Category
    Categories to compare. Default: all available categories.

.PARAMETER DiffOnly
    Show only items that differ (hide identical items).

.EXAMPLE
    .\Compare-ServerInfo.ps1 -Before server-old.json -After server-new.json
    .\Compare-ServerInfo.ps1 -Before before.json -After after.json -HtmlReport report.html
    .\Compare-ServerInfo.ps1 -Before before.json -After after.json -DiffOnly
    .\Compare-ServerInfo.ps1 -Before before.json -After after.json -Category services,packages
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Before,
    [Parameter(Mandatory)][string]$After,
    [string]$HtmlReport = '',
    [ValidateSet('all','os','network','services','packages','users','filesystem','environment','security')]
    [string[]]$Category = @('all'),
    [switch]$DiffOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- Library ---
$libPath = $null
foreach ($c in @(
    [IO.Path]::Combine($PSScriptRoot, '..', 'lib', 'Logging.psm1'),
    [IO.Path]::Combine($PSScriptRoot, '..', 'lib', 'windows', 'Logging.psm1')
)) { if (Test-Path $c) { $libPath = $c; break } }
if (-not $libPath) { throw 'Logging.psm1 not found' }
Import-Module (Resolve-Path $libPath).Path -Force

$configModulePath = $null
foreach ($c in @(
    [IO.Path]::Combine($PSScriptRoot, '..', 'lib', 'Config.psm1'),
    [IO.Path]::Combine($PSScriptRoot, '..', 'lib', 'windows', 'Config.psm1')
)) { if (Test-Path $c) { $configModulePath = $c; break } }
if (-not $configModulePath) { throw 'Config.psm1 not found' }
Import-Module (Resolve-Path $configModulePath).Path -Force

$cfg = Get-OpsConfig -Name 'compare_server_info'
$cfgEnv = if ($env:OPS_ENV) { $env:OPS_ENV } else { 'default' }
$logFile  = if ($cfg.ContainsKey('LogFile'))  { [string]$cfg['LogFile'] }  else { '' }
$logLevel = if ($cfg.ContainsKey('LogLevel')) { [string]$cfg['LogLevel'] } else { 'INFO' }
Set-OpsLogConfig -LogFile $logFile -LogLevel $logLevel

Write-OpsLog -Level INFO -Message "Config loaded: env=$cfgEnv keys=$($cfg.Count)"
Write-OpsLog -Level INFO -Message "Args validated: before='$Before' after='$After' htmlReport='$HtmlReport' diffOnly=$DiffOnly"

$exitCode = 0
$status   = 'unknown'

# ============================================================
# Data structures for comparison results
# ============================================================

class CompareItem {
    [string]$State       # same | changed | removed | added
    [string]$Key
    [string]$BeforeValue
    [string]$AfterValue
}

class CategoryResult {
    [string]$Name
    [System.Collections.Generic.List[CompareItem]]$Items
    [int]$SameCount
    [int]$ChangedCount
    [int]$RemovedCount
    [int]$AddedCount
    CategoryResult([string]$n) {
        $this.Name         = $n
        $this.Items        = [System.Collections.Generic.List[CompareItem]]::new()
        $this.SameCount    = 0
        $this.ChangedCount = 0
        $this.RemovedCount = 0
        $this.AddedCount   = 0
    }
    [void] Add([string]$state, [string]$key, [string]$bv, [string]$av) {
        $i = [CompareItem]::new()
        $i.State       = $state
        $i.Key         = $key
        $i.BeforeValue = $bv
        $i.AfterValue  = $av
        $this.Items.Add($i)
        switch ($state) {
            'same'    { $this.SameCount++ }
            'changed' { $this.ChangedCount++ }
            'removed' { $this.RemovedCount++ }
            'added'   { $this.AddedCount++ }
        }
    }
}

# ============================================================
# Helpers
# ============================================================

function Format-Val([object]$v) {
    if ($null -eq $v) { return '' }
    if ($v -is [System.Collections.IDictionary]) { return ($v.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ' }
    if ($v -is [System.Collections.IEnumerable] -and $v -isnot [string]) { return ($v | ForEach-Object { "$_" }) -join ', ' }
    return "$v"
}

function Compare-Dict([hashtable]$bDict, [hashtable]$aDict, [string]$catName) {
    $result = [CategoryResult]::new($catName)
    $allKeys = @($bDict.Keys) + @($aDict.Keys) | Sort-Object -Unique
    foreach ($k in $allKeys) {
        $bv = Format-Val $bDict[$k]
        $av = Format-Val $aDict[$k]
        if (-not $bDict.ContainsKey($k))   { $result.Add('added',   $k, '', $av) }
        elseif (-not $aDict.ContainsKey($k)) { $result.Add('removed', $k, $bv, '') }
        elseif ($bv -eq $av)               { $result.Add('same',    $k, $bv, $av) }
        else                               { $result.Add('changed', $k, $bv, $av) }
    }
    return $result
}

function Compare-List([object[]]$bList, [object[]]$aList, [string]$keyField, [string[]]$valueFields, [string]$catName) {
    $result = [CategoryResult]::new($catName)
    $bDict = @{}
    $aDict = @{}
    # Use bracket notation [$keyField] to avoid StrictMode errors on missing keys
    foreach ($item in $bList) { $kv = $item[$keyField]; if ($kv) { $bDict["$kv"] = $item } }
    foreach ($item in $aList) { $kv = $item[$keyField]; if ($kv) { $aDict["$kv"] = $item } }
    $allKeys = @($bDict.Keys) + @($aDict.Keys) | Sort-Object -Unique
    foreach ($k in $allKeys) {
        if (-not $bDict.ContainsKey($k)) {
            $av = ($valueFields | ForEach-Object { "$_=$(Format-Val $aDict[$k][$_])" }) -join ', '
            $result.Add('added', $k, '', $av)
        } elseif (-not $aDict.ContainsKey($k)) {
            $bv = ($valueFields | ForEach-Object { "$_=$(Format-Val $bDict[$k][$_])" }) -join ', '
            $result.Add('removed', $k, $bv, '')
        } else {
            $bv = ($valueFields | ForEach-Object { "$_=$(Format-Val $bDict[$k][$_])" }) -join ', '
            $av = ($valueFields | ForEach-Object { "$_=$(Format-Val $aDict[$k][$_])" }) -join ', '
            if ($bv -eq $av) { $result.Add('same', $k, $bv, $av) }
            else             { $result.Add('changed', $k, $bv, $av) }
        }
    }
    return $result
}

function Get-Prop([object]$obj, [string]$key) {
    if ($null -eq $obj) { return $null }
    if ($obj -is [System.Collections.IDictionary]) { return $obj[$key] }
    return $obj.$key
}

function As-Array([object]$v) {
    if ($null -eq $v) { return @() }
    if ($v -is [System.Collections.IEnumerable] -and $v -isnot [string]) { return @($v) }
    return @($v)
}

function As-Dict([object]$v) {
    if ($null -eq $v) { return @{} }
    if ($v -is [System.Collections.IDictionary]) { return $v }
    # PSCustomObject → hashtable
    $h = @{}
    $v.PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value }
    return $h
}

function Obj-To-Dict([object]$obj) {
    # Recursively convert PSCustomObject to hashtable
    if ($null -eq $obj) { return @{} }
    if ($obj -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in $obj.Keys) { $h[$k] = Obj-To-Dict $obj[$k] }
        return $h
    }
    if ($obj -is [System.Collections.IEnumerable] -and $obj -isnot [string]) {
        return @($obj | ForEach-Object { Obj-To-Dict $_ })
    }
    if ($obj -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        $obj.PSObject.Properties | ForEach-Object { $h[$_.Name] = Obj-To-Dict $_.Value }
        return $h
    }
    return $obj
}

# ============================================================
# Category comparators
# ============================================================

function Compare-Os($b, $a) {
    $bd = As-Dict (Obj-To-Dict $b)
    $ad = As-Dict (Obj-To-Dict $a)
    Compare-Dict $bd $ad 'os'
}

function Compare-Network($b, $a) {
    $results = [System.Collections.Generic.List[CategoryResult]]::new()

    # Interfaces
    $bi = @(As-Array (Get-Prop $b 'interfaces') | ForEach-Object { Obj-To-Dict $_ })
    $ai = @(As-Array (Get-Prop $a 'interfaces') | ForEach-Object { Obj-To-Dict $_ })
    $results.Add((Compare-List $bi $ai 'name' @('address','prefix') 'network/interfaces'))

    # Routes
    $br = @(As-Array (Get-Prop $b 'routes') | ForEach-Object { Obj-To-Dict $_ })
    $ar = @(As-Array (Get-Prop $a 'routes') | ForEach-Object { Obj-To-Dict $_ })
    $results.Add((Compare-List $br $ar 'destination' @('gateway','interface') 'network/routes'))

    # DNS (by interface)
    $bd = @(As-Array (Get-Prop $b 'dns_servers') | ForEach-Object { Obj-To-Dict $_ })
    $ad = @(As-Array (Get-Prop $a 'dns_servers') | ForEach-Object { Obj-To-Dict $_ })
    $results.Add((Compare-List $bd $ad 'interface' @('servers') 'network/dns'))

    # Hosts
    $bh = @(As-Array (Get-Prop $b 'hosts') | ForEach-Object { Obj-To-Dict $_ })
    $ah = @(As-Array (Get-Prop $a 'hosts') | ForEach-Object { Obj-To-Dict $_ })
    $results.Add((Compare-List $bh $ah 'ip' @('hostnames') 'network/hosts'))

    return $results
}

function Compare-Services($b, $a) {
    $bl = @(As-Array $b | ForEach-Object { Obj-To-Dict $_ })
    $al = @(As-Array $a | ForEach-Object { Obj-To-Dict $_ })
    Compare-List $bl $al 'name' @('status','start_type') 'services'
}

function Compare-Packages($b, $a) {
    $bl = @(As-Array $b | ForEach-Object { Obj-To-Dict $_ })
    $al = @(As-Array $a | ForEach-Object { Obj-To-Dict $_ })
    Compare-List $bl $al 'name' @('version','vendor') 'packages'
}

function Compare-Users($b, $a) {
    $results = [System.Collections.Generic.List[CategoryResult]]::new()
    $bUsers = @(As-Array (Get-Prop $b 'local_users') | ForEach-Object { Obj-To-Dict $_ })
    $aUsers = @(As-Array (Get-Prop $a 'local_users') | ForEach-Object { Obj-To-Dict $_ })
    $results.Add((Compare-List $bUsers $aUsers 'name' @('enabled','shell') 'users/local_users'))

    $bGroups = @(As-Array (Get-Prop $b 'local_groups') | ForEach-Object { Obj-To-Dict $_ })
    $aGroups = @(As-Array (Get-Prop $a 'local_groups') | ForEach-Object { Obj-To-Dict $_ })
    $results.Add((Compare-List $bGroups $aGroups 'name' @('members') 'users/local_groups'))
    return $results
}

function Compare-Filesystem($b, $a) {
    $bd = @(As-Array (Get-Prop $b 'drives') | ForEach-Object { Obj-To-Dict $_ })
    $ad = @(As-Array (Get-Prop $a 'drives') | ForEach-Object { Obj-To-Dict $_ })
    Compare-List $bd $ad 'drive' @('total_gb','used_gb','free_gb','used_pct') 'filesystem'
}

function Compare-Environment($b, $a) {
    $bd = As-Dict (Obj-To-Dict (Get-Prop $b 'machine'))
    $ad = As-Dict (Obj-To-Dict (Get-Prop $a 'machine'))
    Compare-Dict $bd $ad 'environment'
}

function Compare-Security($b, $a) {
    $results = [System.Collections.Generic.List[CategoryResult]]::new()
    $bp = @(As-Array (Get-Prop $b 'firewall_profiles') | ForEach-Object { Obj-To-Dict $_ })
    $ap = @(As-Array (Get-Prop $a 'firewall_profiles') | ForEach-Object { Obj-To-Dict $_ })
    if ($bp.Count -gt 0 -or $ap.Count -gt 0) {
        $results.Add((Compare-List $bp $ap 'name' @('enabled','inbound_action','outbound_action') 'security/firewall_profiles'))
    }
    $br = @(As-Array (Get-Prop $b 'firewall_rules') | ForEach-Object { Obj-To-Dict $_ })
    $ar = @(As-Array (Get-Prop $a 'firewall_rules') | ForEach-Object { Obj-To-Dict $_ })
    $results.Add((Compare-List $br $ar 'name' @('direction','action','profile') 'security/firewall_rules'))
    return $results
}

# ============================================================
# Console output
# ============================================================

function Write-CategoryConsole([CategoryResult]$r, [bool]$diffOnly) {
    $diffCount = $r.ChangedCount + $r.RemovedCount + $r.AddedCount
    $color = if ($diffCount -gt 0) { 'Yellow' } else { 'Green' }
    Write-Host ''
    Write-Host "=== $($r.Name.ToUpper()) ===" -ForegroundColor $color
    Write-Host "  same=$($r.SameCount)  changed=$($r.ChangedCount)  removed=$($r.RemovedCount)  added=$($r.AddedCount)"

    foreach ($item in $r.Items) {
        if ($diffOnly -and $item.State -eq 'same') { continue }
        $stateColor = switch ($item.State) {
            'same'    { 'DarkGray' }
            'changed' { 'Yellow' }
            'removed' { 'Red' }
            'added'   { 'Cyan' }
        }
        $stateLabel = switch ($item.State) {
            'same'    { 'SAME   ' }
            'changed' { 'CHANGED' }
            'removed' { 'REMOVED' }
            'added'   { 'ADDED  ' }
        }
        $key = $item.Key.PadRight(40)
        Write-Host "  $stateLabel  $key" -ForegroundColor $stateColor -NoNewline
        switch ($item.State) {
            'same'    { Write-Host " $($item.BeforeValue)" -ForegroundColor DarkGray }
            'changed' { Write-Host " before: $($item.BeforeValue)" -ForegroundColor Red -NoNewline; Write-Host "  after: $($item.AfterValue)" -ForegroundColor Green }
            'removed' { Write-Host " $($item.BeforeValue)" -ForegroundColor Red }
            'added'   { Write-Host " $($item.AfterValue)" -ForegroundColor Cyan }
        }
    }
}

# ============================================================
# HTML generation
# ============================================================

function ConvertTo-Html-Report {
    param(
        [hashtable]$bMeta,
        [hashtable]$aMeta,
        [System.Collections.Generic.List[CategoryResult]]$AllResults
    )

    $totalSame    = ($AllResults | Measure-Object -Property SameCount    -Sum).Sum
    $totalChanged = ($AllResults | Measure-Object -Property ChangedCount -Sum).Sum
    $totalRemoved = ($AllResults | Measure-Object -Property RemovedCount -Sum).Sum
    $totalAdded   = ($AllResults | Measure-Object -Property AddedCount   -Sum).Sum
    $totalDiff    = $totalChanged + $totalRemoved + $totalAdded

    $bHostname = if ($bMeta) { $bMeta['hostname'] } else { 'Before' }
    $aHostname = if ($aMeta) { $aMeta['hostname'] } else { 'After' }
    $bTime     = if ($bMeta) { $bMeta['collected_at'] } else { '' }
    $aTime     = if ($aMeta) { $aMeta['collected_at'] } else { '' }

    # Build category nav links
    $navLinks = ($AllResults | ForEach-Object { "<a href='#$($_.Name.Replace('/','_'))'>$($_.Name)</a>" }) -join ' | '

    # Build category HTML sections
    $catHtml = foreach ($r in $AllResults) {
        $anchorId = $r.Name.Replace('/','_')
        $diffCount = $r.ChangedCount + $r.RemovedCount + $r.AddedCount
        $badge = if ($diffCount -gt 0) { "<span class='badge badge-diff'>$diffCount diff</span>" } else { "<span class='badge badge-ok'>OK</span>" }
        $rows = foreach ($item in $r.Items) {
            $cls = $item.State
            $bvEsc = [System.Web.HttpUtility]::HtmlEncode($item.BeforeValue)
            $avEsc = [System.Web.HttpUtility]::HtmlEncode($item.AfterValue)
            $keyEsc = [System.Web.HttpUtility]::HtmlEncode($item.Key)
            "<tr class='$cls'><td class='key'>$keyEsc</td><td class='val-before'>$bvEsc</td><td class='val-after'>$avEsc</td></tr>"
        }
        $statsHtml = "same: $($r.SameCount) | <span class='txt-changed'>changed: $($r.ChangedCount)</span> | <span class='txt-removed'>removed: $($r.RemovedCount)</span> | <span class='txt-added'>added: $($r.AddedCount)</span>"

        @"
<section id="$anchorId" class="category">
  <h2>$($r.Name) $badge <small>$statsHtml</small></h2>
  <table>
    <thead><tr><th>Key / Name</th><th>Before ($bHostname)</th><th>After ($aHostname)</th></tr></thead>
    <tbody>$($rows -join "`n")</tbody>
  </table>
</section>
"@
    }

    $genTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    return @"
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Server Comparison Report</title>
<style>
* { box-sizing: border-box; margin: 0; padding: 0; }
body { font-family: 'Segoe UI', Arial, sans-serif; font-size: 13px; background: #f0f2f5; color: #222; }
a { color: #2563eb; text-decoration: none; }
a:hover { text-decoration: underline; }

.header { background: #1e293b; color: #fff; padding: 20px 24px; }
.header h1 { font-size: 20px; font-weight: 600; }
.header .sub { font-size: 12px; color: #94a3b8; margin-top: 4px; }
.header .nav { margin-top: 12px; font-size: 12px; }
.header .nav a { color: #93c5fd; margin-right: 10px; }

.summary { display: flex; gap: 12px; padding: 16px 24px; flex-wrap: wrap; }
.card { background: #fff; border-radius: 8px; padding: 16px 20px; text-align: center; flex: 1; min-width: 120px; box-shadow: 0 1px 3px rgba(0,0,0,.1); }
.card .num { font-size: 28px; font-weight: 700; }
.card .lbl { font-size: 11px; color: #64748b; margin-top: 2px; }
.card.ok    .num { color: #16a34a; }
.card.diff  .num { color: #d97706; }
.card.rem   .num { color: #dc2626; }
.card.add   .num { color: #2563eb; }

.servers { display: flex; gap: 12px; padding: 0 24px 16px; }
.server-card { background: #fff; border-radius: 8px; padding: 14px 18px; flex: 1; box-shadow: 0 1px 3px rgba(0,0,0,.1); }
.server-card .title { font-size: 11px; font-weight: 600; color: #64748b; text-transform: uppercase; }
.server-card .hostname { font-size: 16px; font-weight: 700; margin: 4px 0 2px; }
.server-card .meta { font-size: 11px; color: #64748b; }

.filter-bar { padding: 8px 24px; display: flex; gap: 8px; align-items: center; }
.filter-bar label { font-size: 12px; color: #64748b; margin-right: 4px; }
.filter-bar button { font-size: 12px; padding: 4px 12px; border: 1px solid #cbd5e1; border-radius: 4px; background: #fff; cursor: pointer; }
.filter-bar button.active { background: #1e293b; color: #fff; border-color: #1e293b; }

.category { background: #fff; margin: 0 24px 16px; border-radius: 8px; padding: 16px; box-shadow: 0 1px 3px rgba(0,0,0,.1); }
.category h2 { font-size: 15px; font-weight: 600; margin-bottom: 10px; display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
.category h2 small { font-size: 11px; color: #64748b; font-weight: 400; }

.badge { font-size: 11px; padding: 2px 8px; border-radius: 10px; font-weight: 600; }
.badge-ok   { background: #dcfce7; color: #16a34a; }
.badge-diff { background: #fef3c7; color: #d97706; }

table { width: 100%; border-collapse: collapse; font-size: 12px; }
th { background: #f1f5f9; padding: 7px 10px; text-align: left; font-weight: 600; color: #475569; border-bottom: 2px solid #e2e8f0; }
td { padding: 6px 10px; border-bottom: 1px solid #f1f5f9; vertical-align: top; word-break: break-all; }
tr:last-child td { border-bottom: none; }

tr.same    td { background: #f8fafc; color: #94a3b8; }
tr.changed td { background: #fffbeb; }
tr.changed td.key { color: #92400e; font-weight: 600; }
tr.changed td.val-before { color: #b91c1c; }
tr.changed td.val-after  { color: #15803d; }
tr.removed td { background: #fff1f2; }
tr.removed td.key { color: #9f1239; font-weight: 600; }
tr.removed td.val-before { color: #b91c1c; }
tr.added   td { background: #eff6ff; }
tr.added   td.key { color: #1e3a5f; font-weight: 600; }
tr.added   td.val-after { color: #1d4ed8; }

td.key { width: 28%; font-weight: 500; }
td.val-before, td.val-after { width: 36%; }

.hidden { display: none; }
.txt-changed { color: #d97706; }
.txt-removed { color: #dc2626; }
.txt-added   { color: #2563eb; }

.footer { text-align: center; padding: 20px; font-size: 11px; color: #94a3b8; }
</style>
</head>
<body>

<div class="header">
  <h1>&#128202; Server Comparison Report</h1>
  <div class="sub">Generated: $genTime</div>
  <div class="nav">$navLinks</div>
</div>

<div class="summary">
  <div class="card diff"><div class="num">$totalDiff</div><div class="lbl">Total Differences</div></div>
  <div class="card ok">  <div class="num">$totalSame</div><div class="lbl">Identical</div></div>
  <div class="card diff"><div class="num">$totalChanged</div><div class="lbl">Changed</div></div>
  <div class="card rem"> <div class="num">$totalRemoved</div><div class="lbl">Removed</div></div>
  <div class="card add"> <div class="num">$totalAdded</div><div class="lbl">Added</div></div>
</div>

<div class="servers">
  <div class="server-card">
    <div class="title">Before</div>
    <div class="hostname">$bHostname</div>
    <div class="meta">Collected: $bTime</div>
  </div>
  <div class="server-card">
    <div class="title">After</div>
    <div class="hostname">$aHostname</div>
    <div class="meta">Collected: $aTime</div>
  </div>
</div>

<div class="filter-bar">
  <label>Show:</label>
  <button class="active" onclick="filterRows('all',this)">All</button>
  <button onclick="filterRows('changed',this)">Changed</button>
  <button onclick="filterRows('removed',this)">Removed</button>
  <button onclick="filterRows('added',this)">Added</button>
  <button onclick="filterRows('diff',this)">Differences only</button>
</div>

$($catHtml -join "`n")

<div class="footer">ops-scripts Compare-ServerInfo.ps1 &bull; $genTime</div>

<script>
function filterRows(mode, btn) {
  document.querySelectorAll('.filter-bar button').forEach(b => b.classList.remove('active'));
  btn.classList.add('active');
  document.querySelectorAll('tbody tr').forEach(row => {
    var show = mode === 'all'
      || row.classList.contains(mode)
      || (mode === 'diff' && !row.classList.contains('same'));
    row.classList.toggle('hidden', !show);
  });
}
</script>
</body>
</html>
"@
}

# ============================================================
# Main
# ============================================================
try {
    Write-OpsLog -Level INFO -Message 'Pre-check start'

    if (-not (Test-Path -LiteralPath $Before)) {
        Write-OpsLog -Level ERROR -Message "Before file not found: $Before"
        $exitCode = 2; $status = 'failed'; exit $exitCode
    }
    if (-not (Test-Path -LiteralPath $After)) {
        Write-OpsLog -Level ERROR -Message "After file not found: $After"
        $exitCode = 2; $status = 'failed'; exit $exitCode
    }

    $bRaw = Get-Content -LiteralPath $Before -Encoding UTF8 -Raw | ConvertFrom-Json
    $aRaw = Get-Content -LiteralPath $After  -Encoding UTF8 -Raw | ConvertFrom-Json

    $bData = Obj-To-Dict $bRaw
    $aData = Obj-To-Dict $aRaw

    $bMeta = As-Dict (Obj-To-Dict ($bData['meta']))
    $aMeta = As-Dict (Obj-To-Dict ($aData['meta']))

    # Determine categories to compare
    $allCats   = @('os','network','services','packages','users','filesystem','environment','security')
    $availCats = $allCats | Where-Object { $bData.ContainsKey($_) -and $aData.ContainsKey($_) }
    $compareCats = if ($Category -contains 'all') { $availCats } else { $Category | Where-Object { $availCats -contains $_ } }

    Write-OpsLog -Level INFO -Message "Pre-check passed: categories=$($compareCats -join ',') diffOnly=$DiffOnly"
    Write-OpsLog -Level INFO -Message 'Main start'

    $allResults = [System.Collections.Generic.List[CategoryResult]]::new()

    foreach ($cat in $compareCats) {
        Write-OpsLog -Level INFO -Message "Comparing: $cat"
        $bCat = $bData[$cat]
        $aCat = $aData[$cat]
        $catResults = switch ($cat) {
            'os'          { @(Compare-Os         $bCat $aCat) }
            'network'     { @(Compare-Network    $bCat $aCat) }
            'services'    { @(Compare-Services   $bCat $aCat) }
            'packages'    { @(Compare-Packages   $bCat $aCat) }
            'users'       { @(Compare-Users      $bCat $aCat) }
            'filesystem'  { @(Compare-Filesystem $bCat $aCat) }
            'environment' { @(Compare-Environment $bCat $aCat) }
            'security'    { @(Compare-Security   $bCat $aCat) }
        }
        foreach ($cr in $catResults) { $allResults.Add($cr) }
    }

    # --- Console output ---
    Write-Host ''
    Write-Host '╔══════════════════════════════════════════════════════════╗' -ForegroundColor Cyan
    Write-Host "║  SERVER COMPARISON REPORT" -ForegroundColor Cyan
    Write-Host "║  Before : $($bMeta['hostname'])  ($($bMeta['collected_at']))" -ForegroundColor Cyan
    Write-Host "║  After  : $($aMeta['hostname'])  ($($aMeta['collected_at']))" -ForegroundColor Cyan
    Write-Host '╚══════════════════════════════════════════════════════════╝' -ForegroundColor Cyan

    foreach ($r in $allResults) {
        Write-CategoryConsole $r $DiffOnly.IsPresent
    }

    # Summary
    $totalDiff = ($allResults | ForEach-Object { $_.ChangedCount + $_.RemovedCount + $_.AddedCount } | Measure-Object -Sum).Sum
    Write-Host ''
    Write-Host '=== SUMMARY ===' -ForegroundColor Cyan
    foreach ($r in $allResults) {
        $d = $r.ChangedCount + $r.RemovedCount + $r.AddedCount
        $col = if ($d -gt 0) { 'Yellow' } else { 'Green' }
        Write-Host ("  {0,-30} same={1,4}  changed={2,4}  removed={3,4}  added={4,4}" -f $r.Name, $r.SameCount, $r.ChangedCount, $r.RemovedCount, $r.AddedCount) -ForegroundColor $col
    }
    Write-Host ''
    $summaryColor = if ($totalDiff -gt 0) { 'Yellow' } else { 'Green' }
    Write-Host "  Total differences: $totalDiff" -ForegroundColor $summaryColor
    Write-Host ''

    # --- HTML report ---
    if ($HtmlReport) {
        $htmlDir = Split-Path -Parent $HtmlReport
        if ($htmlDir -and -not (Test-Path $htmlDir)) { New-Item -ItemType Directory -Path $htmlDir -Force | Out-Null }
        Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
        $html = ConvertTo-Html-Report -bMeta $bMeta -aMeta $aMeta -AllResults $allResults
        [System.IO.File]::WriteAllText($HtmlReport, $html, [System.Text.Encoding]::UTF8)
        Write-OpsLog -Level INFO -Message "HTML report written: $HtmlReport"
        Write-Host "  HTML report: $HtmlReport" -ForegroundColor Green
    }

    Write-OpsLog -Level INFO -Message 'Main complete'
    $status = 'success'
}
catch {
    Write-OpsLog -Level ERROR -Message "Operation failed: error=$($_.Exception.Message)"
    $exitCode = 4; $status = 'failed'
}
finally {
    Write-OpsLog -Level INFO -Message "Script end: status=$status exitCode=$exitCode"
}

exit $exitCode
