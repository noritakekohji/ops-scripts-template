#!/usr/bin/env bash
# ============================================================================
# aws_instance_audit.sh  -  Audit the AWS context of the current EC2 instance
#   IMDSv2 + AWS CLI を用いて、自インスタンスの IAM ロール / Security Group /
#   VPC・Subnet・ENI・Route / メタデータ・タグを収集し JSON 出力する。
#   （tools/ 配下の自己完結スクリプト。lib には依存しない）
#
# Usage:
#   aws_instance_audit.sh [-c <categories>] [-o <out.json>] [--html <out.html>]
#                         [-r <region>] [-h]
#
# Options:
#   -c <cats>   収集カテゴリ（カンマ区切り）。既定: all
#                 all / instance / iam / sg / network
#   -o <file>   JSON 出力先（既定: aws_audit_<instance-id>_<ts>.json）
#   --html <f>  HTML レポート出力先（python3 が必要）
#   -r <region> リージョン上書き（既定: IMDS から自動取得）
#   -h          ヘルプ
#
# 前提:
#   - EC2 インスタンス上で実行（IMDS 169.254.169.254 に到達できること）
#   - aws CLI v2 が PATH 上にあること
#   - インスタンスプロファイルの IAM ロールに必要な読み取り権限
#     (ec2:Describe*, iam:ListAttachedRolePolicies, iam:GetPolicy など)
#
# 終了コード:
#   0 成功 / 1 引数不正 / 2 IMDS 到達不可（EC2 外）/
#   5 出力書込み失敗 / 10 aws CLI 不在 / 20 認証・権限エラー
# ============================================================================
set -uo pipefail

IMDS="http://169.254.169.254/latest"
TOKEN_TTL=21600

# ── ログ（stderr）──────────────────────────────────────────────
_log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] ${*:2}" >&2; }
log_info()  { _log "INFO " "$@"; }
log_warn()  { _log "WARN " "$@"; }
log_error() { _log "ERROR" "$@"; }

usage() { sed -n '2,30p' "$0" >&2; exit 1; }

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
RENDER_PY="${SCRIPT_DIR}/render_report.py"

# ── 引数 ───────────────────────────────────────────────────────
categories="all"
out_file=""
html_file=""
region=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c) categories="${2:-}"; shift 2 ;;
        -o) out_file="${2:-}"; shift 2 ;;
        --html) html_file="${2:-}"; shift 2 ;;
        -r) region="${2:-}"; shift 2 ;;
        -h|--help) usage ;;
        *) log_error "Unknown option: $1"; usage ;;
    esac
done

# ── カテゴリ判定 ───────────────────────────────────────────────
want() {
    [[ "$categories" == "all" ]] && return 0
    [[ ",$categories," == *",$1,"* ]] && return 0
    return 1
}

# ── 前提チェック ───────────────────────────────────────────────
if ! command -v aws >/dev/null 2>&1; then
    log_error "aws CLI not found in PATH"
    exit 10
fi
if ! command -v python3 >/dev/null 2>&1; then
    PY=""
else
    PY="python3"
fi

# ── AWS CLI 挙動の安定化 ───────────────────────────────────────
# - AWS_PAGER='' : v2 のページャー（less 風）が非対話環境で入力待ちになり
#   固まるのを防ぐ
# - 接続/読み取りタイムアウトとリトライ回数を絞り、egress 制限環境で
#   IAM 等の到達不可エンドポイントを叩いたときに数分ハングするのを防ぐ
export AWS_PAGER=""
export AWS_MAX_ATTEMPTS="${AWS_MAX_ATTEMPTS:-2}"
export AWS_RETRY_MODE="${AWS_RETRY_MODE:-standard}"
AWS_TIMEOUT_OPTS=(--cli-connect-timeout 5 --cli-read-timeout 30)

# timeout コマンドがあれば各 aws 呼び出しのハード上限として使う（保険）
if command -v timeout >/dev/null 2>&1; then
    AWS_HARD_TIMEOUT=(timeout 60)
else
    AWS_HARD_TIMEOUT=()
fi

# ── IMDSv2 トークン取得 ────────────────────────────────────────
imds_token() {
    curl -fsS -m 3 -X PUT "${IMDS}/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: ${TOKEN_TTL}" 2>/dev/null
}

TOKEN=$(imds_token || true)
if [[ -z "$TOKEN" ]]; then
    log_error "Cannot reach IMDS (${IMDS}). Not on an EC2 instance, or IMDS disabled."
    exit 2
fi

# IMDS GET ヘルパ（404 等は空文字を返す）
imds_get() {
    curl -fsS -m 3 -H "X-aws-ec2-metadata-token: ${TOKEN}" \
        "${IMDS}/meta-data/$1" 2>/dev/null || true
}

# ── メタデータ収集 ─────────────────────────────────────────────
instance_id=$(imds_get "instance-id")
instance_type=$(imds_get "instance-type")
ami_id=$(imds_get "ami-id")
az=$(imds_get "placement/availability-zone")
local_ip=$(imds_get "local-ipv4")
public_ip=$(imds_get "public-ipv4")
mac=$(imds_get "mac")
[[ -z "$region" ]] && region=$(imds_get "placement/region")
[[ -z "$region" && -n "$az" ]] && region="${az%?}"   # az の末尾1文字を落とす fallback

vpc_id=""; subnet_id=""
if [[ -n "$mac" ]]; then
    vpc_id=$(imds_get "network/interfaces/macs/${mac}/vpc-id")
    subnet_id=$(imds_get "network/interfaces/macs/${mac}/subnet-id")
fi

# インスタンスにアタッチされた SG (IMDS から ID 一覧)
sg_ids_raw=""
if [[ -n "$mac" ]]; then
    sg_ids_raw=$(imds_get "network/interfaces/macs/${mac}/security-group-ids")
fi

# IAM ロール名（instance profile）
iam_role=$(imds_get "iam/security-credentials/")

log_info "Instance: id=$instance_id type=$instance_type region=$region vpc=$vpc_id role=${iam_role:-<none>}"

export AWS_DEFAULT_REGION="$region"

# 出力先決定
ts=$(TZ=Asia/Tokyo date +%Y%m%d-%H%M%S)
[[ -z "$out_file" ]] && out_file="aws_audit_${instance_id:-unknown}_${ts}.json"

# ── JSON 構築（python3 があれば安全に、なければ手組み）────────────
# AWS CLI の生 JSON を一時ファイルに集め、python3 で 1 つに束ねる。
TMPDIR_AUDIT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_AUDIT"' EXIT

aws_json() {
    # $@ = aws CLI 引数。失敗時は "null" を返し WARN。
    # タイムアウト/リトライ抑制オプションとハード timeout を付与する。
    local out
    if out=$("${AWS_HARD_TIMEOUT[@]}" aws "$@" "${AWS_TIMEOUT_OPTS[@]}" --output json 2>"$TMPDIR_AUDIT/err"); then
        printf '%s' "$out"
    else
        log_warn "aws $* failed: $(tr '\n' ' ' < "$TMPDIR_AUDIT/err")"
        printf '%s' "null"
    fi
}

# 認証確認
if ! "${AWS_HARD_TIMEOUT[@]}" aws sts get-caller-identity "${AWS_TIMEOUT_OPTS[@]}" \
        --output json >"$TMPDIR_AUDIT/caller.json" 2>"$TMPDIR_AUDIT/err"; then
    log_error "AWS auth failed (sts get-caller-identity): $(tr '\n' ' ' < "$TMPDIR_AUDIT/err")"
    exit 20
fi

# 各カテゴリの生データ取得
echo 'null' > "$TMPDIR_AUDIT/iam.json"
echo 'null' > "$TMPDIR_AUDIT/sg.json"
echo 'null' > "$TMPDIR_AUDIT/vpc.json"
echo 'null' > "$TMPDIR_AUDIT/subnet.json"
echo 'null' > "$TMPDIR_AUDIT/eni.json"
echo 'null' > "$TMPDIR_AUDIT/rt.json"
echo 'null' > "$TMPDIR_AUDIT/tags.json"

if want iam && [[ -n "$iam_role" ]]; then
    log_info "Collecting IAM role/policies: $iam_role"
    aws_json iam list-attached-role-policies --role-name "$iam_role"   > "$TMPDIR_AUDIT/iam_attached.json"
    aws_json iam list-role-policies          --role-name "$iam_role"   > "$TMPDIR_AUDIT/iam_inline.json"
    aws_json iam get-role                    --role-name "$iam_role"   > "$TMPDIR_AUDIT/iam_role.json"
fi

if want sg; then
    log_info "Collecting security groups"
    if [[ -n "$sg_ids_raw" ]]; then
        # IMDS の SG ID 一覧（改行区切り）を配列化
        mapfile -t sg_ids <<< "$sg_ids_raw"
        aws_json ec2 describe-security-groups --group-ids "${sg_ids[@]}" > "$TMPDIR_AUDIT/sg.json"
    elif [[ -n "$instance_id" ]]; then
        # フォールバック: インスタンスから SG を引く
        aws_json ec2 describe-instances --instance-ids "$instance_id" > "$TMPDIR_AUDIT/inst.json"
    fi
fi

if want network; then
    log_info "Collecting network (vpc/subnet/eni/route)"
    [[ -n "$vpc_id" ]]    && aws_json ec2 describe-vpcs    --vpc-ids "$vpc_id"       > "$TMPDIR_AUDIT/vpc.json"
    [[ -n "$subnet_id" ]] && aws_json ec2 describe-subnets --subnet-ids "$subnet_id" > "$TMPDIR_AUDIT/subnet.json"
    [[ -n "$instance_id" ]] && aws_json ec2 describe-network-interfaces \
        --filters "Name=attachment.instance-id,Values=$instance_id" > "$TMPDIR_AUDIT/eni.json"
    [[ -n "$vpc_id" ]] && aws_json ec2 describe-route-tables \
        --filters "Name=vpc-id,Values=$vpc_id" > "$TMPDIR_AUDIT/rt.json"
fi

if want instance && [[ -n "$instance_id" ]]; then
    aws_json ec2 describe-tags \
        --filters "Name=resource-id,Values=$instance_id" > "$TMPDIR_AUDIT/tags.json"
fi

# ── python3 で最終 JSON を束ねる（_assemble_json.py に集約）──────
if [[ -z "$PY" ]]; then
    log_error "python3 not found — required to assemble JSON output"
    exit 10
fi
ASSEMBLER="${SCRIPT_DIR}/_assemble_json.py"
if [[ ! -f "$ASSEMBLER" ]]; then
    log_error "_assemble_json.py not found: $ASSEMBLER"; exit 5
fi

if ! INST_ID="$instance_id" INST_TYPE="$instance_type" AMI="$ami_id" AZ="$az" \
     REGION="$region" LOCAL_IP="$local_ip" PUBLIC_IP="$public_ip" \
     VPC_ID="$vpc_id" SUBNET_ID="$subnet_id" IAM_ROLE="$iam_role" \
     CATS="$categories" HOSTNAME_S="$(hostname)" TMPD="$TMPDIR_AUDIT" OUT="$out_file" \
     "$PY" "$ASSEMBLER"; then
    log_error "Failed to assemble JSON output"
    exit 5
fi

log_info "JSON written: $out_file"

# ── HTML レポート ───────────────────────────────────────────────
if [[ -n "$html_file" ]]; then
    if [[ -f "$RENDER_PY" ]]; then
        if "$PY" "$RENDER_PY" "$out_file" "$html_file"; then
            log_info "HTML report: $html_file"
        else
            log_error "HTML render failed"; exit 5
        fi
    else
        log_error "render_report.py not found: $RENDER_PY"; exit 5
    fi
fi

echo ""
echo "  AWS instance audit complete"
echo "  JSON: $out_file"
[[ -n "$html_file" ]] && echo "  HTML: $html_file"
echo ""
exit 0
