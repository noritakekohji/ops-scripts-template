# collect-snapshot 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `tools/collect-snapshot/` に断面情報収集ラッパーを追加し、1コマンドで server-snapshot / port-inventory / aws-instance-audit を順番に実行、結果を ZIP にまとめる

**Architecture:** `collect_snapshot.sh` / `CollectSnapshot.ps1` が3つの既存ツールを相対パスで呼び出し、順次実行・進捗表示・ZIP 圧縮を行う。`--menu` フラグで TUI モードに切り替わる。`collect_snapshot.bat` は `--menu` 付きで PS1 を起動するショートカット。

**Tech Stack:** Bash 4+ / PowerShell 5.1 / Batch / `zip` or `tar` (Linux) / `Compress-Archive` (Windows)

---

## ファイルマップ

| 操作 | パス | 役割 |
|---|---|---|
| 作成 | `tools/collect-snapshot/collect_snapshot.sh` | Linux 本体（CUI + TUI） |
| 作成 | `tools/collect-snapshot/CollectSnapshot.ps1` | Windows 本体（CUI + TUI） |
| 作成 | `tools/collect-snapshot/collect_snapshot.bat` | Windows 起動バッチ（`--menu` 付きで PS1 を呼ぶ） |
| 作成 | `tools/collect-snapshot/README.md` | ツールドキュメント |
| 作成 | `tests/bats/collect_snapshot.bats` | Bash テスト |
| 作成 | `tests/pester/CollectSnapshot.Tests.ps1` | PowerShell テスト |
| 修正 | `CHANGELOG.md` | `[Unreleased]` に追記 |

---

## 設計メモ（実装者向け）

### 各ツールの呼び出し方（Linux）

| ツール | 呼び出し | 出力 |
|---|---|---|
| server-snapshot | `bash .../server_snapshot.sh collect -o <file>` | ファイルに JSON 書き込み |
| port-inventory | `bash .../port_inventory.sh --json > <file>` | stdout → ファイルにリダイレクト |
| aws-instance-audit | `bash .../aws_instance_audit.sh -o <file>` | ファイルに JSON 書き込み |

### 各ツールの呼び出し方（Windows / PowerShell）

| ツール | 呼び出し | 出力 |
|---|---|---|
| server-snapshot | `powershell.exe -NoProfile -File ServerSnapshot.ps1 collect -OutputPath <file>` | ファイルに JSON 書き込み |
| port-inventory | `powershell.exe -NoProfile -Command "& 'PortInventory.ps1' -Json"` を キャプチャしてファイルへ | stdout pipeline |
| aws-instance-audit | `powershell.exe -NoProfile -File Get-AwsInstanceAudit.ps1 -OutputPath <file>` | ファイルに JSON 書き込み |

### ツールへの環境変数オーバーライド（テスト用）

```bash
COLLECT_SNAPSHOT_TOOLS_DIR=/path/to/mock/tools bash collect_snapshot.sh
```
```powershell
$env:COLLECT_SNAPSHOT_TOOLS_DIR = 'C:\mock\tools'
& '.\CollectSnapshot.ps1'
```

---

## Task 1: bats テスト — モック環境 + CUI 基本動作

**Files:**
- 作成: `tests/bats/collect_snapshot.bats`

- [ ] **Step 1: テストファイルを作成（失敗する状態）**

```bash
# tests/bats/collect_snapshot.bats
#!/usr/bin/env bats
load test_helper

CTL="${TOOLS_DIR}/collect-snapshot/collect_snapshot.sh"

setup() {
    WORK=$(make_test_workdir)
    MOCK_TOOLS="${WORK}/mock_tools"
    export MOCK_CALL_LOG="${WORK}/mock_calls.log"
    : > "$MOCK_CALL_LOG"

    # モックツール構造を作成
    for t in server-snapshot port-inventory aws-instance-audit; do
        mkdir -p "${MOCK_TOOLS}/${t}"
    done

    # server-snapshot モック: -o <file> に JSON を書く
    cat > "${MOCK_TOOLS}/server-snapshot/server_snapshot.sh" <<'EOF'
#!/usr/bin/env bash
echo "server-snapshot: $*" >> "$MOCK_CALL_LOG"
# -o の次の引数にファイルを書き込む
prev=''
for a in "$@"; do
    [[ "$prev" == "-o" ]] && echo '{"tool":"server-snapshot"}' > "$a"
    prev="$a"
done
exit 0
EOF
    chmod +x "${MOCK_TOOLS}/server-snapshot/server_snapshot.sh"

    # port-inventory モック: --json で stdout に JSON
    cat > "${MOCK_TOOLS}/port-inventory/port_inventory.sh" <<'EOF'
#!/usr/bin/env bash
echo "port-inventory: $*" >> "$MOCK_CALL_LOG"
echo '[{"tool":"port-inventory"}]'
exit 0
EOF
    chmod +x "${MOCK_TOOLS}/port-inventory/port_inventory.sh"

    # aws-instance-audit モック: -o <file> に JSON を書く
    cat > "${MOCK_TOOLS}/aws-instance-audit/aws_instance_audit.sh" <<'EOF'
#!/usr/bin/env bash
echo "aws-instance-audit: $*" >> "$MOCK_CALL_LOG"
prev=''
for a in "$@"; do
    [[ "$prev" == "-o" ]] && echo '{"tool":"aws-instance-audit"}' > "$a"
    prev="$a"
done
exit 0
EOF
    chmod +x "${MOCK_TOOLS}/aws-instance-audit/aws_instance_audit.sh"

    export COLLECT_SNAPSHOT_TOOLS_DIR="$MOCK_TOOLS"
}

teardown() { rm -rf "$WORK"; }

# ── ラベル付きフォルダ名 ───────────────────────────────────────────────
@test "collect_snapshot: --label でフォルダ名にラベルが入る" {
    run bash "$CTL" --label pre-upgrade --output "$WORK/out"
    [ "$status" -eq 0 ]
    # ZIP ファイル名に "pre-upgrade" が含まれる
    ls "$WORK/out/"*pre-upgrade*.zip 1>/dev/null
}

# ── ラベルなしフォルダ名 ────────────────────────────────────────────────
@test "collect_snapshot: ラベルなしでフォルダ名にラベルが入らない" {
    run bash "$CTL" --output "$WORK/out"
    [ "$status" -eq 0 ]
    # ZIP が 1 個ある
    local zips; zips=( "$WORK/out/"*.zip )
    [ "${#zips[@]}" -eq 1 ]
    # "pre-upgrade" を含まない
    [[ "$(basename "${zips[0]}")" != *pre-upgrade* ]]
}

# ── 保存先デフォルト ─────────────────────────────────────────────────────
@test "collect_snapshot: --output なしで ./snapshots に保存される" {
    cd "$WORK"
    run bash "$CTL"
    [ "$status" -eq 0 ]
    ls "$WORK/snapshots/"*.zip 1>/dev/null
}

# ── 保存先指定 ──────────────────────────────────────────────────────────
@test "collect_snapshot: --output で保存先を変更できる" {
    run bash "$CTL" --output "$WORK/custom_out"
    [ "$status" -eq 0 ]
    ls "$WORK/custom_out/"*.zip 1>/dev/null
}
```

- [ ] **Step 2: テストが失敗することを確認**

```
bats tests/bats/collect_snapshot.bats
```
期待: すべて `not found` や `syntax error` などで FAIL

---

## Task 2: collect_snapshot.sh — 引数解析 + 出力ディレクトリ + ツール実行 + ZIP

**Files:**
- 作成: `tools/collect-snapshot/collect_snapshot.sh`

- [ ] **Step 1: スクリプト骨格を作成**

```bash
#!/usr/bin/env bash
# ============================================================
# collect_snapshot.sh
#   断面情報収集ラッパー — server-snapshot / port-inventory /
#   aws-instance-audit を順番に実行し ZIP にまとめる
#
# Usage:
#   collect_snapshot.sh [--label <label>] [--output <dir>] [--menu]
#
# Options:
#   --label, -l <label>   スナップショットのラベル（省略可）
#   --output, -o <dir>    保存先ディレクトリ（既定: ./snapshots）
#   --menu, -m            TUI メニューを表示
#
# Exit codes:
#   0  全ツール正常完了
#   1  1 つ以上のツールが失敗、または ZIP 圧縮失敗
#   10 前提コマンド不足
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="${COLLECT_SNAPSHOT_TOOLS_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

LABEL=''
OUTPUT_DIR='./snapshots'
MENU=0
ALL_TOOLS=('server-snapshot' 'port-inventory' 'aws-instance-audit')
SELECTED_TOOLS=()

# ── Phase 2: 引数解析 ─────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --label|-l)  LABEL="$2";      shift 2 ;;
        --output|-o) OUTPUT_DIR="$2"; shift 2 ;;
        --menu|-m)   MENU=1;          shift   ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
    esac
done

HOSTNAME_VAL="$(hostname -s 2>/dev/null || hostname)"
TIMESTAMP="$(TZ=Asia/Tokyo date '+%Y%m%d-%H%M%S')"
HOSTNAME_TS="${HOSTNAME_VAL}_${TIMESTAMP}"

if [[ -n "$LABEL" ]]; then
    SNAP_NAME="${HOSTNAME_VAL}_${LABEL}_${TIMESTAMP}"
else
    SNAP_NAME="${HOSTNAME_VAL}_${TIMESTAMP}"
fi

# ── Phase 3: 前提コマンドチェック ─────────────────────────────────────
if ! command -v zip >/dev/null 2>&1 && ! command -v tar >/dev/null 2>&1; then
    printf '[collect-snapshot] ERROR: zip または tar が必要です\n' >&2
    exit 10
fi

# ── ツール実行関数 ─────────────────────────────────────────────────────
run_tool() {
    local tool_name="$1"
    local snap_dir="$2"
    local host_ts="$3"

    local tool_dir="${TOOLS_DIR}/${tool_name}"
    local out_subdir="${snap_dir}/${tool_name}"
    mkdir -p "$out_subdir"
    local out_json="${out_subdir}/${host_ts}.json"

    case "$tool_name" in
        server-snapshot)
            local script="${tool_dir}/server_snapshot.sh"
            if [[ ! -f "$script" ]]; then
                printf '[WARN] not found: %s\n' "$script" >&2; return 1
            fi
            bash "$script" collect -o "$out_json"
            ;;
        port-inventory)
            local script="${tool_dir}/port_inventory.sh"
            if [[ ! -f "$script" ]]; then
                printf '[WARN] not found: %s\n' "$script" >&2; return 1
            fi
            bash "$script" --json > "$out_json"
            ;;
        aws-instance-audit)
            local script="${tool_dir}/aws_instance_audit.sh"
            if [[ ! -f "$script" ]]; then
                printf '[WARN] not found: %s\n' "$script" >&2; return 1
            fi
            bash "$script" -o "$out_json"
            ;;
        *)
            printf '[WARN] unknown tool: %s\n' "$tool_name" >&2; return 1
            ;;
    esac
}

# ── 全ツール実行 ───────────────────────────────────────────────────────
run_all() {
    local out_dir="$1"
    local snap_name="$2"
    shift 2
    local tools=("$@")

    local snap_dir="${out_dir}/${snap_name}"
    mkdir -p "$snap_dir"
    local log_file="${snap_dir}/collect-snapshot.log"
    local overall_exit=0
    local total="${#tools[@]}"
    local n=0

    printf '[collect-snapshot] host=%s  start=%s\n' \
        "$HOSTNAME_VAL" "$(TZ=Asia/Tokyo date '+%Y-%m-%d %H:%M:%S')"
    printf '[collect-snapshot] output=%s/\n' "$snap_dir"

    for tool in "${tools[@]}"; do
        n=$((n + 1))
        printf '[%d/%d] %-22s ... ' "$n" "$total" "$tool"

        local t_start; t_start="$(date '+%Y-%m-%d %H:%M:%S')"
        local exit_code=0

        if run_tool "$tool" "$snap_dir" "$HOSTNAME_TS" >> "$log_file" 2>&1; then
            exit_code=0
        else
            exit_code=$?
        fi

        if [[ "$exit_code" -eq 0 ]]; then
            printf 'done (exit=0)\n'
        else
            printf 'WARN (exit=%d)\n' "$exit_code"
            overall_exit=1
        fi
        printf '[%s] %s: exit=%d\n' "$t_start" "$tool" "$exit_code" >> "$log_file"
    done

    # ── ZIP 圧縮 ──────────────────────────────────────────────────────
    local zip_name="${snap_name}.zip"
    local zip_path="${out_dir}/${zip_name}"
    printf '[collect-snapshot] compressing ... '

    local compress_ok=0
    if command -v zip >/dev/null 2>&1; then
        (cd "$out_dir" && zip -qr "$zip_name" "$snap_name") && compress_ok=1
    fi
    if [[ "$compress_ok" -eq 0 ]] && command -v tar >/dev/null 2>&1; then
        tar -czf "${out_dir}/${snap_name}.tar.gz" -C "$out_dir" "$snap_name" && \
            zip_path="${out_dir}/${snap_name}.tar.gz" && compress_ok=1
    fi

    if [[ "$compress_ok" -eq 1 ]]; then
        rm -rf "$snap_dir"
        printf '%s\n' "$(basename "$zip_path")"
        printf '[collect-snapshot] all done.\n'
    else
        printf 'ERROR: compression failed\n' >&2
        return 1
    fi

    return "$overall_exit"
}

# ── TUI モード ─────────────────────────────────────────────────────────
run_tui() {
    printf '\033[1;34m╔══════════════════════════════════════════════════╗\033[0m\n'
    printf '\033[1;34m║         断面情報収集ツール  v1.0                ║\033[0m\n'
    printf '\033[1;34m╚══════════════════════════════════════════════════╝\033[0m\n'
    printf 'ホスト名: %s  |  日時: %s\n\n' \
        "$HOSTNAME_VAL" "$(TZ=Asia/Tokyo date '+%Y-%m-%d %H:%M:%S')"

    # Step 1: ラベル
    printf 'Step 1: スナップショットのラベルを入力してください（空 Enter でスキップ）\n'
    printf 'ラベル > '
    read -r tui_label
    LABEL="${tui_label:-}"

    # Step 2: 保存先
    printf '\nStep 2: 保存先ディレクトリ [Enter で ./snapshots]\n'
    printf '保存先 > '
    read -r tui_output
    OUTPUT_DIR="${tui_output:-./snapshots}"

    # Step 3: ツール選択
    printf '\nStep 3: 実行ツールを選択（番号をカンマ区切り、Enter で全選択）\n'
    local i=1
    for t in "${ALL_TOOLS[@]}"; do
        printf '  [%d] %s\n' "$i" "$t"
        i=$((i + 1))
    done
    printf '選択 [1,2,3] > '
    read -r tui_sel

    local selected=()
    if [[ -z "${tui_sel// /}" ]]; then
        selected=("${ALL_TOOLS[@]}")
    else
        IFS=',' read -ra nums <<< "$tui_sel"
        for num in "${nums[@]}"; do
            num="${num// /}"
            if [[ "$num" =~ ^[1-3]$ ]]; then
                selected+=("${ALL_TOOLS[$((num - 1))]}")
            fi
        done
        [[ "${#selected[@]}" -eq 0 ]] && selected=("${ALL_TOOLS[@]}")
    fi

    # SNAP_NAME を再構築（TUI でラベルが変わるため）
    if [[ -n "$LABEL" ]]; then
        SNAP_NAME="${HOSTNAME_VAL}_${LABEL}_${TIMESTAMP}"
    else
        SNAP_NAME="${HOSTNAME_VAL}_${TIMESTAMP}"
    fi

    printf '\n'
    run_all "$OUTPUT_DIR" "$SNAP_NAME" "${selected[@]}"
}

# ── Phase 4: メイン ────────────────────────────────────────────────────
if [[ "$MENU" -eq 1 ]]; then
    run_tui
else
    run_all "$OUTPUT_DIR" "$SNAP_NAME" "${ALL_TOOLS[@]}"
fi
```

- [ ] **Step 2: 実行権限を付与**

```bash
chmod +x tools/collect-snapshot/collect_snapshot.sh
```

- [ ] **Step 3: Task 1 のテストを実行して全パス確認**

```
bats tests/bats/collect_snapshot.bats
```
期待: 4 tests passed

- [ ] **Step 4: ツール失敗シナリオのテストを追加（Task 1 のファイルに追記）**

`tests/bats/collect_snapshot.bats` の末尾に追加:

```bash
# ── ツール失敗時の継続 ──────────────────────────────────────────────────
@test "collect_snapshot: 1ツール失敗でも残りを実行して exit 1" {
    # port-inventory を失敗させる
    cat > "${MOCK_TOOLS}/port-inventory/port_inventory.sh" <<'EOF'
#!/usr/bin/env bash
echo "port-inventory: $*" >> "$MOCK_CALL_LOG"
exit 1
EOF
    chmod +x "${MOCK_TOOLS}/port-inventory/port_inventory.sh"

    run bash "$CTL" --output "$WORK/out"
    [ "$status" -eq 1 ]
    # 他の 2 ツールは呼ばれている
    grep -q 'server-snapshot:' "$MOCK_CALL_LOG"
    grep -q 'aws-instance-audit:' "$MOCK_CALL_LOG"
    # ZIP は生成される
    ls "$WORK/out/"*.zip 1>/dev/null
}

@test "collect_snapshot: ツールスクリプト不在でも続行して exit 1" {
    rm -f "${MOCK_TOOLS}/port-inventory/port_inventory.sh"

    run bash "$CTL" --output "$WORK/out"
    [ "$status" -eq 1 ]
    # server-snapshot と aws-instance-audit は呼ばれている
    grep -q 'server-snapshot:' "$MOCK_CALL_LOG"
    grep -q 'aws-instance-audit:' "$MOCK_CALL_LOG"
}

@test "collect_snapshot: --menu フラグを受け付ける（引数エラーにならない）" {
    # stdin を /dev/null にして TUI を即終了させる（Enter x4）
    run bash "$CTL" --menu --output "$WORK/out" <<'EOF'

EOF
    # exit 0 または 1（ツール次第）、引数エラー (exit 1 with "Unknown option") ではない
    [[ "$output" != *"Unknown option"* ]]
}
```

- [ ] **Step 5: テストを再実行して全パス確認**

```
bats tests/bats/collect_snapshot.bats
```
期待: 7 tests passed

- [ ] **Step 6: コミット**

```bash
git add tools/collect-snapshot/collect_snapshot.sh tests/bats/collect_snapshot.bats
git commit -m "feat(collect-snapshot): add collect_snapshot.sh with CUI/TUI modes"
```

---

## Task 3: Pester テスト + CollectSnapshot.ps1

**Files:**
- 作成: `tests/pester/CollectSnapshot.Tests.ps1`
- 作成: `tools/collect-snapshot/CollectSnapshot.ps1`

- [ ] **Step 1: Pester テストファイルを作成（失敗する状態）**

```powershell
# tests/pester/CollectSnapshot.Tests.ps1
#Requires -Version 5.1
<#
.SYNOPSIS
    CollectSnapshot.ps1 の単体テスト（モックツールを使用）
#>
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $script:ps1 = Join-Path (Get-RepoRoot) 'tools\collect-snapshot\CollectSnapshot.ps1'

    # モックツール構造を作成するヘルパー
    function New-MockToolsDir {
        $mockRoot = New-TempWorkdir

        foreach ($t in @('server-snapshot','port-inventory','aws-instance-audit')) {
            New-Item -ItemType Directory -Path (Join-Path $mockRoot $t) -Force | Out-Null
        }

        # server-snapshot モック: -OutputPath <file> に JSON を書く
        $ssScript = @'
#Requires -Version 5.1
param([string]$Command='', [string]$OutputPath='')
Add-Content -Path $env:MOCK_CALL_LOG -Value "server-snapshot: $Command $OutputPath"
if ($OutputPath) { '{"tool":"server-snapshot"}' | Set-Content -Path $OutputPath -Encoding UTF8 }
exit 0
'@
        $ssScript | Set-Content -Path (Join-Path $mockRoot 'server-snapshot\ServerSnapshot.ps1') -Encoding UTF8

        # port-inventory モック: -Json で stdout に JSON
        $piScript = @'
#Requires -Version 5.1
param([switch]$Json)
Add-Content -Path $env:MOCK_CALL_LOG -Value "port-inventory: $(if($Json){'-Json'})"
if ($Json) { '[{"tool":"port-inventory"}]' }
exit 0
'@
        $piScript | Set-Content -Path (Join-Path $mockRoot 'port-inventory\PortInventory.ps1') -Encoding UTF8

        # aws-instance-audit モック: -OutputPath <file> に JSON を書く
        $awsScript = @'
#Requires -Version 5.1
param([string]$OutputPath='')
Add-Content -Path $env:MOCK_CALL_LOG -Value "aws-instance-audit: $OutputPath"
if ($OutputPath) { '{"tool":"aws-instance-audit"}' | Set-Content -Path $OutputPath -Encoding UTF8 }
exit 0
'@
        $awsScript | Set-Content -Path (Join-Path $mockRoot 'aws-instance-audit\Get-AwsInstanceAudit.ps1') -Encoding UTF8

        return $mockRoot
    }
}

Describe 'CollectSnapshot: ラベル付きフォルダ名' {
    It '--Label でフォルダ名にラベルが入る' {
        $work = New-TempWorkdir
        $mock = New-MockToolsDir
        $callLog = Join-Path $work 'mock_calls.log'
        try {
            $r = Invoke-Controller -ScriptPath $script:ps1 `
                -Arguments @('-Label', 'pre-upgrade', '-Output', "$work\out") `
                -Env @{ COLLECT_SNAPSHOT_TOOLS_DIR = $mock; MOCK_CALL_LOG = $callLog }
            $r.ExitCode | Should -Be 0
            $zips = Get-ChildItem -Path "$work\out" -Filter '*pre-upgrade*.zip' -ErrorAction SilentlyContinue
            $zips | Should -Not -BeNullOrEmpty
        } finally { Remove-TempPath $work; Remove-TempPath $mock }
    }
}

Describe 'CollectSnapshot: ラベルなしフォルダ名' {
    It 'ラベルなしでも ZIP が 1 個生成される' {
        $work = New-TempWorkdir
        $mock = New-MockToolsDir
        $callLog = Join-Path $work 'mock_calls.log'
        try {
            $r = Invoke-Controller -ScriptPath $script:ps1 `
                -Arguments @('-Output', "$work\out") `
                -Env @{ COLLECT_SNAPSHOT_TOOLS_DIR = $mock; MOCK_CALL_LOG = $callLog }
            $r.ExitCode | Should -Be 0
            $zips = Get-ChildItem -Path "$work\out" -Filter '*.zip' -ErrorAction SilentlyContinue
            @($zips).Count | Should -Be 1
        } finally { Remove-TempPath $work; Remove-TempPath $mock }
    }
}

Describe 'CollectSnapshot: ツール失敗時' {
    It '1ツール失敗でも残りを実行して exit 1' {
        $work = New-TempWorkdir
        $mock = New-MockToolsDir
        $callLog = Join-Path $work 'mock_calls.log'
        # port-inventory を失敗させる
        'exit 1' | Set-Content -Path (Join-Path $mock 'port-inventory\PortInventory.ps1') -Encoding UTF8
        try {
            $r = Invoke-Controller -ScriptPath $script:ps1 `
                -Arguments @('-Output', "$work\out") `
                -Env @{ COLLECT_SNAPSHOT_TOOLS_DIR = $mock; MOCK_CALL_LOG = $callLog }
            $r.ExitCode | Should -Be 1
            # 他 2 ツールは呼ばれている
            $log = Get-Content $callLog -ErrorAction SilentlyContinue
            $log | Should -Match 'server-snapshot'
            $log | Should -Match 'aws-instance-audit'
            # ZIP は生成される
            $zips = Get-ChildItem -Path "$work\out" -Filter '*.zip' -ErrorAction SilentlyContinue
            $zips | Should -Not -BeNullOrEmpty
        } finally { Remove-TempPath $work; Remove-TempPath $mock }
    }
}
```

- [ ] **Step 2: テストが失敗することを確認**

```powershell
# PS5.1 環境で実行
Invoke-Pester tests/pester/CollectSnapshot.Tests.ps1 -Output Detailed
```
期待: `CollectSnapshot.ps1 not found` 等で FAIL

- [ ] **Step 3: CollectSnapshot.ps1 を作成**

```powershell
# tools/collect-snapshot/CollectSnapshot.ps1
#Requires -Version 5.1
<#
.SYNOPSIS
    断面情報収集ラッパー — server-snapshot / port-inventory / aws-instance-audit を
    順番に実行し、結果を ZIP にまとめる

.PARAMETER Label
    スナップショットのラベル（省略可）

.PARAMETER Output
    保存先ディレクトリ（既定: ./snapshots）

.PARAMETER Menu
    TUI メニューを表示して対話的に実行

.EXAMPLE
    .\CollectSnapshot.ps1
    .\CollectSnapshot.ps1 -Label pre-upgrade
    .\CollectSnapshot.ps1 -Label pre-upgrade -Output D:\snapshots
    .\CollectSnapshot.ps1 --menu
#>
[CmdletBinding()]
param(
    [string]$Label  = '',
    [string]$Output = '',
    [switch]$Menu
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ToolsDir  = if ($env:COLLECT_SNAPSHOT_TOOLS_DIR) {
                 $env:COLLECT_SNAPSHOT_TOOLS_DIR
             } else {
                 Split-Path -Parent $ScriptDir
             }

$AllTools  = @('server-snapshot', 'port-inventory', 'aws-instance-audit')
$HostVal   = $env:COMPUTERNAME
$Timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
if (-not $Output) { $Output = '.\snapshots' }

function Get-SnapName {
    param([string]$Lbl)
    if ($Lbl) { "${HostVal}_${Lbl}_${Timestamp}" }
    else       { "${HostVal}_${Timestamp}" }
}

# ── ツール実行 ─────────────────────────────────────────────────────────
function Invoke-SnapTool {
    param([string]$ToolName, [string]$SnapDir, [string]$HostTs)

    $toolDir   = Join-Path $ToolsDir $ToolName
    $outSubDir = Join-Path $SnapDir  $ToolName
    [void](New-Item -ItemType Directory -Path $outSubDir -Force)
    $outJson   = Join-Path $outSubDir "${HostTs}.json"

    $psExe = (Get-Command powershell.exe -ErrorAction SilentlyContinue)?.Source
    if (-not $psExe) { $psExe = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source }
    if (-not $psExe) { Write-Warning "PowerShell host not found"; return 10 }

    switch ($ToolName) {
        'server-snapshot' {
            $script = Join-Path $toolDir 'ServerSnapshot.ps1'
            if (-not (Test-Path $script)) { Write-Warning "not found: $script"; return 1 }
            & $psExe -NoProfile -File $script collect -OutputPath $outJson
            return $LASTEXITCODE
        }
        'port-inventory' {
            $script = Join-Path $toolDir 'PortInventory.ps1'
            if (-not (Test-Path $script)) { Write-Warning "not found: $script"; return 1 }
            $json = & $psExe -NoProfile -Command "& '$($script -replace "'","''")' -Json" 2>$null
            [System.IO.File]::WriteAllText(
                $outJson,
                ($json -join "`n"),
                [System.Text.UTF8Encoding]::new($false)
            )
            return $LASTEXITCODE
        }
        'aws-instance-audit' {
            $script = Join-Path $toolDir 'Get-AwsInstanceAudit.ps1'
            if (-not (Test-Path $script)) { Write-Warning "not found: $script"; return 1 }
            & $psExe -NoProfile -File $script -OutputPath $outJson
            return $LASTEXITCODE
        }
        default { Write-Warning "unknown tool: $ToolName"; return 1 }
    }
}

# ── 全ツール順次実行 ───────────────────────────────────────────────────
function Invoke-AllTools {
    param([string]$OutDir, [string]$SnapName, [string[]]$Tools)

    $snapDir = Join-Path $OutDir $SnapName
    [void](New-Item -ItemType Directory -Path $snapDir -Force)
    $logFile = Join-Path $snapDir 'collect-snapshot.log'
    $hostTs  = "${HostVal}_${Timestamp}"
    $overall = 0
    $total   = $Tools.Count
    $n       = 0

    Write-Host ("[collect-snapshot] host={0}  start={1}" -f $HostVal, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    Write-Host ("[collect-snapshot] output={0}\" -f $snapDir)

    foreach ($tool in $Tools) {
        $n++
        Write-Host ("[{0}/{1}] {2,-22} ... " -f $n, $total, $tool) -NoNewline
        $tStart  = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $exitCode = 0

        try {
            $exitCode = Invoke-SnapTool -ToolName $tool -SnapDir $snapDir -HostTs $hostTs
            if ($null -eq $exitCode) { $exitCode = 0 }
        } catch {
            $exitCode = 1
            Add-Content -Path $logFile -Value "[$tStart] $tool ERROR: $_"
        }

        if ($exitCode -eq 0) {
            Write-Host 'done (exit=0)' -ForegroundColor Green
        } else {
            Write-Host "WARN (exit=$exitCode)" -ForegroundColor Yellow
            $overall = 1
        }
        Add-Content -Path $logFile -Value "[$tStart] ${tool}: exit=$exitCode"
    }

    # ── ZIP 圧縮 ──────────────────────────────────────────────────────
    $zipName = "${SnapName}.zip"
    $zipPath = Join-Path $OutDir $zipName
    Write-Host '[collect-snapshot] compressing ... ' -NoNewline

    try {
        Compress-Archive -Path $snapDir -DestinationPath $zipPath -Force
        Remove-Item -LiteralPath $snapDir -Recurse -Force
        Write-Host $zipName -ForegroundColor Green
        Write-Host '[collect-snapshot] all done.'
    } catch {
        Write-Host 'ERROR: compression failed' -ForegroundColor Red
        Write-Error $_
        exit 1
    }

    exit $overall
}

# ── TUI モード ─────────────────────────────────────────────────────────
function Invoke-TuiMenu {
    Write-Host '╔══════════════════════════════════════════════════╗' -ForegroundColor Blue
    Write-Host '║         断面情報収集ツール  v1.0                ║' -ForegroundColor Blue
    Write-Host '╚══════════════════════════════════════════════════╝' -ForegroundColor Blue
    Write-Host ("ホスト名: {0}  |  日時: {1}" -f $HostVal, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    Write-Host ''

    # Step 1
    Write-Host 'Step 1: スナップショットのラベルを入力してください（空 Enter でスキップ）'
    $tuiLabel = Read-Host 'ラベル'
    $tuiLabel = $tuiLabel.Trim()

    # Step 2
    Write-Host ''
    Write-Host 'Step 2: 保存先ディレクトリ [Enter で .\snapshots]'
    $tuiOutput = (Read-Host '保存先').Trim()
    if (-not $tuiOutput) { $tuiOutput = '.\snapshots' }

    # Step 3
    Write-Host ''
    Write-Host 'Step 3: 実行ツールを選択（番号をカンマ区切り、Enter で全選択）'
    for ($i = 0; $i -lt $AllTools.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $AllTools[$i])
    }
    $tuiSel = (Read-Host '選択 [1,2,3]').Trim()

    $selected = if ($tuiSel -eq '') {
        $AllTools
    } else {
        $nums = $tuiSel -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^[1-3]$' }
        if ($nums.Count -eq 0) { $AllTools }
        else { $nums | ForEach-Object { $AllTools[[int]$_ - 1] } }
    }

    Write-Host ''
    Invoke-AllTools -OutDir $tuiOutput -SnapName (Get-SnapName $tuiLabel) -Tools $selected
}

# ── Phase 4: メイン ────────────────────────────────────────────────────
if ($Menu) {
    Invoke-TuiMenu
} else {
    Invoke-AllTools -OutDir $Output -SnapName (Get-SnapName $Label) -Tools $AllTools
}
```

- [ ] **Step 4: Pester テストを実行して全パス確認**

```powershell
Invoke-Pester tests/pester/CollectSnapshot.Tests.ps1 -Output Detailed
```
期待: 3 tests passed

- [ ] **Step 5: コミット**

```bash
git add tools/collect-snapshot/CollectSnapshot.ps1 tests/pester/CollectSnapshot.Tests.ps1
git commit -m "feat(collect-snapshot): add CollectSnapshot.ps1 with CUI/TUI modes"
```

---

## Task 4: collect_snapshot.bat

**Files:**
- 作成: `tools/collect-snapshot/collect_snapshot.bat`

- [ ] **Step 1: bat ファイルを作成（UTF-8 BOM なし、CRLF）**

```batch
@echo off
setlocal

:: 英語コメント: Launch CollectSnapshot.ps1 in interactive (TUI) menu mode.
:: Double-clicking this bat opens the TUI menu.
:: To run unattended (CUI), call CollectSnapshot.ps1 directly.

set "SCRIPT_DIR=%~dp0"
set "PS_SCRIPT=%SCRIPT_DIR%CollectSnapshot.ps1"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" --menu %*

exit /b %ERRORLEVEL%
```

> **注意**: .bat は CRLF で保存すること（`.gitattributes` が自動変換するので通常は問題ない）

- [ ] **Step 2: 構文確認（Windows 環境で実行）**

```cmd
collect_snapshot.bat /?
```
期待: TUI メニューが表示される（または --menu が渡されてメニューを開こうとする）

- [ ] **Step 3: コミット**

```bash
git add tools/collect-snapshot/collect_snapshot.bat
git commit -m "feat(collect-snapshot): add collect_snapshot.bat launcher"
```

---

## Task 5: README.md + CHANGELOG

**Files:**
- 作成: `tools/collect-snapshot/README.md`
- 修正: `CHANGELOG.md`

- [ ] **Step 1: README.md を作成**

```markdown
# collect-snapshot

断面情報収集ラッパー。基盤テスト実施前に、サーバーの状態スナップショットを
1コマンドで収集して ZIP ファイルにまとめます。

```
tools/collect-snapshot/
├── CollectSnapshot.ps1      # Windows 本体（CUI + TUI）
├── collect_snapshot.sh      # Linux 本体（CUI + TUI）
├── collect_snapshot.bat     # Windows 起動バッチ（ダブルクリックで TUI）
└── README.md
```

## 収集ツール

| 順序 | ツール | 収集内容 |
|---|---|---|
| 1 | server-snapshot | OS・サービス・パッケージ・ネットワーク・環境変数 |
| 2 | port-inventory | 待受ポート（TCP/UDP）とプロセス対応 |
| 3 | aws-instance-audit | EC2 の IAM/SG/VPC 構成（EC2 環境のみ） |

## 前提

| 環境 | 必要なもの |
|---|---|
| Windows | PowerShell 5.1+、`Compress-Archive` |
| Linux | Bash 4+、`python3`、`zip` または `tar` |

## 使い方

### CUI モード（全自動）

```powershell
# Windows: 全ツール自動実行
.\CollectSnapshot.ps1

# ラベル付き
.\CollectSnapshot.ps1 -Label pre-upgrade

# 保存先指定
.\CollectSnapshot.ps1 -Label pre-upgrade -Output D:\snapshots
```

```bash
# Linux: 全ツール自動実行
bash collect_snapshot.sh

# ラベル付き
bash collect_snapshot.sh --label pre-upgrade

# 保存先指定
bash collect_snapshot.sh --label pre-upgrade --output /mnt/snapshots
```

### TUI モード（対話メニュー）

```powershell
# Windows
.\collect_snapshot.bat          # ダブルクリック起動
.\CollectSnapshot.ps1 --menu   # 明示指定
```

```bash
# Linux
bash collect_snapshot.sh --menu
```

## 出力

```
snapshots/
└── web01_pre-upgrade_20260616-143000.zip
    ├── server-snapshot/
    │   └── web01_20260616-143000.json
    ├── port-inventory/
    │   └── web01_20260616-143000.json
    ├── aws-instance-audit/
    │   └── web01_20260616-143000.json
    └── collect-snapshot.log
```

ZIP ファイル名: `<hostname>_<label>_<timestamp>.zip`（ラベルなし時: `<hostname>_<timestamp>.zip`）

## 終了コード

| Code | 意味 |
|---|---|
| 0 | 全ツール正常完了 |
| 1 | 1つ以上のツールが失敗、または ZIP 圧縮失敗 |
| 10 | 前提コマンド不足 |
```

- [ ] **Step 2: CHANGELOG.md の `[Unreleased]` セクションに追記**

`### Added` の下に追加:

```markdown
- `tools/collect-snapshot` — 断面情報収集ラッパー（server-snapshot / port-inventory / aws-instance-audit を一括実行し ZIP で保存）。CUI（全自動）と TUI（対話メニュー）に対応
```

- [ ] **Step 3: エンコーディング検証**

```bash
bash ci/template-check/check_template.sh
```
期待: violations=0（collect-snapshot は tools/ 配下なので lib 依存チェック対象外）

- [ ] **Step 4: コミット**

```bash
git add tools/collect-snapshot/README.md CHANGELOG.md
git commit -m "docs(collect-snapshot): add README and CHANGELOG entry"
```

---

## 自己レビューチェックリスト

| 仕様項目 | 対応タスク |
|---|---|
| server-snapshot + port-inventory + aws-instance-audit を順番に実行 | Task 2 run_all, Task 3 Invoke-AllTools |
| ラベル付き・なしのフォルダ名 | Task 2 SNAP_NAME, Task 3 Get-SnapName |
| 保存先デフォルト `./snapshots` | Task 2 OUTPUT_DIR, Task 3 Output param |
| ZIP 圧縮して元フォルダを削除 | Task 2 zip block, Task 3 Compress-Archive |
| 1 ツール失敗でも続行 | Task 2 `if run_tool ...`, Task 3 try/catch |
| 全失敗でも ZIP を作り exit 1 | Task 2 overall_exit, Task 3 overall |
| `--menu` フラグで TUI | Task 2 run_tui, Task 3 Invoke-TuiMenu |
| bat ダブルクリックで TUI | Task 4 |
| CUI は引数なしで全実行 | Task 2/3 デフォルト動作 |
| exit code 0/1/10 | Task 2/3 各 exit |
| bats テスト | Task 1 (7 ケース) |
| Pester テスト | Task 3 (3 ケース) |
| README | Task 5 |
| CHANGELOG | Task 5 |
