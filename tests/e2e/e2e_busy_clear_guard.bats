#!/usr/bin/env bats
# ═══════════════════════════════════════════════════════════════
# E2E-009: clear_command は自動送信されず、未読のまま保持される
# ═══════════════════════════════════════════════════════════════
# ★契約の改訂 (cmd_754 E-1 / 2026-09-08):
#   本ファイルは元来「busy中は /clear を抑止し、idle なら送信する」という
#   ★条件付き送信の試験であった。その前提は失効した。2026-09-08、確認
#   モーダル表示中の pane へ inbox_watcher が送った Enter が既定選択肢
#   `❯ 1. Yes` を選び、D002-E1 違反の削除が実際に実行された。以後4世代に
#   わたり「画面から安全を証明する」試みを重ねたが4度とも破れ、将軍は
#   ★自動打鍵の安全集合を空とする裁定を下した。
#
#   現契約: inbox_watcher は clear_command / model_switch / cli_restart を
#   ★busy でも idle でも送らない。メッセージは `read: false` のまま保持され、
#   「人手で当該 pane へ入力されたし」という案内を添えて人経路へ上がる。
#   届かなかった命令を既読にすることは、命令を消すことである。
#
#   ゆえに本ファイルが確かめるのは次の2点である:
#     A) 作業中(busy)でも /clear は送られず、未読のまま残る
#     B) 待機中(idle)でも★同じく送られず、未読のまま残る
#        ——idle は例外ではない。安全集合は空である。
#   正本: docs/delivery_channels.md
# ═══════════════════════════════════════════════════════════════

# bats file_tags=e2e

load "../test_helper/bats-support/load"
load "../test_helper/bats-assert/load"

E2E_HELPERS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/helpers" && pwd)"
source "$E2E_HELPERS_DIR/setup.bash"
source "$E2E_HELPERS_DIR/assertions.bash"
source "$E2E_HELPERS_DIR/tmux_helpers.bash"

setup_file() {
    command -v tmux &>/dev/null || skip "tmux not available"
    command -v python3 &>/dev/null || skip "python3 not available"
    python3 -c "import yaml" 2>/dev/null || skip "python3-yaml not available"

    setup_e2e_session 2
    mkdir -p "$E2E_QUEUE/.venv/bin"
    ln -sf "$(command -v python3)" "$E2E_QUEUE/.venv/bin/python3"
}

teardown_file() {
    teardown_e2e_session
}

setup() {
    reset_queues
    mkdir -p "$E2E_QUEUE/.venv/bin"
    ln -sf "$(command -v python3)" "$E2E_QUEUE/.venv/bin/python3"
    sleep 2
}

wait_for_log() {
    local log_file="$1" pattern="$2" timeout="${3:-20}"
    local elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        if grep -qF "$pattern" "$log_file" 2>/dev/null; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    echo "TIMEOUT: '$pattern' not found in $log_file after ${timeout}s" >&2
    cat "$log_file" >&2 2>/dev/null || true
    return 1
}

# ═══ E2E-009-A: 作業中(busy)の clear_command は送られず未読で保持される ═══

@test "E2E-009-A: 作業中の clear_command は送られず、未読のまま保持される" {
    local ashigaru1_pane
    ashigaru1_pane=$(pane_target 1)
    local log_file watcher_pid

    cp "$PROJECT_ROOT/tests/e2e/fixtures/task_ashigaru1_basic.yaml" \
        "$E2E_QUEUE/queue/tasks/ashigaru1.yaml"

    # clear_command が届く前に mock を作業中にしておく。
    send_to_pane "$ashigaru1_pane" "busy_hold 15"
    sleep 2

    tmux set-option -p -t "$ashigaru1_pane" @agent_cli "copilot"
    log_file="/tmp/e2e_inbox_watcher_ashigaru1_busy_${BASHPID}.log"
    watcher_pid=$(
        bash "$E2E_QUEUE/scripts/inbox_watcher.sh" "ashigaru1" "$ashigaru1_pane" "copilot" \
            > "$log_file" 2>&1 &
        echo $!
    )
    sleep 2

    bash "$E2E_QUEUE/scripts/inbox_write.sh" "ashigaru1" \
        "/clear" "clear_command" "karo"

    # 1. 自動では送らぬことがログに残る
    run wait_for_log "$log_file" "[NO-AUTO-SEND] ashigaru1: CLIコマンド(/clear)は自動では送らぬ"
    assert_success

    # 2. 人が何をすればよいかが添えられている (「たぶん次サイクルで届く」ではない)
    run wait_for_log "$log_file" "人手で ashigaru1 の pane へ /clear を入力されたし"
    assert_success

    # 3. 未送信のまま未読で保持する (既読化は命令を消すことである)
    run wait_for_log "$log_file" "[NO-AUTO-SEND-DEFER] ashigaru1: clear_command を未送信のまま未読で保持する"
    assert_success

    # 4. メッセージは read: false のまま残っている
    run assert_inbox_unread_count "$E2E_QUEUE/queue/inbox/ashigaru1.yaml" 1
    assert_success

    # 5. /clear は届かぬゆえ mock は context reset せず、タスクは assigned のまま
    run wait_for_yaml_value "$E2E_QUEUE/queue/tasks/ashigaru1.yaml" "task.status" "assigned" 10
    assert_success

    # 6. 旧契約の打鍵ログは一つも無い (安全集合は空である)
    run grep -qE "\[SEND-KEYS\]" "$log_file"
    [ "$status" -ne 0 ]

    stop_inbox_watcher "$watcher_pid"
}

# ═══ E2E-009-B: 待機中(idle)でも clear_command は送られない ═══
# ★idle は例外ではない。旧契約ではここで /clear を送っていた。

@test "E2E-009-B: 待機中でも clear_command は送られず、未読のまま保持される" {
    local ashigaru1_pane
    ashigaru1_pane=$(pane_target 1)
    local log_file watcher_pid
    local idle_flag="/tmp/shogun_idle_ashigaru1"

    touch "$idle_flag"

    cp "$PROJECT_ROOT/tests/e2e/fixtures/task_ashigaru1_basic.yaml" \
        "$E2E_QUEUE/queue/tasks/ashigaru1.yaml"

    tmux set-option -p -t "$ashigaru1_pane" @agent_cli "claude"
    log_file="/tmp/e2e_inbox_watcher_ashigaru1_idle_${BASHPID}.log"
    watcher_pid=$(
        bash "$E2E_QUEUE/scripts/inbox_watcher.sh" "ashigaru1" "$ashigaru1_pane" "claude" \
            > "$log_file" 2>&1 &
        echo $!
    )
    sleep 2

    bash "$E2E_QUEUE/scripts/inbox_write.sh" "ashigaru1" \
        "/clear" "clear_command" "karo"

    # 1. idle であっても自動送信はしない
    run wait_for_log "$log_file" "[NO-AUTO-SEND] ashigaru1: CLIコマンド(/clear)は自動では送らぬ (cli=claude)"
    assert_success

    # 2. Claude は Stop hook を持つが、それは★未読を本人へ食わせる経路であり、
    #    pane へ /clear を打つ経路ではない。人の入力が要ることを案内する。
    run wait_for_log "$log_file" "人手で ashigaru1 の pane へ /clear を入力されたし"
    assert_success

    # 3. 特殊命令だけが未読として残る周期でも、未配送カウンタは戻さない
    #    (戻せばこの滞留は永久に閾値へ届かず、人へ一度も上がらぬ)
    run wait_for_log "$log_file" "未読1件は特殊命令のみ (人手の入力が要る)。カウンタは戻さぬ"
    assert_success

    # 4. メッセージは read: false のまま残っている
    run assert_inbox_unread_count "$E2E_QUEUE/queue/inbox/ashigaru1.yaml" 1
    assert_success

    # 5. 旧契約では /clear 送信により mock が Session Start をやり直し
    #    タスクが done になっていた。今は誰も打たぬゆえ assigned のままである。
    run wait_for_yaml_value "$E2E_QUEUE/queue/tasks/ashigaru1.yaml" "task.status" "assigned" 10
    assert_success

    # 6. 旧契約の打鍵ログが無いこと
    run grep -qF "[SEND-KEYS] Sending CLI command to ashigaru1 (claude): /clear" "$log_file"
    [ "$status" -ne 0 ]

    stop_inbox_watcher "$watcher_pid"
    rm -f "$idle_flag"
}
