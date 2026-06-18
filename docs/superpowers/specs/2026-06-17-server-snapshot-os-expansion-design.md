# server-snapshot OS 情報拡充 設計仕様書

**作成日**: 2026-06-17 / **ステータス**: 承認済み

## 1. 概要

`tools/server-snapshot` の収集対象を拡充し、基盤テスト実施前後の環境断面をより広く・
性能テストの再現性に効く粒度で押さえられるようにする。新カテゴリを3つ追加し
（`patches` / `tuning` / `scheduled`）、既存の `os` / `network` / `filesystem` /
`security` にフィールドを追加する。Windows (PowerShell / CIM) と Linux (python3) の
両方に同等のカテゴリを実装する。

本仕様はテーマA（OS 情報拡充）のみを対象とする。テーマB（ミドルウェア設定のアドイン化、
および java / python / .NET / openssl 等の言語ランタイム・実行ファイルのバージョン収集）は
別スペックとする。

## 2. カテゴリ構成

収集カテゴリは 8 → 11 に増える。

```
os / network / services / packages / users / filesystem / environment / security
  + patches / tuning / scheduled
```

| カテゴリ | 区分 | 内容 |
|---|---|---|
| patches | 新設 | 適用済みパッチ / 更新の一覧 |
| tuning | 新設 | カーネル / システムパラメータ・リソース上限・性能関連設定 |
| scheduled | 新設 | 起動時実行・スケジュールタスク |
| os | 拡張 | HW / 仮想化・ロケール / コードページ詳細・再起動保留フラグを追加 |
| network | 拡張 | プロキシ設定・時刻同期（設定 + 状態）を追加 |
| filesystem | 拡張 | マウントオプションを追加 |
| security | 拡張 | AppArmor 状態（Linux）・UAC 状態（Windows）を追加 |

既存フィールドはすべて維持する（破壊的変更なし。各カテゴリは追加のみ）。

## 3. 各カテゴリの収集項目と収集元

「両OS 1:1 対応」はカテゴリ名と JSON トップ構造を揃える意味であり、中身の項目は
OS 固有でよい（特に `tuning`）。OS に存在しない項目はキーごと省略する（空文字で埋めない）。

### 3.1 patches（新設）

適用済み OS パッチ / 更新の識別情報を一覧化する。パッケージマネージャは存在検出で
自動判定（rpm / dpkg / zypper）。取得不可なら空配列 + warn ログで継続。

| OS | 収集元 | 出力フィールド |
|---|---|---|
| Windows | `Get-HotFix`。ブロック時 `Get-CimInstance Win32_QuickFixEngineering`、不可なら `wmic qfe list` | `id`(KB番号), `description`, `installed_on` |
| Linux (rpm系) | `rpm -qa --last`。dnf があれば `dnf history list` で補助 | `name`, `version`, `installed_on` |
| Linux (deb系) | `/var/log/apt/history.log` をパース（無ければ `dpkg-query -W` + `/var/log/dpkg.log`） | `name`, `version`, `installed_on` |

### 3.2 tuning（新設）

性能・リソースに関わる設定。OS で項目が異なる。取得不可な項目は省略 or 空 + warn で継続。

**Linux:**

| 項目 | 収集元 | 出力 |
|---|---|---|
| sysctl 主要値 | `sysctl` のホワイトリスト（`net.core.*`, `net.ipv4.tcp_*`, `vm.swappiness`, `vm.dirty_*`, `kernel.shmmax`, `kernel.sem`, `fs.file-max`, `fs.nr_open`） | `sysctl`: key=value dict |
| リソース上限 | `ulimit -a` 相当 + `/etc/security/limits.conf`・`limits.d/*` | `limits`: nofile/nproc/stack 等 |
| CPU ガバナー | `/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor` | `cpu_governor`（同一なら単一値、混在なら一覧） |
| THP | `/sys/kernel/mm/transparent_hugepage/{enabled,defrag}` | `thp_enabled`, `thp_defrag` |
| CPU 脆弱性緩和 | `/sys/devices/system/cpu/vulnerabilities/*` | `cpu_mitigations`: 脆弱性名→状態 dict |

**Windows:**

| 項目 | 収集元 | 出力 |
|---|---|---|
| ページファイル | `Win32_PageFileSetting` / `Win32_PageFileUsage` | `pagefile`: path/initial_mb/maximum_mb/auto_managed |
| 主要 TCP/IP レジストリ | `HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters`（`TcpTimedWaitDelay`・`MaxUserPort` 等） | `registry`: key=value dict |
| 電源プラン | `powercfg /getactivescheme` | `power_scheme` |

THP・CPU ガバナー・CPU 脆弱性緩和は Linux のみ。電源プランは Windows のみ
（Linux の CPU ガバナーが概念上の対応）。

### 3.3 scheduled（新設）

| OS | 収集元 | 出力 |
|---|---|---|
| Windows | `Get-ScheduledTask`（Ready/Running）+ スタートアップ（`HKLM`/`HKCU` の `Run`・スタートアップフォルダ）。ブロック時 `schtasks /query /fo csv` | `scheduled_tasks`(name,path,state), `startup`(name,command,scope) |
| Linux | cron（`/etc/crontab`, `/etc/cron.d/*`, `/var/spool/cron/*`, `/etc/cron.{hourly,daily,weekly,monthly}`）+ `systemctl list-timers --all` | `cron`(source,entry), `systemd_timers`(unit,next,last) |

### 3.4 os 拡張

既存フィールド（hostname, os_name/version/build, architecture, timezone, locale,
install_date, last_boot, cpu_*, memory_* 等）に以下を追加する。

| 項目 | Windows | Linux |
|---|---|---|
| HW / 仮想化 | `Win32_ComputerSystem`(Manufacturer,Model) + `Win32_BIOS`(SMBIOSBIOSVersion,ReleaseDate,SerialNumber) + 仮想化判定 | `/sys/class/dmi/id/{sys_vendor,product_name,bios_version,bios_date}` + `systemd-detect-virt` |
| ロケール / コードページ | `Get-WinSystemLocale`, `Get-Culture`, `chcp`（例: CP932）, `Get-WinUserLanguageList` | `locale`（LANG, LC_*）, `/etc/locale.conf` |
| 再起動保留 | レジストリ3箇所（CBS\RebootPending, WindowsUpdate\Auto Update\RebootRequired, Session Manager\PendingFileRenameOperations） | `/var/run/reboot-required` + `needs-restarting -r`（dnf-utils。無ければ skip） |

出力例: `hardware`(manufacturer,model,bios_version,bios_date,serial,virtualization)、
`locale_detail`(system_locale,code_page,languages)、`reboot_pending`(pending:bool, reasons:[...])。

### 3.5 network 拡張

既存（interfaces, routes, dns_servers, hosts）に以下を追加する。

| 項目 | Windows | Linux |
|---|---|---|
| プロキシ | `netsh winhttp show proxy` + WinINET レジストリ（`Internet Settings` の ProxyEnable/ProxyServer） | 環境変数 `http_proxy`/`https_proxy`/`no_proxy` + `/etc/environment` + `/etc/profile.d/*proxy*` |
| 時刻同期（設定） | `w32tm /query /peers`（同期元ピア） | `chronyc sources` / `ntpq -p` + `timedatectl`（NTP有効/同期済み） |
| 時刻同期（状態） | `w32tm /query /status`（最終同期・ドリフト） | `chronyc tracking`（オフセット） |

出力例: `proxy`(enabled,server,bypass)、`time_sync`(servers:[...], synchronized:bool, source,
`_volatile`{offset,last_sync})。オフセット・最終同期時刻など毎回変わる値は `_volatile`
配下にまとめ **compare の差分対象から除外**（4.2 参照）。同期元サーバ・NTP 有効可否・
同期済みフラグは通常どおり比較対象。

### 3.6 filesystem 拡張

既存の容量情報（drive, fstype, total_gb, used_gb, free_gb, used_pct, root）に
マウントオプションを追加する。

| OS | 収集元 | 出力 |
|---|---|---|
| Windows | `Get-Volume`（FileSystem, AllocationUnitSize 等の取得可能な属性） | `mount_options`: read_only 等 |
| Linux | `mount` の出力 + `/etc/fstab` | `mount_options`: `noatime,nobarrier` 等のオプション文字列 |

### 3.7 security 拡張

既存（Windows: firewall profiles/rules・defender / Linux: firewalld 状態・SELinux mode）に
以下を追加する。

| 項目 | Windows | Linux |
|---|---|---|
| AppArmor | （該当なし） | `aa-status` or `systemctl is-active apparmor`（無ければ skip） |
| UAC | `HKLM:\...\Policies\System` の `EnableLUA`, `ConsentPromptBehaviorAdmin` | （該当なし） |

SELinux mode（`getenforce`）と firewalld 状態は既存維持。Windows の firewall・defender も既存維持。

## 4. 横断方針

### 4.1 制限環境フォールバック（CLAUDE.md 準拠）

- `Get-HotFix` / `Get-ScheduledTask` 等が GPO/AppLocker でブロックされたら
  CIM → `wmic` / `schtasks` の順でフォールバック
- それでも取得不可なら、その項目は空配列 / 空 dict + warn ログで継続。
  **収集全体（他カテゴリ）は止めない**
- Linux 側で対象コマンド / ファイルが無い場合も同様に空で継続

### 4.2 揮発値の compare 除外

時刻同期のオフセット・最終同期時刻など、テストごとに必ず変わる値は JSON 上
`_volatile` キー配下にまとめ、compare の差分比較から除外する。既存 `Compare-Os` の
揮発メトリクス除外と同じ思想。

### 4.3 両OS 1:1 対応

カテゴリ名・JSON トップレベル構造は Windows / Linux で揃える。中身の項目は OS 固有で
よい（例: tuning の THP は Linux のみ、電源プランは Windows のみ）。OS に存在しない
項目はキーごと省略する。

### 4.4 Linux は python3 で実装

既存 `server_snapshot.sh` と同様、Linux 側の収集は埋め込み python3 で実装する。
python3 が無い環境は server-snapshot 自体が動かない前提（既存仕様を踏襲）。

## 5. compare / レポートへの波及

- カテゴリ定義: PS の `[ValidateSet(...)]` と sh の categories リストに
  `patches` / `tuning` / `scheduled` を追加（8→11）
- 収集ディスパッチ: PS は `Get-PatchesInfo` / `Get-TuningInfo` / `Get-ScheduledInfo` を新設、
  sh は `collect_patches` / `collect_tuning` / `collect_scheduled`（python3 関数）を新設。
  os/network/filesystem/security は既存関数にフィールド追加
- compare 比較器を新カテゴリ用に追加:
  - `Compare-Patches`（`id`/`name` をキーにしたリスト比較）
  - `Compare-Tuning`（dict 比較。既存 `Compare-Dict` を流用）
  - `Compare-Scheduled`（`name`/`unit` をキーにしたリスト比較）
- 拡張カテゴリの追加フィールドは、既存比較器が dict / リストを再帰的に扱うため原則
  そのまま差分対象になる。`_volatile` 配下は比較器側で除外する
- compare の HTML / コンソールレポートはカテゴリ駆動。比較器を足せばレポートに反映され、
  レンダリング側の大改造は不要

## 6. テスト方針

### 6.1 Pester（Windows）

- 新カテゴリ収集関数（`Get-PatchesInfo` / `Get-TuningInfo` / `Get-ScheduledInfo`）の単体テスト。
  実コマンドをモックし、正常時に期待 JSON 構造（キー）が得られること／コマンドがブロック・
  欠落しても空で完走し JSON が壊れないこと
- 拡張フィールド（os の hardware/locale_detail/reboot_pending、network の proxy/time_sync、
  filesystem の mount_options、security の uac）が既存構造を壊さず追加されること
- 新比較器（Compare-Patches/Tuning/Scheduled）の same/changed/added/removed 判定
- `_volatile` が compare で除外されること

### 6.2 bats（Linux）

- 新カテゴリの python3 収集関数が、対象コマンド不在でも空 JSON 片を返し全体が完走すること
  （rpm / deb どちらの環境でも壊れない）
- ディストロ判定（rpm / dpkg / zypper）の分岐
- THP / CPU ガバナー / 脆弱性緩和の sysfs パスが無い環境でも壊れないこと

### 6.3 回帰

- 既存の server-snapshot テスト（collect / compare）が全て pass すること
- 既存カテゴリの JSON フィールドが変わらないこと（追加のみ・破壊なし）

## 7. ドキュメント

- `tools/server-snapshot/README.md` に新カテゴリ・新フィールドの説明と収集元を追記
- `docs_windows/os/`・`docs_linux/os/` の該当仕様書を更新
- `CHANGELOG.md` の `[Unreleased]` `### Added` に追記

### CHANGELOG 追記内容（案）

```markdown
- `server-snapshot` に収集カテゴリ `patches` / `tuning` / `scheduled` を追加し、
  `os`（HW/仮想化・ロケール詳細・再起動保留）・`network`（プロキシ・時刻同期）・
  `filesystem`（マウントオプション）・`security`（AppArmor/UAC）を拡張。
  テスト環境の断面把握と性能テスト再現性（CPU ガバナー・THP・CPU 脆弱性緩和）を強化
```

## 8. スコープ外（テーマB）

- ミドルウェア（PostgreSQL / MySQL / SAP HANA / SQL Server / Tomcat / nginx）の
  設定収集アドイン機構は別スペックとする
- 言語ランタイム / 実行ファイルのバージョン（java / python / .NET / openssl 等）は
  テーマB で扱う
