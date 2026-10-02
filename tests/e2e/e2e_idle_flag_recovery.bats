#!/usr/bin/env bats
# ═══════════════════════════════════════════════════════════════
# E2E-010: idle フラグの生成・保持と、誤 busy からの復帰
# ═══════════════════════════════════════════════════════════════
# ★契約の改訂 (cmd_754 E-1 / 2026-09-08):
#   本ファイルは元来「watcher が /clear を送り、その処理を経て idle フラグが
#   戻る」ことを検査していた。自動打鍵は★全廃したため、その経路は無い。
#
#   打鍵が消えても idle フラグ自体は要る。フラグは「Stop hook に委ねてよいか」
#   「滞留時計を進めてよいか」の判断に使われ続けるからである。むしろ打鍵が
#   無くなった今、フラグを消す経路(旧: nudge 送信後の削除)も消えた。
#
#   本ファイルが確かめるもの:
#     A) 起動時に初期 idle フラグが作られ、未配送の周期を跨いでも消えない
#     B) 誤 busy が長引いたときフラグを強制生成し、滞留を人経路へ倒す
#   ★どちらの試験でも「タスクが done になる」ことは期待しない。誰も打鍵
#     せぬ以上 mock は動かぬ。それが裁定どおりの帰結である。
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
}

teardown_file() {
    teardown_e2e_session
}

setup() {
    reset_queues
    sleep 1
}

wait_for_file_within() {
    local target="$1" timeout="${2:-20}"
    local elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        [ -f "$target" ] && return 0
        sleep 1
        elapsed=$((elapsed + 1))
    done
    echo "TIMEOUT: file not found: $target" >&2
    return 1
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

# ═══ E2E-010-A: 初期 idle フラグは生成され、未配送の周期を跨いでも消えない ═══

@test "E2E-010-A: 起動時に idle フラグが作られ、未配送の周期を跨いでも消えぬ" {
    local ashigaru1_pane
    ashigaru1_pane=$(pane_target 1)
    local flag_dir log_file watcher_pid

    flag_dir="$(mktemp -d "/tmp/e2e_idle_flags_XXXXXX")"
    local ashigaru_idle_flag="$flag_dir/shogun_idle_ashigaru1"

    cp "$PROJECT_ROOT/tests/e2e/fixtures/task_ashigaru1_basic.yaml" \
        "$E2E_QUEUE/queue/tasks/ashigaru1.yaml"

    log_file="/tmp/e2e_inbox_watcher_ashigaru1_clear_${BASHPID}.log"
    watcher_pid=$(
        IDLE_FLAG_DIR="$flag_dir" \
        bash "$E2E_QUEUE/scripts/inbox_watcher.sh" "ashigaru1" "$ashigaru1_pane" "claude" \
            > "$log_file" 2>&1 &
        echo $!
    )
    sleep 1

    # 1. 起動時に初期フラグが作られる (welcome 画面での誤 busy を防ぐため)
    run wait_for_log "$log_file" "Created initial idle flag for ashigaru1"
    assert_success
    run wait_for_file_within "$ashigaru_idle_flag" 10
    assert_success

    # 2. clear_command が届いても★送られない。未読のまま保持される。
    bash "$E2E_QUEUE/scripts/inbox_write.sh" "ashigaru1" \
        "/clear" "clear_command" "karo"

    run wait_for_log "$log_file" "[NO-AUTO-SEND] ashigaru1: CLIコマンド(/clear)は自動では送らぬ"
    assert_success
    run assert_inbox_unread_count "$E2E_QUEUE/queue/inbox/ashigaru1.yaml" 1
    assert_success

    # 3. 未配送の周期を何度か跨いでもフラグは消えない
    #    (旧契約では nudge 送信後にフラグを削除していた。その経路ごと無い)
    sleep 8
    [ -f "$ashigaru_idle_flag" ]

    # 4. 誰も /clear を打たぬゆえ mock は context reset せず、タスクは assigned のまま
    run wait_for_yaml_value "$E2E_QUEUE/queue/tasks/ashigaru1.yaml" "task.status" "assigned" 10
    assert_success

    stop_inbox_watcher "$watcher_pid"
    rm -rf "$flag_dir"
}

# ═══ E2E-010-B: 誤 busy が長引けばフラグを強制生成し、滞留を人へ倒す ═══

@test "E2E-010-B: stale busy 復帰でフラグを強制生成し、滞留を人経路へ倒す" {
    local ashigaru1_pane
    ashigaru1_pane=$(pane_target 1)
    local flag_dir log_file watcher_pid first_unread_seen

    flag_dir="$(mktemp -d "/tmp/e2e_idle_flags_stale_XXXXXX")"
    local ashigaru_idle_flag="$flag_dir/shogun_idle_ashigaru1"
    first_unread_seen=$(( $(date +%s) - 420 ))

    # Start mock in busy state before unread messages arrive.
    send_to_pane "$ashigaru1_pane" "busy_hold 12"
    sleep 1

    cp "$PROJECT_ROOT/tests/e2e/fixtures/task_ashigaru1_basic.yaml" \
        "$E2E_QUEUE/queue/tasks/ashigaru1.yaml"

    bash "$E2E_QUEUE/scripts/inbox_write.sh" "ashigaru1" \
        "タスクYAMLを読んで作業開始せよ。" "task_assigned" "karo"

    log_file="/tmp/e2e_inbox_watcher_ashigaru1_stale_busy_${BASHPID}.log"
    watcher_pid=$(
        IDLE_FLAG_DIR="$flag_dir" \
        FIRST_UNREAD_SEEN="$first_unread_seen" \
        bash "$E2E_QUEUE/scripts/inbox_watcher.sh" "ashigaru1" "$ashigaru1_pane" "copilot" \
            > "$log_file" 2>&1 &
        echo $!
    )

    # 1. busy が5分を超えて続けば、誤 busy とみなしフラグを強制生成する
    run wait_for_log "$log_file" "forcing idle flag"
    assert_success

    run wait_for_file_within "$ashigaru_idle_flag" 10
    assert_success

    # 2. 誤 busy から復帰しても打鍵はしない。猶予超過の滞留は人経路へ倒す。
    run wait_for_log "$log_file" "猶予超過。自動打鍵は行わず人経路へ倒す"
    assert_success
    run wait_for_log "$log_file" "人手で当該paneをご確認くだされ"
    assert_success

    # 3. copilot には Stop hook も self-watch も無い。打鍵ログは一つも無い。
    run grep -qE "\[SEND-KEYS\]" "$log_file"
    [ "$status" -ne 0 ]

    # 4. 誰も打鍵せぬゆえタスクは assigned のまま
    #    (旧試験はここで done を期待していた。/clear 送信が前提だったためである)
    run wait_for_yaml_value "$E2E_QUEUE/queue/tasks/ashigaru1.yaml" "task.status" "assigned" 10
    assert_success

    stop_inbox_watcher "$watcher_pid"
    rm -rf "$flag_dir"
}
