#!/usr/bin/env bash
# public_repo_scan.sh — 公開リポジトリへ載せるもの(差分・木・commit message)を
# 禁則語で走査する gate 道具 (cmd_788 AC③)。読取専用: git への書込は一切しない。
#
# 背景: origin は公開リポジトリであり、個別業務に由来する名称や個人識別子を
# 混入させない方針である。cmd_786 では走査を臨時の使い捨て script で行ったため、
# 再現できない根拠になった。走査を常設の道具にして、誰が走らせても同じ件数が出る
# ようにする(件数そのものが根拠になる)。
#
# 禁則語の正本: instructions/common/public_repo_forbidden_words.md の
#   ```forbidden-regex ブロック(ちょうど1行・ERE)。cmd_797 以降、公開側のこの行は
#   具体語を持たない番兵(SENTINEL_REGEX)1行であり、仕組み(書式・許可ドメイン)だけを公開する。
# ローカル拡張: config/public_repo_forbidden_words.local.txt(git 管理外)。具体語
#   (取引先名・商品名・拠点名・人名・識別子など)はすべてこちらだけが持つ。書式は正本ファイルの節を見よ。
#
# ★fail-closed(cmd_797): 公開側が番兵のみ、かつローカル拡張に有効な語が1つも無いとき、
#   具体語ゼロの走査になる。これは 0 件でも「混入が無い」ことを何も意味しないので、黙って通さず、
#   理由を表示して終了コード 2 で止まる。公開側が番兵でない(具体語を持つ)正本を --words-file で
#   与えた場合(試験・検証)は、従来どおりローカル拡張が無くても走る。
#
# 許容(殿確定 2026-09-30・G788-R01): /home/kato・cmd_xxx・v-sync.co.jp のアドレスは
#   残留 OK で、検出しない。/home/kato と cmd_xxx は禁則語に含めないだけ。自社ドメインは
#   禁則語(社名)の部分一致で巻き込まれるので、正本の allowed-email-domains ブロックの
#   ドメイン表記だけを走査前に除去する(同じ行の他の禁則語は消さない。除去の形は
#   build_strip_args を見よ)。
#
# 要確認(WARN): メールアドレスのドメインが allowed-email-domains に無いものを別出力する。
#   「業務繋がり」は機械で判定できないので NG にはせず、件数を出して exit 0 のまま
#   人の目視確認へ渡す。
#
# 使い方:
#   bash scripts/public_repo_scan.sh [--staged] [--range A..B] [--tree REV]
#                                    [--message-file FILE]
#                                    [--words-file FILE] [--local-ext FILE]
#   (走査モードは1つ以上を指定。複数指定すると1つのレポートに集約する)
#   --staged            git diff -U0 --cached の追加行(index にあるもの)
#   --range A..B        範囲内の各 commit の追加行と、各 commit message
#                       (途中で入れて後で消した語も、履歴に残るので検出する。
#                        merge commit 自身が持つ差分は対象外——merge で取り込まれる
#                        側の commit が範囲内なら、そちらで走査される)
#   --tree REV          REV の追跡木(git grep・バイナリ除外。未追跡・ignore 済みは見えない)
#   --message-file FILE commit message 案(# 始まりの行も走査する)
#   --words-file FILE   正本リストの場所を差し替える(試験・検証用)
#   --local-ext FILE    ローカル拡張の場所を差し替える(存在しなければ無視)
#
# 出力: ヒット行(path:行:本文)と、トップディレクトリ別のヒット件数
#   (count_by_dir.sh と同じく総数のみは出さない)。リスト自体の再掲はしない。
#   要確認(WARN)があれば、その行とディレクトリ別件数を続ける(0 件でも件数の行は必ず出す)。
# 終了コード: 0=ヒット0件(WARN の有無は問わない) / 1=ヒット1件以上 / 2=使い方誤り・実行失敗(fail-closed。
#   公開側が番兵のみでローカル拡張も無い場合を含む)。
#
# 自己除外: 正本リストは禁則語そのものを含むため、そのファイル1本
#   (SELF_EXCLUDE_PATH)だけを走査対象から外す。同名の別パスは外さない。
#
# grep は /usr/bin/grep をフルパスで呼ぶ(シェル関数版 grep は gitignore 領域を
# 黙って素通りする。cmd_735)。--tree だけは追跡木を読むため git grep を使う。
set -euo pipefail

# 決定的な挙動のため C ロケールに固定する(日本語の語はバイト列として一致する)。
export LC_ALL=C
# git status 等が index を更新しようとしない(=読取専用を保つ)ため。
export GIT_OPTIONAL_LOCKS=0

GREP_BIN=/usr/bin/grep
SCRIPT_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# 走査から外す唯一のファイル(リポジトリ根からの相対パス)。
SELF_EXCLUDE_PATH="instructions/common/public_repo_forbidden_words.md"
WORDS_FILE="$SCRIPT_DIR/../$SELF_EXCLUDE_PATH"
LOCAL_EXT="$SCRIPT_DIR/../config/public_repo_forbidden_words.local.txt"
# 公開側の正本が持つ番兵(正本の forbidden-regex 行と一字一句同じ)。実在の文には一致しない。
#   ★このファイル自身や試験が走査で自己ヒットしないよう、この正規表現が一致する綴りそのものは
#   ソースのどこにも書かない。文字クラス [-] で割って「正規表現としては一致するが、表記は一致しない」形にしてある。
SENTINEL_REGEX='no-real-word-sentinel[-]7c1e9a'

usage() {
    cat <<'EOF'
Usage: public_repo_scan.sh [--staged] [--range A..B] [--tree REV]
                           [--message-file FILE]
                           [--words-file FILE] [--local-ext FILE]

  公開リポジトリ向けの禁則語走査。走査モードを1つ以上指定する(複数可)。
  --staged            git diff -U0 --cached の追加行
  --range A..B        範囲内の各 commit の追加行と commit message
  --tree REV          REV の追跡木(バイナリ除外)
  --message-file FILE commit message 案
  --words-file FILE   正本リストの場所を差し替える(試験・検証用)
  --local-ext FILE    ローカル拡張の場所を差し替える(無ければ無視)

  出力はトップディレクトリ別のヒット件数つき。許可ドメイン(正本の allowed-email-domains)
  以外のメールアドレスは「要確認(WARN)」として別出力する(NG にはしない)。
  公開側の正本は具体語を持たない番兵のみ。具体語はローカル拡張だけが持ち、公開側が番兵のみで
  ローカル拡張に有効な語が無いときは、黙って通さず終了コード 2 で止まる(fail-closed)。
  終了コード: 0=ヒット0件(WARN は問わない) / 1=ヒットあり / 2=使い方誤り・実行失敗
EOF
}

die() {
    echo "エラー: $*" >&2
    exit 2
}

abspath() {
    case "$1" in
        /*) printf '%s' "$1" ;;
        *) printf '%s/%s' "$PWD" "$1" ;;
    esac
}

DO_STAGED=0
RANGES=()
TREES=()
MSGFILES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h | --help)
            usage
            exit 0
            ;;
        --staged)
            DO_STAGED=1
            shift
            ;;
        --range | --tree | --message-file | --words-file | --local-ext)
            [[ $# -ge 2 ]] || die "$1 には引数が要る"
            case "$1" in
                --range) RANGES+=("$2") ;;
                --tree) TREES+=("$2") ;;
                --message-file) MSGFILES+=("$(abspath "$2")") ;;
                --words-file) WORDS_FILE="$(abspath "$2")" ;;
                --local-ext) LOCAL_EXT="$(abspath "$2")" ;;
            esac
            shift 2
            ;;
        *)
            usage >&2
            die "未知の引数: $1"
            ;;
    esac
done

if [[ "$DO_STAGED" -eq 0 && ${#RANGES[@]} -eq 0 && ${#TREES[@]} -eq 0 && ${#MSGFILES[@]} -eq 0 ]]; then
    usage >&2
    die "走査モードを1つ以上指定せよ(--staged / --range / --tree / --message-file)"
fi

# ---------------------------------------------------------------- 禁則語の読込
BASE_N=0
BASE_DESC=""
EXT_N=0
REGEX=""
ALLOWED_DOMAINS=""   # 許可ドメイン(小文字・改行区切り)
ALLOWED_N=0
STRIP_ARGS=()        # 許可表記の除去に使う sed の引数
# メールアドレスの候補(局部@ドメイン。ドメインは末尾がアルファベット2字以上のもの)。
# pkg@1.2.3 のようなバージョン表記は末尾が数字なので拾わない。
EMAIL_RE='[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}'

# 許可ドメインの表記を空白へ置換する sed の引数を作る(STRIP_ARGS)。
#   許可されたドメインが禁則語の部分一致(自社ドメインに含まれる社名)で巻き込まれないよう、走査の直前に
#   そのドメインの表記「だけ」を消す。同じ行の他の禁則語は消さない。除去するのは次の2形のみ:
#     A: @<ドメイン>   直後が「英数字・.・- 以外」か行末(文末の . は可)。@ ごと消す(局部は残して走査する)
#     B: <ドメイン>    直前が「英数字・@・- 以外」か行頭、直後が A と同じ(URL のホスト等)
#   直前・直後の1文字は \1 \2 \3 で書き戻すので、隣の文字(日本語の禁則語の先頭バイトを含む)は消えない。
#   B の直前に @ を含めないのは、@<ドメイン> を A に任せるため(B が先に @ の後ろだけ消すと、@ が残って
#   個人識別子の局部を禁則語とする正規表現に一致してしまう)。`.` を直後に許すのは文末の句点のため。<許可ドメイン>.<他ドメイン>
#   や <英数字><許可ドメイン> のような紛らわしい表記は境界条件を満たさず除去されない(=禁則語として検出される)。
#   置換で新たな一致が現れうる(隣り合う同一ドメイン)ので、変化が無くなるまで繰り返す(:a … ta)。
build_strip_args() {
    local dom dre
    STRIP_ARGS=(-e ':a')
    while IFS= read -r dom; do
        [[ -z "$dom" ]] && continue
        dre="${dom//./\\.}"
        STRIP_ARGS+=(-e "s/@${dre}(\\.?)([^A-Za-z0-9.-]|\$)/ \\1\\2/I")
        STRIP_ARGS+=(-e "s/(^|[^A-Za-z0-9@-])${dre}(\\.?)([^A-Za-z0-9.-]|\$)/\\1 \\2\\3/I")
    done <<<"$ALLOWED_DOMAINS"
    STRIP_ARGS+=(-e 'ta')
}

load_regex() {
    [[ -f "$WORDS_FILE" ]] || die "禁則語リストが無い: $WORDS_FILE"
    [[ -r "$WORDS_FILE" ]] || die "禁則語リストが読めない: $WORDS_FILE"

    local base
    # ```forbidden-regex ブロックの非空行がちょうど1行であること(0行・2行以上はエラー)。
    base="$(awk '
        /^```forbidden-regex[[:space:]]*$/ { inblk = 1; blocks++; next }
        inblk && /^```[[:space:]]*$/ { inblk = 0; next }
        inblk { sub(/[ \t\r]+$/, ""); if ($0 != "") { n++; line = $0 } }
        END { if (blocks != 1 || n != 1) exit 3; print line }
    ' "$WORDS_FILE")" || die "禁則語リストの forbidden-regex ブロックが不正(ブロックはちょうど1個・中身はちょうど1行): $WORDS_FILE"

    BASE_N="$(awk -F'|' '{ print NF }' <<<"$base")"
    # 公開側が番兵のみか(ローカル拡張を結合する前の基本行で判定する)。
    local sentinel_only=0
    [[ "$base" == "$SENTINEL_REGEX" ]] && sentinel_only=1
    BASE_DESC="基本 ${BASE_N} 語"
    if [[ "$sentinel_only" -eq 1 ]]; then BASE_DESC="基本: 番兵のみ(具体語を持たない)"; fi

    # ```allowed-email-domains ブロック(0個か1個)。1行に1ドメイン。空行と # 行は無視、大小は無視(小文字へ)。
    local doms dom
    doms="$(awk '
        /^```allowed-email-domains[[:space:]]*$/ { inblk = 1; blocks++; next }
        inblk && /^```[[:space:]]*$/ { inblk = 0; next }
        inblk {
            sub(/\r$/, ""); sub(/^[ \t]+/, ""); sub(/[ \t]+$/, "")
            if ($0 == "" || $0 ~ /^#/) next
            print tolower($0)
        }
        END { if (blocks > 1) exit 3 }
    ' "$WORDS_FILE")" || die "禁則語リストの allowed-email-domains ブロックが不正(ブロックは0個か1個): $WORDS_FILE"
    while IFS= read -r dom; do
        [[ -z "$dom" ]] && continue
        # ドメインは英数字・ドット・ハイフンのみ(sed の正規表現へ展開するため、これ以外は拒否する)。
        [[ "$dom" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ && "$dom" == *.* ]] ||
            die "許可ドメインの書式が不正(英数字・ドット・ハイフンのみ・ドットを1つ以上含む): ${dom}"
        ALLOWED_N=$((ALLOWED_N + 1))
    done <<<"$doms"
    ALLOWED_DOMAINS="$doms"
    build_strip_args

    local frag
    if [[ -e "$LOCAL_EXT" ]]; then
        [[ -f "$LOCAL_EXT" ]] || die "ローカル拡張が通常ファイルではない: $LOCAL_EXT"
        [[ -r "$LOCAL_EXT" ]] || die "ローカル拡張が存在するのに読めない: $LOCAL_EXT"
        while IFS= read -r frag || [[ -n "$frag" ]]; do
            frag="${frag%$'\r'}"
            [[ -z "${frag//[[:space:]]/}" ]] && continue
            [[ "$frag" =~ ^[[:space:]]*# ]] && continue
            base="$base|($frag)"
            EXT_N=$((EXT_N + 1))
        done <"$LOCAL_EXT"
    fi

    # fail-closed(cmd_797): 公開側が番兵のみで、有効なローカル拡張も無ければ、走査できる具体語が1つも無い。
    # その状態の「0 件」は混入が無い証拠にならないので、黙って通さず止まる(拡張ファイルが無い場合も、
    # 有効な行が0本の場合も同じ)。
    if [[ "$sentinel_only" -eq 1 && "$EXT_N" -eq 0 ]]; then
        die "公開側の禁則語正本は番兵のみで、ローカル拡張に有効な語が1つも無い(拡張: ${LOCAL_EXT})。具体語ゼロの走査は 0 件でも混入が無いことを意味しないため、黙って通さず停止する(fail-closed)。ローカル拡張を用意してから再実行せよ(書式は正本ファイルの「ローカル拡張」節)"
    fi

    # 正規表現の健全性: 不正な ERE は exit 2、空文字列に一致する式(空の選択肢等)は
    # 全行に一致してしまうので拒否する。
    local rc=0
    printf '\n' | "$GREP_BIN" -q -i -E -e "$base" || rc=$?
    case "$rc" in
        0) die "禁則語の正規表現が空文字列に一致する(空の選択肢 a||b 等)。全行が一致してしまうので拒否する" ;;
        1) ;;
        *) die "禁則語の正規表現が不正(ERE として解釈できない)" ;;
    esac
    REGEX="$base"
}
load_regex

# ---------------------------------------------------------------- 作業ファイル
# ディレクトリの再帰削除は使わない。mktemp のファイルを固定数だけ作り、rm -f で片付ける。
REC="$(mktemp)"      # ヒット記録: top<TAB>path<TAB>loc<TAB>text
WARNREC="$(mktemp)"  # 要確認(WARN)記録: top<TAB>path<TAB>loc<TAB>address
ADDED="$(mktemp)"    # 走査対象の候補: top<TAB>path<TAB>loc<TAB>text
TEXTS="$(mktemp)"    # ADDED の text 列のみ(grep -n の行番号で ADDED と突合する)
STRIPPED="$(mktemp)" # TEXTS から許可ドメインの表記を除いたもの(行数・行順は TEXTS と同じ)
NUMS="$(mktemp)"     # grep -n の結果
EMAILS="$(mktemp)"   # grep -o -n で取ったメールアドレス候補(行番号:アドレス)
DIFF="$(mktemp)"     # git の生出力
MSGF="$(mktemp)"     # commit message 1件分
cleanup() { rm -f -- "$REC" "$WARNREC" "$ADDED" "$TEXTS" "$STRIPPED" "$NUMS" "$EMAILS" "$DIFF" "$MSGF"; }
trap cleanup EXIT

SUMMARY=()

# git を使うモードは、リポジトリ根へ移ってから走る(pathspec の . をリポジトリ全体にするため)。
# --message-file のパスは上で絶対化済み。
if [[ "$DO_STAGED" -eq 1 || ${#RANGES[@]} -gt 0 || ${#TREES[@]} -gt 0 ]]; then
    top="$(git rev-parse --show-toplevel 2>/dev/null)" || die "git リポジトリの中で実行せよ(--staged/--range/--tree)"
    cd -- "$top"
fi

# 統合 diff から追加行だけを取り出す。
#   入力: git diff / git log -p の -U0 出力。 出力: top<TAB>path<TAB>loc<TAB>text
#   ★ハンク内の「+」で始まる行は、本文が「++」で始まっていても追加行として数える
#   (ヘッダの +++ とは、最初の @@ より前かどうかで区別する)。
#   ★git は「特殊な文字を含む path」(既定設定では日本語などの非 ASCII を含む path も)を
#   `+++ "b/…\346\227…"` のように引用符つき・C 風エスケープで出す。b/ を外す前にこれを復号しないと、
#   トップディレクトリが「"b」のような接頭辞になる(G788-R03)。復号は unquote() が行う。
extract_added() {
    awk '
        function top_of(p,    i) { i = index(p, "/"); return i ? substr(p, 1, i - 1) : "(root)" }
        # 先頭が " の引用 path を復号する(閉じの " まで)。\ooo(八進)・\\ ・\" はそのまま復号し、
        # 制御文字(\t \n や 0x20 未満・0x7f)は表の区切りを壊さないよう ? にする。LC_ALL=C なのでバイト単位で動く。
        function unquote(s,    out, i, n, c, k, d) {
            out = ""; i = 2; n = length(s)
            while (i <= n) {
                c = substr(s, i, 1)
                if (c == "\"") break
                if (c != "\\") { out = out c; i++; continue }
                i++; c = substr(s, i, 1)
                if (c ~ /[0-7]/) {
                    k = 0
                    for (d = 0; d < 3 && substr(s, i, 1) ~ /[0-7]/; d++) { k = k * 8 + substr(s, i, 1); i++ }
                    out = out ((k < 32 || k == 127) ? "?" : sprintf("%c", k))
                    continue
                }
                if (c == "\\" || c == "\"") out = out c
                else if (c ~ /[abfnrtv]/) out = out "?"
                else out = out c
                i++
            }
            return out
        }
        # -U0 のハンク内に、接頭辞なしの行は現れない。ゆえに接頭辞なしの「commit <sha>」は必ず区切り行。
        /^commit [0-9a-f]+$/ { ctx = substr($2, 1, 7) " "; in_hunk = 0; path = ""; next }
        /^diff --git / { in_hunk = 0; path = ""; next }
        !in_hunk && /^\+\+\+ / {
            p = substr($0, 5)
            if (substr(p, 1, 1) == "\"") p = unquote(p); else sub(/\t.*$/, "", p)
            if (p == "/dev/null") path = ""; else { sub(/^b\//, "", p); path = p }
            next
        }
        /^@@ / {
            in_hunk = 1
            match($0, /\+[0-9]+/); ln = substr($0, RSTART + 1, RLENGTH - 1) + 0
            next
        }
        in_hunk && /^\+/ {
            printf "%s\t%s\t%s%s:%d\t%s\n", top_of(path), path, ctx, path, ln, substr($0, 2)
            ln++
            next
        }
    ' "$1"
}

# 許可ドメインの表記を空白へ除いた複製を作る(行数・行順は不変)。 $1=入力 $2=出力
strip_allowed() {
    sed -E "${STRIP_ARGS[@]}" "$1" >"$2" || die "許可表記の除去(sed)に失敗した"
    # 行番号で元の行と突合するため、行数が変わっていたら判定を続けない(fail-closed)。
    [[ "$(wc -l <"$1")" == "$(wc -l <"$2")" ]] || die "許可表記の除去で行数が変わった(判定不能)"
}

# ADDED(top<TAB>path<TAB>loc<TAB>text の行集合)を走査し、ヒットを REC へ、要確認(WARN)を WARNREC へ追記する。
#   ヒット: 許可ドメインの表記を除いた text を禁則語の正規表現で照合し、ヒット行は元の text で記録する。
#   WARN : 元の text からメールアドレスを抽出し、ドメインが許可ドメインに無いものを記録する(NG にしない)。
scan_added() {
    local rc=0
    cut -f4- "$ADDED" >"$TEXTS"
    strip_allowed "$TEXTS" "$STRIPPED"
    "$GREP_BIN" -a -i -E -n -e "$REGEX" "$STRIPPED" >"$NUMS" || rc=$?
    [[ "$rc" -le 1 ]] || die "grep の実行に失敗した(exit ${rc})"
    if [[ "$rc" -eq 0 ]]; then
        awk -F'\t' -v OFS='\t' '
            NR == FNR { split($0, a, ":"); hit[a[1]] = 1; next }
            (FNR in hit) { print }
        ' "$NUMS" "$ADDED" >>"$REC"
    fi

    rc=0
    "$GREP_BIN" -a -i -o -E -n -e "$EMAIL_RE" "$TEXTS" >"$EMAILS" || rc=$?
    [[ "$rc" -le 1 ]] || die "grep(メールアドレス抽出)の実行に失敗した(exit ${rc})"
    if [[ "$rc" -eq 0 ]]; then
        awk -F'\t' -v OFS='\t' -v allowed="${ALLOWED_DOMAINS//$'\n'/ }" -v ef="$EMAILS" '
            BEGIN {
                m = split(allowed, arr, " "); for (j = 1; j <= m; j++) if (arr[j] != "") ok[arr[j]] = 1
                while ((getline e < ef) > 0) {
                    i = index(e, ":"); n = substr(e, 1, i - 1) + 0
                    cnt[n]++; addr[n, cnt[n]] = substr(e, i + 1)
                }
            }
            (FNR in cnt) {
                for (k = 1; k <= cnt[FNR]; k++) {
                    a = addr[FNR, k]; d = tolower(substr(a, index(a, "@") + 1))
                    if (!(d in ok)) print $1, $2, $3, a
                }
            }
        ' "$ADDED" >>"$WARNREC"
    fi
}

# ADDED を走査し、走査規模を SUMMARY に残す(0件が「走査した上で0」か「何も走査していない」かを
# 見分けるための根拠)。
#   $1 = 表示用ラベル
filter_hits() {
    local label="$1" nlines nfiles
    nlines="$(wc -l <"$ADDED")"
    nfiles="$(cut -f2 "$ADDED" | sort -u | wc -l)"
    SUMMARY+=("走査: ${label} — 対象 ${nlines} 行 / ${nfiles} ファイル")
    if [[ "$nlines" -eq 0 ]]; then
        return 0
    fi
    scan_added
}

# git diff / git log -p へ渡す共通の引数。
#   --src-prefix / --dst-prefix を明示する: 利用者の設定(diff.noprefix・diff.mnemonicPrefix)で
#   接頭辞が変わっても、extract_added が期待する a/ b/ で出るようにする。
DIFF_OPTS=(--no-color --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/)

scan_staged() {
    git diff -U0 --cached "${DIFF_OPTS[@]}" \
        -- . ":(exclude)$SELF_EXCLUDE_PATH" >"$DIFF" || die "git diff --cached に失敗した"
    extract_added "$DIFF" >"$ADDED"
    filter_hits "staged(git diff -U0 --cached の追加行)"
}

# commit message を1つ走査する。 $1=ファイル $2=識別ラベル
#   行を ADDED と同じ形式(区分は (commit-message)・path 欄は識別ラベル)へ直して scan_added へ渡す。
#   ★ADDED を使い回すので、呼ぶ側は追加行の走査を終えてから呼ぶこと。
scan_message_text() {
    local file="$1" label="$2" nlines
    nlines="$(wc -l <"$file")"
    MSG_LINES=$((MSG_LINES + nlines))
    MSG_UNITS=$((MSG_UNITS + 1))
    awk -v label="$label" '{ printf "%s\t%s\t%s:%d\t%s\n", "(commit-message)", label, label, NR, $0 }' "$file" >"$ADDED"
    if [[ -s "$ADDED" ]]; then
        scan_added
    fi
}

MSG_LINES=0
MSG_UNITS=0

scan_message_file() {
    local file="$1"
    [[ -f "$file" ]] || die "message-file が無い: $file"
    MSG_LINES=0
    MSG_UNITS=0
    scan_message_text "$file" "message-file"
    SUMMARY+=("走査: message-file — 対象 ${MSG_LINES} 行 / 1 ファイル")
}

scan_range() {
    local range="$1" shas sha n=0
    [[ "$range" == *..* ]] || die "--range は A..B の形で指定せよ: $range"
    shas="$(git rev-list --reverse "$range")" || die "範囲を解決できない: $range"
    git log --reverse --no-merges "${DIFF_OPTS[@]}" -p -U0 \
        --format='commit %H' "$range" \
        -- . ":(exclude)$SELF_EXCLUDE_PATH" >"$DIFF" || die "git log -p に失敗した: $range"
    extract_added "$DIFF" >"$ADDED"
    filter_hits "range ${range} の各 commit の追加行"

    MSG_LINES=0
    MSG_UNITS=0
    if [[ -n "$shas" ]]; then
        while IFS= read -r sha; do
            git log -1 --format=%B "$sha" >"$MSGF" || die "commit message を読めない: $sha"
            scan_message_text "$MSGF" "commit ${sha:0:7}"
            n=$((n + 1))
        done <<<"$shas"
    fi
    SUMMARY+=("走査: range ${range} の commit message — ${n} commit / ${MSG_LINES} 行")
}

scan_tree() {
    local rev="$1" tree nfiles rc=0
    tree="$(git rev-parse --verify --quiet "${rev}^{tree}")" || die "木を解決できない: $rev"
    nfiles="$(git ls-tree -r --name-only "$tree" | wc -l)"
    # 候補は「禁則語に一致する行」と「メールアドレスを含む行」。許可ドメインの除去後の再照合は scan_added が行う
    # (除去は文字を消すだけなので、除去後に一致する行は必ず候補に含まれる)。
    git grep -I -i -n -z -E --no-color -e "$REGEX" -e "$EMAIL_RE" "$tree" \
        -- . ":(exclude)$SELF_EXCLUDE_PATH" >"$DIFF" || rc=$?
    [[ "$rc" -le 1 ]] || die "git grep の実行に失敗した(exit ${rc}): $rev"
    # -z の出力は「<tree>:<path> NUL 行 NUL 本文」。NUL を TAB へ替えて整形する。
    tr '\0' '\t' <"$DIFF" | awk -F'\t' -v OFS='\t' -v pre="$tree:" '{
        path = substr($1, length(pre) + 1)
        text = $0; sub(/^[^\t]*\t[^\t]*\t/, "", text)
        i = index(path, "/"); top = i ? substr(path, 1, i - 1) : "(root)"
        print top, path, path ":" $2, text
    }' >"$ADDED"
    if [[ -s "$ADDED" ]]; then
        scan_added
    fi
    SUMMARY+=("走査: tree ${rev} — 追跡ファイル ${nfiles} 本(バイナリは除外・未追跡と ignore 済みは対象外)")
}

# ---------------------------------------------------------------- 実行
if [[ "$DO_STAGED" -eq 1 ]]; then scan_staged; fi
for r in "${RANGES[@]+"${RANGES[@]}"}"; do scan_range "$r"; done
for t in "${TREES[@]+"${TREES[@]}"}"; do scan_tree "$t"; done
for m in "${MSGFILES[@]+"${MSGFILES[@]}"}"; do scan_message_file "$m"; done

# ---------------------------------------------------------------- 報告
total_lines="$(wc -l <"$REC")"
total_files="$(cut -f2 "$REC" | sort -u | wc -l)"
warn_lines="$(wc -l <"$WARNREC")"
warn_files="$(cut -f2 "$WARNREC" | sort -u | wc -l)"

echo "=== 禁則語走査 ==="
echo "正本リスト: ${WORDS_FILE}(${BASE_DESC} + ローカル拡張 ${EXT_N} 行 / 許可ドメイン ${ALLOWED_N} 件 / 自己除外: ${SELF_EXCLUDE_PATH} の1本のみ)"
for s in "${SUMMARY[@]}"; do echo "$s"; done

if [[ "$total_lines" -gt 0 ]]; then
    echo "--- ヒット行 (loc: 本文) ---"
    awk -F'\t' '{ t = $0; sub(/^[^\t]*\t[^\t]*\t[^\t]*\t/, "", t); print $3 ": " t }' "$REC"
fi

# トップディレクトリ別の件数表(行数の多い順)。 $1=記録ファイル
print_by_dir() {
    awk -F'\t' -v OFS='\t' '{
        lines[$1]++
        k = $1 SUBSEP $2
        if (!(k in seen)) { seen[k] = 1; files[$1]++ }
    } END { for (d in lines) print d, lines[d], files[d] }' "$1" |
        sort -t $'\t' -k2,2nr -k1,1
}

echo "--- ディレクトリ別ヒット件数 (トップディレクトリ / 行数 / ファイル数) ---"
if [[ "$total_lines" -eq 0 ]]; then
    echo "(ヒットなし)"
else
    print_by_dir "$REC"
fi
echo "---"
echo "合計: ${total_lines} 行 / ${total_files} ファイル"

# 要確認(WARN): 許可ドメイン外のメールアドレス。NG にはしない(exit 0 のまま)。0 件でも件数の行は出す。
if [[ "$warn_lines" -gt 0 ]]; then
    echo "--- 要確認(WARN): 許可ドメイン外のメールアドレス (loc: アドレス) ---"
    awk -F'\t' '{ print $3 ": " $4 }' "$WARNREC"
    echo "--- 要確認のディレクトリ別件数 (トップディレクトリ / 件数 / ファイル数) ---"
    print_by_dir "$WARNREC"
fi
echo "要確認(WARN・許可ドメイン外のメールアドレス): ${warn_lines} 件 / ${warn_files} ファイル(NG にはしない。業務繋がりかは目視で判断する)"

if [[ "$total_lines" -gt 0 ]]; then
    echo "判定: NG(禁則語あり)"
    exit 1
fi
echo "判定: OK(禁則語 0 件)"
exit 0
