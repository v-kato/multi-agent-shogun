#!/usr/bin/env bats
# test_count_by_dir.bats — scripts/count_by_dir.sh の異常系・root分類テスト
#
# cmd_735 redo1 (軍師QC 2026-09-01T17:21:02): G734-COUNT-ERROR-01
# (無効regex等のgrepエラーがexit 0の「該当なし」に化けていた) と
# G734-COUNT-ROOT-02 (検索起点直下のファイルが(root)へ集約されず
# ファイル名そのままで内訳表示されていた) の再発防止用固定テスト。
# 無効regex・該当無し・正常複数dir(root分類含む)の3パターンを検証する。
#
# cmd_735 redo2 (軍師QC 2026-09-01T17:37:45): G735-R1-D002-TEST-01
# (teardownがD002-E1(d)の直前空値guardを欠いていた点と、無効regex
# テストがcount_by_dir.sh自身の「エラー」文言だけを見ておりgrep自身の
# stderr診断を握り潰されても検出できなかった点)の是正。

setup() {
    TEST_TMP="$(mktemp -d)"
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    SCRIPT="$PROJECT_ROOT/scripts/count_by_dir.sh"
}

teardown() {
    rm -rf -- "${TEST_TMP:?}"
}

@test "count_by_dir: invalid regex causes non-zero exit and shows grep stderr (G734-COUNT-ERROR-01)" {
    run bash "$SCRIPT" '[' "$TEST_TMP"
    [ "$status" -ge 2 ]
    [[ "$output" == *"エラー"* ]]
    [[ "$output" == *"/usr/bin/grep:"* ]]
}

@test "count_by_dir: no match returns exit 0 with zero total (grep exit 1 is normal)" {
    echo "harmless content" > "$TEST_TMP/file.txt"
    run bash "$SCRIPT" 'ZZZ_NO_SUCH_PATTERN_EXISTS_XYZZY_QUUX' "$TEST_TMP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"(該当ファイルなし)"* ]]
    [[ "$output" == *"合計: 0ファイル"* ]]
}

@test "count_by_dir: root-level files aggregate into (root), subdirs show own breakdown (G734-COUNT-ROOT-02)" {
    mkdir -p "$TEST_TMP/subA" "$TEST_TMP/subB"
    echo "MARKERPATTERN" > "$TEST_TMP/root_file.txt"
    echo "MARKERPATTERN" > "$TEST_TMP/root_file2.txt"
    echo "MARKERPATTERN" > "$TEST_TMP/subA/a1.txt"
    echo "MARKERPATTERN" > "$TEST_TMP/subA/a2.txt"
    echo "MARKERPATTERN" > "$TEST_TMP/subB/b1.txt"

    run bash "$SCRIPT" 'MARKERPATTERN' "$TEST_TMP"
    [ "$status" -eq 0 ]
    # root_file.txt はファイル名のままではなく (root) へ集約されること
    [[ "$output" != *"root_file.txt"* ]]
    [[ "$output" == *$'(root)\t2'* ]]
    [[ "$output" == *$'subA\t2'* ]]
    [[ "$output" == *$'subB\t1'* ]]
    [[ "$output" == *"合計: 5ファイル"* ]]
}
