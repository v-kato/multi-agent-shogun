#!/usr/bin/env bats
# test_check_tracked.bats — scripts/check_tracked.sh の単体試験 (cmd_788 Phase 1a)。
#
# ★ライブリポジトリの中身には依存しない。隔離 git repo を mktemp -d 配下に作り、
#   このリポジトリと同じ「全部除外して許可行で戻す」ホワイトリスト方式の .gitignore を
#   その中に置いて判定を確かめる。
# ★後始末の rm は書かない。mktemp -d は試験ファイルごとに1回(setup_file)だけ作り、
#   各試験はその下の専用サブディレクトリを使う。
# ★変異試験: 判定を壊した script の複製を作り、対応する probe が失敗することを確かめる。
#   probe は「正しい script では成功し、壊した script では失敗する」ように書いてある。

setup_file() {
    export T_ROOT
    T_ROOT="$(mktemp -d)"
}

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CHK="$PROJECT_ROOT/scripts/check_tracked.sh"
    T="$T_ROOT/t${BATS_TEST_NUMBER}"
    mkdir -p "$T"
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    PROBE_N=0
}

# ---------------------------------------------------------------- helpers
mkrepo() { # [$1 = 名前] → ホワイトリスト方式の隔離 git repo(.gitignore と ok.sh だけ commit 済み)を REPO に作る
    REPO="$T/${1:-repo}"
    mkdir -p "$REPO"
    git -C "$REPO" init -q -b main
    git -C "$REPO" config user.email tester@example.invalid
    git -C "$REPO" config user.name tester
    git -C "$REPO" config commit.gpgsign false
    git -C "$REPO" config core.hooksPath /dev/null
    printf '*\n!*/\n!.gitignore\n!scripts/ok.sh\n' >"$REPO/.gitignore"
    mkdir -p "$REPO/scripts"
    printf 'ok\n' >"$REPO/scripts/ok.sh"
    git -C "$REPO" add -- .gitignore scripts/ok.sh
    git -C "$REPO" commit -q -m init
}

put() { # $1=相対path $2=内容
    mkdir -p "$(dirname "$REPO/$1")"
    printf '%s\n' "$2" >"$REPO/$1"
}

chk() { (cd "$REPO" && bash "$CHK" "$@"); }

has() {
    [[ "$output" == *"$1"* ]] || {
        echo "期待する出力が無い: $1"
        echo "--- 実出力 ---"
        echo "$output"
        return 1
    }
}
hasnt() {
    [[ "$output" != *"$1"* ]] || {
        echo "含まれてはならない出力がある: $1"
        echo "--- 実出力 ---"
        echo "$output"
        return 1
    }
}

# git の shim。$T/shim.log へサブコマンド名を記録し、GIT_SHIM_FAIL が指すサブコマンドは rc=128 で失敗させる。
# GIT_SHIM_FAIL_ARG も指定すると、その引数(例 --verify)を含む呼び出しだけを失敗させる
# (rev-parse は最初の --is-inside-work-tree 判定にも使われるため、HEAD 確認だけを狙い撃つのに要る)。
make_shim() {
    local real_git
    real_git="$(command -v git)"
    mkdir -p "$T/shim"
    cat >"$T/shim/git" <<EOF
#!/usr/bin/env bash
sub=""; skip=0
for a in "\$@"; do
    if [ "\$skip" = 1 ]; then skip=0; continue; fi
    case "\$a" in -c|-C) skip=1 ;; -*) ;; *) sub="\$a"; break ;; esac
done
printf '%s\n' "\$sub" >> "$T/shim.log"
if [ -n "\${GIT_SHIM_FAIL:-}" ] && [ "\$sub" = "\$GIT_SHIM_FAIL" ]; then
    hit=1
    if [ -n "\${GIT_SHIM_FAIL_ARG:-}" ]; then
        hit=0
        for a in "\$@"; do [ "\$a" = "\$GIT_SHIM_FAIL_ARG" ] && hit=1; done
    fi
    if [ "\$hit" = 1 ]; then
        echo "shim: forced failure of \$sub" >&2
        exit 128
    fi
fi
exec "$real_git" "\$@"
EOF
    chmod +x "$T/shim/git"
    : >"$T/shim.log"
}

# ---------------------------------------------------------------- 判定の基本
@test "追跡済み(commit 済み)は COMMITTED・exit 0" {
    mkrepo
    run chk scripts/ok.sh
    [ "$status" -eq 0 ]
    has "COMMITTED scripts/ok.sh"
    has "判定: OK"
}

@test "ホワイトリストに載っていない新規ファイルは IGNORED・exit 1(効いている規則を表示する)" {
    mkrepo
    put scripts/new.sh "new"
    run chk scripts/new.sh
    [ "$status" -eq 1 ]
    has "IGNORED   scripts/new.sh"
    has "規則: .gitignore:1:*"
    has "判定: NG(1 件)"
}

@test "許可行を足せば IGNORED でなく UNTRACKED になり、add すれば STAGED、commit すれば COMMITTED" {
    mkrepo
    put scripts/new.sh "new"
    printf '!scripts/new.sh\n' >>"$REPO/.gitignore"
    run chk scripts/new.sh
    [ "$status" -eq 0 ]
    has "UNTRACKED scripts/new.sh"
    git -C "$REPO" add -- scripts/new.sh
    run chk scripts/new.sh
    [ "$status" -eq 0 ]
    has "STAGED    scripts/new.sh"
    has "status: A  scripts/new.sh"
    git -C "$REPO" commit -q -m add
    run chk scripts/new.sh
    [ "$status" -eq 0 ]
    has "COMMITTED scripts/new.sh"
}

@test "回帰: 許可行(否定パターン)で再包含したファイルを IGNORED と誤判定しない(check-ignore -v は否定パターンでも exit 0)" {
    mkrepo
    put scripts/new.sh "new"
    printf '!scripts/new.sh\n' >>"$REPO/.gitignore"
    # 前提: -v は否定パターンに一致しても exit 0 でパターンを表示する(これが誤判定の原因だった)
    run bash -c 'cd "$1" && git check-ignore -v -- scripts/new.sh' _ "$REPO"
    [ "$status" -eq 0 ]
    has "!scripts/new.sh"
    run chk scripts/new.sh
    [ "$status" -eq 0 ]
    has "UNTRACKED scripts/new.sh"
    hasnt "IGNORED   scripts/new.sh"
}

@test "存在しない path は MISSING・exit 1(ignore 規則に該当しても綴り誤りとして MISSING)" {
    mkrepo
    run chk scripts/typo.sh
    [ "$status" -eq 1 ]
    has "MISSING   scripts/typo.sh"
    hasnt "IGNORED   scripts/typo.sh"
}

@test "--require-committed: UNTRACKED と STAGED を NG にする(付けなければ OK)" {
    mkrepo
    put scripts/new.sh "new"
    printf '!scripts/new.sh\n' >>"$REPO/.gitignore"
    run chk scripts/new.sh
    [ "$status" -eq 0 ]
    run chk --require-committed scripts/new.sh
    [ "$status" -eq 1 ]
    git -C "$REPO" add -- scripts/new.sh
    run chk --require-committed scripts/new.sh
    [ "$status" -eq 1 ]
    has "STAGED    scripts/new.sh"
    git -C "$REPO" commit -q -m add
    run chk --require-committed scripts/new.sh
    [ "$status" -eq 0 ]
}

@test "複数 path の混在: 状態ごとの件数を出し、1件でも NG なら exit 1" {
    mkrepo
    put scripts/new.sh "new"
    put docs/d.md "doc"
    run chk scripts/ok.sh scripts/new.sh docs/d.md scripts/none.sh
    [ "$status" -eq 1 ]
    has "合計: COMMITTED 1 / STAGED 0 / UNTRACKED 0 / IGNORED 2 / MISSING 1"
    has "判定: NG(3 件)"
}

@test "追跡済みなら ignore 規則に該当していても COMMITTED(force add した実ファイル)" {
    mkrepo
    put scripts/forced.sh "forced"
    git -C "$REPO" add -f -- scripts/forced.sh
    git -C "$REPO" commit -q -m forced
    run chk scripts/forced.sh
    [ "$status" -eq 0 ]
    has "COMMITTED scripts/forced.sh"
}

@test "ディレクトリ: 配下を1本ずつ判定し、COMMITTED 以外だけ表示してディレクトリごとの件数を添える" {
    mkrepo
    put scripts/a.sh "a"
    put scripts/b.sh "b"
    run chk scripts
    [ "$status" -eq 1 ]
    has "IGNORED   scripts/a.sh"
    has "IGNORED   scripts/b.sh"
    hasnt "COMMITTED scripts/ok.sh"
    has "DIR       scripts  (COMMITTED 1 / それ以外 2)"
    has "合計: COMMITTED 1 / STAGED 0 / UNTRACKED 0 / IGNORED 2 / MISSING 0"
}

@test "名前に glob 文字・空白・コロンを含むファイルを literal に扱う" {
    mkrepo
    put 'scripts/a[1].sh' "bracket"
    put 'scripts/sp ace.sh' "space"
    put 'scripts/co:lon.sh' "colon"
    printf '!scripts/a[[]1].sh\n!scripts/sp ace.sh\n!scripts/co:lon.sh\n' >>"$REPO/.gitignore"
    git -C "$REPO" add -f -- ':(literal)scripts/a[1].sh'
    run chk 'scripts/a[1].sh' 'scripts/sp ace.sh' 'scripts/co:lon.sh'
    [ "$status" -eq 0 ]
    has "STAGED    scripts/a[1].sh"
    has "UNTRACKED scripts/sp ace.sh"
    has "UNTRACKED scripts/co:lon.sh"
    # glob として解釈されるなら a[1].sh は「a1.sh」に一致してしまう。実在しない a1.sh は MISSING のまま
    run chk 'scripts/a1.sh'
    [ "$status" -eq 1 ]
    has "MISSING   scripts/a1.sh"
}

@test "サブディレクトリから走らせても相対 path で判定できる" {
    mkrepo
    put scripts/new.sh "new"
    run bash -c 'cd "$1/scripts" && bash "$2" ok.sh new.sh' _ "$REPO" "$CHK"
    [ "$status" -eq 1 ]
    has "COMMITTED ok.sh"
    has "IGNORED   new.sh"
}

@test "HEAD の無い(commit 前の)リポジトリでも動く: add 済みは STAGED" {
    REPO="$T/unborn"
    mkdir -p "$REPO"
    git -C "$REPO" init -q -b main
    printf 'x\n' >"$REPO/f.txt"
    git -C "$REPO" add -- f.txt
    run chk f.txt
    [ "$status" -eq 0 ]
    has "STAGED    f.txt"
}

@test "HEAD の無いリポジトリの判定は HEAD 確認の終了コード 1 に基づく(実 git で 1 を確かめ、それを「HEADなし」として扱う)" {
    REPO="$T/unborn_rc"
    mkdir -p "$REPO"
    git -C "$REPO" init -q -b main
    run bash -c 'cd "$1" && git rev-parse --verify --quiet HEAD' _ "$REPO"
    [ "$status" -eq 1 ]
    printf 'x\n' >"$REPO/f.txt"
    git -C "$REPO" add -- f.txt
    run chk f.txt
    [ "$status" -eq 0 ]
    has "STAGED    f.txt"
    hasnt "判定不能"
}

# ---------------------------------------------------------------- 使い方誤り・fail-closed
@test "使い方誤り: path 無し・未知のオプションは exit 2、-h は exit 0。リポジトリ外は exit 2" {
    mkrepo
    run chk
    [ "$status" -eq 2 ]
    has "path を1つ以上"
    run chk --no-such-option scripts/ok.sh
    [ "$status" -eq 2 ]
    run bash "$CHK" -h
    [ "$status" -eq 0 ]
    has "Usage:"
    mkdir -p "$T/notrepo"
    run bash -c 'cd "$1" && bash "$2" some.txt' _ "$T/notrepo" "$CHK"
    [ "$status" -eq 2 ]
    has "git リポジトリの中で"
}

@test "fail-closed: git check-ignore が失敗したら、黙って UNTRACKED にせず exit 2(判定不能)" {
    mkrepo
    put scripts/new.sh "new"
    make_shim
    run bash -c 'cd "$1" && PATH="$2:$PATH" GIT_SHIM_FAIL=check-ignore bash "$3" scripts/new.sh' _ "$REPO" "$T/shim" "$CHK"
    [ "$status" -eq 2 ]
    has "git check-ignore が判定不能"
    hasnt "UNTRACKED"
}

@test "fail-closed: git ls-files が失敗したら exit 2(判定不能)" {
    mkrepo
    make_shim
    run bash -c 'cd "$1" && PATH="$2:$PATH" GIT_SHIM_FAIL=ls-files bash "$3" scripts/ok.sh' _ "$REPO" "$T/shim" "$CHK"
    [ "$status" -eq 2 ]
    has "git ls-files が判定不能"
}

@test "fail-closed(G788-R02): HEAD 確認(rev-parse --verify)だけが exit 128 で失敗したら、HEAD なし扱いにせず exit 2" {
    mkrepo
    make_shim
    # 前提: shim は --is-inside-work-tree 判定(rev-parse)を通し、--verify の呼び出しだけを 128 で失敗させる。
    run bash -c 'cd "$1" && PATH="$2:$PATH" GIT_SHIM_FAIL=rev-parse GIT_SHIM_FAIL_ARG=--verify bash "$3" scripts/ok.sh' _ "$REPO" "$T/shim" "$CHK"
    [ "$status" -eq 2 ]
    has "git rev-parse HEAD が判定不能(exit 128)"
    # commit 済みの対象を STAGED と表示したり、OK と判定したりしていない
    hasnt "STAGED"
    hasnt "COMMITTED"
    hasnt "判定: OK"
    # 対照: 同じ shim でも失敗を注入しなければ(rev-parse --verify が実 git へ渡れば)COMMITTED と判定される
    run bash -c 'cd "$1" && PATH="$2:$PATH" bash "$3" scripts/ok.sh' _ "$REPO" "$T/shim" "$CHK"
    [ "$status" -eq 0 ]
    has "COMMITTED scripts/ok.sh"
}

# ---------------------------------------------------------------- 読取専用
@test "読取専用: git の書込系サブコマンドを呼ばず、.git の中身が1バイトも変わらない" {
    mkrepo
    put scripts/new.sh "new"
    put scripts/staged.sh "staged"
    git -C "$REPO" add -f -- scripts/staged.sh
    make_shim
    local before after
    before="$(cd "$REPO/.git" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)"
    run bash -c 'cd "$1" && PATH="$2:$PATH" bash "$3" scripts/ok.sh scripts/new.sh scripts/staged.sh scripts docs/none.md' _ "$REPO" "$T/shim" "$CHK"
    [ "$status" -eq 1 ]
    after="$(cd "$REPO/.git" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)"
    [ "$before" = "$after" ]
    [ -s "$T/shim.log" ]
    local sub
    while IFS= read -r sub; do
        case "$sub" in
            rev-parse | ls-files | ls-tree | check-ignore | status) ;;
            *)
                echo "許可外の git サブコマンド: $sub"
                return 1
                ;;
        esac
    done <"$T/shim.log"
    local need
    for need in ls-files ls-tree check-ignore status; do
        /usr/bin/grep -q "^${need}\$" "$T/shim.log" || {
            echo "shim を経由していない git サブコマンド: $need"
            return 1
        }
    done
}

# ---------------------------------------------------------------- 変異試験
# probe は「正しい script なら 0(成功)、壊した script なら非0」を返す。

_probe_repo() { PROBE_N=$((PROBE_N + 1)); mkrepo "p${PROBE_N}"; }
_run_in() { # $1=script $2...=引数 → P_RC / P_OUT
    local s="$1"
    shift
    P_RC=0
    P_OUT="$(cd "$REPO" && bash "$s" "$@" 2>&1)" || P_RC=$?
}

probe_ignored_is_ng() {
    _probe_repo
    put scripts/new.sh "new"
    _run_in "$1" scripts/new.sh
    [ "$P_RC" -eq 1 ] && [[ "$P_OUT" == *"IGNORED   scripts/new.sh"* ]]
}
probe_missing_is_ng() {
    _probe_repo
    _run_in "$1" scripts/nothing.sh
    [ "$P_RC" -eq 1 ]
}
probe_committed_is_ok() {
    _probe_repo
    _run_in "$1" scripts/ok.sh
    [ "$P_RC" -eq 0 ] && [[ "$P_OUT" == *"COMMITTED scripts/ok.sh"* ]]
}
probe_require_committed() {
    _probe_repo
    put scripts/new.sh "new"
    printf '!scripts/new.sh\n' >>"$REPO/.gitignore"
    _run_in "$1" --require-committed scripts/new.sh
    [ "$P_RC" -eq 1 ]
}
probe_ignore_check_failure_not_swallowed() {
    _probe_repo
    put scripts/new.sh "new"
    make_shim
    P_RC=0
    P_OUT="$(cd "$REPO" && PATH="$T/shim:$PATH" GIT_SHIM_FAIL=check-ignore bash "$1" scripts/new.sh 2>&1)" || P_RC=$?
    [ "$P_RC" -eq 2 ]
}
probe_head_check_failure_not_swallowed() {
    _probe_repo
    make_shim
    P_RC=0
    P_OUT="$(cd "$REPO" && PATH="$T/shim:$PATH" GIT_SHIM_FAIL=rev-parse GIT_SHIM_FAIL_ARG=--verify bash "$1" scripts/ok.sh 2>&1)" || P_RC=$?
    [ "$P_RC" -eq 2 ] && [[ "$P_OUT" != *"STAGED"* ]]
}
probe_unborn_head_is_normal() {
    _probe_repo
    local u="$T/unborn_probe${PROBE_N}"
    mkdir -p "$u"
    git -C "$u" init -q -b main
    printf 'x\n' >"$u/f.txt"
    git -C "$u" add -- f.txt
    P_RC=0
    P_OUT="$(cd "$u" && bash "$1" f.txt 2>&1)" || P_RC=$?
    [ "$P_RC" -eq 0 ] && [[ "$P_OUT" == *"STAGED    f.txt"* ]]
}
probe_staged_vs_committed() {
    _probe_repo
    put scripts/new.sh "new"
    printf '!scripts/new.sh\n' >>"$REPO/.gitignore"
    git -C "$REPO" add -- scripts/new.sh
    _run_in "$1" scripts/new.sh
    [[ "$P_OUT" == *"STAGED    scripts/new.sh"* ]]
}

# $1=probe 名 $2=sed 式(壊し方)
assert_mutation_caught() {
    local probe="$1" expr="$2" mut
    "$probe" "$CHK" || {
        echo "probe ${probe} が正しい script で失敗する(probe 自体の誤り)"
        return 1
    }
    mkdir -p "$T/mut"
    mut="$T/mut/${probe}.sh"
    sed -E "$expr" "$CHK" >"$mut"
    if cmp -s "$CHK" "$mut"; then
        echo "変異が適用されていない(sed 式が script に当たらない): ${expr}"
        return 1
    fi
    if "$probe" "$mut"; then
        echo "変異を検出できなかった: probe ${probe} が壊した script でも成功した(${expr})"
        return 1
    fi
}

@test "変異試験: IGNORED を NG に数えないと、無視されたファイルが素通りする" {
    assert_mutation_caught probe_ignored_is_ng 's/^        IGNORED \| MISSING\) N_NG=/        MISSING) N_NG=/'
}
@test "変異試験: MISSING を NG に数えないと、綴り誤りが素通りする" {
    assert_mutation_caught probe_missing_is_ng 's/^        IGNORED \| MISSING\) N_NG=/        IGNORED) N_NG=/'
}
@test "変異試験: 追跡済み(index にある)判定を壊すと COMMITTED を返せなくなる" {
    assert_mutation_caught probe_committed_is_ok 's/if \[\[ -n "\$head_hit" \]\]; then STATE="COMMITTED"; else STATE="STAGED"; fi/STATE="STAGED"/'
}
@test "変異試験: --require-committed の NG 加算を外すと未commitが通る" {
    assert_mutation_caught probe_require_committed 's/if \[\[ "\$REQUIRE_COMMITTED" -eq 1 \]\]; then N_NG=\$\(\(N_NG \+ 1\)\); fi/:/'
}
@test "変異試験: check-ignore の失敗を握りつぶすと、判定不能が UNTRACKED として通る" {
    assert_mutation_caught probe_ignore_check_failure_not_swallowed 's/^                    \*\) die "git check-ignore が判定不能.*$/                    *) STATE="UNTRACKED" ;;/'
}
@test "変異試験: HEAD 確認の失敗(0/1 以外)を握りつぶすと、実行失敗が「HEADなし」として通る" {
    assert_mutation_caught probe_head_check_failure_not_swallowed 's/^    \*\) die "git rev-parse HEAD が判定不能.*$/    *) ;;/'
}
@test "変異試験: HEAD 確認の終了コード 1(正常な HEAD なし)まで判定不能にすると、未commitの新規 repo が使えなくなる" {
    assert_mutation_caught probe_unborn_head_is_normal 's/^    1\) ;;$/    1) die "mutant: HEADなしを判定不能にした" ;;/'
}
@test "変異試験: HEAD 照合(ls-tree)を外すと commit 済みと STAGED を区別できない" {
    assert_mutation_caught probe_staged_vs_committed 's/head_hit="\$\(git ls-tree --name-only HEAD -- "\$p"\)" \|\| die "git ls-tree HEAD に失敗した: \$p"/head_hit="x"/'
}
