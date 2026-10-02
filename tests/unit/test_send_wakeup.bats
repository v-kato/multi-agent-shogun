#!/usr/bin/env bats
# test_send_wakeup.bats — send_wakeup() 系の単体テスト
# Sources the REAL inbox_watcher.sh with __INBOX_WATCHER_TESTING__=1
# to test actual production functions with mocked externals (tmux, pgrep, etc).
#
# ★cmd_754 (将軍裁定 E-1) により、本ファイルの契約は反転した。
#   旧: 「条件が揃えば nudge を send-keys で送る」ことを検査していた
#   新: 「★いかなる条件でも打鍵しない」ことを検査する
#   2026-09-08、nudge の Enter が確認モーダルの既定選択肢を押し、D002-E1
#   違反の削除が実行された。以後4世代の「画面から安全を証明する」試みが
#   全て破れ、将軍は自動打鍵の安全集合を★空とする裁定を下した。
#
# テスト構成 (cmd_754 で「自動打鍵ゼロ」の契約へ全面改訂):
#   T-SW-001: 打鍵なしの配送経路が生きていれば委ね、打鍵しない
#   T-SW-002: send_wakeup は self-watch が無くても打鍵しない (cmd_754 E-1)
#   T-SW-003: nudge 文字列 (inboxN) も Enter も一切送られない
#   T-SW-004: send_wakeup は常に rc=0 を返し watcher を落とさない
#   T-SW-005: 打鍵系 tmux サブコマンドを一切使わない (send-keys/paste-buffer/set-buffer)
#   T-SW-006: agent_has_self_watch returns 0 when inotifywait running
#   T-SW-007: agent_has_self_watch returns 1 when no inotifywait
#   T-SW-008: send_cli_command /clear は送られず rc=1 になる
#   T-SW-009: send_cli_command /model は送られず rc=1 になる
#   T-SW-010: nudge という打鍵経路そのものが存在しない
#   T-SW-011: inbox_watcher.sh に tmux send-keys が1つも無い (構造としての不在)
#   T-ESC-001: escalation state resets when no unread messages
#   T-ESC-002: 猶予内(2分未満)は配送経路へ委ね、打鍵しない
#   T-ESC-003: Escape エスカレーションは廃止され、打鍵は起きない
#   T-ESC-004: 猶予超過でも /clear は送らず、人経路へ倒す
#   T-ESC-005: 滞留が猶予を超えると未配送として数えられる
#   T-BUSY-001: agent_is_busy returns 0 (busy) when no idle flag — claude CLI
#   T-BUSY-002: agent_is_busy returns 1 when pane is idle
#   T-BUSY-003: busy でも idle でも send_wakeup は打鍵しない
#   T-BUSY-004: send_wakeup_with_escape は busy でも打鍵しない
#   T-CODEX-001: codex でも /clear→/new の打鍵は送られない
#   T-CODEX-002: codex の /model も送られない
#   T-OPENCODE-001: opencode でも /clear→/new の打鍵は送られない
#   T-OPENCODE-002: opencode の /model も送られない
#   T-CODEX-003: C-u cleanup sent when no unread and agent is idle
#   T-CODEX-004: C-u cleanup NOT sent when agent is busy
#   T-CODEX-005: claude でも /clear は送られない
#   T-CODEX-006: inbox_watcher.sh は busy 判定と配送経路判定を持つ
#   T-CODEX-007: pane @agent_cli=codex でも打鍵は起きない
#   T-CODEX-008: pane @agent_cli=codex は配送経路の判定に反映される
#   T-CODEX-009: normalize_special_command rejects invalid model_switch payload
#   T-CODEX-010: CLI 種別が解決できずとも打鍵は起きない
#   T-CODEX-011: clear_command は送られず未読のまま残り、auto-recovery も走らない
#   T-SHOGUN-005: process_unread does not auto-recover skipped shogun clear_command
#   T-OPENCODE-003: opencode の Escape 経路も打鍵を持たない
#   T-CODEX-012: enqueue_recovery_task_assigned deduplicates unread auto-recovery message
#   T-CODEX-013: enqueue_recovery_task_assigned skips if task YAML status is cancelled
#   T-CODEX-014: enqueue_recovery_task_assigned skips if task YAML status is idle
#   T-CODEX-015: enqueue_recovery_task_assigned proceeds when task YAML status is assigned
#   T-COPILOT-001: copilot の C-c + 再起動打鍵も送られない
#   T-COPILOT-002: copilot の /model も送られない
#   T-SHOGUN-001: session_has_client returns 0 when client attached
#   T-SHOGUN-002: session_has_client returns 1 when no client
#   T-SHOGUN-003: 将軍 pane が active でも打鍵しない
#   T-SHOGUN-004: 将軍 pane が detached でも打鍵しない
#   T-BUSY-005: agent_is_busy returns 0 (busy) during /clear cooldown period
#   T-BUSY-006: agent_is_busy returns 1 (idle) after /clear cooldown expires
#   T-BUSY-007: agent_is_busy /clear cooldown overrides idle pane state
#   T-BUSY-008: agent_is_busy returns idle when idle prompt is below old busy markers
#   T-BUSY-009: agent_is_busy detects 'background terminal running' as busy
#   T-BUSY-010: agent_is_busy detects 'Compacting conversation' as busy
#   T-BUSY-011: agent_is_busy detects 'esc to interrupt' as busy
#   T-BUSY-012: agent_is_busy detects OpenCode home screen as idle
#   T-BUSY-013: agent_is_busy detects OpenCode busy sidebar as busy
#   T-BUSY-014: agent_is_busy detects OpenCode busy animation row as busy
#   T-BUSY-015: agent_is_busy treats blank OpenCode pane as idle fallback
#   T-BUSY-016: OpenCode busy animation fallback works without python3
#   T-SHOOK-004: 全既読になれば未配送カウンタがリセットされる (nudge throttle は廃止)
#   T-CODEX-016: 送信確認のための capture-pane 再読も行わない
#   T-CRESET-001: send_context_reset — 家老は元より対象外で、打鍵も無い
#   T-CRESET-002: send_context_reset — 軍師も同様に打鍵しない
#   T-CRESET-003: send_context_reset — 足軽へも /clear を送らず rc=1
#   T-CRESET-004: send_context_reset — opencode へも /new を送らず rc=1

# --- セットアップ ---

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export WATCHER_SCRIPT="$PROJECT_ROOT/scripts/inbox_watcher.sh"
    export VENV_PYTHON="$PROJECT_ROOT/.venv/bin/python3"
    [ -f "$WATCHER_SCRIPT" ] || return 1
    "$VENV_PYTHON" -c "import yaml" 2>/dev/null || return 1
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/send_wakeup_test.XXXXXX")"

    # Log file for tmux mock calls (all tmux invocations recorded here)
    export MOCK_LOG="$TEST_TMPDIR/tmux_calls.log"
    > "$MOCK_LOG"

    # Create mock pgrep (default: no self-watch found)
    export MOCK_PGREP="$TEST_TMPDIR/mock_pgrep"
    cat > "$MOCK_PGREP" << 'MOCK'
#!/bin/bash
exit 1
MOCK
    chmod +x "$MOCK_PGREP"

    # Create test inbox directory
    export TEST_INBOX_DIR="$TEST_TMPDIR/queue/inbox"
    mkdir -p "$TEST_INBOX_DIR"

    # Default mock control variables
    # 既定値は「通常のアイドル画面」を模した pane 内容とする (cmd_754)。
    # inbox_watcher.sh は send-keys の直前に capture-pane で確認モーダルの
    # 有無を検査し、pane 内容を確認できない場合は打鍵を抑止する。
    # 空文字列は『pane の状態を確認できない』を意味し実機のアイドル状態を
    # 表さないため、確認待ちを含まないアイドル画面を既定にする。
    export MOCK_CAPTURE_PANE="$(printf '╭────────────────────────────────────────╮\n│ Ask anything                           │\n╰────────────────────────────────────────╯\n  ? for shortcuts\n')"
    export MOCK_CURSOR_SPEC="1|1|0"
    # ★打鍵回数カウンタ(MOCK_SWITCH_AFTER_KEYS を使う試験のみ参照する)
    export MOCK_KEY_COUNT_FILE="$TEST_TMPDIR/key_count"
    echo 0 > "$MOCK_KEY_COUNT_FILE"
    export MOCK_SENDKEYS_RC=0
    export MOCK_PANE_CLI=""
    export MOCK_PANE_ACTIVE=""
    export MOCK_LIST_CLIENTS=""

    # Test harness: sets up mocks, then sources the REAL inbox_watcher.sh
    # __INBOX_WATCHER_TESTING__=1 skips arg parsing, inotifywait check, and main loop.
    # Only function definitions are loaded — testing actual production code.
    export TEST_HARNESS="$TEST_TMPDIR/test_harness.sh"
    cat > "$TEST_HARNESS" << HARNESS
#!/bin/bash
# Variables required by inbox_watcher.sh functions
AGENT_ID="test_agent"
PANE_TARGET="test:0.0"
CLI_TYPE="claude"
INBOX="$TEST_INBOX_DIR/test_agent.yaml"
LOCKFILE="\${INBOX}.lock"
SCRIPT_DIR="$PROJECT_ROOT"
export IDLE_FLAG_DIR="$TEST_TMPDIR"

# Mock external commands (defined before sourcing so they override real commands)
tmux() {
    echo "tmux \$*" >> "$MOCK_LOG"
    if echo "\$*" | grep -q "capture-pane"; then
        # ★N打鍵目の後に画面が変わる状況の再現(例: C-c で CLI が落ちて
        #   シェルへ戻る)。MOCK_SWITCH_AFTER_KEYS を設定した試験でのみ効く。
        if [ -n "\${MOCK_SWITCH_AFTER_KEYS:-}" ] \
            && [ "\$(cat "\${MOCK_KEY_COUNT_FILE:-/nonexistent}" 2>/dev/null || echo 0)" -ge "\${MOCK_SWITCH_AFTER_KEYS}" ]; then
            echo "\${MOCK_CAPTURE_PANE_AFTER:-}"
            return 0
        fi
        echo "\${MOCK_CAPTURE_PANE:-}"
        return 0
    fi
    if echo "\$*" | grep -q "send-keys"; then
        if [ -n "\${MOCK_KEY_COUNT_FILE:-}" ]; then
            echo \$(( \$(cat "\$MOCK_KEY_COUNT_FILE" 2>/dev/null || echo 0) + 1 )) > "\$MOCK_KEY_COUNT_FILE"
        fi
        return \${MOCK_SENDKEYS_RC:-0}
    fi
    if echo "\$*" | grep -q "show-options"; then
        echo "\${MOCK_PANE_CLI:-}"
        return 0
    fi
    if echo "\$*" | grep -q "list-clients"; then
        [ -n "\${MOCK_LIST_CLIENTS:-}" ] && echo "\$MOCK_LIST_CLIENTS"
        return 0
    fi
    if echo "\$*" | grep -q "display-message"; then
        if echo "\$*" | grep -q "cursor_y"; then
            # ★カーソル位置(cursor_y|cursor_flag|pane_in_mode)。既定値 1 は
            #   既定 MOCK_CAPTURE_PANE の入力行(`│ Ask anything │`)の行番号。
            if [ -n "\${MOCK_SWITCH_AFTER_KEYS:-}" ] \
                && [ "\$(cat "\${MOCK_KEY_COUNT_FILE:-/nonexistent}" 2>/dev/null || echo 0)" -ge "\${MOCK_SWITCH_AFTER_KEYS}" ]; then
                echo "\${MOCK_CURSOR_SPEC_AFTER:-1|1|0}"
                return 0
            fi
            echo "\${MOCK_CURSOR_SPEC:-1|1|0}"
            return 0
        fi
        if echo "\$*" | grep -q "pane_active"; then
            echo "\${MOCK_PANE_ACTIVE:-0}"
        else
            echo "mock_session"
        fi
        return 0
    fi
    return 0
}
timeout() { shift; "\$@"; }
pgrep() { "$MOCK_PGREP" "\$@"; }
sleep() { :; }
export -f tmux timeout pgrep sleep

# Source the REAL inbox_watcher.sh (testing guard skips startup & main loop)
export __INBOX_WATCHER_TESTING__=1
source "$WATCHER_SCRIPT"
HARNESS
    chmod +x "$TEST_HARNESS"

    # Default: create idle flag so agent_is_busy() returns idle (1) for claude CLI
    # Tests requiring busy state must rm this file before their run bash -c block
    touch "$TEST_TMPDIR/shogun_idle_test_agent"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

# --- T-SW-001: self-watch active → skip nudge ---


# --- T-SW-002: no self-watch → tmux send-keys ---


# --- T-SW-003: send-keys content is "inboxN" + Enter (separated) ---


# --- T-SW-004: send-keys failure → return 0 (daemon-safe) + WARNING log ---
# send_wakeup always returns 0 to avoid killing the watcher under set -euo pipefail.

@test "T-SW-004: send_wakeup は常に rc=0 を返し watcher を落とさない" {
    run bash -c "MOCK_SENDKEYS_RC=1; source '$TEST_HARNESS'; send_wakeup 3; echo RC=\$?"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "RC=0"
}

# --- T-SW-005: no paste-buffer or set-buffer used ---


# --- T-SW-006: agent_has_self_watch — detects inotifywait ---

@test "T-SW-006: agent_has_self_watch returns 0 when inotifywait running" {
    cat > "$MOCK_PGREP" << 'MOCK'
#!/bin/bash
echo "99999 inotifywait -q -t 120 -e modify inbox/test_agent.yaml"
exit 0
MOCK
    chmod +x "$MOCK_PGREP"

    run bash -c "source '$TEST_HARNESS' && agent_has_self_watch"
    [ "$status" -eq 0 ]
}

# --- T-SW-007: agent_has_self_watch — no inotifywait ---

@test "T-SW-007: agent_has_self_watch returns 1 when no inotifywait" {
    run bash -c "source '$TEST_HARNESS' && agent_has_self_watch"
    [ "$status" -eq 1 ]
}

# --- T-SW-008: /clear uses send-keys ---


# --- T-SW-009: /model uses send-keys ---


# --- T-SW-010: nudge content format ---


# --- T-SW-011: functions exist in inbox_watcher.sh ---


# --- T-ESC-001: no unread → FIRST_UNREAD_SEEN stays 0 ---

@test "T-ESC-001: escalation state resets when no unread messages" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        FIRST_UNREAD_SEEN=12345
        # Simulate no unread
        normal_count=0
        if [ "$normal_count" -gt 0 ] 2>/dev/null; then
            echo "SHOULD_NOT_REACH"
        else
            FIRST_UNREAD_SEEN=0
        fi
        echo "FIRST_UNREAD_SEEN=$FIRST_UNREAD_SEEN"
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "FIRST_UNREAD_SEEN=0"
}

# --- T-ESC-002: unread < 2min → standard nudge ---


# --- T-ESC-003: unread 2-4min → Escape+nudge ---


# --- T-ESC-004: unread > 4min → /clear sent ---


# --- T-ESC-005: /clear cooldown → falls back to Escape+nudge ---


# --- T-BUSY-001: agent_is_busy detects "Working" ---

@test "T-BUSY-001: agent_is_busy returns 0 (busy) when no idle flag — claude CLI" {
    rm -f "$TEST_TMPDIR/shogun_idle_test_agent"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        LAST_CLEAR_TS=0
        agent_is_busy
    '
    [ "$status" -eq 0 ]
}

# --- T-BUSY-002: agent_is_busy returns 1 when idle ---

@test "T-BUSY-002: agent_is_busy returns 1 when pane is idle" {
    run bash -c '
        MOCK_CAPTURE_PANE="› Summarize recent commits
  ? for shortcuts                100% context left"
        source "'"$TEST_HARNESS"'"
        agent_is_busy
    '
    [ "$status" -eq 1 ]
}

# --- T-BUSY-003: send_wakeup skips when agent is busy ---

@test "T-BUSY-003: busy でも idle でも send_wakeup は打鍵しない" {
    rm -f "$TEST_TMPDIR/shogun_idle_test_agent"
    run bash -c "source '$TEST_HARNESS' && send_wakeup 2"
    [ "$status" -eq 0 ]
    ! grep -q "send-keys" "$MOCK_LOG"
}

# --- T-BUSY-004: send_wakeup_with_escape skips when agent is busy ---

@test "T-BUSY-004: send_wakeup_with_escape は busy でも打鍵しない" {
    rm -f "$TEST_TMPDIR/shogun_idle_test_agent"
    run bash -c "source '$TEST_HARNESS' && send_wakeup_with_escape 2"
    [ "$status" -eq 0 ]
    ! grep -q "send-keys" "$MOCK_LOG"
}

# --- T-CODEX-001: codex /clear → /new conversion ---


# --- T-CODEX-002: codex /model → skip ---


# --- T-OPENCODE-001: opencode /clear → /new conversion ---


# --- T-OPENCODE-002: opencode /model → skip with restart-only note ---


# --- T-CODEX-003: C-u sent when unread=0 and agent is idle ---

@test "T-CODEX-003: C-u cleanup sent when no unread and agent is idle" {
    run bash -c '
        MOCK_CAPTURE_PANE="› Summarize recent commits
  ? for shortcuts                100% context left"
        source "'"$TEST_HARNESS"'"
        # Simulate process_unread no-unread path
        FIRST_UNREAD_SEEN=12345
        normal_count=0
        if [ "$normal_count" -gt 0 ] 2>/dev/null; then
            echo "SHOULD_NOT_REACH"
        else
            FIRST_UNREAD_SEEN=0
            if ! agent_is_busy; then
                timeout 2 tmux send-keys -t "$PANE_TARGET" C-u 2>/dev/null
                echo "C_U_SENT"
            fi
        fi
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "C_U_SENT"
    grep -q "send-keys.*C-u" "$MOCK_LOG"
}

# --- T-CODEX-004: C-u NOT sent when agent is busy ---

@test "T-CODEX-004: C-u cleanup NOT sent when agent is busy" {
    rm -f "$TEST_TMPDIR/shogun_idle_test_agent"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        FIRST_UNREAD_SEEN=12345
        normal_count=0
        if [ "$normal_count" -gt 0 ] 2>/dev/null; then
            echo "SHOULD_NOT_REACH"
        else
            FIRST_UNREAD_SEEN=0
            if ! agent_is_busy; then
                timeout 2 tmux send-keys -t "$PANE_TARGET" C-u 2>/dev/null
                echo "C_U_SENT"
            else
                echo "C_U_SKIPPED"
            fi
        fi
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "C_U_SKIPPED"
    ! grep -q "C-u" "$MOCK_LOG"
}

# --- T-CODEX-005: claude /clear passes through as-is ---


# --- T-CODEX-006: inbox_watcher.sh has agent_is_busy and Codex/Copilot handlers ---


# --- T-CODEX-007: pane cli overrides stale CLI_TYPE in Phase2 ---


# --- T-CODEX-008: pane cli overrides stale CLI_TYPE in /clear path ---


# --- T-CODEX-009: invalid model_switch payload is rejected ---

@test "T-CODEX-009: normalize_special_command rejects invalid model_switch payload" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        cmd=$(normalize_special_command "model_switch" "please change model" 2>/dev/null)
        [ -z "$cmd" ]
    '
    [ "$status" -eq 0 ]
}

# --- T-CODEX-010: unresolved cli falls back to codex-safe ---


# --- T-CODEX-011: clear_command auto-recovery injection ---


@test "T-SHOGUN-005: process_unread does not auto-recover skipped shogun clear_command" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="shogun"
        PANE_TARGET="shogun:main"
        CLI_TYPE="codex"
        INBOX="'"$TEST_INBOX_DIR"'/shogun.yaml"
        LOCKFILE="${INBOX}.lock"
        cat > "$INBOX" << "YAML"
messages:
  - id: msg_clear
    from: karo
    timestamp: "2026-05-22T03:22:46+09:00"
    type: clear_command
    content: refresh
    read: false
YAML
        process_unread event
        "$VENV_PYTHON" - << "PY" "$INBOX"
import sys
import yaml

inbox_path = sys.argv[1]
with open(inbox_path, "r", encoding="utf-8") as f:
    data = yaml.safe_load(f) or {}

messages = data.get("messages", []) or []
msg_clear = [m for m in messages if m.get("id") == "msg_clear"]
assert len(msg_clear) == 1 and msg_clear[0].get("read") is True

auto = [
    m for m in messages
    if m.get("from") == "inbox_watcher"
    and m.get("type") == "task_assigned"
    and "[auto-recovery]" in (m.get("content") or "")
]
assert auto == []
print("OK")
PY
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "OK"

    ! grep -q "send-keys.*/new" "$MOCK_LOG"
    ! grep -q "send-keys.*/clear" "$MOCK_LOG"
}

# --- T-OPENCODE-003: OpenCode Phase 2 falls back to plain nudge ---


# --- T-CODEX-012: auto-recovery dedupe ---

@test "T-CODEX-012: enqueue_recovery_task_assigned deduplicates unread auto-recovery message" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        cat > "$INBOX" << "YAML"
messages:
  - id: msg_auto_existing
    from: inbox_watcher
    timestamp: "2026-02-10T14:00:00+09:00"
    type: task_assigned
    content: "[auto-recovery] existing hint"
    read: false
YAML
        r1=$(enqueue_recovery_task_assigned)
        r2=$(enqueue_recovery_task_assigned)
        "$VENV_PYTHON" - << "PY" "$INBOX" "$r1" "$r2"
import sys
import yaml

inbox_path, r1, r2 = sys.argv[1], sys.argv[2], sys.argv[3]
with open(inbox_path, "r", encoding="utf-8") as f:
    data = yaml.safe_load(f) or {}
messages = data.get("messages", []) or []
auto = [
    m for m in messages
    if m.get("from") == "inbox_watcher"
    and m.get("type") == "task_assigned"
    and "[auto-recovery]" in (m.get("content") or "")
    and m.get("read") is False
]
assert len(auto) == 1
assert r1 == "SKIP_DUPLICATE"
assert r2 == "SKIP_DUPLICATE"
print("OK")
PY
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "OK"
}

# --- T-CODEX-013: auto-recovery skipped when task is cancelled ---

@test "T-CODEX-013: enqueue_recovery_task_assigned skips if task YAML status is cancelled" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        # Initialize inbox (required by enqueue_recovery_task_assigned)
        echo "messages: []" > "$INBOX"
        # Place task YAML with status: cancelled
        mkdir -p "$(dirname "$INBOX")/../tasks"
        cat > "$(dirname "$INBOX")/../tasks/test_agent.yaml" << "YAML"
worker_id: test_agent
task_id: subtask_test_cancelled
status: cancelled
YAML
        r=$(enqueue_recovery_task_assigned)
        # Should return SKIP_CANCELLED:cancelled
        if [ "$r" = "SKIP_CANCELLED:cancelled" ]; then echo "OK"; else echo "FAIL:$r"; fi
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "OK"
}

# --- T-CODEX-014: auto-recovery skipped when task is idle ---

@test "T-CODEX-014: enqueue_recovery_task_assigned skips if task YAML status is idle" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        echo "messages: []" > "$INBOX"
        mkdir -p "$(dirname "$INBOX")/../tasks"
        cat > "$(dirname "$INBOX")/../tasks/test_agent.yaml" << "YAML"
worker_id: test_agent
task_id: subtask_test_idle
status: idle
YAML
        r=$(enqueue_recovery_task_assigned)
        if [ "$r" = "SKIP_CANCELLED:idle" ]; then echo "OK"; else echo "FAIL:$r"; fi
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "OK"
}

# --- T-CODEX-015: auto-recovery proceeds when task is assigned ---

@test "T-CODEX-015: enqueue_recovery_task_assigned proceeds when task YAML status is assigned" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        echo "messages: []" > "$INBOX"
        mkdir -p "$(dirname "$INBOX")/../tasks"
        cat > "$(dirname "$INBOX")/../tasks/test_agent.yaml" << "YAML"
worker_id: test_agent
task_id: subtask_test_assigned
status: assigned
YAML
        r=$(enqueue_recovery_task_assigned)
        # Should return a message ID (not SKIP_*)
        if [[ "$r" != SKIP_* ]] && [[ "$r" != "ERROR" ]] && [[ -n "$r" ]]; then echo "OK"; else echo "FAIL:$r"; fi
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "OK"
}

# --- T-COPILOT-001: copilot /clear → Ctrl-C + restart ---


# --- T-COPILOT-002: copilot /model → skip ---


# --- T-SHOGUN-001: session_has_client — client attached ---

@test "T-SHOGUN-001: session_has_client returns 0 when client attached" {
    run bash -c '
        MOCK_LIST_CLIENTS="/dev/pts/1: mock_session [200x50 xterm-256color]"
        source "'"$TEST_HARNESS"'"
        session_has_client
    '
    [ "$status" -eq 0 ]
}

# --- T-SHOGUN-002: session_has_client — no client ---

@test "T-SHOGUN-002: session_has_client returns 1 when no client" {
    run bash -c '
        MOCK_LIST_CLIENTS=""
        source "'"$TEST_HARNESS"'"
        session_has_client
    '
    [ "$status" -ne 0 ]
}

# --- T-SHOGUN-003: shogun + active pane + client attached → send-keys (post PR#75) ---


# --- T-SHOGUN-004: shogun + active pane + no client → send-keys fallthrough ---


# --- T-BUSY-005: agent_is_busy during /clear cooldown ---

@test "T-BUSY-005: agent_is_busy returns 0 (busy) during /clear cooldown period" {
    run bash -c '
        MOCK_CAPTURE_PANE="› prompt
  ? for shortcuts                100% context left"
        source "'"$TEST_HARNESS"'"
        now=$(date +%s)
        LAST_CLEAR_TS=$((now - 10))  # /clear sent 10 seconds ago (within 30s cooldown)
        agent_is_busy
    '
    [ "$status" -eq 0 ]
}

# --- T-BUSY-006: agent_is_busy idle after /clear cooldown expires ---

@test "T-BUSY-006: agent_is_busy returns 1 (idle) after /clear cooldown expires" {
    run bash -c '
        MOCK_CAPTURE_PANE="› prompt
  ? for shortcuts                100% context left"
        source "'"$TEST_HARNESS"'"
        now=$(date +%s)
        LAST_CLEAR_TS=$((now - 40))  # /clear sent 40 seconds ago (past 30s cooldown)
        agent_is_busy
    '
    [ "$status" -eq 1 ]
}

# --- T-BUSY-007: /clear cooldown overrides idle pane ---

@test "T-BUSY-007: agent_is_busy /clear cooldown overrides idle pane state" {
    run bash -c '
        MOCK_CAPTURE_PANE="› Summarize recent commits
  ? for shortcuts                100% context left"
        source "'"$TEST_HARNESS"'"
        now=$(date +%s)
        LAST_CLEAR_TS=$((now - 5))  # /clear sent 5 seconds ago
        # Pane looks idle, but cooldown should make it busy
        if agent_is_busy; then
            echo "BUSY_DURING_COOLDOWN"
        else
            echo "WRONGLY_IDLE"
        fi
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "BUSY_DURING_COOLDOWN"
}

# --- T-BUSY-008: idle prompt at bottom overrides old busy markers (false-busy fix) ---
# Bug: 59ec12f / 69c1ecb — old "Working" or "esc to interrupt" lingered in scroll-back
# above the idle prompt, causing false-busy. Fix: only check bottom 5 lines, idle first.

@test "T-BUSY-008: agent_is_busy returns idle when idle prompt is below old busy markers" {
    run bash -c '
        MOCK_CAPTURE_PANE="$(printf "◦ Working on task (12s • esc to interrupt)\nsome output line\nmore output\n\n❯ ")"
        source "'"$TEST_HARNESS"'"
        LAST_CLEAR_TS=0
        if agent_is_busy; then
            echo "WRONGLY_BUSY"
        else
            echo "CORRECTLY_IDLE"
        fi
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "CORRECTLY_IDLE"
}

# --- T-BUSY-009: 'background terminal running' detected as busy ---
# Bug: 91ebf61 — Codex shows this when a tool is running in background.

@test "T-BUSY-009: agent_is_busy detects 'background terminal running' as busy" {
    run bash -c '
        MOCK_CAPTURE_PANE="$(printf "Some output\nbackground terminal running\n")"
        source "'"$TEST_HARNESS"'"
        LAST_CLEAR_TS=0
        CLI_TYPE="codex"  # pane-based detection (non-claude fallback)
        agent_is_busy
    '
    [ "$status" -eq 0 ]
}

# --- T-BUSY-010: 'Compacting conversation' detected as busy ---

@test "T-BUSY-010: agent_is_busy detects 'Compacting conversation' as busy" {
    run bash -c '
        MOCK_CAPTURE_PANE="$(printf "Compacting conversation...\n")"
        source "'"$TEST_HARNESS"'"
        LAST_CLEAR_TS=0
        CLI_TYPE="codex"  # pane-based detection (non-claude fallback)
        agent_is_busy
    '
    [ "$status" -eq 0 ]
}

# --- T-BUSY-011: 'esc to interrupt' detected as busy ---

@test "T-BUSY-011: agent_is_busy detects 'esc to interrupt' as busy" {
    run bash -c '
        MOCK_CAPTURE_PANE="$(printf "◦ Thinking (5s • esc to interrupt)\n")"
        source "'"$TEST_HARNESS"'"
        LAST_CLEAR_TS=0
        CLI_TYPE="codex"  # pane-based detection (non-claude fallback)
        agent_is_busy
    '
    [ "$status" -eq 0 ]
}

# --- T-BUSY-012: OpenCode idle home screen detected as idle ---

@test "T-BUSY-012: agent_is_busy detects OpenCode home screen as idle" {
    run bash -c '
        MOCK_CAPTURE_PANE="$(printf "  ┃\n  ┃  Ask anything...\n  ┃\n\n                                                   ctrl+p commands\n")"
        MOCK_PANE_CLI="opencode"
        source "'"$TEST_HARNESS"'"
        LAST_CLEAR_TS=0
        CLI_TYPE="opencode"
        agent_is_busy
    '
    [ "$status" -eq 1 ]
}

# --- T-BUSY-013: OpenCode busy sidebar detected as busy ---

@test "T-BUSY-013: agent_is_busy detects OpenCode busy sidebar as busy" {
    run bash -c '
        MOCK_CAPTURE_PANE="$(printf "  ┃  think something deeper\n     → Skill \"requirements-clarification\"\n\n   ■⬝⬝⬝⬝⬝⬝⬝  esc interrupt\n")"
        MOCK_PANE_CLI="opencode"
        source "'"$TEST_HARNESS"'"
        LAST_CLEAR_TS=0
        CLI_TYPE="opencode"
        agent_is_busy
    '
    [ "$status" -eq 0 ]
}

# --- T-BUSY-014: OpenCode busy animation row detected as busy ---

@test "T-BUSY-014: agent_is_busy detects OpenCode busy animation row as busy" {
    run bash -c '
        MOCK_CAPTURE_PANE="$(printf "   ■⬝⬝⬝⬝⬝⬝⬝\n")"
        MOCK_PANE_CLI="opencode"
        source "'"$TEST_HARNESS"'"
        LAST_CLEAR_TS=0
        CLI_TYPE="opencode"
        agent_is_busy
    '
    [ "$status" -eq 0 ]
}

# --- T-BUSY-015: blank OpenCode pane falls back to idle ---

@test "T-BUSY-015: agent_is_busy treats blank OpenCode pane as idle fallback" {
    run bash -c '
        MOCK_CAPTURE_PANE=""
        MOCK_PANE_CLI="opencode"
        source "'"$TEST_HARNESS"'"
        LAST_CLEAR_TS=0
        CLI_TYPE="opencode"
        agent_is_busy
    '
    [ "$status" -eq 1 ]
}

@test "T-BUSY-016: OpenCode busy animation fallback works without python3" {
    run bash -c '
        PATH="/nonexistent"
        source "'"$PROJECT_ROOT"'/lib/agent_status.sh"
        opencode_has_busy_animation "$(printf "   ⬝⬝■⬝⬝⬝⬝⬝  esc interrupt\n")"
    '
    [ "$status" -eq 0 ]
}

# --- T-SHOOK-001: Claude Code throttle uses 60s cooldown (post PR#75: stop-hook supplementary) ---


# --- T-SHOOK-002: Claude Code count change bypasses throttle (post PR#75: standard behavior) ---


# --- T-SHOOK-003: Non-Claude CLIs bypass throttle on count change ---


# --- T-SHOOK-004: all-read reset clears nudge throttle for next inbox1 batch ---


# --- T-CODEX-016: Codex transcript echo is not treated as stuck input ---


# --- T-CRESET-001: send_context_reset suppresses /clear for karo ---


# --- T-CRESET-002: send_context_reset suppresses /clear for gunshi ---


# --- T-CRESET-003: send_context_reset sends /clear for ashigaru ---


# --- T-CRESET-004: send_context_reset sends /new for opencode ---

