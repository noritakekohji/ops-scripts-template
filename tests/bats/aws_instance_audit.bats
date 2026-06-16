#!/usr/bin/env bats
# aws_instance_audit.sh の単体テスト
#   - 引数バリデーション / 前提チェック（aws CLI 不在, IMDS 到達不可）
#   - JSON 組み立て（aws / curl をモックした end-to-end。python3 不要）
#   - render_report.py を fixture で検証（python3 がある場合のみ）
# 実 AWS / 実 IMDS には依存しない。

load test_helper

TOOL_DIR="${TOOLS_DIR}/aws-instance-audit"
SH="${TOOL_DIR}/aws_instance_audit.sh"
RENDER_PY="${TOOL_DIR}/render_report.py"
FIXTURE="${REPO_ROOT}/tests/fixtures/aws_audit_sample.json"

setup() {
    WORK=$(make_test_workdir)
    setup_mock_bin
}
teardown() {
    teardown_mock_bin
    rm -rf "$WORK"
}

# IMDS を返す curl モックと、--query に応じて値を返す aws モックを仕込む。
# JSON 出力経路を python / jq なしで end-to-end に流すための足場。
_setup_aws_mocks() {
    make_mock_script curl '
url=""; for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
case "$url" in
  *api/token) echo "TOK" ;;
  *meta-data/instance-id) echo "i-0test123" ;;
  *meta-data/instance-type) echo "t3.micro" ;;
  *meta-data/ami-id) echo "ami-0abc" ;;
  *placement/availability-zone) echo "ap-northeast-1a" ;;
  *placement/region) echo "ap-northeast-1" ;;
  *local-ipv4) echo "10.0.1.23" ;;
  *public-ipv4) echo "" ;;
  *meta-data/mac) echo "0a:11:22:33:44:55" ;;
  */vpc-id) echo "vpc-0aaa" ;;
  */subnet-id) echo "subnet-0bbb" ;;
  */security-group-ids) printf "sg-0web\n" ;;
  *iam/security-credentials/) echo "web-instance-role" ;;
  *) echo "" ;;
esac
exit 0
'
    make_mock_script aws '
q=""; prev=""; for a in "$@"; do [[ "$prev" == "--query" ]] && q="$a"; prev="$a"; done
act="$2"; [[ "$1" == "sts" ]] && exit 0
case "$act" in
  describe-tags) printf "Name\tweb01\nEnv\tprod\n" ;;
  get-role) case "$q" in
      Role.Arn) echo "arn:aws:iam::123:role/web-instance-role" ;;
      Role.CreateDate) echo "2024-01-01T00:00:00+00:00" ;;
    esac ;;
  list-attached-role-policies) printf "AmazonS3ReadOnlyAccess\tarn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess\n" ;;
  list-role-policies) printf "app-secrets-read\n" ;;
  describe-security-groups) case "$q" in
      *GroupName,Description*) printf "sg-0web\tweb-sg\tweb tier\tvpc-0aaa\n" ;;
      *IpPermissionsEgress*) printf -- "-1\tNone\tNone\t0.0.0.0/0\t\t\n" ;;
      *IpPermissions*) printf "tcp\t443\t443\t0.0.0.0/0\t\t\ntcp\t80\t80\t\t\tsg-0app\n" ;;
    esac ;;
  describe-vpcs) printf "vpc-0aaa\t10.0.0.0/16\tFalse\n" ;;
  describe-subnets) printf "subnet-0bbb\t10.0.1.0/24\tap-northeast-1a\tTrue\n" ;;
  describe-network-interfaces) printf "eni-0eee\t10.0.1.23\tsubnet-0bbb\tprimary\tsg-0web\n" ;;
  describe-route-tables) case "$q" in
      *RouteTableId*) printf "rtb-0fff\n" ;;
      *Routes*) printf "local\tNone\n0.0.0.0/0\tigw-0ggg\n" ;;
    esac ;;
esac
exit 0
'
}

# ─── 前提チェック ─────────────────────────────────────────────

@test "aws_instance_audit: aws CLI 不在は exit 10" {
    # mock bin だけの PATH（aws なし、基本コマンドは /usr/bin /bin に残す）
    PATH="$MOCK_BIN_DIR:/usr/bin:/bin"
    if command -v aws >/dev/null 2>&1; then skip "aws present in system PATH"; fi
    run bash "$SH"
    [ "$status" -eq 10 ]
    [[ "$output" =~ "aws CLI not found" ]]
}

@test "aws_instance_audit: IMDS 到達不可は exit 2" {
    # aws と curl をモック。curl は IMDS トークン取得で失敗（非ゼロ）させる
    make_mock aws 0 ""
    make_mock_script curl 'exit 7'   # curl: couldn't connect
    run bash "$SH"
    [ "$status" -eq 2 ]
    [[ "$output" =~ "Cannot reach IMDS" ]]
}

@test "aws_instance_audit: 不明オプションは exit 1" {
    make_mock aws 0 ""
    run bash "$SH" --bogus
    [ "$status" -eq 1 ]
}

@test "aws_instance_audit: --html 指定で python3 不在なら exit 10" {
    # python を欠いた PATH。aws/curl は存在する想定だが、html_file 検出時点で先に落ちる。
    PATH="$MOCK_BIN_DIR:/usr/bin:/bin"
    make_mock aws 0 ""
    make_mock_script curl 'exit 0'
    if command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; then
        skip "python present in restricted PATH"
    fi
    run bash "$SH" --html "$WORK/r.html"
    [ "$status" -eq 10 ]
    [[ "$output" =~ "HTML report" ]]
}

# ─── ネイティブ JSON 組み立て（python / jq 不要）───────────────

@test "native json: 全カテゴリを python なしで JSON 出力する" {
    _setup_aws_mocks
    out="$WORK/out.json"
    run bash "$SH" -o "$out"
    [ "$status" -eq 0 ]
    [ -f "$out" ]
    # 1 行コンパクト JSON。主要フィールドを文字列で検証（JSON パーサ非依存）。
    run cat "$out"
    [[ "$output" == *'"instance_id":"i-0test123"'* ]]
    [[ "$output" == *'"tags":{"Name":"web01","Env":"prod"}'* ]]
    [[ "$output" == *'"role_arn":"arn:aws:iam::123:role/web-instance-role"'* ]]
    [[ "$output" == *'"inline_policies":["app-secrets-read"]'* ]]
    [[ "$output" == *'"vpc":{"vpc_id":"vpc-0aaa","cidr":"10.0.0.0/16","is_default":false}'* ]]
    [[ "$output" == *'"map_public_ip":true'* ]]
}

@test "native json: SG の -1 を all に、空ポートを null に正規化" {
    _setup_aws_mocks
    out="$WORK/out.json"
    run bash "$SH" -c sg -o "$out"
    [ "$status" -eq 0 ]
    run cat "$out"
    # egress: -1 -> all, FromPort/ToPort None -> null
    [[ "$output" == *'"egress":[{"protocol":"all","from_port":null,"to_port":null,"cidrs":["0.0.0.0/0"],"sg_refs":[]}]'* ]]
    # ingress 2 本目: CIDR 無し（中間空フィールド）でも sg_refs が壊れない
    [[ "$output" == *'"from_port":80,"to_port":80,"cidrs":[],"sg_refs":["sg-0app"]'* ]]
    # sg だけ指定したので instance/iam/network は含まれない
    [[ "$output" != *'"instance"'* ]]
    [[ "$output" != *'"network"'* ]]
}

@test "native json: -c instance はタグのみを含み iam/sg/network を含まない" {
    _setup_aws_mocks
    out="$WORK/out.json"
    run bash "$SH" -c instance -o "$out"
    [ "$status" -eq 0 ]
    run cat "$out"
    [[ "$output" == *'"instance"'* ]]
    [[ "$output" == *'"tags":{"Name":"web01"'* ]]
    [[ "$output" != *'"security_groups"'* ]]
    [[ "$output" != *'"iam"'* ]]
}

# ─── render_report.py（fixture → HTML）─────────────────────────

@test "render_report: fixture JSON から HTML を生成" {
    if ! command -v python3 >/dev/null; then skip "python3 required"; fi
    local out="$WORK/audit.html"
    run python3 "$RENDER_PY" "$FIXTURE" "$out"
    [ "$status" -eq 0 ]
    [ -f "$out" ]
    grep -q "AWS Instance Audit Report" "$out"
    # 主要な内容が反映されている
    grep -q "web-instance-role" "$out"
    grep -q "sg-0web11111" "$out"
    grep -q "vpc-0aaa1111" "$out"
}

@test "render_report: 引数不足は exit 1" {
    if ! command -v python3 >/dev/null; then skip "python3 required"; fi
    run python3 "$RENDER_PY" "$FIXTURE"
    [ "$status" -eq 1 ]
}
