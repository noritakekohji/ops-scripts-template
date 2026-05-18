---
description: "新規ミドルウェア制御スクリプトを Tomcat 同等パターンで一式生成（ドメイン名を引数で指定）"
argument-hint: "<domain-name>  例: redis, kafka, memcached"
---

ドメイン名 **$ARGUMENTS** で新しいミドルウェア制御スクリプトを Tomcat / nginx と同じ
パターンで一式生成してください。生成対象:

1. `scripts_linux/$ARGUMENTS/${ARGUMENTS}ctl.sh`
   - `scripts_linux/tomcat/tomcatctl.sh` をベースに、コメント・ログメッセージ内のミドル名を
     置換しただけのもの（systemctl ベース、5-phase 構造）
   - 実行ビット付与（`git update-index --chmod=+x`）

2. `scripts_windows/$ARGUMENTS/${PascalCase}Ctl.ps1`
   - `scripts_windows/tomcat/TomcatCtl.ps1` をベースに同様に置換
   - **UTF-8 BOM 付き**で保存（必須）

3. `config/default/${ARGUMENTS}ctl.conf`
   - `Wait = true` / `WaitTimeoutSec = 60` をコメント付きで雛形に

4. `docs_linux/$ARGUMENTS/${ARGUMENTS}ctl.md` と
   `docs_windows/$ARGUMENTS/${PascalCase}Ctl.md`
   - 他の docs_*/<mw>/ スタブ（mysql / postgresql / sap 等）と同形式
   - 配置、概要、アクション表、終了コード、関連リンクを記載

5. `ops-scripts-structure.md` の Linux / Windows ツリーに 1 行追加

注意点:
- ファイル名は PowerShell 側は PascalCase（`RedisCtl.ps1`）、Bash 側は snake_case（`redisctl.sh`）
- `config-name` は両方とも `<lowercase>ctl`（例: `redisctl`）
- 終了コード規約・5-phase 構造・ログフォーマットは tomcat と完全一致させる
- 完了したらコミットメッセージのドラフトを提示（コミットは別途承認制）

ドメイン名が指定されていない場合はユーザに尋ねてください。
