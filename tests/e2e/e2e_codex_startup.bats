#!/usr/bin/env bats
# ═══════════════════════════════════════════════════════════════
# E2E-008: Codex CLI — /new も startup prompt も自動では送らぬ
# ═══════════════════════════════════════════════════════════════
# ★契約の改訂 (cmd_754 E-1 / 2026-09-08):
#   本ファイルは元来「inbox_watcher が /new を送り、その後 startup prompt を
#   送って Session Start を起こす」ことを★正常系として検査していた。その
#   前提は失効した。2026-09-08、確認モーダル表示中の pane へ watcher が
#   送った Enter が既定選択肢 `❯ 1. Yes` を選び、D002-E1 違反の削除が実際に
#   実行された。将軍は★自動打鍵の安全集合を空とする裁定を下した (E-1)。
#
#   現契約における Codex:
#     - Stop hook ✕ / agent 自前の self-watch ✕ / 自動打鍵 ✕
#     - ★自動で配送するものは何も無い → 人経路のみ
#   Codex の /new が AGENTS.md を読み直しても Session Start を起こさぬ、と
#   いう CLI 側の事実は変わらない。変わったのは★その穴を打鍵で埋めるのを
#   やめたことである。埋めるのは人であり、watcher は「送れぬ」ことと
#   「人が何をすればよいか」を記録して滞留を人へ上げる。
#
#   本ファイルが確かめるもの:
#     A/B) task_assigned 到来時、/new も startup prompt も送らず人経路へ倒す
#     C)   Claude でも /clear は送らぬ。ただし配送は Stop hook が担う
#     D/E) clear_command は何通来ても送られず、read:false のまま保持される
#     F)   welcome 画面での初期 idle フラグ生成は今も要る(誤 busy 防止)
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

# Helper: dump watcher log on failure
dump_watcher_log() {
    local log_file="$1"
    echo "=== Watcher log ($log_file) ===" >&2
    cat "$log_file" >&2 2>/dev/null || echo "(log not found)" >&2
    echo "=== End watcher log ===" >&2
}

# Helper: wait until a fixed string appears in the watcher log
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
# E2E-008-A: Codex 宛の task_assigned は打鍵されず、タスクは動かない
# ═══════════════════════════════════════════════════════════════
# ★旧試験は「startup prompt が pane に現れ、タスクが done になる」ことを
#   期待していた。今は誰も打たぬゆえ、pane には何も現れず assigned のまま
#   である。これは不具合ではなく、裁定どおりの帰結である。代償(遅延)は
#   可視であり、誤爆の代償は不可視であった。★見える失敗を選ぶ。

@test "E2E-008-A: Codex へは /new も startup prompt も送られず、タスクは動かぬ" {
    local ashigaru1_pane
    ashigaru1_pane=$(pane_target 1)

    # 1. Respawn pane with codex mock (clean restart)
    tmux respawn-pane -k -t "$ashigaru1_pane" \
        "MOCK_CLI_TYPE=codex MOCK_AGENT_ID=ashigaru1 MOCK_PROCESSING_DELAY=1 MOCK_PROJECT_ROOT=$E2E_QUEUE bash $PROJECT_ROOT/tests/e2e/mock_cli.sh"
    sleep 2
    tmux set-option -p -t "$ashigaru1_pane" @agent_cli "codex"

    # 2. Place assigned task YAML
    cp "$PROJECT_ROOT/tests/e2e/fixtures/task_ashigaru1_basic.yaml" \
       "$E2E_QUEUE/queue/tasks/ashigaru1.yaml"

    # 3. Send task_assigned message via inbox_write
    bash "$E2E_QUEUE/scripts/inbox_write.sh" "ashigaru1" \
        "タスクYAMLを読んで作業開始せよ。" "task_assigned" "karo"

    # 4. Start inbox_watcher with codex CLI type
    local watcher_pid log_file
    watcher_pid=$(start_inbox_watcher "ashigaru1" 1 "codex")
    log_file="/tmp/e2e_inbox_watcher_ashigaru1_$$.log"

    # 5. context reset (/new) を送らぬ旨と、人が何をすればよいかが残る
    run wait_for_log "$log_file" "[NO-AUTO-SEND] ashigaru1: 新タスク前の context reset(/new)は自動では送らぬ"
    assert_success
    run wait_for_log "$log_file" "必要なら人手で /new を入力されたし"
    assert_success

    # 6. Codex には配送経路が無い。未配送として数える。
    run wait_for_log "$log_file" "未読1件の起床通知 (cli=codex) は自動では配送せぬ (理由=no_delivery_channel"
    assert_success

    # 7. pane には startup prompt が現れない (打鍵していないのだから当然である)
    run bash -c "tmux capture-pane -t '$ashigaru1_pane' -p -J -S - 2>/dev/null | grep -qF 'Startup prompt received'"
    assert_failure

    # 8. 誰も打鍵せぬゆえタスクは assigned のまま、未読も保持される
    run wait_for_yaml_value "$E2E_QUEUE/queue/tasks/ashigaru1.yaml" "task.status" "assigned" 10
    assert_success
    run assert_inbox_unread_count "$E2E_QUEUE/queue/inbox/ashigaru1.yaml" 1
    assert_success

    # Cleanup
    stop_inbox_watcher "$watcher_pid"
}

# ═══════════════════════════════════════════════════════════════
# E2E-008-B: watcher ログに旧契約の打鍵が一つも現れない
# ═══════════════════════════════════════════════════════════════

@test "E2E-008-B: Codex watcher log には startup prompt も /new 送信も現れない" {
    local ashigaru1_pane
    ashigaru1_pane=$(pane_target 1)

    # 1. Respawn pane with codex mock
    tmux respawn-pane -k -t "$ashigaru1_pane" \
        "MOCK_CLI_TYPE=codex MOCK_AGENT_ID=ashigaru1 MOCK_PROCESSING_DELAY=1 MOCK_PROJECT_ROOT=$E2E_QUEUE bash $PROJECT_ROOT/tests/e2e/mock_cli.sh"
    sleep 2
    tmux set-option -p -t "$ashigaru1_pane" @agent_cli "codex"

    # 2. Place task and send inbox message
    cp "$PROJECT_ROOT/tests/e2e/fixtures/task_ashigaru1_basic.yaml" \
       "$E2E_QUEUE/queue/tasks/ashigaru1.yaml"

    bash "$E2E_QUEUE/scripts/inbox_write.sh" "ashigaru1" \
        "タスクYAMLを読んで作業開始せよ。" "task_assigned" "karo"

    # 3. Start watcher (codex CLI type)
    local watcher_pid log_file
    watcher_pid=$(start_inbox_watcher "ashigaru1" 1 "codex")
    log_file="/tmp/e2e_inbox_watcher_ashigaru1_$$.log"

    # 4. 未読を1周期以上処理させる
    run wait_for_log "$log_file" "unread for ashigaru1"
    assert_success

    # 5. startup prompt は送られない (関数は残るが打鍵を持たぬ)
    run grep "Sending startup prompt to ashigaru1" "$log_file"
    assert_failure

    # 6. 「startup prompt を送った直後ゆえ nudge を抑止する」という
    #    旧契約の分岐そのものが無い
    run grep "Startup prompt just sent.*skipping nudge" "$log_file"
    assert_failure

    # 7. /new も /clear も送られない
    run grep "CONTEXT-RESET.*Sending /new" "$log_file"
    assert_failure

    run grep "CONTEXT-RESET.*Sending /clear" "$log_file"
    assert_failure

    # 8. 打鍵系ログは一つも無い (安全集合は空である)
    run grep -qE "\[SEND-KEYS\]" "$log_file"
    [ "$status" -ne 0 ]

    # Cleanup
    stop_inbox_watcher "$watcher_pid"
}

# ═══════════════════════════════════════════════════════════════
# E2E-008-C: Claude でも /clear は送らぬ。配送は Stop hook が担う
# ═══════════════════════════════════════════════════════════════
# ★旧試験は「Claude には startup prompt を送らず /clear だけ送る」という
#   差異を検査していた。今はどちらも送らない。Claude と他CLIの差は
#   「打鍵の有無」ではなく★「打鍵なしで届く経路(Stop hook)を持つか」である。

@test "E2E-008-C: Claude にも /clear は送られず、Stop hook が配送を担う" {
    local ashigaru1_pane
    ashigaru1_pane=$(pane_target 1)

    # 1. Respawn pane with claude mock
    tmux respawn-pane -k -t "$ashigaru1_pane" \
        "MOCK_CLI_TYPE=claude MOCK_AGENT_ID=ashigaru1 MOCK_PROCESSING_DELAY=1 MOCK_PROJECT_ROOT=$E2E_QUEUE bash $PROJECT_ROOT/tests/e2e/mock_cli.sh"
    sleep 2
    tmux set-option -p -t "$ashigaru1_pane" @agent_cli "claude"

    # 2. Place task and send inbox message
    cp "$PROJECT_ROOT/tests/e2e/fixtures/task_ashigaru1_basic.yaml" \
       "$E2E_QUEUE/queue/tasks/ashigaru1.yaml"

    bash "$E2E_QUEUE/scripts/inbox_write.sh" "ashigaru1" \
        "タスクYAMLを読んで作業開始せよ。" "task_assigned" "karo"

    # 3. Start watcher (claude CLI type)
    local watcher_pid log_file
    watcher_pid=$(start_inbox_watcher "ashigaru1" 1 "claude")
    log_file="/tmp/e2e_inbox_watcher_ashigaru1_$$.log"

    # 4. 配送は Stop hook に委ねる。打鍵は無い。
    run wait_for_log "$log_file" "Stop hook が配送を担う"
    assert_success

    # 5. context reset (/clear) も自動では送らない
    run wait_for_log "$log_file" "[NO-AUTO-SEND] ashigaru1: 新タスク前の context reset(/clear)は自動では送らぬ"
    assert_success

    # 6. startup prompt は Claude にも Codex にも送られない
    run grep "Sending startup prompt" "$log_file"
    assert_failure

    # 7. /clear 送信の旧ログは無い
    run grep "CONTEXT-RESET.*Sending /clear" "$log_file"
    assert_failure

    run grep -qE "\[SEND-KEYS\]" "$log_file"
    [ "$status" -ne 0 ]

    # Cleanup
    stop_inbox_watcher "$watcher_pid"
}

# ═══════════════════════════════════════════════════════════════
# E2E-008-D: Codex 宛 clear_command は0回送信・未読のまま保持される
# ═══════════════════════════════════════════════════════════════
# ★旧試験は「/new をちょうど1回だけ送る」ことを検査していた(多重送信バグの
#   回帰試験)。今の正解は★0回である。多重送信を防ぐ dedup ではなく、
#   送信そのものが無い。届かなかった命令を既読にしないことが要である。

@test "E2E-008-D: Codex 宛 clear_command は一度も送られず、未読のまま残る" {
    local ashigaru1_pane
    ashigaru1_pane=$(pane_target 1)

    # 1. Respawn pane with codex mock
    tmux respawn-pane -k -t "$ashigaru1_pane" \
        "MOCK_CLI_TYPE=codex MOCK_AGENT_ID=ashigaru1 MOCK_PROCESSING_DELAY=1 MOCK_PROJECT_ROOT=$E2E_QUEUE bash $PROJECT_ROOT/tests/e2e/mock_cli.sh"
    sleep 2
    tmux set-option -p -t "$ashigaru1_pane" @agent_cli "codex"

    # 2. Place assigned task YAML
    cp "$PROJECT_ROOT/tests/e2e/fixtures/task_ashigaru1_basic.yaml" \
       "$E2E_QUEUE/queue/tasks/ashigaru1.yaml"

    # 3. Send clear_command via inbox_write (karo が /clear を送る場面)
    bash "$E2E_QUEUE/scripts/inbox_write.sh" "ashigaru1" \
        "/clear" "clear_command" "karo"

    # 4. Start inbox_watcher with codex CLI type
    local watcher_pid log_file
    watcher_pid=$(start_inbox_watcher "ashigaru1" 1 "codex")
    log_file="/tmp/e2e_inbox_watcher_ashigaru1_$$.log"

    # 5. 自動送信せぬ旨と、Codex 向けの人の手順(/clear ではなく /new)が残る
    run wait_for_log "$log_file" "[NO-AUTO-SEND] ashigaru1: CLIコマンド(/clear)は自動では送らぬ (cli=codex)"
    assert_success
    run wait_for_log "$log_file" "人手で ashigaru1 の pane へ /new を入力されたし"
    assert_success

    # 6. 未送信のまま未読で保持される
    run wait_for_log "$log_file" "[NO-AUTO-SEND-DEFER] ashigaru1: clear_command を未送信のまま未読で保持する"
    assert_success
    run assert_inbox_unread_count "$E2E_QUEUE/queue/inbox/ashigaru1.yaml" 1
    assert_success

    # 7. /new 送信は★0回である (旧試験の「ちょうど1回」ではない)
    local new_count
    new_count=$(grep -c -E "Sending /new|Codex /clear→/new" "$log_file" 2>/dev/null || true)
    if [ "$new_count" -ne 0 ]; then
        echo "Expected 0 /new sends, got $new_count" >&2
        dump_watcher_log "$log_file"
    fi
    [ "$new_count" -eq 0 ]

    # 8. startup prompt も0回
    local startup_count
    startup_count=$(grep -c "Sending startup prompt to ashigaru1" "$log_file" 2>/dev/null || true)
    [ "$startup_count" -eq 0 ]

    # 9. 送信していない以上、送信後の取りこぼし対策(auto-recovery の
    #    task_assigned 自動投入)も起きない
    run grep "\[AUTO-RECOVERY\] queued task_assigned" "$log_file"
    assert_failure

    # Cleanup
    stop_inbox_watcher "$watcher_pid"
}

# ═══════════════════════════════════════════════════════════════
# E2E-008-E: clear_command が何通来ても送信は0回。滞留は人へ上がる
# ═══════════════════════════════════════════════════════════════

@test "E2E-008-E: clear_command 3通でも送信は0回、3通とも未読のまま人経路へ" {
    local ashigaru1_pane
    ashigaru1_pane=$(pane_target 1)

    # 1. Respawn pane with codex mock
    tmux respawn-pane -k -t "$ashigaru1_pane" \
        "MOCK_CLI_TYPE=codex MOCK_AGENT_ID=ashigaru1 MOCK_PROCESSING_DELAY=1 MOCK_PROJECT_ROOT=$E2E_QUEUE bash $PROJECT_ROOT/tests/e2e/mock_cli.sh"
    sleep 2
    tmux set-option -p -t "$ashigaru1_pane" @agent_cli "codex"

    # 2. Place assigned task YAML
    cp "$PROJECT_ROOT/tests/e2e/fixtures/task_ashigaru1_basic.yaml" \
       "$E2E_QUEUE/queue/tasks/ashigaru1.yaml"

    # 3. Send THREE clear_commands in rapid succession
    bash "$E2E_QUEUE/scripts/inbox_write.sh" "ashigaru1" \
        "/clear" "clear_command" "karo"
    bash "$E2E_QUEUE/scripts/inbox_write.sh" "ashigaru1" \
        "/clear" "clear_command" "karo"
    bash "$E2E_QUEUE/scripts/inbox_write.sh" "ashigaru1" \
        "/clear" "clear_command" "karo"

    # 4. Start inbox_watcher with codex CLI type
    local watcher_pid log_file
    watcher_pid=$(start_inbox_watcher "ashigaru1" 1 "codex")
    log_file="/tmp/e2e_inbox_watcher_ashigaru1_$$.log"

    # 5. 特殊命令だけが未読として残る周期でも、カウンタは戻さない
    run wait_for_log "$log_file" "未読3件は特殊命令のみ (人手の入力が要る)。カウンタは戻さぬ"
    assert_success

    # 6. 3通とも read: false のまま (1通も消えていない)
    run assert_inbox_unread_count "$E2E_QUEUE/queue/inbox/ashigaru1.yaml" 3
    assert_success

    # 7. 送信は0回 — dedup で1回に絞るのではなく、そもそも送らない
    local new_count
    new_count=$(grep -c -E "Sending /new|Codex /clear→/new" "$log_file" 2>/dev/null || true)
    if [ "$new_count" -ne 0 ]; then
        echo "Expected 0 /new sends despite 3 clear_commands, got $new_count" >&2
        dump_watcher_log "$log_file"
    fi
    [ "$new_count" -eq 0 ]

    # 8. 滞留は閾値を超えて人経路へ上がる (黙って沈まないこと)
    run wait_for_log "$log_file" "[DELIVERY-ALERT]" 45
    assert_success

    # Cleanup
    stop_inbox_watcher "$watcher_pid"
}

# ═══════════════════════════════════════════════════════════════
# E2E-008-F: welcome 画面(idle フラグ無し)でも誤 busy に陥らない
# ═══════════════════════════════════════════════════════════════
# Claude CLI が welcome 画面にいる間は stop_hook が一度も発火しておらず、
# idle フラグが存在しない。フラグ不在を busy と誤認すると、Stop hook 待ちの
# 判断も滞留時計も狂う。★打鍵を廃した後もこの初期フラグ生成は要る。

@test "E2E-008-F: Claude welcome 画面で初期 idle フラグが生成され、誤 busy にならぬ" {
    local ashigaru1_pane
    ashigaru1_pane=$(pane_target 1)

    # Use isolated IDLE_FLAG_DIR to avoid cross-test contamination
    local flag_dir
    flag_dir=$(mktemp -d "/tmp/e2e_idle_flags_XXXXXX")
    export IDLE_FLAG_DIR="$flag_dir"

    # 1. Respawn pane with claude mock
    tmux respawn-pane -k -t "$ashigaru1_pane" \
        "IDLE_FLAG_DIR=$flag_dir MOCK_CLI_TYPE=claude MOCK_AGENT_ID=ashigaru1 MOCK_PROCESSING_DELAY=1 MOCK_PROJECT_ROOT=$E2E_QUEUE bash $PROJECT_ROOT/tests/e2e/mock_cli.sh"
    sleep 2
    tmux set-option -p -t "$ashigaru1_pane" @agent_cli "claude"

    # 2. Remove any idle flag that mock_cli created on startup
    #    (simulates real CLI at welcome screen where stop_hook hasn't fired)
    rm -f "$flag_dir/shogun_idle_ashigaru1"

    # Verify flag is truly gone — this is the precondition for the test
    [ ! -f "$flag_dir/shogun_idle_ashigaru1" ]

    # 3. Place assigned task YAML
    cp "$PROJECT_ROOT/tests/e2e/fixtures/task_ashigaru1_basic.yaml" \
       "$E2E_QUEUE/queue/tasks/ashigaru1.yaml"

    # 4. Send task_assigned message (unread message waiting)
    bash "$E2E_QUEUE/scripts/inbox_write.sh" "ashigaru1" \
        "タスクYAMLを読んで作業開始せよ。" "task_assigned" "karo"

    # 5. Start inbox_watcher — 初期 idle フラグ生成がここで効く
    local watcher_pid log_file
    log_file="/tmp/e2e_inbox_watcher_ashigaru1_$$.log"
    IDLE_FLAG_DIR="$flag_dir" \
    ESCALATE_PHASE1="${E2E_ESCALATE_PHASE1:-10}" \
    ESCALATE_PHASE2="${E2E_ESCALATE_PHASE2:-20}" \
    ESCALATE_COOLDOWN="${E2E_ESCALATE_COOLDOWN:-25}" \
    INOTIFY_TIMEOUT="${E2E_INOTIFY_TIMEOUT:-5}" \
    bash "$E2E_QUEUE/scripts/inbox_watcher.sh" "ashigaru1" "$ashigaru1_pane" "claude" \
        > "$log_file" 2>&1 &
    watcher_pid=$!

    # 6. 初期フラグ生成がログに残る (この修正が効いている証拠)
    run wait_for_log "$log_file" "Created initial idle flag for ashigaru1"
    assert_success
    run wait_for_file "$flag_dir/shogun_idle_ashigaru1" 10
    assert_success

    # 7. 誤 busy に陥らず、配送判断が Stop hook まで進む
    run wait_for_log "$log_file" "Stop hook が配送を担う"
    assert_success

    # 8. 「busy ゆえ待つ」ログが出ていないこと
    #    (修正が無ければ busy 判定が繰り返し記録される)
    run grep "unread for ashigaru1 but agent is busy (claude)" "$log_file"
    assert_failure

    # 9. 判断が進んでも打鍵は発生しない
    run grep -qE "\[SEND-KEYS\]" "$log_file"
    [ "$status" -ne 0 ]

    # Cleanup
    stop_inbox_watcher "$watcher_pid"
    rm -rf "$flag_dir"
}
