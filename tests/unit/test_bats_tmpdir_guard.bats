#!/usr/bin/env bats
# test_bats_tmpdir_guard.bats — scripts/bats_tmpdir_guard.sh の試験(cmd_800)
#
# 本物の bats の代わりに、受け取った引数と TMPDIR を記録して決まった終了コード
# で終わる stub を PATH の先頭に置く。stub が呼ばれたか(記録の有無)で「bats を
# 起動したか」を判定する。TMPDIR は wrapper を起動する子プロセスにだけ与え、
# この試験自身の mktemp -d には影響させない。判定の if 文
# (# judge:tmpdir-absolute の行)を差し替えた変異体で、試験が判定の欠落を
# 検出できることも確かめる(変異試験)。

setup() {
    # 絶対リテラルの template で作り、TMPDIR に依らず絶対パスにする(D002-E1(d))。
    TEST_TMP="$(mktemp -d /tmp/bats_tmpdir_guard.XXXXXX)"
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    WRAPPER="$PROJECT_ROOT/scripts/bats_tmpdir_guard.sh"
    STUB_DIR="$TEST_TMP/bin"
    mkdir -p "$STUB_DIR"
    cat > "$STUB_DIR/bats" <<EOF
#!/usr/bin/env bash
printf '%s\\0' "\$@" > "$TEST_TMP/stub_args"
printf '%s' "\$#" > "$TEST_TMP/stub_argc"
printf '%s' "\${TMPDIR-<unset>}" > "$TEST_TMP/stub_tmpdir"
exit 7
EOF
    chmod +x "$STUB_DIR/bats"
    STUB_PATH="$STUB_DIR:$PATH"
}

teardown() {
    rm -rf -- "${TEST_TMP:?}"
}

# 引数を NUL 区切りで書き出したもの(stub の記録と突き合わせる)
expected_args() {
    printf '%s\0' "$@"
}

# wrapper(または変異体)を、TMPDIR を与えずに起動する
run_unset() {
    local target="$1"
    shift
    run env -u TMPDIR PATH="$STUB_PATH" bash "$target" "$@"
}

# wrapper(または変異体)を、TMPDIR に値を与えて起動する
run_with_tmpdir() {
    local value="$1" target="$2"
    shift 2
    run env PATH="$STUB_PATH" TMPDIR="$value" bash "$target" "$@"
}

# 判定行を差し替えた変異体を作る(目印の行が元と変異体に 1 行ずつあることを確かめる)
mutate_condition() {
    local dst="$1"
    [ "$(/usr/bin/grep -c '# judge:tmpdir-absolute$' "$WRAPPER")" -eq 1 ]
    sed -E 's/^([[:space:]]*)if .*# judge:tmpdir-absolute$/\1if false; then  # judge:tmpdir-absolute MUTATED/' \
        "$WRAPPER" > "$dst"
    [ "$(/usr/bin/grep -c '# judge:tmpdir-absolute MUTATED$' "$dst")" -eq 1 ]
}

# ---- 正常 ----------------------------------------------------------------

@test "正常: TMPDIR 未設定 → bats を起動し、引数をそのまま渡し、終了コードを返す" {
    run_unset "$WRAPPER" --timing 'a b' '' '*' -- --help
    [ "$status" -eq 7 ]
    [ -f "$TEST_TMP/stub_args" ]
    cmp -s "$TEST_TMP/stub_args" <(expected_args --timing 'a b' '' '*' -- --help)
    [ "$(cat "$TEST_TMP/stub_argc")" = "6" ]
    [ "$(cat "$TEST_TMP/stub_tmpdir")" = "<unset>" ]
}

@test "正常: TMPDIR が絶対パス → bats を起動し、TMPDIR を書き換えない" {
    run_with_tmpdir "$TEST_TMP" "$WRAPPER" tests/unit/
    [ "$status" -eq 7 ]
    cmp -s "$TEST_TMP/stub_args" <(expected_args tests/unit/)
    [ "$(cat "$TEST_TMP/stub_tmpdir")" = "$TEST_TMP" ]
}

@test "正常: 引数 0 個もそのまま(0 個で)渡す" {
    run_unset "$WRAPPER"
    [ "$status" -eq 7 ]
    [ "$(cat "$TEST_TMP/stub_argc")" = "0" ]
}

# ---- 異常 ----------------------------------------------------------------

@test "異常: 相対の TMPDIR → bats を起動せず、理由を出して exit 2" {
    run_with_tmpdir tmp "$WRAPPER" tests/unit/
    [ "$status" -eq 2 ]
    [ ! -e "$TEST_TMP/stub_args" ]
    [[ "$output" == *"TMPDIR が絶対パスではない(TMPDIR=tmp)"* ]]
    [[ "$output" == *"bats を起動しない"* ]]
    [[ "$output" == *"unset TMPDIR"* ]]
}

@test "異常: ./ や ../ や ~ で始まる TMPDIR も拒否する" {
    local value
    for value in ./tmp ../tmp '~/tmp' 'tmp/'; do
        run_with_tmpdir "$value" "$WRAPPER" x
        [ "$status" -eq 2 ]
        [ ! -e "$TEST_TMP/stub_args" ]
    done
}

@test "異常: bats が PATH に無い → exit 127" {
    local rc=0
    env -u TMPDIR PATH="$TEST_TMP/empty-bin" /bin/bash "$WRAPPER" x \
        2> "$TEST_TMP/stderr" || rc=$?
    [ "$rc" -eq 127 ]
    /usr/bin/grep -q 'bats が PATH に見つからない' "$TEST_TMP/stderr"
}

# ---- 境界 ----------------------------------------------------------------

@test "境界: TMPDIR が空文字 → 未設定とも絶対パスとも扱わず拒否" {
    run_with_tmpdir '' "$WRAPPER" x
    [ "$status" -eq 2 ]
    [ ! -e "$TEST_TMP/stub_args" ]
    [[ "$output" == *"TMPDIR=''"* ]]
}

@test "境界: TMPDIR がちょうど / → 起動する" {
    run_with_tmpdir / "$WRAPPER" x
    [ "$status" -eq 7 ]
    [ "$(cat "$TEST_TMP/stub_tmpdir")" = "/" ]
}

@test "境界: 先頭に空白のある TMPDIR(' /tmp')→ 拒否" {
    run_with_tmpdir ' /tmp' "$WRAPPER" x
    [ "$status" -eq 2 ]
    [ ! -e "$TEST_TMP/stub_args" ]
}

# ---- 変異試験 ----------------------------------------------------------------

@test "変異: 判定(judge:tmpdir-absolute)を外すと相対の TMPDIR で bats を起動してしまう" {
    mutate_condition "$TEST_TMP/mutant.sh"

    run_with_tmpdir tmp "$WRAPPER" x
    [ "$status" -eq 2 ]
    [ ! -e "$TEST_TMP/stub_args" ]

    run_with_tmpdir tmp "$TEST_TMP/mutant.sh" x
    [ "$status" -eq 7 ]
    [ -e "$TEST_TMP/stub_args" ]
}

@test "変異: 空文字を未設定と同じに扱う(\${TMPDIR:+set})と空の TMPDIR を通してしまう" {
    [ "$(/usr/bin/grep -c '# judge:tmpdir-absolute$' "$WRAPPER")" -eq 1 ]
    sed -e '/# judge:tmpdir-absolute$/ s/\${TMPDIR+set}/${TMPDIR:+set}/' \
        "$WRAPPER" > "$TEST_TMP/mutant.sh"
    [ "$(/usr/bin/grep -c 'TMPDIR:+set' "$TEST_TMP/mutant.sh")" -eq 1 ]

    run_with_tmpdir '' "$WRAPPER" x
    [ "$status" -eq 2 ]

    run_with_tmpdir '' "$TEST_TMP/mutant.sh" x
    [ "$status" -eq 7 ]
    [ -e "$TEST_TMP/stub_args" ]
}
