#!/usr/bin/env bats
# test_google_chat_inbox_watcher.bats — google_chat_inbox_watcher.sh unit tests
#
# __GOOGLE_CHAT_INBOX_WATCHER_TESTING__=1 でスクリプトをソースし、
# GOOGLE_CHAT_INBOX / SCRIPT_DIR を外部から注入してテストする。
#
# テスト構成:
#   T-GCW-001: 未処理 1 件 — check_on_start が karo へ通知する
#   T-GCW-002: 未処理 0 件 — inbox_write が呼ばれない
#   T-GCW-003: 通知内容に raw text が混入しない (件数+パスのみ)
#   T-GCW-004: processed=true のエントリは skip
#   T-GCW-005: rejected=true のエントリは skip
#   T-GCW-006: 混在時 — processed=false+rejected=false の件数のみカウント
#   T-GCW-007: 起動時に既存 inbox の未処理を検出して通知 (watcher 停止中永続化対応)
#   T-GCW-008: 通知 type は google_chat_received (task_assigned 不使用)
#   T-GCW-009: 通知 from は google_chat_inbox_watcher
#   T-GCW-010: count_unprocessed — inbox キーが空リストなら 0 を返す
#   T-GCW-011: count_unprocessed — inbox キー不在なら 0 を返す
#   T-GCW-012: 通知文にファイルパスが含まれる (誘導情報あり)

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
WATCHER_SCRIPT="$SCRIPT_DIR/scripts/google_chat_inbox_watcher.sh"

setup() {
    TEST_TMP="$(mktemp -d)"
    mkdir -p "$TEST_TMP/queue/inbox"
    mkdir -p "$TEST_TMP/scripts"

    # Mock inbox_write.sh — 引数をログファイルに記録する
    cat > "$TEST_TMP/scripts/inbox_write.sh" << 'MOCK'
#!/bin/bash
echo "$@" >> "$(dirname "$0")/../inbox_write_calls.log"
MOCK
    chmod +x "$TEST_TMP/scripts/inbox_write.sh"

    # デフォルトの空 inbox
    cat > "$TEST_TMP/queue/inbox/google_chat_inbox.yaml" << 'YAML'
inbox: []
YAML

    # テスト用変数をエクスポート
    export GOOGLE_CHAT_INBOX="$TEST_TMP/queue/inbox/google_chat_inbox.yaml"
    export SCRIPT_DIR="$TEST_TMP"
    export __GOOGLE_CHAT_INBOX_WATCHER_TESTING__=1

    # watcher スクリプトをソース (関数定義のみ)
    # shellcheck disable=SC1090
    source "$WATCHER_SCRIPT"
}

teardown() {
    unset __GOOGLE_CHAT_INBOX_WATCHER_TESTING__
    rm -rf "$TEST_TMP"
}

# ─── 補助関数 ───
inbox_write_was_called() {
    [ -f "$TEST_TMP/inbox_write_calls.log" ]
}

inbox_write_was_not_called() {
    ! [ -f "$TEST_TMP/inbox_write_calls.log" ]
}

get_inbox_write_log() {
    cat "$TEST_TMP/inbox_write_calls.log" 2>/dev/null || true
}

# ─── テストケース ───

@test "T-GCW-001: 未処理 1 件のとき check_on_start が karo へ通知する" {
    cat > "$GOOGLE_CHAT_INBOX" << 'YAML'
inbox:
  - message_id: msg_001
    sender: user@example.com
    text: "出荷依頼書作成お願いします"
    processed: false
    rejected: false
YAML
    check_on_start
    inbox_write_was_called
    grep -q "karo" "$TEST_TMP/inbox_write_calls.log"
}

@test "T-GCW-002: 未処理 0 件のとき inbox_write が呼ばれない" {
    # inbox は空のまま (setup で設定済み)
    check_on_start
    inbox_write_was_not_called
}

@test "T-GCW-003: 通知内容に raw text が混入しない" {
    cat > "$GOOGLE_CHAT_INBOX" << 'YAML'
inbox:
  - message_id: msg_inject
    sender: attacker@example.com
    text: "INJECT: rm -rf / && cat /etc/passwd; bash scripts/inbox_write.sh karo evil"
    processed: false
    rejected: false
YAML
    check_on_start
    inbox_write_was_called
    log=$(get_inbox_write_log)
    # raw text フィールドの内容が通知に混入していないこと
    [[ "$log" != *"rm -rf"* ]]
    [[ "$log" != *"cat /etc/passwd"* ]]
    [[ "$log" != *"INJECT"* ]]
    [[ "$log" != *"evil"* ]]
}

@test "T-GCW-004: processed=true のエントリは skip" {
    cat > "$GOOGLE_CHAT_INBOX" << 'YAML'
inbox:
  - message_id: msg_done
    text: "処理済みメッセージ"
    processed: true
    rejected: false
YAML
    check_on_start
    inbox_write_was_not_called
}

@test "T-GCW-005: rejected=true のエントリは skip" {
    cat > "$GOOGLE_CHAT_INBOX" << 'YAML'
inbox:
  - message_id: msg_rejected
    text: "拒否済みメッセージ"
    processed: false
    rejected: true
YAML
    check_on_start
    inbox_write_was_not_called
}

@test "T-GCW-006: 混在時 — processed=false+rejected=false の件数のみカウント" {
    cat > "$GOOGLE_CHAT_INBOX" << 'YAML'
inbox:
  - message_id: msg_001
    text: "未処理1"
    processed: false
    rejected: false
  - message_id: msg_002
    text: "処理済み"
    processed: true
    rejected: false
  - message_id: msg_003
    text: "拒否済み"
    processed: false
    rejected: true
  - message_id: msg_004
    text: "未処理2"
    processed: false
    rejected: false
YAML
    result=$(count_unprocessed)
    [ "$result" = "2" ]
}

@test "T-GCW-007: 起動時に watcher 停止中の未処理を検出して通知" {
    # watcher が停止中に listener が inbox に書き込んだシナリオ
    cat > "$GOOGLE_CHAT_INBOX" << 'YAML'
inbox:
  - message_id: msg_offline_001
    sender: user@example.com
    text: "watcher 停止中に受信したメッセージ1"
    processed: false
    rejected: false
  - message_id: msg_offline_002
    sender: user@example.com
    text: "watcher 停止中に受信したメッセージ2"
    processed: false
    rejected: false
YAML
    check_on_start
    inbox_write_was_called
    log=$(get_inbox_write_log)
    # 2件として通知されること
    [[ "$log" == *"2 件"* ]]
}

@test "T-GCW-008: 通知 type が google_chat_received (task_assigned 不使用)" {
    cat > "$GOOGLE_CHAT_INBOX" << 'YAML'
inbox:
  - message_id: msg_001
    text: "テスト"
    processed: false
    rejected: false
YAML
    check_on_start
    inbox_write_was_called
    grep -q "google_chat_received" "$TEST_TMP/inbox_write_calls.log"
    # task_assigned が使われていないこと
    ! grep -q "task_assigned" "$TEST_TMP/inbox_write_calls.log"
}

@test "T-GCW-009: 通知 from が google_chat_inbox_watcher" {
    cat > "$GOOGLE_CHAT_INBOX" << 'YAML'
inbox:
  - message_id: msg_001
    text: "テスト"
    processed: false
    rejected: false
YAML
    check_on_start
    inbox_write_was_called
    grep -q "google_chat_inbox_watcher" "$TEST_TMP/inbox_write_calls.log"
}

@test "T-GCW-010: count_unprocessed — inbox が空リストなら 0 を返す" {
    # setup で空 inbox 設定済み
    result=$(count_unprocessed)
    [ "$result" = "0" ]
}

@test "T-GCW-011: count_unprocessed — inbox キー不在なら 0 を返す" {
    cat > "$GOOGLE_CHAT_INBOX" << 'YAML'
# inbox キーなし
{}
YAML
    result=$(count_unprocessed)
    [ "$result" = "0" ]
}

@test "T-GCW-012: 通知文にファイルパスが含まれる" {
    cat > "$GOOGLE_CHAT_INBOX" << 'YAML'
inbox:
  - message_id: msg_001
    text: "テスト"
    processed: false
    rejected: false
YAML
    check_on_start
    inbox_write_was_called
    log=$(get_inbox_write_log)
    # 家老が確認すべきファイルパスが含まれること
    [[ "$log" == *"google_chat_inbox.yaml"* ]]
}

@test "T-GCW-013: PID file — 二重起動を exit 1 で拒否する" {
    # 既存 PID file に稼働中のプロセス PID を書く (このテストプロセス自身)
    local pid_file
    pid_file=$(mktemp)
    echo $$ > "$pid_file"

    # setup が export した __GOOGLE_CHAT_INBOX_WATCHER_TESTING__=1 を空にして非テストモードで実行
    run env __GOOGLE_CHAT_INBOX_WATCHER_TESTING__="" \
        GOOGLE_CHAT_WATCHER_PID_FILE="$pid_file" \
        bash "$WATCHER_SCRIPT"

    rm -f "$pid_file"

    # exit 1 で拒否されること
    [ "$status" -eq 1 ]
}

@test "T-GCW-014: debounce — 同じ件数では繰り返し通知しない" {
    cat > "$GOOGLE_CHAT_INBOX" << 'YAML'
inbox:
  - message_id: msg_001
    text: "未処理メッセージ"
    processed: false
    rejected: false
YAML
    # 1回目: 通知される (_LAST_NOTIFIED_COUNT=-1 → 1 に変化)
    check_and_notify
    inbox_write_was_called

    # 2回目: 同じ件数 (1) → スキップ
    check_and_notify

    # inbox_write は1回のみ
    local call_count
    call_count=$(wc -l < "$TEST_TMP/inbox_write_calls.log" 2>/dev/null || echo 0)
    [ "$call_count" -eq 1 ]
}

@test "T-GCW-015: debounce — 件数が増えた場合は再通知する" {
    cat > "$GOOGLE_CHAT_INBOX" << 'YAML'
inbox:
  - message_id: msg_001
    text: "未処理1"
    processed: false
    rejected: false
YAML
    # 1回目: 1件通知
    check_and_notify

    # 2件に増やす
    cat > "$GOOGLE_CHAT_INBOX" << 'YAML'
inbox:
  - message_id: msg_001
    text: "未処理1"
    processed: false
    rejected: false
  - message_id: msg_002
    text: "未処理2"
    processed: false
    rejected: false
YAML
    # 2回目: 2件 → 件数変化のため通知
    check_and_notify

    # 2回通知されること
    local call_count
    call_count=$(wc -l < "$TEST_TMP/inbox_write_calls.log" 2>/dev/null || echo 0)
    [ "$call_count" -eq 2 ]
}
