#!/usr/bin/env bats

load "../test_helper/bats-support/load"
load "../test_helper/bats-assert/load"

setup() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/slim_yaml.XXXXXX")"
    export SHOGUN_QUEUE_DIR="$TEST_TMPDIR/queue"
    export TEST_PYTHON="$PROJECT_ROOT/.venv/bin/python3"
    [ -x "$TEST_PYTHON" ] || TEST_PYTHON="python3"
    mkdir -p "$SHOGUN_QUEUE_DIR"/{tasks,reports,inbox}
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

write_yaml() {
    local file="$1" value="$2"
    mkdir -p "$(dirname "$file")"
    printf '%s\n' "$value" > "$file"
}

run_slim() {
    "$TEST_PYTHON" "$PROJECT_ROOT/scripts/slim_yaml.py" "$@"
}

run_slim_wrapper() {
    bash "$PROJECT_ROOT/scripts/slim_yaml.sh" "$@"
}

yaml_value() {
    local file="$1" expr="$2"
    "$TEST_PYTHON" - "$file" "$expr" <<'PY'
import sys
import yaml

path, expr = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as fh:
    data = yaml.safe_load(fh) or {}

value = data
for key in expr.split("."):
    if isinstance(value, dict):
        value = value.get(key)
    else:
        value = None
        break
print("" if value is None else value)
PY
}

@test "dry-run does not mutate commands tasks reports inbox migration or create archive dir" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" $'queue:\n- cmd_id: cmd_done\n  status: done\n- cmd_id: cmd_pending\n  status: pending\n'
    write_yaml "$SHOGUN_QUEUE_DIR/tasks/ashigaru1.yaml" $'worker_id: ashigaru1\nstatus: done\n'
    write_yaml "$SHOGUN_QUEUE_DIR/reports/ashigaru1_cmd_done.yaml" $'parent_cmd: cmd_done\nstatus: done\n'
    touch -d "2 days ago" "$SHOGUN_QUEUE_DIR/reports/ashigaru1_cmd_done.yaml"
    write_yaml "$SHOGUN_QUEUE_DIR/inbox/karo.yaml" $'messages:\n- id: m1\n  read: true\n- id: m2\n  read: false\n'
    mkdir -p "$SHOGUN_QUEUE_DIR/reports/archive"
    write_yaml "$SHOGUN_QUEUE_DIR/reports/archive/old.yaml" "status: done"

    before="$(find "$SHOGUN_QUEUE_DIR" -type f -print0 | sort -z | xargs -0 sha256sum)"

    run run_slim karo --dry-run
    assert_success
    assert_output --partial "[DRY-RUN] would archive"

    after="$(find "$SHOGUN_QUEUE_DIR" -type f -print0 | sort -z | xargs -0 sha256sum)"
    [ "$before" = "$after" ]
    [ ! -d "$SHOGUN_QUEUE_DIR/archive" ]
    [ -f "$SHOGUN_QUEUE_DIR/reports/archive/old.yaml" ]
}

@test "wrapper dry-run does not create queue lock file" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" $'queue:\n- cmd_id: cmd_done\n  status: done\n'

    run run_slim_wrapper karo --dry-run
    assert_success

    [ ! -e "$SHOGUN_QUEUE_DIR/.slim_yaml.lock" ]
    [ "$(yaml_value "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" "queue.0.cmd_id")" = "" ]
    "$TEST_PYTHON" - "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" <<'PY'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
assert data["queue"][0]["cmd_id"] == "cmd_done"
PY
}

@test "archives terminal commands using canonical statuses and keeps non-terminal commands" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" $'queue:\n- cmd_id: cmd_done\n  status: done\n- cmd_id: cmd_cancelled\n  status: cancelled\n- cmd_id: cmd_paused\n  status: paused\n- cmd_id: cmd_pending\n  status: pending\n- cmd_id: cmd_in_progress\n  status: in_progress\n- cmd_id: cmd_blocked\n  status: blocked\n'

    run run_slim karo
    assert_success

    [ "$(yaml_value "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" "queue.0.cmd_id")" = "" ]
    "$TEST_PYTHON" - "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" <<'PY'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
ids = [item["cmd_id"] for item in data["queue"]]
# cmd_714将軍裁定: pausedはTERMINAL(archive対象)ではなくACTIVE(残存)として扱う
assert ids == ["cmd_paused", "cmd_pending", "cmd_in_progress", "cmd_blocked"], ids
PY
    archive_count="$(find "$SHOGUN_QUEUE_DIR/archive" -name 'shogun_to_karo_*.yaml' | wc -l)"
    [ "$archive_count" -eq 1 ]
}

@test "paused commands are not archived from reports slimming (cmd_714)" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" $'queue:\n- cmd_id: cmd_paused\n  status: paused\n'
    write_yaml "$SHOGUN_QUEUE_DIR/reports/ashigaru1_cmd_paused.yaml" $'parent_cmd: cmd_paused\nstatus: done\n'
    touch -d "2 days ago" "$SHOGUN_QUEUE_DIR/reports/ashigaru1_cmd_paused.yaml"

    run run_slim karo
    assert_success

    [ -f "$SHOGUN_QUEUE_DIR/reports/ashigaru1_cmd_paused.yaml" ]
    [ ! -d "$SHOGUN_QUEUE_DIR/archive/reports" ]
}

@test "supports current top-level task status and resets canonical task to top-level idle" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" "queue: []"
    write_yaml "$SHOGUN_QUEUE_DIR/tasks/ashigaru1.yaml" $'worker_id: ashigaru1\ntask_id: subtask_done\nstatus: done\n'
    write_yaml "$SHOGUN_QUEUE_DIR/tasks/subtask_done.yaml" $'task_id: subtask_done\nstatus: done\n'

    run run_slim karo
    assert_success

    [ "$(yaml_value "$SHOGUN_QUEUE_DIR/tasks/ashigaru1.yaml" "status")" = "idle" ]
    [ "$(yaml_value "$SHOGUN_QUEUE_DIR/tasks/ashigaru1.yaml" "worker_id")" = "ashigaru1" ]
    [ ! -f "$SHOGUN_QUEUE_DIR/tasks/subtask_done.yaml" ]
    [ -f "$SHOGUN_QUEUE_DIR/archive/tasks/subtask_done.yaml" ]
}

@test "supports legacy task.status and preserves legacy idle shape" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" "queue: []"
    write_yaml "$SHOGUN_QUEUE_DIR/tasks/ashigaru2.yaml" $'task:\n  task_id: subtask_legacy\n  status: done\n'

    run run_slim karo
    assert_success

    [ "$(yaml_value "$SHOGUN_QUEUE_DIR/tasks/ashigaru2.yaml" "task.status")" = "idle" ]
    [ "$(yaml_value "$SHOGUN_QUEUE_DIR/tasks/ashigaru2.yaml" "status")" = "" ]
}

@test "archives read inbox messages and preserves unread messages" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" "queue: []"
    write_yaml "$SHOGUN_QUEUE_DIR/inbox/karo.yaml" $'messages:\n- id: read-msg\n  read: true\n- id: unread-msg\n  read: false\n'

    run run_slim karo
    assert_success

    "$TEST_PYTHON" - "$SHOGUN_QUEUE_DIR/inbox/karo.yaml" <<'PY'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
ids = [item["id"] for item in data["messages"]]
assert ids == ["unread-msg"], ids
PY
    archive_count="$(find "$SHOGUN_QUEUE_DIR/archive" -name 'inbox_karo_*.yaml' | wc -l)"
    [ "$archive_count" -eq 1 ]
}

@test "ntfy inbox old pending entries are inventoried but not deleted" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" "queue: []"
    write_yaml "$SHOGUN_QUEUE_DIR/ntfy_inbox.yaml" $'inbox:\n- id: pending-old\n  status: pending\n  timestamp: "2000-01-01T00:00:00+09:00"\n- id: done-old\n  status: done\n  timestamp: "2000-01-01T00:00:00+09:00"\n'

    run run_slim karo --dry-run
    assert_success
    assert_output --partial "old ntfy pending/non-terminal entries kept"
    assert_output --partial "old ntfy terminal entries available for explicit cleanup"

    [ "$(yaml_value "$SHOGUN_QUEUE_DIR/ntfy_inbox.yaml" "inbox.0.id")" = "" ]
    "$TEST_PYTHON" - "$SHOGUN_QUEUE_DIR/ntfy_inbox.yaml" <<'PY'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
ids = [item["id"] for item in data["inbox"]]
assert ids == ["pending-old", "done-old"], ids
PY
}

@test "corrupted shogun_to_karo.yaml causes fail-closed report slimming (no archive, non-zero exit)" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" $'queue:\n  - cmd_id: cmd_x\n    status: pending\n  invalid: [unclosed'
    write_yaml "$SHOGUN_QUEUE_DIR/reports/ashigaru1_cmd_x.yaml" $'parent_cmd: cmd_x\nstatus: done\n'
    touch -d "2 days ago" "$SHOGUN_QUEUE_DIR/reports/ashigaru1_cmd_x.yaml"

    run run_slim karo
    assert_failure
    assert_output --partial "FAIL-CLOSED"

    [ -f "$SHOGUN_QUEUE_DIR/reports/ashigaru1_cmd_x.yaml" ]
    [ ! -d "$SHOGUN_QUEUE_DIR/archive/reports" ]
}

@test "missing shogun_to_karo.yaml causes fail-closed report slimming (no archive, non-zero exit) (cmd_745 redo1 D-01)" {
    # queueが存在しないのは「アクティブなcmdが0件」なのか「queueが読めず判別不能」
    # なのか区別できない。安全側に倒し、corrupted YAML同様fail-closedとする。
    write_yaml "$SHOGUN_QUEUE_DIR/reports/ashigaru1_cmd_gone.yaml" $'parent_cmd: cmd_gone\nstatus: done\n'
    touch -d "2 days ago" "$SHOGUN_QUEUE_DIR/reports/ashigaru1_cmd_gone.yaml"

    run run_slim karo
    assert_failure
    assert_output --partial "FAIL-CLOSED"

    [ -f "$SHOGUN_QUEUE_DIR/reports/ashigaru1_cmd_gone.yaml" ]
    [ ! -d "$SHOGUN_QUEUE_DIR/archive/reports" ]
}

@test "*_archive.yaml report stems are excluded from slimming without karo_slim.py patch (cmd_745 C)" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" "queue: []"
    write_yaml "$SHOGUN_QUEUE_DIR/reports/gunshi_report_archive.yaml" $'status: done\n'
    touch -d "2 days ago" "$SHOGUN_QUEUE_DIR/reports/gunshi_report_archive.yaml"

    # scripts/karo_slim.py を経由せず slim_yaml.py を直接実行する点が本テストの要点。
    run run_slim karo
    assert_success

    [ -f "$SHOGUN_QUEUE_DIR/reports/gunshi_report_archive.yaml" ]
    [ ! -d "$SHOGUN_QUEUE_DIR/archive/reports" ]
}

@test "get_active_cmd_ids recognizes cmd_id on a top-level list queue (actual canonical shape, cmd_745 A)" {
    # 実運用のshogun_to_karo.yamlは {queue:[...]} 包装ではなくトップレベルが素のlist。
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" $'- cmd_id: cmd_topA\n  status: pending\n- cmd_id: cmd_topB\n  status: done\n'
    write_yaml "$SHOGUN_QUEUE_DIR/reports/ashigaru1_cmd_topA.yaml" $'parent_cmd: cmd_topA\nstatus: done\n'
    write_yaml "$SHOGUN_QUEUE_DIR/reports/ashigaru2_cmd_topB.yaml" $'parent_cmd: cmd_topB\nstatus: done\n'
    touch -d "2 days ago" "$SHOGUN_QUEUE_DIR/reports/ashigaru1_cmd_topA.yaml"
    touch -d "2 days ago" "$SHOGUN_QUEUE_DIR/reports/ashigaru2_cmd_topB.yaml"

    run run_slim karo
    assert_success

    # cmd_topA は pending(active) のため紐づくreportは残存。cmd_topB は done(terminal) のためarchiveされる。
    [ -f "$SHOGUN_QUEUE_DIR/reports/ashigaru1_cmd_topA.yaml" ]
    [ ! -f "$SHOGUN_QUEUE_DIR/reports/ashigaru2_cmd_topB.yaml" ]
    archive_count="$(find "$SHOGUN_QUEUE_DIR/archive/reports" -name 'ashigaru2_cmd_topB.yaml' | wc -l)"
    [ "$archive_count" -eq 1 ]
}

@test "inventory_commands reports cmd_id, not <missing-id>, for non-canonical status commands (cmd_745 redo1 A-02)" {
    # inventory_commands()がcmd.get('id')のままだと、現行cmd_id commandは
    # 全て<missing-id>として監査表示されてしまう(G745-A-02)。
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" $'queue:\n- cmd_id: cmd_audit_test\n  status: mystery_status\n'

    run run_slim karo
    assert_success
    assert_output --partial "non-canonical command status: cmd_audit_test:mystery_status"
    refute_output --partial "<missing-id>"
    refute_output --partial "<missing-cmd-id>"
}
