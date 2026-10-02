#!/usr/bin/env bats
# test_permission_orphans.bats — scripts/permission_orphans.sh の試験 (cmd_799 ⑤)
#
# 権限要求の孤児記録(hook_resultが無く、received_atからtimeout+マージンを
# 超過した記録)の計数・一覧・退避(削除ではなくmv)を検証する。分類の定義は
# inbox_watcher.sh の has_pending_permission_request() と同一でなければ
# ならないため、同じ fixture を両者に判定させる一致試験(T-PO-009)を含む。
#
# テスト構成:
#   T-PO-001: list が resolved/pending/orphan を正しく数え、孤児だけを列挙する
#   T-PO-002: 記録ディレクトリが無くてもlistは成功し、その旨を示す
#   T-PO-003: archive(--applyなし)は予行で、何も動かさず退避先も作らない
#   T-PO-004: archive --apply は孤児だけを退避し、resolved/pending・決定ファイルは触れない
#   T-PO-005: 退避先に同名があれば上書きせず、元を残して非0で終わる
#   T-PO-006: 境界(timeout+マージンの内側=pending・外側=orphan)
#   T-PO-007: received_atが無い/解釈できない記録はpending(動かさない)
#   T-PO-008: 記録ディレクトリ直下以外(サブディレクトリ)は数えない・動かさない
#   T-PO-009: 同一fixtureでwatcherの未決判定と一致する(定義の食い違い検出)
#   T-PO-010: 不正な引数は使い方を出して終了コード2
#   T-PO-011: スクリプトは削除系(rm/rmdir/unlink/shred/-delete)を含まない(静的確認)
#
# SKIP=0。全試験が実アサーションを持つ。

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
TOOL="$SCRIPT_DIR/scripts/permission_orphans.sh"
WATCHER="$SCRIPT_DIR/scripts/inbox_watcher.sh"

setup() {
    TEST_TMP="$(mktemp -d)"
    REQ="$TEST_TMP/queue/state/permission_requests"
    DEC="$TEST_TMP/queue/state/permission_decisions"
    ORPH="$TEST_TMP/queue/state/permission_requests_orphaned"
    mkdir -p "$REQ" "$DEC"
    export __PERMISSION_ORPHANS_ROOT="$TEST_TMP"
    export PERMISSION_HOOK_TIMEOUT_SECONDS=100
    export __PERMISSION_HOOK_MARGIN_SECONDS=10
}

teardown() {
    rm -rf "$TEST_TMP"
}

# make_record <name> <age_seconds|none|garbage> [with_result]
make_record() {
    local name="$1" age="$2" with_result="${3:-}" ts
    {
        echo "request_id: ${name%.yaml}"
        echo "agent_id: ${name%%_*}"
        case "$age" in
            none) : ;;
            garbage) echo "received_at: 'not-a-date'" ;;
            *)
                ts="$(date -u -d "-${age} seconds" +%Y-%m-%dT%H:%M:%SZ)"
                echo "received_at: '${ts}'"
                ;;
        esac
        if [ -n "$with_result" ]; then
            echo "hook_result:"
            echo "  outcome: ${with_result}"
            echo "  returned_at: '2026-01-01T00:00:00Z'"
        fi
    } > "$REQ/$name"
}

# 標準fixture: resolved 1本 / pending 1本(境界の内側) / orphan 2本
make_standard_fixture() {
    make_record "agentx_resolved.yaml" 500 allow
    make_record "agentx_pending.yaml" 30
    make_record "agentx_orphan1.yaml" 500
    make_record "agentx_orphan2.yaml" 9999
}

@test "T-PO-001: list counts resolved/pending/orphan and lists only the orphans" {
    make_standard_fixture
    run bash "$TOOL" list
    [ "$status" -eq 0 ]
    [[ "$output" == *"total=4 resolved=1 pending=1 orphan=2"* ]]
    [[ "$output" == *"orphan: agentx_orphan1.yaml"* ]]
    [[ "$output" == *"orphan: agentx_orphan2.yaml"* ]]
    [[ "$output" != *"orphan: agentx_resolved.yaml"* ]]
    [[ "$output" != *"orphan: agentx_pending.yaml"* ]]
    # 引数なしの既定は list と同じ
    run bash "$TOOL"
    [ "$status" -eq 0 ]
    [[ "$output" == *"total=4 resolved=1 pending=1 orphan=2"* ]]
}

@test "T-PO-002: list succeeds and says so when the records directory does not exist" {
    rm -rf "$REQ"
    run bash "$TOOL" list
    [ "$status" -eq 0 ]
    [[ "$output" == *"記録ディレクトリが無い"* ]]
    [[ "$output" == *"total=0 resolved=0 pending=0 orphan=0"* ]]
}

@test "T-PO-003: archive without --apply is a dry-run: nothing moves and no destination is created" {
    make_standard_fixture
    run bash "$TOOL" archive
    [ "$status" -eq 0 ]
    [[ "$output" == *"[dry-run] would move: agentx_orphan1.yaml"* ]]
    [[ "$output" == *"[dry-run] would move: agentx_orphan2.yaml"* ]]
    [ -f "$REQ/agentx_orphan1.yaml" ]
    [ -f "$REQ/agentx_orphan2.yaml" ]
    [ ! -e "$ORPH" ]
}

@test "T-PO-004: archive --apply moves only the orphans; resolved/pending records and decision files stay" {
    make_standard_fixture
    echo "decision: deny" > "$DEC/agentx_orphan1.yaml"
    run bash "$TOOL" archive --apply
    [ "$status" -eq 0 ]
    [[ "$output" == *"moved: agentx_orphan1.yaml"* ]]
    [[ "$output" == *"moved: agentx_orphan2.yaml"* ]]

    # 孤児は退避先へ(内容そのまま)・元の場所には無い
    [ -f "$ORPH/agentx_orphan1.yaml" ]
    [ -f "$ORPH/agentx_orphan2.yaml" ]
    [ ! -e "$REQ/agentx_orphan1.yaml" ]
    [ ! -e "$REQ/agentx_orphan2.yaml" ]
    /usr/bin/grep -q '^request_id: agentx_orphan1$' "$ORPH/agentx_orphan1.yaml"

    # resolved・pendingは動かない
    [ -f "$REQ/agentx_resolved.yaml" ]
    [ -f "$REQ/agentx_pending.yaml" ]
    [ ! -e "$ORPH/agentx_resolved.yaml" ]
    [ ! -e "$ORPH/agentx_pending.yaml" ]

    # 決定ファイル(監査ログ)は触れない
    [ -f "$DEC/agentx_orphan1.yaml" ]
    [ "$(cat "$DEC/agentx_orphan1.yaml")" = "decision: deny" ]

    # 退避後は孤児0
    run bash "$TOOL" list
    [[ "$output" == *"total=2 resolved=1 pending=1 orphan=0"* ]]
}

@test "T-PO-005: archive --apply never overwrites a same-named file in the destination (source kept, nonzero exit)" {
    make_record "agentx_orphan1.yaml" 500
    mkdir -p "$ORPH"
    echo "preexisting archived content" > "$ORPH/agentx_orphan1.yaml"
    run bash "$TOOL" archive --apply
    [ "$status" -ne 0 ]
    [[ "$output" == *"skip"* ]]
    [ "$(cat "$ORPH/agentx_orphan1.yaml")" = "preexisting archived content" ]
    [ -f "$REQ/agentx_orphan1.yaml" ]
}

@test "T-PO-006: the boundary is timeout+margin (110s here): inside = pending, outside = orphan" {
    make_record "agentx_inside.yaml" 100
    make_record "agentx_outside.yaml" 130
    run bash "$TOOL" list
    [ "$status" -eq 0 ]
    [[ "$output" == *"total=2 resolved=0 pending=1 orphan=1"* ]]
    [[ "$output" == *"orphan: agentx_outside.yaml"* ]]
    [[ "$output" != *"orphan: agentx_inside.yaml"* ]]

    # timeoutを広げると同じ記録が境界の内側に入る(環境変数がhook・watcherと同じ名前で効く)
    PERMISSION_HOOK_TIMEOUT_SECONDS=1000 run bash "$TOOL" list
    [[ "$output" == *"total=2 resolved=0 pending=2 orphan=0"* ]]
}

@test "T-PO-007: a record with a missing or unparseable received_at is pending and never moved" {
    make_record "agentx_nodate.yaml" none
    make_record "agentx_baddate.yaml" garbage
    run bash "$TOOL" archive --apply
    [ "$status" -eq 0 ]
    [[ "$output" == *"total=2 resolved=0 pending=2 orphan=0"* ]]
    [ -f "$REQ/agentx_nodate.yaml" ]
    [ -f "$REQ/agentx_baddate.yaml" ]
    [ ! -e "$ORPH" ]
}

@test "T-PO-008: files below a subdirectory of the records directory are neither counted nor moved" {
    make_record "agentx_orphan1.yaml" 500
    mkdir -p "$REQ/sub"
    cp "$REQ/agentx_orphan1.yaml" "$REQ/sub/agentx_nested.yaml"
    run bash "$TOOL" archive --apply
    [ "$status" -eq 0 ]
    [[ "$output" == *"total=1 "* ]]
    [ -f "$REQ/sub/agentx_nested.yaml" ]
    [ -f "$ORPH/agentx_orphan1.yaml" ]
    [ ! -e "$ORPH/agentx_nested.yaml" ]
}

@test "T-PO-009: the tool agrees with the watcher's pending judgment on every fixture kind (no definition drift)" {
    # fixture 種別ごとに1ディレクトリを作り、ツールのpending本数と
    # watcher の has_pending_permission_request の真偽が一致することを確かめる。
    local kind expect_pending tool_out watcher_out
    for kind in "resolved:500:allow:0" "recent:30::1" "old:9999::0" "nodate:none::1" "baddate:garbage::1"; do
        IFS=: read -r label age result expect_pending <<< "$kind"
        rm -rf "$REQ"; mkdir -p "$REQ"
        make_record "agentp_${label}.yaml" "$age" "$result"

        tool_out="$(bash "$TOOL" list | head -1)"
        if [ "$expect_pending" -eq 1 ]; then
            [[ "$tool_out" == *"pending=1"* ]]
        else
            [[ "$tool_out" == *"pending=0"* ]]
        fi

        watcher_out="$(env AGENT_ID=agentp SCRIPT_DIR="$TEST_TMP" __INBOX_WATCHER_TESTING__=1 \
            PERMISSION_HOOK_TIMEOUT_SECONDS=100 __PERMISSION_HOOK_MARGIN_SECONDS=10 \
            bash -c "source '$WATCHER'; has_pending_permission_request && echo PENDING || echo RESOLVED")"
        if [ "$expect_pending" -eq 1 ]; then
            [ "$watcher_out" = "PENDING" ]
        else
            [ "$watcher_out" = "RESOLVED" ]
        fi
    done
}

@test "T-PO-010: invalid arguments print usage and exit 2" {
    run bash "$TOOL" frobnicate
    [ "$status" -eq 2 ]
    run bash "$TOOL" archive --force
    [ "$status" -eq 2 ]
    run bash "$TOOL" archive --apply extra
    [ "$status" -eq 2 ]
    run bash "$TOOL" list extra
    [ "$status" -eq 2 ]
}

@test "T-PO-011: the script contains no deletion commands (static check)" {
    run bash -c "/usr/bin/grep -v '^[[:space:]]*#' '$TOOL' | /usr/bin/grep -nE '(^|[^[:alnum:]_])(rm|rmdir|unlink|shred)([[:space:]]|\$)|-delete'"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}
