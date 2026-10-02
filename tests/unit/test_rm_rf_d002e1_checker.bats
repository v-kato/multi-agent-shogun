#!/usr/bin/env bats
# test_rm_rf_d002e1_checker.bats — scripts/rm_rf_d002e1_checker.py の
# 単体テスト (cmd_753・scope変更版=closed grammar化)。
#
# ★ライブリポジトリの実データには依存しない。合成fixtureを都度
# mktemp -d配下に作り、D002-E1の四条件に照らした既知の PASS/
# FORMAT_ONLY/DANGER/EXCLUDED_FP パターンを固定検証する。ライブ
# リポジトリを --root にした網羅走査結果は、完了報告に別途
# 再現コマンドとして記載する(bats固定テストとしては組み込まない
# ——理由は完了報告のA-4節を参照)。
#
# ★scope変更(closed grammar化)による構成変更:
# 旧テスト(redo1: notmktemp/chained ;・&&、redo2: bg &・redirect
# >/1>/>&)のうち、mktemp呼出し自体をcompound化するパターン
# (chained ;・&&・bg &・redirect >/1>/>&)は、将軍裁定(cmd_753
# scope変更 B-2)により「危険と断定しない。判定不能ゆえ不許可」と
# 扱う方針へ変わったため、期待値をDANGERからFORMAT_ONLYへ更新した。
# 個別optionを1つずつ潰す形の試験はもう不要(B-5)なので、これらは
# 1つの consolidated test (closed grammar外の形が軒並み不許可になる
# ことを示す試験)へ統合した。notmktemp(非mktemp再代入と同じ「起源が
# mktempでない」問題であり、compound化とは別カテゴリ)は従来どおり
# DANGERのまま個別に残す。

setup() {
    TEST_TMP="$(mktemp -d)"
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    CHECKER="$PROJECT_ROOT/scripts/rm_rf_d002e1_checker.py"
}

teardown() {
    rm -rf -- "${TEST_TMP:?}"
}

@test "rm_rf_d002e1_checker: 絶対リテラルテンプレート由来かつ正しい綴りは PASS(B-1(ii))" {
    mkdir -p "$TEST_TMP/repo"
    cat > "$TEST_TMP/repo/ok.sh" <<'EOF'
#!/usr/bin/env bash
VAR=$(mktemp -d /tmp/foo.XXXXXX)
rm -rf "$VAR"
EOF
    run python3 "$CHECKER" --root "$TEST_TMP/repo"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS           1"* ]]
    [[ "$output" == *"DANGER         0"* ]]
}

@test "rm_rf_d002e1_checker: -p 絶対リテラル親由来(templateなし)かつ正しい綴りは PASS(B-1(iii))" {
    mkdir -p "$TEST_TMP/repo"
    cat > "$TEST_TMP/repo/parent_p.sh" <<'EOF'
#!/usr/bin/env bash
VAR=$(mktemp -d -p /tmp)
rm -rf "$VAR"
EOF
    run python3 "$CHECKER" --root "$TEST_TMP/repo"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS           1"* ]]
    [[ "$output" == *"DANGER         0"* ]]
}

@test "rm_rf_d002e1_checker: --tmpdir=絶対リテラル親由来かつtemplateなしは PASS(B-1(iii))" {
    mkdir -p "$TEST_TMP/repo"
    cat > "$TEST_TMP/repo/parent_eq.sh" <<'EOF'
#!/usr/bin/env bash
VAR=$(mktemp -d --tmpdir=/tmp)
rm -rf "$VAR"
EOF
    run python3 "$CHECKER" --root "$TEST_TMP/repo"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS           1"* ]]
    [[ "$output" == *"DANGER         0"* ]]
}

@test "rm_rf_d002e1_checker: テンプレート無しmktempはTMPDIR依存でFORMAT_ONLY(PASSにしない・B-1(i)/B-4)" {
    mkdir -p "$TEST_TMP/repo"
    cat > "$TEST_TMP/repo/cond.sh" <<'EOF'
#!/usr/bin/env bash
VAR=$(mktemp -d)
rm -rf "$VAR"
EOF
    run python3 "$CHECKER" --root "$TEST_TMP/repo"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS           0"* ]]
    [[ "$output" == *"FORMAT_ONLY    1"* ]]
}

@test "rm_rf_d002e1_checker: \$BATS_TMPDIR起点templateはTMPDIR依存でFORMAT_ONLY(PASSにしない・B-4)" {
    mkdir -p "$TEST_TMP/repo"
    cat > "$TEST_TMP/repo/batstmpdir.bats" <<'EOF'
setup() {
    VAR="$(mktemp -d "$BATS_TMPDIR/fixture.XXXXXX")"
}
teardown() {
    rm -rf "$VAR"
}
EOF
    run python3 "$CHECKER" --root "$TEST_TMP/repo"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS           0"* ]]
    [[ "$output" == *"FORMAT_ONLY    1"* ]]
}

@test "rm_rf_d002e1_checker: 絶対テンプレート由来だが未クォートはFORMAT_ONLY" {
    mkdir -p "$TEST_TMP/repo"
    cat > "$TEST_TMP/repo/unquoted.sh" <<'EOF'
#!/usr/bin/env bash
VAR=$(mktemp -d /tmp/foo.XXXXXX)
rm -rf $VAR
EOF
    run python3 "$CHECKER" --root "$TEST_TMP/repo"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS           0"* ]]
    [[ "$output" == *"FORMAT_ONLY    1"* ]]
}

@test "rm_rf_d002e1_checker: './'相対パス直書きはFORMAT_ONLY止まり(D002-E1未認証・CWD/symlink未証明・要人手確認・shutsujin_departure.sh型・cmd_753完了処理redo1でINELIGIBLE_IN_TREEから是正)" {
    mkdir -p "$TEST_TMP/repo"
    cat > "$TEST_TMP/repo/literal.sh" <<'EOF'
#!/usr/bin/env bash
rm -rf ./queue/inbox
EOF
    run python3 "$CHECKER" --root "$TEST_TMP/repo"
    [ "$status" -eq 0 ]
    [[ "$output" == *"DANGER         0"* ]]
    [[ "$output" == *"FORMAT_ONLY    1"* ]]
    [[ "$output" == *"CWD/symlink未証明"* ]]
}

@test "rm_rf_d002e1_checker: 絶対パスのリテラル直書きは引き続きDANGER(作業木外の恐れがあり'./'相対パスとは区別する)" {
    mkdir -p "$TEST_TMP/repo"
    cat > "$TEST_TMP/repo/literal_abs.sh" <<'EOF'
#!/usr/bin/env bash
rm -rf /some/literal/path
EOF
    run python3 "$CHECKER" --root "$TEST_TMP/repo"
    [ "$status" -eq 1 ]
    [[ "$output" == *"DANGER         1"* ]]
    [[ "$output" == *"FORMAT_ONLY    0"* ]]
}

@test "rm_rf_d002e1_checker: './'相対パスでも'..'を含めばFORMAT_ONLYにせずDANGERのまま(escapeの恐れ)" {
    mkdir -p "$TEST_TMP/repo"
    cat > "$TEST_TMP/repo/literal_dotdot.sh" <<'EOF'
#!/usr/bin/env bash
rm -rf ./queue/../../etc
EOF
    run python3 "$CHECKER" --root "$TEST_TMP/repo"
    [ "$status" -eq 1 ]
    [[ "$output" == *"DANGER         1"* ]]
    [[ "$output" == *"FORMAT_ONLY    0"* ]]
}

@test "rm_rf_d002e1_checker: cd後の'./'相対パスもFORMAT_ONLY止まりで安全断定しない(実行時CWD変化を追跡しない・G753-INELIGIBLE-CWD-SYMLINK-FALSESAFE-01反例1・cmd_753完了処理redo1)" {
    mkdir -p "$TEST_TMP/repo"
    cat > "$TEST_TMP/repo/cd_then_rm.sh" <<'EOF'
#!/usr/bin/env bash
cd /some/other/dir
rm -rf ./victim
EOF
    run python3 "$CHECKER" --root "$TEST_TMP/repo"
    [ "$status" -eq 0 ]
    [[ "$output" == *"DANGER         0"* ]]
    [[ "$output" == *"FORMAT_ONLY    1"* ]]
    [[ "$output" == *"CWD/symlink未証明"* ]]
}

@test "rm_rf_d002e1_checker: 中間symlinkを経由しうる'./link/child'形もFORMAT_ONLY止まりで安全断定しない(G753-INELIGIBLE-CWD-SYMLINK-FALSESAFE-01反例2・cmd_753完了処理redo1)" {
    mkdir -p "$TEST_TMP/repo"
    cat > "$TEST_TMP/repo/via_link.sh" <<'EOF'
#!/usr/bin/env bash
rm -rf ./link/victim
EOF
    run python3 "$CHECKER" --root "$TEST_TMP/repo"
    [ "$status" -eq 0 ]
    [[ "$output" == *"DANGER         0"* ]]
    [[ "$output" == *"FORMAT_ONLY    1"* ]]
    [[ "$output" == *"CWD/symlink未証明"* ]]
}

@test "rm_rf_d002e1_checker: 同一ファイル内に代入が無い変数はDANGER(起源不明)" {
    mkdir -p "$TEST_TMP/repo"
    cat > "$TEST_TMP/repo/noorigin.sh" <<'EOF'
#!/usr/bin/env bash
rm -rf "$UNDEFINED_VAR"
EOF
    run python3 "$CHECKER" --root "$TEST_TMP/repo"
    [ "$status" -eq 1 ]
    [[ "$output" == *"DANGER         1"* ]]
}

@test "rm_rf_d002e1_checker: mktemp捕捉後の再代入(非mktemp)はDANGER" {
    mkdir -p "$TEST_TMP/repo"
    cat > "$TEST_TMP/repo/reassigned.sh" <<'EOF'
#!/usr/bin/env bash
VAR=$(mktemp -d /tmp/foo.XXXXXX)
VAR="/etc"
rm -rf "$VAR"
EOF
    run python3 "$CHECKER" --root "$TEST_TMP/repo"
    [ "$status" -eq 1 ]
    [[ "$output" == *"DANGER         1"* ]]
}

@test "rm_rf_d002e1_checker: mktemp捕捉前の空初期化はDANGERにしない(bats setup/teardown慣用句)" {
    mkdir -p "$TEST_TMP/repo"
    cat > "$TEST_TMP/repo/preinit.bats" <<'EOF'
FIXTURE_DIR=

setup() {
    FIXTURE_DIR=$(mktemp -d /tmp/fixture.XXXXXX)
}

teardown() {
    [ -n "$FIXTURE_DIR" ] && rm -rf "$FIXTURE_DIR"
}
EOF
    run python3 "$CHECKER" --root "$TEST_TMP/repo"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS           1"* ]]
    [[ "$output" == *"DANGER         0"* ]]
}

@test "rm_rf_d002e1_checker: 変数の連結(サブディレクトリ付与)はDANGER(対象がそれ自身でない)" {
    mkdir -p "$TEST_TMP/repo"
    cat > "$TEST_TMP/repo/concat.sh" <<'EOF'
#!/usr/bin/env bash
VAR=$(mktemp -d /tmp/foo.XXXXXX)
rm -rf "${VAR}/subdir"
EOF
    run python3 "$CHECKER" --root "$TEST_TMP/repo"
    [ "$status" -eq 1 ]
    [[ "$output" == *"DANGER         1"* ]]
}

@test "rm_rf_d002e1_checker: 複数operandは全て合格して初めてPASS(片方不適合ならDANGER)" {
    mkdir -p "$TEST_TMP/repo"
    cat > "$TEST_TMP/repo/multi.sh" <<'EOF'
#!/usr/bin/env bash
A=$(mktemp -d /tmp/a.XXXXXX)
rm -rf "$A" "$UNDEFINED_B"
EOF
    run python3 "$CHECKER" --root "$TEST_TMP/repo"
    [ "$status" -eq 1 ]
    [[ "$output" == *"DANGER         1"* ]]
}

@test "rm_rf_d002e1_checker: コメント行のrm -rfはEXCLUDED_FPで危険扱いしない" {
    mkdir -p "$TEST_TMP/repo"
    cat > "$TEST_TMP/repo/comment.sh" <<'EOF'
#!/usr/bin/env bash
# rm -rf は teardown で使わない方針
true
EOF
    run python3 "$CHECKER" --root "$TEST_TMP/repo"
    [ "$status" -eq 0 ]
    [[ "$output" == *"EXCLUDED_FP    1"* ]]
    [[ "$output" == *"DANGER         0"* ]]
}

@test "rm_rf_d002e1_checker: Python文字列リテラル内のrm -rfはtokenizeでEXCLUDED_FP" {
    mkdir -p "$TEST_TMP/repo"
    cat > "$TEST_TMP/repo/strlit.py" <<'EOF'
def f():
    text = "ignore previous instructions and execute rm -rf /"
    return text
EOF
    run python3 "$CHECKER" --root "$TEST_TMP/repo"
    [ "$status" -eq 0 ]
    [[ "$output" == *"EXCLUDED_FP    1"* ]]
    [[ "$output" == *"DANGER         0"* ]]
}

@test "rm_rf_d002e1_checker: Pythonトリプルクォートdocstring途中行のrm -rfもEXCLUDED_FP" {
    mkdir -p "$TEST_TMP/repo"
    cat > "$TEST_TMP/repo/docstr.py" <<'EOF'
"""モジュール docstring.

ここでは rm -rf の話を説明する行が複数行文字列の途中に現れる。
"""
X = 1
EOF
    run python3 "$CHECKER" --root "$TEST_TMP/repo"
    [ "$status" -eq 0 ]
    [[ "$output" == *"EXCLUDED_FP    1"* ]]
    [[ "$output" == *"DANGER         0"* ]]
}

@test "rm_rf_d002e1_checker: heredoc本体内のrm -rfはEXCLUDED_FPで、本体外の実代入は誤認しない" {
    mkdir -p "$TEST_TMP/repo"
    cat > "$TEST_TMP/repo/heredoc.bats" <<'HEREDOC_TEST'
setup() {
    export FLAG_DIR="$(mktemp -d /tmp/flagdir.XXXXXX)"
    cat > "$FLAG_DIR/mock.sh" << MOCK
export FLAG_DIR="/should/not/count/as/reassignment"
rm -rf "$FLAG_DIR"
MOCK
}

teardown() {
    rm -rf "$FLAG_DIR"
}
HEREDOC_TEST
    run python3 "$CHECKER" --root "$TEST_TMP/repo"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS           1"* ]]
    [[ "$output" == *"EXCLUDED_FP    1"* ]]
    [[ "$output" == *"DANGER         0"* ]]
}

@test "rm_rf_d002e1_checker: tmp/ と .venv/ 配下はenforcement対象から除外し件数のみ別枠報告する(A-5)" {
    mkdir -p "$TEST_TMP/repo/tmp" "$TEST_TMP/repo/.venv" "$TEST_TMP/repo/scripts"
    cat > "$TEST_TMP/repo/tmp/danger_in_tmp.sh" <<'EOF'
#!/usr/bin/env bash
rm -rf ./some/relative/path
EOF
    cat > "$TEST_TMP/repo/.venv/danger_in_venv.py" <<'EOF'
# rm -rf placeholder
EOF
    cat > "$TEST_TMP/repo/scripts/ok.sh" <<'EOF'
#!/usr/bin/env bash
VAR=$(mktemp -d /tmp/foo.XXXXXX)
rm -rf "$VAR"
EOF
    run python3 "$CHECKER" --root "$TEST_TMP/repo"
    [ "$status" -eq 0 ]
    [[ "$output" == *"走査対象ファイル数(enforcement対象): 1"* ]]
    [[ "$output" == *".venv"*"1"* ]]
    [[ "$output" == *"tmp"*"1"* ]]
    [[ "$output" == *"DANGER         0"* ]]
}

@test "rm_rf_d002e1_checker: allowlist候補はPASS由来のリテラルコマンド文字列を重複排除して出す" {
    mkdir -p "$TEST_TMP/repo"
    cat > "$TEST_TMP/repo/a.sh" <<'EOF'
#!/usr/bin/env bash
VAR=$(mktemp -d /tmp/foo.XXXXXX)
rm -rf "$VAR"
EOF
    cat > "$TEST_TMP/repo/b.sh" <<'EOF'
#!/usr/bin/env bash
VAR=$(mktemp -d /tmp/bar.XXXXXX)
rm -rf "$VAR"
EOF
    run python3 "$CHECKER" --root "$TEST_TMP/repo" --allowlist-out "$TEST_TMP/allow.txt"
    [ "$status" -eq 0 ]
    run cat "$TEST_TMP/allow.txt"
    [ "$status" -eq 0 ]
    [ "$output" = 'rm -rf "$VAR"' ]
}

@test "rm_rf_d002e1_checker: --json は全hit詳細を出力しoperand判定根拠を含む" {
    mkdir -p "$TEST_TMP/repo"
    cat > "$TEST_TMP/repo/a.sh" <<'EOF'
#!/usr/bin/env bash
VAR=$(mktemp -d /tmp/foo.XXXXXX)
rm -rf "$VAR"
EOF
    run python3 "$CHECKER" --root "$TEST_TMP/repo" --json "$TEST_TMP/report.json"
    [ "$status" -eq 0 ]
    run python3 -c "import json,sys; d=json.load(open(sys.argv[1])); h=d['hits'][0]; print(h['tag']); print(h['operands'][0]['kind'])" "$TEST_TMP/report.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS"* ]]
    [[ "$output" == *"ABS-CONSTRUCT"* ]]
}

# --- redo1由来(継続。notmktempは「起源がmktempでない」問題であり、
# closed grammar化後もDANGERのまま) ---

@test "rm_rf_d002e1_checker: CRLF heredocの終端はCRを無視して正しく検出し、直後の実rm -rfをEXCLUDED_FPにしない(G753-FAILCLOSED-CRLF-01)" {
    mkdir -p "$TEST_TMP/repo"
    # ★注意: 本ファイル自身も検査対象(tests/*.bats)である。printf
    # フォーマット文字列やコメント中に山括弧2つ+識別子(heredoc開始
    # 記法そのもの)を直書きすると、検査器のheredoc開始検出(字句一致・
    # 限界2b、コメント判定なし)がこの行自体を誤認し、以降のファイル
    # 走査(自己参照)が乱れる。生成物(fixture)側だけにその記法を
    # 出現させるため、演算子を変数経由で組み立てる。
    lt='<'
    heredoc_op="${lt}${lt}"
    printf 'VAR=$(mktemp -d /tmp/foo.XXXXXX)\r\ncat > "$OUT" %sYAML\r\nkey: value\r\nYAML\r\nrm -rf "$VAR"\r\n' \
        "$heredoc_op" > "$TEST_TMP/repo/crlf.sh"
    run python3 "$CHECKER" --root "$TEST_TMP/repo"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS           1"* ]]
    [[ "$output" == *"EXCLUDED_FP    0"* ]]
    [[ "$output" == *"DANGER         0"* ]]
}

@test "rm_rf_d002e1_checker: 未終端heredocは後続を黙って除外せず、判定不能をfail-closedでDANGER相当として報告する" {
    mkdir -p "$TEST_TMP/repo"
    cat > "$TEST_TMP/repo/unterminated.sh" <<'EOF'
#!/usr/bin/env bash
cat > "$OUT" <<YAML
key: value
rm -rf ./queue/inbox
EOF
    run python3 "$CHECKER" --root "$TEST_TMP/repo"
    [ "$status" -eq 1 ]
    [[ "$output" == *"未終端heredoc検出"* ]]
    [[ "$output" == *"DANGER         1"* ]]
}

@test "rm_rf_d002e1_checker: 実ファイル回帰——CRLF既知ファイル群のteardown rm -rfがEXCLUDED_FPに落ちない(G753-FAILCLOSED-CRLF-01実例)" {
    run python3 "$CHECKER" --root "$PROJECT_ROOT" --json "$TEST_TMP/live.json"
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
    # ★対象行は行番号で固定しない(cmd_787。対象batsへ無関係な行が入る
    # たびに行番号が外れ、判定を触らず数字だけ直す作業が生じたため)。
    # 判定順序は「file/raw抽出 → 件数ちょうど1 → tagの存在 →
    # tag != EXCLUDED_FP」。候補はtagで絞らずリストのまま保持し、先に件数を
    # 確かめる(0件=コメントアウト・複数件=複製・誤除外された実行行も候補に
    # 残るので、EXCLUDED_FPへ落ちた場合はtag検査で必ず捕まる)。
    # 禁止: any()・件数確認なしのall()・空集合のfor・最初の一致だけ採用・
    # 辞書化/集合化で複数hitを潰す書き方・tagで候補を先に絞る書き方。
    # 対象は4ファイルの既知の独立した後始末コマンド(行頭が後始末コマンド)の
    # 形のみ。guard付き等へ意図して変えた場合は候補0件でFAILする(fail-closed)。
    run python3 -c "
import json, re, sys
d = json.load(open(sys.argv[1]))
hits = d['hits']
assert isinstance(hits, list) and hits, 'JSON has no hits'
targets = [
    'tests/unit/test_dynamic_model_routing.bats',
    'tests/unit/test_idle_flag.bats',
    'tests/unit/test_ntfy_ack.bats',
    'tests/unit/test_switch_cli.bats',
]
assert len(targets) == 4, 'target list changed: %d' % len(targets)
command_head = re.compile(r'^\s*rm\s+-rf(?:\s|\Z)')
for target in targets:
    candidates = [h for h in hits if h['file'] == target and command_head.match(h['raw'])]
    assert len(candidates) == 1, '%s: expected exactly 1 candidate, got %d: %r' % (target, len(candidates), candidates)
    hit = candidates[0]
    tag = hit['tag']
    assert tag, '%s: tag missing: %r' % (target, hit)
    assert tag != 'EXCLUDED_FP', '%s: still EXCLUDED_FP: %r' % (target, hit)
    print('%s line=%d tag=%s' % (target, hit['line'], tag))
print('checked=%d' % len(targets))
" "$TEST_TMP/live.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"tests/unit/test_dynamic_model_routing.bats line="*" tag="* ]]
    [[ "$output" == *"tests/unit/test_idle_flag.bats line="*" tag="* ]]
    [[ "$output" == *"tests/unit/test_ntfy_ack.bats line="*" tag="* ]]
    [[ "$output" == *"tests/unit/test_switch_cli.bats line="*" tag="* ]]
    [[ "$output" == *"checked=4"* ]]
}

@test "rm_rf_d002e1_checker: notmktemp呼出しは部分文字列一致でPASSにしない(起源がmktempでない=DANGER)" {
    mkdir -p "$TEST_TMP/repo"
    cat > "$TEST_TMP/repo/notmktemp.sh" <<'EOF'
#!/usr/bin/env bash
V=$(notmktemp -d /tmp/owned.XXXXXX)
rm -rf "$V"
EOF
    run python3 "$CHECKER" --root "$TEST_TMP/repo"
    [ "$status" -eq 1 ]
    [[ "$output" == *"PASS           0"* ]]
    [[ "$output" == *"DANGER         1"* ]]
}

@test "rm_rf_d002e1_checker: 未終端heredoc内に正当なmktemp代入+rm -rfを置いてもPASS0・allow候補0(G753-UNTERMINATED-ALLOW-REDO1-02)" {
    mkdir -p "$TEST_TMP/repo"
    cat > "$TEST_TMP/repo/unterminated_fakepass.sh" <<'EOF'
#!/usr/bin/env bash
V=$(mktemp -d /tmp/owned.XXXXXX)
cat > "$OUT" <<YAML
key: value
rm -rf "$V"
EOF
    run python3 "$CHECKER" --root "$TEST_TMP/repo"
    [ "$status" -eq 1 ]
    [[ "$output" == *"未終端heredoc検出"* ]]
    [[ "$output" == *"PASS           0"* ]]
    run python3 "$CHECKER" --root "$TEST_TMP/repo" --allowlist-out "$TEST_TMP/allow_ut.txt"
    run cat "$TEST_TMP/allow_ut.txt"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- scope変更(closed grammar化・cmd_753)本体の試験 ---
# B-5: 「閉じた文法の外にある形が全て不許可になること」を示す。
# 個別optionを1つずつ潰す形の試験はもう不要——1つのconsolidated test
# へ統合する(旧redo1/redo2の;・&&・&・>・1>・>&試験を置き換え)。

@test "rm_rf_d002e1_checker: closed grammar外の呼出し形は軒並みFORMAT_ONLY(判定不能ゆえ不許可・危険と断定しない・B-2/B-5)" {
    mkdir -p "$TEST_TMP/repo"
    # 1) mktempにcompound command連結(;)
    cat > "$TEST_TMP/repo/chained.sh" <<'EOF'
#!/usr/bin/env bash
V=$(mktemp -d /tmp/owned.XXXXXX; printf /etc)
rm -rf "$V"
EOF
    # 2) mktempにcompound command連結(&&)
    cat > "$TEST_TMP/repo/chained_and.sh" <<'EOF'
#!/usr/bin/env bash
V=$(mktemp -d /tmp/owned.XXXXXX && printf /etc)
rm -rf "$V"
EOF
    # 3) mktemp末尾の単一&(バックグラウンド)
    cat > "$TEST_TMP/repo/bg_amp.sh" <<'EOF'
#!/usr/bin/env bash
V=$(mktemp -d /tmp/owned.XXXXXX & printf /etc)
rm -rf "$V"
EOF
    # 4) mktemp末尾の標準出力redirect(>)
    cat > "$TEST_TMP/repo/redirect_gt.sh" <<'EOF'
#!/usr/bin/env bash
V=$(mktemp -d /tmp/owned.XXXXXX > /tmp/path)
rm -rf "$V"
EOF
    # 5) mktemp末尾のfd明示redirect(1>)
    cat > "$TEST_TMP/repo/redirect_fd1.sh" <<'EOF'
#!/usr/bin/env bash
V=$(mktemp -d /tmp/owned.XXXXXX 1>/tmp/path)
rm -rf "$V"
EOF
    # 6) mktempに>&系redirect
    cat > "$TEST_TMP/repo/redirect_ampgt.sh" <<'EOF'
#!/usr/bin/env bash
V=$(mktemp -d /tmp/owned.XXXXXX >&/tmp/path)
rm -rf "$V"
EOF
    # 7) -t PREFIX形式(実在しないため受理集合に含めない)
    cat > "$TEST_TMP/repo/tform.sh" <<'EOF'
#!/usr/bin/env bash
V=$(mktemp -d -t owned.XXXXXX)
rm -rf "$V"
EOF
    # 8) 非作成option(-u)。closed grammarでは受理集合に入らない
    cat > "$TEST_TMP/repo/dryrun.sh" <<'EOF'
#!/usr/bin/env bash
V=$(mktemp -d -u)
rm -rf "$V"
EOF
    # 9) 相対テンプレート直書き
    cat > "$TEST_TMP/repo/reltemplate.sh" <<'EOF'
#!/usr/bin/env bash
V=$(mktemp -d foo.XXXXXX)
rm -rf "$V"
EOF
    # 10) -p 相対親
    cat > "$TEST_TMP/repo/relparent.sh" <<'EOF'
#!/usr/bin/env bash
V=$(mktemp -d -p some/dir)
rm -rf "$V"
EOF
    # 11) 未知の変数起点template(TMPDIR系ではない)
    cat > "$TEST_TMP/repo/unknownvar.sh" <<'EOF'
#!/usr/bin/env bash
V=$(mktemp -d "$MY_CUSTOM_DIR/foo.XXXXXX")
rm -rf "$V"
EOF
    # 12) bareファイルモードmktemp(-dなし。B-1で明示的に受理禁止)
    cat > "$TEST_TMP/repo/barefile.sh" <<'EOF'
#!/usr/bin/env bash
V=$(mktemp "$BATS_TMPDIR/dummy.XXXXXX.ps1")
rm -rf "$V"
EOF

    run python3 "$CHECKER" --root "$TEST_TMP/repo" --json "$TEST_TMP/out.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS           0"* ]]
    [[ "$output" == *"DANGER         0"* ]]
    [[ "$output" == *"FORMAT_ONLY    12"* ]]

    run cat "$TEST_TMP/out.json"
    [ "$status" -eq 0 ]
    run python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
tags = {h['file']: h['tag'] for h in d['hits']}
for f in ['chained.sh', 'chained_and.sh', 'bg_amp.sh', 'redirect_gt.sh',
          'redirect_fd1.sh', 'redirect_ampgt.sh', 'tform.sh', 'dryrun.sh',
          'reltemplate.sh', 'relparent.sh', 'unknownvar.sh', 'barefile.sh']:
    assert tags.get(f) == 'FORMAT_ONLY', '%s -> %r (expected FORMAT_ONLY)' % (f, tags.get(f))
print('ok: all 12 forms are FORMAT_ONLY, none PASS/DANGER')
" "$TEST_TMP/out.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok: all 12 forms are FORMAT_ONLY"* ]]

    run cat "$TEST_TMP/allow.txt" 2>/dev/null
    run python3 "$CHECKER" --root "$TEST_TMP/repo" --allowlist-out "$TEST_TMP/allow.txt"
    run cat "$TEST_TMP/allow.txt"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "rm_rf_d002e1_checker: template/parent単一トークン内へ埋め込まれた制御演算子はDANGER(injection検出)" {
    mkdir -p "$TEST_TMP/repo"
    cat > "$TEST_TMP/repo/injected.sh" <<'EOF'
#!/usr/bin/env bash
V=$(mktemp -d /tmp/foo.XXXXXX;touch>x)
rm -rf "$V"
EOF
    run python3 "$CHECKER" --root "$TEST_TMP/repo"
    [ "$status" -eq 1 ]
    [[ "$output" == *"PASS           0"* ]]
    [[ "$output" == *"DANGER         1"* ]]
}

# --- redo1本体(親指定形trailing slotのclosed grammar化・cmd_753 redo1) ---
# G753-PARENT-TRAILING-OPTION-CLOSED-GRAMMAR-01: 旧実装はB-1(iii)の
# trailing token(親指定形の第2引数)をUNSAFE_CHARS_REの危険文字有無
# のみで検査しており、危険文字を含まないoption形(-u/--dry-run/
# --help/--version)・変数展開由来のtrailingを誤ってPASSさせていた
# (parentの分類結果のみでkindを決定していたため)。是正後は
# classify_template_token()でtrailingも解析し、内容を問わず
# FORMAT_ONLYへ落とす(危険文字を含む場合のみDANGER_TEMPLATE)。
# 軍師が独立再現した7パターンをそのまま否定試験化する。

@test "rm_rf_d002e1_checker: 親指定形trailing slotのoption形・変数由来は軒並みFORMAT_ONLY(PASS0・allow0・G753-PARENT-TRAILING-OPTION-CLOSED-GRAMMAR-01)" {
    mkdir -p "$TEST_TMP/repo"
    # 1) -p + 非生成option(-u)
    cat > "$TEST_TMP/repo/p_u.sh" <<'EOF'
#!/usr/bin/env bash
V=$(mktemp -d -p /tmp -u)
rm -rf "$V"
EOF
    # 2) -p + --dry-run
    cat > "$TEST_TMP/repo/p_dryrun.sh" <<'EOF'
#!/usr/bin/env bash
V=$(mktemp -d -p /tmp --dry-run)
rm -rf "$V"
EOF
    # 3) -p + --help
    cat > "$TEST_TMP/repo/p_help.sh" <<'EOF'
#!/usr/bin/env bash
V=$(mktemp -d -p /tmp --help)
rm -rf "$V"
EOF
    # 4) -p + --version
    cat > "$TEST_TMP/repo/p_version.sh" <<'EOF'
#!/usr/bin/env bash
V=$(mktemp -d -p /tmp --version)
rm -rf "$V"
EOF
    # 5) --tmpdir=(等号形) + -u
    cat > "$TEST_TMP/repo/tmpdireq_u.sh" <<'EOF'
#!/usr/bin/env bash
V=$(mktemp -d --tmpdir=/tmp -u)
rm -rf "$V"
EOF
    # 6) --tmpdir + 変数展開由来trailing(未知変数)
    cat > "$TEST_TMP/repo/tmpdir_optvar.sh" <<'EOF'
#!/usr/bin/env bash
V=$(mktemp -d --tmpdir /tmp "$OPT")
rm -rf "$V"
EOF
    # 7) -p + 変数展開由来trailing(TMPDIR系変数起点でも trailing位置ではFORMAT_ONLY)
    cat > "$TEST_TMP/repo/p_batstmpdir.sh" <<'EOF'
#!/usr/bin/env bash
V=$(mktemp -d -p /tmp "$BATS_TMPDIR/x.XXXXXX")
rm -rf "$V"
EOF

    run python3 "$CHECKER" --root "$TEST_TMP/repo" --json "$TEST_TMP/out.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS           0"* ]]
    [[ "$output" == *"DANGER         0"* ]]
    [[ "$output" == *"FORMAT_ONLY    7"* ]]

    run python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
tags = {h['file']: h['tag'] for h in d['hits']}
for f in ['p_u.sh', 'p_dryrun.sh', 'p_help.sh', 'p_version.sh',
          'tmpdireq_u.sh', 'tmpdir_optvar.sh', 'p_batstmpdir.sh']:
    assert tags.get(f) == 'FORMAT_ONLY', '%s -> %r (expected FORMAT_ONLY)' % (f, tags.get(f))
print('ok: all 7 forms are FORMAT_ONLY, none PASS/DANGER')
" "$TEST_TMP/out.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok: all 7 forms are FORMAT_ONLY"* ]]

    run python3 "$CHECKER" --root "$TEST_TMP/repo" --allowlist-out "$TEST_TMP/allow_trailing.txt"
    run cat "$TEST_TMP/allow_trailing.txt"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "rm_rf_d002e1_checker: 親指定形trailing slotに制御演算子injectionがあればDANGER(既存のUNSAFE_CHARS_RE検出を維持)" {
    mkdir -p "$TEST_TMP/repo"
    cat > "$TEST_TMP/repo/p_trailing_injected.sh" <<'EOF'
#!/usr/bin/env bash
V=$(mktemp -d -p /tmp foo.XXXXXX;touch>x)
rm -rf "$V"
EOF
    run python3 "$CHECKER" --root "$TEST_TMP/repo"
    [ "$status" -eq 1 ]
    [[ "$output" == *"PASS           0"* ]]
    [[ "$output" == *"DANGER         1"* ]]
}

# --- redo2本体(親指定形trailing slotの安全なリテラルtemplate正例・
# cmd_753 redo2・G753-PARENT-VALID-TEMPLATE-REDO1-01) ---
# redo1はtrailingが存在するだけで一律FORMAT_ONLYへ落としており、
# 将軍裁定B-1(iii)が受理形として明示列挙する「親=絶対リテラル・
# template=安全なリテラル」の正当な形までPASSしなくなっていた
# (過剰修正)。本redoはこの正当な形を専用判定(classify_trailing_
# template_token)でPASSへ復元しつつ、上記2試験(redo1で塞いだ7反例・
# injection検出)が引き続きPASS0・allow0/DANGERのままであることを
# 対照試験として維持する(このファイル内で変更していない)。

@test "rm_rf_d002e1_checker: 親指定形+安全なリテラルtemplateはPASS(-p/--tmpdir/--tmpdir=の3形・G753-PARENT-VALID-TEMPLATE-REDO1-01)" {
    mkdir -p "$TEST_TMP/repo"
    # 1) -p 絶対リテラル親 + 安全なリテラルtemplate
    cat > "$TEST_TMP/repo/p_template.sh" <<'EOF'
#!/usr/bin/env bash
A=$(mktemp -d -p /tmp x.XXXXXX)
rm -rf "$A"
EOF
    # 2) --tmpdir 絶対リテラル親 + 安全なリテラルtemplate
    cat > "$TEST_TMP/repo/tmpdir_template.sh" <<'EOF'
#!/usr/bin/env bash
B=$(mktemp -d --tmpdir /tmp x.XXXXXX)
rm -rf "$B"
EOF
    # 3) --tmpdir=(等号形) 絶対リテラル親 + 安全なリテラルtemplate
    cat > "$TEST_TMP/repo/tmpdireq_template.sh" <<'EOF'
#!/usr/bin/env bash
C=$(mktemp -d --tmpdir=/tmp x.XXXXXX)
rm -rf "$C"
EOF

    run python3 "$CHECKER" --root "$TEST_TMP/repo" --json "$TEST_TMP/out.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS           3"* ]]
    [[ "$output" == *"FORMAT_ONLY    0"* ]]
    [[ "$output" == *"DANGER         0"* ]]

    run python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
tags = {h['file']: h['tag'] for h in d['hits']}
for f in ['p_template.sh', 'tmpdir_template.sh', 'tmpdireq_template.sh']:
    assert tags.get(f) == 'PASS', '%s -> %r (expected PASS)' % (f, tags.get(f))
print('ok: all 3 parent+safe-template forms are PASS')
" "$TEST_TMP/out.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok: all 3 parent+safe-template forms are PASS"* ]]

    run python3 "$CHECKER" --root "$TEST_TMP/repo" --allowlist-out "$TEST_TMP/allow_template.txt"
    run cat "$TEST_TMP/allow_template.txt"
    [ "$status" -eq 0 ]
    [[ "$output" == *'rm -rf "$A"'* ]]
    [[ "$output" == *'rm -rf "$B"'* ]]
    [[ "$output" == *'rm -rf "$C"'* ]]
}

@test "rm_rf_d002e1_checker: 親がTMPDIR系変数由来の場合、trailingが安全なリテラルでもFORMAT_ONLY(親のTMPDIR依存は変わらない)" {
    mkdir -p "$TEST_TMP/repo"
    cat > "$TEST_TMP/repo/p_tmpdirvar_template.sh" <<'EOF'
#!/usr/bin/env bash
V=$(mktemp -d -p "$BATS_TMPDIR" x.XXXXXX)
rm -rf "$V"
EOF
    run python3 "$CHECKER" --root "$TEST_TMP/repo"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS           0"* ]]
    [[ "$output" == *"FORMAT_ONLY    1"* ]]
    [[ "$output" == *"DANGER         0"* ]]
}

# --- 本redo(cmd_753 scope縮小・パス軸のclosed grammar化)本体の試験 ---
# 将軍裁定C-1〜C-3: 根を「絶対パスであること」ではなく「リテラル/tmp」
# という文字列そのもので判定する。redo2まではSAFE_LITERAL_PATH_RE
# (絶対パス全般を受理)を使っており、/mnt/c等のWSL保護パスも絶対
# リテラルであるという理由だけでABS-CONSTRUCT(PASS適格)になり得た
# (fail-open。将軍裁定の直接の是正対象)。以下は「根が/tmp以外の
# 絶対リテラルパスはPASSしなくなったこと」を示す回帰試験である。

@test "rm_rf_d002e1_checker: 根が/tmp以外の絶対リテラル(WSL保護パス等)はもうPASSしない・FORMAT_ONLYへ倒す(C-1・redo2 fail-open是正)" {
    mkdir -p "$TEST_TMP/repo"
    # 1) WSL保護パス配下へのtemplate直書き(/mnt/c/Windows)
    cat > "$TEST_TMP/repo/mnt_windows.sh" <<'EOF'
#!/usr/bin/env bash
V=$(mktemp -d /mnt/c/Windows/foo.XXXXXX)
rm -rf "$V"
EOF
    # 2) WSL保護パスを-pの親に指定(/mnt/c/Users)
    cat > "$TEST_TMP/repo/mnt_users_parent.sh" <<'EOF'
#!/usr/bin/env bash
V=$(mktemp -d -p /mnt/c/Users)
rm -rf "$V"
EOF
    # 3) /tmp以外の一般的な絶対リテラル(/etc)
    cat > "$TEST_TMP/repo/etc_literal.sh" <<'EOF'
#!/usr/bin/env bash
V=$(mktemp -d /etc/foo.XXXXXX)
rm -rf "$V"
EOF
    # 4) /home配下の絶対リテラル
    cat > "$TEST_TMP/repo/home_literal.sh" <<'EOF'
#!/usr/bin/env bash
V=$(mktemp -d /home/user/foo.XXXXXX)
rm -rf "$V"
EOF
    # 5) 大小文字違い(/TMP)は文字列として別物——リテラル一致で判定するため通らない
    cat > "$TEST_TMP/repo/uppercase_tmp.sh" <<'EOF'
#!/usr/bin/env bash
V=$(mktemp -d /TMP/foo.XXXXXX)
rm -rf "$V"
EOF
    # 6) 部分一致(/tmpfoo)は"/tmp"を接頭辞に持つだけの別ディレクトリ
    cat > "$TEST_TMP/repo/tmp_prefix_partial.sh" <<'EOF'
#!/usr/bin/env bash
V=$(mktemp -d /tmpfoo/foo.XXXXXX)
rm -rf "$V"
EOF

    run python3 "$CHECKER" --root "$TEST_TMP/repo" --json "$TEST_TMP/out.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS           0"* ]]
    [[ "$output" == *"DANGER         0"* ]]
    [[ "$output" == *"FORMAT_ONLY    6"* ]]

    run python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
tags = {h['file']: h['tag'] for h in d['hits']}
for f in ['mnt_windows.sh', 'mnt_users_parent.sh', 'etc_literal.sh',
          'home_literal.sh', 'uppercase_tmp.sh', 'tmp_prefix_partial.sh']:
    assert tags.get(f) == 'FORMAT_ONLY', '%s -> %r (expected FORMAT_ONLY)' % (f, tags.get(f))
print('ok: all 6 non-/tmp absolute-literal forms are FORMAT_ONLY, none PASS')
" "$TEST_TMP/out.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok: all 6 non-/tmp absolute-literal forms are FORMAT_ONLY"* ]]

    run python3 "$CHECKER" --root "$TEST_TMP/repo" --allowlist-out "$TEST_TMP/allow_mnt.txt"
    run cat "$TEST_TMP/allow_mnt.txt"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "rm_rf_d002e1_checker: /tmp根であっても'..'を含む別名表記はPASSしない(C-2・別名表記の遮断)" {
    mkdir -p "$TEST_TMP/repo"
    # 1) template側の".."による/tmp根の迂回
    cat > "$TEST_TMP/repo/dotdot_template.sh" <<'EOF'
#!/usr/bin/env bash
V=$(mktemp -d /tmp/../etc/foo.XXXXXX)
rm -rf "$V"
EOF
    # 2) -p親側の".."による迂回
    cat > "$TEST_TMP/repo/dotdot_parent.sh" <<'EOF'
#!/usr/bin/env bash
V=$(mktemp -d -p /tmp/..)
rm -rf "$V"
EOF
    # 3) trailing templateに埋め込まれた".."(先頭は英数字のためSAFE_LITERAL_TEMPLATE_REの
    #    構造だけでは弾けない・DOTDOT_REガードの直接試験)
    cat > "$TEST_TMP/repo/dotdot_trailing_embedded.sh" <<'EOF'
#!/usr/bin/env bash
V=$(mktemp -d -p /tmp foo..XXXXXX)
rm -rf "$V"
EOF

    run python3 "$CHECKER" --root "$TEST_TMP/repo" --json "$TEST_TMP/out.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS           0"* ]]
    [[ "$output" == *"DANGER         0"* ]]
    [[ "$output" == *"FORMAT_ONLY    3"* ]]

    run python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
tags = {h['file']: h['tag'] for h in d['hits']}
for f in ['dotdot_template.sh', 'dotdot_parent.sh', 'dotdot_trailing_embedded.sh']:
    assert tags.get(f) == 'FORMAT_ONLY', '%s -> %r (expected FORMAT_ONLY)' % (f, tags.get(f))
print('ok: all 3 \"..\" forms are FORMAT_ONLY, none PASS')
" "$TEST_TMP/out.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *'ok: all 3 "..'* ]]

    run python3 "$CHECKER" --root "$TEST_TMP/repo" --allowlist-out "$TEST_TMP/allow_dotdot.txt"
    run cat "$TEST_TMP/allow_dotdot.txt"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "rm_rf_d002e1_checker: /tmp単体(-p親・templateなし)は引き続きPASS(C-1で狭めすぎていないことの回帰確認)" {
    mkdir -p "$TEST_TMP/repo"
    cat > "$TEST_TMP/repo/tmp_bare_parent.sh" <<'EOF'
#!/usr/bin/env bash
V=$(mktemp -d -p /tmp)
rm -rf "$V"
EOF
    cat > "$TEST_TMP/repo/tmp_trailing_slash_parent.sh" <<'EOF'
#!/usr/bin/env bash
V=$(mktemp -d -p /tmp/)
rm -rf "$V"
EOF
    run python3 "$CHECKER" --root "$TEST_TMP/repo"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS           2"* ]]
    [[ "$output" == *"FORMAT_ONLY    0"* ]]
    [[ "$output" == *"DANGER         0"* ]]
}

# --- 本redo1(問題1是正・G753-TMP-NESTED-SYMLINK-ESCAPE-01)本体の試験 ---
# 軍師が独立fixtureで、旧TMP_LITERAL_ROOT_RE(`^/tmp(?:/[A-Za-z0-9._/-]*)?$`)
# が多段ネスト・連続slash・dotセグメントを字面上PASS適格にしてしまう
# ことを確認した(中間segmentがsymlinkであれば実際の作用先を保証
# できない)。将軍実測どおり実在形は「/tmp直下basename1個」のみで
# あるため、これらは一切PASSしなくなったことを回帰試験として固定する。

@test "rm_rf_d002e1_checker: /tmp配下の多段ネスト・連続slash・dotセグメントはもうPASSしない(G753-TMP-NESTED-SYMLINK-ESCAPE-01)" {
    mkdir -p "$TEST_TMP/repo"
    # 1) 多段ネスト(中間segmentがsymlinkの恐れ)
    cat > "$TEST_TMP/repo/nested.sh" <<'EOF'
#!/usr/bin/env bash
V=$(mktemp -d /tmp/link/out.XXXXXX)
rm -rf "$V"
EOF
    # 2) 連続slash
    cat > "$TEST_TMP/repo/double_slash.sh" <<'EOF'
#!/usr/bin/env bash
V=$(mktemp -d /tmp//double.XXXXXX)
rm -rf "$V"
EOF
    # 3) dotセグメント
    cat > "$TEST_TMP/repo/dot_segment.sh" <<'EOF'
#!/usr/bin/env bash
V=$(mktemp -d /tmp/./dot.XXXXXX)
rm -rf "$V"
EOF
    # 4) 親指定形でも/tmp配下にさらに階層を持つものはもうPASSしない
    cat > "$TEST_TMP/repo/nested_parent.sh" <<'EOF'
#!/usr/bin/env bash
V=$(mktemp -d -p /tmp/sub)
rm -rf "$V"
EOF

    run python3 "$CHECKER" --root "$TEST_TMP/repo" --json "$TEST_TMP/out.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS           0"* ]]
    [[ "$output" == *"DANGER         0"* ]]
    [[ "$output" == *"FORMAT_ONLY    4"* ]]

    run python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
tags = {h['file']: h['tag'] for h in d['hits']}
for f in ['nested.sh', 'double_slash.sh', 'dot_segment.sh', 'nested_parent.sh']:
    assert tags.get(f) == 'FORMAT_ONLY', '%s -> %r (expected FORMAT_ONLY)' % (f, tags.get(f))
print('ok: all 4 nested/symlink-escapable forms are FORMAT_ONLY, none PASS')
" "$TEST_TMP/out.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok: all 4 nested/symlink-escapable forms are FORMAT_ONLY"* ]]

    run python3 "$CHECKER" --root "$TEST_TMP/repo" --allowlist-out "$TEST_TMP/allow_nested.txt"
    run cat "$TEST_TMP/allow_nested.txt"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- 本redo1(問題2是正・G753-NONCREATING-MKTEMP-TEMPLATE-PASS-02)本体の試験 ---
# 軍師が独立fixtureで、mktempが実際に置換する「末尾連続X」を検査器が
# 一切要求していないことを確認した。連続Xを欠くtemplateはmktempが
# 実際にはディレクトリ作成に失敗するか固定名になり、D002-E1(a)の
# 前提(mktemp -dが実際にそのディレクトリを作成した)を満たさない。

@test "rm_rf_d002e1_checker: 末尾連続Xを欠くtemplateはもうPASSしない(G753-NONCREATING-MKTEMP-TEMPLATE-PASS-02)" {
    mkdir -p "$TEST_TMP/repo"
    # 1) 直接template形の/tmp単独(templateがそもそも無い)
    cat > "$TEST_TMP/repo/tmp_alone.sh" <<'EOF'
#!/usr/bin/env bash
V=$(mktemp -d /tmp)
rm -rf "$V"
EOF
    # 2) 直接template形で連続Xなし
    cat > "$TEST_TMP/repo/no_x_direct.sh" <<'EOF'
#!/usr/bin/env bash
V=$(mktemp -d /tmp/no_required_x)
rm -rf "$V"
EOF
    # 3) 親指定形trailingで連続Xなし
    cat > "$TEST_TMP/repo/no_x_trailing.sh" <<'EOF'
#!/usr/bin/env bash
V=$(mktemp -d -p /tmp no_required_x)
rm -rf "$V"
EOF
    # 4) 連続Xが不足(5個。要求は6個以上)
    cat > "$TEST_TMP/repo/short_x.sh" <<'EOF'
#!/usr/bin/env bash
V=$(mktemp -d /tmp/foo.XXXXX)
rm -rf "$V"
EOF

    run python3 "$CHECKER" --root "$TEST_TMP/repo" --json "$TEST_TMP/out.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS           0"* ]]
    [[ "$output" == *"DANGER         0"* ]]
    [[ "$output" == *"FORMAT_ONLY    4"* ]]

    run python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
tags = {h['file']: h['tag'] for h in d['hits']}
for f in ['tmp_alone.sh', 'no_x_direct.sh', 'no_x_trailing.sh', 'short_x.sh']:
    assert tags.get(f) == 'FORMAT_ONLY', '%s -> %r (expected FORMAT_ONLY)' % (f, tags.get(f))
print('ok: all 4 non-creating (no required X) templates are FORMAT_ONLY, none PASS')
" "$TEST_TMP/out.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok: all 4 non-creating (no required X) templates are FORMAT_ONLY"* ]]

    run python3 "$CHECKER" --root "$TEST_TMP/repo" --allowlist-out "$TEST_TMP/allow_no_x.txt"
    run cat "$TEST_TMP/allow_no_x.txt"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "rm_rf_d002e1_checker: 末尾連続X(6個ちょうど)を持つ実在形はPASSのまま(回帰確認)" {
    mkdir -p "$TEST_TMP/repo"
    cat > "$TEST_TMP/repo/exact6.sh" <<'EOF'
#!/usr/bin/env bash
V=$(mktemp -d /tmp/test_allocate_aad_XXXXXX)
rm -rf "$V"
EOF
    run python3 "$CHECKER" --root "$TEST_TMP/repo"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS           1"* ]]
    [[ "$output" == *"FORMAT_ONLY    0"* ]]
    [[ "$output" == *"DANGER         0"* ]]
}
