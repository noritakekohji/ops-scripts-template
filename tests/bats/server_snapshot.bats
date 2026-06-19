#!/usr/bin/env bats
# server_snapshot.sh の単体テスト + compare 結合テスト

load test_helper

CTL="${TOOLS_DIR}/server-snapshot/server_snapshot.sh"
FIXTURES="${REPO_ROOT}/tests/fixtures"

setup()    { WORK=$(make_test_workdir); }
teardown() { rm -rf "$WORK"; }

@test "server_snapshot: 引数なしで usage (exit 1)" {
    run bash "$CTL"
    [ "$status" -eq 1 ]
}

@test "server_snapshot: 不明サブコマンドは exit 1" {
    run bash "$CTL" foo
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Unknown subcommand" ]]
}

@test "server_snapshot: collect -c os で JSON を生成する" {
    if [[ "$(uname -s)" != "Linux" ]]; then skip "Linux only"; fi
    if ! command -v python3 >/dev/null; then skip "python3 required"; fi
    cd "$WORK"
    run bash "$CTL" collect -c os -o "$WORK/snap.json"
    [ "$status" -eq 0 ]
    [ -s "$WORK/snap.json" ]
    python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
assert 'meta' in d, 'meta key missing'
assert 'os' in d, 'os category missing'
assert d['meta']['categories'] == ['os'], 'unexpected categories: ' + str(d['meta']['categories'])
" "$WORK/snap.json"
}

@test "server_snapshot: compare <before> <after> で差分レポート" {
    if ! command -v python3 >/dev/null; then skip "python3 required"; fi
    cd "$WORK"
    run bash "$CTL" compare "${FIXTURES}/server_info_before.json" "${FIXTURES}/server_info_after.json"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "CHANGE DETECTION REPORT" ]]
}

@test "server_snapshot: compare に不存在ファイル → exit 2" {
    if ! command -v python3 >/dev/null; then skip "python3 required"; fi
    cd "$WORK"
    run bash "$CTL" compare "$WORK/nope.json" "${FIXTURES}/server_info_after.json"
    [ "$status" -eq 2 ]
}

@test "server_snapshot: list は exit 0" {
    cd "$WORK"
    run bash "$CTL" list
    [ "$status" -eq 0 ]
    [[ "$output" =~ "No snapshots found" ]]
}

@test "server_snapshot: patches category returns a JSON array" {
    if [[ "$(uname -s)" != "Linux" ]]; then skip "Linux only"; fi
    if ! command -v python3 >/dev/null; then skip "python3 required"; fi
    run bash "$CTL" collect --category patches --output "$WORK/snap.json"
    [ "$status" -eq 0 ]
    python3 -c "import json,sys; d=json.load(open('$WORK/snap.json')); assert isinstance(d.get('patches'), list)"
}

@test "server_snapshot: tuning category returns a JSON object" {
    if [[ "$(uname -s)" != "Linux" ]]; then skip "Linux only"; fi
    if ! command -v python3 >/dev/null; then skip "python3 required"; fi
    run bash "$CTL" collect --category tuning --output "$WORK/snap.json"
    [ "$status" -eq 0 ]
    python3 -c "import json; d=json.load(open('$WORK/snap.json')); assert isinstance(d.get('tuning'), dict)"
}

@test "server_snapshot: middleware file helper masks secrets" {
    if [[ "$(uname -s)" != "Linux" ]]; then skip "Linux only"; fi
    if ! command -v python3 >/dev/null; then skip "python3 required"; fi
    cat > "$WORK/app.conf" <<'EOF'
user = admin
password = s3cr3t
port = 8080
EOF
    _OPS_MW_PROBE="$WORK/app.conf" run bash "$CTL" collect --category middleware --output "$WORK/snap.json"
    [ "$status" -eq 0 ]
    python3 -c "import json; p=json.load(open('$WORK/snap.json'))['middleware']['_probe']; assert p['masked'] is True; assert '***' in p['content']; assert 'user = admin' in p['content']; assert len(p['sha256'])==64"
}

@test "server_snapshot: middleware detects tomcat base and masks server.xml" {
    if [[ "$(uname -s)" != "Linux" ]]; then skip "Linux only"; fi
    if ! command -v python3 >/dev/null; then skip "python3 required"; fi
    base="$WORK/tomcat9"; mkdir -p "$base/conf"
    cat > "$base/conf/server.xml" <<'EOF'
<Server port="8005"><Service name="Catalina">
<Connector port="8080" protocol="HTTP/1.1"/>
<Connector port="8443" secret="topsecret"/>
</Service></Server>
EOF
    CATALINA_BASE="$base" run bash "$CTL" collect --category middleware --output "$WORK/snap.json"
    [ "$status" -eq 0 ]
    python3 -c "
import json
mw=json.load(open('$WORK/snap.json'))['middleware']
t=[x for x in mw.get('tomcat',[]) if x['catalina_base']=='$base']
assert t, 'tomcat not detected'
assert 8080 in t[0]['connector_ports']
sx=[v for k,v in t[0]['config_files'].items() if k.endswith('server.xml')][0]
assert 'secret=\"***\"' in sx['content']
"
}
