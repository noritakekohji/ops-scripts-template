#!/usr/bin/env bash
# ============================================================================
# aws_instance_audit.sh  -  Audit the AWS context of the current EC2 instance
#   IMDSv2 + AWS CLI を用いて、自インスタンスの IAM ロール / Security Group /
#   VPC・Subnet・ENI・Route / メタデータ・タグを収集し JSON 出力する。
#   （tools/ 配下の自己完結スクリプト。lib には依存しない）
#
#   JSON 組み立ては aws CLI の --query (JMESPath) + --output text による値抽出と
#   bash ネイティブの JSON エミッタで行うため python3 / jq は不要。HTML レポート
#   (--html) を生成するときだけ python3 (render_report.py) が必要。
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
#   - HTML レポート（--html）を出すときのみ python3
#
# 終了コード:
#   0 成功 / 1 引数不正 / 2 IMDS 到達不可（EC2 外）/
#   5 出力書込み失敗 / 10 aws CLI 不在（--html 指定時は python3 不在）/
#   20 認証・権限エラー
# ============================================================================
set -uo pipefail

IMDS="http://169.254.169.254/latest"
TOKEN_TTL=21600

# ── ログ（stderr）──────────────────────────────────────────────
_log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] ${*:2}" >&2; }
log_info()  { _log "INFO " "$@"; }
log_warn()  { _log "WARN " "$@"; }
log_error() { _log "ERROR" "$@"; }

usage() { sed -n '2,33p' "$0" >&2; exit 1; }

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
# python3 は HTML レポート生成にのみ使用する。JSON 出力だけなら不要。
if command -v python3 >/dev/null 2>&1; then
    PY="python3"
elif command -v python >/dev/null 2>&1; then
    PY="python"
else
    PY=""
fi
if [[ -n "$html_file" && -z "$PY" ]]; then
    log_error "python3 not found — required for HTML report (--html)"
    exit 10
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

# ── JSON ヘルパー（python3 / jq 不要のネイティブ実装）───────────
# 値の取得は aws CLI の --query (JMESPath) + --output text に寄せ、JSON 文字列の
# 組み立てだけを bash 側で行う（aws が JSON 解析を担うので bash でのパース不要）。

# 文字列を JSON 文字列リテラルにエスケープして出力（前後の " 込み）
json_str() {
    local s=${1-}
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\t'/\\t}
    s=${s//$'\r'/\\r}
    s=${s//$'\n'/\\n}
    printf '"%s"' "$s"
}

# aws --output text の "None"（=null）を空文字に正規化
nz() { if [[ "${1-}" == "None" ]]; then printf ''; else printf '%s' "${1-}"; fi; }

# 数値 or null（"None"/空 -> null、それ以外はそのまま）
json_num() {
    local v=${1-}
    if [[ -z "$v" || "$v" == "None" ]]; then printf 'null'; else printf '%s' "$v"; fi
}

# True/False -> true/false（それ以外は false）
json_bool() { case "${1-}" in True|true) printf 'true' ;; *) printf 'false' ;; esac; }

# 区切り文字でつないだ文字列 -> JSON 文字列配列（空なら []）
json_arr_delim() {
    local delim=$1 s=${2-} out="" sep="" item oldifs=$IFS
    if [[ -z "$s" || "$s" == "None" ]]; then printf '[]'; return; fi
    IFS=$delim
    for item in $s; do
        [[ -z "$item" ]] && continue
        out="$out$sep$(json_str "$item")"; sep=","
    done
    IFS=$oldifs
    printf '[%s]' "$out"
}

# フィールド区切り。aws --output text はフィールド間を TAB で区切るが、TAB は IFS
# 空白文字なので `read` が連続区切りを 1 つに圧縮し「中間の空フィールド」を消す
# （例: FromPort/ToPort が空の -1 ルール）。そこで aws_text 側で TAB を非空白の
# US(0x1f) に置換し、各 read は IFS="$FS" で分割する（空フィールドを保持する）。
FS=$'\x1f'

# aws を --output text で叩く（失敗時は空・WARN、必ず末尾改行を付ける）。
# 末尾改行は `while read` が最終行を取りこぼさないために必須。
# 出力中の TAB は FS(US) に置換して返す。
aws_text() {
    local out
    if out=$("${AWS_HARD_TIMEOUT[@]}" aws "$@" "${AWS_TIMEOUT_OPTS[@]}" --output text 2>/dev/null); then
        printf '%s\n' "${out//$'\t'/$FS}"
    else
        log_warn "aws $* failed"
        printf '\n'
    fi
}

# 1 つの SG の IpPermissions / IpPermissionsEgress を共通スキーマの JSON 配列に
# 正規化する。$1=group-id, $2=IpPermissions|IpPermissionsEgress
sg_perms() {
    local sgid=$1 field=$2 acc="" sep="" proto frm to c4 c6 refs cidrs
    while IFS="$FS" read -r proto frm to c4 c6 refs; do
        [[ -z "$proto" && -z "$frm" && -z "$to" && -z "$c4" && -z "$c6" && -z "$refs" ]] && continue
        [[ "$proto" == "-1" ]] && proto="all"
        # IPv4 (CidrIp) と IPv6 (CidrIpv6) を 1 配列にまとめる（いずれも | 連結済み）
        cidrs=""
        [[ -n "$c4" && "$c4" != "None" ]] && cidrs="$c4"
        if [[ -n "$c6" && "$c6" != "None" ]]; then
            if [[ -n "$cidrs" ]]; then cidrs="$cidrs|$c6"; else cidrs="$c6"; fi
        fi
        [[ "$refs" == "None" ]] && refs=""
        acc="$acc$sep{\"protocol\":$(json_str "$(nz "$proto")"),\"from_port\":$(json_num "$frm"),\"to_port\":$(json_num "$to"),\"cidrs\":$(json_arr_delim '|' "$cidrs"),\"sg_refs\":$(json_arr_delim '|' "$refs")}"
        sep=","
    done < <(aws_text ec2 describe-security-groups --group-ids "$sgid" \
        --query "SecurityGroups[0].${field}[].[IpProtocol,FromPort,ToPort,join(\`\"|\"\`,IpRanges[].CidrIp),join(\`\"|\"\`,Ipv6Ranges[].CidrIpv6),join(\`\"|\"\`,UserIdGroupPairs[].GroupId)]")
    printf '[%s]' "$acc"
}

# ── 認証確認 ───────────────────────────────────────────────────
if ! "${AWS_HARD_TIMEOUT[@]}" aws sts get-caller-identity "${AWS_TIMEOUT_OPTS[@]}" \
        --output text >/dev/null 2>&1; then
    log_error "AWS auth failed (sts get-caller-identity)"
    exit 20
fi

# ── JSON 本体の組み立て ────────────────────────────────────────
now_jst=$(TZ=Asia/Tokyo date '+%Y-%m-%d %H:%M:%S')
host_name=$(hostname 2>/dev/null || printf '')

body="\"meta\":{\"tool\":\"aws_instance_audit\",\"collected_at\":$(json_str "$now_jst"),\"hostname\":$(json_str "$host_name"),\"region\":$(json_str "$region"),\"instance_id\":$(json_str "$instance_id"),\"categories\":$(json_str "${categories:-all}")}"

# ── instance + tags ────────────────────────────────────────────
if want instance; then
    tags_obj="{}"
    if [[ -n "$instance_id" ]]; then
        tpairs=""; tsep=""
        while IFS="$FS" read -r tk tv; do
            [[ -z "$tk" ]] && continue
            tpairs="$tpairs$tsep$(json_str "$(nz "$tk")"):$(json_str "$(nz "$tv")")"; tsep=","
        done < <(aws_text ec2 describe-tags --filters "Name=resource-id,Values=$instance_id" \
            --query 'Tags[].[Key,Value]')
        tags_obj="{$tpairs}"
    fi
    body="$body,\"instance\":{\"instance_id\":$(json_str "$instance_id"),\"instance_type\":$(json_str "$instance_type"),\"ami_id\":$(json_str "$ami_id"),\"availability_zone\":$(json_str "$az"),\"region\":$(json_str "$region"),\"private_ip\":$(json_str "$local_ip"),\"public_ip\":$(json_str "$public_ip"),\"vpc_id\":$(json_str "$vpc_id"),\"subnet_id\":$(json_str "$subnet_id"),\"tags\":$tags_obj}"
fi

# ── IAM ────────────────────────────────────────────────────────
if want iam; then
    role_arn=""; create_date=""; att_json="[]"; inl_json="[]"
    if [[ -n "$iam_role" ]]; then
        log_info "Collecting IAM role/policies: $iam_role"
        role_arn=$(nz "$(aws_text iam get-role --role-name "$iam_role" --query 'Role.Arn')")
        create_date=$(nz "$(aws_text iam get-role --role-name "$iam_role" --query 'Role.CreateDate')")
        ap=""; apsep=""
        while IFS="$FS" read -r pn pa; do
            [[ -z "$pn" && -z "$pa" ]] && continue
            ap="$ap$apsep{\"name\":$(json_str "$(nz "$pn")"),\"arn\":$(json_str "$(nz "$pa")")}"; apsep=","
        done < <(aws_text iam list-attached-role-policies --role-name "$iam_role" \
            --query 'AttachedPolicies[].[PolicyName,PolicyArn]')
        att_json="[$ap]"
        inline_raw=$(aws_text iam list-role-policies --role-name "$iam_role" --query 'PolicyNames')
        inl_json=$(json_arr_delim "$FS" "$(nz "$inline_raw")")
    fi
    iam_json="\"iam\":{\"role_name\":$(json_str "$iam_role"),\"role_arn\":$(json_str "$role_arn"),\"attached_policies\":$att_json,\"inline_policies\":$inl_json"
    [[ -n "$create_date" ]] && iam_json="$iam_json,\"create_date\":$(json_str "$create_date")"
    iam_json="$iam_json}"
    body="$body,$iam_json"
fi

# ── Security Groups ────────────────────────────────────────────
if want sg; then
    sg_json="[]"
    if [[ -n "$sg_ids_raw" ]]; then
        log_info "Collecting security groups"
        mapfile -t sg_ids <<< "$sg_ids_raw"
        sgacc=""; sgsep=""
        for sgid in "${sg_ids[@]}"; do
            [[ -z "$sgid" ]] && continue
            IFS="$FS" read -r gid gname gdesc gvpc < <(aws_text ec2 describe-security-groups \
                --group-ids "$sgid" --query 'SecurityGroups[0].[GroupId,GroupName,Description,VpcId]')
            [[ -z "$gid" || "$gid" == "None" ]] && gid="$sgid"
            ing=$(sg_perms "$sgid" IpPermissions)
            egr=$(sg_perms "$sgid" IpPermissionsEgress)
            sgacc="$sgacc$sgsep{\"group_id\":$(json_str "$(nz "$gid")"),\"group_name\":$(json_str "$(nz "$gname")"),\"description\":$(json_str "$(nz "$gdesc")"),\"vpc_id\":$(json_str "$(nz "$gvpc")"),\"ingress\":$ing,\"egress\":$egr}"
            sgsep=","
        done
        sg_json="[$sgacc]"
    fi
    body="$body,\"security_groups\":$sg_json"
fi

# ── Network (VPC / Subnet / ENI / Route) ───────────────────────
if want network; then
    log_info "Collecting network (vpc/subnet/eni/route)"
    net=""; nsep=""
    # VPC
    if [[ -n "$vpc_id" ]]; then
        IFS="$FS" read -r vid vcidr vdef < <(aws_text ec2 describe-vpcs --vpc-ids "$vpc_id" \
            --query 'Vpcs[0].[VpcId,CidrBlock,IsDefault]')
        if [[ -n "$vid" && "$vid" != "None" ]]; then
            net="$net$nsep\"vpc\":{\"vpc_id\":$(json_str "$(nz "$vid")"),\"cidr\":$(json_str "$(nz "$vcidr")"),\"is_default\":$(json_bool "$vdef")}"; nsep=","
        fi
    fi
    # Subnet
    if [[ -n "$subnet_id" ]]; then
        IFS="$FS" read -r sid scidr saz smap < <(aws_text ec2 describe-subnets --subnet-ids "$subnet_id" \
            --query 'Subnets[0].[SubnetId,CidrBlock,AvailabilityZone,MapPublicIpOnLaunch]')
        if [[ -n "$sid" && "$sid" != "None" ]]; then
            net="$net$nsep\"subnet\":{\"subnet_id\":$(json_str "$(nz "$sid")"),\"cidr\":$(json_str "$(nz "$scidr")"),\"az\":$(json_str "$(nz "$saz")"),\"map_public_ip\":$(json_bool "$smap")}"; nsep=","
        fi
    fi
    # ENI
    if [[ -n "$instance_id" ]]; then
        eacc=""; esep=""
        while IFS="$FS" read -r eid eip esub edesc egroups; do
            [[ -z "$eid" || "$eid" == "None" ]] && continue
            [[ "$egroups" == "None" ]] && egroups=""
            eacc="$eacc$esep{\"eni_id\":$(json_str "$(nz "$eid")"),\"private_ip\":$(json_str "$(nz "$eip")"),\"subnet_id\":$(json_str "$(nz "$esub")"),\"description\":$(json_str "$(nz "$edesc")"),\"groups\":$(json_arr_delim '|' "$egroups")}"; esep=","
        done < <(aws_text ec2 describe-network-interfaces \
            --filters "Name=attachment.instance-id,Values=$instance_id" \
            --query "NetworkInterfaces[].[NetworkInterfaceId,PrivateIpAddress,SubnetId,Description,join(\`\"|\"\`,Groups[].GroupId)]")
        net="$net$nsep\"enis\":[$eacc]"; nsep=","
    fi
    # Route tables
    if [[ -n "$vpc_id" ]]; then
        rtacc=""; rtsep=""
        while IFS="$FS" read -r rtid; do
            [[ -z "$rtid" || "$rtid" == "None" ]] && continue
            racc=""; rsep=""
            while IFS="$FS" read -r rdest rtarget; do
                [[ -z "$rdest" && -z "$rtarget" ]] && continue
                racc="$racc$rsep{\"dest\":$(json_str "$(nz "$rdest")"),\"target\":$(json_str "$(nz "$rtarget")")}"; rsep=","
            done < <(aws_text ec2 describe-route-tables --route-table-ids "$rtid" \
                --query 'RouteTables[0].Routes[].[DestinationCidrBlock || DestinationPrefixListId, GatewayId || NatGatewayId || NetworkInterfaceId || TransitGatewayId]')
            rtacc="$rtacc$rtsep{\"route_table_id\":$(json_str "$(nz "$rtid")"),\"routes\":[$racc]}"; rtsep=","
        done < <(aws_text ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpc_id" \
            --query 'RouteTables[].[RouteTableId]')
        net="$net$nsep\"route_tables\":[$rtacc]"; nsep=","
    fi
    body="$body,\"network\":{$net}"
fi

# ── 出力 ───────────────────────────────────────────────────────
out_dir=$(dirname "$out_file")
[[ -n "$out_dir" && ! -d "$out_dir" ]] && mkdir -p "$out_dir"
if ! printf '{%s}\n' "$body" > "$out_file"; then
    log_error "Failed to write JSON output: $out_file"
    exit 5
fi
log_info "JSON written: $out_file"

# ── HTML レポート（python3 + render_report.py）─────────────────
if [[ -n "$html_file" ]]; then
    if [[ -z "$PY" ]]; then
        log_error "python3 not found — required for HTML report (--html)"
        exit 10
    fi
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
