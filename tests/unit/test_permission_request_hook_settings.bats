#!/usr/bin/env bats
# test_permission_request_hook_settings.bats — .claude/settings.jsonへの
# PermissionRequest hook追加の回帰試験 (cmd_775 Phase C・
# subtask_775_phaseC_hook_decide)
#
# 検証内容:
#   T-PRHS-001: PermissionRequest hookエントリが正しい形(matcherなし・
#               command・timeout)で存在する
#   T-PRHS-002: settings.json内の"timeout"フィールドと、command文字列に
#               インライン展開したPERMISSION_HOOK_TIMEOUT_SECONDSの値が
#               一致する(★二重管理防止。片方だけ書き換えれば即座に
#               この試験で検知できる)
#   T-PRHS-003: SessionStart/Stop/PermissionRequest の3 hookすべてが
#               絶対パス(`"${CLAUDE_PROJECT_DIR}/scripts/<script>"`)形式で
#               commandを書いている(cmd_775 scope内・subtask_775_
#               hook_cwd_fix・将軍裁定shogun_ruling_20260917_hook_cwdの
#               恒久的regression guard)。
#               ★旧版はprivategit f38724d9固定commitとの構造完全一致を
#               検査していたが、これは「本task(Phase C)着手前から
#               SessionStart/Stopが変更されていないこと」を確認する
#               目的の一時的な検査であり、後続のsubtask_775_hook_cwd_fix
#               (家老がSessionStart/Stop/PermissionRequestの3 hookすべてを
#               意図的に絶対パス化)によって恒久的に赤くなった
#               (2026-09-17実測・`bats tests/unit/
#               test_permission_request_hook_settings.bats`でnot
#               ok 3を確認済み)。「commit XXXから変更されていないこと」
#               という検査は、意図的な正当な変更が入るたびに書き直しを
#               要する構造であり、再発防止の恒久文書化(docs/
#               delivery_channels.md §12・instructions/common/
#               tooling_pitfalls.md ⑨)が目指す「絶対パス形式を使え」
#               という規則そのものを直接検査する形へ書き換えた方が
#               恒久的に機能する。commitピン留めは廃止する。
#   T-PRHS-004: JSON全体が引き続きvalidである

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SETTINGS_JSON="$SCRIPT_DIR/.claude/settings.json"
PYTHON="$SCRIPT_DIR/.venv/bin/python3"

@test "T-PRHS-001: PermissionRequest hook entry is correctly shaped" {
    run "$PYTHON" -c "
import json
d = json.load(open('$SETTINGS_JSON'))
pr = d['hooks']['PermissionRequest']
assert isinstance(pr, list) and len(pr) == 1, pr
entry = pr[0]
assert 'matcher' not in entry, entry
hooks = entry['hooks']
assert isinstance(hooks, list) and len(hooks) == 1, hooks
h = hooks[0]
assert h['type'] == 'command', h
assert 'scripts/permission_request_hook.sh' in h['command'], h
assert isinstance(h['timeout'], int) and h['timeout'] > 0, h
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "T-PRHS-002: the inline env var timeout and the hook's registered timeout field agree (no split-brain)" {
    run "$PYTHON" -c "
import json, re
d = json.load(open('$SETTINGS_JSON'))
h = d['hooks']['PermissionRequest'][0]['hooks'][0]
m = re.search(r'PERMISSION_HOOK_TIMEOUT_SECONDS=(\d+)', h['command'])
assert m, h['command']
inline_value = int(m.group(1))
assert inline_value == h['timeout'], (inline_value, h['timeout'])
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "T-PRHS-003: SessionStart/Stop/PermissionRequest hook commands all use the absolute \${CLAUDE_PROJECT_DIR} form (cmd_775 hook_cwd fix regression guard)" {
    run "$PYTHON" -c "
import json
d = json.load(open('$SETTINGS_JSON'))
for name in ('SessionStart', 'Stop', 'PermissionRequest'):
    entries = d['hooks'][name]
    assert isinstance(entries, list) and len(entries) == 1, (name, entries)
    hooks = entries[0]['hooks']
    assert isinstance(hooks, list) and len(hooks) == 1, (name, hooks)
    command = hooks[0]['command']
    needle = '\"\${CLAUDE_PROJECT_DIR}/scripts/'
    assert needle in command, (name, command)
    # 相対形式(cwd依存で起動自体が失敗する旧・欠陥形)が紛れ込んでいない
    # ことも合わせて確認する(cmd_775 shogun_ruling_20260917_hook_cwd)。
    assert 'bash scripts/' not in command, (name, command)
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "T-PRHS-004: settings.json remains valid JSON" {
    run "$PYTHON" -c "import json; json.load(open('$SETTINGS_JSON')); print('OK')"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}
