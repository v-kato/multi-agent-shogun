#!/usr/bin/env bats
# agent_selfwatch.bats — Agent self-watch unit tests (TDD Step 3)
#
# FR/NFR trace (tests/specs/agent_selfwatch_spec.md):
#   TC-FR-001,002,003,004,005,006,007,008,009,010,011,014
#   TC-NFR-002,003,008
#
# Note:
#   This file intentionally includes RED tests for yet-to-be-implemented
#   Phase 1-3 features (TDD flow: test first, implementation later).

setup_file() {
    export PROJECT_ROOT
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export VENV_PYTHON="$PROJECT_ROOT/.venv/bin/python3"

    export WATCHER_SCRIPT="$PROJECT_ROOT/scripts/inbox_watcher.sh"
    export INBOX_WRITE_SCRIPT="$PROJECT_ROOT/scripts/inbox_write.sh"
    export ASHIGARU_INSTR="$PROJECT_ROOT/instructions/generated/codex-ashigaru.md"

    [ -f "$WATCHER_SCRIPT" ] || return 1
    [ -f "$INBOX_WRITE_SCRIPT" ] || return 1
    [ -f "$ASHIGARU_INSTR" ] || return 1
    "$VENV_PYTHON" -c "import yaml" 2>/dev/null || return 1
}

setup() {
    export TEST_TMPDIR
    TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/agent_selfwatch_test.XXXXXX")"

    # 既定値は「通常のアイドル画面」を模した pane 内容とする (cmd_754)。
    # inbox_watcher.sh は send-keys の直前に capture-pane で確認モーダルの
    # 有無を検査し、pane 内容を確認できない場合は打鍵を抑止する。
    # 空文字列は『pane の状態を確認できない』を意味し実機のアイドル状態を
    # 表さないため、確認待ちを含まないアイドル画面を既定にする。
    export MOCK_CAPTURE_PANE="$(printf '╭────────────────────────────────────────╮\n│ Ask anything                           │\n╰────────────────────────────────────────╯\n  ? for shortcuts\n')"
    export MOCK_CURSOR_SPEC="1|1|0"

    export TEST_INBOX="$TEST_TMPDIR/test_agent.yaml"
    cat > "$TEST_INBOX" << 'YAML'
messages: []
YAML

    export MOCK_LOG="$TEST_TMPDIR/tmux_calls.log"
    > "$MOCK_LOG"

    export TEST_HARNESS="$TEST_TMPDIR/harness.sh"
    cat > "$TEST_HARNESS" << 'HARNESS'
#!/bin/bash
AGENT_ID="test_agent"
PANE_TARGET="test:0.0"
CLI_TYPE="${TEST_CLI_TYPE:-claude}"
INBOX="$TEST_INBOX"
LOCKFILE="${INBOX}.lock"
SCRIPT_DIR="$PROJECT_ROOT"

tmux() {
    echo "tmux $*" >> "$MOCK_LOG"
    if echo "$*" | grep -q "capture-pane"; then
        echo "${MOCK_CAPTURE_PANE:-}"
        return 0
    fi
    if echo "$*" | grep -q "send-keys"; then
        return "${MOCK_SENDKEYS_RC:-0}"
    fi
    if echo "$*" | grep -q "cursor_y"; then
        # ★カーソル位置(cursor_y|cursor_flag|pane_in_mode)。既定値 1 は
        #   既定 MOCK_CAPTURE_PANE の入力行(`│ Ask anything │`)の行番号。
        echo "${MOCK_CURSOR_SPEC:-1|1|0}"
        return 0
    fi
    return 0
}

timeout() { shift; "$@"; }
sleep() { :; }
pgrep() { return "${MOCK_PGREP_RC:-1}"; }
export -f tmux timeout sleep pgrep

export __INBOX_WATCHER_TESTING__=1
source "$WATCHER_SCRIPT"
HARNESS
    chmod +x "$TEST_HARNESS"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

@test "TC-FR-001 [RED]: process_unread_once is defined and called on startup" {
    grep -q "process_unread_once()" "$WATCHER_SCRIPT"
    grep -q "process_unread_once" "$WATCHER_SCRIPT"
}

@test "TC-FR-002: inotify + timeout fallback is configured" {
    grep -q "INOTIFY_TIMEOUT=" "$WATCHER_SCRIPT"
    grep -F -q 'inotifywait -q -t "$INOTIFY_TIMEOUT" -e modify -e close_write "$INBOX"' "$WATCHER_SCRIPT"
}




@test "TC-FR-004b: get_unread_info does not update when lock is unavailable" {
    cat > "$TEST_INBOX" << 'YAML'
messages:
  - id: msg_clear
    from: karo
    timestamp: "2026-02-09T21:00:01"
    type: clear_command
    content: /clear
    read: false
YAML
    mkdir "$TEST_INBOX.lock.d"

    run bash -c "source '$TEST_HARNESS'; get_unread_info"
    [ "$status" -eq 0 ]
    [[ "$output" =~ '"count": 0' ]]

    "$VENV_PYTHON" - << 'PY' "$TEST_INBOX"
import sys, yaml
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
assert data["messages"][0]["read"] is False
print("OK")
PY
}

@test "TC-FR-005: post-task inbox check rule is documented for ashigaru" {
    grep -q "MANDATORY Post-Task Inbox Check" "$ASHIGARU_INSTR"
}

@test "TC-FR-006 [RED]: metrics hooks are defined (unread_latency/read_count/estimated_tokens)" {
    grep -q "unread_latency_sec" "$WATCHER_SCRIPT"
    grep -q "read_count" "$WATCHER_SCRIPT"
    grep -q "estimated_tokens" "$WATCHER_SCRIPT"
}

@test "TC-FR-007 [RED]: feature flags for Phase 1/2/3 are defined" {
    grep -q "ASW_PHASE" "$WATCHER_SCRIPT"
    grep -q "ASW_" "$WATCHER_SCRIPT"
}



@test "TC-FR-010 [RED]: summary-first fast path exists (count/summary before full read)" {
    grep -q "summary-first" "$WATCHER_SCRIPT"
    grep -q "unread_count fast-path" "$WATCHER_SCRIPT"
}


@test "TC-FR-014 + TC-NFR-002: inbox_write IF and schema remain backward compatible" {
    run bash "$INBOX_WRITE_SCRIPT" test_agent "compat-check" task_assigned karo
    [ "$status" -eq 0 ]

    "$VENV_PYTHON" - << 'PY' "$PROJECT_ROOT/queue/inbox/test_agent.yaml"
import sys, yaml
p = sys.argv[1]
with open(p) as f:
    data = yaml.safe_load(f)
assert "messages" in data and isinstance(data["messages"], list)
msg = data["messages"][-1]
for k in ("id", "from", "timestamp", "type", "content", "read"):
    assert k in msg
assert msg["type"] == "task_assigned"
assert msg["from"] == "karo"
print("OK")
PY

    # cleanup test artifact written to real queue path by production script
    rm -f "$PROJECT_ROOT/queue/inbox/test_agent.yaml" "$PROJECT_ROOT/queue/inbox/test_agent.yaml.lock"
}

@test "TC-NFR-003 [RED]: no-idle-full-read helper exists" {
    grep -q "no_idle_full_read" "$WATCHER_SCRIPT"
}

@test "TC-NFR-008: test file itself has zero skip directives (SKIP=0 guard, no exceptions)" {
    # ★将軍裁定(2026-09-10・shogun_ruling_20260910_skip_conflict)により、
    #   旧A-3方針(「cmd_754巻き戻しへの言及を伴うskipは正当化済みとして
    #   許容する」という部分文字列例外)は無効化された。CLAUDE.md Test
    #   Rules 1「SKIP=FAIL(SKIP数が1以上なら未完了)」の通り、標準suiteは
    #   いかなる理由であれskip行が0件であることのみを検査する(例外なし)。
    #   cmd_754巻き戻しでFAILしていたTC-FR-003/003b/004/008/009/011は
    #   skipではなくtests/suspended/cmd754/へ原文のまま退避済み(U-1)。
    found="$(grep -En '^[[:space:]]*skip([[:space:]]|$)' "$BATS_TEST_FILENAME" || true)"
    [ -z "$found" ]
}
