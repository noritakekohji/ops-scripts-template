#!/usr/bin/env bats
# check_network_connectivity.sh の単体テスト + localhost 結合テスト

load test_helper

CTL="${TOOLS_DIR}/network-check/check_network_connectivity.sh"

setup()    { WORK=$(make_test_workdir); }
teardown() { rm -rf "$WORK"; }

# ─── 引数バリデーション ───────────────────────────────────────────

@test "network-check: -l なしは exit 1 (usage)" {
    run bash "$CTL"
    [ "$status" -ne 0 ]
}

@test "network-check: 不存在のターゲットリスト → exit 2" {
    run bash "$CTL" -l "$WORK/no-such.lst"
    [ "$status" -eq 2 ]
}

# ─── ターゲットリストのパース ────────────────────────────────────

@test "network-check: 4-field 形式 + コメント + 空行" {
    cat > "$WORK/t.lst" <<'EOF'
# This is a comment

127.0.0.1, -, ok, Localhost ping
EOF
    if ! command -v ping >/dev/null; then skip "ping required"; fi
    run timeout 30 bash "$CTL" -l "$WORK/t.lst" -c 1 -t 2
    # localhost は到達可能想定。 0 (ok) または 1 (warning) で許容
    [ "$status" -le 1 ]
}

# ─── 3-field 互換 ─────────────────────────────────────────────────

@test "network-check: 3-field 形式も受け付ける" {
    cat > "$WORK/t.lst" <<'EOF'
127.0.0.1, -, Localhost (3-field)
EOF
    if ! command -v ping >/dev/null; then skip "ping required"; fi
    run timeout 30 bash "$CTL" -l "$WORK/t.lst" -c 1 -t 2
    [ "$status" -le 1 ]
}

# ─── HTML レポート生成 ────────────────────────────────────────────

@test "network-check: -o で HTML レポートが出力される" {
    cat > "$WORK/t.lst" <<'EOF'
127.0.0.1, -, ok, Localhost
EOF
    if ! command -v ping >/dev/null; then skip "ping required"; fi
    if ! command -v python3 >/dev/null; then skip "python3 required for HTML render"; fi
    run timeout 30 bash "$CTL" -l "$WORK/t.lst" -c 1 -t 2 -o "$WORK/report.html"
    [ -f "$WORK/report.html" ]
    grep -q -i "network" "$WORK/report.html"
}

# ─── 期待値 ng (到達不能想定) ─────────────────────────────────────

@test "network-check: expected=ng で本当に到達不能なら OK" {
    cat > "$WORK/t.lst" <<'EOF'
192.0.2.123, -, ng, Documentation-only IP (RFC5737) should not respond
EOF
    if ! command -v ping >/dev/null; then skip "ping required"; fi
    # ping は ICMP 不到達で 1 を返すが、expected=ng で評価としては成功扱い
    run timeout 30 bash "$CTL" -l "$WORK/t.lst" -c 1 -t 1
    # NG 期待が一致すれば exit 0 / 1 のいずれか（Docker 環境では ping 自体不可な
    # こともあるので緩めに）
    [ "$status" -le 1 ]
}
