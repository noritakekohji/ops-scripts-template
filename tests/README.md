# tests/

ops-scripts-template リポジトリの自動テスト一式。

```
tests/
├── README.md
├── run_unit.sh / run_unit.ps1     # 単体テストランナー（bats / Pester）
├── run_all.sh  / run_all.ps1      # 単体 + 結合 を 1 コマンドで
├── bats/                          # Bash 単体テスト (bats-core)
├── pester/                        # PowerShell 単体テスト (Pester 5+)
├── fixtures/                      # テスト用 JSON / 入力データ
├── docker/                        # Docker コンテナでの E2E テスト
└── results/                       # 実行結果（gitignore 対象）
```

---

## クイックスタート

### Linux / Bash 側

```bash
# 単体テストだけ
bash tests/run_unit.sh

# 単体 + 結合 (rotate_log の tmpdir / perf-monitor の短時間 start/stop など)
bash tests/run_all.sh

# 特定のテストだけ
bash tests/run_unit.sh tests/bats/tomcatctl.bats

# kcov でカバレッジ HTML を生成（要 kcov インストール）
bash tests/run_unit.sh --coverage
# → tests/results/coverage/bash/index.html
```

### Windows / PowerShell 側

```powershell
# 単体テスト
.\tests\run_unit.ps1

# 単体 + 結合
.\tests\run_all.ps1

# 特定のテストだけ（ファイル名フィルタ）
.\tests\run_unit.ps1 -Path Logging

# カバレッジ (JaCoCo XML)
.\tests\run_unit.ps1 -Coverage
# → tests/results/coverage/powershell/coverage.xml
# HTML 化したい場合は reportgenerator など別ツールで XML を変換してください。
```

---

## 何がテストされているか

### 単体テスト（mock 駆動、ローカルで素早く完結）

| 対象 | Bats | Pester |
|---|---|---|
| `lib/logging.{sh,psm1}` | `logging.bats` | `Logging.Tests.ps1` |
| `lib/config.{sh,psm1}` | `config.bats` | `Config.Tests.ps1` |
| TomcatCtl | `tomcatctl.bats` (full) | `TomcatCtl.Tests.ps1` (full) |
| NginxCtl | `nginxctl.bats` | `NginxCtl.Tests.ps1` |
| MySQLCtl | `mysqlctl.bats` | `MySQLCtl.Tests.ps1` |
| PostgreSQLCtl | `postgresqlctl.bats` | `PostgreSQLCtl.Tests.ps1` |
| SqlServerCtl | `sqlserverctl.bats` | `SqlServerCtl.Tests.ps1` |
| SAPCtl | `sapctl.bats` | `SAPCtl.Tests.ps1` |
| HANACtl | `hanactl.bats` | (Windows 版なし) |
| AWS 系 | `aws_scripts.bats` | `Aws-Scripts.Tests.ps1` |
| Get-ServerInfo | `get_server_info.bats` (smoke) | `Get-ServerInfo.Tests.ps1` (smoke) |
| ServerSnapshot | `server_snapshot.bats` | `ServerSnapshot.Tests.ps1` |

カバー観点:

- 不正アクション / 引数欠落 / 値範囲外 → 期待する終了コード
- 前提コマンド不在（`systemctl` / `aws` 等）→ 期待する終了コード
- サービス不在 → 規約通りの exit code
- 冪等スキップ（start when active / stop when inactive）
- restart は常に実行（冪等スキップなし）
- status は read-only（Start/Stop/Restart を呼ばない）
- `-w` / `-t` 経由で待機 + タイムアウト指定が伝播
- `.conf` ファイルからの値補完（SID, InstanceNumber, Wait, WaitTimeoutSec 等）

### 結合テスト（実コマンドを走らせる、ローカルで完結）

`tests/bats/` と `tests/pester/` 内のテストの一部が結合テストを兼ねています。
すべて **sudo 不要・外部ネットワーク不要** で動きます。

| ツール | 何を実機で動かすか |
|---|---|
| rotate_log | tmpdir に 2MB のダミーログを作って rotate / retention / gzip を検証 |
| perf-monitor | `start -i 1 -d 3` で 3 秒間 collector を実プロセスとして走らせ、`data.jsonl` が書かれて report HTML が生成されるまで |
| network-check | `127.0.0.1` を ping / TCP（CI で ICMP がブロックされる場合は exit 1 も許容） |
| server-snapshot | `tests/fixtures/server_info_{before,after}.json` を渡して比較。HTML レポートの中身まで確認 |

---

## モック機構

### Bash (`tests/bats/test_helper.bash`)

```bash
load test_helper
setup() {
    setup_mock_bin                     # PATH の先頭にモック用 bin を置く
    make_mock systemctl 0              # systemctl を成功させる
    make_mock_script aws 'echo ok'     # 任意のスクリプトを差し込む
}
teardown() { teardown_mock_bin; }

@test "..." {
    run bash my_script.sh ...
    [ "$status" -eq 0 ]
    mock_called systemctl
    [ "$(mock_call_count systemctl)" -eq 2 ]
    [[ "$(mock_call_args systemctl 1)" == "start nginx" ]]
}
```

### PowerShell (`tests/pester/TestHelpers.psm1`)

```powershell
# 制御スクリプトを子 powershell.exe で実行（StrictMode / グローバル状態の漏出防止）
$r = Invoke-Controller -ScriptPath $ctl -Arguments @('status', 'svc')
$r.ExitCode | Should -Be 0

# Get-Service / Start-Service / Stop-Service / Restart-Service をモック化
$r = Invoke-ControllerWithServiceMock -ScriptPath $ctl -Arguments @('start', 'svc') -InitialStatus 'Running'
$r.Combined | Should -Match 'Skipped'
($r.Calls | Where-Object { $_ -match 'Start-Service' }).Count | Should -Be 0
```

---

## 前提ソフトウェア

| 種別 | 必要なもの | インストール例 |
|---|---|---|
| Bash 単体テスト | `bats` (>= 1.5) | `apt-get install bats` / `brew install bats-core` |
| Bash カバレッジ | `kcov` | `apt-get install kcov` |
| Bash 結合テスト | `python3`, `iputils-ping` | （多くの環境で標準） |
| PowerShell 単体 | Pester 5+ | `Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force` |
| PowerShell 結合 | PowerShell 5.1+ | （Windows 既定） |

---

## CI との関係

`ci/test/bats.gitlab-ci.yml` / `ci/test/pester.gitlab-ci.yml` が
それぞれ `bats` / `Invoke-Pester` を呼び出して JUnit XML をアーティファクトに残します。

CI 変数 `RUN_COVERAGE=true` を渡すと、Bash 側は `tests/run_unit.sh --coverage` 経由で
kcov を使ったカバレッジ計測に切り替わります。Pester 側も同じ変数で JaCoCo XML を生成します。

詳細は [`tests/docker/README.md`](docker/README.md)（Docker 経由の E2E テスト手順）も参照。

---

## 新しいスクリプトを追加したときの作業

1. 対応する単体テストを bats / Pester の両方に追加（命名は `<name>.bats` / `<Name>.Tests.ps1`）
2. 関連 fixture は `tests/fixtures/` に置く
3. テンプレ準拠を `bash ci/template-check/check_template.sh` で確認
4. ローカルで `bash tests/run_all.sh` と `.\tests\run_all.ps1` を緑にする
