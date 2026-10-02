#!/usr/bin/env bash
# count_by_dir.sh — /usr/bin/grep を直接呼び、マッチ件数をディレクトリ別
# 内訳で出す計数専用ツール。
#
# 背景(cmd_735実測): シェル関数版grep(ugrepラッパ、--ignore-files付与)
# はtmp/・skills/等のgitignore対象ディレクトリを黙って素通りする
# (同一検索で関数版26ファイル/実体413ファイルという実測差が出た)。
# 総数のみを見て報告すると、この種の見落としに気づけない。本ツールは
# フルパスの/usr/bin/grepを直接呼び、結果を常にディレクトリ別内訳付きで
# 出力することで、その失敗パターンを構造で防ぐ(総数のみの出力はしない)。
#
# .bats等のテストランナーは実行しない。数えるだけの道具である。
set -euo pipefail

GREP_BIN=/usr/bin/grep

usage() {
    cat <<'EOF'
Usage: count_by_dir.sh <pattern> [search_path]

  網羅性が必要な検索・棚卸し用の計数ツール。/usr/bin/grep をフルパスで
  直接呼ぶ(シェル関数版grepはgitignore領域〈tmp/・skills/等〉を黙って
  素通りするため、網羅性が必要な計数には使えない。cmd_735実測)。
  結果は必ずディレクトリ別内訳つきで出す(総数のみの出力はしない)。

  <pattern>      grep検索パターン(基本正規表現)
  [search_path]  検索対象ディレクトリ(省略時はカレントディレクトリ)
EOF
}

if [[ $# -lt 1 ]]; then
    usage >&2
    exit 1
fi

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    usage
    exit 0
fi

pattern="$1"
search_path="${2:-.}"

if [[ ! -d "$search_path" ]]; then
    echo "エラー: search_path '$search_path' はディレクトリではない" >&2
    exit 1
fi

norm_root="${search_path%/}"
[[ -n "$norm_root" ]] || norm_root="/"

tmp_files="$(mktemp)"
cleanup() { rm -f -- "$tmp_files"; }
trap cleanup EXIT

grep_exit=0
"$GREP_BIN" -rlIZ -- "$pattern" "$norm_root" >"$tmp_files" || grep_exit=$?

if [[ "$grep_exit" -ge 2 ]]; then
    echo "エラー: grep実行に失敗した(exit ${grep_exit})" >&2
    exit "$grep_exit"
fi

declare -A dir_counts
total=0

while IFS= read -r -d '' file; do
    rel="${file#"$norm_root"/}"
    if [[ "$rel" == */* ]]; then
        top_dir="${rel%%/*}"
    else
        top_dir="(root)"
    fi
    dir_counts["$top_dir"]=$(( ${dir_counts["$top_dir"]:-0} + 1 ))
    total=$(( total + 1 ))
done < "$tmp_files"

echo "=== ディレクトリ別内訳 (grep: $GREP_BIN, pattern: $pattern, path: $norm_root) ==="
if [[ "$total" -eq 0 ]]; then
    echo "(該当ファイルなし)"
else
    for dir in "${!dir_counts[@]}"; do
        printf '%s\t%d\n' "$dir" "${dir_counts[$dir]}"
    done | sort -t $'\t' -k2,2rn -k1,1
fi
echo "---"
echo "合計: ${total}ファイル"
