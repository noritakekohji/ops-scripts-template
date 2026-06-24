#Requires -Version 5.1
<#
.SYNOPSIS
    Collect-snapshot の ZIP を解凍し、HTML レポートを一括生成するツール。

.DESCRIPTION
    Phase 1: Parameter parsing / defaults
    Phase 2: ZIP extraction to temp directory
    Phase 3: JSON discovery (server-snapshot / port-inventory / aws-instance-audit)
    Phase 4: Report generation (single snapshot summary or two-snapshot comparison)
    Phase 5: Cleanup temp directory, output report path

    Single mode:  1 つの ZIP からサマリ HTML を生成
    Compare mode: 2 つの ZIP を解凍し compare_server_info.py で差分レポートを生成

.PARAMETER ZipPath
    対象の ZIP ファイルパス（必須）。

.PARAMETER CompareWith
    比較対象の ZIP ファイルパス。指定すると差分レポートモードになる。

.PARAMETER OutputDir
    レポート出力先ディレクトリ。既定は ZIP と同じディレクトリ。

.PARAMETER DiffOnly
    Compare モードで差分のみ表示する。

.PARAMETER KeepExtracted
    解凍したファイルを削除せず残す。

.EXAMPLE
    .\ReportSnapshot.ps1 -ZipPath .\snapshots\host_label_20260617.zip
    .\ReportSnapshot.ps1 -ZipPath before.zip -CompareWith after.zip
    .\ReportSnapshot.ps1 -ZipPath .\snapshots\*.zip -OutputDir .\reports

.NOTES
    Exit codes:
      0  Success
      1  Bad arguments / ZIP not found
      2  JSON not found in ZIP
     10  Prerequisite missing (python3 for compare mode)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$ZipPath,

    [string]$CompareWith = '',
    [string]$OutputDir   = '',
    [switch]$DiffOnly,
    [switch]$KeepExtracted
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ToolsDir  = Split-Path -Parent $ScriptDir

# ============================================================
# Helpers
# ============================================================

function Resolve-ZipPath {
    param([string]$Path)
    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $resolved) {
        Write-Error "[report-snapshot] ZIP not found: $Path"
        return $null
    }
    return $resolved.Path
}

function Expand-SnapshotZip {
    param([string]$ZipFile, [string]$DestDir)
    if (-not (Test-Path $DestDir)) {
        [void](New-Item -ItemType Directory -Path $DestDir -Force)
    }
    Expand-Archive -LiteralPath $ZipFile -DestinationPath $DestDir -Force
    return $DestDir
}

function Find-JsonInDir {
    param([string]$BaseDir, [string]$SubDir)
    $targetDir = Get-ChildItem -LiteralPath $BaseDir -Directory -Recurse |
        Where-Object { $_.Name -eq $SubDir } |
        Select-Object -First 1
    if (-not $targetDir) { return $null }
    $json = Get-ChildItem -LiteralPath $targetDir.FullName -Filter '*.json' |
        Select-Object -First 1
    if (-not $json) { return $null }
    return $json.FullName
}

function Read-JsonFile {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) { return $null }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $text = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    } else {
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    }
    $lines = $text -split "`n"
    $jsonStart = -1
    $jsonEnd   = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $trimmed = $lines[$i].Trim()
        if ($jsonStart -lt 0 -and ($trimmed -match '^\[' -or $trimmed -match '^\{')) {
            $jsonStart = $i
        }
    }
    if ($jsonStart -lt 0) { return $null }
    for ($i = $lines.Count - 1; $i -ge $jsonStart; $i--) {
        $trimmed = $lines[$i].Trim()
        if ($trimmed -match '^\]' -or $trimmed -match '^\}') {
            $jsonEnd = $i
            break
        }
    }
    if ($jsonEnd -lt $jsonStart) { $jsonEnd = $lines.Count - 1 }
    $jsonText = ($lines[$jsonStart..$jsonEnd]) -join "`n"
    return ($jsonText | ConvertFrom-Json)
}

function HtmlEncode {
    param([string]$S)
    return $S.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

function Get-SafeProp {
    param($Obj, [string]$Name)
    if ($null -eq $Obj) { return $null }
    if ($Obj.PSObject.Properties.Match($Name).Count -gt 0) { return $Obj.$Name }
    return $null
}

# ============================================================
# Single snapshot HTML report
# ============================================================

function Build-OsSummaryRows {
    param($OsData)
    if (-not $OsData) { return '' }
    $rows = ''
    foreach ($prop in ($OsData.PSObject.Properties | Sort-Object Name)) {
        $val = if ($null -eq $prop.Value) { '' } else { "$($prop.Value)" }
        $rows += "<tr><td class='key'>$(HtmlEncode $prop.Name)</td><td>$(HtmlEncode $val)</td></tr>`n"
    }
    return $rows
}

function Build-ListTableRows {
    param($List, [string[]]$Columns)
    if (-not $List) { return '' }
    $items = @($List)
    $rows = ''
    foreach ($item in $items) {
        $cells = ''
        foreach ($col in $Columns) {
            $val = $null
            if ($item.PSObject.Properties.Match($col).Count -gt 0) { $val = $item.$col }
            if ($null -eq $val) { $val = '' }
            if ($val -is [System.Collections.IEnumerable] -and $val -isnot [string]) {
                $val = ($val | ForEach-Object { "$_" }) -join ', '
            }
            $cells += "<td>$(HtmlEncode "$val")</td>"
        }
        $rows += "<tr>$cells</tr>`n"
    }
    return $rows
}

function Build-DictSection {
    param($Dict, [string]$Title)
    if (-not $Dict) { return '' }
    $rows = ''
    foreach ($prop in ($Dict.PSObject.Properties | Sort-Object Name)) {
        $val = if ($null -eq $prop.Value) { '' } else { "$($prop.Value)" }
        $rows += "<tr><td class='key'>$(HtmlEncode $prop.Name)</td><td>$(HtmlEncode $val)</td></tr>`n"
    }
    if (-not $rows) { return '' }
    return @"
<section class="cat">
  <h2>$(HtmlEncode $Title)</h2>
  <table><thead><tr><th>Key</th><th>Value</th></tr></thead>
  <tbody>$rows</tbody></table>
</section>
"@
}

function Build-SnapshotHtml {
    param($ServerJson, $PortJson, $AwsJson, [string]$ZipName, [string]$Generated)

    $meta        = Get-SafeProp $ServerJson 'meta'
    $hostname    = if ($meta) { $v = Get-SafeProp $meta 'hostname'; if ($v) { $v } else { '(unknown)' } } else { '(unknown)' }
    $collectedAt = if ($meta) { $v = Get-SafeProp $meta 'collected_at'; if ($v) { $v } else { '' } } else { '' }

    $sections = ''

    # OS
    $osData = Get-SafeProp $ServerJson 'os'
    if ($osData) {
        $osRows = Build-OsSummaryRows $osData
        $sections += @"
<section class="cat">
  <h2>OS</h2>
  <table><thead><tr><th>Property</th><th>Value</th></tr></thead>
  <tbody>$osRows</tbody></table>
</section>
"@
    }

    # Network
    $net = Get-SafeProp $ServerJson 'network'
    if ($net) {
        $ifData = Get-SafeProp $net 'interfaces'
        if ($ifData) {
            $ifRows = Build-ListTableRows $ifData @('name','address','prefix')
            $sections += @"
<section class="cat">
  <h2>Network - Interfaces</h2>
  <table><thead><tr><th>Name</th><th>Address</th><th>Prefix</th></tr></thead>
  <tbody>$ifRows</tbody></table>
</section>
"@
        }
        $dnsData = Get-SafeProp $net 'dns_servers'
        if ($dnsData) {
            $dnsRows = Build-ListTableRows $dnsData @('interface','servers')
            $sections += @"
<section class="cat">
  <h2>Network - DNS</h2>
  <table><thead><tr><th>Interface</th><th>Servers</th></tr></thead>
  <tbody>$dnsRows</tbody></table>
</section>
"@
        }
        $rtData = Get-SafeProp $net 'routes'
        if ($rtData) {
            $rtRows = Build-ListTableRows $rtData @('destination','gateway','interface','metric')
            $sections += @"
<section class="cat">
  <h2>Network - Routes</h2>
  <table><thead><tr><th>Destination</th><th>Gateway</th><th>Interface</th><th>Metric</th></tr></thead>
  <tbody>$rtRows</tbody></table>
</section>
"@
        }
    }

    # Services
    $svcData = Get-SafeProp $ServerJson 'services'
    if ($svcData) {
        $svcRows = Build-ListTableRows $svcData @('name','status','start_type')
        $svcCount = @($svcData).Count
        $sections += @"
<section class="cat">
  <h2>Services <span class="badge bok">$svcCount</span></h2>
  <table><thead><tr><th>Name</th><th>Status</th><th>Start Type</th></tr></thead>
  <tbody>$svcRows</tbody></table>
</section>
"@
    }

    # Packages
    $pkgData = Get-SafeProp $ServerJson 'packages'
    if ($pkgData) {
        $pkgRows = Build-ListTableRows $pkgData @('name','version','vendor')
        $pkgCount = @($pkgData).Count
        $sections += @"
<section class="cat">
  <h2>Packages <span class="badge bok">$pkgCount</span></h2>
  <table><thead><tr><th>Name</th><th>Version</th><th>Vendor</th></tr></thead>
  <tbody>$pkgRows</tbody></table>
</section>
"@
    }

    # Users
    $usrData = Get-SafeProp $ServerJson 'users'
    if ($usrData) {
        $localUsers = Get-SafeProp $usrData 'local_users'
        if ($localUsers) {
            $usrRows = Build-ListTableRows $localUsers @('name','enabled','full_name')
            $sections += @"
<section class="cat">
  <h2>Users - Local Users</h2>
  <table><thead><tr><th>Name</th><th>Enabled</th><th>Full Name</th></tr></thead>
  <tbody>$usrRows</tbody></table>
</section>
"@
        }
        $localGroups = Get-SafeProp $usrData 'local_groups'
        if ($localGroups) {
            $grpRows = Build-ListTableRows $localGroups @('name','members')
            $sections += @"
<section class="cat">
  <h2>Users - Local Groups</h2>
  <table><thead><tr><th>Name</th><th>Members</th></tr></thead>
  <tbody>$grpRows</tbody></table>
</section>
"@
        }
    }

    # Filesystem
    $fsData = Get-SafeProp $ServerJson 'filesystem'
    if ($fsData) {
        $drvData = Get-SafeProp $fsData 'drives'
        if ($drvData) {
            $drvRows = Build-ListTableRows $drvData @('drive','total_gb','used_gb','free_gb','used_pct','fstype','label')
            $sections += @"
<section class="cat">
  <h2>Filesystem - Drives</h2>
  <table><thead><tr><th>Drive</th><th>Total GB</th><th>Used GB</th><th>Free GB</th><th>Used %</th><th>FS Type</th><th>Label</th></tr></thead>
  <tbody>$drvRows</tbody></table>
</section>
"@
        }
    }

    # Environment
    $envData = Get-SafeProp $ServerJson 'environment'
    if ($envData) {
        $machineEnv = Get-SafeProp $envData 'machine'
        if ($machineEnv) {
            $sections += Build-DictSection $machineEnv 'Environment - Machine'
        }
    }

    # Security
    $secData = Get-SafeProp $ServerJson 'security'
    if ($secData) {
        $fwProfiles = Get-SafeProp $secData 'firewall_profiles'
        if ($fwProfiles) {
            $fwRows = Build-ListTableRows $fwProfiles @('name','enabled','inbound_action','outbound_action')
            $sections += @"
<section class="cat">
  <h2>Security - Firewall Profiles</h2>
  <table><thead><tr><th>Name</th><th>Enabled</th><th>Inbound</th><th>Outbound</th></tr></thead>
  <tbody>$fwRows</tbody></table>
</section>
"@
        }
    }

    # Patches
    $ptchData = Get-SafeProp $ServerJson 'patches'
    if ($ptchData) {
        $ptchRows = Build-ListTableRows $ptchData @('id','description','installed_on')
        $ptchCount = @($ptchData).Count
        $sections += @"
<section class="cat">
  <h2>Patches <span class="badge bok">$ptchCount</span></h2>
  <table><thead><tr><th>ID</th><th>Description</th><th>Installed On</th></tr></thead>
  <tbody>$ptchRows</tbody></table>
</section>
"@
    }

    # Tuning
    $tuneData = Get-SafeProp $ServerJson 'tuning'
    if ($tuneData) {
        $sections += Build-DictSection $tuneData 'Tuning'
    }

    # Scheduled
    $schData = Get-SafeProp $ServerJson 'scheduled'
    if ($schData) {
        $schTasks = Get-SafeProp $schData 'scheduled_tasks'
        if ($schTasks) {
            $taskRows = Build-ListTableRows $schTasks @('name','state','path')
            $sections += @"
<section class="cat">
  <h2>Scheduled Tasks</h2>
  <table><thead><tr><th>Name</th><th>State</th><th>Path</th></tr></thead>
  <tbody>$taskRows</tbody></table>
</section>
"@
        }
    }

    # Middleware
    $mwData = Get-SafeProp $ServerJson 'middleware'
    if ($mwData) {
        foreach ($prop in $mwData.PSObject.Properties) {
            $product = $prop.Name
            $instances = @($prop.Value)
            if ($instances.Count -eq 0) { continue }
            $cols = @($instances[0].PSObject.Properties.Name | Where-Object { $_ -ne 'config_files' -and $_ -ne 'profiles' })
            $mwRows = Build-ListTableRows $instances $cols
            $header = ($cols | ForEach-Object { "<th>$(HtmlEncode $_)</th>" }) -join ''
            $sections += @"
<section class="cat">
  <h2>Middleware - $(HtmlEncode $product)</h2>
  <table><thead><tr>$header</tr></thead>
  <tbody>$mwRows</tbody></table>
</section>
"@
        }
    }

    # Port Inventory
    if ($PortJson) {
        $ports = @($PortJson)
        $portRows = Build-ListTableRows $ports @('port','proto','address','process','pid','status')
        $sections += @"
<section class="cat">
  <h2>Port Inventory <span class="badge bok">$($ports.Count)</span></h2>
  <table><thead><tr><th>Port</th><th>Proto</th><th>Address</th><th>Process</th><th>PID</th><th>Status</th></tr></thead>
  <tbody>$portRows</tbody></table>
</section>
"@
    }

    # AWS Instance Audit
    if ($AwsJson) {
        $sections += Build-DictSection $AwsJson 'AWS Instance Audit'
    }

    # Category navigation
    $catNames = @()
    if (Get-SafeProp $ServerJson 'os')          { $catNames += 'OS' }
    if (Get-SafeProp $ServerJson 'network')      { $catNames += 'Network' }
    if (Get-SafeProp $ServerJson 'services')     { $catNames += 'Services' }
    if (Get-SafeProp $ServerJson 'packages')     { $catNames += 'Packages' }
    if (Get-SafeProp $ServerJson 'users')        { $catNames += 'Users' }
    if (Get-SafeProp $ServerJson 'filesystem')   { $catNames += 'Filesystem' }
    if (Get-SafeProp $ServerJson 'environment')  { $catNames += 'Environment' }
    if (Get-SafeProp $ServerJson 'security')     { $catNames += 'Security' }
    if ($PortJson)                               { $catNames += 'Port Inventory' }

    $nav = ($catNames | ForEach-Object { $_ }) -join ' | '

    $html = @"
<!DOCTYPE html><html lang="ja"><head><meta charset="UTF-8">
<title>Snapshot Report - $(HtmlEncode $hostname)</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Segoe UI',Arial,sans-serif;font-size:13px;background:#f0f2f5;color:#222}
.header{background:#1e293b;color:#fff;padding:20px 24px}
.header h1{font-size:20px;font-weight:600}
.header .sub{font-size:12px;color:#94a3b8;margin-top:4px}
.header .nav{margin-top:10px;font-size:12px;color:#93c5fd}
.summary{display:flex;gap:12px;padding:16px 24px;flex-wrap:wrap}
.card{background:#fff;border-radius:8px;padding:16px 20px;text-align:center;flex:1;min-width:110px;box-shadow:0 1px 3px rgba(0,0,0,.1)}
.card .num{font-size:28px;font-weight:700}.card .lbl{font-size:11px;color:#64748b;margin-top:2px}
.card .num{color:#1e40af}
.info{display:flex;gap:12px;padding:0 24px 16px;flex-wrap:wrap}
.info-card{background:#fff;border-radius:8px;padding:12px 16px;flex:1;box-shadow:0 1px 3px rgba(0,0,0,.1);font-size:12px}
.info-card .lbl{font-size:11px;color:#64748b;margin-bottom:4px}
.cat{background:#fff;margin:0 24px 16px;border-radius:8px;padding:16px;box-shadow:0 1px 3px rgba(0,0,0,.1)}
.cat h2{font-size:15px;font-weight:600;margin-bottom:10px;display:flex;align-items:center;gap:8px;flex-wrap:wrap}
.badge{font-size:11px;padding:2px 8px;border-radius:10px;font-weight:600}
.bok{background:#dcfce7;color:#16a34a}
table{width:100%;border-collapse:collapse;font-size:12px}
th{background:#f1f5f9;padding:7px 10px;text-align:left;font-weight:600;color:#475569;border-bottom:2px solid #e2e8f0}
td{padding:6px 10px;border-bottom:1px solid #f1f5f9;vertical-align:top;word-break:break-all}
tr:last-child td{border-bottom:none}
tr:hover td{background:#f8fafc}
td.key{width:30%;font-weight:500;color:#334155}
.filter-bar{padding:8px 24px;display:flex;gap:8px;align-items:center;flex-wrap:wrap}
.filter-bar label{font-size:12px;color:#64748b;margin-right:4px}
.filter-bar input{font-size:12px;padding:4px 12px;border:1px solid #cbd5e1;border-radius:4px}
.footer{text-align:center;padding:16px;font-size:11px;color:#94a3b8}
</style></head><body>
<div class="header">
  <h1>&#128202; Snapshot Report</h1>
  <div class="sub">Generated: $(HtmlEncode $Generated)</div>
  <div class="nav">$nav</div>
</div>
<div class="info">
  <div class="info-card"><div class="lbl">HOST</div><strong>$(HtmlEncode $hostname)</strong></div>
  <div class="info-card"><div class="lbl">COLLECTED</div><strong>$(HtmlEncode $collectedAt)</strong></div>
  <div class="info-card"><div class="lbl">SOURCE</div><code style="font-size:11px">$(HtmlEncode $ZipName)</code></div>
</div>
<div class="summary">
  <div class="card"><div class="num">$(if ($svcData) { @($svcData).Count } else { '-' })</div><div class="lbl">Services</div></div>
  <div class="card"><div class="num">$(if ($pkgData) { @($pkgData).Count } else { '-' })</div><div class="lbl">Packages</div></div>
  <div class="card"><div class="num">$(if ($PortJson) { @($PortJson).Count } else { '-' })</div><div class="lbl">Ports</div></div>
  <div class="card"><div class="num">$(if ($ptchData) { @($ptchData).Count } else { '-' })</div><div class="lbl">Patches</div></div>
</div>
<div class="filter-bar">
  <label>Filter:</label>
  <input type="text" id="tblFilter" placeholder="Type to filter tables..." oninput="filterTables(this.value)">
</div>
$sections
<div class="footer">ReportSnapshot.ps1 &bull; $(HtmlEncode $Generated)</div>
<script>
function filterTables(q) {
  q = q.toLowerCase();
  document.querySelectorAll('.cat tbody tr').forEach(function(r) {
    r.style.display = r.textContent.toLowerCase().indexOf(q) >= 0 ? '' : 'none';
  });
}
</script></body></html>
"@
    return $html
}

# ============================================================
# Compare mode (delegates to compare_server_info.py)
# ============================================================

function Invoke-CompareReport {
    param(
        [string]$BeforeJson,
        [string]$AfterJson,
        [string]$HtmlPath,
        [bool]$OnlyDiff
    )

    $pyScript = Join-Path $ToolsDir 'server-snapshot\compare_server_info.py'
    if (-not (Test-Path $pyScript)) {
        Write-Error "[report-snapshot] compare_server_info.py not found: $pyScript"
        return 2
    }

    $python = $null
    foreach ($candidate in @('python3', 'python')) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($null -ne $cmd) { $python = $cmd.Source; break }
    }
    if (-not $python) {
        Write-Error "[report-snapshot] python3 / python not found (required for compare mode)"
        return 10
    }

    $pyArgs = @($pyScript, $BeforeJson, $AfterJson)
    if ($HtmlPath)  { $pyArgs += '--html';      $pyArgs += $HtmlPath }
    if ($OnlyDiff)  { $pyArgs += '--diff-only' }

    Write-Host "[report-snapshot] Running compare_server_info.py ..."
    & $python @pyArgs
    $ec = $LASTEXITCODE
    if ($null -eq $ec) { $ec = 0 }
    return $ec
}

# ============================================================
# Main
# ============================================================

# Validate inputs
$ZipPath = $ZipPath.Trim('"').Trim("'")
$resolvedZip = Resolve-ZipPath $ZipPath
if (-not $resolvedZip) { exit 1 }

$isCompare = $false
$resolvedCompare = $null
if ($CompareWith) {
    $CompareWith = $CompareWith.Trim('"').Trim("'")
    $resolvedCompare = Resolve-ZipPath $CompareWith
    if (-not $resolvedCompare) { exit 1 }
    $isCompare = $true
}

if (-not $OutputDir) {
    $OutputDir = Split-Path -Parent $resolvedZip
}
if (-not (Test-Path $OutputDir)) {
    [void](New-Item -ItemType Directory -Path $OutputDir -Force)
}

$tempBase = Join-Path ([System.IO.Path]::GetTempPath()) "report-snapshot-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
[void](New-Item -ItemType Directory -Path $tempBase -Force)

try {
    # Extract ZIP(s)
    Write-Host "[report-snapshot] Extracting: $(Split-Path -Leaf $resolvedZip) ..."
    $extractDir1 = Join-Path $tempBase 'zip1'
    Expand-SnapshotZip -ZipFile $resolvedZip -DestDir $extractDir1

    if ($isCompare) {
        Write-Host "[report-snapshot] Extracting: $(Split-Path -Leaf $resolvedCompare) ..."
        $extractDir2 = Join-Path $tempBase 'zip2'
        Expand-SnapshotZip -ZipFile $resolvedCompare -DestDir $extractDir2
    }

    # Discover JSONs
    $serverJson1 = Find-JsonInDir $extractDir1 'server-snapshot'
    $portJson1   = Find-JsonInDir $extractDir1 'port-inventory'
    $awsJson1    = Find-JsonInDir $extractDir1 'aws-instance-audit'

    if (-not $serverJson1 -and -not $portJson1) {
        Write-Error "[report-snapshot] No JSON files found in ZIP"
        exit 2
    }

    $zipBaseName = [System.IO.Path]::GetFileNameWithoutExtension($resolvedZip)
    $generated   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

    if ($isCompare) {
        # Compare mode
        $serverJson2 = Find-JsonInDir $extractDir2 'server-snapshot'
        if (-not $serverJson1 -or -not $serverJson2) {
            Write-Error "[report-snapshot] server-snapshot JSON required in both ZIPs for compare mode"
            exit 2
        }

        $zipBaseName2 = [System.IO.Path]::GetFileNameWithoutExtension($resolvedCompare)
        $htmlName = "compare_${zipBaseName}_vs_${zipBaseName2}.html"
        $htmlPath = Join-Path $OutputDir $htmlName

        $ec = Invoke-CompareReport -BeforeJson $serverJson1 -AfterJson $serverJson2 `
                                   -HtmlPath $htmlPath -OnlyDiff $DiffOnly.IsPresent
        if ($ec -ne 0) { exit $ec }

        Write-Host "[report-snapshot] Compare report: $htmlPath" -ForegroundColor Green

    } else {
        # Single snapshot report
        $serverData = Read-JsonFile $serverJson1
        $portData   = Read-JsonFile $portJson1
        $awsData    = Read-JsonFile $awsJson1

        $htmlName = "report_${zipBaseName}.html"
        $htmlPath = Join-Path $OutputDir $htmlName

        Write-Host "[report-snapshot] Generating snapshot report ..."
        $html = Build-SnapshotHtml -ServerJson $serverData -PortJson $portData `
                                   -AwsJson $awsData -ZipName (Split-Path -Leaf $resolvedZip) `
                                   -Generated $generated

        [System.IO.File]::WriteAllText(
            $htmlPath,
            $html,
            [System.Text.UTF8Encoding]::new($false)
        )
        Write-Host "[report-snapshot] HTML report: $htmlPath" -ForegroundColor Green
    }

    # Copy extracted files if requested
    if ($KeepExtracted) {
        $keepDir = Join-Path $OutputDir $zipBaseName
        if (Test-Path $keepDir) { Remove-Item -LiteralPath $keepDir -Recurse -Force }
        Copy-Item -LiteralPath $extractDir1 -Destination $keepDir -Recurse -Force
        # Rename 'zip1' inner folder structure
        Write-Host "[report-snapshot] Extracted files kept: $keepDir"
        if ($isCompare) {
            $keepDir2 = Join-Path $OutputDir $zipBaseName2
            if (Test-Path $keepDir2) { Remove-Item -LiteralPath $keepDir2 -Recurse -Force }
            Copy-Item -LiteralPath $extractDir2 -Destination $keepDir2 -Recurse -Force
            Write-Host "[report-snapshot] Extracted files kept: $keepDir2"
        }
    }

    exit 0

} finally {
    if (Test-Path $tempBase) {
        Remove-Item -LiteralPath $tempBase -Recurse -Force -ErrorAction SilentlyContinue
    }
}
