#!/usr/bin/env bash
# check_tracked.sh — 指定した path が git に追跡されているかを判定表示する読取専用の道具
# (cmd_788 AC④)。git への書込は一切しない。
#
# 背景: このリポジトリの .gitignore は「全部除外して許可行で戻す」ホワイトリスト方式である。
# 新規の lib/*.sh・scripts/*.sh・tests/**・docs/** は、許可行を足さない限り git status に
# 現れもせず、棚卸しから黙って漏れる(cmd_763 以降 2 週間・86 件が commit されなかった実例)。
# 「ignore されている」を明示して見つけるための道具である。
#
# 使い方:
#   bash scripts/check_tracked.sh [--require-committed] <path>...
#   --require-committed  未追跡・index のみ(未 commit)も NG として非0にする
#                        (commit 後の最終確認用)
#
# path ごとの判定(表示は先頭の記号):
#   IGNORED   .gitignore で無視されている(追跡されていない)。★常に NG
#   MISSING   作業木にも index にも無い。★常に NG
#   UNTRACKED 追跡されていないが ignore もされていない(git add 待ち)
#   STAGED    index にある(HEAD には無い=未 commit)
#   COMMITTED index にあり、HEAD にもある
# ディレクトリを渡すと、配下のファイルを 1 本ずつ判定する。COMMITTED 以外は 1 本ずつ表示し
# (状態ごとに 50 行まで)、ディレクトリごとの件数を添える。
#
# 終了コード: 0=NG なし / 1=NG あり / 2=使い方誤り・実行失敗。
#
# 用いる git: check-ignore(-q で無視の判定・-v で規則の特定)・ls-files(index)・ls-tree HEAD(commit 済み)・
# rev-parse --verify --quiet HEAD(HEAD の有無。0=あり・1=なし・それ以外は判定不能で exit 2)・
# status --short(作業木の状態表示)。いずれも読取のみ。
set -euo pipefail

export LC_ALL=C
# git status 等が index を更新しようとしない(=読取専用を保つ)ため。
export GIT_OPTIONAL_LOCKS=0
# ★GIT_LITERAL_PATHSPECS は設定しない。check-ignore と ls-tree は literal 指定を受け付けず
# rc=128 で失敗する(=「ignore ではない」と取り違える原因になる)。glob 文字を含む名前は、
# pathspec を取る ls-files / status にだけ :(literal) を付けて扱う。

usage() {
    cat <<'EOF'
Usage: check_tracked.sh [--require-committed] <path>...

  path が git に追跡されているかを判定表示する(読取専用)。
  判定: IGNORED(無視されている) / MISSING(存在しない) / UNTRACKED(未追跡) /
        STAGED(index のみ・未commit) / COMMITTED(HEAD にある)
  IGNORED と MISSING は常に NG(非0)。--require-committed を付けると
  UNTRACKED と STAGED も NG にする(commit 後の最終確認用)。
  ディレクトリを渡すと配下のファイルを 1 本ずつ判定する。
  終了コード: 0=NG なし / 1=NG あり / 2=使い方誤り・実行失敗
EOF
}

die() {
    echo "エラー: $*" >&2
    exit 2
}

REQUIRE_COMMITTED=0
PATHS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h | --help)
            usage
            exit 0
            ;;
        --require-committed)
            REQUIRE_COMMITTED=1
            shift
            ;;
        --)
            shift
            PATHS+=("$@")
            break
            ;;
        -*)
            usage >&2
            die "未知のオプション: $1"
            ;;
        *)
            PATHS+=("$1")
            shift
            ;;
    esac
done

if [[ ${#PATHS[@]} -eq 0 ]]; then
    usage >&2
    die "path を1つ以上指定せよ"
fi

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "git リポジトリの中で実行せよ"
# HEAD が無い(commit 前)リポジトリでは ls-tree HEAD が失敗するのが正常。それ以外の失敗は握りつぶさない。
# ★rev-parse --verify --quiet HEAD の終了コードは、HEAD あり=0・正常な「HEADなし」(未commitの新規repo)=1・
#   実行失敗(壊れた repo・権限・git 自体の異常など)=128 等。1 だけを「HEADなし」とし、それ以外は判定不能
#   として exit 2 にする(失敗を「HEADなし」と取り違えると commit 済みの対象を STAGED と表示してしまう)。
HAS_HEAD=0
head_rc=0
git rev-parse --verify --quiet HEAD >/dev/null 2>&1 || head_rc=$?
case "$head_rc" in
    0) HAS_HEAD=1 ;;
    1) ;;
    *) die "git rev-parse HEAD が判定不能(exit ${head_rc})" ;;
esac

N_COMMITTED=0
N_STAGED=0
N_UNTRACKED=0
N_IGNORED=0
N_MISSING=0
N_NG=0

# 1 本のファイル(または存在しない path)を判定する。結果は STATE / DETAIL に入れる。
# ★git の終了コードは 0/1 以外を「判定不能」として die する。失敗を「該当なし」と取り違えると
#   ignore されたファイルを UNTRACKED と表示してしまう(この道具の存在理由に反する)。
judge() {
    local p="$1" lp rule st head_hit rc
    lp=":(literal)$p"
    DETAIL=""
    rc=0
    git ls-files --error-unmatch -- "$lp" >/dev/null 2>&1 || rc=$?
    case "$rc" in
        0)
            head_hit=""
            if [[ "$HAS_HEAD" -eq 1 ]]; then
                head_hit="$(git ls-tree --name-only HEAD -- "$p")" || die "git ls-tree HEAD に失敗した: $p"
            fi
            if [[ -n "$head_hit" ]]; then STATE="COMMITTED"; else STATE="STAGED"; fi
            ;;
        1)
            if [[ ! -e "$p" && ! -L "$p" ]]; then
                # 存在しない path は ignore 規則に該当しても MISSING(綴り誤りの検出が先)。
                STATE="MISSING"
            else
                # ★判定は -q の終了コードで行う。-v は否定パターン(許可行 !...)に一致した path でも
                #   パターンを表示して exit 0 を返す(=「無視されている」を意味しない)ため、
                #   -v の終了コードで判定すると、許可行で再包含したファイルを IGNORED と誤判定する。
                #   -v は、無視されていると分かった後の規則表示にだけ使う。
                rc=0
                git check-ignore -q -- "$p" 2>/dev/null || rc=$?
                case "$rc" in
                    0)
                        STATE="IGNORED"
                        rule="$(git check-ignore -v -- "$p")" || die "git check-ignore -v が判定不能: $p"
                        DETAIL="規則: ${rule%%$'\t'*}"
                        ;;
                    1) STATE="UNTRACKED" ;;
                    *) die "git check-ignore が判定不能(exit ${rc}): $p" ;;
                esac
            fi
            ;;
        *) die "git ls-files が判定不能(exit ${rc}): $p" ;;
    esac
    st="$(git status --short -- "$lp")" || die "git status に失敗した: $p"
    st="${st%%$'\n'*}"
    if [[ -n "$st" ]]; then
        DETAIL="${DETAIL:+$DETAIL / }status: ${st}"
    fi
}

count_state() {
    case "$1" in
        COMMITTED) N_COMMITTED=$((N_COMMITTED + 1)) ;;
        STAGED) N_STAGED=$((N_STAGED + 1)) ;;
        UNTRACKED) N_UNTRACKED=$((N_UNTRACKED + 1)) ;;
        IGNORED) N_IGNORED=$((N_IGNORED + 1)) ;;
        MISSING) N_MISSING=$((N_MISSING + 1)) ;;
    esac
    case "$1" in
        IGNORED | MISSING) N_NG=$((N_NG + 1)) ;;
        UNTRACKED | STAGED)
            if [[ "$REQUIRE_COMMITTED" -eq 1 ]]; then N_NG=$((N_NG + 1)); fi
            ;;
    esac
}

show() {
    printf '%-9s %s%s\n' "$1" "$2" "${3:+  ($3)}"
}

echo "=== 追跡確認 (require-committed: ${REQUIRE_COMMITTED}) ==="

for p in "${PATHS[@]}"; do
    if [[ -d "$p" && ! -L "$p" ]]; then
        # ディレクトリ: 配下のファイルを 1 本ずつ判定する(.git は除く)。
        d_committed=0 d_other=0
        declare -A shown=()
        while IFS= read -r -d '' f; do
            judge "$f"
            count_state "$STATE"
            if [[ "$STATE" == "COMMITTED" ]]; then
                d_committed=$((d_committed + 1))
                continue
            fi
            d_other=$((d_other + 1))
            shown[$STATE]=$((${shown[$STATE]:-0} + 1))
            if [[ "${shown[$STATE]}" -le 50 ]]; then
                show "$STATE" "$f" "$DETAIL"
            elif [[ "${shown[$STATE]}" -eq 51 ]]; then
                echo "          ...(${STATE} はこれ以降を省略)"
            fi
        done < <(find "$p" -name .git -prune -o -type f -print0)
        echo "DIR       ${p}  (COMMITTED ${d_committed} / それ以外 ${d_other})"
        unset shown
    else
        judge "$p"
        count_state "$STATE"
        show "$STATE" "$p" "$DETAIL"
    fi
done

echo "---"
echo "合計: COMMITTED ${N_COMMITTED} / STAGED ${N_STAGED} / UNTRACKED ${N_UNTRACKED} / IGNORED ${N_IGNORED} / MISSING ${N_MISSING}"
if [[ "$N_NG" -gt 0 ]]; then
    echo "判定: NG(${N_NG} 件)"
    exit 1
fi
echo "判定: OK"
exit 0
