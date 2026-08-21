#!/usr/bin/env bats
# cmd_719 Phase B-1: tlc-cms内の*.ps1がUTF-8 BOM無しで保存され、Windows
# PowerShell 5.1がANSIコードページ(日本語環境ではShift-JIS)として誤読し
# 日本語コメント行で構文が破綻、launch.vbsが無反応のまま起動不能になった
# 実障害(cmd_712で1行だった日本語コメントがcmd_712自体で18行に増えた
# ことで顕在化)の再発防止。
#
# ★性質検査Pの再導入ではない(cmd_718で将軍が禁じたのは「コードが性質Pを
# 持つか」を検査する無限に形が変わるmatcherであり、本testが見る対象は
# 「ファイル先頭3バイトがEF BB BFか」という一意で有限な構造的事実のみ。
# 対象ファイル集合(*.ps1)も列挙ではなくglobで機械的に確定する
# (タスクYAML subtask_719_bom_fix B-1に基づく)。
#
# 検証対象working tree: TLC_CMS_WORKTREE環境変数で指定する
# (test_cmd_712_launch_ps1_t7.batsと同じ慣例)。setup()は呼出側が既に
# exportした値を上書きしない。未指定時の既定値はcanonical current tree
# /home/kato/dev/tlc-cms。

setup() {
    export TLC_CMS_WORKTREE="${TLC_CMS_WORKTREE:-/home/kato/dev/tlc-cms}"
}

# node_modules/.git/dist/buildはvendor・build成果物でありproductionの
# .ps1資産ではない(tlc-cms .gitignoreの除外対象と一致させる)。
ps1_files_under_worktree() {
    find "$TLC_CMS_WORKTREE" \
        -type d \( -name node_modules -o -name .git -o -name dist -o -name build \) -prune \
        -o -type f -name '*.ps1' -print
}

@test "前提: 検査対象working treeが存在し、既知の.ps1ファイル3件を含む" {
    [ -d "$TLC_CMS_WORKTREE" ]
    [ -f "$TLC_CMS_WORKTREE/launch.ps1" ]
    [ -f "$TLC_CMS_WORKTREE/launch.helpers.ps1" ]
    [ -f "$TLC_CMS_WORKTREE/launch.helpers.Tests.ps1" ]
}

@test "cmd_719 B-1: tlc-cms working tree配下の*.ps1は例外なくUTF-8 BOM(EF BB BF)付きで保存されている" {
    local checked=0
    local no_bom=()
    local f head3

    while IFS= read -r f; do
        checked=$((checked + 1))
        head3="$(head -c 3 -- "$f" | xxd -p)"
        if [ "$head3" != "efbbbf" ]; then
            no_bom+=("$f")
        fi
    done < <(ps1_files_under_worktree)

    # globが壊れて0件になった場合に無検査でPASSする事故を防ぐ(既知3件が下限)。
    [ "$checked" -ge 3 ]

    if [ "${#no_bom[@]}" -ne 0 ]; then
        echo "BOM無し.ps1ファイル(${#no_bom[@]}件):"
        printf '  %s\n' "${no_bom[@]}"
        return 1
    fi
}
