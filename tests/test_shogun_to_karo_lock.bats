#!/usr/bin/env bats
# test_shogun_to_karo_lock.bats — shogun_to_karo_lock.sh ユニットテスト
# (cmd_741 / cmd_741 redo1 / redo2)
#
# 対象: queue/shogun_to_karo.yaml への新規cmd追記(append)・既存cmdの
# フィールド更新(update)・既存cmdの削除(remove)を、共通の排他ロック
# (queue/.shogun_to_karo.lock)経由で行うラッパー。2026-09-01T17:2x頃、
# 将軍が `cat >> queue/shogun_to_karo.yaml <<EOF ... EOF` で追記した際に
# 区切り行が消失し、cmd_735がcmd_734へサイレント吸収される事故が起きた
# (cmd_731/732でも同型)。redo1では、append専用lockだけでは防げない
# Karoのread-modify-write(status更新・archive移管)由来のlost update、
# ロック二重解放によるownership崩壊、PyYAML safe_loadの重複key後勝ち
# 受理も是正対象とした。
#
# T-C741-1: append の基本動作(単発・複数回・複数要素まとめて)
# T-C741-2: 将軍のヒアドキュメント記法がそのまま使えること (A-2)
# T-C741-3: 異常な標準入力(空/不正YAML/非list/cmd_id欠落)は拒否され、
#           本番ファイルには一切変更が反映されない
# T-C741-4: 既存ファイルが壊れている(トップレベルがlistでない)場合は
#           書込み前に拒否され、既存ファイルは無傷のまま
# T-C741-5: 5プロセス完全同時appendでも区切り行が消えず、全件が
#           過不足なく保存される(cmd_734/735事故の再発防止・本命)
# ↑ T-C741-1〜5はcmd_741初回実装分。据え置き(壊すな・再変更するな)。
#
# T-C741-6〜7:  update の基本動作・異常系 (G741-WRITER-COVERAGE-01)
# T-C741-8〜9:  remove の基本動作・異常系 (G741-WRITER-COVERAGE-01)
# T-C741-10:    mapping内重複keyの拒否 (G741-YAML-STRICTNESS-04)
# T-C741-11:    結合/更新後のcmd_id一意性検査 (G741-YAML-STRICTNESS-04)
# T-C741-12〜13: append対update・append対active-removalの並行fixtureで
#               lost update 0 を示す (G741-WRITER-COVERAGE-01)
# T-C741-14〜15: ロック保持者/後続所有者のLOCK_DIRを、取得できなかった
#               processや先行processの遅延trapが誤って消さない
#               (G741-LOCK-OWNERSHIP-03)
#
# ↓ 以下はcmd_741 redo2追加分(軍師QC 2026-09-02T20:49:04、verdict:
#   FAIL_REDO2_SCOPE_AMENDMENT_REQUIRED)。中核lock機構(上記T-C741-1〜15)
#   は再変更禁止・据え置き。
# T-C741-16:    quoted heredoc(`<<'EOF'`)がliteral `$VAR`/`${...}`/
#               バッククォート/`$()`をbyte-for-byteで保存すること
#               (G741-R1-HEREDOC-01)
# T-C741-17〜19: append/update/removeそれぞれで、既存targetのmode
#               (パーミッションbit)が書込み後も保持されること
#               (G741-R1-MODE-02)
# T-C741-20:    SHOGUN_TO_KARO_LOCK_TEST_MODEを設定しない限り、個別
#               チューニング変数(SHOGUN_TO_KARO_LOCK_MKDIR_ITERS等)が
#               呼び出し元シェルに残留していても黙殺され、既定値が使われる
#               こと (G741-R1-TEST-HOOK-05)

setup() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export VENV_PYTHON="$PROJECT_ROOT/.venv/bin/python3"

    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/shogun_to_karo_lock.XXXXXX")"
    export TEST_SCRIPT_DIR="$TEST_TMPDIR/scripts"
    mkdir -p "$TEST_SCRIPT_DIR" "$TEST_TMPDIR/queue"

    cp "$PROJECT_ROOT/scripts/shogun_to_karo_lock.sh" "$TEST_SCRIPT_DIR/shogun_to_karo_lock.sh"
    chmod +x "$TEST_SCRIPT_DIR/shogun_to_karo_lock.sh"
    ln -sf "$PROJECT_ROOT/.venv" "$TEST_TMPDIR/.venv"

    export TEST_SCRIPT="$TEST_SCRIPT_DIR/shogun_to_karo_lock.sh"
    export TEST_TARGET="$TEST_TMPDIR/queue/shogun_to_karo.yaml"
    export TEST_LOCK_DIR="$TEST_TMPDIR/queue/.shogun_to_karo.lock.d"
}

# teardown で rm -rf は使わない(家老指示・2026-08-18T15:52、
# test_gunshi_report_lock.bats と同方針)。TEST_TMPDIR は mktemp -d 由来の
# $BATS_TMPDIR 配下であり、後始末は OS/tmpfs に任せる。

make_cmd_doc() {
    # make_cmd_doc <cmd_id> <title> <out_file> — cmd_idを持つ単一要素の
    # YAML list(1件)を out_file へ書き出す
    cat > "$3" <<EOF
- cmd_id: $1
  timestamp: '2026-09-02T18:00:00+09:00'
  title: $2
  status: pending
EOF
}

cmd_ids() {
    # cmd_ids <file> — ファイル内の cmd_id をスペース区切りで出力(順不同比較用)
    "$VENV_PYTHON" - "$1" <<'PY'
import sys, yaml
path = sys.argv[1]
try:
    with open(path, encoding='utf-8') as f:
        data = yaml.safe_load(f) or []
except FileNotFoundError:
    data = []
ids = [e.get('cmd_id') for e in data if isinstance(e, dict) and e.get('cmd_id')]
print(' '.join(sorted(ids)))
PY
}

field_value() {
    # field_value <file> <cmd_id> <field> — 指定cmd_idの指定fieldの値を
    # repr()で1行出力する(改行を含む値も1行で比較できるようにするため)。
    # cmd_id自体が無ければ '__NOTFOUND__'、fieldが無ければ 'None' を出力。
    "$VENV_PYTHON" - "$1" "$2" "$3" <<'PY'
import sys, yaml
path, cid, field = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding='utf-8') as f:
    data = yaml.safe_load(f) or []
for e in data:
    if isinstance(e, dict) and e.get('cmd_id') == cid:
        print(repr(e.get(field)))
        break
else:
    print('__NOTFOUND__')
PY
}

assert_file_contains() {
    # assert_file_contains <file> <needle_file> — <file> が <needle_file> の
    # 内容をそのまま(部分文字列として)含んでいればexit 0
    "$VENV_PYTHON" - "$1" "$2" <<'PY'
import sys
path, needle_path = sys.argv[1], sys.argv[2]
with open(path, encoding='utf-8') as f:
    hay = f.read()
with open(needle_path, encoding='utf-8') as f:
    needle = f.read()
sys.exit(0 if needle in hay else 1)
PY
}

@test "T-C741-1: append の基本動作(単発・複数回・複数要素まとめて)" {
    make_cmd_doc cmd_A1 A1 "$TEST_TMPDIR/a1.yaml"
    run bash -c "bash '$TEST_SCRIPT' append < '$TEST_TMPDIR/a1.yaml'"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "1件追記しました(cmd_id要素数: 0 → 1)" ]]
    [ "$(cmd_ids "$TEST_TARGET")" = "cmd_A1" ]

    make_cmd_doc cmd_A2 A2 "$TEST_TMPDIR/a2.yaml"
    run bash -c "bash '$TEST_SCRIPT' append < '$TEST_TMPDIR/a2.yaml'"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "1件追記しました(cmd_id要素数: 1 → 2)" ]]
    [ "$(cmd_ids "$TEST_TARGET")" = "cmd_A1 cmd_A2" ]

    # 複数要素をまとめて1回のappendで追記(N=2)
    cat > "$TEST_TMPDIR/multi.yaml" <<'EOF'
- cmd_id: cmd_A3
  title: A3
- cmd_id: cmd_A4
  title: A4
EOF
    run bash -c "bash '$TEST_SCRIPT' append < '$TEST_TMPDIR/multi.yaml'"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "2件追記しました(cmd_id要素数: 2 → 4)" ]]
    [ "$(cmd_ids "$TEST_TARGET")" = "cmd_A1 cmd_A2 cmd_A3 cmd_A4" ]

    # 書込み後のファイルが妥当なYAML・トップレベルlistであること
    "$VENV_PYTHON" - "$TEST_TARGET" <<PY
import yaml
with open("$TEST_TARGET", encoding='utf-8') as f:
    data = yaml.safe_load(f)
assert isinstance(data, list), data
assert len(data) == 4, data
PY

    [ ! -d "$TEST_TMPDIR/queue/.shogun_to_karo.lock.d" ]
}

@test "T-C741-2: 将軍のヒアドキュメント記法がそのまま使える (A-2)" {
    run bash "$TEST_SCRIPT" append <<'EOF'
- cmd_id: cmd_HEREDOC
  timestamp: '2026-09-02T18:10:00+09:00'
  north_star: ヒアドキュメントでの追記確認
  status: pending
EOF
    [ "$status" -eq 0 ]
    [[ "$output" =~ "1件追記しました(cmd_id要素数: 0 → 1)" ]]
    [ "$(cmd_ids "$TEST_TARGET")" = "cmd_HEREDOC" ]
}

@test "T-C741-3: 異常な標準入力は拒否され、本番ファイルは一切変更されない" {
    # 空
    run bash -c ": | bash '$TEST_SCRIPT' append"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "標準入力が空です" ]]
    [ ! -e "$TEST_TARGET" ]

    # 不正なYAML
    printf '  : broken: [\n' > "$TEST_TMPDIR/broken.yaml"
    run bash -c "bash '$TEST_SCRIPT' append < '$TEST_TMPDIR/broken.yaml'"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "正しいYAMLではありません" ]]
    [ ! -e "$TEST_TARGET" ]

    # トップレベルがlistでない(dict)
    printf 'cmd_id: cmd_X\ntitle: X\n' > "$TEST_TMPDIR/notlist.yaml"
    run bash -c "bash '$TEST_SCRIPT' append < '$TEST_TMPDIR/notlist.yaml'"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "YAML list" ]]
    [ ! -e "$TEST_TARGET" ]

    # cmd_idを持たない要素を含む
    cat > "$TEST_TMPDIR/noid.yaml" <<'EOF'
- cmd_id: cmd_X
  title: X
- title: NoId
EOF
    run bash -c "bash '$TEST_SCRIPT' append < '$TEST_TMPDIR/noid.yaml'"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "cmd_idを持つマッピング" ]]
    [ ! -e "$TEST_TARGET" ]
}

@test "T-C741-4: 既存ファイルが壊れている場合は書込み前に拒否し、既存ファイルは無傷のまま" {
    printf 'not_a_list: true\n' > "$TEST_TARGET"

    make_cmd_doc cmd_X X "$TEST_TMPDIR/x.yaml"
    run bash -c "bash '$TEST_SCRIPT' append < '$TEST_TMPDIR/x.yaml'"
    [ "$status" -eq 2 ]
    [[ "$output" =~ "既存ファイルのトップレベルがlistでは" ]]

    # 既存ファイルの内容が一切変更されていないこと(バイト単位で一致)
    run cat "$TEST_TARGET"
    [ "$output" = "not_a_list: true" ]
}

@test "T-C741-5: 5プロセス完全同時appendでも区切り行が消えず全件保存される" {
    # 事前状態: cmd_S1〜cmd_S5 を逐次追記(将軍のこれまでの投稿を模す)
    for n in 1 2 3 4 5; do
        make_cmd_doc "cmd_S$n" "Seed$n" "$TEST_TMPDIR/seed_$n.yaml"
        bash -c "bash '$TEST_SCRIPT' append < '$TEST_TMPDIR/seed_$n.yaml'" >/dev/null
    done
    [ "$(cmd_ids "$TEST_TARGET")" = "cmd_S1 cmd_S2 cmd_S3 cmd_S4 cmd_S5" ]

    # 将軍3件+家老想定2件、計5件を完全同時実行(race再現)
    for n in A B C D E; do
        make_cmd_doc "cmd_N$n" "New$n" "$TEST_TMPDIR/new_$n.yaml"
    done

    for n in A B C D E; do
        ( bash -c "bash '$TEST_SCRIPT' append < '$TEST_TMPDIR/new_$n.yaml'" > "$TEST_TMPDIR/out_$n.log" 2>&1 ) &
    done
    wait

    for n in A B C D E; do
        grep -q "1件追記しました" "$TEST_TMPDIR/out_$n.log"
    done

    # 元5件+新規5件=10件が一切失われていないこと(区切り行消失なし)
    [ "$(cmd_ids "$TEST_TARGET")" = "cmd_NA cmd_NB cmd_NC cmd_ND cmd_NE cmd_S1 cmd_S2 cmd_S3 cmd_S4 cmd_S5" ]

    # 妥当なYAMLとして10件パースできること
    "$VENV_PYTHON" - "$TEST_TARGET" <<PY
import yaml
with open("$TEST_TARGET", encoding='utf-8') as f:
    data = yaml.safe_load(f)
assert isinstance(data, list), data
assert len(data) == 10, (len(data), data)
PY

    [ ! -d "$TEST_TMPDIR/queue/.shogun_to_karo.lock.d" ]
}

@test "T-C741-6: update の基本動作(既存フィールド上書き・新規フィールド追加・他エントリ無変更)" {
    make_cmd_doc cmd_U1 U1 "$TEST_TMPDIR/u1.yaml"
    make_cmd_doc cmd_U2 U2 "$TEST_TMPDIR/u2.yaml"
    bash -c "bash '$TEST_SCRIPT' append < '$TEST_TMPDIR/u1.yaml'" >/dev/null
    bash -c "bash '$TEST_SCRIPT' append < '$TEST_TMPDIR/u2.yaml'" >/dev/null

    run bash "$TEST_SCRIPT" update <<'EOF'
- cmd_id: cmd_U1
  status: in_progress
  karo_note: |
    1行目
    2行目
EOF
    [ "$status" -eq 0 ]
    [[ "$output" =~ "1件更新しました" ]]
    [[ "$output" =~ "cmd_U1" ]]

    [ "$(field_value "$TEST_TARGET" cmd_U1 status)" = "'in_progress'" ]
    [ "$(field_value "$TEST_TARGET" cmd_U1 karo_note)" = "'1行目\\n2行目\\n'" ]
    # cmd_id自体はlookup keyであり不変
    [ "$(field_value "$TEST_TARGET" cmd_U1 cmd_id)" = "'cmd_U1'" ]

    # 更新対象外のcmd_U2は生テキストのまま一切変更されていないこと
    assert_file_contains "$TEST_TARGET" "$TEST_TMPDIR/u2.yaml"

    [ "$(cmd_ids "$TEST_TARGET")" = "cmd_U1 cmd_U2" ]
    [ ! -d "$TEST_LOCK_DIR" ]
}

@test "T-C741-7: update の異常系は拒否され、本番ファイルは一切変更されない" {
    make_cmd_doc cmd_U1 U1 "$TEST_TMPDIR/u1.yaml"
    bash -c "bash '$TEST_SCRIPT' append < '$TEST_TMPDIR/u1.yaml'" >/dev/null
    BEFORE="$(cat "$TEST_TARGET")"

    # 対象cmd_idが存在しない
    run bash "$TEST_SCRIPT" update <<'EOF'
- cmd_id: cmd_NOPE
  status: done
EOF
    [ "$status" -eq 2 ]
    [[ "$output" =~ "見つかりません" ]]
    [ "$(cat "$TEST_TARGET")" = "$BEFORE" ]

    # cmd_id以外の更新フィールドが1件も無い
    run bash "$TEST_SCRIPT" update <<'EOF'
- cmd_id: cmd_U1
EOF
    [ "$status" -eq 1 ]
    [[ "$output" =~ "更新対象フィールドがありません" ]]
    [ "$(cat "$TEST_TARGET")" = "$BEFORE" ]

    # 標準入力が空
    run bash -c ": | bash '$TEST_SCRIPT' update"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "標準入力が空です" ]]
    [ "$(cat "$TEST_TARGET")" = "$BEFORE" ]

    # 標準入力内でcmd_idが重複(どちらが有効か曖昧)
    run bash "$TEST_SCRIPT" update <<'EOF'
- cmd_id: cmd_U1
  status: a
- cmd_id: cmd_U1
  status: b
EOF
    [ "$status" -eq 1 ]
    [[ "$output" =~ "重複しています" ]]
    [ "$(cat "$TEST_TARGET")" = "$BEFORE" ]
}

@test "T-C741-8: remove の基本動作(単一削除・複数一括削除・他エントリ無変更)" {
    for n in 1 2 3 4; do
        make_cmd_doc "cmd_R$n" "R$n" "$TEST_TMPDIR/r$n.yaml"
        bash -c "bash '$TEST_SCRIPT' append < '$TEST_TMPDIR/r$n.yaml'" >/dev/null
    done
    [ "$(cmd_ids "$TEST_TARGET")" = "cmd_R1 cmd_R2 cmd_R3 cmd_R4" ]

    run bash "$TEST_SCRIPT" remove cmd_R2
    [ "$status" -eq 0 ]
    [[ "$output" =~ "1件削除しました(cmd_id要素数: 4 → 3)" ]]
    [ "$(cmd_ids "$TEST_TARGET")" = "cmd_R1 cmd_R3 cmd_R4" ]

    # 残存エントリは生テキストのまま無変更
    assert_file_contains "$TEST_TARGET" "$TEST_TMPDIR/r1.yaml"
    assert_file_contains "$TEST_TARGET" "$TEST_TMPDIR/r3.yaml"
    assert_file_contains "$TEST_TARGET" "$TEST_TMPDIR/r4.yaml"

    # 複数件を1回でまとめて削除
    run bash "$TEST_SCRIPT" remove cmd_R1 cmd_R4
    [ "$status" -eq 0 ]
    [[ "$output" =~ "2件削除しました(cmd_id要素数: 3 → 1)" ]]
    [ "$(cmd_ids "$TEST_TARGET")" = "cmd_R3" ]
    assert_file_contains "$TEST_TARGET" "$TEST_TMPDIR/r3.yaml"

    [ ! -d "$TEST_LOCK_DIR" ]
}

@test "T-C741-9: remove の異常系は拒否され、本番ファイルは一切変更されない" {
    make_cmd_doc cmd_R1 R1 "$TEST_TMPDIR/r1.yaml"
    bash -c "bash '$TEST_SCRIPT' append < '$TEST_TMPDIR/r1.yaml'" >/dev/null
    BEFORE="$(cat "$TEST_TARGET")"

    # 対象cmd_idが存在しない
    run bash "$TEST_SCRIPT" remove cmd_NOPE
    [ "$status" -eq 2 ]
    [[ "$output" =~ "見つかりません" ]]
    [ "$(cat "$TEST_TARGET")" = "$BEFORE" ]

    # 引数0件
    run bash "$TEST_SCRIPT" remove
    [ "$status" -eq 1 ]
    [ "$(cat "$TEST_TARGET")" = "$BEFORE" ]

    # 引数内でcmd_idが重複
    run bash "$TEST_SCRIPT" remove cmd_R1 cmd_R1
    [ "$status" -eq 1 ]
    [[ "$output" =~ "重複しています" ]]
    [ "$(cat "$TEST_TARGET")" = "$BEFORE" ]
}

@test "T-C741-10: mapping内重複keyは拒否される (G741-YAML-STRICTNESS-04)" {
    # append: 標準入力側のmapping内重複key
    run bash "$TEST_SCRIPT" append <<'EOF'
- cmd_id: cmd_DUPKEY
  status: pending
  status: done
EOF
    [ "$status" -eq 1 ]
    [[ "$output" =~ "重複キーを検出しました" ]]
    [ ! -e "$TEST_TARGET" ]

    # 正常な1件を種として投入
    make_cmd_doc cmd_OK OK "$TEST_TMPDIR/ok.yaml"
    bash -c "bash '$TEST_SCRIPT' append < '$TEST_TMPDIR/ok.yaml'" >/dev/null
    BEFORE="$(cat "$TEST_TARGET")"

    # update: 標準入力側のmapping内重複key
    run bash "$TEST_SCRIPT" update <<'EOF'
- cmd_id: cmd_OK
  status: a
  status: b
EOF
    [ "$status" -eq 1 ]
    [[ "$output" =~ "重複キーを検出しました" ]]
    [ "$(cat "$TEST_TARGET")" = "$BEFORE" ]

    # 既存ファイル側が(何らかの理由で)重複keyを持つ場合、read時に拒否される
    printf -- '- cmd_id: cmd_BROKEN\n  status: pending\n  status: done\n' > "$TEST_TARGET"
    run bash "$TEST_SCRIPT" update <<'EOF'
- cmd_id: cmd_BROKEN
  status: whatever
EOF
    [ "$status" -eq 2 ]
    [[ "$output" =~ "既存ファイルの解析に失敗" ]]
    [[ "$output" =~ "重複キーを検出しました" ]]
    # 既存ファイルは無傷のまま(バイト単位)
    run cat "$TEST_TARGET"
    [ "$output" = "- cmd_id: cmd_BROKEN
  status: pending
  status: done" ]
}

@test "T-C741-11: 結合/更新後のcmd_id一意性検査 (G741-YAML-STRICTNESS-04)" {
    # append: 標準入力内で異なる要素が同じcmd_idを使う(mapping内重複keyではない)
    run bash "$TEST_SCRIPT" append <<'EOF'
- cmd_id: cmd_DUP
  title: X
- cmd_id: cmd_DUP
  title: Y
EOF
    [ "$status" -eq 1 ]
    [[ "$output" =~ "標準入力内でcmd_idが重複しています" ]]
    [ ! -e "$TEST_TARGET" ]

    # 既存ファイルとcmd_idが重複するappendは拒否される(参照曖昧化の防止)
    make_cmd_doc cmd_EXIST EXIST "$TEST_TMPDIR/exist.yaml"
    bash -c "bash '$TEST_SCRIPT' append < '$TEST_TMPDIR/exist.yaml'" >/dev/null
    BEFORE="$(cat "$TEST_TARGET")"

    run bash "$TEST_SCRIPT" append <<'EOF'
- cmd_id: cmd_EXIST
  title: Duplicate of existing
EOF
    [ "$status" -eq 1 ]
    [[ "$output" =~ "既存ファイルと重複しています" ]]
    [ "$(cat "$TEST_TARGET")" = "$BEFORE" ]

    # PyYAMLの安全側safe_loadなら「before+N件数」チェックだけでは検知できない
    # ケースであることの確認(件数だけ見ればbefore=1+new=1=after=2で一見成立する)
    "$VENV_PYTHON" - <<'PY'
import yaml
data = yaml.safe_load("""
- cmd_id: cmd_EXIST
  title: A
- cmd_id: cmd_EXIST
  title: B
""")
assert len(data) == 2, "safe_loadは重複cmd_idを黙って2件として受理する(本スクリプトは別途一意性検査で拒否する)"
PY
}

@test "T-C741-12: append対updateの並行実行でlost updateが起きない (G741-WRITER-COVERAGE-01)" {
    for n in 1 2 3; do
        make_cmd_doc "cmd_P$n" "P$n" "$TEST_TMPDIR/seed_p$n.yaml"
        bash -c "bash '$TEST_SCRIPT' append < '$TEST_TMPDIR/seed_p$n.yaml'" >/dev/null
    done
    [ "$(cmd_ids "$TEST_TARGET")" = "cmd_P1 cmd_P2 cmd_P3" ]

    for n in 1 2 3; do
        cat > "$TEST_TMPDIR/upd_$n.yaml" <<EOF
- cmd_id: cmd_P$n
  status: updated_$n
EOF
    done
    for n in A B C; do
        make_cmd_doc "cmd_APP$n" "APP$n" "$TEST_TMPDIR/app_$n.yaml"
    done

    for n in 1 2 3; do
        ( bash -c "bash '$TEST_SCRIPT' update < '$TEST_TMPDIR/upd_$n.yaml'" > "$TEST_TMPDIR/upd_out_$n.log" 2>&1 ) &
    done
    for n in A B C; do
        ( bash -c "bash '$TEST_SCRIPT' append < '$TEST_TMPDIR/app_$n.yaml'" > "$TEST_TMPDIR/app_out_$n.log" 2>&1 ) &
    done
    wait

    for n in 1 2 3; do
        grep -q "1件更新しました" "$TEST_TMPDIR/upd_out_$n.log"
    done
    for n in A B C; do
        grep -q "1件追記しました" "$TEST_TMPDIR/app_out_$n.log"
    done

    # 3件のupdateが全て反映されていること(lost update 0)
    for n in 1 2 3; do
        [ "$(field_value "$TEST_TARGET" "cmd_P$n" status)" = "'updated_$n'" ]
    done
    # 3件のappendも全て反映されていること
    [ "$(cmd_ids "$TEST_TARGET")" = "cmd_APPA cmd_APPB cmd_APPC cmd_P1 cmd_P2 cmd_P3" ]

    "$VENV_PYTHON" - "$TEST_TARGET" <<PY
import yaml
with open("$TEST_TARGET", encoding='utf-8') as f:
    data = yaml.safe_load(f)
assert isinstance(data, list) and len(data) == 6, data
PY
    [ ! -d "$TEST_LOCK_DIR" ]
}

@test "T-C741-13: append対active-removalの並行実行でlost updateが起きない (G741-WRITER-COVERAGE-01)" {
    for n in 1 2 3; do
        make_cmd_doc "cmd_Q$n" "Q$n" "$TEST_TMPDIR/seed_q$n.yaml"
        bash -c "bash '$TEST_SCRIPT' append < '$TEST_TMPDIR/seed_q$n.yaml'" >/dev/null
    done
    [ "$(cmd_ids "$TEST_TARGET")" = "cmd_Q1 cmd_Q2 cmd_Q3" ]

    for n in A B C; do
        make_cmd_doc "cmd_RAPP$n" "RAPP$n" "$TEST_TMPDIR/rapp_$n.yaml"
    done

    ( bash "$TEST_SCRIPT" remove cmd_Q2 > "$TEST_TMPDIR/rm_out.log" 2>&1 ) &
    for n in A B C; do
        ( bash -c "bash '$TEST_SCRIPT' append < '$TEST_TMPDIR/rapp_$n.yaml'" > "$TEST_TMPDIR/rapp_out_$n.log" 2>&1 ) &
    done
    wait

    grep -q "1件削除しました" "$TEST_TMPDIR/rm_out.log"
    for n in A B C; do
        grep -q "1件追記しました" "$TEST_TMPDIR/rapp_out_$n.log"
    done

    # cmd_Q2だけが消え、cmd_Q1/cmd_Q3とappend分3件が過不足なく残ること
    [ "$(cmd_ids "$TEST_TARGET")" = "cmd_Q1 cmd_Q3 cmd_RAPPA cmd_RAPPB cmd_RAPPC" ]

    "$VENV_PYTHON" - "$TEST_TARGET" <<PY
import yaml
with open("$TEST_TARGET", encoding='utf-8') as f:
    data = yaml.safe_load(f)
assert isinstance(data, list) and len(data) == 5, data
PY
    [ ! -d "$TEST_LOCK_DIR" ]
}

@test "T-C741-14: 外部保持者がLOCK_DIRを握っている間にscriptがtimeoutしても保持者のdirを消さない (G741-LOCK-OWNERSHIP-03)" {
    # G741-R1-TEST-HOOK-05: 個別チューニング変数はSHOGUN_TO_KARO_LOCK_TEST_MODE=1が
    # 無い限り黙殺されるため、本testでも明示的に設定する。
    export SHOGUN_TO_KARO_LOCK_TEST_MODE=1
    export SHOGUN_TO_KARO_LOCK_MKDIR_ITERS=3
    export SHOGUN_TO_KARO_LOCK_MAX_ATTEMPTS=1
    export SHOGUN_TO_KARO_LOCK_RETRY_SLEEP=0.1

    # 外部保持者を模す: 本スクリプトと同じmkdir方式のLOCK_DIRを握って保持する
    ( mkdir "$TEST_LOCK_DIR"; sleep 2; rmdir "$TEST_LOCK_DIR" ) &
    HOLDER_PID=$!
    sleep 0.2   # 外部保持者がmkdirを終えるのを待つ

    make_cmd_doc cmd_TIMEOUT TIMEOUT "$TEST_TMPDIR/timeout.yaml"
    run bash -c "bash '$TEST_SCRIPT' append < '$TEST_TMPDIR/timeout.yaml'"
    [ "$status" -eq 4 ]

    [ -d "$TEST_LOCK_DIR" ]     # 外部保持者のLOCK_DIRがまだ存在する(loserに消されていない)
    [ ! -e "$TEST_TARGET" ]    # targetファイルはloserにより作成されていない

    wait "$HOLDER_PID"
    [ ! -d "$TEST_LOCK_DIR" ]   # 外部保持者の解放後は正しく消えている
}

@test "T-C741-15: 先行process手動解放後の遅延trapが後続所有のLOCK_DIRを消さない (G741-LOCK-OWNERSHIP-03)" {
    make_cmd_doc cmd_HANDOFF HANDOFF "$TEST_TMPDIR/handoff.yaml"

    # Aは手動解放後、実際のexitまでに人工的な遅延を挟む(通常運用では常に0=無効)。
    # G741-R1-TEST-HOOK-05: SHOGUN_TO_KARO_LOCK_TEST_MODE=1も併せて設定しない限り
    # このフック自体が黙殺される。
    SHOGUN_TO_KARO_LOCK_TEST_MODE=1 SHOGUN_TO_KARO_LOCK_TEST_DELAY_BEFORE_EXIT=2 \
        bash "$TEST_SCRIPT" append \
        < "$TEST_TMPDIR/handoff.yaml" > "$TEST_TMPDIR/a_out.log" 2>&1 &
    A_PID=$!

    sleep 0.5   # Aがacquire→python実行→手動releaseを終え、2s delay中であることを待つ
    [ ! -d "$TEST_LOCK_DIR" ]   # Aは既に手動解放済み(LOCK_DIR消滅)であること

    # 後続(このテスト自身)が新規にLOCK_DIRを取得する(Aの遅延trapより先に取得できることの確認)
    mkdir "$TEST_LOCK_DIR"

    wait "$A_PID"
    [ "$?" -eq 0 ]
    grep -q "1件追記しました" "$TEST_TMPDIR/a_out.log"

    # Aの遅延trap発火後も、後続所有のLOCK_DIRが残っていること
    [ -d "$TEST_LOCK_DIR" ]

    rmdir "$TEST_LOCK_DIR"
}

@test "T-C741-16: quoted heredoc(<<'EOF')がliteral \$VAR/\${...}/バッククォート/\$()をbyte-for-byteで保存する (G741-R1-HEREDOC-01)" {
    # 隔離実測(軍師QC)で「非引用<<EOFはshellがcmd本文を展開してから渡す」
    # ことが確認された。本testは、公式手順どおりquoted <<'EOF'を使えば
    # シェル展開の対象となり得る4種(\$VAR・\${...}・バッククォート・\$())が
    # 一切展開されず、書込み後もliteralなまま保存されることを示す。
    export SHOULD_NOT_EXPAND="qwerty12345"
    run bash "$TEST_SCRIPT" append <<'EOF'
- cmd_id: cmd_LITERAL
  command: |
    echo $SHOULD_NOT_EXPAND and ${SHOULD_NOT_EXPAND} and `echo nope` and $(echo nope2)
EOF
    [ "$status" -eq 0 ]
    [[ "$output" =~ "1件追記しました(cmd_id要素数: 0 → 1)" ]]

    # (a) 生テキストへ、展開されていないliteralな\$VARがそのまま含まれること
    raw_content="$(cat "$TEST_TARGET")"
    [[ "$raw_content" == *'echo $SHOULD_NOT_EXPAND and ${SHOULD_NOT_EXPAND} and `echo nope` and $(echo nope2)'* ]]
    # 展開されていれば紛れ込むはずの値(\$VARの展開結果そのもの)が
    # 含まれていないこと。("nope"は`echo nope`のliteralテキスト自体に
    # 正しく含まれるため、ここでは検査しない — 上記(a)の完全一致で
    # バッククォート/\$()の非展開は既に立証済み)
    [[ "$raw_content" != *"qwerty12345"* ]]

    # (b) YAMLとして再パースしたcommandフィールドの値もbyte-for-byteで一致すること
    "$VENV_PYTHON" - "$TEST_TARGET" <<'PY'
import sys
import yaml
path = sys.argv[1]
with open(path, encoding='utf-8') as f:
    data = yaml.safe_load(f)
expected = 'echo $SHOULD_NOT_EXPAND and ${SHOULD_NOT_EXPAND} and `echo nope` and $(echo nope2)\n'
actual = data[0]['command']
assert actual == expected, (actual, expected)
PY
}

@test "T-C741-17: append実行後も既存targetのmodeが保持される (G741-R1-MODE-02)" {
    make_cmd_doc cmd_M1 M1 "$TEST_TMPDIR/m1.yaml"
    bash -c "bash '$TEST_SCRIPT' append < '$TEST_TMPDIR/m1.yaml'" >/dev/null
    chmod 0640 "$TEST_TARGET"
    [ "$(stat -c '%a' "$TEST_TARGET")" = "640" ]

    make_cmd_doc cmd_M2 M2 "$TEST_TMPDIR/m2.yaml"
    run bash -c "bash '$TEST_SCRIPT' append < '$TEST_TMPDIR/m2.yaml'"
    [ "$status" -eq 0 ]
    [ "$(stat -c '%a' "$TEST_TARGET")" = "640" ]
}

@test "T-C741-18: update実行後も既存targetのmodeが保持される (G741-R1-MODE-02)" {
    make_cmd_doc cmd_M1 M1 "$TEST_TMPDIR/m1.yaml"
    bash -c "bash '$TEST_SCRIPT' append < '$TEST_TMPDIR/m1.yaml'" >/dev/null
    chmod 0640 "$TEST_TARGET"

    run bash "$TEST_SCRIPT" update <<'EOF'
- cmd_id: cmd_M1
  status: in_progress
EOF
    [ "$status" -eq 0 ]
    [ "$(stat -c '%a' "$TEST_TARGET")" = "640" ]
}

@test "T-C741-19: remove実行後も既存targetのmodeが保持される (G741-R1-MODE-02)" {
    make_cmd_doc cmd_M1 M1 "$TEST_TMPDIR/m1.yaml"
    make_cmd_doc cmd_M2 M2 "$TEST_TMPDIR/m2.yaml"
    bash -c "bash '$TEST_SCRIPT' append < '$TEST_TMPDIR/m1.yaml'" >/dev/null
    bash -c "bash '$TEST_SCRIPT' append < '$TEST_TMPDIR/m2.yaml'" >/dev/null
    chmod 0640 "$TEST_TARGET"

    run bash "$TEST_SCRIPT" remove cmd_M1
    [ "$status" -eq 0 ]
    [ "$(stat -c '%a' "$TEST_TARGET")" = "640" ]
}

@test "T-C741-20: SHOGUN_TO_KARO_LOCK_TEST_MODE未設定なら個別チューニング変数の残留値は無視され既定値が使われる (G741-R1-TEST-HOOK-05)" {
    # 「前回のtest実行等でチューニング変数が呼び出し元シェルに残留している」
    # 状況を模す。SHOGUN_TO_KARO_LOCK_TEST_MODEを設定しない限りこれらは
    # 黙殺され、既定値(MKDIR_ITERS=50=5秒上限×MAX_ATTEMPTS=3試行)が使われる
    # ことを、既定よりはるかに短い値(黙殺されなければ即timeoutする値)を
    # わざと残留させて確認する。
    export SHOGUN_TO_KARO_LOCK_MKDIR_ITERS=1
    export SHOGUN_TO_KARO_LOCK_MAX_ATTEMPTS=1
    export SHOGUN_TO_KARO_LOCK_RETRY_SLEEP=0

    # 外部保持者を1秒だけLOCK_DIRを握らせる
    ( mkdir "$TEST_LOCK_DIR"; sleep 1; rmdir "$TEST_LOCK_DIR" ) &
    HOLDER_PID=$!
    sleep 0.2   # 外部保持者がmkdirを終えるのを待つ

    make_cmd_doc cmd_HARDEN HARDEN "$TEST_TMPDIR/harden.yaml"
    run bash -c "bash '$TEST_SCRIPT' append < '$TEST_TMPDIR/harden.yaml'"
    # 残留env varが黙殺されず有効化されていれば、MKDIR_ITERS=1(0.1秒)×
    # MAX_ATTEMPTS=1で即timeout(status 4)するはず。既定値が使われれば
    # 保持者解放(1秒後)を待って成功する。
    [ "$status" -eq 0 ]
    [ "$(cmd_ids "$TEST_TARGET")" = "cmd_HARDEN" ]

    wait "$HOLDER_PID"
}
