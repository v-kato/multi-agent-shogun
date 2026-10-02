#!/usr/bin/env bats
# test_permission_decide.bats — scripts/permission_decide.sh unit tests
# (cmd_775 Phase C・subtask_775_phaseC_hook_decide)
#
# テスト構成:
#   T-PD-001: 引数不足 → usage error
#   T-PD-002: 未知の引数 → error
#   T-PD-003: decision値が不正 → error
#   T-PD-004: --by値が不正 → error
#   T-PD-005: --by欠落 → error
#   T-PD-006: --reason欠落(空文字列) → error
#   T-PD-007: --lord-channel値が不正 → error
#   T-PD-008: request_idに不正文字 → error
#   T-PD-009: request_idが空 → error
#   T-PD-010: allow + --by lord は無条件で受理される
#   T-PD-011: allow + --by shogun かつ --machine-check 無し → 拒否
#   T-PD-012: allow + --by shogun + --machine-check ファイル不在 → 拒否
#   T-PD-013: allow + --by shogun + checked_commandが不一致 → 拒否
#   T-PD-014: allow + --by shogun + verdictがPASSでない → 拒否
#   T-PD-015: allow + --by shogun + 完全一致+PASS → 受理・決定ファイル
#             にby=shogun・machine_check=pathが記録される
#   T-PD-016: allow + --by shogun + 対応する記録ファイルが存在しない → 拒否
#   T-PD-017: deny + --by shogun は正常に決定ファイルを書く
#   T-PD-018: defer は決定値として拒否される(cmd_775 Phase D redo2で
#             defer廃止・旧仕様からの意図的な後方非互換)
#   T-PD-019: 1 request 1 決定(2回目の書込みは失敗し、1回目の内容は不変)
#   T-PD-020: decided_atが正しいUTC ISO8601形式である
#   T-PD-021: 決定ディレクトリが無い場合は自動作成される
#   T-PD-022: --lord-channel省略時はnullになる
#
# 以下はcmd_775 Phase D redo2(将軍裁定(iii)・inquireサブコマンド新設)で追加:
#   T-PD-023: inquireは記録ファイルへinquiryフィールドを原子的に追記する
#   T-PD-024: inquireは決定ファイルを書かない
#   T-PD-025: inquire後もallow/denyが正常に書ける(1 request 1決定の
#             slotを消費しない)
#   T-PD-026: inquireは対応する記録ファイルが無ければ拒否される
#   T-PD-027: inquireの--channelが不正な値なら拒否される
#   T-PD-028: inquireの--byがshogun以外なら拒否される
#   T-PD-029: inquireは記録ファイルの既存フィールドを変更しない

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
DECIDE_SCRIPT="$SCRIPT_DIR/scripts/permission_decide.sh"
PYTHON="$SCRIPT_DIR/.venv/bin/python3"

setup() {
    TEST_TMP="$(mktemp -d)"
    mkdir -p "$TEST_TMP/queue/state/permission_requests"
    mkdir -p "$TEST_TMP/queue/state/permission_decisions"
    ln -s "$SCRIPT_DIR/.venv" "$TEST_TMP/.venv"
}

teardown() {
    rm -rf "$TEST_TMP"
}

run_decide() {
    __PERMISSION_DECIDE_ROOT="$TEST_TMP" run bash "$DECIDE_SCRIPT" "$@"
}

write_request_record() {
    # bashのheredoc手組みだとcommand値に埋め込まれた二重引用符等が
    # YAMLとして壊れうるため(YAML自体のエスケープ規則が絡む)、python の
    # yaml.safe_dump で機械的に組み立てる(本番hookのrecord書込みと同じ
    # 手段)。
    local request_id="$1" command="$2"
    "$PYTHON" -c "
import yaml
record = {
    'request_id': '$request_id',
    'agent_id': 'ashigaru9',
    'session_id': 'sess1',
    'tool_use_id': None,
    'permission_suggestions': None,
    'tool_name': 'Bash',
    'tool_input': {'command': '''$command''', 'description': 'test'},
    'cwd': '/path/to/project',
    'task_id': None,
    'parent_cmd': None,
    'received_at': '2026-09-17T12:00:00Z',
}
with open('$TEST_TMP/queue/state/permission_requests/${request_id}.yaml', 'w') as f:
    yaml.safe_dump(record, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
"
}

decision_file_path() {
    echo "$TEST_TMP/queue/state/permission_decisions/${1}.yaml"
}

@test "T-PD-001: too few arguments is a usage error" {
    run_decide "req_only_one_arg"
    [ "$status" -ne 0 ]
}

@test "T-PD-002: unknown flag is rejected" {
    run_decide "req1" deny --by shogun --reason "x" --bogus-flag foo
    [ "$status" -ne 0 ]
    [ ! -f "$(decision_file_path req1)" ]
}

@test "T-PD-003: invalid decision value is rejected" {
    run_decide "req1" maybe --by shogun --reason "x"
    [ "$status" -ne 0 ]
    [ ! -f "$(decision_file_path req1)" ]
}

@test "T-PD-004: invalid --by value is rejected" {
    run_decide "req1" deny --by nobody --reason "x"
    [ "$status" -ne 0 ]
    [ ! -f "$(decision_file_path req1)" ]
}

@test "T-PD-005: missing --by is rejected" {
    run_decide "req1" deny --reason "x"
    [ "$status" -ne 0 ]
    [ ! -f "$(decision_file_path req1)" ]
}

@test "T-PD-006: empty --reason is rejected" {
    run_decide "req1" deny --by shogun --reason ""
    [ "$status" -ne 0 ]
    [ ! -f "$(decision_file_path req1)" ]
}

@test "T-PD-007: invalid --lord-channel value is rejected" {
    run_decide "req1" deny --by shogun --reason "x" --lord-channel carrier_pigeon
    [ "$status" -ne 0 ]
    [ ! -f "$(decision_file_path req1)" ]
}

@test "T-PD-008: request_id with a path-traversal-looking character is rejected" {
    run_decide "../etc/passwd" deny --by shogun --reason "x"
    [ "$status" -ne 0 ]
}

@test "T-PD-009: empty request_id is rejected" {
    run_decide "" deny --by shogun --reason "x"
    [ "$status" -ne 0 ]
}

@test "T-PD-010: allow with --by lord is accepted unconditionally" {
    run_decide "req_lord_allow" allow --by lord --reason "殿がntfyでallowと回答した"
    [ "$status" -eq 0 ]
    local f
    f="$(decision_file_path req_lord_allow)"
    [ -f "$f" ]
    run "$PYTHON" -c "
import yaml
with open('$f') as fh:
    d = yaml.safe_load(fh)
assert d['decision'] == 'allow', d
assert d['by'] == 'lord', d
assert d['machine_check'] is None, d
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "T-PD-011: allow with --by shogun and no --machine-check is rejected" {
    run_decide "req_shogun_no_mc" allow --by shogun --reason "画面を見て安全そう"
    [ "$status" -ne 0 ]
    [ ! -f "$(decision_file_path req_shogun_no_mc)" ]
}

@test "T-PD-012: allow with --by shogun and a nonexistent --machine-check file is rejected" {
    run_decide "req_shogun_missing_mc" allow --by shogun --reason "x" \
        --machine-check "$TEST_TMP/does_not_exist.yaml"
    [ "$status" -ne 0 ]
    [ ! -f "$(decision_file_path req_shogun_missing_mc)" ]
}

@test "T-PD-013: allow with --by shogun and mismatched checked_command is rejected" {
    write_request_record "req_mismatch" 'rm -rf -- "$TMPD"'
    cat > "$TEST_TMP/evidence_mismatch.yaml" << 'YAML'
checked_command: "rm -rf -- \"$SOME_OTHER_VAR\""
verdict: PASS
YAML
    run_decide "req_mismatch" allow --by shogun --reason "checker PASS" \
        --machine-check "$TEST_TMP/evidence_mismatch.yaml"
    [ "$status" -ne 0 ]
    [ ! -f "$(decision_file_path req_mismatch)" ]
}

@test "T-PD-014: allow with --by shogun and verdict != PASS is rejected" {
    write_request_record "req_not_pass" 'rm -rf -- "$TMPD"'
    cat > "$TEST_TMP/evidence_not_pass.yaml" << 'YAML'
checked_command: "rm -rf -- \"$TMPD\""
verdict: FORMAT_ONLY
YAML
    run_decide "req_not_pass" allow --by shogun --reason "checker said format_only" \
        --machine-check "$TEST_TMP/evidence_not_pass.yaml"
    [ "$status" -ne 0 ]
    [ ! -f "$(decision_file_path req_not_pass)" ]
}

@test "T-PD-015: allow with --by shogun, exact match and verdict PASS is accepted" {
    write_request_record "req_pass" 'rm -rf -- "$TMPD"'
    cat > "$TEST_TMP/evidence_pass.yaml" << 'YAML'
checked_command: "rm -rf -- \"$TMPD\""
verdict: PASS
YAML
    run_decide "req_pass" allow --by shogun --reason "cmd_753 checker: PASS" \
        --machine-check "$TEST_TMP/evidence_pass.yaml"
    [ "$status" -eq 0 ]

    local f
    f="$(decision_file_path req_pass)"
    [ -f "$f" ]
    run "$PYTHON" -c "
import yaml
with open('$f') as fh:
    d = yaml.safe_load(fh)
assert d['decision'] == 'allow', d
assert d['by'] == 'shogun', d
assert d['machine_check'] == '$TEST_TMP/evidence_pass.yaml', d
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "T-PD-016: allow with --by shogun but no corresponding request record is rejected" {
    cat > "$TEST_TMP/evidence_orphan.yaml" << 'YAML'
checked_command: "rm -rf -- \"$TMPD\""
verdict: PASS
YAML
    run_decide "req_no_record" allow --by shogun --reason "x" \
        --machine-check "$TEST_TMP/evidence_orphan.yaml"
    [ "$status" -ne 0 ]
    [ ! -f "$(decision_file_path req_no_record)" ]
}

@test "T-PD-017: deny with --by shogun writes a correct decision file" {
    run_decide "req_deny" deny --by shogun \
        --reason "D002-E1(d)の絶対パス条件を満たさない。代替: mktemp -d /tmp/x.XXXXXX を使え。"
    [ "$status" -eq 0 ]
    local f
    f="$(decision_file_path req_deny)"
    [ -f "$f" ]
    run "$PYTHON" -c "
import yaml
with open('$f') as fh:
    d = yaml.safe_load(fh)
assert d['decision'] == 'deny', d
assert d['by'] == 'shogun', d
assert 'mktemp -d /tmp/x.XXXXXX' in d['reason'], d
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "T-PD-018: defer is rejected as an invalid decision value (removed from the vocabulary by cmd_775 Phase D redo2)" {
    run_decide "req_defer_removed" defer --by shogun --reason "殿へntfyで問うた" --lord-channel ntfy
    [ "$status" -ne 0 ]
    [ ! -f "$(decision_file_path req_defer_removed)" ]
}

@test "T-PD-019: one request one decision — a second write attempt fails and leaves the first decision byte-for-byte unchanged" {
    run_decide "req_once" deny --by shogun --reason "最初の理由"
    [ "$status" -eq 0 ]
    local f before after
    f="$(decision_file_path req_once)"
    before="$(cat "$f")"

    run_decide "req_once" allow --by lord --reason "後から来たallow試行"
    [ "$status" -ne 0 ]

    after="$(cat "$f")"
    [ "$before" = "$after" ]
    run "$PYTHON" -c "
import yaml
with open('$f') as fh:
    d = yaml.safe_load(fh)
assert d['decision'] == 'deny', d
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "T-PD-020: decided_at is a well-formed UTC ISO8601 timestamp" {
    run_decide "req_ts" deny --by shogun --reason "x"
    [ "$status" -eq 0 ]
    local f
    f="$(decision_file_path req_ts)"
    run "$PYTHON" -c "
import yaml, re
with open('$f') as fh:
    d = yaml.safe_load(fh)
assert re.match(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$', d['decided_at']), d['decided_at']
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "T-PD-021: decisions directory is auto-created if missing" {
    rm -rf "$TEST_TMP/queue/state/permission_decisions"
    run_decide "req_autodir" deny --by shogun --reason "x"
    [ "$status" -eq 0 ]
    [ -f "$(decision_file_path req_autodir)" ]
}

@test "T-PD-022: omitted --lord-channel becomes null" {
    run_decide "req_no_channel" deny --by shogun --reason "x"
    [ "$status" -eq 0 ]
    local f
    f="$(decision_file_path req_no_channel)"
    run "$PYTHON" -c "
import yaml
with open('$f') as fh:
    d = yaml.safe_load(fh)
assert d['lord_channel'] is None, d
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "T-PD-023: inquire appends an inquiry field to the request record" {
    write_request_record "req_inquire_ok" 'echo hello'
    run_decide inquire "req_inquire_ok" --by shogun --channel ntfy
    [ "$status" -eq 0 ]

    run "$PYTHON" -c "
import yaml
with open('$TEST_TMP/queue/state/permission_requests/req_inquire_ok.yaml') as fh:
    d = yaml.safe_load(fh)
assert d['inquiry']['channel'] == 'ntfy', d
assert d['inquiry']['by'] == 'shogun', d
assert isinstance(d['inquiry']['sent_at'], str) and d['inquiry']['sent_at'], d
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "T-PD-024: inquire does not write a decision file" {
    write_request_record "req_inquire_no_decision" 'echo hello'
    run_decide inquire "req_inquire_no_decision" --by shogun --channel terminal
    [ "$status" -eq 0 ]
    [ ! -f "$(decision_file_path req_inquire_no_decision)" ]
}

@test "T-PD-025: inquire does not consume the one-request-one-decision slot (allow can still be written afterward)" {
    write_request_record "req_inquire_then_allow" 'echo hello'
    run_decide inquire "req_inquire_then_allow" --by shogun --channel ntfy
    [ "$status" -eq 0 ]

    run_decide "req_inquire_then_allow" allow --by lord --reason "殿がntfyでallowと回答した"
    [ "$status" -eq 0 ]
    [ -f "$(decision_file_path req_inquire_then_allow)" ]
}

@test "T-PD-026: inquire is rejected when no corresponding request record exists" {
    run_decide inquire "req_inquire_no_record" --by shogun --channel ntfy
    [ "$status" -ne 0 ]
}

@test "T-PD-027: inquire with an invalid --channel value is rejected" {
    write_request_record "req_inquire_bad_channel" 'echo hello'
    run_decide inquire "req_inquire_bad_channel" --by shogun --channel carrier_pigeon
    [ "$status" -ne 0 ]

    run "$PYTHON" -c "
import yaml
with open('$TEST_TMP/queue/state/permission_requests/req_inquire_bad_channel.yaml') as fh:
    d = yaml.safe_load(fh)
assert 'inquiry' not in d, d
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "T-PD-028: inquire with --by other than shogun is rejected" {
    write_request_record "req_inquire_bad_by" 'echo hello'
    run_decide inquire "req_inquire_bad_by" --by karo --channel ntfy
    [ "$status" -ne 0 ]

    run "$PYTHON" -c "
import yaml
with open('$TEST_TMP/queue/state/permission_requests/req_inquire_bad_by.yaml') as fh:
    d = yaml.safe_load(fh)
assert 'inquiry' not in d, d
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "T-PD-029: inquire does not modify pre-existing request record fields" {
    write_request_record "req_inquire_preserve" 'echo hello'
    run_decide inquire "req_inquire_preserve" --by shogun --channel ntfy
    [ "$status" -eq 0 ]

    run "$PYTHON" -c "
import yaml
with open('$TEST_TMP/queue/state/permission_requests/req_inquire_preserve.yaml') as fh:
    d = yaml.safe_load(fh)
assert d['agent_id'] == 'ashigaru9', d
assert d['session_id'] == 'sess1', d
assert d['tool_input']['command'] == 'echo hello', d
assert d['request_id'] == 'req_inquire_preserve', d
assert d['inquiry']['channel'] == 'ntfy', d
assert d['inquiry']['by'] == 'shogun', d
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}
