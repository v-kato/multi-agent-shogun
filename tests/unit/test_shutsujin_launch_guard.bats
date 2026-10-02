#!/usr/bin/env bats
# test_shutsujin_launch_guard.bats — 出陣時の起動打鍵ガード (cmd_754 E-5)
#
# 将軍裁定 E-5 は「agent がまだ動いていない pane への送信を廃止対象に
# 含めるか」を実装者の判断に委ねた。判断は★残す(ただし条件付き)である。
#
#   残す理由: 誤爆の形が成立しない。事故とは「TUI が出したモーダルの既定
#     選択肢を Enter が押す」ことであった。CLI が動いていない pane に TUI は
#     無く、モーダルも既定選択肢も存在しない。廃せば得られる安全が無い。
#
#   ★条件: 出陣は既存セッションを使い回すため、★既に agent が稼働している
#     pane へ起動コマンドを打ち込む経路が実在した。これは E-1 が廃した当の
#     ものである。よって打鍵の直前に pane の★前景プロセスが素のシェルで
#     あることを確かめる(画面は読まない)。
#
# テスト構成:
#   T-SD-001: 生の tmux send-keys は shutsujin_send_launch の1箇所のみ
#   T-SD-002: 前景が素のシェルなら起動打鍵を送る
#   T-SD-003: 前景が agent CLI なら送らない (E-1 の対象)
#   T-SD-004: 前景を読めなければ送らない (fail-safe)
#   T-SD-005: 送らなかった pane は記録され、人へ報せられる
#   T-SD-006: preflight ライブラリ未ロードなら送らない (fail-safe)
#   T-SD-007: 送らなかったことは黙って落とさずログへ出る

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export SHUTSUJIN="$PROJECT_ROOT/shutsujin_departure.sh"
    export PREFLIGHT_LIB="$PROJECT_ROOT/lib/pane_preflight.sh"
    [ -f "$SHUTSUJIN" ] || return 1
    [ -f "$PREFLIGHT_LIB" ] || return 1
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/shutsujin_guard.XXXXXX")"
    export MOCK_LOG="$TEST_TMPDIR/tmux_calls.log"
    > "$MOCK_LOG"
    export MOCK_FOREGROUND="bash"
    export MOCK_PANE_ID_RC=0

    export TEST_HARNESS="$TEST_TMPDIR/harness.sh"
    cat > "$TEST_HARNESS" << HARNESS
#!/bin/bash
tmux() {
    echo "tmux \$*" >> "$MOCK_LOG"
    if echo "\$*" | grep -q "pane_current_command"; then
        # ★実装は pane_id と前景プロセスを一度に問い合わせる
        printf '%s|%s\n' "\${MOCK_PANE_ID-%0}" "\${MOCK_FOREGROUND:-}"
        return 0
    fi
    if echo "\$*" | grep -q "pane_id"; then
        return "\${MOCK_PANE_ID_RC:-0}"
    fi
    return 0
}
timeout() { shift; "\$@"; }
log_info() { echo "[log_info] \$*" >&2; }
export -f tmux timeout log_info

source "$PREFLIGHT_LIB"
SHUTSUJIN_SKIPPED_PANES=""
# 出陣スクリプト本体は実行しない(実 tmux セッションを作らせぬため)。
# 起動打鍵ヘルパの定義だけを取り出して評価する。
_fn="\$(awk '/^shutsujin_send_launch\(\) \{/,/^}/' "$SHUTSUJIN")"
eval "\$_fn"
HARNESS
    chmod +x "$TEST_HARNESS"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

@test "T-SD-001: 生の tmux send-keys は shutsujin_send_launch の1箇所のみ" {
    local code_only n body
    # echo で人へ案内している行(手動起動の手順表示)は打鍵ではないので除く
    code_only="$(grep -vE '^[[:space:]]*#' "$SHUTSUJIN" | grep -vE '^[[:space:]]*echo ')"
    n="$(echo "$code_only" | grep -cE 'tmux send-keys' || true)"
    [ "$n" -eq 1 ]
    body="$(awk '/^shutsujin_send_launch\(\) \{/,/^}/' "$SHUTSUJIN")"
    echo "$body" | grep -qE 'tmux send-keys'
    echo "$body" | grep -q 'pane_is_bare_shell'
}

@test "T-SD-002: 前景が素のシェルなら起動打鍵を送る" {
    run bash -c "MOCK_FOREGROUND=bash; source '$TEST_HARNESS'; shutsujin_send_launch test:0.0 'CLI起動' 'claude --model opus' Enter; echo RC=\$?"
    echo "$output" | grep -q "RC=0"
    grep -q "send-keys -t test:0.0 claude --model opus Enter" "$MOCK_LOG"
}

@test "T-SD-003: 前景が agent CLI なら送らない (E-1 の対象)" {
    for fg in claude codex copilot kimi opencode node; do
        > "$MOCK_LOG"
        run bash -c "MOCK_FOREGROUND='$fg'; source '$TEST_HARNESS'; shutsujin_send_launch test:0.0 'CLI起動' 'claude' Enter; echo RC=\$?"
        echo "$output" | grep -q "RC=1"
        ! grep -q "send-keys" "$MOCK_LOG"
    done
}

@test "T-SD-004: 前景を読めなければ送らない (fail-safe)" {
    run bash -c "MOCK_FOREGROUND=''; source '$TEST_HARNESS'; shutsujin_send_launch test:0.0 'CLI起動' 'claude' Enter; echo RC=\$?"
    echo "$output" | grep -q "RC=1"
    ! grep -q "send-keys" "$MOCK_LOG"
}

@test "T-SD-005: 送らなかった pane は記録され、人へ報せられる" {
    run bash -c "MOCK_FOREGROUND=claude; source '$TEST_HARNESS'; shutsujin_send_launch test:0.9 'CLI起動' 'claude' Enter || true; echo \"SKIPPED=\$SHUTSUJIN_SKIPPED_PANES\""
    echo "$output" | grep -q "SKIPPED=test:0.9"
    # 末尾の人向け報告ブロックが存在すること
    grep -q '起動打鍵を送らなかった pane がござる' "$SHUTSUJIN"
}

@test "T-SD-006: preflight ライブラリ未ロードなら送らない (fail-safe)" {
    run bash -c "source '$TEST_HARNESS'; unset -f pane_is_bare_shell; shutsujin_send_launch test:0.0 'CLI起動' 'claude' Enter; echo RC=\$?"
    echo "$output" | grep -q "RC=1"
    ! grep -q "send-keys" "$MOCK_LOG"
}

@test "T-SD-007: 送らなかったことは黙って落とさずログへ出る" {
    run bash -c "MOCK_FOREGROUND=claude; source '$TEST_HARNESS'; shutsujin_send_launch test:0.0 'CLI起動' 'claude' Enter || true"
    echo "$output" | grep -q "素のシェルではない"
    echo "$output" | grep -q "稼働中の pane へ打鍵せぬ"
}
