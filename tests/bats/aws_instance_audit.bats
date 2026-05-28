#!/usr/bin/env bats
# aws_instance_audit.sh の単体テスト
#   - 引数バリデーション / 前提チェック（aws CLI 不在, IMDS 到達不可）
#   - render_report.py / _assemble_json.py を fixture で検証
# 実 AWS / 実 IMDS には依存しない。

load test_helper

TOOL_DIR="${TOOLS_DIR}/aws-instance-audit"
SH="${TOOL_DIR}/aws_instance_audit.sh"
RENDER_PY="${TOOL_DIR}/render_report.py"
ASSEMBLE_PY="${TOOL_DIR}/_assemble_json.py"
FIXTURE="${REPO_ROOT}/tests/fixtures/aws_audit_sample.json"

setup() {
    WORK=$(make_test_workdir)
    setup_mock_bin
}
teardown() {
    teardown_mock_bin
    rm -rf "$WORK"
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

# ─── _assemble_json.py 単体（環境変数 + tmp 生 JSON を束ねる）───

@test "assemble: メタ情報と instance/tags を組み立てる" {
    if ! command -v python3 >/dev/null; then skip "python3 required"; fi
    local td="$WORK/tmp"; mkdir -p "$td"
    # tags.json を用意
    cat > "$td/tags.json" <<'EOF'
{ "Tags": [ { "Key": "Name", "Value": "web01" }, { "Key": "Env", "Value": "prod" } ] }
EOF
    local out="$WORK/out.json"
    TMPD="$td" OUT="$out" CATS="instance" HOSTNAME_S="web01" REGION="ap-northeast-1" \
    INST_ID="i-0test" INST_TYPE="t3.micro" AMI="ami-0x" AZ="ap-northeast-1a" \
    LOCAL_IP="10.0.1.5" PUBLIC_IP="" VPC_ID="vpc-0x" SUBNET_ID="subnet-0x" IAM_ROLE="" \
    python3 "$ASSEMBLE_PY"
    [ -f "$out" ]
    python3 -c "
import json,sys
d=json.load(open('$out'))
assert d['meta']['instance_id']=='i-0test', d['meta']
assert d['instance']['instance_type']=='t3.micro'
assert d['instance']['tags']['Name']=='web01'
assert d['instance']['tags']['Env']=='prod'
# iam/sg/network は instance カテゴリ指定なので含まれない
assert 'iam' not in d
"
}

@test "assemble: SG の -1 プロトコルを all に正規化する" {
    if ! command -v python3 >/dev/null; then skip "python3 required"; fi
    local td="$WORK/tmp"; mkdir -p "$td"
    cat > "$td/sg.json" <<'EOF'
{ "SecurityGroups": [ {
  "GroupId": "sg-0x", "GroupName": "g", "Description": "d", "VpcId": "vpc-0x",
  "IpPermissions": [ { "IpProtocol": "tcp", "FromPort": 443, "ToPort": 443, "IpRanges": [ { "CidrIp": "0.0.0.0/0" } ] } ],
  "IpPermissionsEgress": [ { "IpProtocol": "-1", "IpRanges": [ { "CidrIp": "0.0.0.0/0" } ] } ]
} ] }
EOF
    local out="$WORK/out.json"
    TMPD="$td" OUT="$out" CATS="sg" HOSTNAME_S="h" REGION="ap-northeast-1" \
    INST_ID="i-0x" INST_TYPE="" AMI="" AZ="" LOCAL_IP="" PUBLIC_IP="" \
    VPC_ID="" SUBNET_ID="" IAM_ROLE="" \
    python3 "$ASSEMBLE_PY"
    python3 -c "
import json
d=json.load(open('$out'))
sg=d['security_groups'][0]
assert sg['group_id']=='sg-0x'
assert sg['ingress'][0]['from_port']==443
assert sg['egress'][0]['protocol']=='all', sg['egress']
"
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
