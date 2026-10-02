#!/usr/bin/env bats
# test_permission_request_hook_isolated_tmux.bats —
# scripts/permission_request_hook.sh の agent_id 解決を、実際の(ただし
# 隔離された)tmuxサーバに対して検証する試験 (cmd_775 Phase C・
# subtask_775_phaseC_hook_decide)。
#
# scripts/isolated_tmux.sh (cmd_758 QC済helper)でcreate/teardownされる
# 隔離tmuxソケット上のpaneへ `@agent_id` pane optionを設定し、hookが
# 実際に `tmux display-message -t "$TMUX_PANE" -p '#{@agent_id}'` を
# 呼んで正しく解決できることを確認する。__PERMISSION_HOOK_AGENT_ID
# override は一切使わない(実際のtmuxコード経路を通す)。
#
# ★稼働中のmultiagent/shogun本番tmuxソケットへは一切触れない。
#   isolated_tmux.shが作る隔離ソケット(tmp/isolated_tmux_sockets/配下)
#   にのみアクセスする(D006遵守)。
#
# テスト構成:
#   T-PRH-ISO-001: 隔離pane上の実際の@agent_id("ashigaru_iso_test")を
#                  hookが正しく解決し、記録ファイルに反映される
#   T-PRH-ISO-002: 隔離pane上の@agent_idが"shogun"の場合、fail-closed・
#                  記録ファイル/inbox通知ともに一切行われない
#   T-PRH-ISO-003: tmux呼出し自体が失敗する場合(隔離ソケットに存在
#                  しないpane_idを指定)、fail-closed

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/scripts/permission_request_hook.sh"
PYTHON="$SCRIPT_DIR/.venv/bin/python3"
ISOLATED_TMUX="$SCRIPT_DIR/scripts/isolated_tmux.sh"

setup() {
    TEST_TMP="$(mktemp -d)"
    mkdir -p "$TEST_TMP/scripts"
    mkdir -p "$TEST_TMP/queue/tasks"
    mkdir -p "$TEST_TMP/queue/state/permission_requests"
    mkdir -p "$TEST_TMP/queue/state/permission_decisions"
    ln -s "$SCRIPT_DIR/.venv" "$TEST_TMP/.venv"

    cat > "$TEST_TMP/scripts/inbox_write.sh" << 'MOCK'
#!/bin/bash
echo "$@" >> "$(dirname "$0")/../inbox_write_calls.log"
MOCK
    chmod +x "$TEST_TMP/scripts/inbox_write.sh"

    HANDLE_FILE=""
}

teardown() {
    if [ -n "${HANDLE_FILE:-}" ] && [ -f "$HANDLE_FILE" ]; then
        bash "$ISOLATED_TMUX" teardown "$HANDLE_FILE" || true
    fi
    rm -rf "$TEST_TMP"
}

default_json() {
    local command="${1:-echo hello_from_isolated_tmux}"
    "$PYTHON" -c "
import json
print(json.dumps({
    'session_id': 'sess_iso_001',
    'tool_name': 'Bash',
    'tool_input': {'command': '$command', 'description': 'isolated tmux test'},
    'cwd': '/path/to/project',
}))
"
}

# 隔離tmuxセッションを1つ作り、pane上に @agent_id を設定する。
# 呼出後、以下のシェル変数を設定する:
#   ISO_SOCKET_PATH / ISO_PANE_ID / ISO_SERVER_PID
create_isolated_pane_with_agent_id() {
    local agent_id="$1"
    local socket_label="$2"
    HANDLE_FILE="$(bash "$ISOLATED_TMUX" create -L "$socket_label")"
    [ -n "$HANDLE_FILE" ]
    ISO_SOCKET_PATH="$(grep '^SOCKET_PATH=' "$HANDLE_FILE" | cut -d= -f2-)"
    ISO_PANE_ID="$(grep '^PANE_ID=' "$HANDLE_FILE" | cut -d= -f2-)"
    ISO_SERVER_PID="$(grep '^SERVER_PID=' "$HANDLE_FILE" | cut -d= -f2-)"
    [ -n "$ISO_SOCKET_PATH" ]
    [ -n "$ISO_PANE_ID" ]
    tmux -S "$ISO_SOCKET_PATH" set-option -p -t "$ISO_PANE_ID" @agent_id "$agent_id"
}

request_files() {
    find "$TEST_TMP/queue/state/permission_requests" -maxdepth 1 -name '*.yaml' -type f
}

@test "T-PRH-ISO-001: real (isolated) tmux pane @agent_id is resolved and recorded" {
    create_isolated_pane_with_agent_id "ashigaru_iso_test" "cmd775t_iso1"

    local json
    json="$(default_json)"
    TMUX="${ISO_SOCKET_PATH},${ISO_SERVER_PID},0" \
    TMUX_PANE="$ISO_PANE_ID" \
    __PERMISSION_HOOK_ROOT="$TEST_TMP" \
    PERMISSION_HOOK_TIMEOUT_SECONDS="1" \
    __PERMISSION_HOOK_MARGIN_SECONDS="0" \
    run bash "$HOOK_SCRIPT" <<< "$json"

    # 決定ファイルが無いため最終的にはfail-closedするが、記録ファイルは
    # agent_id解決が成功した証拠として書かれているはずである。
    [ "$status" -ne 0 ]
    [ -z "$output" ]

    local f
    f="$(request_files)"
    [ -n "$f" ]
    run "$PYTHON" -c "
import yaml
with open('$f') as fh:
    d = yaml.safe_load(fh)
assert d['agent_id'] == 'ashigaru_iso_test', d
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "T-PRH-ISO-002: real (isolated) tmux pane @agent_id == shogun fails closed with no side effects" {
    create_isolated_pane_with_agent_id "shogun" "cmd775t_iso2"

    local json
    json="$(default_json)"
    TMUX="${ISO_SOCKET_PATH},${ISO_SERVER_PID},0" \
    TMUX_PANE="$ISO_PANE_ID" \
    __PERMISSION_HOOK_ROOT="$TEST_TMP" \
    PERMISSION_HOOK_TIMEOUT_SECONDS="1" \
    __PERMISSION_HOOK_MARGIN_SECONDS="0" \
    run bash "$HOOK_SCRIPT" <<< "$json"

    [ "$status" -ne 0 ]
    [ -z "$output" ]
    [ -z "$(request_files)" ]
    [ ! -f "$TEST_TMP/inbox_write_calls.log" ]
}

@test "T-PRH-ISO-003: tmux display-message failure (nonexistent pane on the isolated socket) fails closed" {
    create_isolated_pane_with_agent_id "ashigaru_iso_test3" "cmd775t_iso3"

    local json
    json="$(default_json)"
    # 実在しないpane_idを指定して tmux display-message 自体を失敗させる。
    TMUX="${ISO_SOCKET_PATH},${ISO_SERVER_PID},0" \
    TMUX_PANE="%999" \
    __PERMISSION_HOOK_ROOT="$TEST_TMP" \
    PERMISSION_HOOK_TIMEOUT_SECONDS="1" \
    __PERMISSION_HOOK_MARGIN_SECONDS="0" \
    run bash "$HOOK_SCRIPT" <<< "$json"

    [ "$status" -ne 0 ]
    [ -z "$output" ]
    [ -z "$(request_files)" ]
}
