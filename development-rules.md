# スクリプト開発ルール

このリポジトリでスクリプトを開発・修正する際の規則と注意点をまとめたものです。  
実際の開発で発生したバグや問題から得た知見を反映しています。

---

## 目次

1. [ファイルエンコーディングと改行コード](#1-ファイルエンコーディングと改行コード)
2. [Shift-JIS LF-eating バグ](#2-shift-jis-lf-eating-バグ)
3. [bash スクリプトの作法](#3-bash-スクリプトの作法)
4. [PowerShell スクリプトの作法](#4-powershell-スクリプトの作法)
5. [バッチファイル (.bat) の作法](#5-バッチファイル-bat-の作法)
6. [Python スクリプトの作法](#6-python-スクリプトの作法)
7. [スクリプト構造の統一パターン](#7-スクリプト構造の統一パターン)
8. [比較・差分検出ツールの注意点](#8-比較差分検出ツールの注意点)
9. [Docker テスト環境](#9-docker-テスト環境)
10. [ディレクトリ構造とファイル配置](#10-ディレクトリ構造とファイル配置)
11. [コミット規約](#11-コミット規約)

---

## 1. ファイルエンコーディングと改行コード

`.gitattributes` で種別ごとに改行コードを固定している。

| ファイル種別 | エンコーディング | 改行 | BOM | 備考 |
|---|---|---|---|---|
| `.sh` / `.bash` / `.bats` | UTF-8 | LF | なし | BOM があるとシェバン行が壊れる |
| `.ps1` / `.psm1` | UTF-8 | CRLF | **必須** | BOM なしだと PS5.1 が CP932 として読む |
| `.bat` | ASCII/SJIS | CRLF | なし | 日本語コメントは文字化けする → 英語のみ |
| `.py` | UTF-8 | LF | なし | |
| `.conf` / `.lst` / `.yaml` | UTF-8 | LF | なし | |
| `.md` / `.sql` / `.json` | UTF-8 | LF | なし | |

### Python でファイルを書き込む際の注意

```python
# BAD: Windows では CRLF が混入する
path.write_text(content, encoding='utf-8')

# GOOD: 改行コードを明示する
path.write_text(content, encoding='utf-8', newline='\n')   # LF 固定
path.write_bytes(content.encode('utf-8'))                   # バイナリで制御

# PS1 ファイルには UTF-8 BOM を付与
path.write_bytes(b'\xef\xbb\xbf' + content.encode('utf-8'))
```

`write_text()` は Windows では `\n` を `\r\n` に変換する。  
bash スクリプトを Python で生成・編集した後は必ず CRLF が混入していないか確認すること。

---

## 2. Shift-JIS LF-eating バグ

**現象:** Windows の PS5.1 やエディタで Shift-JIS (CP932) として保存した際、  
マルチバイト文字の末尾バイトが後続の `LF (0x0A)` を「食う」ことがある。

**結果:** コメント行と次の行のコードが結合し、コードがコメントとして扱われ消える。

```bash
# 元の意図（2行）
# これはコメント行（末尾バイトが 0x94 などの Shift-JIS lead byte の場合）
local line="$1"   ← この行が消える

# 実際の保存結果（1行に結合）
# これはコメント行（末尾バイト...）local line="$1"   ← コメントに飲み込まれた
```

**確認方法:**

```python
with open('script.sh', 'rb') as f:
    data = f.read()
lines = data.split(b'\n')
for i, line in enumerate(lines, 1):
    # 非 ASCII バイトを含む行を表示
    if any(b > 127 for b in line):
        print(f'L{i}: {line[:100]}')
```

**修正方法:** バイトレベルで欠落行を復元する。  
`# shellcheck disable=SC2206` の直後に `local -a tok=( $line )` がない、  
`if [[ ...` が行頭に現れないなど、文脈からコードが欠落していることに気付く。

---

## 3. bash スクリプトの作法

### 必須ヘッダー

```bash
#!/usr/bin/env bash
set -euo pipefail
```

### よくあるエラーと対処

| エラー | 原因 | 対処 |
|---|---|---|
| `variable: unbound variable` | `set -u` 下での未初期化変数 | `declare -a arr=()` で空配列初期化（`declare -a arr` だけでは駄目） |
| `invalid option --tmpdir=` | MSYS2/一部 Linux 環境 | `mktemp "$dir/file.XXXXXX"` を使う |
| IFS で分割できない | `IFS='|||'` は `IFS='|'` と同じ | 非空白の IFS で重複文字は無視される。別ファイルに1行ずつ保存して `read` |
| root FS に書けない | Docker コンテナの `/ ` は read-only | 一時ファイルは `${TMPDIR:-/tmp}/` に書く |
| `bash -n` が通らない | CRLF 改行 | Python の `write_text` で書いた後は CRLF チェック必須 |

### 配列と `set -u`

```bash
# BAD: set -u 下でエラーになる
declare -a arr
echo ${#arr[@]}   # unbound variable

# GOOD
declare -a arr=()
echo ${#arr[@]}   # 0

# 連想配列も同様
declare -A map=()
```

### 一時ファイル

```bash
# BAD: MSYS2/Alpine で動かない場合がある
tmpfile=$(mktemp --tmpdir=/tmp test.XXXXXX)

# GOOD
tmpdir="${TMPDIR:-/tmp}"
tmpfile=$(mktemp "${tmpdir}/test.XXXXXX")
```

### IFS 区切りの落とし穴

```bash
# BAD: IFS='|||' は IFS='|' と同じ → 分割が崩れる
IFS='|||' read -r a b c <<< "val1|||val2|||val3"
# a=val1, b="", c="|val2|||val3"  ← 意図しない結果

# GOOD: 1行1値のファイルから読み戻す
printf '%s\n%s\n%s\n' "$val1" "$val2" "$val3" > "$tmpfile"
{ IFS= read -r a; IFS= read -r b; IFS= read -r c; } < "$tmpfile"
```

### JSON 出力時の null 安全

```bash
# BAD: 空文字が入ると不正 JSON になる ("net_rx_mbps":,)
printf '{"net_rx_mbps":%s}\n' "$net_rx_mbps"

# GOOD: ヘルパーで空文字を null に変換
_j() { [[ -z "$1" ]] && echo "null" || echo "$1"; }
printf '{"net_rx_mbps":%s}\n' "$(_j "$net_rx_mbps")"
```

### コンテナ環境での一時ファイル出力

`investigation` ファイルなど、スクリプトが相対パスに書き込む処理は  
コンテナ内で root FS (read-only) に書こうとしてエラーになる。

```bash
# BAD: カレントディレクトリが / (read-only) の場合に失敗
invest_file="investigation_${ts}.txt"

# GOOD
invest_dir="${TMPDIR:-/tmp}"
invest_file="${invest_dir}/investigation_${ts}.txt"
# さらに失敗してもメイン処理を止めない
run_investigation "$data" "$invest_file" || true
```

---

## 4. PowerShell スクリプトの作法

### 読み取り専用の自動変数

```powershell
# BAD: $Host は PS の自動変数（read-only）
foreach ($hEntry in $hostEntries) {
    $host = $hEntry.host   # Set-StrictMode 下でエラー

# GOOD
foreach ($hEntry in $hostEntries) {
    $hName = $hEntry.host
```

代表的な読み取り専用変数: `$Host`、`$PSVersionTable`、`$PID`、`$PWD` など。

### `return if` は無効

```powershell
# BAD: 'if' がコマンド名として解釈されエラー
return if ($x -eq 'ok') { 'PASS' } else { 'FAIL' }

# GOOD
if ($x -eq 'ok') { return 'PASS' } else { return 'FAIL' }

# $var = if (...) は有効（代入コンテキストでは式として評価される）
$result = if ($x -eq 'ok') { 'PASS' } else { 'FAIL' }
```

### `utf8NoBOM` は PS7+ のみ

```powershell
# BAD: PS5.1 では無効
$text | Out-File $file -Encoding utf8NoBOM

# GOOD: BOM なし UTF-8（PS5.1/PS7 両対応）
$enc = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::AppendAllText($file, $text + [Environment]::NewLine, $enc)
[System.IO.File]::WriteAllText($file, $text, $enc)

# ステータスファイル等 BOM があっても問題ない場合
$text | Out-File $file -Encoding utf8    # PS5.1 では BOM が付く
```

### `Start-Job` vs `Start-Process`

```powershell
# BAD: Start-Job のバックグラウンドジョブは
#      親 PowerShell プロセスが終了すると一緒に終了する
#      → cmd.exe/bat から呼ぶと即終了する
$job = Start-Job -ScriptBlock { ... }

# GOOD: 独立プロセスとして起動（bat 経由でも継続動作する）
$proc = Start-Process powershell.exe `
    -ArgumentList @('-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script) `
    -WindowStyle Hidden -PassThru
$proc.Id | Out-File 'collector.pid' -Encoding utf8
```

### ArgumentList での型キャスト

```powershell
# BAD: [int] が型リテラルとして配列に入り $Interval が System.Type になる
$job = Start-Job -ScriptBlock $block -ArgumentList $dir, [int]$CFG['Interval']

# GOOD: 事前に変数へ代入
$argInterval = [int]$CFG['Interval']
$job = Start-Job -ScriptBlock $block -ArgumentList $dir, $argInterval
```

### `Resolve-Path` はパスが存在しないとエラー

```powershell
# BAD: パスが存在しない場合エラー
$absPath = (Resolve-Path $outputDir).Path

# GOOD: 先に作成してから解決
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
$absPath = (Resolve-Path $outputDir).Path
```

### stdout リダイレクトと Out-File の競合

```powershell
# Start-Process で -RedirectStandardOutput を指定すると
# 同じファイルを Out-File で開けなくなる（ロック競合）

# BAD: collector.log に両方が書き込もうとする
$proc = Start-Process powershell.exe -RedirectStandardOutput 'collector.log'
# プロセス内: "msg" | Out-File 'collector.log' -Append  ← エラー

# GOOD: ログは Write-Host (stdout → リダイレクト先) で出力する
function CLog($lvl, $msg) {
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Write-Host "[$ts] [$lvl] $msg"   # stdout がリダイレクト先に流れる
}
```

### `Set-StrictMode -Version Latest` での注意点

- 未定義変数の参照でエラー → 使う前に必ず初期化
- 配列の範囲外アクセスでエラー
- メソッド呼び出しの結果を捨てる場合は `$null = ...` または `| Out-Null`

---

## 5. バッチファイル (.bat) の作法

### 日本語コメントは書かない

```bat
:: BAD: cmd.exe は CP932 で読む → UTF-8 の日本語が文字化け → 誤動作
:: セッションを開始します

:: GOOD: 英語コメントのみ
:: Start the session
```

### ArgumentList の渡し方

```bat
:: shift 後は %* が使えないため、個別に渡す
:cmd_stop
if "%~2"=="" (
    powershell.exe -ExecutionPolicy Bypass -File "%PS1%" stop
) else (
    powershell.exe -ExecutionPolicy Bypass -File "%PS1%" stop ^
        -SessionDir "%~2" %3 %4 %5 %6 %7 %8
)
```

### パスのスペース対応

```bat
:: パスを必ず "" で囲む
powershell.exe -File "%PS1%" report -SessionDir "%~2"
```

---

## 6. Python スクリプトの作法

### JSON 関連

```python
# Python の null は None（JSON の null ではない）
# BAD: Python の heredoc 内で JSON の null を使う
rows.append({'value': null})   # NameError

# GOOD
rows.append({'value': None})   # Python → json.dumps() で null に変換される

# 読み込み時は BOM を考慮する
# PS5.1 が utf8NoBOM なしで書いたファイルは BOM 付きになることがある
with open(path, encoding='utf-8-sig') as f:   # utf-8-sig は BOM を自動除去
    data = json.loads(f.read())
```

### HTML レポート生成

```python
# Chart.js は CDN から読み込む（オフライン環境では対応できないため要注意）
# しきい値ラインはデータセットとして追加する（プラグインなしで実現）
# 文字コードは UTF-8 で書き出す
Path(output_path).write_text(html, encoding='utf-8')
```

---

## 7. スクリプト構造の統一パターン

### ファイル命名

| 種別 | Linux | Windows |
|---|---|---|
| ライフサイクル制御 | `tomcatctl.sh` | `TomcatCtl.ps1` |
| 情報収集 | `get_server_info.sh` | `Get-ServerInfo.ps1` |
| ローテート | `rotate_log.sh` | `Rotate-Log.ps1` |
| 起動バッチ | — | `xxx.bat` |

### スクリプトヘッダー（bash）

```bash
#!/usr/bin/env bash
# ============================================================================
# scriptname.sh
#   [1行の概要説明]
#
# 使い方:
#   scriptname.sh <action> [options]
#
# アクション:
#   start / stop / restart / status
#
# オプション:
#   -w  完了まで待機
#   -t  タイムアウト秒 (既定: 120)
#
# 終了コード: 0 成功/スキップ, 1 usage, 2 サービス不在,
#             3 タイムアウト, 4 実行失敗, 10 依存ツール不在
# ============================================================================
set -euo pipefail
```

### 終了コード規約

| コード | 意味 |
|---|---|
| 0 | 成功 / スキップ（冪等） |
| 1 | usage エラー（引数不正） |
| 2 | 前提条件不在（サービス未登録など） |
| 3 | 待機タイムアウト |
| 4 | 実行失敗（コマンド失敗数） |
| 10 | 依存ツール不在（systemctl、aws CLI など） |
| 20 | 認証エラー |

### 冪等性

```bash
# 既に目的の状態ならスキップ（何度実行しても結果が同じ）
if [[ "$action" == "start" && "$before_state" == "active" ]]; then
    log_info "Skipped (idempotent): service=$service state=active"
    status="skipped"; exit 0
fi
```

### ライブラリの読み込み

```bash
# リポジトリ内でもデプロイ先でも動くように複数パスを試す
_ops_lib=""
for _d in "${SCRIPT_DIR}/../lib" "${SCRIPT_DIR}/../lib/linux"; do
    if [[ -f "${_d}/logging.sh" ]]; then
        _ops_lib="$(cd "${_d}" && pwd)"; break
    fi
done
[[ -z "${_ops_lib:-}" ]] && { echo "[ERROR] lib/logging.sh not found" >&2; exit 1; }
source "${_ops_lib}/logging.sh"
source "${_ops_lib}/config.sh"
```

### 設定ファイル

- 場所: `config/default/<scriptname>.conf`
- 優先順位: **CLI 引数 > 設定ファイル > スクリプト既定値**
- フォーマット: `Key = Value`（`#` コメント可）

---

## 8. 比較・差分検出ツールの注意点

### volatile なメトリクスは比較対象から除外する

瞬間値は常に変動するため、before/after スナップショットを比較すると  
実質的な変化がなくても必ず「差分あり」と判定されてしまう。

```python
# BAD: 常に変動するメトリクスを比較すると偽陽性が大量発生
compare_dicts(before['os'], after['os'])   # free_memory_gb 等も含む

# GOOD: volatile なフィールドを除外してから比較
_VOLATILE = {'free_memory_gb', 'used_memory_gb', 'swap_free_gb'}
bd = {k: v for k, v in before['os'].items() if k not in _VOLATILE}
ad = {k: v for k, v in after['os'].items()  if k not in _VOLATILE}
compare_dicts(bd, ad)
```

**除外すべき volatile フィールドの例:**

| カテゴリ | 除外フィールド | 比較すべきフィールド |
|---|---|---|
| OS | `free_memory_gb`, `used_memory_gb`, `swap_free_gb` | `total_memory_gb`, `swap_total_gb` |
| Filesystem | `free_gb`, `used_gb`, `used_pct` | `total_gb`, `fstype` |
| Network | (変動しない) | `address`, `prefix` |

---

## 9. Docker テスト環境

### コンテナ構成

| コンテナ | イメージ | 用途 |
|---|---|---|
| `ops-test-linux` | Ubuntu 22.04 | bash スクリプトのテスト |
| `ops-test-powershell` | PowerShell 7.4 on Ubuntu | PS スクリプトのテスト |

### 起動オプション

```powershell
# 両コンテナとも --cap-add=NET_RAW が必要（Ping のため）
docker run --rm --cap-add=NET_RAW -v "${RepoRoot}:/repo:ro" ops-test-linux:latest ...
docker run --rm --cap-add=NET_RAW -v "${RepoRoot}:/repo:ro" ops-test-powershell:latest ...
```

### テストスクリプト

| ファイル | 内容 |
|---|---|
| `tests/docker/linux_tests.sh` | bash テストスイート（コンテナ内で実行） |
| `tests/docker/powershell_tests.ps1` | PS テストスイート（コンテナ内で実行） |
| `tests/docker/run_tests.ps1` | ホスト側ランナー（両コンテナを起動） |

### 新機能追加時のテスト追加ルール

1. `linux_tests.sh` に Suite を追加（bash / Python ツール）
2. `powershell_tests.ps1` に Suite を追加（PS ツール / render_report.py）
3. テストはドライラン・構文チェック中心（実際の AWS 操作などは行わない）
4. コンテナ内の一時ファイルは `/tmp/ops_test/` 以下に作成する

### テストで発見しやすいバグ

- **CRLF**: Python で生成した bash スクリプトが `bash -n` でエラー
- **読み取り専用 root**: `./output.txt` への書き込みが Permission denied
- **IFS 分割バグ**: 複数値の受け渡しが崩れて空文字になる
- **null/None の混在**: Python heredoc 内で `null` を使うと NameError
- **shellcheck disable コメント後の行消失**: Shift-JIS LF-eating バグ

---

## 10. ディレクトリ構造とファイル配置

```
ops-scripts-template/
├── scripts_linux/          # Linux 用スクリプト
│   ├── lib/               # logging.sh, config.sh
│   ├── os/               # rotate_log.sh, get_server_info.sh ...
│   ├── aws/              # backup_ami.sh, ec2ctl.sh ...
│   ├── postgresql/       # postgresqlctl.sh
│   ├── mysql/            # mysqlctl.sh
│   ├── hana/             # hanactl.sh (SAP HANA, Linux 専用)
│   ├── sap/              # sapctl.sh (S/4HANA)
│   ├── sqlserver/        # sqlserverctl.sh
│   └── tomcat/           # tomcatctl.sh
│
├── scripts_windows/        # Windows 用スクリプト
│   ├── lib/               # Logging.psm1, Config.psm1
│   ├── os/               # Rotate-Log.ps1, Get-ServerInfo.ps1 ...
│   ├── aws/              # Backup-Ami.ps1, Ec2Ctl.ps1 ...
│   ├── postgresql/       # PostgreSQLCtl.ps1
│   ├── mysql/            # MySQLCtl.ps1
│   ├── sap/              # SAPCtl.ps1 (S/4HANA / NetWeaver)
│   ├── sqlserver/        # SqlServerCtl.ps1
│   └── tomcat/           # TomcatCtl.ps1
│
├── config/
│   └── default/           # デフォルト設定ファイル (*.conf)
│
├── tools/                  # スタンドアロンツール
│   ├── server-compare/    # サーバー情報比較
│   ├── network-check/     # ネットワーク疎通確認
│   ├── change-detect/     # 変更検出
│   └── perf-monitor/      # 性能テスト用リソースモニター
│
├── docs_linux/             # Linux スクリプト仕様書
├── docs_windows/           # Windows スクリプト仕様書
├── tests/
│   ├── docker/            # Docker テストスイート
│   └── pester/            # PowerShell ユニットテスト
│
├── deploy/                 # ターゲットリポジトリへの自動配布
│   ├── servers.yaml       # サーバー台帳
│   ├── sync.py            # MR 自動作成スクリプト
│   └── SPEC.md            # 配布機能仕様書
│
├── .gitattributes          # 改行コード・エンコーディング設定
├── .gitignore
├── shell-specification.md  # シェルスクリプト仕様書
├── ops-scripts-structure.md # ディレクトリ構成設計書
└── development-rules.md    # ← 本ドキュメント
```

---

## 11. コミット規約

### プレフィックス

| プレフィックス | 用途 |
|---|---|
| `feat:` | 新機能追加 |
| `fix:` | バグ修正 |
| `test:` | テスト追加・修正 |
| `chore:` | メンテナンス（依存更新、gitignore 等） |
| `docs:` | ドキュメントのみの変更 |
| `refactor:` | 機能変更を伴わないリファクタリング |

### Co-Authored-By

AI アシスタントが生成したコミットには必ず付与する：

```
Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
```

### 複数ファイルのコミット分割方針

- **バグ修正と新機能は別コミット**にする
- 同一バグの複数ファイル修正は1コミットにまとめる
- テストスイートの追加は機能追加とは別コミットにしてもよい

---

*最終更新: 開発セッション中に蓄積した知見を反映*
