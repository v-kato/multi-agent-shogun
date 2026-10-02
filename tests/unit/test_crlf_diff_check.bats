#!/usr/bin/env bats
# test_crlf_diff_check.bats — scripts/crlf_diff_check.py の試験(cmd_800)
#
# CRLF/LF 混在の fixture は試験ごとに mktemp -d の下へ git repository を作って
# 生成する(実 repository には触れない)。正常・異常・境界に加えて、判定の if 文
# (# judge:<名前> の行)の条件を外した変異体を作り、この試験群がその欠落を
# 検出できることを確かめる(変異試験)。

setup() {
    # 絶対リテラルの template で作り、TMPDIR に依らず絶対パスにする(D002-E1(d))。
    TEST_TMP="$(mktemp -d /tmp/crlf_diff_check.XXXXXX)"
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    SCRIPT="$PROJECT_ROOT/scripts/crlf_diff_check.py"
    # 利用者の git 設定・環境に左右されないようにする。
    export GIT_CONFIG_GLOBAL=/dev/null
    export GIT_CONFIG_NOSYSTEM=1
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
    # TEST_TMP より上の repository を見つけないようにする(「作業木の外」の
    # 試験を、TEST_TMP の親の状況に左右させない)。
    export GIT_CEILING_DIRECTORIES="$(dirname "$TEST_TMP")"
    REPO="$TEST_TMP/repo"
    git init -q "$REPO"
}

teardown() {
    rm -rf -- "${TEST_TMP:?}"
}

# fixture の commit(パスを明示する)
commit_paths() {
    local message="$1"
    shift
    git -C "$REPO" add -- "$@"
    git -C "$REPO" -c user.name=fixture -c user.email=fixture@example.invalid \
        commit -q -m "$message"
}

# 判定行の条件を差し替えた変異体を作る。目印の行が元に 1 行・変異体に 1 行
# あることを確かめる(目印が消えて変異が空振りするのを防ぐ)。
mutate_judge() {
    local tag="$1" dst="$2"
    [ "$(/usr/bin/grep -c "# judge:${tag}\$" "$SCRIPT")" -eq 1 ]
    sed -E "s/^([[:space:]]*)if .*# judge:${tag}\$/\\1if False:  # judge:${tag} MUTATED/" \
        "$SCRIPT" > "$dst"
    [ "$(/usr/bin/grep -c "# judge:${tag} MUTATED\$" "$dst")" -eq 1 ]
}

# ---- 正常 ----------------------------------------------------------------

@test "正常: CRLF混在ファイルを行末を保ったまま編集 → exit 0・各項目を出力" {
    printf 'a\r\nb\r\nc\nd\r\ne\n' > "$REPO/f.txt"
    commit_paths init f.txt
    printf 'a\r\nB2\r\nc\nnew\r\nd\r\ne\n' > "$REPO/f.txt"

    cd "$REPO"
    run python3 "$SCRIPT" --rev HEAD f.txt
    [ "$status" -eq 0 ]
    [[ "$output" == *"=== f.txt ==="* ]]
    [[ "$output" == *"行数: 現在 6行(CRLF 4 / LF 2 / 改行なし 0)"* ]]
    [[ "$output" == *"参照 5行(CRLF 3 / LF 2 / 改行なし 0)"* ]]
    [[ "$output" == *"LFのみの行: 現在 3,6"* ]]
    [[ "$output" == *"参照 3,5"* ]]
    [[ "$output" == *"最初の差分: 行2 桁1(byte offset 3・内容の差)"* ]]
    [[ "$output" == *"内容不変の行: 4行(byte一致 4 / 行末のみ変化 0)"* ]]
    [[ "$output" == *"現在へ +2(追加・変更行の行末: CRLF 2 / LF 0 / 改行なし 0)"* ]]
    [[ "$output" == *"numstat: git diff +2 -1 / --ignore-space-at-eol +2 -1 → 一致"* ]]
    [[ "$output" == *"判定: OK"* ]]
    [[ "$output" == *"対象ファイル数: 1(OK 1 / NG 0 / エラー 0)"* ]]
}

@test "正常: --rev 省略時は HEAD・複数ファイルを数える" {
    printf 'x\r\ny\n' > "$REPO/f.txt"
    printf 'p\nq\r\n' > "$REPO/g.txt"
    commit_paths init f.txt g.txt
    printf 'x\r\ny\nz\n' > "$REPO/f.txt"

    cd "$REPO"
    run python3 "$SCRIPT" f.txt g.txt
    [ "$status" -eq 0 ]
    [[ "$output" == *"参照版: HEAD ("* ]]
    [[ "$output" == *"=== f.txt ==="* ]]
    [[ "$output" == *"=== g.txt ==="* ]]
    [[ "$output" == *"対象ファイル数: 2(OK 2 / NG 0 / エラー 0)"* ]]
}

@test "正常: --rev に過去の commit を与えるとその版と比べる" {
    printf 'a\r\nb\n' > "$REPO/f.txt"
    commit_paths v1 f.txt
    printf 'a\r\nb\nc\r\n' > "$REPO/f.txt"
    commit_paths v2 f.txt

    cd "$REPO"
    run python3 "$SCRIPT" --rev HEAD~1 f.txt
    [ "$status" -eq 0 ]
    [[ "$output" == *"参照版: HEAD~1 ("* ]]
    [[ "$output" == *"numstat: git diff +1 -0 / --ignore-space-at-eol +1 -0 → 一致"* ]]
}

@test "正常: サブディレクトリから相対パスで指定できる" {
    mkdir -p "$REPO/sub"
    printf 'a\r\nb\n' > "$REPO/sub/f.txt"
    commit_paths init sub/f.txt
    mkdir -p "$REPO/other"

    cd "$REPO/other"
    run python3 "$SCRIPT" ../sub/f.txt
    [ "$status" -eq 0 ]
    [[ "$output" == *"=== ../sub/f.txt ==="* ]]
    [[ "$output" == *"判定: OK"* ]]
}

# ---- 異常(不健全 → exit 1) ------------------------------------------------

@test "異常: 編集で LF 行が支配的な CRLF へ巻き込まれた → exit 1・行番号と numstat 不一致" {
    printf 'a\r\nb\r\nc\nd\r\ne\n' > "$REPO/f.txt"
    commit_paths init f.txt
    printf 'a\r\nB2\r\nc\r\nd\r\ne\r\n' > "$REPO/f.txt"

    cd "$REPO"
    run python3 "$SCRIPT" f.txt
    [ "$status" -eq 1 ]
    [[ "$output" == *"LFのみの行: 現在 (なし)"* ]]
    [[ "$output" == *"内容不変の行: 4行(byte一致 2 / 行末のみ変化 2)"* ]]
    [[ "$output" == *"行末だけが変わった行が 2 行ある(LF→CRLF 2行): 現在の行番号 3,5"* ]]
    [[ "$output" == *"行3(参照 行3): LF→CRLF"* ]]
    [[ "$output" == *"numstat: git diff +3 -3 / --ignore-space-at-eol +1 -1 → 不一致"* ]]
    [[ "$output" == *"判定: NG"* ]]
    [[ "$output" == *"対象ファイル数: 1(OK 0 / NG 1 / エラー 0)"* ]]
}

@test "異常: git が行末差を見ない設定(.gitattributes eol=lf)でも byte 比較で検出 → exit 1" {
    printf '*.txt text eol=lf\n' > "$REPO/.gitattributes"
    printf 'a\nb\nc\n' > "$REPO/f.txt"
    commit_paths init .gitattributes f.txt
    printf 'a\nb\r\nc\n' > "$REPO/f.txt"

    cd "$REPO"
    run python3 "$SCRIPT" f.txt
    [ "$status" -eq 1 ]
    # git 側の数は一致してしまう(行末の差が見えない)ことを確かめた上で、
    [[ "$output" == *"numstat: git diff +0 -0 / --ignore-space-at-eol +0 -0 → 一致"* ]]
    # byte 比較だけが捕まえる。
    [[ "$output" == *"最初の差分: 行2 桁2(byte offset 3・行末の差(LF→CRLF))"* ]]
    [[ "$output" == *"現在の行番号 2"* ]]
    [[ "$output" == *"判定: NG"* ]]
}

@test "異常: 行末空白だけを変えた水増し → numstat 不一致で exit 1" {
    printf 'a\r\nb\r\nc\n' > "$REPO/f.txt"
    commit_paths init f.txt
    printf 'a\r\nb  \r\nc\n' > "$REPO/f.txt"

    cd "$REPO"
    run python3 "$SCRIPT" f.txt
    [ "$status" -eq 1 ]
    [[ "$output" == *"行末のみ変化 0"* ]]
    [[ "$output" == *"numstat 不一致(+1 -1 対 +0 -0)"* ]]
    [[ "$output" == *"行末空白だけを変えた行が 1 行ある"* ]]
}

@test "異常: 健全 1 本と不健全 1 本 → exit 1・集計に両方" {
    printf 'a\r\nb\n' > "$REPO/ok.txt"
    printf 'a\r\nb\n' > "$REPO/ng.txt"
    commit_paths init ok.txt ng.txt
    printf 'a\r\nb\r\n' > "$REPO/ng.txt"

    cd "$REPO"
    run python3 "$SCRIPT" ok.txt ng.txt
    [ "$status" -eq 1 ]
    [[ "$output" == *"対象ファイル数: 2(OK 1 / NG 1 / エラー 0)"* ]]
}

# ---- 異常(使い方誤り・実行失敗 → exit 2・沈黙して 0 を返さない) ---------------

@test "エラー: 対象 0 本 → exit 2" {
    cd "$REPO"
    run python3 "$SCRIPT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"対象ファイルが 0 本"* ]]
}

@test "エラー: rev を解決できない → exit 2・比較へ進まない" {
    printf 'a\r\nb\n' > "$REPO/f.txt"
    commit_paths init f.txt

    cd "$REPO"
    run python3 "$SCRIPT" --rev no-such-rev f.txt
    [ "$status" -eq 2 ]
    [[ "$output" == *"rev 'no-such-rev' を commit に解決できない"* ]]
    [[ "$output" != *"行数:"* ]]
    [[ "$output" == *"対象ファイル数: 1(OK 0 / NG 0 / エラー 1)"* ]]
}

@test "エラー: rev が - で始まる → exit 2" {
    printf 'a\n' > "$REPO/f.txt"
    commit_paths init f.txt

    cd "$REPO"
    run python3 "$SCRIPT" --rev=--all f.txt
    [ "$status" -eq 2 ]
    [[ "$output" == *"rev が - で始まる"* ]]
}

@test "エラー: 参照版に無いファイル(未追跡)→ exit 2" {
    printf 'a\n' > "$REPO/f.txt"
    commit_paths init f.txt
    printf 'new\r\n' > "$REPO/untracked.txt"

    cd "$REPO"
    run python3 "$SCRIPT" untracked.txt
    [ "$status" -eq 2 ]
    [[ "$output" == *"にこのファイルが無い"* ]]
}

@test "エラー: ファイルが無い・git の作業木の外・バイナリ → いずれも exit 2" {
    printf 'a\n' > "$REPO/f.txt"
    printf 'a\0b\n' > "$REPO/bin.dat"
    commit_paths init f.txt bin.dat
    printf 'outside\n' > "$TEST_TMP/outside.txt"

    cd "$REPO"
    run python3 "$SCRIPT" missing.txt
    [ "$status" -eq 2 ]
    [[ "$output" == *"ファイルが無い"* ]]

    run python3 "$SCRIPT" "$TEST_TMP/outside.txt"
    [ "$status" -eq 2 ]
    [[ "$output" == *"git の作業木の外"* ]]

    run python3 "$SCRIPT" bin.dat
    [ "$status" -eq 2 ]
    [[ "$output" == *"バイナリ"* ]]
}

@test "エラー: エラーと NG と OK が混在 → エラーを優先して exit 2" {
    printf 'a\r\nb\n' > "$REPO/ok.txt"
    printf 'a\r\nb\n' > "$REPO/ng.txt"
    commit_paths init ok.txt ng.txt
    printf 'a\r\nb\r\n' > "$REPO/ng.txt"

    cd "$REPO"
    run python3 "$SCRIPT" ok.txt ng.txt missing.txt
    [ "$status" -eq 2 ]
    [[ "$output" == *"対象ファイル数: 3(OK 1 / NG 1 / エラー 1)"* ]]
}

# ---- 境界 ----------------------------------------------------------------

@test "境界: 参照版と同一 → exit 0・同一である旨を注意として出す" {
    printf 'a\r\nb\n' > "$REPO/f.txt"
    commit_paths init f.txt

    cd "$REPO"
    run python3 "$SCRIPT" f.txt
    [ "$status" -eq 0 ]
    [[ "$output" == *"最初の差分: なし(参照版と byte 一致)"* ]]
    [[ "$output" == *"判定: OK(注意: 参照版と同一。"* ]]
}

@test "境界: 改行の無い最終行の後へ追記すると、その行の行末変化として NG(fail-closed)" {
    printf 'a\r\nb' > "$REPO/f.txt"
    commit_paths init f.txt
    printf 'a\r\nb\r\nc' > "$REPO/f.txt"

    cd "$REPO"
    run python3 "$SCRIPT" f.txt
    [ "$status" -eq 1 ]
    [[ "$output" == *"参照 2行(CRLF 1 / LF 0 / 改行なし 1)"* ]]
    [[ "$output" == *"行2(参照 行2): 改行なし→CRLF"* ]]
}

@test "境界: LF だけのファイルは行番号を範囲で縮め、CRLF だけなら(なし)" {
    printf 'a\nb\nc\n' > "$REPO/lf.txt"
    printf 'a\r\nb\r\n' > "$REPO/crlf.txt"
    commit_paths init lf.txt crlf.txt
    printf 'a\nb\nc\nd\n' > "$REPO/lf.txt"

    cd "$REPO"
    run python3 "$SCRIPT" lf.txt crlf.txt
    [ "$status" -eq 0 ]
    [[ "$output" == *"LFのみの行: 現在 1-4"* ]]
    [[ "$output" == *"参照 1-3"* ]]
    [[ "$output" == *"LFのみの行: 現在 (なし)"* ]]
}

@test "境界: 空ファイルへ追記 → exit 0" {
    : > "$REPO/empty.txt"
    commit_paths init empty.txt
    printf 'a\r\n' > "$REPO/empty.txt"

    cd "$REPO"
    run python3 "$SCRIPT" empty.txt
    [ "$status" -eq 0 ]
    [[ "$output" == *"参照 0行(CRLF 0 / LF 0 / 改行なし 0)"* ]]
    [[ "$output" == *"現在の側にだけ行がある"* ]]
}

@test "境界: checkout 変換(eol=crlf)のあるファイルは変換後と比べ、注記を出す" {
    printf '*.bat text eol=crlf\n' > "$REPO/.gitattributes"
    printf 'x\ny\n' > "$REPO/g.bat"
    commit_paths init .gitattributes g.bat
    # 作業木を一度別の内容にしてから checkout し直し、CRLF で書き出させる
    # (blob は LF のまま)
    printf 'changed\n' > "$REPO/g.bat"
    git -C "$REPO" checkout -q -- g.bat
    [ "$(od -An -c "$REPO/g.bat" | tr -d ' \n')" = 'x\r\ny\r\n' ]

    cd "$REPO"
    run python3 "$SCRIPT" g.bat
    [ "$status" -eq 0 ]
    [[ "$output" == *"注記: blob の生の内容と checkout 変換後とで行末が異なる"* ]]
    [[ "$output" == *"内容不変の行: 2行(byte一致 2 / 行末のみ変化 0)"* ]]
}

@test "読み取り専用: 判定後も対象ファイルと index は変わらない" {
    printf 'a\r\nb\nc\r\n' > "$REPO/f.txt"
    commit_paths init f.txt
    printf 'a\r\nb\r\nc\r\n' > "$REPO/f.txt"
    touch -d '2000-01-01 00:00:00' "$REPO/f.txt"
    local before_file before_mtime before_index
    before_file="$(sha256sum < "$REPO/f.txt")"
    before_mtime="$(stat -c %Y "$REPO/f.txt")"
    before_index="$(sha256sum < "$REPO/.git/index")"

    cd "$REPO"
    run python3 "$SCRIPT" f.txt
    [ "$status" -eq 1 ]
    [ "$(sha256sum < "$REPO/f.txt")" = "$before_file" ]
    [ "$(stat -c %Y "$REPO/f.txt")" = "$before_mtime" ]
    [ "$(sha256sum < "$REPO/.git/index")" = "$before_index" ]
}

# ---- 同じ本文の行が複数ある場合の対応付け(cmd_800 G800-01) -------------------
# 本文だけで対応させると、byte 一致のまま残る既存の CRLF 空行ではなく、挿入した
# LF 空行を対応させて「行末だけが変わった」と誤認する型(実例は
# tests/unit/test_switch_cli.bats に 61 行を挿入した編集)。

@test "対応付け: 重複空行を含む LF の塊を既存の CRLF 空行の前へ挿入しただけ → exit 0" {
    printf 'a\nb\nc\n\r\nz\r\n' > "$REPO/f.txt"
    commit_paths init f.txt
    printf 'a\nb\nc\n\nnew1\n\nnew2\n\r\nz\r\n' > "$REPO/f.txt"

    cd "$REPO"
    run python3 "$SCRIPT" f.txt
    [ "$status" -eq 0 ]
    [[ "$output" == *"本文だけで対応させると行末のみ変化 1行と出るが、byte 一致の行を優先して対応させると 0行(内容不変として対応した行 5→5行)"* ]]
    [[ "$output" == *"内容不変の行: 5行(byte一致 5 / 行末のみ変化 0)"* ]]
    [[ "$output" == *"現在へ +4(追加・変更行の行末: CRLF 0 / LF 4 / 改行なし 0)"* ]]
    [[ "$output" == *"numstat: git diff +4 -0 / --ignore-space-at-eol +4 -0 → 一致"* ]]
    [[ "$output" == *"判定: OK"* ]]
}

@test "対応付け: 既存の CRLF 空行の前にあった LF 空行を含む塊を削除しただけ → exit 0" {
    printf 'a\nb\nc\n\nold\n\r\nz\r\n' > "$REPO/f.txt"
    commit_paths init f.txt
    printf 'a\nb\nc\n\r\nz\r\n' > "$REPO/f.txt"

    cd "$REPO"
    run python3 "$SCRIPT" f.txt
    [ "$status" -eq 0 ]
    [[ "$output" == *"内容不変の行: 5行(byte一致 5 / 行末のみ変化 0)"* ]]
    [[ "$output" == *"参照から -2 / 現在へ +0"* ]]
    [[ "$output" == *"判定: OK"* ]]
}

@test "対応付け: 同じ挿入に本物の行末変化が混ざれば、その行だけを挙げて exit 1" {
    printf 'a\nb\nc\n\r\nz\r\n' > "$REPO/f.txt"
    commit_paths init f.txt
    printf 'a\r\nb\nc\n\nnew1\n\nnew2\n\r\nz\r\n' > "$REPO/f.txt"

    cd "$REPO"
    run python3 "$SCRIPT" f.txt
    [ "$status" -eq 1 ]
    [[ "$output" == *"内容不変の行: 5行(byte一致 4 / 行末のみ変化 1)"* ]]
    [[ "$output" == *"行末だけが変わった行が 1 行ある(LF→CRLF 1行): 現在の行番号 1"* ]]
    [[ "$output" == *"行1(参照 行1): LF→CRLF"* ]]
    [[ "$output" != *"(参照 行4)"* ]]
    [[ "$output" == *"判定: NG"* ]]
}

@test "対応付け: byte 一致を優先すると対応する行が減る場合は採らず、行末変化を検出 → exit 1" {
    # byte 一致を優先すると 1 行目の A を削除・追加として扱い、行末変化 0 に
    # 見えるが、内容不変として対応する行が 2→1 に減る。git も行末差を見ない。
    printf '*.txt text eol=lf\n' > "$REPO/.gitattributes"
    printf 'A\nB\n' > "$REPO/f.txt"
    commit_paths init .gitattributes f.txt
    printf 'A\r\nB\nA\n' > "$REPO/f.txt"

    cd "$REPO"
    run python3 "$SCRIPT" f.txt
    [ "$status" -eq 1 ]
    [[ "$output" == *"numstat: git diff +1 -0 / --ignore-space-at-eol +1 -0 → 一致"* ]]
    [[ "$output" != *"byte 一致の行を優先して対応させると"* ]]
    [[ "$output" == *"内容不変の行: 2行(byte一致 1 / 行末のみ変化 1)"* ]]
    [[ "$output" == *"行1(参照 行1): LF→CRLF"* ]]
}

# ---- 変異試験(判定を外すと上の試験が落ちることを確かめる) --------------------

@test "変異: 行末変化の判定(judge:eol-change)を外すと git が見ない行末変化を見逃す" {
    printf '*.txt text eol=lf\n' > "$REPO/.gitattributes"
    printf 'a\nb\nc\n' > "$REPO/f.txt"
    commit_paths init .gitattributes f.txt
    printf 'a\nb\r\nc\n' > "$REPO/f.txt"
    mutate_judge eol-change "$TEST_TMP/mutant.py"

    cd "$REPO"
    run python3 "$SCRIPT" f.txt
    [ "$status" -eq 1 ]
    run python3 "$TEST_TMP/mutant.py" f.txt
    [ "$status" -eq 0 ]
}

@test "変異: numstat 突合の判定(judge:numstat-mismatch)を外すと行末空白の水増しを見逃す" {
    printf 'a\r\nb\r\nc\n' > "$REPO/f.txt"
    commit_paths init f.txt
    printf 'a\r\nb  \r\nc\n' > "$REPO/f.txt"
    mutate_judge numstat-mismatch "$TEST_TMP/mutant.py"

    cd "$REPO"
    run python3 "$SCRIPT" f.txt
    [ "$status" -eq 1 ]
    run python3 "$TEST_TMP/mutant.py" f.txt
    [ "$status" -eq 0 ]
}

@test "変異: 対象 0 本の判定(judge:no-target)を外すと沈黙して 0 を返す" {
    mutate_judge no-target "$TEST_TMP/mutant.py"

    cd "$REPO"
    run python3 "$SCRIPT"
    [ "$status" -eq 2 ]
    run python3 "$TEST_TMP/mutant.py"
    [ "$status" -eq 0 ]
}

@test "変異: rev 未解決の判定(judge:rev-unresolved)を外すと解決できない rev のまま比較へ進む" {
    printf 'a\r\nb\n' > "$REPO/f.txt"
    commit_paths init f.txt
    mutate_judge rev-unresolved "$TEST_TMP/mutant.py"

    cd "$REPO"
    run python3 "$SCRIPT" --rev no-such-rev f.txt
    [[ "$output" == *"を commit に解決できない"* ]]
    [[ "$output" != *"行数:"* ]]
    run python3 "$TEST_TMP/mutant.py" --rev no-such-rev f.txt
    [[ "$output" != *"を commit に解決できない"* ]]
    [[ "$output" == *"行数:"* ]]
}

@test "変異: byte 一致優先の判定(judge:prefer-byte-match)を外すと挿入した空行を行末変化と誤認する" {
    printf 'a\nb\nc\n\r\nz\r\n' > "$REPO/f.txt"
    commit_paths init f.txt
    printf 'a\nb\nc\n\nnew1\n\nnew2\n\r\nz\r\n' > "$REPO/f.txt"
    mutate_judge prefer-byte-match "$TEST_TMP/mutant.py"

    cd "$REPO"
    run python3 "$SCRIPT" f.txt
    [ "$status" -eq 0 ]
    run python3 "$TEST_TMP/mutant.py" f.txt
    [ "$status" -eq 1 ]
    [[ "$output" == *"行4(参照 行4): CRLF→LF"* ]]
}

@test "変異: 対応行数の判定(judge:keep-matched-lines)を外すと行を減らして行末変化を見逃す" {
    printf '*.txt text eol=lf\n' > "$REPO/.gitattributes"
    printf 'A\nB\n' > "$REPO/f.txt"
    commit_paths init .gitattributes f.txt
    printf 'A\r\nB\nA\n' > "$REPO/f.txt"
    mutate_judge keep-matched-lines "$TEST_TMP/mutant.py"

    cd "$REPO"
    run python3 "$SCRIPT" f.txt
    [ "$status" -eq 1 ]
    run python3 "$TEST_TMP/mutant.py" f.txt
    [ "$status" -eq 0 ]
}
