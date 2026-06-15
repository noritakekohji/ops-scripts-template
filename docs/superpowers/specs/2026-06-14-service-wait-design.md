# service-wait 設計仕様書

- 日付: 2026-06-14（初版） / 2026-06-15（v2 監視パラメータ移行） /
  2026-06-15（v3 ローカル service / process チェック追加） /
  **2026-06-15（改訂 v3.1: 行レベルオーバーライドを廃止）**
- ステータス: v3 実装済み、v3.1 仕様確定・実装未着手
- 配置ドメイン: `scripts_*/os/`

## 改訂サマリ (v2, 2026-06-15)

「設定ファイルはスクリプトの設定、監視用ファイルは監視タイミングごとの設定」という
責任分割に合わせて、`initial_wait_sec` / `interval_sec` / `success_threshold` /
`timeout_sec` / `per_check_timeout_sec` の 5 項目を **conf から lst のヘッダに移動** する。

- `service_wait.conf` は **ロギング設定のみ** (`LogFile`, `LogLevel`) を保持
- `.lst` ファイル先頭に `key = value` 形式で監視パラメータを記述（全項目オプション）
- lst ヘッダで未指定の項目は **スクリプトのハードコード既定値** にフォールバック
  （conf には監視パラメータの既定値を持たない）
- 行レベルの `per_check_timeout_sec=N` オーバーライドは v1 と同じく継続サポート

詳細は §4 / §5 / §6 を参照。

## 改訂サマリ (v3, 2026-06-15)

**ローカルノード限定** で `service` と `process` の 2 タイプを追加する。
他ノードへの SSH/WinRM 委譲は v3 でも対象外。

- `type=service`
  - Linux: `systemctl is-active <name>` が `active` を返したら OK
  - Windows: `Get-Service -Name <name>` の `Status` が `Running` なら OK
- `type=process`
  - Linux: `pgrep -x <name>` が 1 件以上ヒットしたら OK（実行ファイル名の完全一致）
  - Windows: `Get-Process -Name <name>` が 1 件以上返ったら OK（`.exe` 抜き、完全一致）
- service / process 名は OS 依存。**OS ごとに別 .lst を使う前提** で、同じ lst を
  別 OS 間で共有することは想定しない
- 前提コマンド: Linux `service` → `systemctl`、Linux `process` → `pgrep`。
  不足時は exit 10（既存規約どおり）
- ターゲット書式: ping/tcp/http と同じ CSV 行。service/process では target に
  service 名・プロセス名を入れる。カンマと先頭末尾空白は不可

詳細は §5 / §6 を参照。

## 1. 目的とスコープ

デプロイ・サービス再起動後の **ヘルスチェック待ち** を行う運用スクリプト。
指定したターゲット群が「連続 N ラウンドすべて応答 OK」になるまで定期的に確認し、
タイムアウト前に達成すれば正常終了、達成できなければタイムアウトエラーで終了する。

CI/CD・運用手順内で「次の手順に進んでよい」判定や、フェイルオーバー後の疎通確認に組み込む用途を想定。

### スコープ内

- Ping（ICMP 応答）チェック
- TCP ポート Listen チェック
- HTTP/HTTPS ステータスコードチェック（2xx を OK とみなす）
- ローカル / リモート問わず、ネットワーク到達可能なターゲット
- **ローカルノードの OS サービス状態（systemctl / Get-Service）チェック**（v3）
- **ローカルノードのプロセス存在チェック**（v3）
- 単一プロセスでの定期ポーリングと連続成功判定

### スコープ外

- SSH/WinRM 経由でのリモートノード OS / サービス / プロセス操作
- 早期失敗（fail_threshold）機構
- JSON / HTML レポート出力

## 2. 配置

OS-first レイアウトに準拠し、Linux / Windows の対称配置を維持する。

```
scripts_linux/os/service_wait.sh         # Bash, UTF-8 LF, BOMなし
scripts_windows/os/ServiceWait.ps1       # PowerShell 5.1, UTF-8 BOM
scripts_windows/os/service_wait.bat      # 起動ラッパ, CRLF
config/default/service_wait.conf         # 既定設定
docs_linux/os/service_wait.md            # Linux 仕様書
docs_windows/os/ServiceWait.md           # Windows 仕様書
tests/bats/service_wait.bats             # Linux ユニットテスト
tests/pester/ServiceWait.Tests.ps1       # Windows ユニットテスト
```

## 3. 起動方法

ターゲットリストファイルは必須引数。

```bash
scripts_linux/os/service_wait.sh path/to/targets.lst
```

```powershell
scripts_windows/os/ServiceWait.ps1 -TargetList path\to\targets.lst
```

設定は環境変数 `OPS_ENV` で切り替え（既定: `default`）。

## 4. 設定ファイル `service_wait.conf`（v2）

スクリプト単位の設定のみを保持する。`config/<env>/service_wait.conf` →
`config/default/service_wait.conf` の順で解決。default と env のマージは行わない
（CLAUDE.md の優先順位規約に準拠）。

```ini
# ログファイル出力先（空ならコンソールのみ）
LogFile  =
# ログレベル DEBUG/INFO/WARN/ERROR
LogLevel = INFO
```

監視パラメータ（`initial_wait_sec` 等）は conf には**置かない**。配置場所は `.lst`
ヘッダ（§5.1）。conf にこれらのキーを書いた場合は **WARN を出して無視** する
（誤って v1 形式を残しても挙動が壊れないよう defensive）。

## 5. ターゲットリスト仕様（v2）

CSV 風形式。リポジトリの他ツール（network-check / cert-check / port-inventory）の
`.lst` 慣習に揃えつつ、**先頭にヘッダブロック**を持つ点が他ツールとの違い。

### 5.1 ヘッダ（監視パラメータ）

ファイル先頭にデータ行（カンマを含む CSV 行）が出現する **前** までの間、
`key = value` 形式の行を任意の順序・任意の個数で記述できる。すべて省略可能。

```
# 監視パラメータ（全項目オプション）
initial_wait_sec      = 10
interval_sec          = 5
success_threshold     = 3
timeout_sec           = 600
per_check_timeout_sec = 5

# ---- Web tier ----
http, https://api/health, API
tcp,  10.0.0.1:8080,      Tomcat
```

| キー | 既定値 | 意味 |
|---|---|---|
| `initial_wait_sec` | 0 | 起動後の初期待機（秒） |
| `interval_sec` | 5 | ラウンド間隔（秒） |
| `success_threshold` | 3 | 連続成功ラウンド数 |
| `timeout_sec` | 600 | 全体タイムアウト（秒） |
| `per_check_timeout_sec` | 5 | 個別チェックタイムアウト（秒、行レベルでさらにオーバーライド可） |

- フォーマット: `key = value`（前後空白は無視、`#` から行末はコメント）
- 値は非負整数のみ受け付ける。それ以外は exit 2
- 未知のキーは exit 2（誤記の早期検知）
- 同じキーが複数回現れた場合は **後勝ち** + WARN ログ
- ヘッダブロックの終わりは「最初のターゲット行（type で始まりカンマを含む）」を検出した時点
  （以後はヘッダ行を受け付けず、`key=value` 行が現れたら exit 2）

### 5.2 ターゲット行（v1 と同一）

```
# type, target, description
ping,    10.0.0.1,                node-A
ping,    10.0.0.2,                node-B
tcp,     10.0.0.1:8080,           Tomcat
http,    https://api/health,      API
service, httpd,                   Apache HTTP Server (v3)
process, java,                    JVM process (v3)
```

- `#` 始まりの行・空行はスキップ
- フィールド区切り: カンマ + 任意の空白
- セクション区切りコメント `# ---- Section ----` も他ツールと同じく許容

### 5.3 必須フィールド

| 列 | 内容 | 制約 |
|---|---|---|
| type | `ping` / `tcp` / `http` / `service` / `process` | 上記 5 つ以外は exit 2 |
| target | チェック対象 | type ごとの形式: ping は host、tcp は host:port、http は URL、service / process は名前（空白・カンマ不可） |
| description | 説明 | 自由テキスト。ログ表示用 |

### 5.4 行レベルオーバーライド（v3.1 で廃止）

v1〜v3 では 4 列目以降に `per_check_timeout_sec=N` を書けたが、v3.1 で削除。
**行は厳密に 3 列**。4 列目以降に文字が入った行は `reason=extra_columns` で exit 2。

タイミング設定はファイル単位で完結させ、ターゲットごとに別の挙動を必要とする
ケースは別 `.lst` を作って分離する設計とする。

### 5.5 判定基準

| type | OK の条件 |
|---|---|
| ping    | ICMP echo 応答が 1 回返ること |
| tcp     | TCP connect が成功すること |
| http    | HTTP ステータスコードが 2xx であること |
| service | ローカル OS で対象サービスが起動中（Linux=`active`, Windows=`Running`）（v3） |
| process | ローカル OS で対象実行ファイル名のプロセスが 1 件以上存在すること（v3） |

`expected` 列は持たない。すべて「OK 判定」固定。
service / process はローカルノードでしか確認できないため、別ノードを含むリストで
混在させる場合は実行ノード上で OK が出るかどうかを利用者が把握する必要がある。

### 5.6 値の解決順位

```
1. .lst ヘッダの key = value
2. スクリプトのハードコード既定値（§5.1 表の「既定値」列）
```

`service_wait.conf` には監視パラメータの既定値を持たないため、解決順位から除外。
v3.1 で行レベルオーバーライドも廃止したため、すべての監視パラメータは
ファイル単位（lst ヘッダ）で確定する。

## 6. 動作フロー（5-phase 構造）

```
Phase 1: ヘッダ・シバン
  - #!/usr/bin/env bash + set -euo pipefail (Linux)
  - #Requires -Version 5.1 + StrictMode + ErrorAction Stop (Windows)

Phase 2: 引数・設定読み込み
  - ターゲットリストファイル引数を受領
  - 共通 lib (logging.sh / Logging.psm1) ロード
  - config 解決: $OPS_CONFIG_DIR → config/<env>/service_wait.conf
                 → config/default/service_wait.conf
    （v2: 監視パラメータキーが残っていれば WARN、ログ系のみ採用）
  - ターゲットリストのパース
      a. ヘッダブロック: 最初のターゲット行が出るまで key=value をスキャン
         監視パラメータ 5 項目を内部状態に格納（未指定はハードコード既定値）
      b. ターゲット行: type/target/desc + 行レベルオーバーライドを内部配列に格納

Phase 3: 事前検査
  - リストファイルの存在・読み取り可能性
  - ヘッダ各キーの値バリデーション（非負整数、未知キーは exit 2）
  - 各行の type / target 形式バリデーション
  - 各行の key=value バリデーション（未知キーで exit 2）
  - 前提コマンド存在確認:
      ping    → ping (Linux) / Test-Connection (Windows)
      http    → curl (Linux) / Invoke-WebRequest (Windows)
      tcp     → 標準機能で対応（追加コマンド不要）
      service → systemctl (Linux) / Get-Service (Windows; PS5.1 同梱) (v3)
      process → pgrep (Linux) / Get-Process (Windows; PS5.1 同梱) (v3)
  - 不足時は exit 10

Phase 4: 本処理
  sleep $initial_wait_sec
  start    = now
  deadline = now + timeout_sec
  consecutive = 0
  round    = 0
  while now < deadline:
      round++
      round_ok = true
      foreach target in targets:
          to = target.per_check_timeout_sec or default.per_check_timeout_sec
          result = check(target.type, target.target, to)
          log INFO "[ROUND $round] $type $target -> $result (desc=$desc)"
          if not result: round_ok = false
      if round_ok:
          consecutive++
      else:
          consecutive = 0
      log INFO "[ROUND $round] $(PASS|FAIL) consec=$consecutive/$success_threshold"
      if consecutive >= success_threshold:
          exit 0
      sleep $interval_sec
  exit 3  # timeout

Phase 5: 後始末・結果出力
  - trap (Bash) / try-finally (PowerShell) で最終 RESULT 行を必ず出力
  - "[RESULT] status=success|timeout rounds=$round elapsed=${elapsed}s consec=$consecutive"
```

### 6.1 判定実装の選択

| type | Linux 実装 | Windows 実装 |
|---|---|---|
| ping    | `ping -c1 -W <timeout> <host>` (Linux ping は `-W` 秒) | `Test-Connection -Count 1 -TimeoutSeconds <timeout> -Quiet` |
| tcp     | `bash -c 'exec 3<>/dev/tcp/<host>/<port>'` をタイムアウト付きで実行 | `[System.Net.Sockets.TcpClient]::ConnectAsync` + `Wait(<timeout>ms)` |
| http    | `curl -sS -o /dev/null -w '%{http_code}' --max-time <timeout> <url>` で 2xx 判定 | `Invoke-WebRequest -UseBasicParsing -TimeoutSec <timeout> -UseDefaultCredentials:$false` で StatusCode 判定 |
| service | `timeout <to> systemctl is-active --quiet <name>` の exit 0 を OK | `(Get-Service -Name <name> -ErrorAction SilentlyContinue).Status -eq 'Running'` |
| process | `timeout <to> pgrep -x <name> >/dev/null` の exit 0 を OK | `@(Get-Process -Name <name> -ErrorAction SilentlyContinue).Count -ge 1` |

ICMP は OS により権限・実装差があるため、PowerShell 5.1 で `Test-Connection -TimeoutSeconds`
が使えない環境では `.NET Ping` クラス（`System.Net.NetworkInformation.Ping`）にフォールバック。

service / process は実行ノードのローカル OS にしか問い合わせない。リモート対象を
書いても OK にはならない（NG として通常のラウンドロジックに乗る）。
target 文字列は前後空白除去後そのまま `systemctl` / `pgrep` / `Get-Service` /
`Get-Process` の引数として渡す。シェルメタ文字を含む値はパース時に拒否
（`reason=bad_service_name` / `reason=bad_process_name` で exit 2）。

## 7. 出力仕様

### 7.1 ログ

- 共通 lib (`logging.sh` / `Logging.psm1`) 経由のみ使用
- フォーマット: `[YYYY-MM-DD hh:mm:ss JST] [Level] (service_wait:pid) Message`
- 1 イベント 1 行
- 構造化情報は `key=value` をスペース区切りでメッセージに埋め込む

### 7.2 標準的なログ列

```
[2026-06-14 10:00:00 JST] [INFO]  (service_wait:1234) start targets=5 timeout=600 success=3
[2026-06-14 10:00:00 JST] [INFO]  (service_wait:1234) [ROUND 1] ping 10.0.0.1 -> OK (desc=node-A)
[2026-06-14 10:00:00 JST] [WARN]  (service_wait:1234) [ROUND 1] http https://api/health -> NG status=503 (desc=API)
[2026-06-14 10:00:00 JST] [INFO]  (service_wait:1234) [ROUND 1] FAIL consec=0/3
[2026-06-14 10:00:30 JST] [INFO]  (service_wait:1234) [ROUND 7] PASS consec=3/3
[2026-06-14 10:00:30 JST] [INFO]  (service_wait:1234) [RESULT] status=success rounds=7 elapsed=30s consec=3
```

### 7.3 JSON / HTML

出力しない（スコープ外）。

## 8. 終了コード

| Code | 意味 |
|---|---|
| 0  | 連続成功達成（正常終了） |
| 1  | 引数不正・usage |
| 2  | ターゲットリストの形式エラー（type 不正・未知 key=value 等） |
| 3  | タイムアウト失敗 |
| 10 | 前提コマンド不足（ping / curl 等） |

リポジトリの終了コード規約に準拠。`4` (制御失敗) と `20` (一時障害) は本ツールでは使用しない。

## 9. エンコーディング・改行

- `service_wait.sh`: UTF-8 BOM なし + LF
- `ServiceWait.ps1`: UTF-8 BOM 付き
- `service_wait.bat`: CRLF
- `service_wait.conf`: LF 統一

`.gitattributes` の既存設定により自動強制される。

## 10. テスト方針

### 10.1 ユニット（bats / Pester）

- リストパーサ
    - 正常行
    - コメント・空行スキップ
    - 不正 type で exit 2
    - 未知 key=value で exit 2
    - per_check_timeout_sec オーバーライドの反映
- 各 type のチェック関数（モック）
    - ping: 成功 / 失敗
    - tcp: 接続成功 / refused / timeout
    - http: 200 / 500 / connection error
- ラウンド判定ロジック
    - success_threshold 連続成功 → exit 0
    - 途中失敗で consecutive リセット
    - timeout_sec 超過 → exit 3
    - initial_wait_sec が守られる（短い値でテスト）

### 10.2 結合

- 短い timeout で `127.0.0.1:22` 等の常時 Listen ポートを相手に E2E 動作確認
- 存在しないターゲットでタイムアウト exit 3 を確認

### 10.3 Docker

`tests/docker/` の既存パターンに従い、Linux / Windows コンテナで bats / Pester を実行。

## 11. CI / テンプレ準拠

- `ci/template-check/check_template.sh` に通すこと
- 5-phase 構造のヘッダコメント必須
- PS5.1 互換禁止構文（`??`, `?:`, `?.`, `utf8NoBOM` 等）は使用しない
- `Start-Job` ではなく必要に応じ `Start-Process`

## 12. 受入条件（v3）

1. `scripts_linux/os/service_wait.sh targets.lst` でリスト全行 OK になるまで待ち exit 0
2. すべてのターゲットが応答しないリストでヘッダ `timeout_sec = 10` を指定し exit 3
3. 不正な type を含むリストで exit 2
4. ping コマンドを `PATH` から外して実行し exit 10
5. `per_check_timeout_sec=30` をリスト行に書いた場合、その行のみ 30 秒タイムアウトで動作
6. lst ヘッダに監視パラメータを書かなくてもハードコード既定値で動作（5/3/600/0/5）
7. 同じ lst を別の引数で渡すと、それぞれのヘッダで挙動が独立に切り替わる
8. conf に `interval_sec = ...` 等が残っていても WARN を出して無視され、起動はする
9. Linux / Windows 両方でログフォーマットが規約どおり
10. (v3) Linux で `service, sshd, ssh daemon` を持つ lst が systemd 環境で OK になる
11. (v3) Linux で `process, bash, login shell` を持つ lst が bash プロセスを検出して OK
12. (v3) Windows で `service, BITS, Background Intelligent Transfer Service` が
    BITS Running 時に OK になる
13. (v3) Windows で `process, powershell, current shell` が PowerShell プロセスを検出して OK
14. (v3) 存在しない service/process 名を渡したリストはタイムアウトで exit 3
15. (v3) `pgrep` を PATH から外した状態で process 行を含む lst を実行 → exit 10
16. (v3) target に空白やカンマを含む service / process 名は exit 2
17. bats / Pester テストがローカル・Docker・CI で通る
18. `ci/template-check` を通る
