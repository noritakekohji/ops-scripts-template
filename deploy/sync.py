#!/usr/bin/env python3
"""
deploy/sync.py  —  ops-scripts を複数のターゲットリポジトリへ同期し GitLab MR を作成

使い方:
    python3 deploy/sync.py                           # 全有効サーバーを同期
    python3 deploy/sync.py --server server-web01     # 特定サーバーのみ
    python3 deploy/sync.py --target infra-tokyo      # 特定ターゲットリポジトリのみ
    python3 deploy/sync.py --dry-run                 # ドライラン（変更なし）

GitLab CI 変数 (Settings > CI/CD > Variables):
    GITLAB_URL      GitLab のベース URL  例: https://gitlab.example.com
    GITLAB_TOKEN    Personal Access Token（スコープ: api, write_repository）
    DEPLOY_SERVERS  コンマ区切りのサーバー名（空 = 全有効サーバー）
    DEPLOY_TARGETS  コンマ区切りのターゲット ID（空 = 全ターゲット）
    DRY_RUN         "true" でドライラン（コミット・MR 作成を行わない）

処理の流れ:
    同じターゲットリポジトリに属するサーバーは 1 回のクローンで処理される。
    ターゲット A のサーバーを全て処理してから、ターゲット B に移る。
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
from collections import defaultdict
from pathlib import Path

# ---------------------------------------------------------------------------
# 依存パッケージ（CI では before_script でインストール済み、ローカルは自動）
# ---------------------------------------------------------------------------
def _ensure_deps() -> None:
    import importlib.util
    need = []
    if importlib.util.find_spec('yaml')     is None: need.append('pyyaml')
    if importlib.util.find_spec('requests') is None: need.append('requests')
    if need:
        subprocess.check_call([sys.executable, '-m', 'pip', 'install', '-q'] + need)

_ensure_deps()
import yaml        # noqa: E402
import requests    # noqa: E402

# ---------------------------------------------------------------------------
# 定数
# ---------------------------------------------------------------------------
DEPLOY_DIR = Path(__file__).parent
REPO_ROOT  = DEPLOY_DIR.parent

# src パスの先頭から除去してターゲット相対パスを求めるプレフィックス
# 順序重要: より長いものを先にマッチさせる
_STRIP_PREFIXES = (
    'scripts_windows/',
    'scripts_linux/',
    'config/default/',
)


# ---------------------------------------------------------------------------
# ユーティリティ
# ---------------------------------------------------------------------------
def run(cmd: str, cwd: Path | None = None, check: bool = True) -> str:
    """シェルコマンドを実行して stdout を返す。失敗時は RuntimeError。"""
    r = subprocess.run(
        cmd, shell=True, cwd=cwd, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if check and r.returncode != 0:
        raise RuntimeError(
            f"コマンド失敗 [exit {r.returncode}]: {cmd}\n{r.stderr.strip()}"
        )
    return r.stdout.strip()


def target_rel(src_str: str) -> str:
    """
    'scripts_windows/lib/Logging.psm1' -> 'lib/Logging.psm1'
    'config/default/global.conf'       -> 'global.conf'
    'tools/server-snapshot/'           -> 'tools/server-snapshot/'  (そのまま)
    """
    for prefix in _STRIP_PREFIXES:
        if src_str.startswith(prefix):
            return src_str[len(prefix):]
    return src_str


def header(text: str, width: int = 58) -> None:
    print(f"\n{'='*width}")
    print(f"  {text}")
    print(f"{'='*width}")


# ---------------------------------------------------------------------------
# GitLab API ラッパー
# ---------------------------------------------------------------------------
class GitLabAPI:
    def __init__(self, base_url: str, token: str, project_id: int) -> None:
        self._root = f"{base_url.rstrip('/')}/api/v4"
        self._api  = f"{self._root}/projects/{project_id}"
        self._sess = requests.Session()
        self._sess.headers['PRIVATE-TOKEN'] = token

    def project_info(self) -> dict:
        r = self._sess.get(self._api)
        r.raise_for_status()
        return r.json()

    def open_mr_for_branch(self, source_branch: str) -> dict | None:
        r = self._sess.get(
            f"{self._api}/merge_requests",
            params={'state': 'opened', 'source_branch': source_branch},
        )
        r.raise_for_status()
        mrs = r.json()
        return mrs[0] if mrs else None

    def create_mr(self, **kwargs) -> dict:
        r = self._sess.post(f"{self._api}/merge_requests", json=kwargs)
        r.raise_for_status()
        return r.json()

    def add_mr_note(self, iid: int, body: str) -> None:
        r = self._sess.post(
            f"{self._api}/merge_requests/{iid}/notes",
            json={'body': body},
        )
        r.raise_for_status()


# ---------------------------------------------------------------------------
# ファイルコピー
# ---------------------------------------------------------------------------
def copy_scripts(server: dict, target_root: Path) -> list[str]:
    """
    server['scripts'] に列挙されたパスをコピー（常に上書き）。
    コピーしたファイルの target_root からの相対パスリストを返す。
    """
    scripts_dst = target_root / server['scripts_dir']
    scripts_dst.mkdir(parents=True, exist_ok=True)
    copied: list[str] = []

    for entry in server.get('scripts', []):
        src = REPO_ROOT / entry.rstrip('/')

        if src.is_dir():
            # ディレクトリ: 配下を再帰コピー、サブパス構造を維持
            entry_rel = target_rel(entry.rstrip('/') + '/')  # 例: 'lib/'
            for f in sorted(src.rglob('*')):
                if not f.is_file():
                    continue
                sub = f.relative_to(src)
                dst = scripts_dst / entry_rel / sub
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(f, dst)
                copied.append(str(dst.relative_to(target_root)))

        elif src.is_file():
            rel = target_rel(entry)
            dst = scripts_dst / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)
            copied.append(str(dst.relative_to(target_root)))

        else:
            print(f"  [WARN] 見つかりません（スキップ）: {entry}")

    return copied


def copy_configs(server: dict, target_root: Path) -> tuple[list[str], list[str]]:
    """
    server['configs'] に列挙されたコンフィグをコピー（存在しない場合のみ）。
    戻り値: (新規コピーしたパスリスト, スキップしたパスリスト)
    """
    config_dst = target_root / server['config_dir']
    config_dst.mkdir(parents=True, exist_ok=True)
    new_files: list[str] = []
    skipped:   list[str] = []

    for entry in server.get('configs', []):
        src = REPO_ROOT / entry
        if not src.is_file():
            print(f"  [WARN] コンフィグが見つかりません（スキップ）: {entry}")
            continue
        rel = target_rel(entry)
        dst = config_dst / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        if dst.exists():
            skipped.append(str(dst.relative_to(target_root)))
        else:
            shutil.copy2(src, dst)
            new_files.append(str(dst.relative_to(target_root)))

    return new_files, skipped


# ---------------------------------------------------------------------------
# MR 本文生成
# ---------------------------------------------------------------------------
def build_mr_body(
    server: dict,
    target_id: str,
    sha: str,
    scripts: list[str],
    cfg_new: list[str],
    cfg_skip: list[str],
    source_url: str,
) -> str:
    def file_list(files: list[str]) -> str:
        return '\n'.join(f'- `{f}`' for f in files) if files else '_なし_'

    cfg_new_section = (
        f'\n\n### コンフィグ（新規作成）\n\n{file_list(cfg_new)}'
        if cfg_new else ''
    )
    cfg_skip_section = (
        '\n\n### コンフィグ（既存のためスキップ）\n\n'
        + '\n'.join(f'- `{f}` ← ターゲットの既存ファイルを保持' for f in cfg_skip)
        if cfg_skip else ''
    )

    repo_name = source_url.rstrip('/').split('/')[-1] or 'ops-scripts-template'

    return textwrap.dedent(f"""\
        ## Ops スクリプト同期 — `{server['name']}`

        | 項目 | 内容 |
        |---|---|
        | コミット | `{sha}` |
        | ターゲット | `{target_id}` |
        | OS | `{server['os']}` |
        | 説明 | {server.get('description', '―')} |

        ### スクリプト（上書き更新）

        {file_list(scripts)}{cfg_new_section}{cfg_skip_section}

        ---

        > ⚙️ このMRは [{repo_name}]({source_url}) の CI によって自動生成されました。
        > 内容を確認した上でマージしてください。
    """)


# ---------------------------------------------------------------------------
# サーバー単体の同期処理（クローン済みの target_root を受け取る）
# ---------------------------------------------------------------------------
def sync_server(
    server: dict,
    target_id: str,
    target_root: Path,
    api: GitLabAPI,
    base_branch: str,
    sha: str,
    source_url: str,
    mr_labels: list[str],
    mr_assignee_id: int | None,
    dry_run: bool,
) -> dict:
    name   = server['name']
    branch = f"sync/ops-{name}"

    # ── ブランチ準備 ──────────────────────────────────────
    run(f"git checkout {base_branch}", cwd=target_root)
    run(f"git pull origin {base_branch} --ff-only", cwd=target_root)
    run(f"git branch -D {branch}", cwd=target_root, check=False)
    run(f"git checkout -b {branch}", cwd=target_root)

    # ── ファイルコピー ────────────────────────────────────
    scripts_copied       = copy_scripts(server, target_root)
    cfg_new, cfg_skipped = copy_configs(server, target_root)

    # ── 差分確認 ──────────────────────────────────────────
    diff_stat = run("git status --porcelain", cwd=target_root)
    if not diff_stat:
        print("  変更なし — MR 作成をスキップ")
        run(f"git checkout {base_branch}", cwd=target_root)
        return {'status': 'no_changes'}

    if dry_run:
        print("  [DRY-RUN] 差分あり（コミット・MR 作成はスキップ）")
        print(textwrap.indent(diff_stat, "    "))
        run("git checkout -- .", cwd=target_root, check=False)
        run("git clean -fd",     cwd=target_root, check=False)
        run(f"git checkout {base_branch}", cwd=target_root, check=False)
        return {'status': 'dry_run'}

    # ── コミット & プッシュ ───────────────────────────────
    run("git add -A", cwd=target_root)
    commit_msg = (
        f"sync(ops): {name} スクリプト更新 [{sha}]\n\n"
        f"Source: ops-scripts-template @ {sha}"
    )
    run(f"git commit -m {commit_msg!r}", cwd=target_root)
    run(f"git push origin {branch} --force", cwd=target_root)

    # ── MR 作成 or 既存MR 更新 ───────────────────────────
    mr_body    = build_mr_body(
        server, target_id, sha, scripts_copied, cfg_new, cfg_skipped, source_url)
    existing   = api.open_mr_for_branch(branch)

    if existing:
        api.add_mr_note(
            existing['iid'],
            f"🔄 スクリプトを `{sha}` で更新しました（force push）。\n\n"
            f"差分タブで変更内容を再確認してください。",
        )
        mr_url = existing['web_url']
        print(f"  既存MR にコメント追加 → {mr_url}")
        return {'status': 'mr_updated', 'mr_url': mr_url}

    mr_kwargs: dict = dict(
        source_branch        = branch,
        target_branch        = base_branch,
        title                = f"[Ops Sync] {name} スクリプト更新 ({sha})",
        description          = mr_body,
        remove_source_branch = True,
    )
    if mr_labels:
        mr_kwargs['labels'] = ','.join(mr_labels)
    if mr_assignee_id:
        mr_kwargs['assignee_id'] = mr_assignee_id

    mr     = api.create_mr(**mr_kwargs)
    mr_url = mr['web_url']
    print(f"  MR 作成 → {mr_url}")
    return {'status': 'mr_created', 'mr_url': mr_url}


# ---------------------------------------------------------------------------
# ターゲットリポジトリ単位の処理（クローン1回 → サーバー複数処理）
# ---------------------------------------------------------------------------
def process_target(
    target_cfg: dict,
    servers: list[dict],
    gitlab_url: str,
    gitlab_token: str,
    sha: str,
    source_url: str,
    dry_run: bool,
) -> list[dict]:
    target_id = target_cfg['id']
    header(f"ターゲット: {target_id}  ({len(servers)} サーバー)")

    api = GitLabAPI(gitlab_url, gitlab_token, int(target_cfg['project_id']))
    try:
        proj = api.project_info()
    except Exception as e:
        print(f"  [ERROR] GitLab API 接続失敗 ({target_id}): {e}")
        return [{'server': s['name'], 'target': target_id,
                 'status': 'error', 'error': str(e)} for s in servers]

    clone_url = proj['http_url_to_repo'].replace(
        'https://', f'https://oauth2:{gitlab_token}@')

    tmpdir      = Path(tempfile.mkdtemp())
    target_root = tmpdir / target_id
    print(f"  クローン中: {proj['name_with_namespace']}")
    run(f"git clone --depth 50 {clone_url} {target_root}")
    run("git config user.email 'ci-sync@ops-scripts'", cwd=target_root)
    run("git config user.name  'Ops Sync CI'",          cwd=target_root)

    base_branch   = target_cfg.get('branch', 'main')
    mr_labels     = target_cfg.get('mr_labels', [])
    mr_assignee   = target_cfg.get('mr_assignee_id')

    results: list[dict] = []
    for server in servers:
        name = server['name']
        print(f"\n  ── {name} ({server['os']}) ──")
        try:
            r = sync_server(
                server, target_id, target_root, api,
                base_branch, sha, source_url,
                mr_labels, mr_assignee, dry_run,
            )
            r['server'] = name
            r['target'] = target_id
            results.append(r)
        except Exception as e:
            print(f"  [ERROR] {e}")
            results.append({'server': name, 'target': target_id,
                            'status': 'error', 'error': str(e)})
        finally:
            run(f"git checkout {base_branch}", cwd=target_root, check=False)

    return results


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
def main() -> None:
    parser = argparse.ArgumentParser(description='ops-scripts 同期ツール')
    parser.add_argument('--server',  help='同期対象サーバー名（未指定 = 全有効サーバー）')
    parser.add_argument('--target',  help='同期対象ターゲット ID（未指定 = 全ターゲット）')
    parser.add_argument('--dry-run', action='store_true', help='ドライラン（変更なし）')
    args = parser.parse_args()

    dry_run = args.dry_run or os.environ.get('DRY_RUN', '').lower() == 'true'

    # ── 台帳読み込み ──────────────────────────────────────
    registry_path = DEPLOY_DIR / 'servers.yaml'
    if not registry_path.exists():
        print(f"[ERROR] {registry_path} が見つかりません")
        sys.exit(1)
    registry = yaml.safe_load(registry_path.read_text(encoding='utf-8'))

    # targets を id → dict のマップに変換
    targets_map: dict[str, dict] = {t['id']: t for t in registry.get('targets', [])}
    if not targets_map:
        print("[ERROR] servers.yaml に targets が定義されていません")
        sys.exit(1)

    gitlab_url   = os.environ.get('GITLAB_URL',   '').rstrip('/')
    gitlab_token = os.environ.get('GITLAB_TOKEN', '')
    if not gitlab_url or not gitlab_token:
        print("[ERROR] 環境変数 GITLAB_URL と GITLAB_TOKEN を設定してください")
        sys.exit(1)

    sha        = os.environ.get('CI_COMMIT_SHORT_SHA', 'manual')
    source_url = os.environ.get('CI_PROJECT_URL', 'ops-scripts-template')

    # ── サーバー・ターゲットの絞り込み ───────────────────
    def split_env(key: str) -> list[str]:
        return [s.strip() for s in os.environ.get(key, '').split(',') if s.strip()]

    filter_servers = ([args.server]  if args.server  else []) or split_env('DEPLOY_SERVERS')
    filter_targets = ([args.target]  if args.target  else []) or split_env('DEPLOY_TARGETS')

    all_servers = [s for s in registry.get('servers', []) if s.get('enabled', True)]

    # 対象サーバーを絞り込み
    if filter_servers:
        servers = [s for s in all_servers if s['name'] in filter_servers]
        missing = set(filter_servers) - {s['name'] for s in servers}
        if missing:
            print(f"[WARN] 台帳にないサーバー名: {sorted(missing)}")
    else:
        servers = all_servers

    # 対象ターゲットを絞り込み
    if filter_targets:
        unknown = set(filter_targets) - set(targets_map)
        if unknown:
            print(f"[WARN] 台帳にないターゲット ID: {sorted(unknown)}")
        servers = [s for s in servers if s.get('target') in filter_targets]

    # target フィールドが未定義なサーバーをチェック
    invalid = [s['name'] for s in servers if s.get('target') not in targets_map]
    if invalid:
        print(f"[ERROR] 以下のサーバーの target が targets に定義されていません: {invalid}")
        sys.exit(1)

    if not servers:
        print("同期対象サーバーがありません")
        sys.exit(0)

    # ── サーバーをターゲットごとにグループ化 ────────────
    # 同じターゲットリポジトリは 1 回のクローンで処理する
    grouped: dict[str, list[dict]] = defaultdict(list)
    for s in servers:
        grouped[s['target']].append(s)

    print(f"ターゲット数: {len(grouped)}  /  サーバー数: {len(servers)}")
    print(f"ドライラン: {dry_run}")
    for tid, svrs in grouped.items():
        print(f"  [{tid}] → {[s['name'] for s in svrs]}")

    # ── ターゲットごとに処理 ──────────────────────────────
    all_results: list[dict] = []
    for target_id, target_servers in grouped.items():
        results = process_target(
            targets_map[target_id], target_servers,
            gitlab_url, gitlab_token,
            sha, source_url, dry_run,
        )
        all_results.extend(results)

    # ── 結果サマリー ──────────────────────────────────────
    icons = {
        'mr_created': '✅', 'mr_updated': '🔄',
        'no_changes': '⏭️', 'dry_run':    '🧪', 'error': '❌',
    }
    header("結果サマリー")
    # ターゲットごとにグループ表示
    for target_id in grouped:
        print(f"\n  [{target_id}]")
        for r in all_results:
            if r['target'] != target_id:
                continue
            st  = r['status']
            url = f"  → {r['mr_url']}" if 'mr_url' in r else ''
            err = f"  {r.get('error', '')}" if st == 'error' else ''
            print(f"    {icons.get(st, '?')} {r['server']}: {st}{url}{err}")

    if any(r['status'] == 'error' for r in all_results):
        sys.exit(1)


if __name__ == '__main__':
    main()
