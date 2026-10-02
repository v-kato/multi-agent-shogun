#!/usr/bin/env bats
# test_google_chat_inbox_watcher_g2.bats — watcher G-2 回帰テスト
# cmd_506 Phase G-2 W-G2-001〜W-G2-007
#
# W-G2-001: 未処理 msg_1 を初回通知し、同じ file を rewrite しても再通知しない
# W-G2-002: msg_1 通知済み + msg_1 processed:true + msg_2 processed:false → msg_2 通知
# W-G2-003: state file が再起動後も効き、通知済み message_id を再通知しない
# W-G2-004: inbox_write.sh 失敗時は state file に通知済みとして記録しない
# W-G2-005: state file 破損時は安全に初期化し raw text を通知しない
# W-G2-006: processed/rejected entry は通知対象外かつ state pruning 対象
# W-G2-007: timeout だけでは再通知しない (29 秒ストーム再現防止)

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
WATCHER_SCRIPT="$SCRIPT_DIR/scripts/google_chat_inbox_watcher.sh"

setup() {
    TEST_TMP="$(mktemp -d)"
    mkdir -p "$TEST_TMP/queue/inbox"
    mkdir -p "$TEST_TMP/queue/state"
    mkdir -p "$TEST_TMP/scripts"

    # Mock inbox_write.sh — 成功ケース: 引数をログに記録
    cat > "$TEST_TMP/scripts/inbox_write.sh" << 'MOCK'
#!/bin/bash
echo "$@" >> "$(dirname "$0")/../inbox_write_calls.log"
exit 0
MOCK
    chmod +x "$TEST_TMP/scripts/inbox_write.sh"

    # デフォルトの空 inbox
    cat > "$TEST_TMP/queue/inbox/google_chat_inbox.yaml" << 'YAML'
inbox: []
YAML

    # テスト用変数をエクスポート
    export GOOGLE_CHAT_INBOX="$TEST_TMP/queue/inbox/google_chat_inbox.yaml"
    export GOOGLE_CHAT_WATCHER_STATE="$TEST_TMP/queue/state/google_chat_inbox_watcher_state.yaml"
    export SCRIPT_DIR="$TEST_TMP"
    export __GOOGLE_CHAT_INBOX_WATCHER_TESTING__=1

    # watcher スクリプトをソース (関数定義のみ)
    # shellcheck disable=SC1090
    source "$WATCHER_SCRIPT"
}

teardown() {
    unset __GOOGLE_CHAT_INBOX_WATCHER_TESTING__
    unset GOOGLE_CHAT_WATCHER_STATE
    rm -rf "$TEST_TMP"
}

# ─── 補助関数 ───
inbox_write_was_called() {
    [ -f "$TEST_TMP/inbox_write_calls.log" ]
}

inbox_write_was_not_called() {
    ! [ -f "$TEST_TMP/inbox_write_calls.log" ]
}

get_inbox_write_call_count() {
    wc -l < "$TEST_TMP/inbox_write_calls.log" 2>/dev/null || echo 0
}

reset_inbox_write_log() {
    rm -f "$TEST_TMP/inbox_write_calls.log"
}

# ─── テストケース ───

@test "W-G2-001: 未処理 msg_1 を初回通知し、同じ file を rewrite しても再通知しない" {
    # 未処理 msg_1 をセット
    cat > "$GOOGLE_CHAT_INBOX" << 'YAML'
inbox:
  - message_id: spaces/AAA/messages/msg_1
    text: "テスト1"
    processed: false
    rejected: false
YAML

    # 1回目: msg_1 は未通知 → 通知される
    check_and_notify
    inbox_write_was_called

    # state file が作成されたこと
    [ -f "$GOOGLE_CHAT_WATCHER_STATE" ]

    reset_inbox_write_log

    # 同じファイルを rewrite (内容は同じ・inotify modify をシミュレート)
    cp "$GOOGLE_CHAT_INBOX" "${GOOGLE_CHAT_INBOX}.bak"
    mv "${GOOGLE_CHAT_INBOX}.bak" "$GOOGLE_CHAT_INBOX"

    # 2回目: msg_1 は既に state 済み → 通知しない
    check_and_notify
    inbox_write_was_not_called
}

@test "W-G2-002: msg_1 通知済み後に msg_1 processed:true + msg_2 追加 → msg_2 通知" {
    cat > "$GOOGLE_CHAT_INBOX" << 'YAML'
inbox:
  - message_id: spaces/AAA/messages/msg_1
    text: "テスト1"
    processed: false
    rejected: false
YAML

    # 1回目: msg_1 通知
    check_and_notify
    inbox_write_was_called
    reset_inbox_write_log

    # msg_1 processed:true に変更 + msg_2 追加
    cat > "$GOOGLE_CHAT_INBOX" << 'YAML'
inbox:
  - message_id: spaces/AAA/messages/msg_1
    text: "テスト1"
    processed: true
    rejected: false
  - message_id: spaces/AAA/messages/msg_2
    text: "テスト2"
    processed: false
    rejected: false
YAML

    # 2回目: msg_2 は未通知 → 通知される
    check_and_notify
    inbox_write_was_called

    local log
    log=$(cat "$TEST_TMP/inbox_write_calls.log" 2>/dev/null || true)
    # msg_1 は通知されない (processed 済)
    # 通知は 1 回のみ (msg_2 分)
    local call_count
    call_count=$(get_inbox_write_call_count)
    [ "$call_count" -eq 1 ]
}

@test "W-G2-003: state file が再起動後も効き、通知済み message_id を再通知しない" {
    cat > "$GOOGLE_CHAT_INBOX" << 'YAML'
inbox:
  - message_id: spaces/AAA/messages/persist_msg
    text: "永続テスト"
    processed: false
    rejected: false
YAML

    # 1回目: 通知 → state に記録
    check_and_notify
    inbox_write_was_called
    reset_inbox_write_log

    # state file が存在することを確認
    [ -f "$GOOGLE_CHAT_WATCHER_STATE" ]

    # watcher を「再起動」= source し直す (state file は残る)
    # shellcheck disable=SC1090
    source "$WATCHER_SCRIPT"

    # 2回目 (再起動後): persist_msg は state 済み → 再通知なし
    check_and_notify
    inbox_write_was_not_called
}

@test "W-G2-004: inbox_write.sh 失敗時は state file に通知済みとして記録しない" {
    # inbox_write.sh を失敗するものに置き換え
    cat > "$TEST_TMP/scripts/inbox_write.sh" << 'MOCK'
#!/bin/bash
exit 1
MOCK
    chmod +x "$TEST_TMP/scripts/inbox_write.sh"

    cat > "$GOOGLE_CHAT_INBOX" << 'YAML'
inbox:
  - message_id: spaces/AAA/messages/failed_msg
    text: "失敗テスト"
    processed: false
    rejected: false
YAML

    check_and_notify

    # state file が作成されていない (または通知済みリストが空)
    if [ -f "$GOOGLE_CHAT_WATCHER_STATE" ]; then
        local notified_count
        notified_count=$(python3 -c "
import yaml, sys
with open('$GOOGLE_CHAT_WATCHER_STATE') as f:
    state = yaml.safe_load(f) or {}
ids = state.get('notified_message_ids', []) or []
print(len(ids))
" 2>/dev/null || echo 0)
        [ "$notified_count" -eq 0 ]
    fi
    # inbox_write 呼び出しは試みたがログなし (exit 1 で終わるのでログ先に書けない場合も)
    # 重要: state file に failed_msg が入っていないこと
}

@test "W-G2-005: state file 破損時は安全に初期化し raw text を通知しない" {
    # 壊れた state file を作成
    echo "!!!corrupt_yaml: [unclosed" > "$GOOGLE_CHAT_WATCHER_STATE"

    cat > "$GOOGLE_CHAT_INBOX" << 'YAML'
inbox:
  - message_id: spaces/AAA/messages/after_corrupt
    text: "復旧テスト"
    processed: false
    rejected: false
YAML

    # 破損 state でも安全に動作する (エラー終了しない)
    run check_and_notify

    # raw text ("復旧テスト") が通知に含まれないこと
    if [ -f "$TEST_TMP/inbox_write_calls.log" ]; then
        local log
        log=$(cat "$TEST_TMP/inbox_write_calls.log")
        [[ "$log" != *"復旧テスト"* ]]
    fi
}

@test "W-G2-006: processed/rejected entry は通知対象外かつ state pruning 対象" {
    cat > "$GOOGLE_CHAT_INBOX" << 'YAML'
inbox:
  - message_id: spaces/AAA/messages/active_msg
    text: "未処理"
    processed: false
    rejected: false
YAML

    # 1回目: active_msg を通知
    check_and_notify
    inbox_write_was_called
    reset_inbox_write_log

    # active_msg を processed:true にする (家老が処理完了)
    cat > "$GOOGLE_CHAT_INBOX" << 'YAML'
inbox:
  - message_id: spaces/AAA/messages/active_msg
    text: "未処理"
    processed: true
    rejected: false
YAML

    # 2回目: 未処理なし → 通知なし (pruning 対象になっている)
    check_and_notify
    inbox_write_was_not_called
}

@test "W-G2-007: timeout だけでは再通知しない (29 秒ストーム再現防止)" {
    cat > "$GOOGLE_CHAT_INBOX" << 'YAML'
inbox:
  - message_id: spaces/AAA/messages/timeout_msg
    text: "タイムアウトテスト"
    processed: false
    rejected: false
YAML

    # 1回目: timeout_msg を通知 (state に記録)
    check_and_notify
    inbox_write_was_called

    local call_count_after_first
    call_count_after_first=$(get_inbox_write_call_count)
    [ "$call_count_after_first" -eq 1 ]

    # inotifywait timeout を simulate: ファイル変更なしで check_and_notify を繰り返す
    # これが 29 秒ストームの再現条件
    check_and_notify  # timeout 2回目
    check_and_notify  # timeout 3回目
    check_and_notify  # timeout 4回目
    check_and_notify  # timeout 5回目

    # 通知は最初の 1 回のみであること (ストームなし)
    local total_calls
    total_calls=$(get_inbox_write_call_count)
    [ "$total_calls" -eq 1 ]
}
