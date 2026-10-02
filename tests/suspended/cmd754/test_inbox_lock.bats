# 出所ファイル: tests/test_inbox_lock.bats

# ────────────────────────────────────────────────────────────────────
# 出所: tests/test_inbox_lock.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-CL-21a (b): writer/watcher/mark-read 三者同時実行でYAML parse成功・全件保存
# 移動元行番号(除去前): 524-590
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-CL-21a (b): writer/watcher/mark-read 三者同時実行でYAML parse成功・全件保存" {
    make_inbox "$TEST_INBOX_DIR/ashigaru3.yaml" msg_1 false msg_2 false msg_clear false
    # msg_clear は type: task_assigned で作られる(make_inboxの固定type)ため、
    # watcher legの対象special typeへ後から書き換える。
    "$VENV_PYTHON" - "$TEST_INBOX_DIR/ashigaru3.yaml" <<'PY'
import sys, yaml
path = sys.argv[1]
with open(path, encoding='utf-8') as f:
    data = yaml.safe_load(f)
for m in data['messages']:
    if m['id'] == 'msg_clear':
        m['type'] = 'clear_command'
with open(path, 'w', encoding='utf-8') as f:
    yaml.safe_dump(data, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
PY

    cat > "$TEST_TMPDIR/watcher_once.sh" <<EOF
#!/bin/bash
INBOX="$TEST_INBOX_DIR/ashigaru3.yaml"
LOCKFILE="\${INBOX}.lock"
SCRIPT_DIR="$PROJECT_ROOT"
export __INBOX_WATCHER_TESTING__=1
source "$PROJECT_ROOT/scripts/inbox_watcher.sh"
# ★cmd_754 redo1 で契約が変わった: get_unread_info は既読化しない。
#   特殊命令の read 更新は送信確定後の mark_inbox_message_read が担う。
#   本テストの主眼は「三者同時実行でも YAML が壊れず全件残る」ことゆえ、
#   watcher leg は読み取りと read 更新の両方を今の正しい順で行う。
get_unread_info >/dev/null
mark_inbox_message_read msg_clear clear_command >/dev/null
EOF
    chmod +x "$TEST_TMPDIR/watcher_once.sh"

    bash "$TEST_WRITE_SCRIPT" ashigaru3 "新規1" concurrent karo > "$TEST_TMPDIR/w1.log" 2>&1 &
    pid_w1=$!
    bash "$TEST_WRITE_SCRIPT" ashigaru3 "新規2" concurrent karo > "$TEST_TMPDIR/w2.log" 2>&1 &
    pid_w2=$!
    bash "$TEST_WRITE_SCRIPT" ashigaru3 "新規3" concurrent karo > "$TEST_TMPDIR/w3.log" 2>&1 &
    pid_w3=$!
    bash "$TEST_TMPDIR/watcher_once.sh" > "$TEST_TMPDIR/watcher.log" 2>&1 &
    pid_watch=$!
    bash "$TEST_SCRIPT" mark-read ashigaru3 --id msg_1 msg_2 > "$TEST_TMPDIR/locker.log" 2>&1 &
    pid_lock=$!

    for pid in $pid_w1 $pid_w2 $pid_w3 $pid_watch $pid_lock; do
        wait "$pid"
    done

    assert_yaml_valid "$TEST_INBOX_DIR/ashigaru3.yaml"
    [ "$(count_messages "$TEST_INBOX_DIR/ashigaru3.yaml")" -eq 6 ]
    [ "$(read_flag "$TEST_INBOX_DIR/ashigaru3.yaml" msg_1)" = "true" ]
    [ "$(read_flag "$TEST_INBOX_DIR/ashigaru3.yaml" msg_2)" = "true" ]
    [ "$(read_flag "$TEST_INBOX_DIR/ashigaru3.yaml" msg_clear)" = "true" ]

    "$VENV_PYTHON" - "$TEST_INBOX_DIR/ashigaru3.yaml" <<'PY'
import sys, yaml
with open(sys.argv[1], encoding='utf-8') as f:
    data = yaml.safe_load(f)
contents = sorted(m['content'] for m in data['messages'] if m['id'] not in ('msg_1', 'msg_2', 'msg_clear'))
assert contents == ['新規1', '新規2', '新規3'], contents
for m in data['messages']:
    if m['id'] not in ('msg_1', 'msg_2', 'msg_clear'):
        assert m['read'] is False, m
PY

    [ ! -d "$TEST_INBOX_DIR/ashigaru3.yaml.lock.d" ]
}
