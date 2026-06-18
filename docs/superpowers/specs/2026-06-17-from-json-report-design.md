# 保存済み JSON からのレポート再生成（`-FromJson`）設計仕様書

**作成日**: 2026-06-17
**ステータス**: 承認済み

---

## 1. 概要

運用補助ツールが出力した JSON を後から読み込み、収集を再実行せずにレポート
（コンソールテーブル / JSON / HTML）を再生成する機能。

各ツールの「収集フェーズ」を「JSON 読み込み」に差し替えるだけで、出力ロジックは
既存実装を 100% 再利用する。判定結果（OK/NG/WARN）は JSON に保存済みの値を
そのまま使い、対象リスト（`.lst`）は不要とする。

**実装は Windows (PowerShell) 側のみ。** Linux (`.sh`) は対象外。

---

## 2. 対象ツール

| ツール | 対応 |
|---|---|
| `tools/cert-check/CertCheck.ps1` | `-FromJson` 追加 |
| `tools/port-inventory/PortInventory.ps1` | `-FromJson` 追加 |
| `tools/aws-instance-audit/Get-AwsInstanceAudit.ps1` | `-FromJson` 追加 |
| `*.sh`（Linux 全般） | 対象外（変更なし） |
| `*.bat` | usage コメント追記のみ（`%*` 透過で自動的に通る） |
| `tools/server-snapshot/ServerSnapshot.ps1` | 点検のみ（既存 `compare` でカバー済み） |
| `tools/perf-monitor/PerfMonitor.ps1` | 点検のみ（既存 `report <dir>` でカバー済み） |

「点検のみ」のツールは新規実装を行わず、ドキュメント整合の確認のみ行う。

---

## 3. インターフェース

```powershell
# cert-check
.\CertCheck.ps1     -FromJson saved.json [-HtmlReport out.html] [-Json] [-FailOnly]

# port-inventory
.\PortInventory.ps1 -FromJson saved.json [-HtmlReport out.html] [-Json] [-FailOnly]

# aws-instance-audit
.\Get-AwsInstanceAudit.ps1 -FromJson saved.json [-HtmlReport out.html]
```

bat 経由でも同じ（`%*` 透過）:

```bat
cert_check.bat -FromJson saved.json -HtmlReport out.html
```

### 引数の排他

- `-FromJson` 指定時は `-TargetList` / 収集系オプションを無視する（`-FromJson` 優先）
- `-FailOnly` と `-HtmlReport` / `-Json` は併用可

---

## 4. データフロー

```
通常:     [収集] → 内部表現 → [出力: console / json / html]
FromJson: [JSON 読込] → 内部表現に復元 → [出力: console / json / html]
                                          ↑ 後半は既存ロジックそのまま
```

### PowerShell 共通パターン

```powershell
# 1. param に追加
[string]$FromJson = '',

# 2. 収集フェーズの手前で分岐
if ($FromJson) {
    if (-not (Test-Path -LiteralPath $FromJson)) {
        Write-Error "FromJson file not found: $FromJson"
        exit 2
    }
    try {
        $raw = Get-Content -LiteralPath $FromJson -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Error "Failed to parse JSON: $FromJson"
        exit 1
    }
    # → 内部表現に復元（下記ツールごとの復元先）
} else {
    # 既存の収集ロジック
}

# 3. 出力分岐（既存ロジックをそのまま再利用）
if ($Json) { ... } elseif ($HtmlReport) { ... } else { console table }
```

### ツールごとの復元先

| ツール | JSON 構造 | 復元先 | 注意 |
|---|---|---|---|
| cert-check | 配列 `[{host,port,description,...,status,message}]` | `$displayResults` | JSON `description` → 内部 `desc` などフィールド名マッピング |
| port-inventory | 配列 `[{port,proto,...,status,description}]` | `$displayRows` | — |
| aws-instance-audit | オブジェクト `{meta:{...}, <categories>}` | `$result` | HTML レンダラへそのまま渡せる構造 |

---

## 5. エラーハンドリング

| 状況 | 動作 | 終了コード |
|---|---|---|
| ファイルが存在しない | エラーログ出力 | 2（リソース不在） |
| JSON パース失敗（壊れた JSON） | エラーログ出力 | 1（入力不正） |
| トップレベル構造が想定外（cert/port は配列、aws はオブジェクトを期待） | エラーログ出力 | 1 |
| 個別レコードのフィールド欠落 | 警告ログ + 欠損は空欄として描画継続 | 継続（0/1 は status 次第） |

- 細かいフィールド欠落で処理を止めず、スナップショットを可能な限り再現する
- 判定結果（OK/NG/WARN）が JSON にあれば、それに基づき従来どおり exit 0/1 を返す
  - cert-check / port-inventory: NG または WARN が 1 件でもあれば exit 1、それ以外 0
  - aws-instance-audit: 棚卸し（INFO）のため判定なし。読み込み成功なら exit 0

---

## 6. テスト方針

**Pester のみ**（PS 側だけの実装なので bats は不要）。

fixture は各ツールの実 `--json` 出力を 2〜3 レコードに切り詰めたものを
`tests/pester/fixtures/from-json/` に配置する。

各ツールにつき以下を検証する。

### 正常系

| テスト | 検証内容 |
|---|---|
| FromJson → `-Json` | 読んだ JSON を再出力し、主要フィールドが保たれる（ラウンドトリップ） |
| FromJson → `-HtmlReport out.html` | HTML ファイルが生成され、主要な値（ホスト名・status 等）を含む |
| FromJson → `-FailOnly` | NG/WARN のみに絞られる（cert-check / port-inventory のみ） |

### 異常系

| テスト | 検証内容 |
|---|---|
| 存在しないファイル | exit 2 |
| 壊れた JSON | exit 1 |

---

## 7. ドキュメント

- 各ツールの `README.md` に `-FromJson` の使用例を追記
- 各 `.bat` の usage コメントに `-FromJson` を追記
- `CHANGELOG.md` の `[Unreleased]` に追記

### CHANGELOG 追記内容（案）

```markdown
### Added
- `cert-check` / `port-inventory` / `aws-instance-audit` に `-FromJson` を追加。
  保存済み JSON を読み込み、収集を再実行せずにレポート（コンソール / JSON / HTML）を
  再生成できる（Windows / PowerShell のみ）
```
