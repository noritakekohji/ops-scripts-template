# `-FromJson` レポート再生成 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** cert-check / port-inventory / aws-instance-audit の3つの PowerShell ツールに `-FromJson <file>` を追加し、保存済み JSON を読み込んで収集を再実行せずにレポート（コンソール / JSON / HTML）を再生成できるようにする。

**Architecture:** 各ツールの「収集フェーズ」を「JSON 読み込み + 内部表現への復元」に差し替える。出力ロジック（`-Json` / `-HtmlReport` / `-FailOnly` / コンソール）は既存実装を 100% 再利用する。判定結果（OK/NG/WARN）は JSON 保存済みの値をそのまま使い、対象リスト（`.lst`）は不要。Windows (PowerShell) のみ実装し、Linux (`.sh`) は変更しない。

**Tech Stack:** PowerShell 5.1 / Pester / `ConvertFrom-Json`（ネイティブ）/ aws のみ HTML は既存 `render_report.py`（python3）

**Spec:** [`docs/superpowers/specs/2026-06-17-from-json-report-design.md`](../specs/2026-06-17-from-json-report-design.md)

---

## ファイルマップ

| 操作 | パス | 役割 |
|---|---|---|
| 作成 | `tests/pester/fixtures/from-json/cert_sample.json` | cert-check テスト用 fixture |
| 作成 | `tests/pester/fixtures/from-json/port_sample.json` | port-inventory テスト用 fixture |
| 作成 | `tests/pester/fixtures/from-json/aws_sample.json` | aws-instance-audit テスト用 fixture |
| 作成 | `tests/pester/CertCheckFromJson.Tests.ps1` | cert-check `-FromJson` テスト |
| 作成 | `tests/pester/PortInventoryFromJson.Tests.ps1` | port-inventory `-FromJson` テスト |
| 作成 | `tests/pester/AwsAuditFromJson.Tests.ps1` | aws `-FromJson` テスト |
| 修正 | `tools/cert-check/CertCheck.ps1` | `-FromJson` 追加 |
| 修正 | `tools/port-inventory/PortInventory.ps1` | `-FromJson` 追加 |
| 修正 | `tools/aws-instance-audit/Get-AwsInstanceAudit.ps1` | `-FromJson` 追加 |
| 修正 | `tools/cert-check/cert_check.bat` | usage コメント追記 |
| 修正 | `tools/port-inventory/port_inventory.bat` | usage コメント追記 |
| 修正 | `tools/aws-instance-audit/aws_instance_audit.bat` | usage コメント追記 |
| 修正 | 各ツール `README.md` | `-FromJson` 使用例 |
| 修正 | `CHANGELOG.md` | `[Unreleased]` に追記 |

---

## 共通ヘルパーの方針

cert-check / port-inventory は `Set-StrictMode -Version Latest` 下で動く。`ConvertFrom-Json`
が返す `PSCustomObject` の **存在しないプロパティへのアクセスは例外**になるため、欠落フィールドを
安全に取り出すヘルパーを各スクリプトに追加する（aws には既存の `Get-Prop` がある）。

```powershell
# StrictMode 下で JSON オブジェクトの欠落プロパティを安全に取得する
function Get-JsonProp($obj, [string]$name) {
    if ($null -eq $obj) { return $null }
    $pp = $obj.PSObject.Properties[$name]
    if ($pp) { return $pp.Value }
    return $null
}
```

---

## Task 1: cert-check `-FromJson`

**Files:**
- Create: `tests/pester/fixtures/from-json/cert_sample.json`
- Create: `tests/pester/CertCheckFromJson.Tests.ps1`
- Modify: `tools/cert-check/CertCheck.ps1`

### 背景（実装者向け）

`CertCheck.ps1` の現状の流れ:
- `param` の `$TargetList` は `[Parameter(Mandatory)]`（47行目）
- 収集ループ（375–421行）が `$results`（`[List[hashtable]]`）を構築。各要素は
  `host / port / desc / subject / issuer / not_after / days_remaining / warn_days / san / status / message / section` を持つ hashtable
- 出力フェーズ（427–533行）は `$displayResults`（FailOnly フィルタ後）と `$results`（サマリ集計）を使う
- HTML の `$meta.listFile`（510行）は `$TargetList` を参照
- JSON 出力フィールド（439–453行）: `host / port / description / subject / issuer / not_after / days_remaining / warn_days / san / status / message`（内部 `desc` ↔ JSON `description` に注意）

`-FromJson` は「収集ループをスキップして `$results` を JSON から復元する」だけ。出力フェーズは無改造。

- [ ] **Step 1: fixture を作成**

`tests/pester/fixtures/from-json/cert_sample.json`（OK / WARN / NG を1件ずつ）:

```json
[
  {
    "host": "ok.example.com",
    "port": 443,
    "description": "Healthy cert",
    "subject": "CN=ok.example.com",
    "issuer": "CN=Test CA",
    "not_after": "2027-01-01 00:00:00",
    "days_remaining": 200,
    "warn_days": 30,
    "san": ["ok.example.com"],
    "status": "OK",
    "message": ""
  },
  {
    "host": "warn.example.com",
    "port": 443,
    "description": "Expiring soon",
    "subject": "CN=warn.example.com",
    "issuer": "CN=Test CA",
    "not_after": "2026-07-01 00:00:00",
    "days_remaining": 13,
    "warn_days": 30,
    "san": ["warn.example.com"],
    "status": "WARN",
    "message": "Expires in 13 days (threshold: 30)"
  },
  {
    "host": "ng.example.com",
    "port": 443,
    "description": "Expired",
    "subject": "CN=ng.example.com",
    "issuer": "CN=Test CA",
    "not_after": "2026-01-01 00:00:00",
    "days_remaining": -5,
    "warn_days": 30,
    "san": [],
    "status": "NG",
    "message": "Certificate expired"
  }
]
```

- [ ] **Step 2: 失敗するテストを作成**

`tests/pester/CertCheckFromJson.Tests.ps1`:

```powershell
#Requires -Version 5.1
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $script:ps1     = Join-Path (Get-RepoRoot) 'tools\cert-check\CertCheck.ps1'
    $script:fixture = Join-Path $PSScriptRoot 'fixtures\from-json\cert_sample.json'
}

Describe 'CertCheck -FromJson' {
    It 'reads JSON and emits JSON with all records, exit 1 (WARN/NG present)' {
        $r = Invoke-Controller -ScriptPath $script:ps1 -Arguments @('-FromJson', $script:fixture, '-Json')
        $r.ExitCode | Should -Be 1
        $arr = @($r.StdOut | ConvertFrom-Json)
        $arr.Count | Should -Be 3
        ($arr | Where-Object { $_.host -eq 'ok.example.com' }).status | Should -Be 'OK'
    }

    It 'FailOnly hides OK rows' {
        $r = Invoke-Controller -ScriptPath $script:ps1 -Arguments @('-FromJson', $script:fixture, '-Json', '-FailOnly')
        $arr = @($r.StdOut | ConvertFrom-Json)
        $arr.Count | Should -Be 2
        ($arr | Where-Object { $_.status -eq 'OK' }).Count | Should -Be 0
    }

    It 'generates an HTML report containing host names' {
        $work = New-TempWorkdir
        try {
            $html = Join-Path $work 'cert.html'
            $r = Invoke-Controller -ScriptPath $script:ps1 -Arguments @('-FromJson', $script:fixture, '-HtmlReport', $html)
            Test-Path -LiteralPath $html | Should -Be $true
            (Get-Content -LiteralPath $html -Raw) | Should -Match 'ng\.example\.com'
        } finally { Remove-TempPath $work }
    }

    It 'missing file exits 2' {
        $r = Invoke-Controller -ScriptPath $script:ps1 -Arguments @('-FromJson', 'C:\no\such\file.json')
        $r.ExitCode | Should -Be 2
    }

    It 'broken JSON exits 1' {
        $work = New-TempWorkdir
        try {
            $bad = Join-Path $work 'bad.json'
            'not json {' | Set-Content -LiteralPath $bad -Encoding UTF8
            $r = Invoke-Controller -ScriptPath $script:ps1 -Arguments @('-FromJson', $bad)
            $r.ExitCode | Should -Be 1
        } finally { Remove-TempPath $work }
    }

    It 'no -TargetList and no -FromJson exits 1' {
        $r = Invoke-Controller -ScriptPath $script:ps1 -Arguments @()
        $r.ExitCode | Should -Be 1
    }
}
```

- [ ] **Step 3: テストが失敗することを確認**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester 'tests\pester\CertCheckFromJson.Tests.ps1' -Output Detailed"`
Expected: FAIL（`-FromJson` 未実装、`-TargetList` Mandatory のためパラメータエラー）

- [ ] **Step 4: param を変更**

`tools/cert-check/CertCheck.ps1` の `param` ブロック（45–52行）を次に置き換える:

```powershell
[CmdletBinding()]
param(
    [string]$TargetList = '',
    [int]$TimeoutSec    = 10,
    [string]$HtmlReport = '',
    [string]$FromJson   = '',
    [switch]$Json,
    [switch]$FailOnly
)
```

- [ ] **Step 5: Get-JsonProp ヘルパーを追加**

`Set-StrictMode -Version Latest`（55行目）の直後に追加:

```powershell
# StrictMode 下で JSON オブジェクトの欠落プロパティを安全に取得する
function Get-JsonProp($obj, [string]$name) {
    if ($null -eq $obj) { return $null }
    $pp = $obj.PSObject.Properties[$name]
    if ($pp) { return $pp.Value }
    return $null
}
```

- [ ] **Step 6: 収集ループを FromJson 分岐で囲む**

現状の「収集ヘッダ表示 + 収集ループ」（おおよそ 367–421 行：`Write-Host` のヘッダから
`$results.Add($certResult)` を含む `foreach` の終わりまで）を、次の構造に置き換える。
**`$results` の構築をこのブロックで完結させる**こと（出力フェーズ 427 行以降は無改造）。

```powershell
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

    # ── 既存の収集ヘッダ + 収集ループをここに丸ごと移動する ──
    # （367–421 行の Write-Host ヘッダ / targets パース / foreach 収集ループ /
    #   $results.Add($certResult) をそのまま、ただし `$results = ...new()` の
    #   再初期化行は上で済ませたので削除する）
}
```

> 実装注意:
> - 既存コードに `$TargetList` の存在チェックが収集ループ内 / パーサ側にある場合は重複させない。
>   この else ブロック冒頭の存在チェックを正とし、既存の重複チェックは削除する。
> - 既存収集ループ内の `$results = [System.Collections.Generic.List[hashtable]]::new()`
>   初期化行（372 行相当）は上に移したので **else 内からは削除**する。

- [ ] **Step 7: HTML meta の listFile を FromJson 対応にする**

`$meta`（509–513行）を次に変更:

```powershell
    $meta = @{
        listFile = if ($FromJson) { [System.IO.Path]::GetFileName($FromJson) } else { [System.IO.Path]::GetFileName($TargetList) }
        timeout  = $TimeoutSec
        hostname = $env:COMPUTERNAME
    }
```

- [ ] **Step 8: テストを実行して全パス確認**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester 'tests\pester\CertCheckFromJson.Tests.ps1' -Output Detailed"`
Expected: 6 passed

- [ ] **Step 9: 既存テストが壊れていないか確認**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester 'tests\pester\CertCheck.Tests.ps1' -Output Detailed"`
Expected: 既存テストが全て pass（`-TargetList` の Mandatory 解除が回帰を起こしていないこと）

> 注: `tests/pester/CertCheck.Tests.ps1` が存在しない場合はこの Step をスキップしてよい。

- [ ] **Step 10: コミット**

```bash
git add tests/pester/fixtures/from-json/cert_sample.json tests/pester/CertCheckFromJson.Tests.ps1 tools/cert-check/CertCheck.ps1
git commit -m "feat(cert-check): add -FromJson to regenerate report from saved JSON"
```

---

## Task 2: port-inventory `-FromJson`

**Files:**
- Create: `tests/pester/fixtures/from-json/port_sample.json`
- Create: `tests/pester/PortInventoryFromJson.Tests.ps1`
- Modify: `tools/port-inventory/PortInventory.ps1`

### 背景（実装者向け）

`PortInventory.ps1` の現状の流れ:
- `param`（49–55行）に `$ExpectedList`（任意）。`$hasExpectedList` フラグ（493行）
- 収集（512行 `$actual = Get-ListeningPorts`）→ `$outputRows` 構築（531–550行）
- `$displayRows`（FailOnly フィルタ、557行）→ 出力（566–640行）
- サマリ（642–654行）は `$hasExpectedList` と `$actual.Count` を参照
- JSON 出力フィールド（570–578行）: `port / proto / address / process / pid / path / status / description`
  （JSON 構造と内部 `$outputRows` の hashtable 構造が一致）

`-FromJson` は「収集 + `$outputRows` 構築をスキップして JSON から `$outputRows` を復元」する。
サマリで `$actual` を参照する行が StrictMode 下で未定義例外にならないよう注意する。

- [ ] **Step 1: fixture を作成**

`tests/pester/fixtures/from-json/port_sample.json`（OK / NG / INFO を1件ずつ）:

```json
[
  {
    "port": 443,
    "proto": "tcp",
    "address": "0.0.0.0",
    "process": "nginx",
    "pid": 1234,
    "path": "/usr/sbin/nginx",
    "status": "OK",
    "description": "HTTPS"
  },
  {
    "port": 23,
    "proto": "tcp",
    "address": "0.0.0.0",
    "process": "telnetd",
    "pid": 666,
    "path": "/usr/sbin/telnetd",
    "status": "NG",
    "description": "Telnet must be closed"
  },
  {
    "port": 8080,
    "proto": "tcp",
    "address": "127.0.0.1",
    "process": "java",
    "pid": 4321,
    "path": "/usr/bin/java",
    "status": "INFO",
    "description": ""
  }
]
```

- [ ] **Step 2: 失敗するテストを作成**

`tests/pester/PortInventoryFromJson.Tests.ps1`:

```powershell
#Requires -Version 5.1
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $script:ps1     = Join-Path (Get-RepoRoot) 'tools\port-inventory\PortInventory.ps1'
    $script:fixture = Join-Path $PSScriptRoot 'fixtures\from-json\port_sample.json'
}

Describe 'PortInventory -FromJson' {
    It 'reads JSON and emits JSON with all rows, exit 1 (NG present)' {
        $r = Invoke-Controller -ScriptPath $script:ps1 -Arguments @('-FromJson', $script:fixture, '-Json')
        $r.ExitCode | Should -Be 1
        $arr = @($r.StdOut | ConvertFrom-Json)
        $arr.Count | Should -Be 3
        ($arr | Where-Object { $_.port -eq 23 }).status | Should -Be 'NG'
    }

    It 'FailOnly keeps only NG/WARN' {
        $r = Invoke-Controller -ScriptPath $script:ps1 -Arguments @('-FromJson', $script:fixture, '-Json', '-FailOnly')
        $arr = @($r.StdOut | ConvertFrom-Json)
        $arr.Count | Should -Be 1
        $arr[0].status | Should -Be 'NG'
    }

    It 'generates an HTML report containing a process name' {
        $work = New-TempWorkdir
        try {
            $html = Join-Path $work 'port.html'
            $r = Invoke-Controller -ScriptPath $script:ps1 -Arguments @('-FromJson', $script:fixture, '-HtmlReport', $html)
            Test-Path -LiteralPath $html | Should -Be $true
            (Get-Content -LiteralPath $html -Raw) | Should -Match 'telnetd'
        } finally { Remove-TempPath $work }
    }

    It 'missing file exits 2' {
        $r = Invoke-Controller -ScriptPath $script:ps1 -Arguments @('-FromJson', 'C:\no\such\file.json')
        $r.ExitCode | Should -Be 2
    }

    It 'broken JSON exits 1' {
        $work = New-TempWorkdir
        try {
            $bad = Join-Path $work 'bad.json'
            'not json {' | Set-Content -LiteralPath $bad -Encoding UTF8
            $r = Invoke-Controller -ScriptPath $script:ps1 -Arguments @('-FromJson', $bad)
            $r.ExitCode | Should -Be 1
        } finally { Remove-TempPath $work }
    }
}
```

- [ ] **Step 3: テストが失敗することを確認**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester 'tests\pester\PortInventoryFromJson.Tests.ps1' -Output Detailed"`
Expected: FAIL（`-FromJson` 未実装）

- [ ] **Step 4: param を変更**

`tools/port-inventory/PortInventory.ps1` の `param` ブロック（49–55行）を次に置き換える:

```powershell
[CmdletBinding()]
param(
    [string]$ExpectedList = '',
    [string]$HtmlReport   = '',
    [string]$FromJson     = '',
    [switch]$Json,
    [switch]$FailOnly
)
```

- [ ] **Step 5: Get-JsonProp ヘルパーを追加**

`Set-StrictMode -Version Latest`（58行目）の直後に追加:

```powershell
# StrictMode 下で JSON オブジェクトの欠落プロパティを安全に取得する
function Get-JsonProp($obj, [string]$name) {
    if ($null -eq $obj) { return $null }
    $pp = $obj.PSObject.Properties[$name]
    if ($pp) { return $pp.Value }
    return $null
}
```

- [ ] **Step 6: 収集を FromJson 分岐で囲む**

「Phase 4: Main processing」の収集（508–550行：`Write-Host` の収集ヘッダから
`$outputRows` 構築の終わりまで）を次に置き換える。**`$outputRows` をこのブロックで確定**させる。

```powershell
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
    # ── 既存の収集をここに丸ごと移動する ──
    # （508–550 行：収集ヘッダ Write-Host / $actual = Get-ListeningPorts /
    #   $hasExpectedList による監査 / $outputRows 構築 をそのまま）
}
```

- [ ] **Step 7: サマリの $actual 参照を FromJson 安全にする**

サマリ部（642–654行）の `$hasExpectedList` 分岐に FromJson を考慮する。
`Write-Host "Summary: ..."` の分岐（649–654行）を次に置き換える:

```powershell
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
```

- [ ] **Step 8: HTML meta を FromJson 対応にする**

`$meta`（630–634行）を次に変更:

```powershell
    $meta = @{
        hostname = $env:COMPUTERNAME
        listFile = if ($fromJsonMode) { [System.IO.Path]::GetFileName($FromJson) }
                   elseif ($hasExpectedList) { [System.IO.Path]::GetFileName($ExpectedList) }
                   else { '(none)' }
        mode     = if ($fromJsonMode) { 'FromJson' }
                   elseif ($hasExpectedList) { 'Audit' }
                   else { 'Inventory' }
    }
```

- [ ] **Step 9: テストを実行して全パス確認**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester 'tests\pester\PortInventoryFromJson.Tests.ps1' -Output Detailed"`
Expected: 5 passed

- [ ] **Step 10: コミット**

```bash
git add tests/pester/fixtures/from-json/port_sample.json tests/pester/PortInventoryFromJson.Tests.ps1 tools/port-inventory/PortInventory.ps1
git commit -m "feat(port-inventory): add -FromJson to regenerate report from saved JSON"
```

---

## Task 3: aws-instance-audit `-FromJson`

**Files:**
- Create: `tests/pester/fixtures/from-json/aws_sample.json`
- Create: `tests/pester/AwsAuditFromJson.Tests.ps1`
- Modify: `tools/aws-instance-audit/Get-AwsInstanceAudit.ps1`

### 背景（実装者向け）

`Get-AwsInstanceAudit.ps1` は他2ツールと構造が違う:
- 出力は `$result | ConvertTo-Json` を `$OutputPath` に書く。コンソールテーブルも `-Json` フラグも無い
- **HTML レンダラ `render_report.py` は元々 JSON ファイルを入力に取る**（`render_report.py <input.json> <output.html>`、362行）
- 前提チェック: aws CLI（72行 → 無ければ exit 10）、HTML 時のみ python3（76–79行）
- `Get-Prop` ヘルパー（63行）と `$renderPy`（48行）は既存

したがって `-FromJson` は「aws CLI を呼ばず、保存済み JSON をそのまま render に渡す / コピーする」
早期分岐として実装するのが最もシンプル。**aws CLI チェックの前**に分岐して exit する。

- [ ] **Step 1: fixture を作成**

`tests/pester/fixtures/from-json/aws_sample.json`:

```json
{
  "meta": {
    "tool": "aws_instance_audit",
    "collected_at": "2026-06-17 10:00:00",
    "hostname": "web01",
    "region": "ap-northeast-1",
    "instance_id": "i-0abc123def456",
    "categories": "all"
  },
  "instance": {
    "instance_id": "i-0abc123def456",
    "instance_type": "t3.medium",
    "ami_id": "ami-0123456789",
    "availability_zone": "ap-northeast-1a",
    "region": "ap-northeast-1",
    "private_ip": "10.0.1.10",
    "public_ip": "",
    "vpc_id": "vpc-0aaa",
    "subnet_id": "subnet-0bbb",
    "tags": { "Name": "web01" }
  }
}
```

- [ ] **Step 2: 失敗するテストを作成**

`tests/pester/AwsAuditFromJson.Tests.ps1`:

```powershell
#Requires -Version 5.1
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $script:ps1     = Join-Path (Get-RepoRoot) 'tools\aws-instance-audit\Get-AwsInstanceAudit.ps1'
    $script:fixture = Join-Path $PSScriptRoot 'fixtures\from-json\aws_sample.json'

    $py = Get-Command python3 -ErrorAction SilentlyContinue
    if (-not $py) { $py = Get-Command python -ErrorAction SilentlyContinue }
    $script:hasPython = [bool]$py
}

Describe 'Get-AwsInstanceAudit -FromJson' {
    It 'copies JSON to -OutputPath and exits 0' {
        $work = New-TempWorkdir
        try {
            $out = Join-Path $work 'copied.json'
            $r = Invoke-Controller -ScriptPath $script:ps1 -Arguments @('-FromJson', $script:fixture, '-OutputPath', $out)
            $r.ExitCode | Should -Be 0
            Test-Path -LiteralPath $out | Should -Be $true
            $obj = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json
            $obj.meta.instance_id | Should -Be 'i-0abc123def456'
        } finally { Remove-TempPath $work }
    }

    It 'generates an HTML report from saved JSON' -Skip:(-not $script:hasPython) {
        $work = New-TempWorkdir
        try {
            $html = Join-Path $work 'aws.html'
            $r = Invoke-Controller -ScriptPath $script:ps1 -Arguments @('-FromJson', $script:fixture, '-HtmlReport', $html)
            $r.ExitCode | Should -Be 0
            Test-Path -LiteralPath $html | Should -Be $true
            (Get-Content -LiteralPath $html -Raw) | Should -Match 'i-0abc123def456'
        } finally { Remove-TempPath $work }
    }

    It 'missing file exits 2' {
        $r = Invoke-Controller -ScriptPath $script:ps1 -Arguments @('-FromJson', 'C:\no\such\file.json')
        $r.ExitCode | Should -Be 2
    }

    It 'broken JSON exits 1' {
        $work = New-TempWorkdir
        try {
            $bad = Join-Path $work 'bad.json'
            'not json {' | Set-Content -LiteralPath $bad -Encoding UTF8
            $r = Invoke-Controller -ScriptPath $script:ps1 -Arguments @('-FromJson', $bad)
            $r.ExitCode | Should -Be 1
        } finally { Remove-TempPath $work }
    }
}
```

- [ ] **Step 3: テストが失敗することを確認**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester 'tests\pester\AwsAuditFromJson.Tests.ps1' -Output Detailed"`
Expected: FAIL（`-FromJson` 未実装。aws CLI 不在環境では exit 10 になる）

- [ ] **Step 4: param に -FromJson を追加**

`param` ブロック（34–40行）を次に置き換える:

```powershell
[CmdletBinding()]
param(
    [string]$Category = 'all',
    [string]$OutputPath = '',
    [string]$HtmlReport = '',
    [string]$Region = '',
    [string]$FromJson = ''
)
```

- [ ] **Step 5: FromJson 早期分岐を追加**

aws CLI チェック（70–72行の `$awsCmd = Get-Command aws ...`）の **直前**に挿入する。
`Get-Prop`（63行）と `$renderPy`（48行）は既に定義済みなのでそのまま使える:

```powershell
# ── FromJson: 保存済み JSON からレポートを再生成（収集・aws CLI 不要）──
if ($FromJson) {
    if (-not (Test-Path -LiteralPath $FromJson)) {
        Write-Log 'ERROR' "FromJson file not found: $FromJson"
        exit 2
    }
    try {
        $fj = Get-Content -LiteralPath $FromJson -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Log 'ERROR' "Failed to parse JSON: $FromJson"
        exit 1
    }
    if (-not (Get-Prop $fj 'meta')) {
        Write-Log 'ERROR' 'Invalid structure: top-level "meta" object not found'
        exit 1
    }

    # HTML レポート（python3 + render_report.py、入力は FromJson 自身）
    if ($HtmlReport) {
        $pyCmd = Get-Command python3 -ErrorAction SilentlyContinue
        if (-not $pyCmd) { $pyCmd = Get-Command python -ErrorAction SilentlyContinue }
        if (-not $pyCmd) { Write-Log 'ERROR' 'python3 not found (required for HTML report)'; exit 10 }
        if (-not (Test-Path $renderPy)) { Write-Log 'ERROR' "render_report.py not found: $renderPy"; exit 5 }
        & $pyCmd.Source $renderPy $FromJson $HtmlReport
        if ($LASTEXITCODE -ne 0) { Write-Log 'ERROR' 'HTML render failed'; exit 5 }
        Write-Log 'INFO' "HTML report: $HtmlReport"
    }

    # OutputPath 指定時は JSON をコピー
    if ($OutputPath) {
        $outDir = Split-Path -Parent $OutputPath
        if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
        Copy-Item -LiteralPath $FromJson -Destination $OutputPath -Force
        Write-Log 'INFO' "JSON copied: $OutputPath"
    }

    $m = Get-Prop $fj 'meta'
    Write-Host ''
    Write-Host '  AWS instance audit (from JSON)'
    Write-Host "  instance_id : $([string](Get-Prop $m 'instance_id'))"
    Write-Host "  collected_at: $([string](Get-Prop $m 'collected_at'))"
    if ($OutputPath) { Write-Host "  JSON: $OutputPath" }
    if ($HtmlReport) { Write-Host "  HTML: $HtmlReport" }
    Write-Host ''
    exit 0
}
```

- [ ] **Step 6: テストを実行して全パス確認**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester 'tests\pester\AwsAuditFromJson.Tests.ps1' -Output Detailed"`
Expected: 4 passed（python3 不在なら HTML テストは Skipped で 3 passed / 1 skipped）

- [ ] **Step 7: コミット**

```bash
git add tests/pester/fixtures/from-json/aws_sample.json tests/pester/AwsAuditFromJson.Tests.ps1 tools/aws-instance-audit/Get-AwsInstanceAudit.ps1
git commit -m "feat(aws-instance-audit): add -FromJson to regenerate report from saved JSON"
```

---

## Task 4: ドキュメント更新 + 既存ツール点検

**Files:**
- Modify: `tools/cert-check/cert_check.bat`
- Modify: `tools/port-inventory/port_inventory.bat`
- Modify: `tools/aws-instance-audit/aws_instance_audit.bat`
- Modify: `tools/cert-check/README.md`
- Modify: `tools/port-inventory/README.md`
- Modify: `tools/aws-instance-audit/README.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: 各 bat の usage コメントに -FromJson を追記**

`tools/cert-check/cert_check.bat` の Usage コメント（`Usage:` 行付近）に1行追加:

```
::   cert_check.bat -FromJson <saved.json> [-HtmlReport file] [-Json] [-FailOnly]
```

`tools/port-inventory/port_inventory.bat` の Usage コメントに追加:

```
::   port_inventory.bat -FromJson <saved.json> [-HtmlReport file] [-Json] [-FailOnly]
```

`tools/aws-instance-audit/aws_instance_audit.bat` の Usage コメントに追加:

```
::   aws_instance_audit.bat -FromJson <saved.json> [-OutputPath file] [-HtmlReport file]
```

> bat は `%*` で全引数を透過するため、コード変更は不要（コメントのみ）。

- [ ] **Step 2: 各 README に -FromJson セクションを追記**

`tools/cert-check/README.md` の使い方セクション末尾に追加:

```markdown
### 保存済み JSON からレポート再生成（Windows のみ）

過去に `-Json` で保存した結果を読み込み、収集せずにレポートを再生成できます。

```powershell
# JSON を再表示
.\CertCheck.ps1 -FromJson saved.json -Json

# HTML レポートを生成
.\CertCheck.ps1 -FromJson saved.json -HtmlReport report.html

# NG/WARN のみ
.\CertCheck.ps1 -FromJson saved.json -FailOnly
```

判定（OK/WARN/NG）は JSON に保存された値をそのまま使うため、対象リストは不要です。
```

`tools/port-inventory/README.md` の使い方セクション末尾に追加:

```markdown
### 保存済み JSON からレポート再生成（Windows のみ）

過去に `-Json` で保存した結果を読み込み、収集せずにレポートを再生成できます。

```powershell
.\PortInventory.ps1 -FromJson saved.json -Json
.\PortInventory.ps1 -FromJson saved.json -HtmlReport report.html
.\PortInventory.ps1 -FromJson saved.json -FailOnly
```

判定（OK/NG/WARN/INFO）は JSON に保存された値をそのまま使うため、期待値リストは不要です。
```

`tools/aws-instance-audit/README.md` の使い方セクション末尾に追加:

```markdown
### 保存済み JSON からレポート再生成（Windows のみ）

過去に保存した監査 JSON を読み込み、aws CLI を呼ばずに HTML レポートを再生成できます。

```powershell
# HTML レポートを生成（python3 が必要）
.\Get-AwsInstanceAudit.ps1 -FromJson saved.json -HtmlReport report.html

# JSON を別パスへコピー
.\Get-AwsInstanceAudit.ps1 -FromJson saved.json -OutputPath copy.json
```
```

- [ ] **Step 3: server-snapshot / perf-monitor の点検**

既存機能で「保存済み JSON からのレポート」をカバー済みであることを確認する（コード変更なし）:

```bash
grep -n "compare" tools/server-snapshot/README.md
grep -n "report" tools/perf-monitor/README.md
```

Expected: server-snapshot は `compare before.json after.json`、perf-monitor は `report <session_dir>`
の記載があること。記載があれば追加対応は不要。**無い場合のみ**、各 README に1行
「保存済みデータからのレポート再生成は `compare` / `report` を参照」を追記する。

- [ ] **Step 4: CHANGELOG に追記**

`CHANGELOG.md` の `[Unreleased]` の `### Added` に追加:

```markdown
- `cert-check` / `port-inventory` / `aws-instance-audit` に `-FromJson` を追加。保存済み JSON を読み込み、収集を再実行せずにレポート（コンソール / JSON / HTML）を再生成できる（Windows / PowerShell のみ）
```

- [ ] **Step 5: 全 FromJson テストをまとめて実行**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester 'tests\pester\CertCheckFromJson.Tests.ps1','tests\pester\PortInventoryFromJson.Tests.ps1','tests\pester\AwsAuditFromJson.Tests.ps1' -Output Detailed"`
Expected: 全 pass（aws HTML は python3 不在時 Skipped）

- [ ] **Step 6: エンコーディング検証**

Run: `bash ci/template-check/check_template.sh`
Expected: 新規追加ファイルによる violation が増えていないこと（既存の pre-existing violation は無視可）

- [ ] **Step 7: コミット**

```bash
git add tools/cert-check/cert_check.bat tools/port-inventory/port_inventory.bat tools/aws-instance-audit/aws_instance_audit.bat tools/cert-check/README.md tools/port-inventory/README.md tools/aws-instance-audit/README.md CHANGELOG.md
git commit -m "docs(from-json): document -FromJson in bat/README/CHANGELOG"
```

---

## 自己レビューチェックリスト

| 仕様項目 | 対応タスク |
|---|---|
| cert-check に `-FromJson` | Task 1 |
| port-inventory に `-FromJson` | Task 2 |
| aws-instance-audit に `-FromJson` | Task 3 |
| 既存出力モード（console/JSON/HTML/FailOnly）の再利用 | Task 1–3（出力フェーズ無改造） |
| 判定は JSON 保存値そのまま | Task 1–3（status を復元、再判定しない） |
| ファイル不在 → exit 2 | Task 1–3 各異常系テスト |
| 壊れた JSON → exit 1 | Task 1–3 各異常系テスト |
| Linux (.sh) 変更なし | （全タスクで .sh を触らない） |
| bat は usage 追記のみ | Task 4 Step 1 |
| README / CHANGELOG | Task 4 Step 2,4 |
| server-snapshot / perf-monitor は点検のみ | Task 4 Step 3 |
| Pester のみ（bats なし） | Task 1–3 |
