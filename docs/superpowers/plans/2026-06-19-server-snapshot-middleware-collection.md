# server-snapshot ミドルウェア情報取得 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** server-snapshot に `middleware` カテゴリを追加し、SAP HANA / SAP NW・S4 / SQL Server / Tomcat の構成（バージョン・状態・ポート・設定ファイル全文）を機密マスク付きで収集・比較できるようにする。

**Architecture:** 既存のカテゴリ駆動収集（PS: `Invoke-Collect` の dispatch switch / sh: `CAT_MAP`）に `middleware` を足し、`Get-MiddlewareInfo`（PS）/`collect_middleware`（python3）が製品別ヘルパを集約する。設定ファイルは単一の共通ヘルパ（マスク+サイズ上限+sha256+権限を FileEntry 化）を通す。compare は新比較器 `Compare-Middleware` を足すだけでカテゴリ駆動レポートに反映される。

**Tech Stack:** PowerShell 5.1 (CIM/レジストリ/sqlcmd) / Bash + 埋め込み python3 / Pester / bats

**Spec:** [`docs/superpowers/specs/2026-06-19-server-snapshot-middleware-collection-design.md`](../specs/2026-06-19-server-snapshot-middleware-collection-design.md)

---

## 対象ファイル

| パス | 役割 |
|---|---|
| `tools/server-snapshot/ServerSnapshot.ps1` | Windows 収集 + compare |
| `tools/server-snapshot/server_snapshot.sh` | Linux 収集（埋め込み python3）+ compare 呼び出し |
| `tools/server-snapshot/middleware.conf` | 検出/マスク/上限の上書き設定（**新規・LF**） |
| `tests/pester/ServerSnapshot.Tests.ps1` | Windows 収集テスト（既存に追記） |
| `tests/bats/server_snapshot.bats` | Linux 収集テスト（既存に追記） |
| `tools/server-snapshot/README.md` / `CHANGELOG.md` | ドキュメント |

## 共通の前提（全タスク）

- **両OS 1:1**: トップは `middleware` で揃える。製品サブキーは**検出ゼロなら省略**（OS 適用差はこれで吸収。Windows は hana/sap が自然に省略される）。
- **自己完結**: `scripts_*/lib/` 非依存。`middleware.conf` はツール同梱。PS は `$PSScriptRoot\middleware.conf`、sh は bash が `_OPS_MW_CONF` を export して python に渡す。
- **フォールバック**: コマンド無し/権限無し/パース失敗は当該項目を空または FileEntry の `reason` 付きで記録し、収集全体は止めない。
- **PS5.1**: `??`/`?:`/`?.` 禁止。`Set-StrictMode -Version Latest` 下で欠落プロパティに触れない。`Safe-Exec`（`function Safe-Exec([scriptblock]$Block,[string]$Label)`、`-Label`/`-Block` 名前付きで呼ぶ）を使う。
- **python**: 例外は `except Exception: pass` で黙って握りつぶす（既存 collector 規約）。stderr に書かない。ファイル読取は `Path(...).read_text()`。
- **エンコーディング**: `.ps1`=UTF-8 BOM、`.sh`/`.bats`/`.conf`=BOM なし LF。git の「LF→CRLF」警告（.ps1）は想定内。
- **コミット**: ワークツリーに無関係な変更があるため `git add -A` 禁止。各タスクの指定ファイルだけ add。main 直コミット可。
- **埋め込み python の検証**: `.sh` 編集後は `python3 - << 'PYEOF'` 〜 `PYEOF` のブロックを抽出して `ast.parse` で構文確認すること。

---

## Task 1: middleware カテゴリ枠 + conf + 製品ヘルパ stub

`middleware` を受理し、`Get-MiddlewareInfo`/`collect_middleware` が製品別ヘルパ（この時点では空配列を返す stub）を集約する枠を作る。`middleware.conf` も新規作成。

**Files:**
- Modify: `tools/server-snapshot/ServerSnapshot.ps1`（`$validCategories`:39 / `$allCategories`:395 / dispatch switch:425 / `$allCats`:871 / `Get-SecurityInfo` の後に関数追加）
- Modify: `tools/server-snapshot/server_snapshot.sh`（`all_cats`:131 / `CAT_MAP`:554 / 製品 stub + `collect_middleware` / `_OPS_MW_CONF` export）
- Create: `tools/server-snapshot/middleware.conf`
- Test: `tests/pester/ServerSnapshot.Tests.ps1`

- [ ] **Step 1: 失敗するテストを書く** — `tests/pester/ServerSnapshot.Tests.ps1` に追記

```powershell
Describe 'ServerSnapshot middleware scaffold' {
    It 'collect accepts middleware and writes a middleware object' {
        $work = New-TempWorkdir
        try {
            $out = Join-Path $work 'snap.json'
            $r = Invoke-Controller -ScriptPath $script:ps1 `
                -Arguments @('collect','-Category','middleware','-OutputPath',$out)
            $r.ExitCode | Should -Be 0
            $obj = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json
            $obj.PSObject.Properties.Name | Should -Contain 'middleware'
        } finally { Remove-TempPath $work }
    }
}
```

- [ ] **Step 2: 失敗を確認**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester 'tests\pester\ServerSnapshot.Tests.ps1' -Output Detailed"`
Expected: FAIL（`middleware` は validCategories 外 → exit 1）。

- [ ] **Step 3: PS にカテゴリ枠を追加**

1. 39行 `$validCategories` 末尾に `,'middleware'` を追加。
2. 395行 `$allCategories` 末尾に `,'middleware'` を追加。
3. 871行 `$allCats` 末尾に `,'middleware'` を追加。
4. 425行付近 dispatch switch（`$result[$cat] = switch ($cat) { ... }`）に追加:

```powershell
            'middleware'  { Get-MiddlewareInfo }
```

5. `Get-SecurityInfo`（282行）の後に集約関数 + 製品 stub を追加:

```powershell
function Get-MiddlewareInfo {
    Write-Host '  Collecting: middleware ...'
    $conf = Read-MwConf
    $r = [ordered]@{}
    $hana = @(Get-MwHana      $conf); if ($hana.Count) { $r['hana']      = $hana }
    $sap  = @(Get-MwSap       $conf); if ($sap.Count)  { $r['sap']       = $sap }
    $sql  = @(Get-MwSqlServer $conf); if ($sql.Count)  { $r['sqlserver'] = $sql }
    $tom  = @(Get-MwTomcat    $conf); if ($tom.Count)  { $r['tomcat']    = $tom }
    $r
}

# Stubs (real impl in later tasks)
function Get-MwHana($conf)      { @() }
function Get-MwSap($conf)       { @() }
function Get-MwSqlServer($conf) { @() }
function Get-MwTomcat($conf)    { @() }

# conf reader stub (real impl in Task 2)
function Read-MwConf { @{} }
```

> 注: 製品 stub は空配列を返すので全製品キーが省略され、`middleware` は `{}` で出力される（テストは存在のみ確認）。

- [ ] **Step 4: sh にカテゴリ枠を追加**

1. 131行 `all_cats` の末尾に ` middleware` を追加。
2. `collect_scheduled`（528行）の後に stub + 集約を追加（埋め込み python 内）:

```python
def _mw_load_conf(): return {}   # real impl in Task 2
def _mw_hana(conf):      return []
def _mw_sap(conf):       return []
def _mw_sqlserver(conf): return []
def _mw_tomcat(conf):    return []

def _mw_assemble(conf):
    r = {}
    for key, fn in (('hana', _mw_hana), ('sap', _mw_sap),
                    ('sqlserver', _mw_sqlserver), ('tomcat', _mw_tomcat)):
        try:
            items = fn(conf)
        except Exception:
            items = []
        if items:            # detected-zero -> omit key (OS 1:1)
            r[key] = items
    return r

def collect_middleware():
    conf = _mw_load_conf()
    return _mw_assemble(conf)
```

> Task 2 で `collect_middleware` に `_OPS_MW_PROBE` 分岐を足す（probe があれば `{'_probe': ...}` を返す）。本タスクでは上記の通常版でよい。

3. 554行 `CAT_MAP` に追加: `'middleware': collect_middleware,`
4. `collect_snapshot()` 内の python 呼び出し前（`export _OPS_OUTPUT=...` の近く、145行付近）に追加:

```bash
    export _OPS_MW_CONF="${SCRIPT_DIR}/middleware.conf"
```

5. 埋め込み python 冒頭の import 行（148行）に `Path` が無ければ追加（既に `from pathlib import Path` 済み。確認のみ）。

- [ ] **Step 5: middleware.conf を新規作成（LF, BOM なし）**

`tools/server-snapshot/middleware.conf`:

```ini
# server-snapshot middleware collection config.
# Auto-detection is the default; entries here ADD to or override detection.
# Leave list values empty to use auto-detection only.

[hana]
sids =
config_globs = /usr/sap/%SID%/SYS/global/hdb/custom/config/*.ini

[sap]
sids =
profile_globs = /usr/sap/%SID%/SYS/profile/*

[sqlserver]
instances =
connect = auto

[tomcat]
bases =
config_names = server.xml,web.xml,context.xml,catalina.properties,setenv.sh,setenv.bat

[masking]
patterns = password,passwd,pwd,secret,key,credential,token,connectionstring

[limits]
max_file_kb = 256
```

- [ ] **Step 6: テストが通ることを確認**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester 'tests\pester\ServerSnapshot.Tests.ps1' -Output Detailed"`
Expected: PASS

- [ ] **Step 7: 埋め込み python 構文確認 + 回帰 + コミット**

```bash
start=$(grep -n "python3 - << 'PYEOF'" tools/server-snapshot/server_snapshot.sh | head -1 | cut -d: -f1)
end=$(awk 'NR>'"$start"' && /^PYEOF$/{print NR; exit}' tools/server-snapshot/server_snapshot.sh)
sed -n "$((start+1)),$((end-1))p" tools/server-snapshot/server_snapshot.sh | python -c "import ast,sys; ast.parse(sys.stdin.read()); print('PY OK')"
bash ci/template-check/check_template.sh   # 新規 violation がないこと
git add tools/server-snapshot/ServerSnapshot.ps1 tools/server-snapshot/server_snapshot.sh tools/server-snapshot/middleware.conf tests/pester/ServerSnapshot.Tests.ps1
git commit -m "feat(server-snapshot): scaffold middleware category + conf"
```

---

## Task 2: 共通ヘルパ（conf パーサ + FileEntry/マスク）

設定ファイルを FileEntry 化する単一実装点と conf パーサを実装する。全製品コレクタがこれを使う。

**Files:**
- Modify: `tools/server-snapshot/ServerSnapshot.ps1`（`Read-MwConf` stub 置換 + `Read-MwConfigFile`/`Mask-MwSecrets` 追加）
- Modify: `tools/server-snapshot/server_snapshot.sh`（`_mw_load_conf` stub 置換 + `_mw_read_file`/`_mw_mask` 追加）
- Test: `tests/pester/ServerSnapshot.Tests.ps1` / `tests/bats/server_snapshot.bats`

- [ ] **Step 1: Pester テスト（失敗）** — 追記

```powershell
Describe 'ServerSnapshot middleware file helper' {
    It 'Read-MwConfigFile masks secrets, sets sha256/size, and flags too_large/not_found' {
        $work = New-TempWorkdir
        try {
            $f = Join-Path $work 'app.conf'
            "user = admin`r`npassword = s3cr3t`r`nport = 8080" | Set-Content -LiteralPath $f -Encoding UTF8
            # dot-source the script's functions in a child PS and exercise Read-MwConfigFile
            $script = @"
. '$($script:ps1 -replace "'","''")' *> `$null
"@
            # NOTE: ServerSnapshot.ps1 runs on load; instead call via a tiny probe collect.
            $out = Join-Path $work 'snap.json'
            $r = Invoke-Controller -ScriptPath $script:ps1 -Arguments @('collect','-Category','middleware','-OutputPath',$out) -Env @{ _OPS_MW_PROBE = $f }
            $r.ExitCode | Should -Be 0
        } finally { Remove-TempPath $work }
    }
}
```

> 実装注: `ServerSnapshot.ps1` は読み込み時に param 処理＋実行されるため、関数だけを dot-source できない。ヘルパの単体検証は **専用の probe 経路**で行う。`Get-MiddlewareInfo` の冒頭に「`$env:_OPS_MW_PROBE` が設定されていればそのファイルを `Read-MwConfigFile` で読み、`_probe` キーに入れて返す」テスト用フックを足す:
>
> ```powershell
>     if ($env:_OPS_MW_PROBE) {
>         $conf = Read-MwConf
>         return @{ _probe = (Read-MwConfigFile -Path $env:_OPS_MW_PROBE -MaskPatterns $conf['mask_patterns'] -MaxFileKb $conf['max_file_kb']) }
>     }
> ```
>
> その上でテストを下記の確定版に置き換える:

```powershell
Describe 'ServerSnapshot middleware file helper' {
    It 'masks secrets and records sha256/size; missing file flagged' {
        $work = New-TempWorkdir
        try {
            $f = Join-Path $work 'app.conf'
            "user = admin`npassword = s3cr3t`nport = 8080" | Set-Content -LiteralPath $f -Encoding UTF8
            $out = Join-Path $work 'snap.json'
            $r = Invoke-Controller -ScriptPath $script:ps1 -Arguments @('collect','-Category','middleware','-OutputPath',$out) -Env @{ _OPS_MW_PROBE = $f }
            $r.ExitCode | Should -Be 0
            $p = (Get-Content -LiteralPath $out -Raw | ConvertFrom-Json).middleware._probe
            $p.masked      | Should -BeTrue
            $p.content     | Should -Match 'password\s*=\s*\*\*\*'
            $p.content     | Should -Match 'user = admin'
            $p.size_bytes  | Should -BeGreaterThan 0
            $p.sha256      | Should -Match '^[0-9a-f]{64}$'
            $p.readable    | Should -BeTrue
        } finally { Remove-TempPath $work }
    }
}
```

- [ ] **Step 2: 失敗を確認**（`Read-MwConf`/`Read-MwConfigFile` 未実装で probe が壊れる）

- [ ] **Step 3: PS 共通ヘルパを実装** — `Read-MwConf` stub を置換し、ヘルパ2つを追加

```powershell
function Read-MwConf {
    $conf = @{
        hana_sids = @(); hana_config_globs = @('/usr/sap/%SID%/SYS/global/hdb/custom/config/*.ini')
        sap_sids = @();  sap_profile_globs = @('/usr/sap/%SID%/SYS/profile/*')
        sqlserver_instances = @(); sqlserver_connect = 'auto'
        tomcat_bases = @(); tomcat_config_names = @('server.xml','web.xml','context.xml','catalina.properties','setenv.sh','setenv.bat')
        mask_patterns = @('password','passwd','pwd','secret','key','credential','token','connectionstring')
        max_file_kb = 256
    }
    $path = Join-Path $PSScriptRoot 'middleware.conf'
    if (-not (Test-Path -LiteralPath $path)) { return $conf }
    $section = ''
    foreach ($line in (Get-Content -LiteralPath $path -ErrorAction SilentlyContinue)) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        if ($t -match '^\[(.+)\]$') { $section = $Matches[1].Trim().ToLower(); continue }
        $kv = $t -split '=', 2
        if ($kv.Count -lt 2) { continue }
        $key = $kv[0].Trim().ToLower(); $val = $kv[1].Trim()
        $list = @($val -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        switch ("$section.$key") {
            'hana.sids'              { $conf.hana_sids = $list }
            'hana.config_globs'      { if ($list.Count) { $conf.hana_config_globs = $list } }
            'sap.sids'               { $conf.sap_sids = $list }
            'sap.profile_globs'      { if ($list.Count) { $conf.sap_profile_globs = $list } }
            'sqlserver.instances'    { $conf.sqlserver_instances = $list }
            'sqlserver.connect'      { if ($val) { $conf.sqlserver_connect = $val.ToLower() } }
            'tomcat.bases'           { $conf.tomcat_bases = $list }
            'tomcat.config_names'    { if ($list.Count) { $conf.tomcat_config_names = $list } }
            'masking.patterns'       { if ($list.Count) { $conf.mask_patterns = $list } }
            'limits.max_file_kb'     { $n = 0; if ([int]::TryParse($val, [ref]$n) -and $n -gt 0) { $conf.max_file_kb = $n } }
        }
    }
    return $conf
}

function Mask-MwSecrets {
    param([string]$Text, [string[]]$Patterns)
    if (-not $Text -or -not $Patterns -or $Patterns.Count -eq 0) { return @{ Text = "$Text"; Masked = $false } }
    $alt = ($Patterns | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $didMask = $false
    $lines = "$Text" -split "`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -imatch $alt) {
            # XML attribute form: key="value"
            $new = [regex]::Replace($line, '(?i)((?:' + $alt + ')[A-Za-z0-9_.-]*\s*=\s*")[^"]*(")', '${1}***${2}')
            # key = value / key: value form
            $new = [regex]::Replace($new, '(?i)^(\s*[A-Za-z0-9_.\-/]*(?:' + $alt + ')[A-Za-z0-9_.\-/]*\s*[:=]\s*)\S.*$', '${1}***')
            if ($new -ne $line) { $didMask = $true; $lines[$i] = $new }
        }
    }
    return @{ Text = ($lines -join "`n"); Masked = $didMask }
}

function Read-MwConfigFile {
    param([string]$Path, [string[]]$MaskPatterns, [int]$MaxFileKb)
    if (-not $MaxFileKb) { $MaxFileKb = 256 }
    $entry = @{ content = ''; masked = $false; size_bytes = 0; sha256 = ''; readable = $true; reason = '' }
    try {
        if (-not (Test-Path -LiteralPath $Path)) { $entry.readable = $false; $entry.reason = 'not_found'; return $entry }
        $fi = Get-Item -LiteralPath $Path -ErrorAction Stop
        $entry.size_bytes = [int]$fi.Length
        try { $entry.sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLower() } catch {}
        if ($fi.Length -gt ($MaxFileKb * 1024)) { $entry.reason = 'too_large'; return $entry }
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        $m = Mask-MwSecrets -Text $raw -Patterns $MaskPatterns
        $entry.content = $m.Text; $entry.masked = $m.Masked
    } catch {
        $entry.readable = $false; $entry.reason = 'permission_denied'; $entry.content = ''; $entry.sha256 = ''
    }
    return $entry
}
```

また `Get-MiddlewareInfo` 冒頭（`$conf = Read-MwConf` の直後）に Step1 注記の probe フックを追加する。

- [ ] **Step 4: sh 共通ヘルパを実装** — `_mw_load_conf` stub を置換し、`_mw_mask`/`_mw_read_file` を追加

```python
def _mw_load_conf():
    conf = {
        'hana_sids': [], 'hana_config_globs': ['/usr/sap/%SID%/SYS/global/hdb/custom/config/*.ini'],
        'sap_sids': [], 'sap_profile_globs': ['/usr/sap/%SID%/SYS/profile/*'],
        'sqlserver_instances': [], 'sqlserver_connect': 'auto',
        'tomcat_bases': [], 'tomcat_config_names': ['server.xml','web.xml','context.xml','catalina.properties','setenv.sh','setenv.bat'],
        'mask_patterns': ['password','passwd','pwd','secret','key','credential','token','connectionstring'],
        'max_file_kb': 256,
    }
    path = os.environ.get('_OPS_MW_CONF', '')
    if not path or not os.path.isfile(path):
        return conf
    section = ''
    listmap = {'hana.sids':'hana_sids','hana.config_globs':'hana_config_globs',
               'sap.sids':'sap_sids','sap.profile_globs':'sap_profile_globs',
               'sqlserver.instances':'sqlserver_instances','tomcat.bases':'tomcat_bases',
               'tomcat.config_names':'tomcat_config_names','masking.patterns':'mask_patterns'}
    try:
        for line in Path(path).read_text().splitlines():
            t = line.strip()
            if not t or t.startswith('#'): continue
            m = re.match(r'^\[(.+)\]$', t)
            if m: section = m.group(1).strip().lower(); continue
            if '=' not in t: continue
            k, v = t.split('=', 1); k = k.strip().lower(); v = v.strip()
            full = section + '.' + k
            vals = [x.strip() for x in v.split(',') if x.strip()]
            if full in listmap:
                if vals: conf[listmap[full]] = vals
            elif full == 'sqlserver.connect' and v:
                conf['sqlserver_connect'] = v.lower()
            elif full == 'limits.max_file_kb':
                try:
                    n = int(v)
                    if n > 0: conf['max_file_kb'] = n
                except Exception: pass
    except Exception: pass
    return conf

def _mw_mask(text, patterns):
    if not text or not patterns:
        return text, False
    alt = '|'.join(re.escape(p) for p in patterns)
    did = [False]
    attr_re = re.compile(r'(?i)((?:' + alt + r')[A-Za-z0-9_.\-]*\s*=\s*")[^"]*(")')
    kv_re   = re.compile(r'(?i)^(\s*[A-Za-z0-9_.\-/]*(?:' + alt + r')[A-Za-z0-9_.\-/]*\s*[:=]\s*)\S.*$')
    out = []
    for line in text.split('\n'):
        if re.search(r'(?i)' + alt, line):
            new = attr_re.sub(r'\1***\2', line)
            new = kv_re.sub(r'\1***', new)
            if new != line: did[0] = True
            out.append(new)
        else:
            out.append(line)
    return '\n'.join(out), did[0]

def _mw_read_file(path, patterns, max_kb):
    entry = {'content': '', 'masked': False, 'size_bytes': 0, 'sha256': '', 'readable': True, 'reason': ''}
    try:
        if not os.path.isfile(path):
            entry['readable'] = False; entry['reason'] = 'not_found'; return entry
        import hashlib
        raw = Path(path).read_bytes()
        entry['size_bytes'] = len(raw)
        entry['sha256'] = hashlib.sha256(raw).hexdigest()
        if len(raw) > max_kb * 1024:
            entry['reason'] = 'too_large'; return entry
        text = raw.decode('utf-8', errors='replace')
        masked, did = _mw_mask(text, patterns)
        entry['content'] = masked; entry['masked'] = did
    except PermissionError:
        entry['readable'] = False; entry['reason'] = 'permission_denied'; entry['sha256'] = ''
    except Exception:
        entry['readable'] = False; entry['reason'] = 'permission_denied'; entry['sha256'] = ''
    return entry
```

- [ ] **Step 5: bats テスト** — 追記（既存スキップガードに合わせる）

```bash
@test "server_snapshot: middleware file helper masks secrets" {
    cat > "$WORK/app.conf" <<'EOF'
user = admin
password = s3cr3t
port = 8080
EOF
    _OPS_MW_PROBE="$WORK/app.conf" run bash "$CTL" collect --category middleware --output "$WORK/snap.json"
    [ "$status" -eq 0 ]
    python3 -c "import json; p=json.load(open('$WORK/snap.json'))['middleware']['_probe']; assert p['masked'] is True; assert '***' in p['content']; assert 'user = admin' in p['content']; assert len(p['sha256'])==64"
}
```

> 注: probe フックは python 側 `collect_middleware` でも対応する。`collect_middleware` を下記に更新:
>
> ```python
> def collect_middleware():
>     conf = _mw_load_conf()
>     probe = os.environ.get('_OPS_MW_PROBE', '')
>     if probe:
>         return {'_probe': _mw_read_file(probe, conf['mask_patterns'], conf['max_file_kb'])}
>     return _mw_assemble(conf)
> ```
>
> PS 側 probe フックと対称になる。

- [ ] **Step 6: テスト + 構文確認 + コミット**

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester 'tests\pester\ServerSnapshot.Tests.ps1' -Output Detailed"
start=$(grep -n "python3 - << 'PYEOF'" tools/server-snapshot/server_snapshot.sh | head -1 | cut -d: -f1)
end=$(awk 'NR>'"$start"' && /^PYEOF$/{print NR; exit}' tools/server-snapshot/server_snapshot.sh)
sed -n "$((start+1)),$((end-1))p" tools/server-snapshot/server_snapshot.sh | python -c "import ast,sys; ast.parse(sys.stdin.read()); print('PY OK')"
git add tools/server-snapshot/ServerSnapshot.ps1 tools/server-snapshot/server_snapshot.sh tests/pester/ServerSnapshot.Tests.ps1 tests/bats/server_snapshot.bats
git commit -m "feat(server-snapshot): middleware conf parser + masked FileEntry helper"
```

---

## Task 3: Tomcat コレクタ（両 OS）

`Get-MwTomcat` / `_mw_tomcat` を実装。両 OS で動く最も検証しやすい製品。

**Files:**
- Modify: `tools/server-snapshot/ServerSnapshot.ps1`（`Get-MwTomcat` stub 置換）
- Modify: `tools/server-snapshot/server_snapshot.sh`（`_mw_tomcat` stub 置換）
- Test: `tests/pester/ServerSnapshot.Tests.ps1` / `tests/bats/server_snapshot.bats`

- [ ] **Step 1: Pester テスト（失敗）** — fixtures で擬似 CATALINA_BASE を作る

```powershell
Describe 'ServerSnapshot middleware tomcat' {
    It 'detects a tomcat base from conf and collects masked server.xml + ports' {
        $work = New-TempWorkdir
        try {
            $base = Join-Path $work 'tomcat9'
            New-Item -ItemType Directory -Path (Join-Path $base 'conf') -Force | Out-Null
            @'
<Server port="8005">
  <Service name="Catalina">
    <Connector port="8080" protocol="HTTP/1.1"/>
    <Connector port="8443" secret="topsecret"/>
  </Service>
</Server>
'@ | Set-Content -LiteralPath (Join-Path $base 'conf\server.xml') -Encoding UTF8
            # write a conf pointing tomcat.bases at our fixture
            $confPath = Join-Path $PSScriptRoot '..\..\tools\server-snapshot\middleware.conf'
            $out = Join-Path $work 'snap.json'
            $r = Invoke-Controller -ScriptPath $script:ps1 -Arguments @('collect','-Category','middleware','-OutputPath',$out) -Env @{ CATALINA_BASE = $base }
            $r.ExitCode | Should -Be 0
            $mw = (Get-Content -LiteralPath $out -Raw | ConvertFrom-Json).middleware
            $tom = @($mw.tomcat)
            ($tom | Where-Object { $_.catalina_base -eq $base }).Count | Should -BeGreaterThan 0
            $inst = $tom | Where-Object { $_.catalina_base -eq $base }
            @($inst.connector_ports) | Should -Contain 8080
            $sx = $inst.config_files.PSObject.Properties | Where-Object { $_.Name -like '*server.xml' }
            $sx.Value.content | Should -Match 'secret="\*\*\*"'
        } finally { Remove-TempPath $work }
    }
}
```

> 検出は環境変数 `CATALINA_BASE` でテストする（conf 上書きと別経路で確実）。`Get-MwTomcat` は `$env:CATALINA_BASE`/`$env:CATALINA_HOME` も検出元に含めること。

- [ ] **Step 2: 失敗を確認**

- [ ] **Step 3: `Get-MwTomcat` を実装**

```powershell
function Get-MwTomcat($conf) {
    $bases = New-Object System.Collections.Generic.List[string]
    foreach ($b in @($conf['tomcat_bases'])) { if ($b) { $bases.Add($b) } }
    foreach ($e in @($env:CATALINA_BASE, $env:CATALINA_HOME)) { if ($e) { $bases.Add($e) } }
    # running java processes with -Dcatalina.base
    Safe-Exec -Label 'mw.tomcat.proc' -Block {
        Get-CimInstance Win32_Process -Filter "Name='java.exe'" -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.CommandLine -and $_.CommandLine -match '-Dcatalina\.base=([^ "]+)') { $bases.Add($Matches[1]) }
        }
    } | Out-Null
    $seen = @{}; $result = @()
    foreach ($base in $bases) {
        $norm = $base.TrimEnd('\','/')
        if (-not $norm -or $seen[$norm.ToLower()]) { continue }
        $serverXml = Join-Path $norm 'conf\server.xml'
        if (-not (Test-Path -LiteralPath $serverXml)) { continue }
        $seen[$norm.ToLower()] = $true
        $inst = @{
            name = (Split-Path $norm -Leaf); catalina_base = $norm
            version = ''; java_version = ''; jvm_opts = ''; state = ''; pid = 0; connector_ports = @()
            config_files = @{}
        }
        # version
        $inst.version = Safe-Exec -Label 'mw.tomcat.ver' -Block {
            $bat = Join-Path $norm 'bin\version.bat'
            if (Test-Path -LiteralPath $bat) {
                $o = (& cmd /c "`"$bat`"" 2>$null) -join "`n"
                if ($o -match 'Server version:\s*(.+)') { return $Matches[1].Trim() }
            }
            $rel = Join-Path $norm 'RELEASE-NOTES'
            if (Test-Path -LiteralPath $rel) {
                $line = (Get-Content -LiteralPath $rel | Where-Object { $_ -match 'Apache Tomcat Version' } | Select-Object -First 1)
                if ($line) { return $line.Trim() }
            }
            ''
        }
        # ports from server.xml
        $inst.connector_ports = @(Safe-Exec -Label 'mw.tomcat.ports' -Block {
            $ports = @()
            [regex]::Matches((Get-Content -LiteralPath $serverXml -Raw), '<Connector[^>]*\bport="(\d+)"') | ForEach-Object { $ports += [int]$_.Groups[1].Value }
            $ports
        })
        # config files
        foreach ($name in @($conf['tomcat_config_names'])) {
            $p = Join-Path (Join-Path $norm 'conf') $name
            if ($name -like 'setenv*') { $p = Join-Path (Join-Path $norm 'bin') $name }
            if (Test-Path -LiteralPath $p) {
                $inst.config_files["$p"] = Read-MwConfigFile -Path $p -MaskPatterns $conf['mask_patterns'] -MaxFileKb $conf['max_file_kb']
            }
        }
        $result += $inst
    }
    return $result
}
```

- [ ] **Step 4: `_mw_tomcat` を実装（python3）**

```python
def _mw_tomcat(conf):
    import glob as _glob
    bases = []
    for b in conf.get('tomcat_bases', []):
        if b: bases.append(b)
    for e in (os.environ.get('CATALINA_BASE',''), os.environ.get('CATALINA_HOME','')):
        if e: bases.append(e)
    for g in ('/opt/tomcat*', '/usr/share/tomcat*', '/opt/apache-tomcat*'):
        bases.extend(_glob.glob(g))
    # running procs with -Dcatalina.base
    try:
        ps = subprocess.run(['ps','-eo','args'], capture_output=True, text=True, timeout=10)
        for line in ps.stdout.splitlines():
            m = re.search(r'-Dcatalina\.base=(\S+)', line)
            if m: bases.append(m.group(1))
    except Exception: pass
    seen = set(); result = []
    for base in bases:
        norm = base.rstrip('/')
        if not norm or norm.lower() in seen: continue
        server_xml = os.path.join(norm, 'conf', 'server.xml')
        if not os.path.isfile(server_xml): continue
        seen.add(norm.lower())
        inst = {'name': os.path.basename(norm), 'catalina_base': norm, 'version': '',
                'java_version': '', 'jvm_opts': '', 'state': '', 'pid': 0,
                'connector_ports': [], 'config_files': {}}
        # version
        try:
            sh = os.path.join(norm, 'bin', 'catalina.sh')
            if os.path.isfile(sh):
                r = subprocess.run([sh, 'version'], capture_output=True, text=True, timeout=15,
                                   env=dict(os.environ, CATALINA_HOME=norm))
                m = re.search(r'Server version:\s*(.+)', r.stdout)
                if m: inst['version'] = m.group(1).strip()
            if not inst['version']:
                rel = os.path.join(norm, 'RELEASE-NOTES')
                if os.path.isfile(rel):
                    for line in Path(rel).read_text(errors='replace').splitlines():
                        if 'Apache Tomcat Version' in line: inst['version'] = line.strip(); break
        except Exception: pass
        # java version
        try:
            r = subprocess.run(['java','-version'], capture_output=True, text=True, timeout=10)
            m = re.search(r'version "([^"]+)"', (r.stderr or '') + (r.stdout or ''))
            if m: inst['java_version'] = m.group(1)
        except Exception: pass
        # ports
        try:
            xml = Path(server_xml).read_text(errors='replace')
            inst['connector_ports'] = [int(x) for x in re.findall(r'<Connector[^>]*\bport="(\d+)"', xml)]
        except Exception: pass
        # config files
        for name in conf.get('tomcat_config_names', []):
            sub = 'bin' if name.startswith('setenv') else 'conf'
            p = os.path.join(norm, sub, name)
            if os.path.isfile(p):
                inst['config_files'][p] = _mw_read_file(p, conf['mask_patterns'], conf['max_file_kb'])
        result.append(inst)
    return result
```

- [ ] **Step 5: bats テスト**

```bash
@test "server_snapshot: middleware detects tomcat base and masks server.xml" {
    base="$WORK/tomcat9"; mkdir -p "$base/conf"
    cat > "$base/conf/server.xml" <<'EOF'
<Server port="8005"><Service name="Catalina">
<Connector port="8080" protocol="HTTP/1.1"/>
<Connector port="8443" secret="topsecret"/>
</Service></Server>
EOF
    CATALINA_BASE="$base" run bash "$CTL" collect --category middleware --output "$WORK/snap.json"
    [ "$status" -eq 0 ]
    python3 -c "
import json
mw=json.load(open('$WORK/snap.json'))['middleware']
t=[x for x in mw.get('tomcat',[]) if x['catalina_base']=='$base']
assert t, 'tomcat not detected'
assert 8080 in t[0]['connector_ports']
sx=[v for k,v in t[0]['config_files'].items() if k.endswith('server.xml')][0]
assert 'secret=\"***\"' in sx['content']
"
}
```

- [ ] **Step 6: テスト + 構文確認 + コミット**

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester 'tests\pester\ServerSnapshot.Tests.ps1' -Output Detailed"
start=$(grep -n "python3 - << 'PYEOF'" tools/server-snapshot/server_snapshot.sh | head -1 | cut -d: -f1); end=$(awk 'NR>'"$start"' && /^PYEOF$/{print NR; exit}' tools/server-snapshot/server_snapshot.sh); sed -n "$((start+1)),$((end-1))p" tools/server-snapshot/server_snapshot.sh | python -c "import ast,sys; ast.parse(sys.stdin.read()); print('PY OK')"
git add tools/server-snapshot/ServerSnapshot.ps1 tools/server-snapshot/server_snapshot.sh tests/pester/ServerSnapshot.Tests.ps1 tests/bats/server_snapshot.bats
git commit -m "feat(server-snapshot): collect tomcat middleware (version/ports/config)"
```

---

## Task 4: HANA コレクタ（Linux 主体）

`_mw_hana`（python3）を実装。Windows 側 `Get-MwHana` は HANA 非対応のため空配列のままとする（OS 1:1 は「検出ゼロ→省略」で成立）。

**Files:**
- Modify: `tools/server-snapshot/server_snapshot.sh`（`_mw_hana` stub 置換）
- Modify: `tools/server-snapshot/ServerSnapshot.ps1`（`Get-MwHana` にコメントのみ。空配列維持）
- Test: `tests/bats/server_snapshot.bats`

- [ ] **Step 1: bats テスト（失敗）** — 擬似 SID ツリーを作り conf で指定

```bash
@test "server_snapshot: middleware collects hana ini from config_globs" {
    root="$WORK/usr_sap/PRD/SYS/global/hdb/custom/config"; mkdir -p "$root"
    cat > "$root/global.ini" <<'EOF'
[communication]
listeninterface = .global
[authentication]
password = supersecret
EOF
    conf="$WORK/mw.conf"
    cat > "$conf" <<EOF
[hana]
sids = PRD
config_globs = $WORK/usr_sap/%SID%/SYS/global/hdb/custom/config/*.ini
[masking]
patterns = password,secret,key
[limits]
max_file_kb = 256
EOF
    _OPS_MW_CONF="$conf" run bash "$CTL" collect --category middleware --output "$WORK/snap.json"
    [ "$status" -eq 0 ]
    python3 -c "
import json
mw=json.load(open('$WORK/snap.json'))['middleware']
h=[x for x in mw.get('hana',[]) if x['sid']=='PRD']
assert h, 'hana PRD not found'
gi=[v for k,v in h[0]['config_files'].items() if k.endswith('global.ini')][0]
assert 'password = ***' in gi['content']
assert 'listeninterface = .global' in gi['content']
"
}
```

- [ ] **Step 2: 失敗を確認**

- [ ] **Step 3: `_mw_hana` を実装（python3）**

```python
def _mw_hana(conf):
    import glob as _glob
    sids = list(conf.get('hana_sids', []))
    if not sids:
        # auto-detect: /usr/sap/<SID>/HDB<nr>
        for d in _glob.glob('/usr/sap/*/HDB[0-9][0-9]'):
            sid = d.split('/usr/sap/')[1].split('/')[0]
            if sid and sid not in sids: sids.append(sid)
    result = []
    for sid in sids:
        inst = {'sid': sid, 'instance_no': '', 'version': '', 'edition': '',
                'state': '', 'ports': [], 'config_files': {}}
        # instance number from HDB<nr>
        for d in _glob.glob('/usr/sap/%s/HDB[0-9][0-9]' % sid):
            inst['instance_no'] = d[-2:]; break
        # version: HDB version (best-effort, sidadm env normally required)
        try:
            r = subprocess.run(['su','-','%sadm' % sid.lower(), '-c', 'HDB version'],
                               capture_output=True, text=True, timeout=15)
            m = re.search(r'version:\s*([0-9.]+)', r.stdout)
            if m: inst['version'] = m.group(1)
        except Exception: pass
        # state via sapcontrol (best-effort)
        if inst['instance_no']:
            try:
                r = subprocess.run(['sapcontrol','-nr',inst['instance_no'],'-function','GetProcessList'],
                                   capture_output=True, text=True, timeout=15)
                if 'GREEN' in r.stdout: inst['state'] = 'GREEN'
                elif 'YELLOW' in r.stdout: inst['state'] = 'YELLOW'
                elif 'GRAY' in r.stdout: inst['state'] = 'GRAY'
            except Exception: pass
        # config files via globs (%SID% expansion)
        for g in conf.get('hana_config_globs', []):
            for p in _glob.glob(g.replace('%SID%', sid)):
                if os.path.isfile(p):
                    inst['config_files'][p] = _mw_read_file(p, conf['mask_patterns'], conf['max_file_kb'])
        result.append(inst)
    return result
```

- [ ] **Step 4: PS 側はコメントのみ**

`Get-MwHana` を次に置換（Windows では HANA 非対応である旨を明示）:

```powershell
function Get-MwHana($conf) {
    # SAP HANA is Linux-only; on Windows nothing is detected (key omitted by Get-MiddlewareInfo).
    @()
}
```

- [ ] **Step 5: テスト + 構文確認 + コミット**

```bash
start=$(grep -n "python3 - << 'PYEOF'" tools/server-snapshot/server_snapshot.sh | head -1 | cut -d: -f1); end=$(awk 'NR>'"$start"' && /^PYEOF$/{print NR; exit}' tools/server-snapshot/server_snapshot.sh); sed -n "$((start+1)),$((end-1))p" tools/server-snapshot/server_snapshot.sh | python -c "import ast,sys; ast.parse(sys.stdin.read()); print('PY OK')"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester 'tests\pester\ServerSnapshot.Tests.ps1' -Output Detailed"
git add tools/server-snapshot/ServerSnapshot.ps1 tools/server-snapshot/server_snapshot.sh tests/bats/server_snapshot.bats
git commit -m "feat(server-snapshot): collect SAP HANA middleware (ini/version/state)"
```

---

## Task 5: SAP NW/S4 コレクタ（Linux 主体）

`_mw_sap`（python3）を実装。`Get-MwSap` は空配列維持。

**Files:**
- Modify: `tools/server-snapshot/server_snapshot.sh`（`_mw_sap` stub 置換）
- Modify: `tools/server-snapshot/ServerSnapshot.ps1`（`Get-MwSap` コメントのみ）
- Test: `tests/bats/server_snapshot.bats`

- [ ] **Step 1: bats テスト（失敗）** — 擬似プロファイルツリー

```bash
@test "server_snapshot: middleware collects sap profiles from profile_globs" {
    prof="$WORK/usr_sap/PRD/SYS/profile"; mkdir -p "$prof"
    cat > "$prof/DEFAULT.PFL" <<'EOF'
SAPSYSTEMNAME = PRD
rdisp/wp_no_dia = 10
login/password_downwards_compatibility = 0
EOF
    cat > "$prof/PRD_D00_host" <<'EOF'
INSTANCE_NAME = D00
EOF
    conf="$WORK/mw.conf"
    cat > "$conf" <<EOF
[sap]
sids = PRD
profile_globs = $WORK/usr_sap/%SID%/SYS/profile/*
[limits]
max_file_kb = 256
EOF
    _OPS_MW_CONF="$conf" run bash "$CTL" collect --category middleware --output "$WORK/snap.json"
    [ "$status" -eq 0 ]
    python3 -c "
import json
mw=json.load(open('$WORK/snap.json'))['middleware']
s=[x for x in mw.get('sap',[]) if x['sid']=='PRD']
assert s, 'sap PRD not found'
names=[k.split('/')[-1] for k in s[0]['profiles'].keys()]
assert 'DEFAULT.PFL' in names and 'PRD_D00_host' in names
"
}
```

- [ ] **Step 2: 失敗を確認**

- [ ] **Step 3: `_mw_sap` を実装（python3）**

```python
def _mw_sap(conf):
    import glob as _glob
    sids = list(conf.get('sap_sids', []))
    if not sids:
        for d in _glob.glob('/usr/sap/*/SYS/profile'):
            sid = d.split('/usr/sap/')[1].split('/')[0]
            if sid and sid != 'trans' and sid not in sids: sids.append(sid)
    result = []
    for sid in sids:
        inst = {'sid': sid, 'instance': '', 'instance_no': '', 'type': '',
                'kernel_version': '', 'state': '', 'ports': [], 'profiles': {}}
        # instance dir like /usr/sap/<SID>/<TYPE><NR>
        for d in _glob.glob('/usr/sap/%s/[A-Z]*[0-9][0-9]' % sid):
            base = os.path.basename(d)
            inst['instance'] = base
            inst['instance_no'] = base[-2:]
            m = re.match(r'^([A-Z]+)\d\d$', base)
            if m: inst['type'] = m.group(1)
            break
        # kernel version (best-effort)
        try:
            r = subprocess.run(['disp+work','-v'], capture_output=True, text=True, timeout=15)
            m = re.search(r'kernel release\s+(\S+)', r.stdout)
            if m: inst['kernel_version'] = m.group(1)
        except Exception: pass
        # state via sapcontrol
        if inst['instance_no']:
            try:
                r = subprocess.run(['sapcontrol','-nr',inst['instance_no'],'-function','GetProcessList'],
                                   capture_output=True, text=True, timeout=15)
                if 'GREEN' in r.stdout: inst['state'] = 'GREEN'
                elif 'YELLOW' in r.stdout: inst['state'] = 'YELLOW'
                elif 'GRAY' in r.stdout: inst['state'] = 'GRAY'
            except Exception: pass
        # profiles
        for g in conf.get('sap_profile_globs', []):
            for p in _glob.glob(g.replace('%SID%', sid)):
                if os.path.isfile(p):
                    inst['profiles'][p] = _mw_read_file(p, conf['mask_patterns'], conf['max_file_kb'])
        result.append(inst)
    return result
```

- [ ] **Step 4: PS 側はコメントのみ**

```powershell
function Get-MwSap($conf) {
    # SAP NW/S4 application server is Linux-only here; nothing detected on Windows.
    @()
}
```

- [ ] **Step 5: テスト + 構文確認 + コミット**

```bash
start=$(grep -n "python3 - << 'PYEOF'" tools/server-snapshot/server_snapshot.sh | head -1 | cut -d: -f1); end=$(awk 'NR>'"$start"' && /^PYEOF$/{print NR; exit}' tools/server-snapshot/server_snapshot.sh); sed -n "$((start+1)),$((end-1))p" tools/server-snapshot/server_snapshot.sh | python -c "import ast,sys; ast.parse(sys.stdin.read()); print('PY OK')"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester 'tests\pester\ServerSnapshot.Tests.ps1' -Output Detailed"
git add tools/server-snapshot/ServerSnapshot.ps1 tools/server-snapshot/server_snapshot.sh tests/bats/server_snapshot.bats
git commit -m "feat(server-snapshot): collect SAP NW/S4 middleware (profiles/kernel/state)"
```

---

## Task 6: SQL Server コレクタ（両 OS, sp_configure best-effort）

`Get-MwSqlServer`（Windows: レジストリ + サービス + sqlcmd -E）/ `_mw_sqlserver`（Linux: mssql.conf + systemctl + sqlcmd）を実装。

**Files:**
- Modify: `tools/server-snapshot/ServerSnapshot.ps1`（`Get-MwSqlServer` stub 置換）
- Modify: `tools/server-snapshot/server_snapshot.sh`（`_mw_sqlserver` stub 置換）
- Test: `tests/pester/ServerSnapshot.Tests.ps1`

- [ ] **Step 1: Pester テスト（失敗）** — SQL Server 不在環境でも壊れないこと（退化）を検証

```powershell
Describe 'ServerSnapshot middleware sqlserver' {
    It 'sqlserver collection never throws; entries (if any) carry sp_configure_available' {
        $work = New-TempWorkdir
        try {
            $out = Join-Path $work 'snap.json'
            $r = Invoke-Controller -ScriptPath $script:ps1 -Arguments @('collect','-Category','middleware','-OutputPath',$out)
            $r.ExitCode | Should -Be 0
            $mw = (Get-Content -LiteralPath $out -Raw | ConvertFrom-Json).middleware
            # If SQL Server isn't installed, key is omitted -> that's fine. If present, must have the flag.
            if ($mw.PSObject.Properties.Name -contains 'sqlserver') {
                @($mw.sqlserver)[0].PSObject.Properties.Name | Should -Contain 'sp_configure_available'
            }
        } finally { Remove-TempPath $work }
    }
}
```

- [ ] **Step 2: 失敗を確認**（`Get-MwSqlServer` stub は空配列なので exit 0 だが、実装後も「壊れない」ことを担保。実装前にこの It を足すと PASS してしまう場合は、実装で `sp_configure_available` が必ず付くことを担保する目的のテストとして残す）

- [ ] **Step 3: `Get-MwSqlServer` を実装（Windows）**

```powershell
function Get-MwSqlServer($conf) {
    $result = @()
    $instances = @($conf['sqlserver_instances'])
    if (-not $instances.Count) {
        Safe-Exec -Label 'mw.sql.instances' -Block {
            $p = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
            $item = Get-ItemProperty -Path $p -ErrorAction SilentlyContinue
            if ($item) {
                $item.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object { $instances += $_.Name }
            }
        } | Out-Null
    }
    foreach ($name in $instances) {
        if (-not $name) { continue }
        $inst = @{
            instance_name = "$name"; version = ''; edition = ''; state = ''; port = 0
            config_files = @{}; sp_configure = $null; sp_configure_available = $false
        }
        # service state
        $svcName = if ($name -eq 'MSSQLSERVER') { 'MSSQLSERVER' } else { "MSSQL`$$name" }
        $inst.state = Safe-Exec -Label 'mw.sql.svc' -Block {
            $s = Get-Service -Name $svcName -ErrorAction SilentlyContinue
            if ($s) { $s.Status.ToString().ToLower() } else { '' }
        }
        # sp_configure + version via sqlcmd -E (integrated auth, best-effort)
        if ($conf['sqlserver_connect'] -ne 'off') {
            $sqlcmd = Get-Command sqlcmd -ErrorAction SilentlyContinue
            if ($sqlcmd) {
                $target = if ($name -eq 'MSSQLSERVER') { '.' } else { ".\$name" }
                $cfg = Safe-Exec -Label 'mw.sql.spcfg' -Block {
                    $q = "SET NOCOUNT ON; EXEC sp_configure;"
                    $o = & sqlcmd -S $target -E -h -1 -W -s "|" -Q $q 2>$null
                    $o
                }
                if ($cfg) {
                    $h = @{}
                    foreach ($row in $cfg) {
                        $cols = "$row" -split '\|'
                        if ($cols.Count -ge 2 -and $cols[0].Trim()) { $h[$cols[0].Trim()] = $cols[1].Trim() }
                    }
                    if ($h.Count) { $inst.sp_configure = $h; $inst.sp_configure_available = $true }
                }
                $ver = Safe-Exec -Label 'mw.sql.ver' -Block {
                    $o = & sqlcmd -S $target -E -h -1 -W -Q "SET NOCOUNT ON; SELECT CONVERT(varchar,SERVERPROPERTY('ProductVersion'));" 2>$null
                    ($o | Where-Object { $_ -match '^\d+\.' } | Select-Object -First 1)
                }
                if ($ver) { $inst.version = "$ver".Trim() }
            }
        }
        # port from registry (best-effort)
        $inst.port = Safe-Exec -Label 'mw.sql.port' -Block {
            $instId = Safe-Exec -Label 'mw.sql.instid' -Block {
                (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction SilentlyContinue).$name
            }
            if ($instId) {
                $tp = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instId\MSSQLServer\SuperSocketNetLib\Tcp\IPAll"
                $v = (Get-ItemProperty -Path $tp -ErrorAction SilentlyContinue).TcpPort
                if ($v) { [int]$v } else { 0 }
            } else { 0 }
        }
        $result += $inst
    }
    return $result
}
```

- [ ] **Step 4: `_mw_sqlserver` を実装（Linux, python3）**

```python
def _mw_sqlserver(conf):
    result = []
    has_conf = os.path.isfile('/var/opt/mssql/mssql.conf')
    # detect presence: mssql.conf or systemd unit
    present = has_conf
    try:
        r = subprocess.run(['systemctl','is-enabled','mssql-server'], capture_output=True, text=True, timeout=5)
        if r.returncode == 0 or 'enabled' in r.stdout or 'disabled' in r.stdout: present = True
    except Exception: pass
    if not present:
        return result
    inst = {'instance_name': 'MSSQLSERVER', 'version': '', 'edition': '', 'state': '',
            'port': 1433, 'config_files': {}, 'sp_configure': None, 'sp_configure_available': False}
    # service state
    try:
        r = subprocess.run(['systemctl','is-active','mssql-server'], capture_output=True, text=True, timeout=5)
        inst['state'] = r.stdout.strip()
    except Exception: pass
    # mssql.conf
    if has_conf:
        p = '/var/opt/mssql/mssql.conf'
        inst['config_files'][p] = _mw_read_file(p, conf['mask_patterns'], conf['max_file_kb'])
    # sp_configure + version via sqlcmd (best-effort, integrated/current creds)
    if conf.get('sqlserver_connect') != 'off':
        sqlcmd = None
        for cand in ('/opt/mssql-tools/bin/sqlcmd','/opt/mssql-tools18/bin/sqlcmd','sqlcmd'):
            if cand == 'sqlcmd':
                from shutil import which
                if which('sqlcmd'): sqlcmd = 'sqlcmd'
            elif os.path.isfile(cand):
                sqlcmd = cand
            if sqlcmd: break
        if sqlcmd:
            try:
                r = subprocess.run([sqlcmd,'-S','localhost','-E','-h','-1','-W','-s','|','-Q','SET NOCOUNT ON; EXEC sp_configure;'],
                                   capture_output=True, text=True, timeout=20)
                h = {}
                for row in r.stdout.splitlines():
                    cols = row.split('|')
                    if len(cols) >= 2 and cols[0].strip():
                        h[cols[0].strip()] = cols[1].strip()
                if h: inst['sp_configure'] = h; inst['sp_configure_available'] = True
            except Exception: pass
            try:
                r = subprocess.run([sqlcmd,'-S','localhost','-E','-h','-1','-W','-Q',"SET NOCOUNT ON; SELECT CONVERT(varchar,SERVERPROPERTY('ProductVersion'));"],
                                   capture_output=True, text=True, timeout=15)
                for line in r.stdout.splitlines():
                    if re.match(r'^\d+\.', line.strip()): inst['version'] = line.strip(); break
            except Exception: pass
    result.append(inst)
    return result
```

- [ ] **Step 5: テスト + 構文確認 + コミット**

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester 'tests\pester\ServerSnapshot.Tests.ps1' -Output Detailed"
start=$(grep -n "python3 - << 'PYEOF'" tools/server-snapshot/server_snapshot.sh | head -1 | cut -d: -f1); end=$(awk 'NR>'"$start"' && /^PYEOF$/{print NR; exit}' tools/server-snapshot/server_snapshot.sh); sed -n "$((start+1)),$((end-1))p" tools/server-snapshot/server_snapshot.sh | python -c "import ast,sys; ast.parse(sys.stdin.read()); print('PY OK')"
git add tools/server-snapshot/ServerSnapshot.ps1 tools/server-snapshot/server_snapshot.sh tests/pester/ServerSnapshot.Tests.ps1
git commit -m "feat(server-snapshot): collect SQL Server middleware (registry/service/sp_configure best-effort)"
```

---

## Task 7: compare 比較器 `Compare-Middleware`

製品ごとにインスタンスをキー突合し、config_files/profiles は sha256 で差分判定。compare dispatch に登録。

**Files:**
- Modify: `tools/server-snapshot/ServerSnapshot.ps1`（`Compare-Scheduled`:667 の後に `Compare-Middleware` 追加 / dispatch switch:882 に登録）
- Test: `tests/pester/ServerSnapshot.Tests.ps1`

- [ ] **Step 1: Pester テスト（失敗）** — 2 スナップショットで config の sha256 変化を検出

```powershell
Describe 'ServerSnapshot compare middleware' {
    It 'detects tomcat version change and config sha256 change' {
        $work = New-TempWorkdir
        try {
            $before = Join-Path $work 'b.json'; $after = Join-Path $work 'a.json'
            $mk = {
                param($ver,$sha)
                @{ meta=@{hostname='h';os_type='windows';collected_at='t';categories=@('middleware')}
                   middleware=@{ tomcat=@(@{
                       name='t9'; catalina_base='/opt/t9'; version=$ver; java_version='17'; jvm_opts='';
                       state='running'; pid=1; connector_ports=@(8080)
                       config_files=@{ '/opt/t9/conf/server.xml' = @{ content='x'; masked=$false; size_bytes=10; sha256=$sha; readable=$true; reason='' } }
                   }) } }
            }
            (& $mk 'Tomcat/9.0.1' 'aaa') | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $before -Encoding UTF8
            (& $mk 'Tomcat/9.0.2' 'bbb') | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $after  -Encoding UTF8
            $r = Invoke-Controller -ScriptPath $script:ps1 -Arguments @('compare',$before,$after)
            $r.ExitCode | Should -Be 0
            $r.Combined | Should -Match 'middleware'
            $r.Combined | Should -Match '9\.0\.2'           # version change shown
            $r.Combined | Should -Match 'CHANGED'           # sha256 change detected
        } finally { Remove-TempPath $work }
    }
}
```

- [ ] **Step 2: 失敗を確認**（比較器未登録で middleware が比較されない）

- [ ] **Step 3: `Compare-Middleware` を実装** — `Compare-Scheduled`（667行）の後に追加

```powershell
function Compare-Middleware($b, $a) {
    $results = [System.Collections.Generic.List[CategoryResult]]::new()
    $bd = Obj-To-Dict $b; $ad = Obj-To-Dict $a
    # product -> (key fields, scalar value fields, config field name)
    $specs = @(
        @{ prod='hana';      key={ param($x) "$($x['sid'])" };                          vals=@('version','instance_no','state'); cfg='config_files' },
        @{ prod='sap';       key={ param($x) "$($x['sid'])/$($x['instance'])" };        vals=@('kernel_version','type','state'); cfg='profiles' },
        @{ prod='sqlserver'; key={ param($x) "$($x['instance_name'])" };                vals=@('version','edition','state','port','sp_configure_available'); cfg='config_files' },
        @{ prod='tomcat';    key={ param($x) "$($x['name'])@$($x['catalina_base'])" };  vals=@('version','java_version','state'); cfg='config_files' }
    )
    foreach ($s in $specs) {
        $bl = @(As-Array $bd[$s.prod] | ForEach-Object { Obj-To-Dict $_ })
        $al = @(As-Array $ad[$s.prod] | ForEach-Object { Obj-To-Dict $_ })
        if (-not $bl.Count -and -not $al.Count) { continue }
        # scalar fields comparison (build keyed dicts with a 'name' field for Compare-List)
        $bScalar = @($bl | ForEach-Object { $h = @{ name = (& $s.key $_) }; foreach ($v in $s.vals) { $h[$v] = $_[$v] }; $h })
        $aScalar = @($al | ForEach-Object { $h = @{ name = (& $s.key $_) }; foreach ($v in $s.vals) { $h[$v] = $_[$v] }; $h })
        $results.Add((Compare-List $bScalar $aScalar 'name' $s.vals "middleware/$($s.prod)"))
        # config files compared by sha256 (key = instanceKey::path, value = sha256)
        $bCfg = @(); $aCfg = @()
        foreach ($inst in $bl) { $files = Obj-To-Dict $inst[$s.cfg]; foreach ($p in $files.Keys) { $bCfg += @{ name = "$(& $s.key $inst)::$p"; sha256 = (Obj-To-Dict $files[$p])['sha256'] } } }
        foreach ($inst in $al) { $files = Obj-To-Dict $inst[$s.cfg]; foreach ($p in $files.Keys) { $aCfg += @{ name = "$(& $s.key $inst)::$p"; sha256 = (Obj-To-Dict $files[$p])['sha256'] } } }
        if ($bCfg.Count -or $aCfg.Count) {
            $results.Add((Compare-List $bCfg $aCfg 'name' @('sha256') "middleware/$($s.prod)/files"))
        }
    }
    return $results
}
```

- [ ] **Step 4: compare dispatch に登録** — 882行付近の switch に追加

```powershell
            'middleware'  { @(Compare-Middleware $bCat $aCat) }
```

> 注: `Compare-Middleware` は複数 `CategoryResult` を返す。`Compare-Network`/`Compare-Users` 等と同じく switch アームで `@(...)` 展開され `$allResults.AddRange` 相当で集約される実装になっているか確認（882行直後の集約ロジックに合わせる）。

- [ ] **Step 5: テストが通ることを確認**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester 'tests\pester\ServerSnapshot.Tests.ps1' -Output Detailed"`
Expected: PASS

- [ ] **Step 6: 回帰 + コミット**

```bash
git add tools/server-snapshot/ServerSnapshot.ps1 tests/pester/ServerSnapshot.Tests.ps1
git commit -m "feat(server-snapshot): add Compare-Middleware (scalar + config sha256 diff)"
```

---

## Task 8: ドキュメント更新 + 全体回帰

**Files:**
- Modify: `tools/server-snapshot/README.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: README に追記**

`tools/server-snapshot/README.md` の収集カテゴリ説明に `middleware` を追加。製品別の収集内容（hana/sap/sqlserver/tomcat）と収集元、`middleware.conf` の各セクション（hana/sap/sqlserver/tomcat/masking/limits）、機密マスク・権限不能（`reason`）・サイズ上限の挙動、SQL Server は統合認証 best-effort で資格情報非保存である点を表で記載。実行例を追加:

```
.\server_snapshot.bat collect -Category middleware
bash server_snapshot.sh collect --category middleware
```

- [ ] **Step 2: CHANGELOG に追記**

`CHANGELOG.md` の `[Unreleased]` `### Added` に:

```markdown
- `server-snapshot` に `middleware` カテゴリを追加。SAP HANA / SAP NW・S4 / SQL Server / Tomcat のバージョン・状態・Listen ポート・設定ファイル全文（機密キーは自動マスク）を収集し、`middleware.conf` で検出パス/マスクパターン/サイズ上限を上書き可能。compare は製品インスタンス単位のスカラ差分＋設定ファイルの sha256 差分を検出。SQL Server の sp_configure は統合認証で best-effort 取得（資格情報は保存しない）
```

- [ ] **Step 3: 全テスト + テンプレチェック**

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester 'tests\pester\ServerSnapshot.Tests.ps1' -Output Detailed"
bats tests/bats/server_snapshot.bats   # bats があれば
bash ci/template-check/check_template.sh
```
Expected: 全 pass、新規 violation なし。

- [ ] **Step 4: コミット**

```bash
git add tools/server-snapshot/README.md CHANGELOG.md
git commit -m "docs(server-snapshot): document middleware category and middleware.conf"
```

---

## 自己レビューチェックリスト（仕様 → タスク対応）

| 仕様項目 | 対応タスク |
|---|---|
| middleware カテゴリ枠 + conf | Task 1 |
| conf パーサ + FileEntry/マスク（単一実装点） | Task 2 |
| Tomcat 収集（両OS, version/ports/config） | Task 3 |
| HANA 収集（ini/version/state, Linux） | Task 4 |
| SAP NW/S4 収集（profile/kernel/state, Linux） | Task 5 |
| SQL Server 収集（registry/service/port/sp_configure best-effort, 両OS） | Task 6 |
| compare（スカラ + config sha256） | Task 7 |
| 機密マスク・権限・サイズ（reason） | Task 2（各コレクタが共通ヘルパ経由） |
| 両OS 1:1（検出ゼロで省略） | Task 1 の集約ロジック |
| 自己完結（conf 同梱、lib 非依存） | Task 1/2 |
| ドキュメント（README/CHANGELOG） | Task 8 |

**実装順序の注意:** Task 1（枠）→ 2（共通ヘルパ）→ 3-6（各製品）→ 7（compare）→ 8（docs）。Task 3-6 は Task 2 の `Read-MwConfigFile`/`_mw_read_file` に依存するため、必ず Task 2 の後に実施する。Task 7 は全製品のデータ構造（key フィールド・config_files/profiles）に依存するため最後。

**行番号は目安:** 各タスクの行番号は執筆時点（HEAD: middleware 着手前）の参照値。実装者は Grep で関数名/`validCategories`/`CAT_MAP`/dispatch switch を検索して実際の挿入位置を特定すること。

**probe フックについて:** Task 2 で導入する `_OPS_MW_PROBE` フック（PS/python 両方）は共通ヘルパの単体検証用。本番の collect 動作には影響しない（環境変数未設定時は通常経路）。実装後も残置してよい（テストが依存するため削除しないこと）。
