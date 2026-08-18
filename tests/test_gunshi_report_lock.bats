#!/usr/bin/env bats
# test_gunshi_report_lock.bats — gunshi_report_lock.sh ユニットテスト (cmd_699)
#
# 対象: queue/reports/gunshi_report.yaml への追記(append/軍師)と
# 移管(archive/家老)を同一ロック(queue/reports/.gunshi_report.lock)経由で
# 行うラッパー。inbox_write.sh の T-010 (flock並行書き込みテスト) と同形。
#
# T-C699-1: append/archive の基本動作 (正しい文書が正しいファイルへ入る)
# T-C699-2: archive と append を意図的に同時実行しても lost update が起きない

setup() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export VENV_PYTHON="$PROJECT_ROOT/.venv/bin/python3"

    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/gunshi_report_lock.XXXXXX")"
    export TEST_SCRIPT_DIR="$TEST_TMPDIR/scripts"
    mkdir -p "$TEST_SCRIPT_DIR" "$TEST_TMPDIR/queue/reports"

    cp "$PROJECT_ROOT/scripts/gunshi_report_lock.sh" "$TEST_SCRIPT_DIR/gunshi_report_lock.sh"
    chmod +x "$TEST_SCRIPT_DIR/gunshi_report_lock.sh"
    ln -sf "$PROJECT_ROOT/.venv" "$TEST_TMPDIR/.venv"

    export TEST_SCRIPT="$TEST_SCRIPT_DIR/gunshi_report_lock.sh"
    export TEST_REPORT="$TEST_TMPDIR/queue/reports/gunshi_report.yaml"
    export TEST_ARCHIVE="$TEST_TMPDIR/queue/reports/gunshi_report_archive.yaml"
}

# teardown で rm -rf は使わない(家老指示・2026-08-18T15:52)。
# TEST_TMPDIR は mktemp -d 由来の $BATS_TMPDIR 配下であり、後始末は
# OS/tmpfs に任せる。

make_doc() {
    # make_doc <task_id> <parent_cmd> <out_file> — task_id/parent_cmd を持つ文書を out_file へ書き出す
    cat > "$3" <<EOF
worker_id: gunshi
task_id: $1
parent_cmd: $2
status: done
result:
  verdict: pass
EOF
}

doc_ids() {
    # doc_ids <file> — 文書内の task_id をスペース区切りで出力 (順不同比較用)
    "$VENV_PYTHON" - "$1" <<'PY'
import sys, yaml
path = sys.argv[1]
try:
    with open(path, encoding='utf-8') as f:
        docs = [d for d in yaml.safe_load_all(f) if d]
except FileNotFoundError:
    docs = []
print(' '.join(sorted(d['task_id'] for d in docs)))
PY
}

@test "T-C699-1: append で文書を書き込み、archive は一致する parent_cmd の文書のみを移動する" {
    make_doc subtask_a1 cmd_A "$TEST_TMPDIR/a1.yaml"
    make_doc subtask_b1 cmd_B "$TEST_TMPDIR/b1.yaml"

    run bash "$TEST_SCRIPT" append "$TEST_TMPDIR/a1.yaml"
    [ "$status" -eq 0 ]
    run bash "$TEST_SCRIPT" append "$TEST_TMPDIR/b1.yaml"
    [ "$status" -eq 0 ]

    [ "$(doc_ids "$TEST_REPORT")" = "subtask_a1 subtask_b1" ]

    # 一致しない parent_cmd の archive は no-op (0件・main側は無傷)
    run bash "$TEST_SCRIPT" archive cmd_NONE
    [ "$status" -eq 0 ]
    [[ "$output" =~ "0件移動しました" ]]
    [ "$(doc_ids "$TEST_REPORT")" = "subtask_a1 subtask_b1" ]

    # cmd_A だけが archive へ移る
    run bash "$TEST_SCRIPT" archive cmd_A
    [ "$status" -eq 0 ]
    [[ "$output" =~ "1件を archive へ移動しました" ]]

    [ "$(doc_ids "$TEST_REPORT")" = "subtask_b1" ]
    [ "$(doc_ids "$TEST_ARCHIVE")" = "subtask_a1" ]

    # 両ファイルとも壊れていない有効な YAML であること
    "$VENV_PYTHON" - "$TEST_REPORT" "$TEST_ARCHIVE" <<PY
import yaml
for p in ("$TEST_REPORT", "$TEST_ARCHIVE"):
    with open(p, encoding='utf-8') as f:
        docs = [d for d in yaml.safe_load_all(f) if d]
    assert len(docs) == 1, (p, docs)
PY

    [ ! -d "$TEST_TMPDIR/queue/reports/.gunshi_report.lock.d" ]
}

@test "T-C699-2: karo の archive と gunshi の append を同時実行しても更新が失われない" {
    # 事前状態: cmd_A x2, cmd_B x1, cmd_C x2 = 5件
    make_doc subtask_s1 cmd_A "$TEST_TMPDIR/s1.yaml"
    make_doc subtask_s2 cmd_A "$TEST_TMPDIR/s2.yaml"
    make_doc subtask_s3 cmd_B "$TEST_TMPDIR/s3.yaml"
    make_doc subtask_s4 cmd_C "$TEST_TMPDIR/s4.yaml"
    make_doc subtask_s5 cmd_C "$TEST_TMPDIR/s5.yaml"
    for n in s1 s2 s3 s4 s5; do
        bash "$TEST_SCRIPT" append "$TEST_TMPDIR/$n.yaml" >/dev/null
    done
    [ "$(doc_ids "$TEST_REPORT")" = "subtask_s1 subtask_s2 subtask_s3 subtask_s4 subtask_s5" ]

    # 家老の移管(cmd_A・cmd_C)と軍師の新規追記(cmd_D/E/F)を同時実行
    make_doc subtask_n1 cmd_D "$TEST_TMPDIR/n1.yaml"
    make_doc subtask_n2 cmd_E "$TEST_TMPDIR/n2.yaml"
    make_doc subtask_n3 cmd_F "$TEST_TMPDIR/n3.yaml"

    bash "$TEST_SCRIPT" archive cmd_A > "$TEST_TMPDIR/out_a.log" 2>&1 &
    pid_a=$!
    bash "$TEST_SCRIPT" archive cmd_C > "$TEST_TMPDIR/out_c.log" 2>&1 &
    pid_c=$!
    bash "$TEST_SCRIPT" append "$TEST_TMPDIR/n1.yaml" > "$TEST_TMPDIR/out_n1.log" 2>&1 &
    pid_n1=$!
    bash "$TEST_SCRIPT" append "$TEST_TMPDIR/n2.yaml" > "$TEST_TMPDIR/out_n2.log" 2>&1 &
    pid_n2=$!
    bash "$TEST_SCRIPT" append "$TEST_TMPDIR/n3.yaml" > "$TEST_TMPDIR/out_n3.log" 2>&1 &
    pid_n3=$!

    for pid in $pid_a $pid_c $pid_n1 $pid_n2 $pid_n3; do
        wait "$pid"
        [ "$?" -eq 0 ]
    done

    # 元5件 + 新規3件 = 8件が一切失われず両ファイルに分配されていること
    report_ids="$(doc_ids "$TEST_REPORT")"
    archive_ids="$(doc_ids "$TEST_ARCHIVE")"

    [ "$report_ids" = "subtask_n1 subtask_n2 subtask_n3 subtask_s3" ]
    [ "$archive_ids" = "subtask_s1 subtask_s2 subtask_s4 subtask_s5" ]

    all_ids="$(printf '%s\n' $report_ids $archive_ids | sort | tr '\n' ' ')"
    all_ids="${all_ids% }"
    [ "$all_ids" = "subtask_n1 subtask_n2 subtask_n3 subtask_s1 subtask_s2 subtask_s3 subtask_s4 subtask_s5" ]

    [ ! -d "$TEST_TMPDIR/queue/reports/.gunshi_report.lock.d" ]
}
