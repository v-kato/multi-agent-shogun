#!/usr/bin/env bats
# test_ashigaru_report_lock.bats — ashigaru_report_lock.sh ユニットテスト (cmd_734)
#
# 対象: queue/reports/ashigaru{N}_report.yaml への追記(append)と
# 移管(archive/複数parent_cmd対応)を同一ロック経由で行うラッパー。
# tests/test_gunshi_report_lock.bats (cmd_699) と同形の構成に、
# agent_id引数・複数parent_cmd対応・list形式chunkのfail-safe保留を追加検証する。
#
# T-C734-1: agent_id allowlist検証(未知のagent_idは使い方エラーで拒否)
# T-C734-2: append/archive の基本動作(複数parent_cmdをまとめて移動できる)
# T-C734-3: list形式chunk(1チャンクに複数エントリ)は、一部エントリのみ完了済の
#           場合chunk全体がkeepに残る(混在fail-safe。cmd_734追加是正で
#           always-keepから「全エントリ完了済のみ移動」に変更した後も維持される
#           挙動)
# T-C734-4: archive と append を意図的に同時実行しても lost update が起きない
# T-C734-5: list形式chunkは全エントリが完了済の場合、chunk全体が移動される
#           (cmd_734追加是正の主眼。旧仕様ではlist形式は常にkeepだった)
# T-C734-6: 全件archiveでreport側の残りが0件になっても、0バイトではなく
#           有効な最小stubが書かれる(cmd_734追加是正)
# T-C734-7: report側が既に0バイトの状態でarchiveを呼ぶと、有効な最小stubへ
#           自己修復される(cmd_734追加是正・ashigaru3/4の実障害に対応)
# T-C734-8: ashigaru1・ashigaru2がallowlistに追加され、append/archiveが
#           正しく動作する(cmd_734追加是正)

setup() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export VENV_PYTHON="$PROJECT_ROOT/.venv/bin/python3"

    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/ashigaru_report_lock.XXXXXX")"
    export TEST_SCRIPT_DIR="$TEST_TMPDIR/scripts"
    mkdir -p "$TEST_SCRIPT_DIR" "$TEST_TMPDIR/queue/reports"

    cp "$PROJECT_ROOT/scripts/ashigaru_report_lock.sh" "$TEST_SCRIPT_DIR/ashigaru_report_lock.sh"
    chmod +x "$TEST_SCRIPT_DIR/ashigaru_report_lock.sh"
    ln -sf "$PROJECT_ROOT/.venv" "$TEST_TMPDIR/.venv"

    export TEST_SCRIPT="$TEST_SCRIPT_DIR/ashigaru_report_lock.sh"
    export TEST_AGENT="ashigaru6"
    export TEST_REPORT="$TEST_TMPDIR/queue/reports/${TEST_AGENT}_report.yaml"
    export TEST_ARCHIVE="$TEST_TMPDIR/queue/reports/${TEST_AGENT}_report_archive.yaml"
}

# teardown で rm -rf は使わない(家老指示・2026-08-18T15:52)。
# TEST_TMPDIR は mktemp -d 由来の $BATS_TMPDIR 配下であり、後始末は
# OS/tmpfs に任せる。

make_doc() {
    # make_doc <task_id> <parent_cmd> <out_file> — task_id/parent_cmd を持つ dict文書を out_file へ書き出す
    cat > "$3" <<EOF
worker_id: $TEST_AGENT
task_id: $1
parent_cmd: $2
status: done
result:
  verdict: pass
EOF
}

make_cmd_list() {
    # make_cmd_list <out_file> <cmd_id...> — cmd_idを1行1件で書き出す
    local out="$1"
    shift
    printf '%s\n' "$@" > "$out"
}

doc_ids() {
    # doc_ids <file> — 文書内の task_id をスペース区切りで出力(dict形式のみ・順不同比較用)
    # report_stub: true の空stub文書(cmd_734追加是正)はtask_idを持たないため
    # 実データではないと判定してスキップする。
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
    if isinstance(d, dict):
        if 'task_id' in d:
            ids.append(d['task_id'])
    elif isinstance(d, list):
        for item in d:
            if isinstance(item, dict) and 'task_id' in item:
                ids.append(item['task_id'])
print(' '.join(sorted(ids)))
PY
}

@test "T-C734-1: allowlist外のagent_idは使い方エラーで拒否される" {
    make_doc subtask_x1 cmd_X "$TEST_TMPDIR/x1.yaml"

    run bash "$TEST_SCRIPT" append ashigaru99 "$TEST_TMPDIR/x1.yaml"
    [ "$status" -eq 1 ]

    run bash "$TEST_SCRIPT" append "../../etc" "$TEST_TMPDIR/x1.yaml"
    [ "$status" -eq 1 ]

    # 対象ファイルが作られていないこと(allowlist拒否が書込前に効いている)
    [ ! -f "$TEST_TMPDIR/queue/reports/ashigaru99_report.yaml" ]
}

@test "T-C734-2: append で文書を書き込み、archive は複数parent_cmdをまとめて移動する" {
    make_doc subtask_a1 cmd_A "$TEST_TMPDIR/a1.yaml"
    make_doc subtask_b1 cmd_B "$TEST_TMPDIR/b1.yaml"
    make_doc subtask_c1 cmd_C "$TEST_TMPDIR/c1.yaml"

    run bash "$TEST_SCRIPT" append "$TEST_AGENT" "$TEST_TMPDIR/a1.yaml"
    [ "$status" -eq 0 ]
    run bash "$TEST_SCRIPT" append "$TEST_AGENT" "$TEST_TMPDIR/b1.yaml"
    [ "$status" -eq 0 ]
    run bash "$TEST_SCRIPT" append "$TEST_AGENT" "$TEST_TMPDIR/c1.yaml"
    [ "$status" -eq 0 ]

    [ "$(doc_ids "$TEST_REPORT")" = "subtask_a1 subtask_b1 subtask_c1" ]

    # 一致しない parent_cmd の archive は no-op (0件・main側は無傷)
    make_cmd_list "$TEST_TMPDIR/none_list.txt" cmd_NONE
    run bash "$TEST_SCRIPT" archive "$TEST_AGENT" "$TEST_TMPDIR/none_list.txt"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "0件移動しました" ]]
    [ "$(doc_ids "$TEST_REPORT")" = "subtask_a1 subtask_b1 subtask_c1" ]

    # cmd_A と cmd_C をまとめて1回のarchive呼び出しで移動(複数parent_cmd対応)
    make_cmd_list "$TEST_TMPDIR/done_list.txt" cmd_A cmd_C
    run bash "$TEST_SCRIPT" archive "$TEST_AGENT" "$TEST_TMPDIR/done_list.txt"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "2件を archive へ移動しました" ]]

    [ "$(doc_ids "$TEST_REPORT")" = "subtask_b1" ]
    [ "$(doc_ids "$TEST_ARCHIVE")" = "subtask_a1 subtask_c1" ]

    # 両ファイルとも壊れていない有効な YAML であること
    "$VENV_PYTHON" - "$TEST_REPORT" "$TEST_ARCHIVE" <<PY
import yaml
for p, expect_n in (("$TEST_REPORT", 1), ("$TEST_ARCHIVE", 2)):
    with open(p, encoding='utf-8') as f:
        docs = [d for d in yaml.safe_load_all(f) if d]
    assert len(docs) == expect_n, (p, docs)
PY

    [ ! -d "$TEST_TMPDIR/queue/reports/.${TEST_AGENT}_report.lock.d" ]
}

@test "T-C734-3: list形式chunk(複数エントリ混在)は一部エントリのみ完了済ならchunk全体がkeepに残る" {
    # 過去分に存在する形式: 1つの'---'区切りチャンクに複数エントリがlistでまとめられている。
    # cmd_LIST_A は完了済扱いにするが cmd_LIST_B は完了済リストに含めない(混在)。
    # チャンク内の1件でも未完了なら、チャンク全体をkeepに残す(fail-safe維持)ことを検証する。
    # list形式はappendの単一マッピング文書チェック(dict専用)に引っかかるため
    # append経由では作れない。archive側のfail-safeを独立に検証するため、
    # report ファイルへ直接1chunk分書き込む(過去分の実データを模した既成事実として扱う)。
    cat > "$TEST_REPORT" <<EOF
---
- task_id: subtask_list1
  parent_cmd: cmd_LIST_A
  status: done
- task_id: subtask_list2
  parent_cmd: cmd_LIST_B
  status: done
EOF

    make_doc subtask_d1 cmd_D "$TEST_TMPDIR/d1.yaml"
    run bash "$TEST_SCRIPT" append "$TEST_AGENT" "$TEST_TMPDIR/d1.yaml"
    [ "$status" -eq 0 ]

    [ "$(doc_ids "$TEST_REPORT")" = "subtask_d1 subtask_list1 subtask_list2" ]

    # cmd_LIST_A・cmd_D は「完了済」とするが、cmd_LIST_B は含めない(意図的な混在)
    make_cmd_list "$TEST_TMPDIR/done_list.txt" cmd_LIST_A cmd_D
    run bash "$TEST_SCRIPT" archive "$TEST_AGENT" "$TEST_TMPDIR/done_list.txt"
    [ "$status" -eq 0 ]
    # dict形式の subtask_d1 (cmd_D) のみ1件移動。list形式chunkは混在のためkeepされる
    [[ "$output" =~ "1件を archive へ移動しました" ]]
    [[ "$output" =~ "一部未完了" ]]

    # list形式chunk(list1・list2とも)はreport側に残り、dict形式(subtask_d1)のみarchiveへ移る
    [ "$(doc_ids "$TEST_REPORT")" = "subtask_list1 subtask_list2" ]
    [ "$(doc_ids "$TEST_ARCHIVE")" = "subtask_d1" ]
}

@test "T-C734-5: list形式chunkは全エントリが完了済ならchunk全体が移動される" {
    # T-C734-3 と対になるケース: chunk内の全エントリ(cmd_LIST_C・cmd_LIST_D)が
    # 完了済cmdの場合、chunk全体(list1・list2相当の2エントリ)がarchiveへ移る。
    # 旧仕様(cmd_734是正前)ではlist形式は常にkeepだったため、この移動自体が
    # 本追加是正の主眼である。
    cat > "$TEST_REPORT" <<EOF
---
- task_id: subtask_list3
  parent_cmd: cmd_LIST_C
  status: done
- task_id: subtask_list4
  parent_cmd: cmd_LIST_D
  status: done
EOF

    make_doc subtask_e1 cmd_E "$TEST_TMPDIR/e1.yaml"
    run bash "$TEST_SCRIPT" append "$TEST_AGENT" "$TEST_TMPDIR/e1.yaml"
    [ "$status" -eq 0 ]
    [ "$(doc_ids "$TEST_REPORT")" = "subtask_e1 subtask_list3 subtask_list4" ]

    # cmd_LIST_C・cmd_LIST_D のみ完了済とする(cmd_E は含めない)
    make_cmd_list "$TEST_TMPDIR/done_list.txt" cmd_LIST_C cmd_LIST_D
    run bash "$TEST_SCRIPT" archive "$TEST_AGENT" "$TEST_TMPDIR/done_list.txt"
    [ "$status" -eq 0 ]
    # list形式chunk全体(2エントリ)が移動する
    [[ "$output" =~ "2件を archive へ移動しました" ]]
    [[ "$output" =~ "list形式chunk全体移動: 1件" ]]

    # dict形式(subtask_e1・cmd_E未完了)はreportに残り、list形式2件はarchiveへ移る
    [ "$(doc_ids "$TEST_REPORT")" = "subtask_e1" ]
    [ "$(doc_ids "$TEST_ARCHIVE")" = "subtask_list3 subtask_list4" ]
}

@test "T-C734-6: 全件archiveでreport側の残りが0件になっても0バイトにならず有効なstubが書かれる" {
    make_doc subtask_f1 cmd_F "$TEST_TMPDIR/f1.yaml"
    run bash "$TEST_SCRIPT" append "$TEST_AGENT" "$TEST_TMPDIR/f1.yaml"
    [ "$status" -eq 0 ]

    make_cmd_list "$TEST_TMPDIR/done_list.txt" cmd_F
    run bash "$TEST_SCRIPT" archive "$TEST_AGENT" "$TEST_TMPDIR/done_list.txt"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "1件を archive へ移動しました" ]]
    [[ "$output" =~ "残り0chunk" ]]

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

    # このstub状態のままもう一度archiveを呼んでも安全(エラーにならず、
    # stubがdict-not-matchedとしてkeepに残り続ける)
    run bash "$TEST_SCRIPT" archive "$TEST_AGENT" "$TEST_TMPDIR/done_list.txt"
    [ "$status" -eq 0 ]
    [ -s "$TEST_REPORT" ]
}

@test "T-C734-7: report側が既に0バイトの状態でarchiveを呼ぶと有効なstubへ自己修復される" {
    # ashigaru3/4 で実際に発生した状態(0バイトファイル)を直接再現する。
    : > "$TEST_REPORT"
    [ -f "$TEST_REPORT" ]
    [ ! -s "$TEST_REPORT" ]

    make_cmd_list "$TEST_TMPDIR/dummy_list.txt" cmd_ANYTHING
    run bash "$TEST_SCRIPT" archive "$TEST_AGENT" "$TEST_TMPDIR/dummy_list.txt"
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

@test "T-C734-8: ashigaru1・ashigaru2がallowlistに追加され、append/archiveが正しく動作する" {
    for agent in ashigaru1 ashigaru2; do
        report="$TEST_TMPDIR/queue/reports/${agent}_report.yaml"
        archive="$TEST_TMPDIR/queue/reports/${agent}_report_archive.yaml"

        make_doc subtask_g1 cmd_G "$TEST_TMPDIR/${agent}_g1.yaml"
        run bash "$TEST_SCRIPT" append "$agent" "$TEST_TMPDIR/${agent}_g1.yaml"
        [ "$status" -eq 0 ]
        [ "$(doc_ids "$report")" = "subtask_g1" ]

        make_cmd_list "$TEST_TMPDIR/${agent}_done_list.txt" cmd_G
        run bash "$TEST_SCRIPT" archive "$agent" "$TEST_TMPDIR/${agent}_done_list.txt"
        [ "$status" -eq 0 ]
        [[ "$output" =~ "1件を archive へ移動しました" ]]
        [ "$(doc_ids "$archive")" = "subtask_g1" ]
    done
}

@test "T-C734-4: karo の archive と ashigaru の append を同時実行しても更新が失われない" {
    # 事前状態: cmd_A x2, cmd_B x1, cmd_C x2 = 5件
    make_doc subtask_s1 cmd_A "$TEST_TMPDIR/s1.yaml"
    make_doc subtask_s2 cmd_A "$TEST_TMPDIR/s2.yaml"
    make_doc subtask_s3 cmd_B "$TEST_TMPDIR/s3.yaml"
    make_doc subtask_s4 cmd_C "$TEST_TMPDIR/s4.yaml"
    make_doc subtask_s5 cmd_C "$TEST_TMPDIR/s5.yaml"
    for n in s1 s2 s3 s4 s5; do
        bash "$TEST_SCRIPT" append "$TEST_AGENT" "$TEST_TMPDIR/$n.yaml" >/dev/null
    done
    [ "$(doc_ids "$TEST_REPORT")" = "subtask_s1 subtask_s2 subtask_s3 subtask_s4 subtask_s5" ]

    # 家老の移管(cmd_A・cmd_C まとめて)と足軽の新規追記(cmd_D/E/F)を同時実行
    make_doc subtask_n1 cmd_D "$TEST_TMPDIR/n1.yaml"
    make_doc subtask_n2 cmd_E "$TEST_TMPDIR/n2.yaml"
    make_doc subtask_n3 cmd_F "$TEST_TMPDIR/n3.yaml"
    make_cmd_list "$TEST_TMPDIR/done_list.txt" cmd_A cmd_C

    bash "$TEST_SCRIPT" archive "$TEST_AGENT" "$TEST_TMPDIR/done_list.txt" > "$TEST_TMPDIR/out_ac.log" 2>&1 &
    pid_ac=$!
    bash "$TEST_SCRIPT" append "$TEST_AGENT" "$TEST_TMPDIR/n1.yaml" > "$TEST_TMPDIR/out_n1.log" 2>&1 &
    pid_n1=$!
    bash "$TEST_SCRIPT" append "$TEST_AGENT" "$TEST_TMPDIR/n2.yaml" > "$TEST_TMPDIR/out_n2.log" 2>&1 &
    pid_n2=$!
    bash "$TEST_SCRIPT" append "$TEST_AGENT" "$TEST_TMPDIR/n3.yaml" > "$TEST_TMPDIR/out_n3.log" 2>&1 &
    pid_n3=$!

    for pid in $pid_ac $pid_n1 $pid_n2 $pid_n3; do
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

    [ ! -d "$TEST_TMPDIR/queue/reports/.${TEST_AGENT}_report.lock.d" ]
}

