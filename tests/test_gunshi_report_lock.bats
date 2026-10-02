#!/usr/bin/env bats
# test_gunshi_report_lock.bats — gunshi_report_lock.sh ユニットテスト (cmd_699)
#
# 対象: queue/reports/gunshi_report.yaml への追記(append/軍師)と
# 移管(archive/家老)を同一ロック(queue/reports/.gunshi_report.lock)経由で
# 行うラッパー。inbox_write.sh の T-010 (flock並行書き込みテスト) と同形。
#
# T-C699-1: append/archive の基本動作 (正しい文書が正しいファイルへ入る)
# T-C699-2: archive と append を意図的に同時実行しても lost update が起きない
# T-C751-1: 全件archiveでreport側の残りが0件になっても0バイトにならず有効なstubが書かれる
# T-C751-2: report側が既に0バイトの状態でarchiveを呼ぶと有効なstubへ自己修復される

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

make_nested_doc() {
    # make_nested_doc <task_id> <parent_cmd> <out_file> — legacy nested形式
    # (report: 直下にtask_id/parent_cmd)の文書を out_file へ書き出す
    # (cmd_734 G734-B-01・実データのcmd_631文書と同形)
    cat > "$3" <<EOF
report:
  task_id: $1
  parent_cmd: $2
  status: done
  verdict: PASS
EOF
}

make_other_nested_doc() {
    # make_other_nested_doc <task_id> <parent_cmd> <out_file> — report以外の
    # キー(result)配下へネストした文書。legacy互換対応の対象外形式(G734-B-01
    # required_fix「その他の任意ネストまで広げるな」の回帰確認用)
    cat > "$3" <<EOF
result:
  task_id: $1
  parent_cmd: $2
  status: done
EOF
}

doc_ids() {
    # doc_ids <file> — 文書内の task_id をスペース区切りで出力 (順不同比較用)。
    # 標準形式(トップレベルtask_id)を優先し、無ければlegacy nested形式
    # (report.task_id)を見る。doc_parent_cmd()と同じ2形式限定の優先順位。
    "$VENV_PYTHON" - "$1" <<'PY'
import sys, yaml
path = sys.argv[1]
try:
    with open(path, encoding='utf-8') as f:
        docs = [d for d in yaml.safe_load_all(f) if d]
except FileNotFoundError:
    docs = []
ids = []
for d in docs:
    tid = d.get('task_id')
    if tid is None and isinstance(d.get('report'), dict):
        tid = d['report'].get('task_id')
    ids.append(tid)
print(' '.join(sorted(ids)))
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

# =============================================================================
# cmd_734 G734-B-01: archive の legacy nested (report.parent_cmd) 後方互換対応
# =============================================================================

@test "T-C734-B01-1: archive は標準形式(トップレベルparent_cmd)とlegacy nested形式(report.parent_cmd)の両方を検出して移動する" {
    make_doc subtask_std1 cmd_STD "$TEST_TMPDIR/std1.yaml"
    make_nested_doc subtask_legacy1 cmd_LEGACY "$TEST_TMPDIR/legacy1.yaml"
    make_nested_doc subtask_legacy2 cmd_OTHER "$TEST_TMPDIR/legacy2.yaml"

    run bash "$TEST_SCRIPT" append "$TEST_TMPDIR/std1.yaml"
    [ "$status" -eq 0 ]
    run bash "$TEST_SCRIPT" append "$TEST_TMPDIR/legacy1.yaml"
    [ "$status" -eq 0 ]
    run bash "$TEST_SCRIPT" append "$TEST_TMPDIR/legacy2.yaml"
    [ "$status" -eq 0 ]

    [ "$(doc_ids "$TEST_REPORT")" = "subtask_legacy1 subtask_legacy2 subtask_std1" ]

    # legacy nested形式でparent_cmd=cmd_LEGACYの文書のみがarchiveへ移動する
    # (cmd_OTHER・標準形式のcmd_STDはactiveに残る)
    run bash "$TEST_SCRIPT" archive cmd_LEGACY
    [ "$status" -eq 0 ]
    [[ "$output" =~ "1件を archive へ移動しました" ]]

    [ "$(doc_ids "$TEST_REPORT")" = "subtask_legacy2 subtask_std1" ]
    [ "$(doc_ids "$TEST_ARCHIVE")" = "subtask_legacy1" ]

    # 標準形式(cmd_STD)も引き続き正しく移動できること(回帰確認)
    run bash "$TEST_SCRIPT" archive cmd_STD
    [ "$status" -eq 0 ]
    [[ "$output" =~ "1件を archive へ移動しました" ]]
    [ "$(doc_ids "$TEST_REPORT")" = "subtask_legacy2" ]
    [ "$(doc_ids "$TEST_ARCHIVE")" = "subtask_legacy1 subtask_std1" ]

    # 両ファイルとも壊れていない有効なYAMLであること
    "$VENV_PYTHON" - "$TEST_REPORT" "$TEST_ARCHIVE" <<PY
import yaml
for p in ("$TEST_REPORT", "$TEST_ARCHIVE"):
    with open(p, encoding='utf-8') as f:
        docs = [d for d in yaml.safe_load_all(f) if d]
    assert len(docs) >= 1, (p, docs)
PY
}

@test "T-C734-B01-2: archive は report 以外のキーへネストした parent_cmd (対象外形式) を無視し active に残す" {
    make_doc subtask_std2 cmd_STD2 "$TEST_TMPDIR/std2.yaml"
    make_other_nested_doc subtask_other1 cmd_OTHERFMT "$TEST_TMPDIR/other1.yaml"

    run bash "$TEST_SCRIPT" append "$TEST_TMPDIR/std2.yaml"
    [ "$status" -eq 0 ]
    run bash "$TEST_SCRIPT" append "$TEST_TMPDIR/other1.yaml"
    [ "$status" -eq 0 ]

    # result: 配下ネストはrequired_fixが明示する「その他の任意ネストまで
    # 広げるな」の対象外形式なので、archiveは0件のままactiveに留まる
    run bash "$TEST_SCRIPT" archive cmd_OTHERFMT
    [ "$status" -eq 0 ]
    [[ "$output" =~ "0件移動しました" ]]

    # 両文書ともactiveに残っていること(対象外形式が誤って移動されていない証跡)
    grep -q "subtask_std2" "$TEST_REPORT"
    grep -q "subtask_other1" "$TEST_REPORT"
    run cat "$TEST_ARCHIVE"
    [ "$status" -ne 0 ]

    # 標準形式(cmd_STD2)は引き続き正しく移動できること(回帰確認)
    run bash "$TEST_SCRIPT" archive cmd_STD2
    [ "$status" -eq 0 ]
    [[ "$output" =~ "1件を archive へ移動しました" ]]
    run grep -q "subtask_std2" "$TEST_REPORT"
    [ "$status" -ne 0 ]
    grep -q "subtask_other1" "$TEST_REPORT"
    grep -q "subtask_std2" "$TEST_ARCHIVE"
}

# =============================================================================
# cmd_751: 全件archive時0バイト化の封鎖(stub化・自己修復)
# =============================================================================

@test "T-C751-1: 全件archiveでreport側の残りが0件になっても0バイトにならず有効なstubが書かれる" {
    make_doc subtask_h1 cmd_H "$TEST_TMPDIR/h1.yaml"

    run bash "$TEST_SCRIPT" append "$TEST_TMPDIR/h1.yaml"
    [ "$status" -eq 0 ]
    [ "$(doc_ids "$TEST_REPORT")" = "subtask_h1" ]

    # cmd_H が唯一の文書 → archive後、report側の残りは0件になる
    run bash "$TEST_SCRIPT" archive cmd_H
    [ "$status" -eq 0 ]
    [[ "$output" =~ "1件を archive へ移動しました" ]]
    [[ "$output" =~ "残り 0 件" ]]

    # 0バイトになっていないこと(そのもの)
    [ -s "$TEST_REPORT" ]
    # 有効なYAML dictであり、report_stub: true を持つこと(task_idは持たない)
    "$VENV_PYTHON" - "$TEST_REPORT" <<PY
import sys, yaml
with open(sys.argv[1], encoding='utf-8') as f:
    docs = [d for d in yaml.safe_load_all(f) if d]
assert len(docs) == 1, docs
assert docs[0].get('report_stub') is True, docs[0]
assert 'task_id' not in docs[0], docs[0]
PY

    # stub状態のままもう一度archiveを呼んでも安全(エラーにならず、
    # stubはparent_cmd不一致としてkeepに残り続け、report側は無傷)
    run bash "$TEST_SCRIPT" archive cmd_H
    [ "$status" -eq 0 ]
    [[ "$output" =~ "0件移動しました" ]]
    [ -s "$TEST_REPORT" ]
}

@test "T-C751-2: report側が既に0バイトの状態でarchiveを呼ぶと有効なstubへ自己修復される" {
    # cmd_751起票の実障害(ashigaru3/4で実際に発生した0バイト化)を直接再現する。
    : > "$TEST_REPORT"
    [ -f "$TEST_REPORT" ]
    [ ! -s "$TEST_REPORT" ]

    run bash "$TEST_SCRIPT" archive cmd_ANYTHING
    [ "$status" -eq 0 ]
    [[ "$output" =~ "0バイトだったため" ]]
    [[ "$output" =~ "有効な空stubへ是正しました" ]]

    [ -s "$TEST_REPORT" ]
    "$VENV_PYTHON" - "$TEST_REPORT" <<PY
import sys, yaml
with open(sys.argv[1], encoding='utf-8') as f:
    docs = [d for d in yaml.safe_load_all(f) if d]
assert len(docs) == 1, docs
assert docs[0].get('report_stub') is True, docs[0]
PY
}
