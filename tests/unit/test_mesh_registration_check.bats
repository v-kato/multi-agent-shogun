#!/usr/bin/env bats
# test_mesh_registration_check.bats — lib/mesh_registration_check.sh ユニットテスト
# cmd_759 A-3: 出陣後のmesh登録(socket実在)read-only確認

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    TEST_TMP="$(mktemp -d)"
    export MESH_SOCK_DIR="${TEST_TMP}/cc-socks"
    mkdir -p "$MESH_SOCK_DIR"
    # ★セッション記録の探索先を試験専用dirへ隔離する(実 ~/.claude/sessions の
    #   古い記録が、偶然同じpidの偽claudeへ混入しないように)。
    export CLAUDE_CONFIG_DIR="${TEST_TMP}/claude-config"
    mkdir -p "${CLAUDE_CONFIG_DIR}/sessions"

    # shellcheck disable=SC1090
    source "$PROJECT_ROOT/lib/mesh_registration_check.sh"
}

teardown() {
    # 本テストが立てたsocket待受プロセスがあれば自然終了を待つ(killしない)。
    if [ -n "${SOCK_SERVER_PID:-}" ]; then
        kill -0 "$SOCK_SERVER_PID" 2>/dev/null && wait "$SOCK_SERVER_PID" 2>/dev/null
    fi
    if [ -n "${FAKE_CLAUDE_PID:-}" ]; then
        wait "$FAKE_CLAUDE_PID" 2>/dev/null || true
    fi
    if [ -n "${FAKE_OTHER_PID:-}" ]; then
        wait "$FAKE_OTHER_PID" 2>/dev/null || true
    fi
    rm -rf "$TEST_TMP"
}

# start_fake_socket_at <socket_path>
# 指定パスにLISTENするUNIXソケットを立てる(親dirは呼出側が用意済みであること)。
# 生成したサーバのPIDはSOCK_SERVER_PIDへ格納する(teardownで自然終了を待つ)。
start_fake_socket_at() {
    local path="$1"
    "${PROJECT_ROOT}/.venv/bin/python3" -c "
import socket, sys, time
path = sys.argv[1]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path)
s.listen(1)
time.sleep(4)
" "$path" &
    SOCK_SERVER_PID=$!
    # ★固定sleepでの待受完了確認は避け、ソケットファイル出現をイベントとして
    #   一度だけポーリング上限つきで待つ(最大2秒・50ms間隔)。長時間ループ
    #   ではなく起動確認のみに限定する。
    for _ in $(seq 1 40); do
        [ -S "$path" ] && return 0
        sleep 0.05
    done
    return 1
}

# start_fake_socket_server <pid_like_name>
# ${MESH_SOCK_DIR}/<pid_like_name>.sock にLISTENするUNIXソケットを立てる。
start_fake_socket_server() {
    start_fake_socket_at "${MESH_SOCK_DIR}/${1}.sock"
}

# make_fake_claude_bin
# comm名が"claude"になる偽バイナリ(sleepの複製)をTEST_TMP配下に作り、
# FAKE_BIN_DIRへそのdirを格納する(teardownのTEST_TMP削除で一緒に消える)。
make_fake_claude_bin() {
    FAKE_BIN_DIR="${TEST_TMP}/fakebin"
    mkdir -p "$FAKE_BIN_DIR"
    cp "$(command -v sleep)" "${FAKE_BIN_DIR}/claude"
    chmod +x "${FAKE_BIN_DIR}/claude"
}

# clear_mesh_env
# 置場判定に効く呼出側環境変数を全て外す(試験ごとに必要なものだけ設定し直す)。
# CLAUDE_CONFIG_DIR は setup の隔離値を残す。
clear_mesh_env() {
    unset MESH_SOCK_DIR XDG_RUNTIME_DIR CLAUDE_CODE_TMPDIR TMPDIR
}

# spawn_fake_claude <秒> [env(1)へ渡す引数...]
# comm名が"claude"の偽プロセスを、指定の環境(VAR=値 / -u VAR)付きで起動し、
# PIDをFAKE_CLAUDE_PIDへ格納する。★exec完了前は/proc/<pid>/environが起動元の
# 古い値のままなので、comm名がclaudeになる(=exec完了)のをイベントとして
# 待つ(最大2秒・50ms間隔)。
spawn_fake_claude() {
    local secs="$1"
    shift
    make_fake_claude_bin
    env "$@" "${FAKE_BIN_DIR}/claude" "$secs" &
    FAKE_CLAUDE_PID=$!
    for _ in $(seq 1 40); do
        [ "$(cat "/proc/${FAKE_CLAUDE_PID}/comm" 2>/dev/null)" = "claude" ] && return 0
        sleep 0.05
    done
    return 1
}

# proc_starttime <pid> — /proc/<pid>/stat の22番目(comm名に空白が無い前提)
proc_starttime() {
    awk '{print $22}' "/proc/$1/stat"
}

# write_session_record <pid> <socket_path> [procStart] [記録上のpid]
# 対象pidのセッション記録(~/.claude/sessions/<pid>.jsonの形式)を、隔離した
# CLAUDE_CONFIG_DIR配下へ書く。procStartの既定は実プロセスのstarttime。
write_session_record() {
    local pid="$1" sock_path="$2"
    local start="${3:-$(proc_starttime "$pid")}"
    local rec_pid="${4:-$pid}"
    printf '{"pid":%s,"sessionId":"x","cwd":"/x","procStart":"%s","messagingSocketPath":"%s","name":"t"}' \
        "$rec_pid" "$start" "$sock_path" \
        > "${CLAUDE_CONFIG_DIR}/sessions/${pid}.json"
}

# ─────────────────────────────────────────────────────────────
# mesh_is_registered
# ─────────────────────────────────────────────────────────────

@test "mesh_is_registered: 実在するUNIXソケット → 0" {
    start_fake_socket_server "99999"
    run mesh_is_registered "99999"
    [ "$status" -eq 0 ]
}

@test "mesh_is_registered: ソケットファイルが無い → 1" {
    run mesh_is_registered "12345"
    [ "$status" -eq 1 ]
}

@test "mesh_is_registered: 同名の通常ファイル(ソケットでない) → 1" {
    touch "${MESH_SOCK_DIR}/54321.sock"
    run mesh_is_registered "54321"
    [ "$status" -eq 1 ]
}

@test "mesh_is_registered: pid空文字 → 1" {
    run mesh_is_registered ""
    [ "$status" -eq 1 ]
}

# ─────────────────────────────────────────────────────────────
# mesh_child_claude_pid
# ─────────────────────────────────────────────────────────────

@test "mesh_child_claude_pid: comm名claudeの直接子を1つ返す" {
    FAKE_BIN_DIR="$(mktemp -d)"
    cp "$(command -v sleep)" "${FAKE_BIN_DIR}/claude"
    chmod +x "${FAKE_BIN_DIR}/claude"
    "${FAKE_BIN_DIR}/claude" 2 &
    FAKE_CLAUDE_PID=$!

    result=$(mesh_child_claude_pid "$$")
    [ "$result" = "$FAKE_CLAUDE_PID" ]

    rm -rf "$FAKE_BIN_DIR"
}

@test "mesh_child_claude_pid: claude以外の子しか無い → 空文字" {
    sleep 2 &
    FAKE_OTHER_PID=$!

    result=$(mesh_child_claude_pid "$$")
    [ -z "$result" ]
}

@test "mesh_child_claude_pid: 子プロセスが無い → 空文字" {
    result=$(mesh_child_claude_pid "$$")
    [ -z "$result" ]
}

@test "mesh_child_claude_pid: 複数のclaude子(判定不能) → 空文字" {
    FAKE_BIN_DIR="$(mktemp -d)"
    cp "$(command -v sleep)" "${FAKE_BIN_DIR}/claude"
    chmod +x "${FAKE_BIN_DIR}/claude"
    "${FAKE_BIN_DIR}/claude" 2 &
    pid1=$!
    "${FAKE_BIN_DIR}/claude" 2 &
    pid2=$!

    result=$(mesh_child_claude_pid "$$")
    [ -z "$result" ]

    wait "$pid1" 2>/dev/null || true
    wait "$pid2" 2>/dev/null || true
    rm -rf "$FAKE_BIN_DIR"
}

@test "mesh_child_claude_pid: parent_pid空文字 → 空文字" {
    result=$(mesh_child_claude_pid "")
    [ -z "$result" ]
}

# ─────────────────────────────────────────────────────────────
# check_mesh_registration (mesh_pane_pidをtestダブルへ差し替えて分岐網羅)
# ★tmuxの実挙動そのもの(mesh_pane_pid)は関数として薄いラッパのみであり、
#   ここでは check_mesh_registration の合成ロジック(3分岐)を検査する。
# ─────────────────────────────────────────────────────────────

@test "check_mesh_registration: pane_pidが取れない → unregistered:pane_pid_not_found" {
    mesh_pane_pid() { echo ""; }
    run check_mesh_registration "dummy:pane"
    [ "$status" -eq 1 ]
    [ "$output" = "unregistered:pane_pid_not_found" ]
}

@test "check_mesh_registration: claude子が見つからない → unregistered:claude_pid_not_found" {
    mesh_pane_pid() { echo "424242"; }
    run check_mesh_registration "dummy:pane"
    [ "$status" -eq 1 ]
    [ "$output" = "unregistered:claude_pid_not_found" ]
}

@test "check_mesh_registration: claude子は在るがsocket未登録 → unregistered:no_socket:<pid>" {
    test_pid="$$"
    mesh_pane_pid() { echo "$test_pid"; }
    FAKE_BIN_DIR="$(mktemp -d)"
    cp "$(command -v sleep)" "${FAKE_BIN_DIR}/claude"
    chmod +x "${FAKE_BIN_DIR}/claude"
    "${FAKE_BIN_DIR}/claude" 2 &
    FAKE_CLAUDE_PID=$!

    run check_mesh_registration "dummy:pane"
    [ "$status" -eq 1 ]
    [ "$output" = "unregistered:no_socket:${FAKE_CLAUDE_PID}" ]

    rm -rf "$FAKE_BIN_DIR"
}

@test "check_mesh_registration: claude子・socket両方在る → registered:<pid>" {
    test_pid="$$"
    mesh_pane_pid() { echo "$test_pid"; }
    FAKE_BIN_DIR="$(mktemp -d)"
    cp "$(command -v sleep)" "${FAKE_BIN_DIR}/claude"
    chmod +x "${FAKE_BIN_DIR}/claude"
    "${FAKE_BIN_DIR}/claude" 3 &
    FAKE_CLAUDE_PID=$!
    start_fake_socket_server "$FAKE_CLAUDE_PID"

    run check_mesh_registration "dummy:pane"
    [ "$status" -eq 0 ]
    [ "$output" = "registered:${FAKE_CLAUDE_PID}" ]

    rm -rf "$FAKE_BIN_DIR"
}

# ─────────────────────────────────────────────────────────────
# mesh_pid_env_value / mesh_env_of (cmd_784 Phase 1)
# 対象pidの/proc/<pid>/environを、値を評価せず文字列として読む。
# 稼働中agentは使わず、環境変数付きで起動した偽claude(sleep複製)で検証する。
# ─────────────────────────────────────────────────────────────

@test "mesh_pid_env_value: 対象pidのenvironから値を取り出す" {
    clear_mesh_env
    spawn_fake_claude 2 XDG_RUNTIME_DIR="${TEST_TMP}/target-run/"
    run mesh_pid_env_value "$FAKE_CLAUDE_PID" XDG_RUNTIME_DIR
    [ "$status" -eq 0 ]
    [ "$output" = "${TEST_TMP}/target-run/" ]
}

@test "mesh_pid_env_value: 値は評価・展開されず文字列のまま返る" {
    clear_mesh_env
    local evil="${TEST_TMP}/a b/\$(touch ${TEST_TMP}/pwned)"
    spawn_fake_claude 2 XDG_RUNTIME_DIR="$evil"
    run mesh_pid_env_value "$FAKE_CLAUDE_PID" XDG_RUNTIME_DIR
    [ "$status" -eq 0 ]
    [ "$output" = "$evil" ]
    [ ! -e "${TEST_TMP}/pwned" ]
}

@test "mesh_pid_env_value: 対象が変数を持たない → 0・空出力(読めたが未設定)" {
    clear_mesh_env
    spawn_fake_claude 2
    run mesh_pid_env_value "$FAKE_CLAUDE_PID" XDG_RUNTIME_DIR
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "mesh_pid_env_value: pid空・存在しないpid・数字以外のpid・名前空 → 1" {
    run mesh_pid_env_value "" XDG_RUNTIME_DIR
    [ "$status" -eq 1 ]
    run mesh_pid_env_value "999999999" XDG_RUNTIME_DIR
    [ "$status" -eq 1 ]
    run mesh_pid_env_value "1/../$$" XDG_RUNTIME_DIR
    [ "$status" -eq 1 ]
    run mesh_pid_env_value "$$" ""
    [ "$status" -eq 1 ]
}

@test "mesh_pid_env_value: 名前は前方一致でなく完全一致(XDG_RUNTIME_DIR2は拾わない)" {
    clear_mesh_env
    spawn_fake_claude 2 XDG_RUNTIME_DIR2=/nope
    run mesh_pid_env_value "$FAKE_CLAUDE_PID" XDG_RUNTIME_DIR
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "mesh_env_of: 対象environが読めれば呼出側の値より優先・読めなければ呼出側へ退避" {
    clear_mesh_env
    export XDG_RUNTIME_DIR="/caller"
    spawn_fake_claude 2 XDG_RUNTIME_DIR=/target
    run mesh_env_of "$FAKE_CLAUDE_PID" XDG_RUNTIME_DIR
    [ "$output" = "/target" ]
    run mesh_env_of "999999999" XDG_RUNTIME_DIR
    [ "$output" = "/caller" ]
    run mesh_env_of "" XDG_RUNTIME_DIR
    [ "$output" = "/caller" ]
}

@test "mesh_env_of: 対象が読めて未設定なら呼出側の値へ退避しない" {
    clear_mesh_env
    export XDG_RUNTIME_DIR="/caller"
    spawn_fake_claude 2 -u XDG_RUNTIME_DIR
    run mesh_env_of "$FAKE_CLAUDE_PID" XDG_RUNTIME_DIR
    [ -z "$output" ]
}

# ─────────────────────────────────────────────────────────────
# 予測式(セッション記録が無い/使えない時): mesh_sock_dirs / mesh_sock_dir
#   base = XDG_RUNTIME_DIR || CLAUDE_CODE_TMPDIR || TMPDIR || /tmp
#   → <base>/cc-socks(末尾スラッシュ正規化)。退避候補 /tmp/cc-socks-<uid>。
#   MESH_SOCK_DIR明示が最優先。対象pidのenvironが読めればそれを基準にする。
# 存在しないpid(999999999)を渡すと記録なし・environ不読 = 呼出側環境の予測になる。
# ─────────────────────────────────────────────────────────────

@test "予測式: XDG_RUNTIME_DIRあり → <XDG_RUNTIME_DIR>/cc-socks が一次候補" {
    clear_mesh_env
    export XDG_RUNTIME_DIR="${TEST_TMP}/run"
    run mesh_sock_dir 999999999
    [ "$status" -eq 0 ]
    [ "$output" = "${TEST_TMP}/run/cc-socks" ]
}

@test "予測式: pid引数なしでも呼出側環境で予測できる" {
    clear_mesh_env
    export XDG_RUNTIME_DIR="${TEST_TMP}/run"
    run mesh_sock_dir
    [ "$output" = "${TEST_TMP}/run/cc-socks" ]
}

@test "予測式: 末尾スラッシュ(1個・複数個)を正規化する" {
    clear_mesh_env
    export XDG_RUNTIME_DIR="${TEST_TMP}/run/"
    run mesh_sock_dir 999999999
    [ "$output" = "${TEST_TMP}/run/cc-socks" ]

    export XDG_RUNTIME_DIR="${TEST_TMP}/run///"
    run mesh_sock_dir 999999999
    [ "$output" = "${TEST_TMP}/run/cc-socks" ]
}

@test "予測式: XDG無し・CLAUDE_CODE_TMPDIRあり → <CLAUDE_CODE_TMPDIR>/cc-socks" {
    clear_mesh_env
    export CLAUDE_CODE_TMPDIR="${TEST_TMP}/cct/"
    export TMPDIR="${TEST_TMP}/tmpdir"
    run mesh_sock_dir 999999999
    [ "$output" = "${TEST_TMP}/cct/cc-socks" ]
}

@test "予測式: XDG・CLAUDE_CODE_TMPDIR無し・TMPDIRあり → <TMPDIR>/cc-socks" {
    clear_mesh_env
    export TMPDIR="${TEST_TMP}/tmpdir/"
    run mesh_sock_dir 999999999
    [ "$output" = "${TEST_TMP}/tmpdir/cc-socks" ]
}

@test "予測式: 全て無し → /tmp/cc-socks(uidなし)" {
    clear_mesh_env
    run mesh_sock_dir 999999999
    [ "$output" = "/tmp/cc-socks" ]
}

@test "予測式: 優先順は XDG_RUNTIME_DIR > CLAUDE_CODE_TMPDIR > TMPDIR" {
    clear_mesh_env
    export XDG_RUNTIME_DIR="${TEST_TMP}/x" CLAUDE_CODE_TMPDIR="${TEST_TMP}/c" TMPDIR="${TEST_TMP}/t"
    run mesh_sock_dir 999999999
    [ "$output" = "${TEST_TMP}/x/cc-socks" ]
    unset XDG_RUNTIME_DIR
    run mesh_sock_dir 999999999
    [ "$output" = "${TEST_TMP}/c/cc-socks" ]
}

@test "予測式: 空文字の変数は未設定扱いで飛ばす" {
    clear_mesh_env
    export XDG_RUNTIME_DIR="" CLAUDE_CODE_TMPDIR="${TEST_TMP}/c"
    run mesh_sock_dir 999999999
    [ "$output" = "${TEST_TMP}/c/cc-socks" ]
    export CLAUDE_CODE_TMPDIR=""
    run mesh_sock_dir 999999999
    [ "$output" = "/tmp/cc-socks" ]
}

@test "予測式: 退避候補 /tmp/cc-socks-<uid> が2番目に並ぶ(uidはid -u由来・1000決め打ちでない)" {
    clear_mesh_env
    export XDG_RUNTIME_DIR="${TEST_TMP}/run"
    id() { echo 4242; }
    run mesh_sock_dirs 999999999
    [ "${lines[0]}" = "${TEST_TMP}/run/cc-socks" ]
    [ "${lines[1]}" = "/tmp/cc-socks-4242" ]
    [ "${#lines[@]}" -eq 2 ]
}

@test "予測式: MESH_SOCK_DIR明示は最優先(候補はその1件のみ)" {
    clear_mesh_env
    export MESH_SOCK_DIR="${TEST_TMP}/explicit"
    export XDG_RUNTIME_DIR="${TEST_TMP}/run"
    run mesh_sock_dirs 999999999
    [ "$output" = "${TEST_TMP}/explicit" ]
    [ "${#lines[@]}" -eq 1 ]
}

@test "予測式: 対象pidのenvironのXDG_RUNTIME_DIRを基準にする(呼出側環境より優先・末尾スラッシュ正規化)" {
    clear_mesh_env
    export XDG_RUNTIME_DIR="${TEST_TMP}/caller-run"
    spawn_fake_claude 2 XDG_RUNTIME_DIR="${TEST_TMP}/target-run/"
    run mesh_sock_dir "$FAKE_CLAUDE_PID"
    [ "$output" = "${TEST_TMP}/target-run/cc-socks" ]
}

@test "予測式: 対象pidが何も持たない → 呼出側の値へ退避せず /tmp/cc-socks" {
    clear_mesh_env
    export XDG_RUNTIME_DIR="${TEST_TMP}/caller-run" TMPDIR="${TEST_TMP}/caller-tmp"
    spawn_fake_claude 2 -u XDG_RUNTIME_DIR -u TMPDIR -u CLAUDE_CODE_TMPDIR
    run mesh_sock_dir "$FAKE_CLAUDE_PID"
    [ "$output" = "/tmp/cc-socks" ]
}

@test "予測式: 対象pidのenvironが読めない(存在しないpid) → 呼出側のXDG_RUNTIME_DIRへ退避" {
    clear_mesh_env
    export XDG_RUNTIME_DIR="${TEST_TMP}/caller-run/"
    run mesh_sock_dir 999999999
    [ "$output" = "${TEST_TMP}/caller-run/cc-socks" ]
}

@test "予測式: MESH_SOCK_DIR明示は対象pidのenvironよりも優先" {
    clear_mesh_env
    spawn_fake_claude 2 XDG_RUNTIME_DIR="${TEST_TMP}/target-run"
    export MESH_SOCK_DIR="${TEST_TMP}/explicit"
    run mesh_sock_dir "$FAKE_CLAUDE_PID"
    [ "$output" = "${TEST_TMP}/explicit" ]
}

# ─────────────────────────────────────────────────────────────
# セッション記録 (~/.claude/sessions/<pid>.json の messagingSocketPath)
#   本体が実際にbindしたパスの記録。有効なら予測式より優先する。
#   有効条件: pid一致・procStartが/proc/<pid>/statのstarttimeと一致・
#   絶対パス・basenameが<pid>.sock。試験ではCLAUDE_CONFIG_DIRを隔離dirへ向ける。
# ─────────────────────────────────────────────────────────────

@test "記録: 有効な記録があれば予測式(XDG)より優先してその置場を返す" {
    clear_mesh_env
    spawn_fake_claude 2 XDG_RUNTIME_DIR="${TEST_TMP}/xdg-run/"
    write_session_record "$FAKE_CLAUDE_PID" "${TEST_TMP}/recorded/cc-socks/${FAKE_CLAUDE_PID}.sock"

    run mesh_recorded_sock_dir "$FAKE_CLAUDE_PID"
    [ "$status" -eq 0 ]
    [ "$output" = "${TEST_TMP}/recorded/cc-socks" ]

    run mesh_sock_dirs "$FAKE_CLAUDE_PID"
    [ "$output" = "${TEST_TMP}/recorded/cc-socks" ]
    [ "${#lines[@]}" -eq 1 ]
}

@test "記録: MESH_SOCK_DIR明示は記録よりも優先" {
    clear_mesh_env
    spawn_fake_claude 2
    write_session_record "$FAKE_CLAUDE_PID" "${TEST_TMP}/recorded/cc-socks/${FAKE_CLAUDE_PID}.sock"
    export MESH_SOCK_DIR="${TEST_TMP}/explicit"
    run mesh_sock_dir "$FAKE_CLAUDE_PID"
    [ "$output" = "${TEST_TMP}/explicit" ]
}

@test "記録: 記録が示す場所のsocketを見つけて registered(MESH_SOCK_DIR未設定)" {
    clear_mesh_env
    test_pid="$$"
    mesh_pane_pid() { echo "$test_pid"; }
    spawn_fake_claude 3 XDG_RUNTIME_DIR="${TEST_TMP}/xdg-run/"
    local rec_dir="${TEST_TMP}/recorded/cc-socks"
    mkdir -p "$rec_dir"
    write_session_record "$FAKE_CLAUDE_PID" "${rec_dir}/${FAKE_CLAUDE_PID}.sock"
    start_fake_socket_at "${rec_dir}/${FAKE_CLAUDE_PID}.sock"

    run check_mesh_registration "dummy:pane"
    [ "$status" -eq 0 ]
    [ "$output" = "registered:${FAKE_CLAUDE_PID}" ]
}

# cmd_784の真因B: 記録が示す置場(runtime dir)が撤去されて socket が消えた状態。
# 予測式のXDG側に別のsocketがあっても、記録が権威であり「未登録」が正しい。
@test "記録: 記録が示す場所にsocketが無ければ、予測式側にsocketがあっても unregistered:no_socket" {
    clear_mesh_env
    test_pid="$$"
    mesh_pane_pid() { echo "$test_pid"; }
    local xdg_run="${TEST_TMP}/xdg-run"
    mkdir -p "${xdg_run}/cc-socks"
    spawn_fake_claude 3 XDG_RUNTIME_DIR="${xdg_run}/"
    write_session_record "$FAKE_CLAUDE_PID" "${TEST_TMP}/removed-runtime-dir/cc-socks/${FAKE_CLAUDE_PID}.sock"
    start_fake_socket_at "${xdg_run}/cc-socks/${FAKE_CLAUDE_PID}.sock"

    run check_mesh_registration "dummy:pane"
    [ "$status" -eq 1 ]
    [ "$output" = "unregistered:no_socket:${FAKE_CLAUDE_PID}" ]
}

@test "記録: procStartが実プロセスと不一致(pid再利用の古い記録) → 無視して予測式" {
    clear_mesh_env
    spawn_fake_claude 2 XDG_RUNTIME_DIR="${TEST_TMP}/xdg-run"
    write_session_record "$FAKE_CLAUDE_PID" "${TEST_TMP}/stale/cc-socks/${FAKE_CLAUDE_PID}.sock" "1"
    run mesh_recorded_sock_dir "$FAKE_CLAUDE_PID"
    [ "$status" -eq 1 ]
    run mesh_sock_dir "$FAKE_CLAUDE_PID"
    [ "$output" = "${TEST_TMP}/xdg-run/cc-socks" ]
}

@test "記録: 記録上のpidが対象と違う → 無視して予測式" {
    clear_mesh_env
    spawn_fake_claude 2 XDG_RUNTIME_DIR="${TEST_TMP}/xdg-run"
    write_session_record "$FAKE_CLAUDE_PID" "${TEST_TMP}/other/cc-socks/${FAKE_CLAUDE_PID}.sock" "" "1"
    run mesh_recorded_sock_dir "$FAKE_CLAUDE_PID"
    [ "$status" -eq 1 ]
    run mesh_sock_dir "$FAKE_CLAUDE_PID"
    [ "$output" = "${TEST_TMP}/xdg-run/cc-socks" ]
}

@test "記録: basenameが<pid>.sockでない → 無視して予測式" {
    clear_mesh_env
    spawn_fake_claude 2 XDG_RUNTIME_DIR="${TEST_TMP}/xdg-run"
    write_session_record "$FAKE_CLAUDE_PID" "${TEST_TMP}/x/cc-socks/99.sock"
    run mesh_recorded_sock_dir "$FAKE_CLAUDE_PID"
    [ "$status" -eq 1 ]
    run mesh_sock_dir "$FAKE_CLAUDE_PID"
    [ "$output" = "${TEST_TMP}/xdg-run/cc-socks" ]
}

@test "記録: 相対パス → 無視して予測式" {
    clear_mesh_env
    spawn_fake_claude 2 XDG_RUNTIME_DIR="${TEST_TMP}/xdg-run"
    write_session_record "$FAKE_CLAUDE_PID" "rel/cc-socks/${FAKE_CLAUDE_PID}.sock"
    run mesh_recorded_sock_dir "$FAKE_CLAUDE_PID"
    [ "$status" -eq 1 ]
}

@test "記録: messagingSocketPathキーが無い記録 → 無視して予測式" {
    clear_mesh_env
    spawn_fake_claude 2 XDG_RUNTIME_DIR="${TEST_TMP}/xdg-run"
    printf '{"pid":%s,"procStart":"%s","name":"t"}' "$FAKE_CLAUDE_PID" "$(proc_starttime "$FAKE_CLAUDE_PID")" \
        > "${CLAUDE_CONFIG_DIR}/sessions/${FAKE_CLAUDE_PID}.json"
    run mesh_recorded_sock_dir "$FAKE_CLAUDE_PID"
    [ "$status" -eq 1 ]
    run mesh_sock_dir "$FAKE_CLAUDE_PID"
    [ "$output" = "${TEST_TMP}/xdg-run/cc-socks" ]
}

@test "記録: procStartが無い記録は検証不能として無視" {
    clear_mesh_env
    spawn_fake_claude 2
    printf '{"pid":%s,"messagingSocketPath":"%s/r/%s.sock"}' "$FAKE_CLAUDE_PID" "$TEST_TMP" "$FAKE_CLAUDE_PID" \
        > "${CLAUDE_CONFIG_DIR}/sessions/${FAKE_CLAUDE_PID}.json"
    run mesh_recorded_sock_dir "$FAKE_CLAUDE_PID"
    [ "$status" -eq 1 ]
}

@test "記録: 記録ファイルが無い・壊れている → 予測式へ退避" {
    clear_mesh_env
    spawn_fake_claude 2 XDG_RUNTIME_DIR="${TEST_TMP}/xdg-run"
    run mesh_recorded_sock_dir "$FAKE_CLAUDE_PID"
    [ "$status" -eq 1 ]

    printf 'this is not json {{{' > "${CLAUDE_CONFIG_DIR}/sessions/${FAKE_CLAUDE_PID}.json"
    run mesh_recorded_sock_dir "$FAKE_CLAUDE_PID"
    [ "$status" -eq 1 ]
    run mesh_sock_dir "$FAKE_CLAUDE_PID"
    [ "$output" = "${TEST_TMP}/xdg-run/cc-socks" ]
}

@test "記録: 整形済み(複数行・コロン前後に空白)JSONとprocStartの数値表記も受理する" {
    clear_mesh_env
    spawn_fake_claude 2
    local start
    start="$(proc_starttime "$FAKE_CLAUDE_PID")"
    cat > "${CLAUDE_CONFIG_DIR}/sessions/${FAKE_CLAUDE_PID}.json" <<JSON
{
  "pid" : ${FAKE_CLAUDE_PID},
  "procStart" : ${start},
  "messagingSocketPath" : "${TEST_TMP}/pretty/cc-socks/${FAKE_CLAUDE_PID}.sock"
}
JSON
    run mesh_recorded_sock_dir "$FAKE_CLAUDE_PID"
    [ "$status" -eq 0 ]
    [ "$output" = "${TEST_TMP}/pretty/cc-socks" ]
}

@test "記録: 値は評価・展開されず文字列として扱う(\$(...)・空白を含むパス)" {
    clear_mesh_env
    spawn_fake_claude 2
    local evil_dir="${TEST_TMP}/a b/\$(touch ${TEST_TMP}/pwned)/cc-socks"
    write_session_record "$FAKE_CLAUDE_PID" "${evil_dir}/${FAKE_CLAUDE_PID}.sock"
    run mesh_recorded_sock_dir "$FAKE_CLAUDE_PID"
    [ "$status" -eq 0 ]
    [ "$output" = "$evil_dir" ]
    [ ! -e "${TEST_TMP}/pwned" ]
}

@test "記録: エスケープ(バックスラッシュ)を含む文字列値は解釈せず無視" {
    clear_mesh_env
    spawn_fake_claude 2
    printf '{"pid":%s,"procStart":"%s","messagingSocketPath":"/a\\\\b/cc-socks/%s.sock"}' \
        "$FAKE_CLAUDE_PID" "$(proc_starttime "$FAKE_CLAUDE_PID")" "$FAKE_CLAUDE_PID" \
        > "${CLAUDE_CONFIG_DIR}/sessions/${FAKE_CLAUDE_PID}.json"
    run mesh_recorded_sock_dir "$FAKE_CLAUDE_PID"
    [ "$status" -eq 1 ]
}

@test "記録: 記録の探索先(CLAUDE_CONFIG_DIR)も対象pidのenvironを基準にする" {
    clear_mesh_env
    local target_cfg="${TEST_TMP}/target-config"
    mkdir -p "${target_cfg}/sessions"
    spawn_fake_claude 2 CLAUDE_CONFIG_DIR="$target_cfg"
    # setupの隔離dir(呼出側)には置かず、対象のenvironが指す方へだけ置く
    printf '{"pid":%s,"procStart":"%s","messagingSocketPath":"%s/t/cc-socks/%s.sock"}' \
        "$FAKE_CLAUDE_PID" "$(proc_starttime "$FAKE_CLAUDE_PID")" "$TEST_TMP" "$FAKE_CLAUDE_PID" \
        > "${target_cfg}/sessions/${FAKE_CLAUDE_PID}.json"
    run mesh_recorded_sock_dir "$FAKE_CLAUDE_PID"
    [ "$status" -eq 0 ]
    [ "$output" = "${TEST_TMP}/t/cc-socks" ]
}

@test "記録: pidが数字でない・空 → 1(パス組み立てに使わない)" {
    run mesh_recorded_sock_dir ""
    [ "$status" -eq 1 ]
    run mesh_recorded_sock_dir "../../etc/passwd"
    [ "$status" -eq 1 ]
}

# ─────────────────────────────────────────────────────────────
# mesh_is_registered / check_mesh_registration の結合
# ─────────────────────────────────────────────────────────────

@test "mesh_is_registered: 記録が無くても対象pidのXDG_RUNTIME_DIR配下のsocketを見つける(予測式)" {
    clear_mesh_env
    local xdg_run="${TEST_TMP}/xdg-run"
    mkdir -p "${xdg_run}/cc-socks"
    spawn_fake_claude 3 XDG_RUNTIME_DIR="${xdg_run}/"
    start_fake_socket_at "${xdg_run}/cc-socks/${FAKE_CLAUDE_PID}.sock"

    run mesh_is_registered "$FAKE_CLAUDE_PID"
    [ "$status" -eq 0 ]
}

@test "mesh_is_registered: 候補dirのうち後ろの候補にsocketがあれば登録済み" {
    clear_mesh_env
    local d1="${TEST_TMP}/cand1" d2="${TEST_TMP}/cand2"
    mkdir -p "$d1" "$d2"
    mesh_sock_dirs() { printf '%s\n' "$d1" "$d2"; }
    start_fake_socket_at "${d2}/777.sock"

    run mesh_is_registered "777"
    [ "$status" -eq 0 ]
    run mesh_is_registered "778"
    [ "$status" -eq 1 ]
}

# cmd_784の誤検知の再現防止: 旧実装は置場を/tmp/cc-socks-1000へ固定しており、
# 対象が別の置場(XDG_RUNTIME_DIR配下)にbindしていると未登録と誤判定した。
@test "check_mesh_registration: 対象がXDG_RUNTIME_DIR配下へbindしたsocket → registered(旧置場固定の誤検知を再現させない)" {
    clear_mesh_env
    export XDG_RUNTIME_DIR="${TEST_TMP}/caller-run-unrelated"
    test_pid="$$"
    mesh_pane_pid() { echo "$test_pid"; }
    local target_run="${TEST_TMP}/target-run"
    mkdir -p "${target_run}/cc-socks"
    spawn_fake_claude 3 XDG_RUNTIME_DIR="${target_run}/"
    start_fake_socket_at "${target_run}/cc-socks/${FAKE_CLAUDE_PID}.sock"

    run check_mesh_registration "dummy:pane"
    [ "$status" -eq 0 ]
    [ "$output" = "registered:${FAKE_CLAUDE_PID}" ]
}

@test "check_mesh_registration: socketが対象の置場と別の場所にだけ在る → unregistered:no_socket:<pid>(出力形式は不変)" {
    clear_mesh_env
    test_pid="$$"
    mesh_pane_pid() { echo "$test_pid"; }
    local target_run="${TEST_TMP}/target-run" other_run="${TEST_TMP}/other-run"
    mkdir -p "${target_run}/cc-socks" "${other_run}/cc-socks"
    spawn_fake_claude 3 XDG_RUNTIME_DIR="${target_run}/"
    start_fake_socket_at "${other_run}/cc-socks/${FAKE_CLAUDE_PID}.sock"

    run check_mesh_registration "dummy:pane"
    [ "$status" -eq 1 ]
    [ "$output" = "unregistered:no_socket:${FAKE_CLAUDE_PID}" ]
}
