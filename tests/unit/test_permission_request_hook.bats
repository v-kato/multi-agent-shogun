#!/usr/bin/env bats
# test_permission_request_hook.bats — scripts/permission_request_hook.sh unit tests
# (cmd_775 Phase C・subtask_775_phaseC_hook_decide)
#
# 実際の scripts/permission_request_hook.sh を、環境変数override
# (__PERMISSION_HOOK_ROOT / __PERMISSION_HOOK_AGENT_ID / タイミング系)を
# 使って隔離した状態で呼び出す。tmux実機を用いる試験は別ファイル
# tests/unit/test_permission_request_hook_isolated_tmux.bats に分離した
# (scripts/isolated_tmux.sh使用・稼働中の他agent paneへは一切触れない)。
#
# テスト構成:
#   T-PRH-001: 不正JSON(構文エラー) → fail-closed
#   T-PRH-002: JSON最上位がdict以外 → fail-closed
#   T-PRH-003〜006: 必須field欠落/型不正 → fail-closed
#   T-PRH-007: agent_id解決失敗(override無し・TMUX_PANE無し) → fail-closed
#   T-PRH-008: agent_id=="shogun" → fail-closed・記録/inbox無し
#   T-PRH-009: 正常系: 記録ファイルが正しいschemaで書かれる
#   T-PRH-010/011: task_id/parent_cmdの転記(存在時/不在時)
#   T-PRH-012: tool_use_id欠落時はnull
#   T-PRH-013: permission_suggestions転記
#   T-PRH-014: inbox_write失敗時も処理継続
#   T-PRH-015: timeout到達・決定なし → fail-closed(deferToUser相当)
#   T-PRH-016: 決定=deny → 正しいJSON出力・exit0
#   T-PRH-017: 決定=allow → 正しいJSON出力(behaviorのみ)・exit0
#   T-PRH-018: 決定=defer → fail-closed
#   T-PRH-019: 決定schema不正(decision値不正) → fail-closed
#   T-PRH-020: 決定本文のrequest_id不一致 → fail-closed
#   T-PRH-021: 記録ディレクトリ書込み不能 → fail-closed
#   T-PRH-022: 同時2要求の分離(異なるtool_input→異なるrequest_id)
#   T-PRH-023: allow出力コードパスが本ファイル中1箇所のみ(静的確認)
#   T-PRH-024: 決定ファイル読取のidempotency(2回連続呼出しで同じ決定)
#   T-PRH-025: ポーリング中(timeout到達前)に届いた決定の一意な消費
#
# 以下はcmd_775 Phase D redo2(将軍裁定(ii)(iii))で追加:
#   T-PRH-026: hook_result outcome=allow が記録ファイルへ書かれる
#   T-PRH-027: hook_result outcome=deny が記録ファイルへ書かれる
#   T-PRH-028: hook_result outcome=defer_timeout が記録ファイルへ書かれる
#              (deadline到達・決定なし)
#   T-PRH-029: hook_result outcome=failed が記録ファイルへ書かれる
#              (決定ファイルschema不正)
#   T-PRH-030: 旧`defer`決定値はhook_result outcome=failedになる
#              (defer廃止後の後方互換確認)
#   T-PRH-031: hook_result追記は既存フィールドを一切変更しない

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/scripts/permission_request_hook.sh"
PYTHON="$SCRIPT_DIR/.venv/bin/python3"

setup() {
    TEST_TMP="$(mktemp -d)"
    mkdir -p "$TEST_TMP/scripts"
    mkdir -p "$TEST_TMP/queue/tasks"
    mkdir -p "$TEST_TMP/queue/state/permission_requests"
    mkdir -p "$TEST_TMP/queue/state/permission_decisions"
    # プロジェクトrootの.venvをそのまま使う(python依存のため実体をリンク)
    ln -s "$SCRIPT_DIR/.venv" "$TEST_TMP/.venv"

    # inbox_write.sh のモック: 呼出し引数をログへ記録するだけ
    cat > "$TEST_TMP/scripts/inbox_write.sh" << 'MOCK'
#!/bin/bash
echo "$@" >> "$(dirname "$0")/../inbox_write_calls.log"
MOCK
    chmod +x "$TEST_TMP/scripts/inbox_write.sh"
}

teardown() {
    rm -rf "$TEST_TMP"
}

# デフォルトの正常なhook入力JSONを組み立てる(python経由でjson.dumpsして
# エスケープを安全にする)
default_json() {
    local command="${1:-echo hello}"
    "$PYTHON" -c "
import json
print(json.dumps({
    'session_id': 'sess_test_001',
    'prompt_id': 'prompt_001',
    'tool_use_id': 'toolu_should_be_ignored',
    'hook_event_name': 'PermissionRequest',
    'tool_name': 'Bash',
    'tool_input': {'command': '$command', 'description': 'test command'},
    'cwd': '/path/to/project',
    'transcript_path': '/tmp/transcript.jsonl',
    'permission_mode': 'default',
}))
"
}

run_hook() {
    local json="$1"
    local agent_id="${2:-ashigaru9}"
    __PERMISSION_HOOK_ROOT="$TEST_TMP" \
    __PERMISSION_HOOK_AGENT_ID="$agent_id" \
    __PERMISSION_HOOK_POLL_INTERVAL_SECONDS="0.2" \
    PERMISSION_HOOK_TIMEOUT_SECONDS="2" \
    __PERMISSION_HOOK_MARGIN_SECONDS="0" \
    run bash "$HOOK_SCRIPT" <<< "$json"
}

request_files() {
    find "$TEST_TMP/queue/state/permission_requests" -maxdepth 1 -name '*.yaml' -type f
}

@test "T-PRH-001: invalid JSON syntax fails closed (no output, nonzero exit)" {
    run_hook '{not valid json'
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    [ -z "$(request_files)" ]
}

@test "T-PRH-002: JSON top-level is a list, not an object" {
    run_hook '[1, 2, 3]'
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    [ -z "$(request_files)" ]
}

@test "T-PRH-003: missing session_id fails closed" {
    run_hook '{"tool_name":"Bash","tool_input":{"command":"echo hi"},"cwd":"/tmp"}'
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    [ -z "$(request_files)" ]
}

@test "T-PRH-004: empty tool_name fails closed" {
    run_hook '{"session_id":"s1","tool_name":"","tool_input":{"command":"echo hi"},"cwd":"/tmp"}'
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "T-PRH-005: missing cwd fails closed" {
    run_hook '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"echo hi"}}'
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "T-PRH-006: tool_input is not an object fails closed" {
    run_hook '{"session_id":"s1","tool_name":"Bash","tool_input":"echo hi","cwd":"/tmp"}'
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "T-PRH-007: agent_id unresolved (no override, no TMUX_PANE) fails closed" {
    local json
    json="$(default_json)"
    __PERMISSION_HOOK_ROOT="$TEST_TMP" \
    __PERMISSION_HOOK_AGENT_ID="" \
    TMUX_PANE="" \
    PERMISSION_HOOK_TIMEOUT_SECONDS="2" \
    run bash "$HOOK_SCRIPT" <<< "$json"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    [ -z "$(request_files)" ]
}

@test "T-PRH-008: agent_id==shogun fails closed with no record and no inbox notification" {
    local json
    json="$(default_json)"
    run_hook "$json" "shogun"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    [ -z "$(request_files)" ]
    [ ! -f "$TEST_TMP/inbox_write_calls.log" ]
}

@test "T-PRH-009: happy path writes a correctly-shaped record file" {
    local json
    json="$(default_json 'echo hello_from_test')"
    # 決定なしで確実にtimeoutさせて記録のみ検査する(short timeout)
    __PERMISSION_HOOK_ROOT="$TEST_TMP" \
    __PERMISSION_HOOK_AGENT_ID="ashigaru9" \
    __PERMISSION_HOOK_POLL_INTERVAL_SECONDS="0.2" \
    PERMISSION_HOOK_TIMEOUT_SECONDS="1" \
    __PERMISSION_HOOK_MARGIN_SECONDS="0" \
    run bash "$HOOK_SCRIPT" <<< "$json"
    [ "$status" -ne 0 ]

    local f
    f="$(request_files)"
    [ -n "$f" ]
    [ "$(find "$TEST_TMP/queue/state/permission_requests" -maxdepth 1 -name '*.yaml' -type f | wc -l)" -eq 1 ]

    run "$PYTHON" -c "
import yaml
with open('$f') as fh:
    d = yaml.safe_load(fh)
assert d['agent_id'] == 'ashigaru9', d
assert d['session_id'] == 'sess_test_001', d
assert d['tool_name'] == 'Bash', d
assert d['tool_input']['command'] == 'echo hello_from_test', d
assert d['cwd'] == '/path/to/project', d
assert d['request_id'] + '.yaml' == '$(basename "$f")', d
assert 'received_at' in d and d['received_at'], d
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "T-PRH-010: task_id/parent_cmd are copied from queue/tasks/<agent>.yaml when present" {
    cat > "$TEST_TMP/queue/tasks/ashigaru9.yaml" << 'YAML'
task:
  task_id: subtask_999_example
  parent_cmd: cmd_999
  status: assigned
YAML
    local json
    json="$(default_json)"
    __PERMISSION_HOOK_ROOT="$TEST_TMP" \
    __PERMISSION_HOOK_AGENT_ID="ashigaru9" \
    PERMISSION_HOOK_TIMEOUT_SECONDS="1" \
    __PERMISSION_HOOK_MARGIN_SECONDS="0" \
    run bash "$HOOK_SCRIPT" <<< "$json"

    local f
    f="$(request_files)"
    [ -n "$f" ]
    run "$PYTHON" -c "
import yaml
with open('$f') as fh:
    d = yaml.safe_load(fh)
assert d['task_id'] == 'subtask_999_example', d
assert d['parent_cmd'] == 'cmd_999', d
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "T-PRH-011: task_id/parent_cmd are null when task YAML is absent" {
    local json
    json="$(default_json)"
    __PERMISSION_HOOK_ROOT="$TEST_TMP" \
    __PERMISSION_HOOK_AGENT_ID="ashigaru_no_task" \
    PERMISSION_HOOK_TIMEOUT_SECONDS="1" \
    __PERMISSION_HOOK_MARGIN_SECONDS="0" \
    run bash "$HOOK_SCRIPT" <<< "$json"

    local f
    f="$(request_files)"
    [ -n "$f" ]
    run "$PYTHON" -c "
import yaml
with open('$f') as fh:
    d = yaml.safe_load(fh)
assert d['task_id'] is None, d
assert d['parent_cmd'] is None, d
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "T-PRH-012: tool_use_id absent from input becomes null in the record" {
    local json
    json="$("$PYTHON" -c "
import json
print(json.dumps({
    'session_id': 's1',
    'tool_name': 'Bash',
    'tool_input': {'command': 'echo hi'},
    'cwd': '/tmp',
}))
")"
    __PERMISSION_HOOK_ROOT="$TEST_TMP" \
    __PERMISSION_HOOK_AGENT_ID="ashigaru9" \
    PERMISSION_HOOK_TIMEOUT_SECONDS="1" \
    __PERMISSION_HOOK_MARGIN_SECONDS="0" \
    run bash "$HOOK_SCRIPT" <<< "$json"

    local f
    f="$(request_files)"
    [ -n "$f" ]
    run "$PYTHON" -c "
import yaml
with open('$f') as fh:
    d = yaml.safe_load(fh)
assert d['tool_use_id'] is None, d
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "T-PRH-013: permission_suggestions is transcribed into the record when present" {
    local json
    json="$("$PYTHON" -c "
import json
print(json.dumps({
    'session_id': 's1',
    'tool_name': 'Bash',
    'tool_input': {'command': 'echo hi'},
    'cwd': '/tmp',
    'permission_suggestions': ['Bash(echo:*)'],
}))
")"
    __PERMISSION_HOOK_ROOT="$TEST_TMP" \
    __PERMISSION_HOOK_AGENT_ID="ashigaru9" \
    PERMISSION_HOOK_TIMEOUT_SECONDS="1" \
    __PERMISSION_HOOK_MARGIN_SECONDS="0" \
    run bash "$HOOK_SCRIPT" <<< "$json"

    local f
    f="$(request_files)"
    [ -n "$f" ]
    run "$PYTHON" -c "
import yaml
with open('$f') as fh:
    d = yaml.safe_load(fh)
assert d['permission_suggestions'] == ['Bash(echo:*)'], d
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "T-PRH-014: inbox_write failure does not abort the hook (record still written)" {
    # inbox_write.sh を必ず失敗するモックへ差し替える
    cat > "$TEST_TMP/scripts/inbox_write.sh" << 'MOCK'
#!/bin/bash
exit 1
MOCK
    chmod +x "$TEST_TMP/scripts/inbox_write.sh"

    local json
    json="$(default_json)"
    __PERMISSION_HOOK_ROOT="$TEST_TMP" \
    __PERMISSION_HOOK_AGENT_ID="ashigaru9" \
    PERMISSION_HOOK_TIMEOUT_SECONDS="1" \
    __PERMISSION_HOOK_MARGIN_SECONDS="0" \
    run bash "$HOOK_SCRIPT" <<< "$json"

    # 記録ファイルは書けているはず(inbox失敗は非致命的)
    [ -n "$(request_files)" ]
}

@test "T-PRH-015: timeout with no decision file fails closed (deferToUser equivalent)" {
    local json
    json="$(default_json)"
    local start end elapsed
    start="$SECONDS"
    __PERMISSION_HOOK_ROOT="$TEST_TMP" \
    __PERMISSION_HOOK_AGENT_ID="ashigaru9" \
    __PERMISSION_HOOK_POLL_INTERVAL_SECONDS="1" \
    PERMISSION_HOOK_TIMEOUT_SECONDS="3" \
    __PERMISSION_HOOK_MARGIN_SECONDS="1" \
    run bash "$HOOK_SCRIPT" <<< "$json"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "T-PRH-016: decision=deny returns correct hookSpecificOutput JSON and exits 0" {
    local json
    json="$(default_json)"
    # __PERMISSION_HOOK_UTC_TS_OVERRIDE を両呼出しで揃えることで、
    # 実時刻の秒境界に依存せず同一request_idを決定的に得る(test専用)。
    __PERMISSION_HOOK_ROOT="$TEST_TMP" \
    __PERMISSION_HOOK_AGENT_ID="ashigaru9" \
    __PERMISSION_HOOK_UTC_TS_OVERRIDE="20260917T120000Z" \
    PERMISSION_HOOK_TIMEOUT_SECONDS="1" \
    __PERMISSION_HOOK_MARGIN_SECONDS="0" \
    run bash "$HOOK_SCRIPT" <<< "$json"
    local f request_id
    f="$(request_files)"
    [ -n "$f" ]
    request_id="$(basename "$f" .yaml)"

    cat > "$TEST_TMP/queue/state/permission_decisions/${request_id}.yaml" << YAML
request_id: ${request_id}
decision: deny
by: shogun
reason: "D002-E1(d)の絶対パス条件を満たさない。mktemp -d /tmp/x.XXXXXX を使え。"
machine_check: null
lord_channel: null
decided_at: "2026-09-17T12:40:00Z"
YAML

    __PERMISSION_HOOK_ROOT="$TEST_TMP" \
    __PERMISSION_HOOK_AGENT_ID="ashigaru9" \
    __PERMISSION_HOOK_UTC_TS_OVERRIDE="20260917T120000Z" \
    __PERMISSION_HOOK_POLL_INTERVAL_SECONDS="0.2" \
    PERMISSION_HOOK_TIMEOUT_SECONDS="30" \
    __PERMISSION_HOOK_MARGIN_SECONDS="25" \
    run bash "$HOOK_SCRIPT" <<< "$json"

    [ "$status" -eq 0 ]
    run "$PYTHON" -c "
import json
d = json.loads('''$output''')
hso = d['hookSpecificOutput']
assert hso['hookEventName'] == 'PermissionRequest', hso
dec = hso['decision']
assert dec['behavior'] == 'deny', dec
assert 'mktemp -d /tmp/x.XXXXXX' in dec['message'], dec
assert dec['interrupt'] is False, dec
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "T-PRH-017: decision=allow returns behavior-only JSON (no updatedPermissions) and exits 0" {
    local json
    json="$(default_json)"
    __PERMISSION_HOOK_ROOT="$TEST_TMP" \
    __PERMISSION_HOOK_AGENT_ID="ashigaru9" \
    __PERMISSION_HOOK_UTC_TS_OVERRIDE="20260917T120000Z" \
    PERMISSION_HOOK_TIMEOUT_SECONDS="1" \
    __PERMISSION_HOOK_MARGIN_SECONDS="0" \
    run bash "$HOOK_SCRIPT" <<< "$json"
    local f request_id
    f="$(request_files)"
    request_id="$(basename "$f" .yaml)"

    cat > "$TEST_TMP/queue/state/permission_decisions/${request_id}.yaml" << YAML
request_id: ${request_id}
decision: allow
by: lord
reason: "殿が端末で allow と回答した"
machine_check: null
lord_channel: terminal
decided_at: "2026-09-17T12:40:00Z"
YAML

    __PERMISSION_HOOK_ROOT="$TEST_TMP" \
    __PERMISSION_HOOK_AGENT_ID="ashigaru9" \
    __PERMISSION_HOOK_UTC_TS_OVERRIDE="20260917T120000Z" \
    __PERMISSION_HOOK_POLL_INTERVAL_SECONDS="0.2" \
    PERMISSION_HOOK_TIMEOUT_SECONDS="30" \
    __PERMISSION_HOOK_MARGIN_SECONDS="25" \
    run bash "$HOOK_SCRIPT" <<< "$json"

    [ "$status" -eq 0 ]
    [ "$output" = '{"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "allow"}}}' ]
    [[ "$output" != *"updatedPermissions"* ]]
}

@test "T-PRH-018: decision=defer fails closed (falls through to normal modal)" {
    local json
    json="$(default_json)"
    __PERMISSION_HOOK_ROOT="$TEST_TMP" \
    __PERMISSION_HOOK_AGENT_ID="ashigaru9" \
    __PERMISSION_HOOK_UTC_TS_OVERRIDE="20260917T120000Z" \
    PERMISSION_HOOK_TIMEOUT_SECONDS="1" \
    __PERMISSION_HOOK_MARGIN_SECONDS="0" \
    run bash "$HOOK_SCRIPT" <<< "$json"
    local f request_id
    f="$(request_files)"
    request_id="$(basename "$f" .yaml)"

    cat > "$TEST_TMP/queue/state/permission_decisions/${request_id}.yaml" << YAML
request_id: ${request_id}
decision: defer
by: shogun
reason: "殿の判断を仰ぐ(ntfy送信済み)"
machine_check: null
lord_channel: ntfy
decided_at: "2026-09-17T12:40:00Z"
YAML

    __PERMISSION_HOOK_ROOT="$TEST_TMP" \
    __PERMISSION_HOOK_AGENT_ID="ashigaru9" \
    __PERMISSION_HOOK_UTC_TS_OVERRIDE="20260917T120000Z" \
    __PERMISSION_HOOK_POLL_INTERVAL_SECONDS="0.2" \
    PERMISSION_HOOK_TIMEOUT_SECONDS="30" \
    __PERMISSION_HOOK_MARGIN_SECONDS="25" \
    run bash "$HOOK_SCRIPT" <<< "$json"

    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "T-PRH-019: malformed decision (invalid decision value) fails closed, never allow" {
    local json
    json="$(default_json)"
    __PERMISSION_HOOK_ROOT="$TEST_TMP" \
    __PERMISSION_HOOK_AGENT_ID="ashigaru9" \
    __PERMISSION_HOOK_UTC_TS_OVERRIDE="20260917T120000Z" \
    PERMISSION_HOOK_TIMEOUT_SECONDS="1" \
    __PERMISSION_HOOK_MARGIN_SECONDS="0" \
    run bash "$HOOK_SCRIPT" <<< "$json"
    local f request_id
    f="$(request_files)"
    request_id="$(basename "$f" .yaml)"

    cat > "$TEST_TMP/queue/state/permission_decisions/${request_id}.yaml" << YAML
request_id: ${request_id}
decision: maybe_allow_i_guess
by: shogun
reason: "不正な値"
decided_at: "2026-09-17T12:40:00Z"
YAML

    __PERMISSION_HOOK_ROOT="$TEST_TMP" \
    __PERMISSION_HOOK_AGENT_ID="ashigaru9" \
    __PERMISSION_HOOK_UTC_TS_OVERRIDE="20260917T120000Z" \
    __PERMISSION_HOOK_POLL_INTERVAL_SECONDS="0.2" \
    PERMISSION_HOOK_TIMEOUT_SECONDS="30" \
    __PERMISSION_HOOK_MARGIN_SECONDS="25" \
    run bash "$HOOK_SCRIPT" <<< "$json"

    [ "$status" -ne 0 ]
    [ -z "$output" ]
    [[ "$output" != *"allow"* ]]
}

@test "T-PRH-020: decision body request_id mismatch fails closed, never allow" {
    local json
    json="$(default_json)"
    __PERMISSION_HOOK_ROOT="$TEST_TMP" \
    __PERMISSION_HOOK_AGENT_ID="ashigaru9" \
    __PERMISSION_HOOK_UTC_TS_OVERRIDE="20260917T120000Z" \
    PERMISSION_HOOK_TIMEOUT_SECONDS="1" \
    __PERMISSION_HOOK_MARGIN_SECONDS="0" \
    run bash "$HOOK_SCRIPT" <<< "$json"
    local f request_id
    f="$(request_files)"
    request_id="$(basename "$f" .yaml)"

    cat > "$TEST_TMP/queue/state/permission_decisions/${request_id}.yaml" << YAML
request_id: some_other_request_id_entirely
decision: allow
by: lord
reason: "殿がallowと回答"
decided_at: "2026-09-17T12:40:00Z"
YAML

    __PERMISSION_HOOK_ROOT="$TEST_TMP" \
    __PERMISSION_HOOK_AGENT_ID="ashigaru9" \
    __PERMISSION_HOOK_UTC_TS_OVERRIDE="20260917T120000Z" \
    __PERMISSION_HOOK_POLL_INTERVAL_SECONDS="0.2" \
    PERMISSION_HOOK_TIMEOUT_SECONDS="30" \
    __PERMISSION_HOOK_MARGIN_SECONDS="25" \
    run bash "$HOOK_SCRIPT" <<< "$json"

    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "T-PRH-021: unwritable permission_requests directory fails closed" {
    # permission_requests を「ディレクトリではないファイル」に差し替えて
    # os.makedirs(exist_ok=True) を失敗させる(chmod/rootに依存しない
    # 決定的な故障注入)。
    rm -rf "$TEST_TMP/queue/state/permission_requests"
    touch "$TEST_TMP/queue/state/permission_requests"

    local json
    json="$(default_json)"
    __PERMISSION_HOOK_ROOT="$TEST_TMP" \
    __PERMISSION_HOOK_AGENT_ID="ashigaru9" \
    PERMISSION_HOOK_TIMEOUT_SECONDS="1" \
    __PERMISSION_HOOK_MARGIN_SECONDS="0" \
    run bash "$HOOK_SCRIPT" <<< "$json"

    [ "$status" -ne 0 ]
    [ -z "$output" ]
    [ ! -f "$TEST_TMP/inbox_write_calls.log" ]
}

@test "T-PRH-022: two concurrent requests with different tool_input get distinct request_ids" {
    local json1 json2
    json1="$(default_json 'echo request_one')"
    json2="$(default_json 'echo request_two')"

    __PERMISSION_HOOK_ROOT="$TEST_TMP" \
    __PERMISSION_HOOK_AGENT_ID="ashigaru9" \
    PERMISSION_HOOK_TIMEOUT_SECONDS="1" \
    __PERMISSION_HOOK_MARGIN_SECONDS="0" \
    run bash "$HOOK_SCRIPT" <<< "$json1"

    __PERMISSION_HOOK_ROOT="$TEST_TMP" \
    __PERMISSION_HOOK_AGENT_ID="ashigaru9" \
    PERMISSION_HOOK_TIMEOUT_SECONDS="1" \
    __PERMISSION_HOOK_MARGIN_SECONDS="0" \
    run bash "$HOOK_SCRIPT" <<< "$json2"

    local count
    count="$(find "$TEST_TMP/queue/state/permission_requests" -maxdepth 1 -name '*.yaml' -type f | wc -l)"
    [ "$count" -eq 2 ]
}

@test "T-PRH-023: the JSON output line that grants allow appears exactly once in the source" {
    run grep -c "'behavior': 'allow'" "$HOOK_SCRIPT"
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ]
}

@test "T-PRH-024: re-reading an already-decided decision file is idempotent (no contradiction)" {
    # ①将軍裁定(d)相当: hookが決定待ちの間に決定が届き、後から別の
    # hook起動(同一request_id)が同じ決定ファイルを読んでも、常に同じ
    # 結果(allow)を返し、矛盾した結果を返さないことを確認する。
    local json
    json="$(default_json)"
    __PERMISSION_HOOK_ROOT="$TEST_TMP" \
    __PERMISSION_HOOK_AGENT_ID="ashigaru9" \
    __PERMISSION_HOOK_UTC_TS_OVERRIDE="20260917T120000Z" \
    PERMISSION_HOOK_TIMEOUT_SECONDS="1" \
    __PERMISSION_HOOK_MARGIN_SECONDS="0" \
    run bash "$HOOK_SCRIPT" <<< "$json"
    local f request_id
    f="$(request_files)"
    request_id="$(basename "$f" .yaml)"

    cat > "$TEST_TMP/queue/state/permission_decisions/${request_id}.yaml" << YAML
request_id: ${request_id}
decision: allow
by: lord
reason: "殿がallowと回答"
decided_at: "2026-09-17T12:40:00Z"
YAML

    __PERMISSION_HOOK_ROOT="$TEST_TMP" \
    __PERMISSION_HOOK_AGENT_ID="ashigaru9" \
    __PERMISSION_HOOK_UTC_TS_OVERRIDE="20260917T120000Z" \
    __PERMISSION_HOOK_POLL_INTERVAL_SECONDS="0.2" \
    PERMISSION_HOOK_TIMEOUT_SECONDS="30" \
    __PERMISSION_HOOK_MARGIN_SECONDS="25" \
    run bash "$HOOK_SCRIPT" <<< "$json"
    local first_status="$status" first_output="$output"

    __PERMISSION_HOOK_ROOT="$TEST_TMP" \
    __PERMISSION_HOOK_AGENT_ID="ashigaru9" \
    __PERMISSION_HOOK_UTC_TS_OVERRIDE="20260917T120000Z" \
    __PERMISSION_HOOK_POLL_INTERVAL_SECONDS="0.2" \
    PERMISSION_HOOK_TIMEOUT_SECONDS="30" \
    __PERMISSION_HOOK_MARGIN_SECONDS="25" \
    run bash "$HOOK_SCRIPT" <<< "$json"
    local second_status="$status" second_output="$output"

    [ "$first_status" -eq 0 ]
    [ "$second_status" -eq 0 ]
    [ "$first_output" = "$second_output" ]

    # 決定ファイル自体もこの2回の読取りで一切変更されていない(単一の
    # 決定が監査ログとして安定していることの確認)。
    run "$PYTHON" -c "
import yaml
with open('$TEST_TMP/queue/state/permission_decisions/${request_id}.yaml') as fh:
    d = yaml.safe_load(fh)
assert d['decision'] == 'allow', d
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "T-PRH-025: a decision written while the hook is actively polling (not yet timed out) is picked up exactly once, with no contradictory output" {
    # ①将軍裁定(d)相当・より実機に近い形: hook起動を1本のプロセスとして
    # backgroundで走らせ、その決定待ちポーリングの最中(timeout到達前)に
    # 決定ファイルを書き込む。1つのhookプロセスは1回しかstdoutへ出力
    # できない構造(1回のbash script実行・複数箇所からの出力なし)である
    # ため、「後から来た決定と二重実行・矛盾する」余地が無いことを、
    # 実際に並行させて確認する。
    local json
    json="$(default_json 'echo concurrent_decision_test')"

    local stdout_file="$TEST_TMP/bg_stdout.txt"
    (
        __PERMISSION_HOOK_ROOT="$TEST_TMP" \
        __PERMISSION_HOOK_AGENT_ID="ashigaru9" \
        __PERMISSION_HOOK_POLL_INTERVAL_SECONDS="0.3" \
        PERMISSION_HOOK_TIMEOUT_SECONDS="8" \
        __PERMISSION_HOOK_MARGIN_SECONDS="1" \
        bash "$HOOK_SCRIPT" <<< "$json" > "$stdout_file"
        echo "$?" > "$TEST_TMP/bg_exit_code.txt"
    ) &
    local bg_pid=$!

    # 記録ファイルが現れるまで待つ(最大5秒。busy-wait)。
    local waited=0
    while [ -z "$(request_files)" ] && [ "$waited" -lt 50 ]; do
        sleep 0.1
        waited=$((waited + 1))
    done
    local f request_id
    f="$(request_files)"
    [ -n "$f" ]
    request_id="$(basename "$f" .yaml)"

    # hookがまだポーリング中(timeoutにはまだ遠い)であることを明示的に
    # 待ってから決定を書く。
    sleep 0.6

    cat > "$TEST_TMP/queue/state/permission_decisions/${request_id}.yaml" << YAML
request_id: ${request_id}
decision: allow
by: lord
reason: "殿がallowと回答(ポーリング中に到着)"
decided_at: "2026-09-17T12:40:00Z"
YAML

    wait "$bg_pid"
    local exit_code
    exit_code="$(cat "$TEST_TMP/bg_exit_code.txt")"
    local bg_output
    bg_output="$(cat "$stdout_file")"

    [ "$exit_code" -eq 0 ]
    [ "$bg_output" = '{"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "allow"}}}' ]

    # ちょうど1個のrecordファイルしか無く、決定ファイルも1個のみ・
    # 内容が書いたとおりで矛盾なく安定している。
    [ "$(find "$TEST_TMP/queue/state/permission_requests" -maxdepth 1 -name '*.yaml' -type f | wc -l)" -eq 1 ]
    [ "$(find "$TEST_TMP/queue/state/permission_decisions" -maxdepth 1 -name '*.yaml' -type f | wc -l)" -eq 1 ]
}

@test "T-PRH-026: hook_result outcome=allow is recorded in the request file after an allow decision" {
    local json
    json="$(default_json)"
    __PERMISSION_HOOK_ROOT="$TEST_TMP" \
    __PERMISSION_HOOK_AGENT_ID="ashigaru9" \
    __PERMISSION_HOOK_UTC_TS_OVERRIDE="20260917T120000Z" \
    __PERMISSION_HOOK_POLL_INTERVAL_SECONDS="0.2" \
    PERMISSION_HOOK_TIMEOUT_SECONDS="1" \
    __PERMISSION_HOOK_MARGIN_SECONDS="0" \
    run bash "$HOOK_SCRIPT" <<< "$json"
    local f request_id
    f="$(request_files)"
    request_id="$(basename "$f" .yaml)"

    cat > "$TEST_TMP/queue/state/permission_decisions/${request_id}.yaml" << YAML
request_id: ${request_id}
decision: allow
by: lord
reason: "殿がallowと回答"
decided_at: "2026-09-17T12:40:00Z"
YAML

    __PERMISSION_HOOK_ROOT="$TEST_TMP" \
    __PERMISSION_HOOK_AGENT_ID="ashigaru9" \
    __PERMISSION_HOOK_UTC_TS_OVERRIDE="20260917T120000Z" \
    __PERMISSION_HOOK_POLL_INTERVAL_SECONDS="0.2" \
    PERMISSION_HOOK_TIMEOUT_SECONDS="30" \
    __PERMISSION_HOOK_MARGIN_SECONDS="25" \
    run bash "$HOOK_SCRIPT" <<< "$json"
    [ "$status" -eq 0 ]

    run "$PYTHON" -c "
import yaml
with open('$f') as fh:
    d = yaml.safe_load(fh)
assert d['hook_result']['outcome'] == 'allow', d
assert isinstance(d['hook_result']['returned_at'], str) and d['hook_result']['returned_at'], d
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "T-PRH-027: hook_result outcome=deny is recorded in the request file after a deny decision" {
    local json
    json="$(default_json)"
    __PERMISSION_HOOK_ROOT="$TEST_TMP" \
    __PERMISSION_HOOK_AGENT_ID="ashigaru9" \
    __PERMISSION_HOOK_UTC_TS_OVERRIDE="20260917T120000Z" \
    __PERMISSION_HOOK_POLL_INTERVAL_SECONDS="0.2" \
    PERMISSION_HOOK_TIMEOUT_SECONDS="1" \
    __PERMISSION_HOOK_MARGIN_SECONDS="0" \
    run bash "$HOOK_SCRIPT" <<< "$json"
    local f request_id
    f="$(request_files)"
    request_id="$(basename "$f" .yaml)"

    cat > "$TEST_TMP/queue/state/permission_decisions/${request_id}.yaml" << YAML
request_id: ${request_id}
decision: deny
by: shogun
reason: "D002-E1(d)の絶対パス条件を満たさない。mktemp -d /tmp/x.XXXXXX を使え。"
machine_check: null
lord_channel: null
decided_at: "2026-09-17T12:40:00Z"
YAML

    __PERMISSION_HOOK_ROOT="$TEST_TMP" \
    __PERMISSION_HOOK_AGENT_ID="ashigaru9" \
    __PERMISSION_HOOK_UTC_TS_OVERRIDE="20260917T120000Z" \
    __PERMISSION_HOOK_POLL_INTERVAL_SECONDS="0.2" \
    PERMISSION_HOOK_TIMEOUT_SECONDS="30" \
    __PERMISSION_HOOK_MARGIN_SECONDS="25" \
    run bash "$HOOK_SCRIPT" <<< "$json"
    [ "$status" -eq 0 ]

    run "$PYTHON" -c "
import yaml
with open('$f') as fh:
    d = yaml.safe_load(fh)
assert d['hook_result']['outcome'] == 'deny', d
assert isinstance(d['hook_result']['returned_at'], str) and d['hook_result']['returned_at'], d
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "T-PRH-028: hook_result outcome=defer_timeout is recorded when the poll deadline is reached with no decision" {
    local json
    json="$(default_json)"
    __PERMISSION_HOOK_ROOT="$TEST_TMP" \
    __PERMISSION_HOOK_AGENT_ID="ashigaru9" \
    __PERMISSION_HOOK_POLL_INTERVAL_SECONDS="0.2" \
    PERMISSION_HOOK_TIMEOUT_SECONDS="1" \
    __PERMISSION_HOOK_MARGIN_SECONDS="0" \
    run bash "$HOOK_SCRIPT" <<< "$json"
    [ "$status" -ne 0 ]
    [ -z "$output" ]

    local f
    f="$(request_files)"
    [ -n "$f" ]
    run "$PYTHON" -c "
import yaml
with open('$f') as fh:
    d = yaml.safe_load(fh)
assert d['hook_result']['outcome'] == 'defer_timeout', d
assert isinstance(d['hook_result']['returned_at'], str) and d['hook_result']['returned_at'], d
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "T-PRH-029: hook_result outcome=failed is recorded when the decision file content is schema-invalid" {
    local json
    json="$(default_json)"
    __PERMISSION_HOOK_ROOT="$TEST_TMP" \
    __PERMISSION_HOOK_AGENT_ID="ashigaru9" \
    __PERMISSION_HOOK_UTC_TS_OVERRIDE="20260917T120000Z" \
    __PERMISSION_HOOK_POLL_INTERVAL_SECONDS="0.2" \
    PERMISSION_HOOK_TIMEOUT_SECONDS="1" \
    __PERMISSION_HOOK_MARGIN_SECONDS="0" \
    run bash "$HOOK_SCRIPT" <<< "$json"
    local f request_id
    f="$(request_files)"
    request_id="$(basename "$f" .yaml)"

    cat > "$TEST_TMP/queue/state/permission_decisions/${request_id}.yaml" << YAML
request_id: ${request_id}
decision: maybe_allow_i_guess
by: shogun
reason: "不正な値"
decided_at: "2026-09-17T12:40:00Z"
YAML

    __PERMISSION_HOOK_ROOT="$TEST_TMP" \
    __PERMISSION_HOOK_AGENT_ID="ashigaru9" \
    __PERMISSION_HOOK_UTC_TS_OVERRIDE="20260917T120000Z" \
    __PERMISSION_HOOK_POLL_INTERVAL_SECONDS="0.2" \
    PERMISSION_HOOK_TIMEOUT_SECONDS="30" \
    __PERMISSION_HOOK_MARGIN_SECONDS="25" \
    run bash "$HOOK_SCRIPT" <<< "$json"
    [ "$status" -ne 0 ]
    [ -z "$output" ]

    run "$PYTHON" -c "
import yaml
with open('$f') as fh:
    d = yaml.safe_load(fh)
assert d['hook_result']['outcome'] == 'failed', d
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "T-PRH-030: a legacy decision:defer value now yields hook_result outcome=failed (defer removed from the vocabulary)" {
    local json
    json="$(default_json)"
    __PERMISSION_HOOK_ROOT="$TEST_TMP" \
    __PERMISSION_HOOK_AGENT_ID="ashigaru9" \
    __PERMISSION_HOOK_UTC_TS_OVERRIDE="20260917T120000Z" \
    __PERMISSION_HOOK_POLL_INTERVAL_SECONDS="0.2" \
    PERMISSION_HOOK_TIMEOUT_SECONDS="1" \
    __PERMISSION_HOOK_MARGIN_SECONDS="0" \
    run bash "$HOOK_SCRIPT" <<< "$json"
    local f request_id
    f="$(request_files)"
    request_id="$(basename "$f" .yaml)"

    cat > "$TEST_TMP/queue/state/permission_decisions/${request_id}.yaml" << YAML
request_id: ${request_id}
decision: defer
by: shogun
reason: "殿の判断を仰ぐ(ntfy送信済み・旧運用の名残)"
machine_check: null
lord_channel: ntfy
decided_at: "2026-09-17T12:40:00Z"
YAML

    __PERMISSION_HOOK_ROOT="$TEST_TMP" \
    __PERMISSION_HOOK_AGENT_ID="ashigaru9" \
    __PERMISSION_HOOK_UTC_TS_OVERRIDE="20260917T120000Z" \
    __PERMISSION_HOOK_POLL_INTERVAL_SECONDS="0.2" \
    PERMISSION_HOOK_TIMEOUT_SECONDS="30" \
    __PERMISSION_HOOK_MARGIN_SECONDS="25" \
    run bash "$HOOK_SCRIPT" <<< "$json"
    [ "$status" -ne 0 ]
    [ -z "$output" ]

    run "$PYTHON" -c "
import yaml
with open('$f') as fh:
    d = yaml.safe_load(fh)
assert d['hook_result']['outcome'] == 'failed', d
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "T-PRH-031: hook_result write preserves pre-existing record fields (agent_id/session_id/tool_input unchanged)" {
    local json
    json="$(default_json 'echo preserve_fields_test')"
    __PERMISSION_HOOK_ROOT="$TEST_TMP" \
    __PERMISSION_HOOK_AGENT_ID="ashigaru9" \
    __PERMISSION_HOOK_UTC_TS_OVERRIDE="20260917T120000Z" \
    __PERMISSION_HOOK_POLL_INTERVAL_SECONDS="0.2" \
    PERMISSION_HOOK_TIMEOUT_SECONDS="1" \
    __PERMISSION_HOOK_MARGIN_SECONDS="0" \
    run bash "$HOOK_SCRIPT" <<< "$json"
    local f request_id
    f="$(request_files)"
    request_id="$(basename "$f" .yaml)"

    cat > "$TEST_TMP/queue/state/permission_decisions/${request_id}.yaml" << YAML
request_id: ${request_id}
decision: allow
by: lord
reason: "殿がallowと回答"
decided_at: "2026-09-17T12:40:00Z"
YAML

    __PERMISSION_HOOK_ROOT="$TEST_TMP" \
    __PERMISSION_HOOK_AGENT_ID="ashigaru9" \
    __PERMISSION_HOOK_UTC_TS_OVERRIDE="20260917T120000Z" \
    __PERMISSION_HOOK_POLL_INTERVAL_SECONDS="0.2" \
    PERMISSION_HOOK_TIMEOUT_SECONDS="30" \
    __PERMISSION_HOOK_MARGIN_SECONDS="25" \
    run bash "$HOOK_SCRIPT" <<< "$json"
    [ "$status" -eq 0 ]

    run "$PYTHON" -c "
import yaml
with open('$f') as fh:
    d = yaml.safe_load(fh)
assert d['agent_id'] == 'ashigaru9', d
assert d['session_id'] == 'sess_test_001', d
assert d['tool_name'] == 'Bash', d
assert d['tool_input']['command'] == 'echo preserve_fields_test', d
assert d['cwd'] == '/path/to/project', d
assert d['request_id'] == '${request_id}', d
assert 'received_at' in d and d['received_at'], d
assert d['hook_result']['outcome'] == 'allow', d
assert isinstance(d['hook_result']['returned_at'], str) and d['hook_result']['returned_at'], d
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}
