#!/usr/bin/env bats
# test_google_chat_inbox_watcher_g3.bats — watcher G-3 回帰テスト
# cmd_544 Phase G-3 修正の検証
#
# T-G3-001: _parse_watcher_args — --inbox 引数を GOOGLE_CHAT_INBOX として解釈
# T-G3-002: _parse_watcher_args — --target 引数を NOTIFY_TARGET として解釈
# T-G3-003: _parse_watcher_args — デフォルト値 (target=karo, inbox 未設定)
# T-G3-004: atomic rename (mv) → main-loop 検知 → 通知 1 回 (inotifywait 必須)
# T-G3-005: basename filter — 対象外ファイルの modify では通知しない
# T-G3-006: stuck entry startup — 未通知 entry 在り状態で起動 → 起動時チェックで通知
# T-G3-007: timeout safety net — inotify が来なくても timeout 後に check_and_notify
# T-G3-008: state path — GOOGLE_CHAT_WATCHER_STATE 未設定時に inbox と同 root に解決

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
WATCHER_SCRIPT="$SCRIPT_DIR/scripts/google_chat_inbox_watcher.sh"

setup() {
    TEST_TMP="$(mktemp -d)"
    mkdir -p "$TEST_TMP/queue/inbox"
    mkdir -p "$TEST_TMP/queue/state"
    mkdir -p "$TEST_TMP/scripts"

    # Mock inbox_write.sh — 引数をログに記録して成功
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

    # テスト用変数 (テストモードで関数テスト)
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
    unset NOTIFY_TARGET
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

get_inbox_write_log() {
    cat "$TEST_TMP/inbox_write_calls.log" 2>/dev/null || true
}

# ─── 引数解析テスト (T-G3-001〜T-G3-003) ───

@test "T-G3-001: _parse_watcher_args — --inbox 引数を受け取る" {
    _parse_watcher_args --inbox /custom/path/inbox.yaml --target karo
    [ "$_PARSED_INBOX" = "/custom/path/inbox.yaml" ]
}

@test "T-G3-002: _parse_watcher_args — --target 引数を受け取る" {
    _parse_watcher_args --inbox /some/inbox.yaml --target testbot
    [ "$_PARSED_TARGET" = "testbot" ]
}

@test "T-G3-003: _parse_watcher_args — デフォルト値 (inbox 空・target=karo)" {
    _parse_watcher_args
    [ "$_PARSED_INBOX" = "" ]
    [ "$_PARSED_TARGET" = "karo" ]
}

# ─── State path テスト (T-G3-008) ───

@test "T-G3-008: state path — GOOGLE_CHAT_WATCHER_STATE 未設定時に inbox と同 root" {
    unset GOOGLE_CHAT_WATCHER_STATE

    # inbox: /tmp/.../queue/inbox/google_chat_inbox.yaml
    # 期待 state: /tmp/.../queue/state/google_chat_inbox_watcher_state.yaml
    local expected_state
    expected_state="$(dirname "$(dirname "$GOOGLE_CHAT_INBOX")")/state/google_chat_inbox_watcher_state.yaml"

    local actual_state
    actual_state=$(_watcher_state_path)

    [ "$actual_state" = "$expected_state" ]
}

# ─── stuck entry startup テスト (T-G3-006) ───

@test "T-G3-006: stuck entry startup — 未通知 entry 在りで起動 → 起動時チェックで通知" {
    cat > "$GOOGLE_CHAT_INBOX" << 'YAML'
inbox:
  - message_id: c_yefWdG33k
    text: "stuck entry テスト"
    processed: false
    rejected: false
    intent:
      status: pending
    karo_decision:
      status: pending
YAML

    check_on_start
    inbox_write_was_called
    local log
    log=$(get_inbox_write_log)
    [[ "$log" == *"karo"* ]] || [[ "$log" == *"${NOTIFY_TARGET:-karo}"* ]]
    # 通知は 1 回のみ
    [ "$(get_inbox_write_call_count)" -eq 1 ]
}

# ─── timeout safety net テスト (T-G3-007) ───

@test "T-G3-007: timeout safety net — check_and_notify が timeout 経路でも実行される" {
    cat > "$GOOGLE_CHAT_INBOX" << 'YAML'
inbox:
  - message_id: timeout_safety_msg
    text: "safety net テスト"
    processed: false
    rejected: false
YAML

    # timeout 経路は check_and_notify を直接呼ぶことで再現
    check_and_notify
    inbox_write_was_called
    [ "$(get_inbox_write_call_count)" -eq 1 ]

    # 2 回目 (state 済み) → 通知なし
    check_and_notify
    [ "$(get_inbox_write_call_count)" -eq 1 ]
}

# ─── main-loop 統合テスト (T-G3-004, T-G3-005) ───
# inotifywait が必要。preflight で確認し、なければテスト失敗とする。

@test "T-G3-004: atomic rename (mv) → main-loop 検知 → 通知 1 回" {
    if ! command -v inotifywait &>/dev/null; then
        echo "PREFLIGHT FAIL: inotifywait not found" >&2
        false
    fi

    local watcher_pid_file="$TEST_TMP/watcher_g3_004.pid"

    # 非テストモードで起動: __GOOGLE_CHAT_INBOX_WATCHER_TESTING__ を空に override
    # setup() で export=1 されているが env で上書き
    __GOOGLE_CHAT_INBOX_WATCHER_TESTING__="" \
    INOTIFY_TIMEOUT=3 \
    GOOGLE_CHAT_WATCHER_PID_FILE="$watcher_pid_file" \
    GOOGLE_CHAT_SCRIPT_DIR="$TEST_TMP" \
    GOOGLE_CHAT_WATCHER_STATE="$TEST_TMP/queue/state/watcher_state_g3.yaml" \
    bash "$WATCHER_SCRIPT" \
        --inbox "$TEST_TMP/queue/inbox/google_chat_inbox.yaml" \
        --target karo &
    local bg_pid=$!

    sleep 0.8

    # atomic rename: temp file を作成して mv で inbox に置換
    local tmp_inbox="$TEST_TMP/queue/inbox/.google_chat_inbox.yaml.tmp"
    cat > "$tmp_inbox" << 'YAML'
inbox:
  - message_id: atomic_rename_test_001
    text: "atomic rename テスト"
    processed: false
    rejected: false
YAML
    mv "$tmp_inbox" "$TEST_TMP/queue/inbox/google_chat_inbox.yaml"

    # 通知されるまで待つ (最大 8 秒)
    local waited=0
    while [ "$waited" -lt 16 ] && ! inbox_write_was_called; do
        sleep 0.5
        waited=$((waited + 1))
    done

    # watcher を停止
    kill "$bg_pid" 2>/dev/null || true
    wait "$bg_pid" 2>/dev/null || true
    rm -f "$watcher_pid_file"

    inbox_write_was_called
    [ "$(get_inbox_write_call_count)" -eq 1 ]
}

@test "T-G3-009: SCRIPT_DIR != inbox root — notify_karo は inbox root 側の inbox_write.sh を呼ぶ" {
    # root A: TEST_TMP (GOOGLE_CHAT_INBOX のプロジェクトルート)
    # root B: TEST_TMP_B (worktree を模擬 — SCRIPT_DIR がここを指す)
    local TEST_TMP_B
    TEST_TMP_B="$(mktemp -d)"
    mkdir -p "$TEST_TMP_B/scripts"
    mkdir -p "$TEST_TMP_B/queue/inbox"

    # root A の inbox_write.sh — 呼ばれるべきもの (ROOT_A マーカー付き)
    cat > "$TEST_TMP/scripts/inbox_write.sh" << 'MOCK_A'
#!/bin/bash
echo "ROOT_A:$*" >> "$(dirname "$0")/../inbox_write_calls_a.log"
exit 0
MOCK_A
    chmod +x "$TEST_TMP/scripts/inbox_write.sh"

    # root B の inbox_write.sh — 呼ばれてはいけないもの (ROOT_B マーカー付き)
    cat > "$TEST_TMP_B/scripts/inbox_write.sh" << 'MOCK_B'
#!/bin/bash
echo "ROOT_B:$*" >> "$(dirname "$0")/../inbox_write_calls_b.log"
exit 0
MOCK_B
    chmod +x "$TEST_TMP_B/scripts/inbox_write.sh"

    # SCRIPT_DIR を worktree (root B) に変更
    export SCRIPT_DIR="$TEST_TMP_B"
    # GOOGLE_CHAT_INBOX は root A のまま
    # GOOGLE_CHAT_INBOX_WRITE_ROOT / SHOGUN_ROOT は未設定 — 推定ロジック発動

    # 未処理エントリを root A の inbox に追加
    cat > "$GOOGLE_CHAT_INBOX" << 'YAML'
inbox:
  - message_id: root_split_regression_001
    text: "root 分離回帰テスト"
    processed: false
    rejected: false
YAML

    NOTIFY_TARGET="karo" check_and_notify

    # root A の log が存在する → 正しい inbox_write.sh が呼ばれた
    [ -f "$TEST_TMP/inbox_write_calls_a.log" ]
    local log_a
    log_a=$(cat "$TEST_TMP/inbox_write_calls_a.log")
    [[ "$log_a" == ROOT_A:* ]]

    # root B の log は存在しない → worktree 側 inbox_write.sh は呼ばれていない
    ! [ -f "$TEST_TMP_B/inbox_write_calls_b.log" ]

    rm -rf "$TEST_TMP_B"
}

@test "T-G3-010: --shogun-root 引数が _watcher_inbox_write_root の優先 source になる" {
    _parse_watcher_args --shogun-root /explicit/shogun/root --inbox /some/queue/inbox/foo.yaml
    [ "$_PARSED_SHOGUN_ROOT" = "/explicit/shogun/root" ]

    # _watcher_inbox_write_root は _PARSED_SHOGUN_ROOT を GOOGLE_CHAT_INBOX 推定より優先する
    local root
    root=$(_watcher_inbox_write_root)
    [ "$root" = "/explicit/shogun/root" ]
}

@test "T-G3-005: basename filter — 対象外ファイルの moved_to では通知しない" {
    if ! command -v inotifywait &>/dev/null; then
        echo "PREFLIGHT FAIL: inotifywait not found" >&2
        false
    fi

    local watcher_pid_file="$TEST_TMP/watcher_g3_005.pid"

    # 非テストモードで起動
    __GOOGLE_CHAT_INBOX_WATCHER_TESTING__="" \
    INOTIFY_TIMEOUT=3 \
    GOOGLE_CHAT_WATCHER_PID_FILE="$watcher_pid_file" \
    GOOGLE_CHAT_SCRIPT_DIR="$TEST_TMP" \
    GOOGLE_CHAT_WATCHER_STATE="$TEST_TMP/queue/state/watcher_state_g3_005.yaml" \
    bash "$WATCHER_SCRIPT" \
        --inbox "$TEST_TMP/queue/inbox/google_chat_inbox.yaml" \
        --target karo &
    local bg_pid=$!

    sleep 0.8

    # 対象外ファイル (basename 不一致) を atomic rename
    local tmp_other="$TEST_TMP/queue/inbox/.other_file.yaml.tmp"
    echo "other: data" > "$tmp_other"
    mv "$tmp_other" "$TEST_TMP/queue/inbox/other_file.yaml"

    # inbox 対象外なので通知されないはず
    sleep 1.5

    # watcher を停止
    kill "$bg_pid" 2>/dev/null || true
    wait "$bg_pid" 2>/dev/null || true
    rm -f "$watcher_pid_file"

    # inbox が空なので通知なし (起動時チェック + 対象外イベント)
    inbox_write_was_not_called
}
