#!/usr/bin/env bats
# ═══════════════════════════════════════════════════════════════
# E2E-009: OpenCode CLI — /new も startup prompt も自動では送らぬ
# ═══════════════════════════════════════════════════════════════
# ★契約の改訂 (cmd_754 E-1 / 2026-09-08):
#   本ファイルは元来「inbox_watcher が /new を送り、nudge を送る」ことを
#   ★正常系として検査していた。その前提は失効した。自動打鍵の安全集合は
#   空である (2026-09-08 の誤爆事故と将軍裁定 E-1)。
#
#   現契約における OpenCode:
#     - Stop hook ✕ / agent 自前の self-watch ✕ / 自動打鍵 ✕
#     - ★自動で配送するものは何も無い → 人経路のみ
#   ゆえに watcher が行うのは「送れぬことを記録し、人が何をすればよいかを
#   添えて滞留を人へ上げる」ことだけである。
#
#   本試験が確かめるもの:
#     1. context reset (/new) を★送らないこと、その旨と人の手順が残ること
#     2. startup prompt を★送らないこと
#     3. 配送経路が無い CLI として未配送に数えられること
#     4. 誰も打たぬゆえタスクは assigned のまま、未読も保持されること
#   正本: docs/delivery_channels.md
# ═══════════════════════════════════════════════════════════════

# bats file_tags=e2e

load "../test_helper/bats-support/load"
load "../test_helper/bats-assert/load"

# Load E2E helpers
E2E_HELPERS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/helpers" && pwd)"
source "$E2E_HELPERS_DIR/setup.bash"
source "$E2E_HELPERS_DIR/assertions.bash"
source "$E2E_HELPERS_DIR/tmux_helpers.bash"

# ─── Lifecycle ───

setup_file() {
    command -v tmux &>/dev/null || skip "tmux not available"
    command -v python3 &>/dev/null || skip "python3 not available"
    python3 -c "import yaml" 2>/dev/null || skip "python3-yaml not available"

    setup_e2e_session 3
}

teardown_file() {
    teardown_e2e_session
}

setup() {
    reset_queues
    sleep 1
}

dump_watcher_log() {
    local log_file="$1"
    echo "=== Watcher log ($log_file) ===" >&2
    cat "$log_file" >&2 2>/dev/null || echo "(log not found)" >&2
    echo "=== End watcher log ===" >&2
}

wait_for_log() {
    local log_file="$1" pattern="$2" timeout="${3:-30}"
    local elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        if grep -qF "$pattern" "$log_file" 2>/dev/null; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    echo "TIMEOUT: '$pattern' not found in $log_file after ${timeout}s" >&2
    dump_watcher_log "$log_file"
    return 1
}

# ═══════════════════════════════════════════════════════════════
# E2E-009-A: OpenCode 宛の task_assigned は自動配送されず人経路へ倒れる
# ═══════════════════════════════════════════════════════════════

@test "E2E-009-A: OpenCode へは /new も nudge も送られず、人経路へ倒れる" {
    local ashigaru1_pane
    ashigaru1_pane=$(pane_target 1)

    # 1. Respawn pane with OpenCode mock
    tmux respawn-pane -k -t "$ashigaru1_pane" \
        "MOCK_CLI_TYPE=opencode MOCK_AGENT_ID=ashigaru1 MOCK_PROCESSING_DELAY=1 MOCK_PROJECT_ROOT=$E2E_QUEUE bash $PROJECT_ROOT/tests/e2e/mock_cli.sh"
    sleep 2
    tmux set-option -p -t "$ashigaru1_pane" @agent_cli "opencode"

    # 2. Place assigned task YAML
    cp "$PROJECT_ROOT/tests/e2e/fixtures/task_ashigaru1_basic.yaml" \
       "$E2E_QUEUE/queue/tasks/ashigaru1.yaml"

    # 3. Send task_assigned message via inbox_write
    bash "$E2E_QUEUE/scripts/inbox_write.sh" "ashigaru1" \
        "タスクYAMLを読んで作業開始せよ。" "task_assigned" "karo"

    # 4. Start inbox_watcher with OpenCode CLI type
    local watcher_pid log_file
    watcher_pid=$(start_inbox_watcher "ashigaru1" 1 "opencode")
    log_file="/tmp/e2e_inbox_watcher_ashigaru1_$$.log"

    # 5. context reset (/new) は★送らない。送らぬ旨と人の手順がログに残る。
    run wait_for_log "$log_file" "[NO-AUTO-SEND] ashigaru1: 新タスク前の context reset(/new)は自動では送らぬ"
    assert_success
    run wait_for_log "$log_file" "必要なら人手で /new を入力されたし"
    assert_success

    # 6. OpenCode には配送経路が無い。未配送として数えられる。
    run wait_for_log "$log_file" "未読1件の起床通知 (cli=opencode) は自動では配送せぬ (理由=no_delivery_channel"
    assert_success

    # 7. 旧契約の打鍵ログ(★/new 送信・startup prompt)は一つも無い
    run grep "CONTEXT-RESET.*Sending /new" "$log_file"
    assert_failure

    run grep "Sending startup prompt" "$log_file"
    assert_failure

    run grep -qE "\[SEND-KEYS\]" "$log_file"
    [ "$status" -ne 0 ]

    # 8. 誰も打鍵せぬゆえ mock は動かず、タスクは assigned・未読は保持される
    run wait_for_yaml_value "$E2E_QUEUE/queue/tasks/ashigaru1.yaml" "task.status" "assigned" 10
    assert_success
    run assert_inbox_unread_count "$E2E_QUEUE/queue/inbox/ashigaru1.yaml" 1
    assert_success

    # 9. OpenCode 版 mock は起動しており、入力待ちのまま止まっている
    #    (「動いていないから届かない」のではなく「届けていない」ことの確認)
    run wait_for_pane_text "$ashigaru1_pane" "Ask anything" 10
    if [ "$status" -ne 0 ]; then
        dump_watcher_log "$log_file"
    fi
    assert_success

    # Cleanup
    stop_inbox_watcher "$watcher_pid"
}
