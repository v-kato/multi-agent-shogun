#!/usr/bin/env bats
# test_public_repo_scan.bats — scripts/public_repo_scan.sh の単体試験 (cmd_788 Phase 1a)。
#
# ★ライブリポジトリの中身には依存しない。隔離 git repo を mktemp -d 配下に作り、その中で
#   走査する(実リポジトリの index・HEAD・作業木には触れない)。
# ★公開側の正本(instructions/common/public_repo_forbidden_words.md)は cmd_797 以降、具体語を持たない
#   番兵1行のみ。具体語は git 管理外のローカル拡張だけが持つので、この試験は実ローカル拡張
#   (config/public_repo_forbidden_words.local.txt)に依存しない。実 md を使う試験は、旧・基本語18語を
#   実行時に組み立てた試験用拡張(REALEXT)と組み合わせて走査する。
# ★禁則語の陽性対照は、語を実行時に断片から組み立てる。この試験ファイル自身が禁則語を
#   含まないことは「自己走査」の試験で確かめている(除外されるのは正本リスト1本のみ)。
# ★後始末の rm は書かない。mktemp -d は試験ファイルごとに1回(setup_file)だけ作り、
#   各試験はその下の専用サブディレクトリを使う(/tmp の残骸は再起動で消える)。
# ★変異試験: 検出を壊した script の複製を作り、対応する probe が失敗することを確かめる。
#   probe は「正しい script では成功し、壊した script では失敗する」ように書いてある。

setup_file() {
    export T_ROOT
    T_ROOT="$(mktemp -d)"
}

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCAN="$PROJECT_ROOT/scripts/public_repo_scan.sh"
    WORDS_REAL="$PROJECT_ROOT/instructions/common/public_repo_forbidden_words.md"
    T="$T_ROOT/t${BATS_TEST_NUMBER}"
    mkdir -p "$T"
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    SELF="instructions/common/public_repo_forbidden_words.md"
    NOEXT="$T/no_such_ext.txt"
    PROBE_N=0
    write_words 'qzx-one|qzx-two'
    write_real_ext
}

# ---------------------------------------------------------------- helpers
write_words() { # $1 = 正規表現。fixture の正本リストを $T/words.md に作る
    WORDS="$T/words.md"
    printf '# fixture\n\n```forbidden-regex\n%s\n```\n' "$1" >"$WORDS"
}

mkrepo() { # [$1 = 名前] → 隔離 git repo を作り REPO に入れる
    REPO="$T/${1:-repo}"
    mkdir -p "$REPO"
    git -C "$REPO" init -q -b main
    git -C "$REPO" config user.email tester@example.invalid
    git -C "$REPO" config user.name tester
    git -C "$REPO" config commit.gpgsign false
    git -C "$REPO" config core.hooksPath /dev/null
}

put() { # $1=相対path $2=内容(末尾に改行を足す)
    mkdir -p "$(dirname "$REPO/$1")"
    printf '%s\n' "$2" >"$REPO/$1"
}

gadd() { git -C "$REPO" add -- "$@"; }
gcommit() { git -C "$REPO" commit -q -m "${1:-c}"; }

# 試験用拡張(旧・基本語18語)を $T/real_ext.txt に作る。語は実行時に断片から組み立てる
# (ソース上に語そのものは現れない)。TERM_PAIRS・term は下で定義(試験の実行時には定義済み)。
write_real_ext() {
    REALEXT="$T/real_ext.txt"
    local pair a b
    : >"$REALEXT"
    for pair in "${TERM_PAIRS[@]}"; do
        IFS='|' read -r a b <<<"$pair"
        printf '%s\n' "$(term "$a" "$b")" >>"$REALEXT"
    done
}

# script の番兵(正本の forbidden-regex 行と一字一句同じ)を script から取り出す(試験に綴りを書かない)
sentinel_of_script() { sed -n "s/^SENTINEL_REGEX='\(.*\)'\$/\1/p" "$SCAN"; }

# fixture の正本リストで走査する(ローカル拡張は無し)
scanf() { (cd "$REPO" && bash "$SCAN" --words-file "$WORDS" --local-ext "$NOEXT" "$@"); }
# 実際の正本(番兵のみ)+試験用拡張(旧・基本語18語)で走査する
scanr() { (cd "$REPO" && bash "$SCAN" --local-ext "$REALEXT" "$@"); }
# 実際の正本(番兵のみ)・ローカル拡張は無し(fail-closed の対象)
scanr0() { (cd "$REPO" && bash "$SCAN" --local-ext "$NOEXT" "$@"); }

has() { # 出力に部分文字列が含まれること
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

# 既知の禁則語を実行時に組み立てる(断片の連結。ソース上に語そのものは現れない)
term() { printf '%s%s' "$1" "$2"; }
# メールアドレスも実行時に組み立てる(ソース上に非許可ドメインのアドレスを置かない)
mail() { printf '%s@%s' "$1" "$2"; }
TERM_PAIRS=(
    "tl|c" "tl|c-cms" "poke|mon" "ポケ|モン" "v-|sync" "matching |table" "content|matching"
    "data|studio" "ロジ|スコ" "紙|袋" "paper|bag" "出荷|依頼" "海老|名" "ピカ|チュウ"
    "イー|ブイ" "big|query" "tl|c-data" "kato|@"
)

# ---------------------------------------------------------------- A. 陽性対照・0件
@test "陽性対照: 公開側の正本は番兵のみで具体語を持たず、拡張に置いた全18語(許容にした /home/kato は含まない)を1語ずつ検出する" {
    local re pair a b i=0 lines=""
    re="$(awk '/^```forbidden-regex/{f=1;next} /^```/{f=0} f' "$WORDS_REAL")"
    [ -n "$re" ]
    # 公開側は番兵1行: script の番兵と一字一句同じ
    [ "$re" = "$(sentinel_of_script)" ]
    for pair in "${TERM_PAIRS[@]}"; do
        IFS='|' read -r a b <<<"$pair"
        i=$((i + 1))
        # 公開側の正規表現は、どの具体語にも一致しない(=公開側に具体語が残っていない)
        if printf '%s' "$(term "$a" "$b")" | /usr/bin/grep -q -i -E -e "$re"; then
            echo "公開側に具体語が残っている(組立): 番号 $i"
            return 1
        fi
        lines+="L${i} $(term "$a" "$b")"$'\n'
    done
    [ "$i" -eq 18 ]
    mkrepo
    printf '%s' "$lines" >"$REPO/f.txt"
    gadd f.txt
    run scanr --staged
    [ "$status" -eq 1 ]
    has "合計: 18 行 / 1 ファイル"
    for ((i = 1; i <= 18; i++)); do has "f.txt:${i}: L${i} "; done
}

@test "陽性対照: 大文字・混在表記も検出する(大小無視)" {
    mkrepo
    put f.txt "$(term TL C) $(term Poke MON) $(term BIG QUERY)"
    gadd f.txt
    run scanr --staged
    [ "$status" -eq 1 ]
    has "合計: 1 行 / 1 ファイル"
}

@test "0件: 禁則語が無ければ exit 0・「ヒットなし」・走査規模(0行ではない)を出す" {
    mkrepo
    put docs/a.md "ただの文書 $(term sha 256) の話"
    put r.txt "clean"
    gadd docs/a.md r.txt
    run scanr --staged
    [ "$status" -eq 0 ]
    has "判定: OK(禁則語 0 件)"
    has "(ヒットなし)"
    has "対象 2 行 / 2 ファイル"
    has "合計: 0 行 / 0 ファイル"
}

# ---------------------------------------------------------------- A2. 許容条件(殿確定 2026-09-30・G788-R01)
# 許容は3種: /home/kato・v-sync.co.jp のアドレス・cmd_xxx。実際の正本リストで確かめる(scanr)。

@test "許容(G788-R01): 公開側の正規表現(番兵)は /home/kato と cmd_xxx を含まない。社名(最低語)は拡張が保ち、許可ドメインのブロックは自社ドメインを含む" {
    local re
    re="$(awk '/^```forbidden-regex/{f=1;next} /^```/{f=0} f' "$WORDS_REAL")"
    [ -n "$re" ]
    # 許容2種は禁則語ではない
    ! printf '%s\n' "cd /home/kato/project" | /usr/bin/grep -q -i -E -e "$re"
    ! printf '%s\n' "cmd_788 cmd_xxx" | /usr/bin/grep -q -i -E -e "$re"
    # 公開側は社名を持たない(番兵のみ)。社名は拡張だけが持ち、許可ドメインの除去より前の段階では検出される
    ! printf '%s\n' "$(term v- sync)" | /usr/bin/grep -q -i -E -e "$re"
    mkrepo
    put f.txt "$(term v- sync)"
    gadd f.txt
    run scanr --staged
    [ "$status" -eq 1 ]
    has "f.txt:1: $(term v- sync)"
    # 許可ドメインのブロックは1個・自社ドメインを含む
    [ "$(/usr/bin/grep -c '^```allowed-email-domains' "$WORDS_REAL")" -eq 1 ]
    awk '/^```allowed-email-domains/{f=1;next} /^```/{f=0} f' "$WORDS_REAL" | /usr/bin/grep -q -x 'v-sync.co.jp'
}

@test "許容3種(G788-R01): home path・v-sync.co.jp のアドレス・cmd_xxx は、それぞれ単独の行でも exit 0・0件" {
    mkrepo
    put a.txt "cd /home/kato/project"
    put b.txt "連絡先 kato@v-sync.co.jp"
    put c.txt "詳細は cmd_788 と cmd_xxx を見よ"
    gadd a.txt b.txt c.txt
    run scanr --staged
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    has "対象 3 行 / 3 ファイル"
    has "合計: 0 行 / 0 ファイル"
    has "判定: OK(禁則語 0 件)"
    has "(ヒットなし)"
}

@test "許容(G788-R01): 許可ドメインの表記は前後の記号・文末の句点・大小・URL のホスト・日本語の隣でも除去される" {
    mkrepo
    put f.txt "$(printf '%s\n' \
        '<kato@v-sync.co.jp>' \
        'mailto:info@v-sync.co.jp?subject=x' \
        'kato@V-Sync.CO.JP.' \
        'https://www.v-sync.co.jp/about' \
        'a@v-sync.co.jp, b@v-sync.co.jp, c@v-sync.co.jp' \
        'v-sync.co.jp v-sync.co.jp' \
        'kato@v-sync.co.jpの人' \
        '連絡はkato@v-sync.co.jpまで' \
        '"kato@v-sync.co.jp"' \
        'kato@v-sync.co.jp と kato@v-sync.co.jp' \
        'https://v-sync.co.jp/ kato@v-sync.co.jp' \
        'kato@v-sync.co.jp https://v-sync.co.jp/')"
    gadd f.txt
    run scanr --staged
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    has "対象 12 行 / 1 ファイル"
    has "合計: 0 行 / 0 ファイル"
}

@test "許容と禁止が同一行に混在した行は検出される(許可の除去が禁止語まで消さない・G788-R01)" {
    mkrepo
    put f.txt "$(printf '%s\n' \
        "kato@v-sync.co.jp $(term tl c-cms)" \
        "$(term tl c-cms) kato@v-sync.co.jp" \
        "/home/kato/$(term poke mon)/x" \
        "$(term v- sync)-jp/repo kato@v-sync.co.jp" \
        "x@$(term tl c).v-sync.co.jp" \
        "$(term poke mon)-team@v-sync.co.jp" \
        "kato@v-sync.co.jp$(term 紙 袋)" \
        "a@$(term v- sync).co.jp.evil.example" \
        "x$(term v- sync).co.jp" \
        "許容だけの行 kato@v-sync.co.jp /home/kato cmd_788")"
    gadd f.txt
    run scanr --staged
    [ "$status" -eq 1 ]
    has "合計: 9 行 / 1 ファイル"
    local i
    for i in 1 2 3 4 5 6 7 8 9; do has "f.txt:${i}: "; done
    hasnt "f.txt:10: "
    # 同じ行が --tree(git grep の候補→除去後の再照合)でも同じ結果になる
    gcommit c1
    run scanr --tree HEAD
    [ "$status" -eq 1 ]
    has "合計: 9 行 / 1 ファイル"
    hasnt "f.txt:10: "
    # message でも同じ
    printf 'cmd_788: kato@v-sync.co.jp と /home/kato\n%s kato@v-sync.co.jp\n' "$(term tl c-cms)" >"$T/m.txt"
    run scanr --message-file "$T/m.txt"
    [ "$status" -eq 1 ]
    has "合計: 1 行 / 1 ファイル"
    has "message-file:2: "
}

@test "許容(G788-R01): ローカル拡張の語は、許可ドメインと同じ行にあっても検出する" {
    mkrepo
    put f.txt "zzy-local-only kato@v-sync.co.jp"
    gadd f.txt
    printf 'zzy-local-only\n' >"$T/ext.txt"
    run bash -c 'cd "$1" && bash "$2" --local-ext "$3" --staged' _ "$REPO" "$SCAN" "$T/ext.txt"
    [ "$status" -eq 1 ]
    has "f.txt:1: zzy-local-only kato@v-sync.co.jp"
}

@test "許容(G788-R01): 許可表記は --staged・--range(追加行と message)・--tree・--message-file のどれでも0件" {
    mkrepo
    put base.txt "base"
    gadd base.txt
    gcommit c0
    local base
    base="$(git -C "$REPO" rev-parse HEAD)"
    put d/f.txt $'cd /home/kato/x\nkato@v-sync.co.jp\ncmd_788'
    gadd d/f.txt
    git -C "$REPO" commit -q -m "cmd_788: kato@v-sync.co.jp が author の変更"
    put e/g.txt "kato@v-sync.co.jp"
    gadd e/g.txt
    printf 'cmd_788 kato@v-sync.co.jp /home/kato\n' >"$T/m.txt"
    run scanr --staged --range "${base}..HEAD" --tree HEAD --message-file "$T/m.txt"
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    has "合計: 0 行 / 0 ファイル"
    has "1 commit / "
}

@test "許容(G788-R01): 個人識別子(メールの局部)は許可ドメイン宛以外なら引き続き検出する。許可ドメイン宛は通る" {
    mkrepo
    put f.txt "$(mail kato corp.test)"
    gadd f.txt
    run scanr --staged
    [ "$status" -eq 1 ]
    has "f.txt:1: $(mail kato corp.test)"
    put g.txt "$(mail kato example.invalid) と $(mail kato v-sync.co.jp)"
    gadd g.txt
    git -C "$REPO" reset -q -- f.txt
    run scanr --staged
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    has "合計: 0 行 / 0 ファイル"
}

# ---------------------------------------------------------------- A3. 要確認(WARN)= 許可ドメイン外のメールアドレス
@test "要確認(WARN): 許可ドメイン外のメールアドレスは exit 0 のまま別出力する(件数・ディレクトリ別つき・NG にしない)" {
    mkrepo
    put docs/a.md "連絡先 $(mail person corp.test) まで"
    put src/b.md "clean"
    gadd docs src
    run scanr --staged
    [ "$status" -eq 0 ]
    has "判定: OK(禁則語 0 件)"
    has "合計: 0 行 / 0 ファイル"
    has "要確認(WARN・許可ドメイン外のメールアドレス): 1 件 / 1 ファイル"
    has "docs/a.md:1: $(mail person corp.test)"
    has "--- 要確認のディレクトリ別件数"
    has $'docs\t1\t1'
    hasnt $'src\t'
}

@test "要確認(WARN): 許可リストのドメインは WARN にしない(大小無視・完全一致。サブドメインは別・バージョン表記は対象外)" {
    mkrepo
    put f.txt "$(printf '%s\n' \
        "$(mail a example.com)" \
        "$(mail b EXAMPLE.ORG)" \
        "tester@example.invalid" \
        "noreply@github.com" \
        "1234+name@users.noreply.github.com" \
        "Co-Authored-By: Claude <noreply@anthropic.com>" \
        "kato@v-sync.co.jp" \
        "pkg@1.2.3 と user@host" \
        "$(mail x mail.example.com)")"
    gadd f.txt
    run scanr --staged
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    has "要確認(WARN・許可ドメイン外のメールアドレス): 1 件 / 1 ファイル"
    has "f.txt:9: $(mail x mail.example.com)"
}

@test "要確認(WARN): 禁則語のヒットと併存する(exit 1・ヒットと WARN の両方を出す)" {
    mkrepo
    put f.txt "$(term tl c-cms) $(mail person corp.test)"
    gadd f.txt
    run scanr --staged
    [ "$status" -eq 1 ]
    has "判定: NG(禁則語あり)"
    has "合計: 1 行 / 1 ファイル"
    has "要確認(WARN・許可ドメイン外のメールアドレス): 1 件 / 1 ファイル"
}

@test "要確認(WARN): 1行に複数あれば1つずつ数え、0 件でも件数の行は必ず出す" {
    mkrepo
    put f.txt "$(mail a corp.test) と $(mail b other.test) と $(mail a corp.test)"
    gadd f.txt
    run scanr --staged
    [ "$status" -eq 0 ]
    has "要確認(WARN・許可ドメイン外のメールアドレス): 3 件 / 1 ファイル"
    put g.txt "clean"
    run scanr --message-file "$REPO/g.txt"
    [ "$status" -eq 0 ]
    has "要確認(WARN・許可ドメイン外のメールアドレス): 0 件 / 0 ファイル"
    hasnt "--- 要確認(WARN)"
}

@test "要確認(WARN): --message-file・--range(追加行と commit message)・--tree でも拾う" {
    mkrepo
    put base.txt "base"
    gadd base.txt
    gcommit c0
    local base
    base="$(git -C "$REPO" rev-parse HEAD)"
    put d/f.txt "追加行に $(mail person corp.test)"
    gadd d/f.txt
    git -C "$REPO" commit -q -m "題に $(mail person corp.test)"
    run scanr --range "${base}..HEAD"
    [ "$status" -eq 0 ]
    has "要確認(WARN・許可ドメイン外のメールアドレス): 2 件 / 2 ファイル"
    has $'(commit-message)\t1\t1'
    has $'d\t1\t1'
    run scanr --tree HEAD
    [ "$status" -eq 0 ]
    has "要確認(WARN・許可ドメイン外のメールアドレス): 1 件 / 1 ファイル"
    has "d/f.txt:1: $(mail person corp.test)"
    printf '本文に %s\n' "$(mail person corp.test)" >"$T/m.txt"
    run scanr --message-file "$T/m.txt"
    [ "$status" -eq 0 ]
    has "要確認(WARN・許可ドメイン外のメールアドレス): 1 件 / 1 ファイル"
    has "message-file:1: $(mail person corp.test)"
}

@test "許可ドメインの書式: 空行・# コメント・大文字・CRLF・前後の空白を許す。ブロックが無ければ全アドレスが要確認" {
    mkrepo
    put f.txt "$(mail a ok.example.test) と $(mail b other.example.test)"
    gadd f.txt
    printf '```forbidden-regex\nqzx-one\n```\n```allowed-email-domains\n# コメント\n\n  Ok.Example.Test  \r\n```\n' >"$T/wd.md"
    run bash -c 'cd "$1" && bash "$2" --words-file "$3" --local-ext "$4" --staged' _ "$REPO" "$SCAN" "$T/wd.md" "$NOEXT"
    [ "$status" -eq 0 ]
    has "許可ドメイン 1 件"
    has "要確認(WARN・許可ドメイン外のメールアドレス): 1 件 / 1 ファイル"
    has "f.txt:1: $(mail b other.example.test)"
    hasnt "$(mail a ok.example.test)"$'\n'
    printf '```forbidden-regex\nqzx-one\n```\n' >"$T/wn.md"
    run bash -c 'cd "$1" && bash "$2" --words-file "$3" --local-ext "$4" --staged' _ "$REPO" "$SCAN" "$T/wn.md" "$NOEXT"
    [ "$status" -eq 0 ]
    has "許可ドメイン 0 件"
    has "要確認(WARN・許可ドメイン外のメールアドレス): 2 件 / 1 ファイル"
}

@test "許可ドメインの書式: 不正なエントリ・ドット無し・2個目のブロックは exit 2(fail-closed)" {
    mkrepo
    put f.txt "clean"
    gadd f.txt
    local bad
    for bad in 'bad domain.com' 'nodot' '-a.com' 'a.com/x' 'a_b.com'; do
        printf '```forbidden-regex\nqzx-one\n```\n```allowed-email-domains\n%s\n```\n' "$bad" >"$T/wb.md"
        run bash -c 'cd "$1" && bash "$2" --words-file "$3" --local-ext "$4" --staged' _ "$REPO" "$SCAN" "$T/wb.md" "$NOEXT"
        [ "$status" -eq 2 ] || {
            echo "エントリ ${bad}: exit ${status}"
            return 1
        }
        has "許可ドメインの書式が不正"
    done
    printf '```forbidden-regex\nqzx-one\n```\n```allowed-email-domains\na.example.test\n```\n```allowed-email-domains\nb.example.test\n```\n' >"$T/w2b.md"
    run bash -c 'cd "$1" && bash "$2" --words-file "$3" --local-ext "$4" --staged' _ "$REPO" "$SCAN" "$T/w2b.md" "$NOEXT"
    [ "$status" -eq 2 ]
    has "allowed-email-domains ブロックが不正"
}

# ---------------------------------------------------------------- A4. git が引用した path(G788-R03)
@test "日本語 path(G788-R03): 引用形式で出る path も所属ディレクトリ(docs)で集計し、path を復号して表示する(--staged)" {
    mkrepo
    put "docs/日本語の文書.md" "qzx-one"
    gadd docs
    # 前提: 実 git は既定設定で、この path を八進エスケープの引用形式で出す(これを復号できないのが不具合だった)
    run bash -c 'cd "$1" && git diff -U0 --cached' _ "$REPO"
    [[ "$output" == *'+++ "b/docs/\346'* ]]
    run scanf --staged
    [ "$status" -eq 1 ]
    has $'docs\t1\t1'
    has "docs/日本語の文書.md:1: qzx-one"
    has "合計: 1 行 / 1 ファイル"
    hasnt '"b/'
}

@test "日本語 path(G788-R03): --range(同じ抽出処理)でも、所属ディレクトリで集計し、path を復号して表示する" {
    mkrepo
    put base.txt "base"
    gadd base.txt
    gcommit c0
    local base head7
    base="$(git -C "$REPO" rev-parse HEAD)"
    put "docs/日本語の文書.md" "qzx-one"
    gadd docs
    gcommit c1
    head7="$(git -C "$REPO" rev-parse --short=7 HEAD)"
    run bash -c 'cd "$1" && git log -1 -p -U0 --format=%H' _ "$REPO"
    [[ "$output" == *'+++ "b/docs/\346'* ]]
    run scanf --range "${base}..HEAD"
    [ "$status" -eq 1 ]
    has $'docs\t1\t1'
    has "${head7} docs/日本語の文書.md:1: qzx-one"
    hasnt '"b/'
}

@test "特殊な path(G788-R03): 二重引用符・タブ・空白・日本語を含む path も、すべて所属ディレクトリで集計する" {
    mkrepo
    put 'docs/a"b.md' "qzx-one"
    put $'docs/tab\there.md' "qzx-one"
    put 'docs/with space.md' "qzx-one"
    put 'docs/日本語.md' "qzx-one"
    put 'docs/バックスラッシュ\名.md' "qzx-one"
    gadd docs
    run scanf --staged
    [ "$status" -eq 1 ]
    has $'docs\t5\t5'
    has 'docs/a"b.md:1: qzx-one'
    has 'docs/tab?here.md:1: qzx-one'
    has 'docs/with space.md:1: qzx-one'
    has 'docs/日本語.md:1: qzx-one'
    has 'docs/バックスラッシュ\名.md:1: qzx-one'
    hasnt '"b/'
}

@test "diff の接頭辞設定(diff.mnemonicPrefix)に左右されない: 接頭辞を a/ b/ に固定して集計する" {
    mkrepo
    put docs/a.md "qzx-one"
    gadd docs
    printf '[diff]\n\tmnemonicPrefix = true\n' >"$T/gc_mn"
    # 前提: 設定を効かせると、素の git diff --cached は i/ 接頭辞で出す(script が固定しなければ「i」が区分になる)
    run bash -c 'cd "$1" && GIT_CONFIG_GLOBAL="$2" git diff -U0 --cached' _ "$REPO" "$T/gc_mn"
    [[ "$output" == *'+++ i/docs/a.md'* ]]
    run bash -c 'cd "$1" && GIT_CONFIG_GLOBAL="$2" bash "$3" --words-file "$4" --local-ext "$5" --staged' _ "$REPO" "$T/gc_mn" "$SCAN" "$WORDS" "$NOEXT"
    [ "$status" -eq 1 ]
    has $'docs\t1\t1'
    has "docs/a.md:1: qzx-one"
}

# ---------------------------------------------------------------- B. --staged
@test "--staged: 追加行のみが対象。commit 済みの既存行に語があっても、無関係な追加では0件" {
    mkrepo
    put f.txt $'keep\nqzx-one'
    gadd f.txt
    gcommit base
    printf 'clean addition\n' >>"$REPO/f.txt"
    gadd f.txt
    run scanf --staged
    [ "$status" -eq 0 ]
    has "対象 1 行"
}

@test "--staged: 削除した行の語は検出しない" {
    mkrepo
    put f.txt $'keep\nqzx-one'
    gadd f.txt
    gcommit base
    put f.txt "keep"
    gadd f.txt
    run scanf --staged
    [ "$status" -eq 0 ]
    has "対象 0 行"
}

@test "--staged: index に無い(作業木だけの)追加は対象外" {
    mkrepo
    put f.txt "keep"
    gadd f.txt
    gcommit base
    printf 'qzx-one only in worktree\n' >>"$REPO/f.txt"
    run scanf --staged
    [ "$status" -eq 0 ]
    has "対象 0 行"
}

@test "--staged: 追加行を path:行番号:本文 つきで検出する(途中への挿入の行番号も正しい)" {
    mkrepo
    put f.txt $'one\nthree'
    gadd f.txt
    gcommit base
    put f.txt $'one\nqzx-TWO here\nthree'
    gadd f.txt
    run scanf --staged
    [ "$status" -eq 1 ]
    has "f.txt:2: qzx-TWO here"
    has "合計: 1 行 / 1 ファイル"
}

@test "--staged: 本文が ++ で始まる追加行(diff ヘッダ +++ と紛れる)も検出する" {
    mkrepo
    put f.txt "++ qzx-one"
    gadd f.txt
    run scanf --staged
    [ "$status" -eq 1 ]
    has "f.txt:1: ++ qzx-one"
}

@test "--staged: commit 前(HEAD 無し)のリポジトリでも走査できる" {
    mkrepo
    put f.txt "qzx-one"
    gadd f.txt
    run scanf --staged
    [ "$status" -eq 1 ]
    has "f.txt:1: qzx-one"
}

@test "--staged: バイナリ(NUL を含む)は対象外。同じ diff のテキストは走査する" {
    mkrepo
    printf 'qzx-one\0binary\n' >"$REPO/b.bin"
    put t.txt "clean text"
    gadd b.bin t.txt
    run scanf --staged
    [ "$status" -eq 0 ]
    has "対象 1 行 / 1 ファイル"
}

@test "--staged: サブディレクトリから走らせてもリポジトリ全体を走査し、パスは根からの相対で出る" {
    mkrepo
    put top/x.txt "qzx-one"
    put sub/keep.txt "clean"
    gadd top/x.txt sub/keep.txt
    run bash -c 'cd "$1/sub" && bash "$2" --words-file "$3" --local-ext "$4" --staged' _ "$REPO" "$SCAN" "$WORDS" "$NOEXT"
    [ "$status" -eq 1 ]
    has "top/x.txt:1: qzx-one"
}

# ---------------------------------------------------------------- B. --range
@test "--range: 範囲内 commit の追加行を commit の短縮 hash つきで検出し、範囲外(A 以前)は検出しない" {
    mkrepo
    put old.txt "qzx-one before the range"
    gadd old.txt
    gcommit c1
    put new.txt "qzx-two inside the range"
    gadd new.txt
    gcommit c2
    local base head7
    base="$(git -C "$REPO" rev-parse HEAD~1)"
    head7="$(git -C "$REPO" rev-parse --short=7 HEAD)"
    run scanf --range "${base}..HEAD"
    [ "$status" -eq 1 ]
    has "${head7} new.txt:1: qzx-two inside the range"
    hasnt "old.txt"
    has "合計: 1 行 / 1 ファイル"
}

@test "--range: 途中で入れて後で消した語も、履歴に残るので検出する(--tree の最終木では0件)" {
    mkrepo
    put f.txt "base"
    gadd f.txt
    gcommit c1
    put f.txt $'base\nqzx-one transient'
    gadd f.txt
    gcommit c2
    put f.txt "base"
    gadd f.txt
    gcommit c3
    local base
    base="$(git -C "$REPO" rev-parse HEAD~2)"
    run scanf --range "${base}..HEAD"
    [ "$status" -eq 1 ]
    has "f.txt:2: qzx-one transient"
    run scanf --tree HEAD
    [ "$status" -eq 0 ]
}

@test "--range: commit message の語を検出する(ディレクトリ区分は (commit-message))" {
    mkrepo
    put f.txt "base"
    gadd f.txt
    gcommit c1
    put g.txt "clean"
    gadd g.txt
    git -C "$REPO" commit -q -m "機能追加 qzx-two を含む題" -m "本文は無害"
    local base
    base="$(git -C "$REPO" rev-parse HEAD~1)"
    run scanf --range "${base}..HEAD"
    [ "$status" -eq 1 ]
    has ": 機能追加 qzx-two を含む題"
    has $'(commit-message)\t1\t1'
    has "1 commit / "
}

@test "--range: 空の範囲(0 commit)は exit 0 で、0 commit と出す" {
    mkrepo
    put f.txt "qzx-one"
    gadd f.txt
    gcommit c1
    run scanf --range "HEAD..HEAD"
    [ "$status" -eq 0 ]
    has "0 commit"
}

@test "--range: 解決できない範囲・.. の無い指定は exit 2(fail-closed)" {
    mkrepo
    put f.txt "x"
    gadd f.txt
    gcommit c1
    run scanf --range "no_such_rev..HEAD"
    [ "$status" -eq 2 ]
    has "範囲を解決できない"
    run scanf --range "HEAD"
    [ "$status" -eq 2 ]
    has "A..B の形"
}

# ---------------------------------------------------------------- B. --tree
@test "--tree: 追跡木の語を検出する。未追跡ファイルは対象外" {
    mkrepo
    put tracked/a.txt "qzx-one tracked"
    gadd tracked/a.txt
    gcommit c1
    put loose/b.txt "qzx-one untracked"
    run scanf --tree HEAD
    [ "$status" -eq 1 ]
    has "tracked/a.txt:1: qzx-one tracked"
    hasnt "loose/b.txt"
    has $'tracked\t1\t1'
}

@test "--tree: ignore 済みファイルは追跡されていなければ対象外(道具の限界を明示する出力がある)" {
    mkrepo
    put .gitignore "ign/"
    put ign/c.txt "qzx-one ignored"
    put ok.txt "clean"
    gadd .gitignore ok.txt
    gcommit c1
    run scanf --tree HEAD
    [ "$status" -eq 0 ]
    has "未追跡と ignore 済みは対象外"
}

@test "--tree: 指定した rev の木を走査する(旧 rev は検出・新 rev は0件)" {
    mkrepo
    put f.txt "qzx-one old"
    gadd f.txt
    gcommit c1
    put f.txt "clean now"
    gadd f.txt
    gcommit c2
    run scanf --tree HEAD~1
    [ "$status" -eq 1 ]
    run scanf --tree HEAD
    [ "$status" -eq 0 ]
}

@test "--tree: バイナリは対象外。テキストは走査する" {
    mkrepo
    printf 'qzx-one\0binary\n' >"$REPO/b.bin"
    put t.txt "clean text"
    gadd b.bin t.txt
    gcommit c1
    run scanf --tree HEAD
    [ "$status" -eq 0 ]
    has "追跡ファイル 2 本"
}

@test "--tree: 解決できない rev は exit 2" {
    mkrepo
    put f.txt "x"
    gadd f.txt
    gcommit c1
    run scanf --tree no_such_rev
    [ "$status" -eq 2 ]
    has "木を解決できない"
}

# ---------------------------------------------------------------- B. --message-file
@test "--message-file: commit message 案の語を検出する(# 始まりの行も走査)" {
    mkrepo
    printf '題名\n\n# qzx-two はコメント行だが走査する\n本文\n' >"$T/msg.txt"
    run scanf --message-file "$T/msg.txt"
    [ "$status" -eq 1 ]
    has "message-file:3: # qzx-two はコメント行だが走査する"
    has $'(commit-message)\t1\t1'
}

@test "--message-file: 無害な message は0件。相対パスでも読める" {
    mkrepo
    printf '機能名のみの題\n' >"$REPO/msg.txt"
    run scanf --message-file msg.txt
    [ "$status" -eq 0 ]
    has "対象 1 行 / 1 ファイル"
}

@test "--message-file: ファイルが無ければ exit 2。git リポジトリの外でも走る" {
    run bash "$SCAN" --words-file "$WORDS" --local-ext "$NOEXT" --message-file "$T/absent.txt"
    [ "$status" -eq 2 ]
    has "message-file が無い"
    printf 'qzx-one\n' >"$T/outside.txt"
    run bash -c 'cd "$1" && bash "$2" --words-file "$3" --local-ext "$4" --message-file "$5"' _ "$T" "$SCAN" "$WORDS" "$NOEXT" "$T/outside.txt"
    [ "$status" -eq 1 ]
}

@test "複数モード: --staged と --message-file を1つのレポートに集約する" {
    mkrepo
    put d/f.txt "qzx-one"
    gadd d/f.txt
    printf 'qzx-two\n' >"$T/m.txt"
    run scanf --staged --message-file "$T/m.txt"
    [ "$status" -eq 1 ]
    has "合計: 2 行 / 2 ファイル"
    has $'d\t1\t1'
    has $'(commit-message)\t1\t1'
}

@test "使い方誤り: モード無し・未知の引数・引数欠落は exit 2、-h は exit 0" {
    mkrepo
    run scanf
    [ "$status" -eq 2 ]
    has "走査モードを1つ以上"
    run scanf --no-such-option
    [ "$status" -eq 2 ]
    run scanf --range
    [ "$status" -eq 2 ]
    run bash "$SCAN" -h
    [ "$status" -eq 0 ]
    has "Usage:"
}

@test "git リポジトリの外で --staged/--range/--tree は exit 2" {
    mkdir -p "$T/notrepo"
    run bash -c 'cd "$1" && bash "$2" --words-file "$3" --local-ext "$4" --staged' _ "$T/notrepo" "$SCAN" "$WORDS" "$NOEXT"
    [ "$status" -eq 2 ]
    has "git リポジトリの中で"
}

# ---------------------------------------------------------------- C. ディレクトリ別出力
@test "ディレクトリ別: トップディレクトリごとの行数・ファイル数を出す(総数のみにしない)" {
    mkrepo
    put docs/a.md $'qzx-one\nclean\nqzx-two'
    put docs/b.md "qzx-one"
    put tests/c.txt "qzx-one"
    put a/b/c/deep.txt "qzx-two"
    put root.txt "qzx-one"
    gadd docs tests a root.txt
    run scanf --staged
    [ "$status" -eq 1 ]
    has $'docs\t3\t2'
    has $'tests\t1\t1'
    has $'a\t1\t1'
    has $'(root)\t1\t1'
    has "合計: 6 行 / 5 ファイル"
    # 行数の多い順(docs が先頭)
    local first
    first="$(printf '%s\n' "$output" | awk '/^--- ディレクトリ別/{f=1;next} f&&/\t/{print $1; exit}')"
    [ "$first" = "docs" ]
}

# ---------------------------------------------------------------- D. 自己除外
@test "自己除外: 正本リスト1本(固定パス)は --staged/--range/--tree のいずれでも走査しない" {
    mkrepo
    put base.txt "base"
    gadd base.txt
    gcommit c0
    put "$SELF" "リスト自身は qzx-one を含む"
    gadd "$SELF"
    run scanf --staged
    [ "$status" -eq 0 ]
    gcommit c1
    run scanf --tree HEAD
    [ "$status" -eq 0 ]
    local base
    base="$(git -C "$REPO" rev-parse HEAD~1)"
    run scanf --range "${base}..HEAD"
    [ "$status" -eq 0 ]
}

@test "自己除外は1本のみ: 同ディレクトリの別ファイル・同名の別パスは走査する" {
    mkrepo
    put "$SELF" "qzx-one in the list itself"
    put instructions/common/other.md "qzx-one in a sibling"
    put docs/public_repo_forbidden_words.md "qzx-one in a same-named file"
    gadd instructions docs
    run scanf --staged
    [ "$status" -eq 1 ]
    has "合計: 2 行 / 2 ファイル"
    has "instructions/common/other.md:1:"
    has "docs/public_repo_forbidden_words.md:1:"
    hasnt "instructions/common/public_repo_forbidden_words.md:1:"
}

@test "自己除外: サブディレクトリから走らせてもリポジトリ根基準で除外される" {
    mkrepo
    put "$SELF" "qzx-one in the list"
    put sub/keep.txt "clean"
    gadd instructions sub
    run bash -c 'cd "$1/sub" && bash "$2" --words-file "$3" --local-ext "$4" --staged' _ "$REPO" "$SCAN" "$WORDS" "$NOEXT"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------- E. ローカル拡張
@test "ローカル拡張: 存在すれば追加される(拡張語は基本リストに無い=対照つき)" {
    mkrepo
    put f.txt "zzy-local-only word"
    gadd f.txt
    run scanf --staged
    [ "$status" -eq 0 ]
    printf 'zzy-local-only\n' >"$T/ext.txt"
    run bash -c 'cd "$1" && bash "$2" --words-file "$3" --local-ext "$4" --staged' _ "$REPO" "$SCAN" "$WORDS" "$T/ext.txt"
    [ "$status" -eq 1 ]
    has "f.txt:1: zzy-local-only word"
    has "ローカル拡張 1 行"
}

@test "ローカル拡張: 無ければ無視する(エラーにしない)" {
    mkrepo
    put f.txt "clean"
    gadd f.txt
    run scanf --staged
    [ "$status" -eq 0 ]
    has "ローカル拡張 0 行"
}

@test "ローカル拡張: 空行・# コメント(前に空白があっても)・行末 CR は無視する" {
    mkrepo
    put f.txt "clean"
    gadd f.txt
    printf '# コメント\n\n   \n  # 空白つきコメント\nzzy-real\r\n' >"$T/ext.txt"
    run bash -c 'cd "$1" && bash "$2" --words-file "$3" --local-ext "$4" --staged' _ "$REPO" "$SCAN" "$WORDS" "$T/ext.txt"
    [ "$status" -eq 0 ]
    has "ローカル拡張 1 行"
    put g.txt "zzy-real appears"
    gadd g.txt
    run bash -c 'cd "$1" && bash "$2" --words-file "$3" --local-ext "$4" --staged' _ "$REPO" "$SCAN" "$WORDS" "$T/ext.txt"
    [ "$status" -eq 1 ]
    has "g.txt:1: zzy-real appears"
}

@test "ローカル拡張: 不正な ERE・空文字列に一致する行・通常ファイルでない指定は exit 2(fail-closed)" {
    mkrepo
    put f.txt "clean"
    gadd f.txt
    printf 'bad(\n' >"$T/ext_bad.txt"
    run bash -c 'cd "$1" && bash "$2" --words-file "$3" --local-ext "$4" --staged' _ "$REPO" "$SCAN" "$WORDS" "$T/ext_bad.txt"
    [ "$status" -eq 2 ]
    printf 'x*\n' >"$T/ext_empty.txt"
    run bash -c 'cd "$1" && bash "$2" --words-file "$3" --local-ext "$4" --staged' _ "$REPO" "$SCAN" "$WORDS" "$T/ext_empty.txt"
    [ "$status" -eq 2 ]
    mkdir -p "$T/ext_dir"
    run bash -c 'cd "$1" && bash "$2" --words-file "$3" --local-ext "$4" --staged' _ "$REPO" "$SCAN" "$WORDS" "$T/ext_dir"
    [ "$status" -eq 2 ]
    has "通常ファイルではない"
}

@test "ローカル拡張: 既定の置き場所は script から見た ../config/public_repo_forbidden_words.local.txt" {
    mkdir -p "$T/proj/scripts" "$T/proj/instructions/common" "$T/proj/config"
    cp "$SCAN" "$T/proj/scripts/public_repo_scan.sh"
    cp "$WORDS" "$T/proj/$SELF"
    printf 'zzy-default-place\n' >"$T/proj/config/public_repo_forbidden_words.local.txt"
    mkrepo
    put f.txt "zzy-default-place is here"
    gadd f.txt
    run bash -c 'cd "$1" && bash "$2" --staged' _ "$REPO" "$T/proj/scripts/public_repo_scan.sh"
    [ "$status" -eq 1 ]
    has "f.txt:1: zzy-default-place is here"
    has "ローカル拡張 1 行"
}

# ---------------------------------------------------------------- E2. 番兵のみ・fail-closed (cmd_797)
@test "fail-closed(cmd_797): 公開側が番兵のみでローカル拡張が無ければ、どの走査モードでも exit 2 で止まり、0件の判定を出さない" {
    mkrepo
    put f.txt "clean"
    gadd f.txt
    gcommit c1
    printf 'clean message\n' >"$T/m.txt"
    run scanr0 --staged
    [ "$status" -eq 2 ] || {
        echo "--staged: exit ${status}"
        return 1
    }
    has "番兵のみ"
    has "fail-closed"
    hasnt "判定: OK"
    hasnt "(ヒットなし)"
    run scanr0 --tree HEAD
    [ "$status" -eq 2 ]
    has "番兵のみ"
    hasnt "判定: OK"
    run scanr0 --range "HEAD..HEAD"
    [ "$status" -eq 2 ]
    has "番兵のみ"
    hasnt "判定: OK"
    run scanr0 --message-file "$T/m.txt"
    [ "$status" -eq 2 ]
    has "番兵のみ"
    hasnt "判定: OK"
}

@test "fail-closed(cmd_797): 拡張ファイルが在っても有効な語が0行(空・# コメントのみ)なら止まる。有効な行が1つでもあれば走り、拡張語を従来どおり検出する" {
    mkrepo
    put f.txt "clean"
    gadd f.txt
    printf '# コメントのみ\n\n   \n  # 空白つきコメント\n' >"$T/ext_none.txt"
    run bash -c 'cd "$1" && bash "$2" --local-ext "$3" --staged' _ "$REPO" "$SCAN" "$T/ext_none.txt"
    [ "$status" -eq 2 ]
    has "有効な語が1つも無い"
    hasnt "判定: OK"
    printf 'zzy-only-word\n' >"$T/ext_one.txt"
    run bash -c 'cd "$1" && bash "$2" --local-ext "$3" --staged' _ "$REPO" "$SCAN" "$T/ext_one.txt"
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    has "基本: 番兵のみ"
    has "ローカル拡張 1 行"
    has "判定: OK(禁則語 0 件)"
    put g.txt "zzy-only-word appears"
    gadd g.txt
    run bash -c 'cd "$1" && bash "$2" --local-ext "$3" --staged' _ "$REPO" "$SCAN" "$T/ext_one.txt"
    [ "$status" -eq 1 ]
    has "g.txt:1: zzy-only-word appears"
}

@test "fail-closed(cmd_797): 番兵のみかは正本の行が script の番兵と一致するかで決まる(番兵に他の語が付けば番兵のみではない)" {
    mkrepo
    put f.txt "qzx-one"
    gadd f.txt
    local sen
    sen="$(sentinel_of_script)"
    [ -n "$sen" ]
    write_words "$sen"
    run scanf --staged
    [ "$status" -eq 2 ]
    has "番兵のみ"
    write_words "${sen}|qzx-one"
    run scanf --staged
    [ "$status" -eq 1 ]
    has "f.txt:1: qzx-one"
    has "基本 2 語"
    hasnt "番兵のみ"
}

@test "公開側の正本自身に具体語が無い: 実 md を別パスへ複製し、試験用拡張の全18語で走査して0件(許可ドメインの表記は除去される)" {
    mkrepo
    mkdir -p "$REPO/docs"
    cp "$WORDS_REAL" "$REPO/docs/copy_of_list.md"
    gadd docs
    run scanr --staged
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    has "対象 "
    has "合計: 0 行 / 0 ファイル"
    # 陽性対照: 複製へ語を1つ足せば検出する(複製が実際に走査対象である証拠)
    printf '%s\n' "$(term poke mon)" >>"$REPO/docs/copy_of_list.md"
    gadd docs
    run scanr --staged
    [ "$status" -eq 1 ]
    has "合計: 1 行 / 1 ファイル"
}

# ---------------------------------------------------------------- F. 正本リストの書式
@test "リスト書式: forbidden-regex ブロックが0個・2個・複数行・空なら exit 2" {
    mkrepo
    put f.txt "clean"
    gadd f.txt
    printf '# no block\nqzx-one\n' >"$T/w0.md"
    printf '```forbidden-regex\nqzx-one\n```\n```forbidden-regex\nqzx-two\n```\n' >"$T/w2.md"
    printf '```forbidden-regex\nqzx-one\nqzx-two\n```\n' >"$T/wm.md"
    printf '```forbidden-regex\n\n```\n' >"$T/we.md"
    local w
    for w in w0 w2 wm we; do
        run bash -c 'cd "$1" && bash "$2" --words-file "$3" --local-ext "$4" --staged' _ "$REPO" "$SCAN" "$T/$w.md" "$NOEXT"
        [ "$status" -eq 2 ] || {
            echo "$w: exit ${status}"
            return 1
        }
        has "forbidden-regex ブロックが不正"
    done
}

@test "リスト書式: 空の選択肢(a||b)・不正な ERE・リスト無しは exit 2" {
    mkrepo
    put f.txt "clean"
    gadd f.txt
    write_words 'qzx-one||qzx-two'
    run scanf --staged
    [ "$status" -eq 2 ]
    has "空文字列に一致する"
    write_words 'qzx-one|(qzx'
    run scanf --staged
    [ "$status" -eq 2 ]
    has "不正"
    run bash -c 'cd "$1" && bash "$2" --words-file "$3" --local-ext "$4" --staged' _ "$REPO" "$SCAN" "$T/absent.md" "$NOEXT"
    [ "$status" -eq 2 ]
    has "禁則語リストが無い"
}

@test "リスト書式: CRLF のリストも読める。ブロック外の文(説明表など)は正規表現にならない" {
    mkrepo
    printf '# 説明に qzx-explain と書いてある\r\n\r\n```forbidden-regex\r\nqzx-one\r\n```\r\n' >"$T/wcrlf.md"
    put f.txt $'qzx-one\nqzx-explain'
    gadd f.txt
    run bash -c 'cd "$1" && bash "$2" --words-file "$3" --local-ext "$4" --staged' _ "$REPO" "$SCAN" "$T/wcrlf.md" "$NOEXT"
    [ "$status" -eq 1 ]
    has "合計: 1 行 / 1 ファイル"
    has "f.txt:1: qzx-one"
    hasnt "f.txt:2:"
}

# ---------------------------------------------------------------- G. git 書込が無いこと
@test "読取専用: 全モードで git の書込系サブコマンドを呼ばず、.git の中身が1バイトも変わらない" {
    mkrepo
    put f.txt "base"
    gadd f.txt
    gcommit c1
    put h.txt "clean second commit"
    gadd h.txt
    gcommit c2
    put g.txt "qzx-one added"
    gadd g.txt
    printf 'qzx-two\n' >"$T/m.txt"
    mkdir -p "$T/shim"
    local real_git
    real_git="$(command -v git)"
    cat >"$T/shim/git" <<EOF
#!/usr/bin/env bash
sub=""; skip=0
for a in "\$@"; do
    if [ "\$skip" = 1 ]; then skip=0; continue; fi
    case "\$a" in -c|-C) skip=1 ;; -*) ;; *) sub="\$a"; break ;; esac
done
printf '%s\n' "\$sub" >> "$T/shim.log"
exec "$real_git" "\$@"
EOF
    chmod +x "$T/shim/git"
    : >"$T/shim.log"
    local before after
    before="$(cd "$REPO/.git" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)"
    run bash -c 'cd "$1" && PATH="$2:$PATH" bash "$3" --words-file "$4" --local-ext "$5" --staged --range "HEAD~1..HEAD" --tree HEAD --message-file "$6"' _ "$REPO" "$T/shim" "$SCAN" "$WORDS" "$NOEXT" "$T/m.txt"
    [ "$status" -eq 1 ]
    after="$(cd "$REPO/.git" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)"
    [ "$before" = "$after" ]
    [ -s "$T/shim.log" ]
    local sub
    while IFS= read -r sub; do
        case "$sub" in
            rev-parse | diff | log | rev-list | ls-tree | grep) ;;
            *)
                echo "許可外の git サブコマンド: $sub"
                return 1
                ;;
        esac
    done <"$T/shim.log"
    # 全モードが実際に git を呼んだこと(shim が経由されている証拠)
    local need
    for need in diff log rev-list ls-tree grep; do
        /usr/bin/grep -q "^${need}\$" "$T/shim.log" || {
            echo "shim を経由していない git サブコマンド: $need"
            return 1
        }
    done
}

# ---------------------------------------------------------------- H. 自己走査
@test "自己走査: 新規の script・試験・正本リストを実リストで走査して0件(除外は正本リスト1本のみ)" {
    mkrepo
    mkdir -p "$REPO/scripts" "$REPO/tests/unit" "$REPO/instructions/common"
    cp "$PROJECT_ROOT/scripts/public_repo_scan.sh" "$REPO/scripts/"
    cp "$PROJECT_ROOT/scripts/check_tracked.sh" "$REPO/scripts/"
    cp "$PROJECT_ROOT/tests/unit/test_public_repo_scan.bats" "$REPO/tests/unit/"
    cp "$PROJECT_ROOT/tests/unit/test_check_tracked.bats" "$REPO/tests/unit/"
    cp "$WORDS_REAL" "$REPO/$SELF"
    gadd scripts tests instructions
    run scanr --staged
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    has "対象 "
    has "要確認(WARN・許可ドメイン外のメールアドレス): 0 件 / 0 ファイル"
    gcommit c1
    run scanr --tree HEAD
    [ "$status" -eq 0 ]
    has "追跡ファイル 5 本"
}

# ---------------------------------------------------------------- I. 変異試験
# probe は「正しい script なら 0(成功)、壊した script なら非0」を返す。各 probe は自分専用の
# 隔離 repo を作る。

_probe_repo() { PROBE_N=$((PROBE_N + 1)); mkrepo "p${PROBE_N}"; }
_run_in() { # $1=script $2...=引数 → P_RC / P_OUT
    local s="$1"
    shift
    P_RC=0
    P_OUT="$(cd "$REPO" && bash "$s" --words-file "$WORDS" --local-ext "${EXT_OVERRIDE:-$NOEXT}" "$@" 2>&1)" || P_RC=$?
}

probe_case_insensitive() {
    _probe_repo
    put f.txt "QZX-ONE upper"
    gadd f.txt
    _run_in "$1" --staged
    [ "$P_RC" -eq 1 ]
}
probe_exit_codes() {
    _probe_repo
    put f.txt "clean"
    gadd f.txt
    _run_in "$1" --staged
    [ "$P_RC" -eq 0 ] || return 1
    put g.txt "qzx-one"
    gadd g.txt
    _run_in "$1" --staged
    [ "$P_RC" -eq 1 ]
}
probe_added_lines_only() {
    _probe_repo
    put f.txt $'keep\nqzx-one'
    gadd f.txt
    gcommit base
    put f.txt $'keep\nclean replacement'
    gadd f.txt
    _run_in "$1" --staged
    [ "$P_RC" -eq 0 ]
}
probe_index_only() {
    _probe_repo
    put f.txt "keep"
    gadd f.txt
    gcommit base
    printf 'qzx-one only in worktree\n' >>"$REPO/f.txt"
    _run_in "$1" --staged
    [ "$P_RC" -eq 0 ]
}
probe_self_exclusion() {
    _probe_repo
    put "$SELF" "qzx-one in the list"
    gadd "$SELF"
    _run_in "$1" --staged
    [ "$P_RC" -eq 0 ] || return 1
    put docs/other.md "qzx-one elsewhere"
    gadd docs/other.md
    _run_in "$1" --staged
    [ "$P_RC" -eq 1 ]
}
probe_per_dir() {
    _probe_repo
    put docs/a.md "qzx-one"
    put root.txt "qzx-two"
    gadd docs root.txt
    _run_in "$1" --staged
    [[ "$P_OUT" == *$'docs\t1\t1'* ]] && [[ "$P_OUT" == *$'(root)\t1\t1'* ]]
}
probe_local_ext() {
    _probe_repo
    printf 'zzy-ext-word\n' >"$T/probe_ext.txt"
    put f.txt "zzy-ext-word"
    gadd f.txt
    EXT_OVERRIDE="$T/probe_ext.txt" _run_in "$1" --staged
    [ "$P_RC" -eq 1 ]
}
probe_tree_binary() {
    _probe_repo
    printf 'qzx-one\0binary\n' >"$REPO/b.bin"
    gadd b.bin
    gcommit c1
    _run_in "$1" --tree HEAD
    [ "$P_RC" -eq 0 ] || return 1
    put t.txt "qzx-one text"
    gadd t.txt
    gcommit c2
    _run_in "$1" --tree HEAD
    [ "$P_RC" -eq 1 ]
}
probe_message_file() {
    _probe_repo
    printf 'qzx-two in message\n' >"$T/probe_msg.txt"
    _run_in "$1" --message-file "$T/probe_msg.txt"
    [ "$P_RC" -eq 1 ]
}
probe_range_message() {
    _probe_repo
    put f.txt "base"
    gadd f.txt
    gcommit c1
    put g.txt "clean"
    gadd g.txt
    gcommit "題に qzx-two"
    _run_in "$1" --range "HEAD~1..HEAD"
    [ "$P_RC" -eq 1 ]
}
probe_plusplus_line() {
    _probe_repo
    put f.txt "++ qzx-one"
    gadd f.txt
    _run_in "$1" --staged
    [ "$P_RC" -eq 1 ]
}
probe_empty_alternative_rejected() {
    _probe_repo
    put f.txt "clean"
    gadd f.txt
    write_words 'qzx-one||qzx-two'
    _run_in "$1" --staged
    local rc="$P_RC"
    write_words 'qzx-one|qzx-two'
    [ "$rc" -eq 2 ]
}
probe_range_added_lines() {
    _probe_repo
    put f.txt "base"
    gadd f.txt
    gcommit c1
    put g.txt "qzx-one added in range"
    gadd g.txt
    gcommit c2
    _run_in "$1" --range "HEAD~1..HEAD"
    [ "$P_RC" -eq 1 ]
}

_run_real() { # $1=script $2...=引数 → P_RC / P_OUT(実際の正本(番兵のみ)+試験用拡張で走査する)
    local s="$1"
    shift
    P_RC=0
    P_OUT="$(cd "$REPO" && bash "$s" --words-file "$WORDS_REAL" --local-ext "$REALEXT" "$@" 2>&1)" || P_RC=$?
}

probe_allowed_domain_removed() {
    _probe_repo
    put f.txt "kato@v-sync.co.jp"
    gadd f.txt
    _run_real "$1" --staged
    [ "$P_RC" -eq 0 ]
}
probe_allowed_removal_keeps_other_words() {
    _probe_repo
    put f.txt "kato@v-sync.co.jp $(term tl c-cms)"
    gadd f.txt
    _run_real "$1" --staged
    [ "$P_RC" -eq 1 ]
}
probe_allowed_removal_leading_boundary() {
    _probe_repo
    put f.txt "x$(term v- sync).co.jp"
    gadd f.txt
    _run_real "$1" --staged
    [ "$P_RC" -eq 1 ]
}
probe_allowed_removal_trailing_boundary() {
    _probe_repo
    put f.txt "a@$(term v- sync).co.jp.evil.example"
    gadd f.txt
    _run_real "$1" --staged
    [ "$P_RC" -eq 1 ]
}
probe_allowed_removal_restores_next_char() {
    _probe_repo
    put f.txt "kato@v-sync.co.jp$(term 紙 袋)"
    gadd f.txt
    _run_real "$1" --staged
    [ "$P_RC" -eq 1 ]
}
probe_allowed_address_after_another() {
    _probe_repo
    put f.txt "kato@v-sync.co.jp と kato@v-sync.co.jp"
    gadd f.txt
    _run_real "$1" --staged
    [ "$P_RC" -eq 0 ]
}
probe_allowed_removal_repeats() {
    _probe_repo
    put f.txt "v-sync.co.jp v-sync.co.jp"
    gadd f.txt
    _run_real "$1" --staged
    [ "$P_RC" -eq 0 ]
}
probe_warn_reported() {
    _probe_repo
    put f.txt "$(mail person corp.test)"
    gadd f.txt
    _run_real "$1" --staged
    [ "$P_RC" -eq 0 ] && [[ "$P_OUT" == *"要確認(WARN・許可ドメイン外のメールアドレス): 1 件 / 1 ファイル"* ]]
}
probe_warn_allowlist_honored() {
    _probe_repo
    put f.txt "$(mail a example.com)"
    gadd f.txt
    _run_real "$1" --staged
    [ "$P_RC" -eq 0 ] && [[ "$P_OUT" == *"要確認(WARN・許可ドメイン外のメールアドレス): 0 件 / 0 ファイル"* ]]
}
probe_warn_is_not_ng() {
    _probe_repo
    put f.txt "$(mail person corp.test)"
    gadd f.txt
    _run_real "$1" --staged
    [ "$P_RC" -eq 0 ]
}
probe_sentinel_only_fail_closed() {
    _probe_repo
    put f.txt "clean"
    gadd f.txt
    P_RC=0
    P_OUT="$(cd "$REPO" && bash "$1" --words-file "$WORDS_REAL" --local-ext "$NOEXT" --staged 2>&1)" || P_RC=$?
    [ "$P_RC" -eq 2 ]
}
probe_sentinel_with_ext_runs() {
    _probe_repo
    put f.txt "clean"
    gadd f.txt
    printf 'zzy-ext-word\n' >"$T/probe_ext_sen.txt"
    P_RC=0
    P_OUT="$(cd "$REPO" && bash "$1" --words-file "$WORDS_REAL" --local-ext "$T/probe_ext_sen.txt" --staged 2>&1)" || P_RC=$?
    [ "$P_RC" -eq 0 ] || return 1
    put g.txt "zzy-ext-word"
    gadd g.txt
    P_RC=0
    P_OUT="$(cd "$REPO" && bash "$1" --words-file "$WORDS_REAL" --local-ext "$T/probe_ext_sen.txt" --staged 2>&1)" || P_RC=$?
    [ "$P_RC" -eq 1 ]
}
probe_quoted_path_decoded() {
    _probe_repo
    put "docs/日本語.md" "qzx-one"
    gadd docs
    _run_in "$1" --staged
    [[ "$P_OUT" == *$'docs\t1\t1'* ]]
}
probe_quoted_path_decoded_range() {
    _probe_repo
    put base.txt "base"
    gadd base.txt
    gcommit c0
    local base
    base="$(git -C "$REPO" rev-parse HEAD)"
    put "docs/日本語.md" "qzx-one"
    gadd docs
    gcommit c1
    _run_in "$1" --range "${base}..HEAD"
    [[ "$P_OUT" == *$'docs\t1\t1'* ]]
}
probe_diff_prefix_pinned() {
    _probe_repo
    put docs/a.md "qzx-one"
    gadd docs
    printf '[diff]\n\tmnemonicPrefix = true\n' >"$T/gc_mn_probe"
    P_RC=0
    P_OUT="$(cd "$REPO" && GIT_CONFIG_GLOBAL="$T/gc_mn_probe" bash "$1" --words-file "$WORDS" --local-ext "$NOEXT" --staged 2>&1)" || P_RC=$?
    [[ "$P_OUT" == *$'docs\t1\t1'* ]]
}

# $1=probe 名 $2=sed 式(壊し方)。正しい script で成功し、壊した複製で失敗することを確かめる。
assert_mutation_caught() {
    local probe="$1" expr="$2" mut
    "$probe" "$SCAN" || {
        echo "probe ${probe} が正しい script で失敗する(probe 自体の誤り)"
        return 1
    }
    mkdir -p "$T/mut"
    mut="$T/mut/${probe}.sh"
    sed -E "$expr" "$SCAN" >"$mut"
    if cmp -s "$SCAN" "$mut"; then
        echo "変異が適用されていない(sed 式が script に当たらない): ${expr}"
        return 1
    fi
    if "$probe" "$mut"; then
        echo "変異を検出できなかった: probe ${probe} が壊した script でも成功した(${expr})"
        return 1
    fi
}

@test "変異試験: 大小無視(-i)を外すと検出できなくなる" {
    assert_mutation_caught probe_case_insensitive 's/"\$GREP_BIN" -a -i -E -n -e "\$REGEX" "\$STRIPPED"/"$GREP_BIN" -a -E -n -e "$REGEX" "$STRIPPED"/'
}
@test "変異試験: ヒット時の終了コードを 0 にすると gate にならない" {
    assert_mutation_caught probe_exit_codes 's/^    exit 1$/    exit 0/'
}
@test "変異試験: 削除行も数えると「追加行のみ」が崩れる" {
    assert_mutation_caught probe_added_lines_only 's#in_hunk && /\^\\\+/ \{#in_hunk \&\& /^[-+]/ {#'
}
@test "変異試験: --cached を外すと index でなく作業木を見てしまう" {
    assert_mutation_caught probe_index_only 's/git diff -U0 --cached /git diff -U0 /'
}
@test "変異試験: 自己除外を外すと正本リスト自身が誤検出される" {
    assert_mutation_caught probe_self_exclusion 's/":\(exclude\)\$SELF_EXCLUDE_PATH"/"."/'
}
@test "変異試験: ディレクトリ別を潰す(常に (root))と内訳が消える" {
    assert_mutation_caught probe_per_dir 's/return i \? substr\(p, 1, i - 1\) : "\(root\)"/return "(root)"/'
}
@test "変異試験: ローカル拡張を結合しないと拡張語が検出されない" {
    assert_mutation_caught probe_local_ext 's/^            base="\$base\|\(\$frag\)"$/            :/'
}
@test "変異試験: --tree のバイナリ除外(-I)を外すとバイナリを誤検出する" {
    assert_mutation_caught probe_tree_binary 's/git grep -I -i/git grep -a -i/'
}
@test "変異試験: message-file の走査を潰すと検出できなくなる" {
    assert_mutation_caught probe_message_file 's/^    awk -v label="\$label" .* >"\$ADDED"$/    : >"$ADDED"/'
}
@test "変異試験: 範囲内 commit の message 走査を潰すと検出できなくなる" {
    assert_mutation_caught probe_range_message 's/^            scan_message_text "\$MSGF" "commit \$\{sha:0:7\}"$/            :/'
}
@test "変異試験: 範囲内 commit の追加行の走査を潰すと検出できなくなる" {
    assert_mutation_caught probe_range_added_lines 's/^    filter_hits "range \$\{range\} の各 commit の追加行"$/    :/'
}
@test "変異試験: +++ ヘッダ判定から !in_hunk を外すと ++ で始まる追加行を取りこぼす" {
    assert_mutation_caught probe_plusplus_line 's#!in_hunk && /\^\\\+\\\+\\\+ / \{#/^\\+\\+\\+ / {#'
}
@test "変異試験: 空文字列一致の拒否を外すと空の選択肢が通ってしまう" {
    assert_mutation_caught probe_empty_alternative_rejected 's/^(        0\) )die .*空文字列に一致する.*$/\1: ;;/'
}

# ---- G788-R01: 許可表記の除去
@test "変異試験(R01): 許可表記の除去を無効化すると、許可ドメインのアドレスが社名の部分一致で拒否される" {
    assert_mutation_caught probe_allowed_domain_removed 's/^    sed -E "\$\{STRIP_ARGS\[@\]\}" "\$1" >"\$2" \|\| die .*$/    cp "$1" "$2"/'
}
@test "変異試験(R01): 除去が行全体を消すようになると、許容と禁止が混在した行を取りこぼす" {
    assert_mutation_caught probe_allowed_removal_keeps_other_words 's#^(        STRIP_ARGS\+=\(-e )"s/@\$\{dre\}.*$#\1"s/.*@${dre}.*//I")#'
}
@test "変異試験(R01): 単独ドメインの直前境界を外すと、英数字が直前に付いた別語(<英数字><許可ドメイン>)を許可してしまう" {
    assert_mutation_caught probe_allowed_removal_leading_boundary 's#\(\^\|\[\^A-Za-z0-9@-\]\)\$\{dre\}#()${dre}#'
}
@test "変異試験(R01): 直後境界に . を許すと、<許可ドメイン>.<他ドメイン> を許可してしまう" {
    assert_mutation_caught probe_allowed_removal_trailing_boundary 's#\[\^A-Za-z0-9\.-\]#[^A-Za-z0-9-]#g'
}
@test "変異試験(R01): 直後の1文字を書き戻さないと、隣接する日本語の禁則語を壊して取りこぼす" {
    assert_mutation_caught probe_allowed_removal_restores_next_char 's#/ \\\\1\\\\2/I"\)#/ \\\\1/I")#'
}
@test "変異試験(R01): 単独ドメイン用の規則が @ の直後も消すようになると、@ だけが残って個人識別子の禁則語に一致する(A→B の順序不具合)" {
    assert_mutation_caught probe_allowed_address_after_another 's#\[\^A-Za-z0-9@-\]#[^A-Za-z0-9-]#'
}
@test "変異試験(R01): 除去の繰り返し(:a … ta)を外すと、隣り合う同一ドメインの2つ目が残って誤検出される" {
    assert_mutation_caught probe_allowed_removal_repeats "s/^    STRIP_ARGS\\+=\\(-e 'ta'\\)\$/    :/"
}
# ---- G788-R01: 要確認(WARN)
@test "変異試験(R01): メールアドレスの抽出を潰すと、許可ドメイン外のアドレスが要確認に出ない" {
    assert_mutation_caught probe_warn_reported 's/^    "\$GREP_BIN" -a -i -o -E -n -e "\$EMAIL_RE" "\$TEXTS" >"\$EMAILS" \|\| rc=\$\?$/    rc=1/'
}
@test "変異試験(R01): 許可リストを無視すると、許可ドメインのアドレスまで要確認になる" {
    assert_mutation_caught probe_warn_allowlist_honored 's/if \(!\(d in ok\)\) print/if (1) print/'
}
@test "変異試験(R01): 要確認を NG に数えると、WARN だけで commit が止まる" {
    assert_mutation_caught probe_warn_is_not_ng 's/^(warn_files=.*)$/\1; total_lines=$((total_lines + warn_lines))/'
}
# ---- cmd_797: 番兵のみ・fail-closed
@test "変異試験(cmd_797): 停止(die)を外すと、公開側が番兵のみでも具体語ゼロの走査が0件で通ってしまう" {
    assert_mutation_caught probe_sentinel_only_fail_closed 's/^        die "公開側の禁則語正本は番兵のみ.*$/        :/'
}
@test "変異試験(cmd_797): 番兵のみの判定を落とすと、具体語ゼロの走査が0件で通ってしまう" {
    assert_mutation_caught probe_sentinel_only_fail_closed 's/^    \[\[ "\$base" == "\$SENTINEL_REGEX" \]\] && sentinel_only=1$/    :/'
}
@test "変異試験(cmd_797): 拡張の有無を見ずに止めると、有効な拡張があっても走査できなくなる" {
    assert_mutation_caught probe_sentinel_with_ext_runs 's/"\$EXT_N" -eq 0 \]\]/"$EXT_N" -ge 0 ]]/'
}
# ---- G788-R03: git が引用した path
@test "変異試験(R03): 引用 path の復号を外すと、日本語 path の所属ディレクトリが引用符つきの接頭辞になる(--staged)" {
    assert_mutation_caught probe_quoted_path_decoded 's/if \(substr\(p, 1, 1\) == "\\""\) p = unquote\(p\); else/if (0) p = unquote(p); else/'
}
@test "変異試験(R03): 引用 path の復号を外すと、--range(同じ抽出処理)でも所属ディレクトリを誤る" {
    assert_mutation_caught probe_quoted_path_decoded_range 's/if \(substr\(p, 1, 1\) == "\\""\) p = unquote\(p\); else/if (0) p = unquote(p); else/'
}
@test "変異試験(R03): diff の接頭辞を固定しないと、diff.mnemonicPrefix 設定下で所属ディレクトリを誤る" {
    assert_mutation_caught probe_diff_prefix_pinned 's# --src-prefix=a/ --dst-prefix=b/##'
}
