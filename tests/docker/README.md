# Docker-based Tool Tests

Docker コンテナ（Ubuntu 22.04）を使って bash ツールを実機相当の Linux 環境でテストします。

## 前提

- Docker Desktop が **Linux コンテナモード** で起動していること
- インターネット接続があること（DNS・TCP チェックで使用）

## 実行方法

```bash
cd tests/docker

# 初回（イメージビルド + テスト実行）
bash run_tests.sh

# イメージ強制再ビルド
bash run_tests.sh --build

# イメージ再ビルドなし（高速）
bash run_tests.sh --no-build

# コンテナ内のシェルに入る（デバッグ用）
bash run_tests.sh --shell
```

## テスト内容

```
=== Prerequisites ===
  python3, ping, ip, df, lsblk の存在確認

=== get_server_info.sh ===
  os + network + filesystem カテゴリの収集
  JSON 構造の検証（meta, os, network, filesystem）
  全カテゴリの収集（services, packages, environment）

=== check_network_connectivity.sh ===
  Python エラーなし（スクリプト動作確認）
  HTML レポート生成確認
  DNS 解決（google.com）
  TCP 疎通（google.com:443 OK）
  TCP 疎通（google.com:22 NG）

=== change_detect.sh ===
  before スナップショット取得
  after  スナップショット取得
  compare モードで差分レポート生成
  HTML レポート生成確認
  変化なし（0 changes）の検証
```

## コンテナ内の環境

| ツール | バージョン |
|---|---|
| OS | Ubuntu 22.04 |
| bash | 5.x |
| python3 | 3.10 |
| ping | iputils-ping |
| ip | iproute2 |

## Ping について

`--cap-add=NET_RAW` を付けて実行するため ICMP ping が使えます。  
Ping が NG になる場合は Docker のネットワーク設定を確認してください。

## デバッグ

```bash
# コンテナ内シェルに入る
bash run_tests.sh --shell

# コンテナ内でテスト手動実行
bash /ops/tests/container_tests.sh

# ツールを直接実行
bash /ops/tools/server-compare/get_server_info.sh
bash /ops/tools/network-check/check_network_connectivity.sh -l /ops/tests/test_targets.lst
```

## テスト結果例

```
=== Prerequisites ===
[PASS] python3 available
[PASS] ping available
[PASS] ip available
[PASS] df available
[PASS] lsblk available

=== get_server_info.sh ===
[PASS] os,network,filesystem collection
[PASS] JSON meta.hostname present
[PASS] JSON os category collected
[PASS] JSON os.architecture present
[PASS] JSON network collected
[PASS] JSON filesystem collected
[PASS] all categories collection
[PASS] all: services collected
[PASS] all: packages collected
[PASS] all: environment collected

=== check_network_connectivity.sh ===
[PASS] script runs without Python errors
[PASS] HTML report created
[PASS] HTML contains google.com
[PASS] DNS: google.com resolves
[PASS] TCP: google.com:443 reachable
[PASS] TCP: google.com:22 not reachable (SSH blocked)

=== change_detect.sh ===
[PASS] before snapshot
[PASS] before JSON created
[PASS] after snapshot + comparison
[PASS] after JSON created
[PASS] HTML report from compare
[PASS] HTML report created
[PASS] HTML content valid
[PASS] 0 changes (no change between snapshots)

──────────────────────────────────────────────────────────
  ALL TESTS PASSED
  Total: 23   PASS: 23   FAIL: 0
```
