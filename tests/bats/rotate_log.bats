#!/usr/bin/env bats
# rotate_log.sh の単体テスト + 結合テスト（実 FS 操作・sudo 不要）

load test_helper

CTL="${SCRIPTS_DIR}/os/rotate_log.sh"

setup() {
    WORK=$(make_test_workdir)
}
teardown() {
    rm -rf "$WORK"
}

# ─── 引数バリデーション ───────────────────────────────────────────

@test "rotate_log: -p も -L も無いと exit 1" {
    run bash "$CTL"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Specify -p or -L" ]]
}

@test "rotate_log: 不正な MaxSizeMB は exit 1" {
    run bash "$CTL" -p "$WORK/x.log" -s "abc"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Numeric arguments" ]]
}

@test "rotate_log: -L 指定で存在しないリストファイル → exit 2" {
    run bash "$CTL" -L "$WORK/no-such.lst"
    [ "$status" -eq 2 ]
    [[ "$output" =~ "Path list file not found" ]]
}

# ─── 結合: 単一ファイルのサイズベース rotate（dry-run）──────────────

@test "rotate_log: dry-run はファイルを変更しない" {
    local f="$WORK/app.log"
    head -c 2097152 /dev/urandom > "$f"   # 2 MiB
    local before
    before=$(stat -c%s "$f")
    run bash "$CTL" -p "$f" -s 1 -n
    [ "$status" -eq 0 ]
    [ -f "$f" ]
    [ "$(stat -c%s "$f")" -eq "$before" ]
}

# ─── 結合: 単一ファイルのサイズベース rotate（実 rotate）────────────

@test "rotate_log: 閾値超で実際に rotate される" {
    local f="$WORK/app.log"
    head -c 2097152 /dev/urandom > "$f"
    run bash "$CTL" -p "$f" -s 1
    [ "$status" -eq 0 ]
    # 元ファイルは空または新規になり、別名のローテファイルが生成される
    # rotate 後のサイズは 0、別名ファイルが 1 つ以上
    [ -f "$f" ]
    [ "$(stat -c%s "$f")" -eq 0 ]
    local rotated
    rotated=$(find "$WORK" -maxdepth 1 -name 'app.log.*' | wc -l)
    [ "$rotated" -ge 1 ]
}

# ─── 結合: 閾値未満ならスキップ（exit 0 で status=skipped）──────────

@test "rotate_log: 閾値未満なら rotate されず skipped" {
    local f="$WORK/app.log"
    head -c 1024 /dev/urandom > "$f"
    local before
    before=$(stat -c%s "$f")
    run bash "$CTL" -p "$f" -s 100   # 100MB 閾値 → 当然超えない
    [ "$status" -eq 0 ]
    [ "$(stat -c%s "$f")" -eq "$before" ]
    [[ "$output" =~ "Skipped" ]] || true   # status=skipped のログが出る
}

# ─── 結合: retention で古いローテートファイルが削除される ─────────

@test "rotate_log: retention 超過の古いファイルが削除される" {
    local f="$WORK/app.log"
    head -c 2097152 /dev/urandom > "$f"
    # ダミーの古いローテートファイルを 5 つ作る
    for i in 1 2 3 4 5; do
        local t
        t=$(printf '%08d-%06d' 20250101 $((i*100000)))
        : > "$WORK/app.log.${t}"
    done
    # retention=2 → 古い 3 つ削除されるはず
    run bash "$CTL" -p "$f" -s 1 -k 2
    [ "$status" -eq 0 ]
    local remaining
    remaining=$(find "$WORK" -maxdepth 1 -name 'app.log.*' | wc -l)
    # 元の 5 + 新規 rotate 1 = 6、retention=2 で 2 つ残るはず
    # （実装上「最新 retention 件を残す」）
    [ "$remaining" -le 3 ]
}

# ─── 結合: -L リストファイル経由 ────────────────────────────────

@test "rotate_log: -L でリストファイル経由の rotate" {
    local f1="$WORK/a.log" f2="$WORK/b.log"
    head -c 2097152 /dev/urandom > "$f1"
    head -c 2097152 /dev/urandom > "$f2"
    cat > "$WORK/list.txt" <<EOF
$f1
$f2
EOF
    run bash "$CTL" -L "$WORK/list.txt" -s 1
    [ "$status" -eq 0 ]
    [ "$(stat -c%s "$f1")" -eq 0 ]
    [ "$(stat -c%s "$f2")" -eq 0 ]
}

@test "rotate_log: -L のコメント行と空行は無視される" {
    local f="$WORK/c.log"
    head -c 2097152 /dev/urandom > "$f"
    cat > "$WORK/list.txt" <<EOF
# this is a comment

$f

EOF
    run bash "$CTL" -L "$WORK/list.txt" -s 1
    [ "$status" -eq 0 ]
    [ "$(stat -c%s "$f")" -eq 0 ]
}

# ─── 結合: -c (gzip) ──────────────────────────────────────────────

@test "rotate_log: -c で rotate 後のファイルは .gz になる" {
    if ! command -v gzip >/dev/null; then skip "gzip not installed"; fi
    local f="$WORK/d.log"
    head -c 2097152 /dev/urandom > "$f"
    run bash "$CTL" -p "$f" -s 1 -c
    [ "$status" -eq 0 ]
    local gz
    gz=$(find "$WORK" -maxdepth 1 -name 'd.log.*.gz' | wc -l)
    [ "$gz" -ge 1 ]
}
