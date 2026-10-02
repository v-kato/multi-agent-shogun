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
#
# 以下はcmd_799 ④(手動No/Esc中断時の結果記帳)で追加:
#   T-PRH-032: SIGTERM中断で hook_result outcome=aborted が1回だけ書かれる
#   T-PRH-033: SIGHUP中断でも同様
#   T-PRH-034: defer_timeout経路でEXIT trapが二重記帳・abortedへの上書きをしない
#   T-PRH-035: allow/deny経路で hook_result が1本のまま(outcome不変)
#   T-PRH-036: abortedの後、watcher guardがfail-safe timeoutを待たず解除される
#
# 以下はcmd_799 ④ 堅牢化(QC REDO: 隔離実機で約23%記録されなかった)で追加。
# Claude Codeは中断時にSIGTERM→約1.4秒後にSIGKILLを送る。その猶予内に記帳が
# 終わること(=trap内の記帳がbash組込みだけで速いこと・待機が中断可能なこと)を
# 「TERMの約0.3秒後にSIGKILL」で決定的に固定する:
#   T-PRH-037: 記帳pythonが遅くても(stub)TERMの0.3秒後のSIGKILLまでにabortedが残る
#   T-PRH-038: 待機間隔が長くても(bashだけにTERM)中断可能な待ちで0.3秒以内に記帳される
#   T-PRH-039: 既に記帳済みのhook_resultはtrapが上書き・二重記帳しない
#   T-PRH-040: 記録ファイルが無ければtrapは記録を新規作成しない

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

# ─── cmd_799 ④: 手動No/Escによる中断(SIGTERM系)でも hook_result を1回だけ記帳する ───
#
# 実測(context/cmd_775_manual_answer_test.md Case B/B2): 手動No/Escでは
# Claude Codeがhookプロセスを終了させ、finish()を通らないまま退出するため
# hook_resultが書かれず、watcherのguardがfail-safe timeout(約30分)まで
# 解けなかった。EXIT trapから outcome=aborted を記帳する(check-and-setで
# 通常退出経路との二重記帳を防ぐ)。判定(allow/deny)の中身・timeout値は
# 変えない。
#
# ★D006-E1 Branch 1: hookは本試験が直接spawnした子であり、`$!`をspawn直後に
#   専用変数 HOOK_PID へ捕捉して以後再代入しない。signal送信直前に
#   (1) kill -0(signal 0=存在確認のみ)と (2) `jobs -r -p`(この shellが
#   未回収のままの同じ子であること=pid再利用でないこと)を確かめ、確認
#   できなければsignalを送らない。単一の正のPIDのみを対象とし、broadcast・
#   pgid指定・pgrep等の列挙は一切使わない。

HOOK_PID=""

# hookを直接の子としてバックグラウンド起動する。決定ファイルは置かないので
# ポーリング中(timeout 60s・deadline 60s)のまま待機し続ける。
spawn_hook_bg() {
    local json="$1"
    local poll_interval="${2:-0.2}"
    __PERMISSION_HOOK_ROOT="$TEST_TMP" \
    __PERMISSION_HOOK_AGENT_ID="ashigaru9" \
    __PERMISSION_HOOK_POLL_INTERVAL_SECONDS="$poll_interval" \
    PERMISSION_HOOK_TIMEOUT_SECONDS="60" \
    __PERMISSION_HOOK_MARGIN_SECONDS="0" \
    bash "$HOOK_SCRIPT" <<< "$json" >"$TEST_TMP/hook_bg.out" 2>"$TEST_TMP/hook_bg.err" &
    HOOK_PID=$!
}

# 記録ファイルが作られ、かつhookが記録のpathを確定して家老inbox通知(手順6=
# ポーリングの直前)へ進むまで、最大約30秒待つ。記録ファイルが現れた直後には、
# hookがまだ記録pathを確定していない(=abortedを記帳できない)僅かな窓があり、
# 高負荷だとそこでsignalを送ってしまう。モックinbox_writeの呼出しログは、その窓の
# 後でしか書かれないので、ログの出現を「hookが退出時記帳の準備を終えた」合図にする。
wait_for_request_file() {
    local i
    for i in $(seq 1 300); do
        [ -n "$(request_files)" ] && [ -s "$TEST_TMP/inbox_write_calls.log" ] && return 0
        sleep 0.1
    done
    return 1
}

# 指定signalを HOOK_PID へ送る。D006-E1 Branch 1の同一性確認(上記)を満たした
# 時だけ送り、確認できなければ(既に終了・回収済み等)送らず非0を返す。
send_signal_hook_bg() {
    local sig="$1"
    if kill -0 "$HOOK_PID" 2>/dev/null && [[ " $(jobs -r -p | tr '\n' ' ') " == *" $HOOK_PID "* ]]; then
        kill -s "$sig" "$HOOK_PID" 2>/dev/null || true
        return 0
    fi
    return 1
}

# 指定signalを HOOK_PID へ送り、hookの終了を待つ。結果は HOOK_RC に入る。
signal_hook_bg_and_wait() {
    send_signal_hook_bg "$1" || return 1
    HOOK_RC=0
    wait "$HOOK_PID" 2>/dev/null || HOOK_RC=$?
    return 0
}

# Claude Codeの中断を模す: TERMを送り、約0.3秒後にまだ生きていればKILL(trap不能)を
# 送ってから終了を待つ。本物は約1.4秒後にKILLを送るので、その猶予より短く厳しい。
# KILLの送信にもD006-E1 Branch 1の同一性確認が掛かる(既に終了していれば送らない)。
term_then_kill_hook_bg_and_wait() {
    send_signal_hook_bg TERM || return 1
    sleep 0.3
    send_signal_hook_bg KILL || true
    HOOK_RC=0
    wait "$HOOK_PID" 2>/dev/null || HOOK_RC=$?
    return 0
}

# 記録ファイル内のトップレベル `hook_result:` キーの本数を数える
# (二重記帳検出用。YAMLのキー重複はsafe_loadでは後勝ちで隠れるため生行で数える)。
hook_result_key_count() {
    /usr/bin/grep -c '^hook_result:' "$1" || true
}

@test "T-PRH-032: SIGTERM while polling (manual No/Esc) records hook_result outcome=aborted exactly once" {
    local json
    json="$(default_json 'echo aborted_sigterm')"
    spawn_hook_bg "$json"
    wait_for_request_file

    local f
    f="$(request_files)"
    [ -n "$f" ]
    # 中断前: 未決(hook_resultなし)であること
    [ "$(hook_result_key_count "$f")" -eq 0 ]

    signal_hook_bg_and_wait TERM
    # signalで終了した(正常終了0ではない)・stdoutへ何も出していない(allow/denyを出さない)
    [ "$HOOK_RC" -ne 0 ]
    [ ! -s "$TEST_TMP/hook_bg.out" ]

    [ "$(hook_result_key_count "$f")" -eq 1 ]
    run "$PYTHON" -c "
import yaml
with open('$f') as fh:
    d = yaml.safe_load(fh)
assert d['hook_result']['outcome'] == 'aborted', d
assert isinstance(d['hook_result']['returned_at'], str) and d['hook_result']['returned_at'], d
# 既存フィールドは不変(追加のみ)
assert d['agent_id'] == 'ashigaru9', d
assert d['tool_input']['command'] == 'echo aborted_sigterm', d
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "T-PRH-033: SIGHUP while polling also records hook_result outcome=aborted exactly once" {
    local json
    json="$(default_json 'echo aborted_sighup')"
    spawn_hook_bg "$json"
    wait_for_request_file

    local f
    f="$(request_files)"
    [ -n "$f" ]

    signal_hook_bg_and_wait HUP
    [ "$HOOK_RC" -ne 0 ]
    [ ! -s "$TEST_TMP/hook_bg.out" ]

    [ "$(hook_result_key_count "$f")" -eq 1 ]
    run /usr/bin/grep -A3 '^hook_result:' "$f"
    [ "$status" -eq 0 ]
    [[ "$output" == *"outcome: aborted"* ]]
}

@test "T-PRH-034: normal exit paths still write exactly one hook_result and never aborted (no double write via the EXIT trap)" {
    local json f

    # defer_timeout 経路(deadline到達・決定なし)
    json="$(default_json 'echo once_timeout')"
    __PERMISSION_HOOK_ROOT="$TEST_TMP" \
    __PERMISSION_HOOK_AGENT_ID="ashigaru9" \
    __PERMISSION_HOOK_POLL_INTERVAL_SECONDS="0.2" \
    PERMISSION_HOOK_TIMEOUT_SECONDS="1" \
    __PERMISSION_HOOK_MARGIN_SECONDS="0" \
    run bash "$HOOK_SCRIPT" <<< "$json"
    [ "$status" -ne 0 ]
    f="$(request_files)"
    [ -n "$f" ]
    [ "$(hook_result_key_count "$f")" -eq 1 ]
    run /usr/bin/grep -A3 '^hook_result:' "$f"
    [[ "$output" == *"outcome: defer_timeout"* ]]
    [[ "$output" != *"aborted"* ]]
}

@test "T-PRH-035: allow and deny exit paths each write exactly one hook_result (outcome unchanged by the EXIT trap)" {
    local outcome decision json f request_id
    for decision in allow deny; do
        json="$(default_json "echo once_${decision}")"
        __PERMISSION_HOOK_ROOT="$TEST_TMP" \
        __PERMISSION_HOOK_AGENT_ID="ashigaru9" \
        __PERMISSION_HOOK_UTC_TS_OVERRIDE="20260917T13000${#decision}Z" \
        __PERMISSION_HOOK_POLL_INTERVAL_SECONDS="0.2" \
        PERMISSION_HOOK_TIMEOUT_SECONDS="1" \
        __PERMISSION_HOOK_MARGIN_SECONDS="0" \
        run bash "$HOOK_SCRIPT" <<< "$json"
        f="$(find "$TEST_TMP/queue/state/permission_requests" -maxdepth 1 -name '*_20260917T13000'"${#decision}"'Z_*.yaml' -type f)"
        [ -n "$f" ]
        request_id="$(basename "$f" .yaml)"

        if [ "$decision" = "deny" ]; then
            printf 'request_id: %s\ndecision: deny\nreason: "test deny"\nby: shogun\ndecided_at: "2026-09-17T13:00:00Z"\n' \
                "$request_id" > "$TEST_TMP/queue/state/permission_decisions/${request_id}.yaml"
        else
            printf 'request_id: %s\ndecision: allow\nby: lord\nreason: "test allow"\ndecided_at: "2026-09-17T13:00:00Z"\n' \
                "$request_id" > "$TEST_TMP/queue/state/permission_decisions/${request_id}.yaml"
        fi

        __PERMISSION_HOOK_ROOT="$TEST_TMP" \
        __PERMISSION_HOOK_AGENT_ID="ashigaru9" \
        __PERMISSION_HOOK_UTC_TS_OVERRIDE="20260917T13000${#decision}Z" \
        __PERMISSION_HOOK_POLL_INTERVAL_SECONDS="0.2" \
        PERMISSION_HOOK_TIMEOUT_SECONDS="30" \
        __PERMISSION_HOOK_MARGIN_SECONDS="25" \
        run bash "$HOOK_SCRIPT" <<< "$json"
        [ "$status" -eq 0 ]
        [[ "$output" == *'"behavior": "'"$decision"'"'* ]]

        [ "$(hook_result_key_count "$f")" -eq 1 ]
        outcome="$(/usr/bin/grep -A3 '^hook_result:' "$f" | /usr/bin/grep 'outcome:' | awk '{print $2}')"
        [ "$outcome" = "$decision" ]
    done
}

@test "T-PRH-036: after an aborted exit the watcher guard is released immediately (no wait for the fail-safe timeout); while the hook is still polling it is held" {
    local json
    json="$(default_json 'echo aborted_guard')"
    spawn_hook_bg "$json"
    wait_for_request_file

    local f
    f="$(request_files)"
    [ -n "$f" ]

    # 中断前: hook待機中(記録の received_at は直近=fail-safe未到達)ゆえ未決→guard有効
    run env AGENT_ID=ashigaru9 SCRIPT_DIR="$TEST_TMP" __INBOX_WATCHER_TESTING__=1 \
        bash -c "source '$SCRIPT_DIR/scripts/inbox_watcher.sh'; has_pending_permission_request && echo PENDING || echo RESOLVED"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PENDING"* ]]

    signal_hook_bg_and_wait TERM

    # 中断後: hook_result(aborted)により、received_atが直近のままでも解除される
    run env AGENT_ID=ashigaru9 SCRIPT_DIR="$TEST_TMP" __INBOX_WATCHER_TESTING__=1 \
        bash -c "source '$SCRIPT_DIR/scripts/inbox_watcher.sh'; has_pending_permission_request && echo PENDING || echo RESOLVED"
    [ "$status" -eq 0 ]
    [[ "$output" == *"RESOLVED"* ]]
}

# ─── cmd_799 ④ 堅牢化: SIGTERM後の約1.4秒の猶予(その後SIGKILL)に記帳を収める ───
#
# 実機の独立再現(context/cmd_799_hook_qc.md §1)では、EXIT trapに頼る作りだと
# 約23%の中断で記録が残らなかった(trapに入る前・記帳(python起動)の途中での
# SIGKILL)。以下は、その猶予に収まる作りであること(trap内の記帳がbash組込み
# だけ・待機が中断可能)を、TERMの約0.3秒後にKILLを送って決定的に固定する。

# 記録ファイル内のトップレベルキーの並びと、hook_result以外の値を取り出す。
record_snapshot() {
    "$PYTHON" -c "
import json, sys, yaml
with open(sys.argv[1]) as fh:
    d = yaml.safe_load(fh)
print(json.dumps({k: v for k, v in d.items() if k != 'hook_result'}, sort_keys=True, default=str))
print(json.dumps(list(d.keys())))
" "$1"
}

@test "T-PRH-037: aborted is recorded before a SIGKILL 0.3s after SIGTERM even when python is slow (the EXIT trap uses no python)" {
    # 記録作成後のpython起動を5秒遅くするstub(flagファイルができるまでは素通し)。
    # trap内の記帳がpythonに依存していれば、0.3秒後のKILLまでに間に合わない。
    rm -f "$TEST_TMP/.venv"
    mkdir -p "$TEST_TMP/.venv/bin"
    cat > "$TEST_TMP/.venv/bin/python3" <<STUB
#!/bin/bash
[ -e "$TEST_TMP/slow_python" ] && sleep 5
exec "$PYTHON" "\$@"
STUB
    chmod +x "$TEST_TMP/.venv/bin/python3"

    local json f
    json="$(default_json 'echo aborted_slow_python')"
    spawn_hook_bg "$json"
    wait_for_request_file
    f="$(request_files)"
    [ -n "$f" ]
    local before
    before="$(record_snapshot "$f")"
    : > "$TEST_TMP/slow_python"

    term_then_kill_hook_bg_and_wait
    [ ! -s "$TEST_TMP/hook_bg.out" ]

    [ "$(hook_result_key_count "$f")" -eq 1 ]
    # 形式はpython記帳と同じ: outcome=aborted・returned_atは文字列(UTC)・既存フィールド不変
    run "$PYTHON" -c "
import re, yaml
with open('$f') as fh:
    d = yaml.safe_load(fh)
r = d['hook_result']
assert r['outcome'] == 'aborted', d
assert isinstance(r['returned_at'], str), d
assert re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z', r['returned_at']), d
assert sorted(r.keys()) == ['outcome', 'returned_at'], d
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
    # 追記のみ: hook_result以外の既存フィールドは不変・hook_resultは末尾に追加される
    local after
    after="$(record_snapshot "$f")"
    [ "$(printf '%s\n' "$after" | head -1)" = "$(printf '%s\n' "$before" | head -1)" ]
    [ "$(printf '%s\n' "$after" | tail -1 | "$PYTHON" -c 'import json,sys; print(json.load(sys.stdin)[-1])')" = "hook_result" ]
}

@test "T-PRH-038: with a long poll interval and SIGTERM sent only to the hook, aborted is still recorded before a SIGKILL 0.3s later (interruptible wait)" {
    # 待機間隔30秒。前景のsleepだと、bashだけに来たTERMはsleepが終わるまで処理
    # されず(trapが遅れ)、0.3秒後のKILLまでに記帳できない。孫のsleepには
    # signalを送らない(D006-E1: 直接の子のみ)ので、この状況を正確に再現する。
    local json f
    json="$(default_json 'echo aborted_long_poll')"
    spawn_hook_bg "$json" 30
    wait_for_request_file
    f="$(request_files)"
    [ -n "$f" ]
    [ "$(hook_result_key_count "$f")" -eq 0 ]

    term_then_kill_hook_bg_and_wait
    [ ! -s "$TEST_TMP/hook_bg.out" ]

    [ "$(hook_result_key_count "$f")" -eq 1 ]
    run /usr/bin/grep -A3 '^hook_result:' "$f"
    [ "$status" -eq 0 ]
    [[ "$output" == *"outcome: aborted"* ]]
}

@test "T-PRH-039: the EXIT trap never overwrites or duplicates an already-recorded hook_result" {
    local json f
    json="$(default_json 'echo aborted_already_recorded')"
    spawn_hook_bg "$json"
    wait_for_request_file
    f="$(request_files)"
    [ -n "$f" ]

    # 先に別の結果が記帳済みの記録(例: 通常経路が書き終えた直後にTERMが来た場合)
    printf "hook_result:\n  outcome: failed\n  returned_at: '2026-10-02T00:00:00Z'\n" >> "$f"
    local before
    before="$(cat "$f")"

    signal_hook_bg_and_wait TERM
    [ "$HOOK_RC" -ne 0 ]

    [ "$(hook_result_key_count "$f")" -eq 1 ]
    [ "$(cat "$f")" = "$before" ]
    run /usr/bin/grep -A3 '^hook_result:' "$f"
    [[ "$output" == *"outcome: failed"* ]]
    [[ "$output" != *"aborted"* ]]
}

@test "T-PRH-040: the EXIT trap does not create a record file that does not exist" {
    local json f
    json="$(default_json 'echo aborted_no_record')"
    spawn_hook_bg "$json"
    wait_for_request_file
    f="$(request_files)"
    [ -n "$f" ]

    # 記録ファイルを退避して「無い」状態にする(削除はしない)
    mv "$f" "$TEST_TMP/moved_away_record.yaml"
    [ ! -e "$f" ]

    signal_hook_bg_and_wait TERM
    [ "$HOOK_RC" -ne 0 ]

    # trapの`>>`が空の記録を新規作成していない(hook_resultだけのファイルが残らない)
    [ ! -e "$f" ]
    [ -z "$(request_files)" ]
}
