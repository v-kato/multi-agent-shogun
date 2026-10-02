# 出所ファイル: tests/unit/test_send_wakeup.bats

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_wakeup.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-SW-001: 打鍵なしの配送経路が生きていれば委ね、打鍵しない
# 移動元行番号(除去前): 209-222
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-SW-001: 打鍵なしの配送経路が生きていれば委ね、打鍵しない" {
    cat > "$MOCK_PGREP" << 'MOCK'
#!/bin/bash
echo "12345 inotifywait -q -t 120 -e modify inbox/test_agent.yaml"
exit 0
MOCK
    chmod +x "$MOCK_PGREP"

    run bash -c "source '$TEST_HARNESS' && send_wakeup 3"
    [ "$status" -eq 0 ]
    ! grep -q "send-keys" "$MOCK_LOG"
    echo "$output" | grep -q "打鍵なしの配送経路"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_wakeup.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-SW-002: send_wakeup は self-watch が無くても打鍵しない (cmd_754 E-1)
# 移動元行番号(除去前): 226-233
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-SW-002: send_wakeup は self-watch が無くても打鍵しない (cmd_754 E-1)" {
    run bash -c "source '$TEST_HARNESS' && send_wakeup 5"
    [ "$status" -eq 0 ]
    ! grep -q "send-keys" "$MOCK_LOG"
    # claude は Stop hook が配送を担う
    echo "$output" | grep -q "Stop hook が配送を担う"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_wakeup.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-SW-003: nudge 文字列 (inboxN) も Enter も一切送られない
# 移動元行番号(除去前): 237-243
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-SW-003: nudge 文字列 (inboxN) も Enter も一切送られない" {
    run bash -c "source '$TEST_HARNESS' && send_wakeup 3"
    [ "$status" -eq 0 ]
    ! grep -q "inbox3" "$MOCK_LOG"
    ! grep -q "send-keys" "$MOCK_LOG"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_wakeup.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-SW-005: 打鍵系 tmux サブコマンドを一切使わない (send-keys/paste-buffer/set-buffer)
# 移動元行番号(除去前): 256-263
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-SW-005: 打鍵系 tmux サブコマンドを一切使わない (send-keys/paste-buffer/set-buffer)" {
    run bash -c "source '$TEST_HARNESS' && send_wakeup 3"
    [ "$status" -eq 0 ]
    ! grep -q "paste-buffer" "$MOCK_LOG"
    ! grep -q "set-buffer" "$MOCK_LOG"
    ! grep -q "send-keys" "$MOCK_LOG"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_wakeup.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-SW-008: send_cli_command /clear は送られず rc=1 になる
# 移動元行番号(除去前): 288-297
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-SW-008: send_cli_command /clear は送られず rc=1 になる" {
    run bash -c "source '$TEST_HARNESS'; send_cli_command '/clear'; echo RC=\$?"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "RC=1"
    ! grep -q "send-keys" "$MOCK_LOG"
    echo "$output" | grep -q "NO-AUTO-SEND"
    # 人が何をすればよいかを添える (E-3)
    echo "$output" | grep -q "人手で"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_wakeup.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-SW-009: send_cli_command /model は送られず rc=1 になる
# 移動元行番号(除去前): 301-308
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-SW-009: send_cli_command /model は送られず rc=1 になる" {
    run bash -c "source '$TEST_HARNESS'; send_cli_command '/model opus'; echo RC=\$?"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "RC=1"
    ! grep -q "send-keys" "$MOCK_LOG"
    echo "$output" | grep -q "switch_cli.sh"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_wakeup.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-SW-010: nudge という打鍵経路そのものが存在しない
# 移動元行番号(除去前): 312-319
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-SW-010: nudge という打鍵経路そのものが存在しない" {
    # かつて nudge を組み立てていた関数群が打鍵を持たぬことを、実装の
    # 文面ではなく★実行結果で確かめる。
    run bash -c "source '$TEST_HARNESS'; send_wakeup 2; send_wakeup_with_escape 2; send_startup_prompt; true"
    [ "$status" -eq 0 ]
    ! grep -q "send-keys" "$MOCK_LOG"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_wakeup.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-SW-011: inbox_watcher.sh に tmux send-keys が1つも無い (構造としての不在)
# 移動元行番号(除去前): 323-331
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-SW-011: inbox_watcher.sh に tmux send-keys が1つも無い (構造としての不在)" {
    # コメント行を除いた実コードに `tmux send-keys` が現れないこと。
    run bash -c "grep -v '^[[:space:]]*#' '$WATCHER_SCRIPT' | grep -c 'tmux send-keys' || true"
    [ "$output" = "0" ]
    # 置き換え先の関数は存在する
    grep -q "delivery_register_undeliverable()" "$WATCHER_SCRIPT"
    grep -q "delivery_channel_for_cli()" "$WATCHER_SCRIPT"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_wakeup.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-ESC-002: 猶予内(2分未満)は配送経路へ委ね、打鍵しない
# 移動元行番号(除去前): 354-369
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-ESC-002: 猶予内(2分未満)は配送経路へ委ね、打鍵しない" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        now=$(date +%s)
        FIRST_UNREAD_SEEN=$((now - 30))
        age=$((now - FIRST_UNREAD_SEEN))
        if [ "$age" -lt "$ESCALATE_PHASE1" ]; then
            send_wakeup 2
            echo "PHASE1_DELEGATED"
        fi
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "PHASE1_DELEGATED"
    ! grep -q "send-keys" "$MOCK_LOG"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_wakeup.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-ESC-003: Escape エスカレーションは廃止され、打鍵は起きない
# 移動元行番号(除去前): 373-383
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-ESC-003: Escape エスカレーションは廃止され、打鍵は起きない" {
    run bash -c '
        MOCK_PANE_CLI="copilot"
        source "'"$TEST_HARNESS"'"
        send_wakeup_with_escape 2
    '
    [ "$status" -eq 0 ]
    ! grep -q "send-keys" "$MOCK_LOG"
    echo "$output" | grep -q "Escape エスカレーションは廃止済み"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_wakeup.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-ESC-004: 猶予超過でも /clear は送らず、人経路へ倒す
# 移動元行番号(除去前): 387-397
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-ESC-004: 猶予超過でも /clear は送らず、人経路へ倒す" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        send_cli_command "/clear"
        echo "RC=$?"
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "RC=1"
    ! grep -q "send-keys" "$MOCK_LOG"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_wakeup.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-ESC-005: 滞留が猶予を超えると未配送として数えられる
# 移動元行番号(除去前): 401-413
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-ESC-005: 滞留が猶予を超えると未配送として数えられる" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        DELIVERY_ALERT_THRESHOLD=99
        delivery_register_undeliverable "未読2件が300秒滞留" "unread_stalled"
        echo "COUNT=$DELIVERY_BLOCK_COUNT"
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "COUNT=1"
    echo "$output" | grep -q "NO-AUTO-SEND"
    ! grep -q "send-keys" "$MOCK_LOG"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_wakeup.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-CODEX-001: codex でも /clear→/new の打鍵は送られない
# 移動元行番号(除去前): 459-472
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-CODEX-001: codex でも /clear→/new の打鍵は送られない" {
    run bash -c '
        MOCK_PANE_CLI="codex"
        source "'"$TEST_HARNESS"'"
        send_cli_command "/clear"
        echo "RC=$?"
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "RC=1"
    ! grep -q "send-keys" "$MOCK_LOG"
    # codex/opencode には /new を人手で入れよ、と案内する
    echo "$output" | grep -q "/new"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_wakeup.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-CODEX-002: codex の /model も送られない
# 移動元行番号(除去前): 476-487
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-CODEX-002: codex の /model も送られない" {
    run bash -c '
        MOCK_PANE_CLI="codex"
        source "'"$TEST_HARNESS"'"
        send_cli_command "/model gpt"
        echo "RC=$?"
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "RC=1"
    ! grep -q "send-keys" "$MOCK_LOG"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_wakeup.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-OPENCODE-001: opencode でも /clear→/new の打鍵は送られない
# 移動元行番号(除去前): 491-502
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-OPENCODE-001: opencode でも /clear→/new の打鍵は送られない" {
    run bash -c '
        MOCK_PANE_CLI="opencode"
        source "'"$TEST_HARNESS"'"
        send_cli_command "/clear"
        echo "RC=$?"
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "RC=1"
    ! grep -q "send-keys" "$MOCK_LOG"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_wakeup.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-OPENCODE-002: opencode の /model も送られない
# 移動元行番号(除去前): 506-517
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-OPENCODE-002: opencode の /model も送られない" {
    run bash -c '
        MOCK_PANE_CLI="opencode"
        source "'"$TEST_HARNESS"'"
        send_cli_command "/model x"
        echo "RC=$?"
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "RC=1"
    ! grep -q "send-keys" "$MOCK_LOG"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_wakeup.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-CODEX-005: claude でも /clear は送られない
# 移動元行番号(除去前): 571-583
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-CODEX-005: claude でも /clear は送られない" {
    run bash -c '
        MOCK_PANE_CLI="claude"
        source "'"$TEST_HARNESS"'"
        send_cli_command "/clear"
        echo "RC=$?"
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "RC=1"
    ! grep -q "send-keys" "$MOCK_LOG"
    echo "$output" | grep -q "/clear"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_wakeup.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-CODEX-006: inbox_watcher.sh は busy 判定と配送経路判定を持つ
# 移動元行番号(除去前): 587-594
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-CODEX-006: inbox_watcher.sh は busy 判定と配送経路判定を持つ" {
    # ★grep ではなく実際に定義されているかで確かめる(コメントへの
    #   部分一致による false pass を避ける)。
    run bash -c "source '$TEST_HARNESS'; for f in agent_is_busy delivery_channel_for_cli delivery_register_undeliverable delivery_reset_counter; do declare -f \$f >/dev/null 2>&1 || echo \"MISSING=\$f\"; done; true"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_wakeup.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-CODEX-007: pane @agent_cli=codex でも打鍵は起きない
# 移動元行番号(除去前): 598-608
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-CODEX-007: pane @agent_cli=codex でも打鍵は起きない" {
    run bash -c '
        MOCK_PANE_CLI="codex"
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="claude"
        send_wakeup_with_escape 2
    '
    [ "$status" -eq 0 ]
    ! grep -q "send-keys" "$MOCK_LOG"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_wakeup.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-CODEX-008: pane @agent_cli=codex は配送経路の判定に反映される
# 移動元行番号(除去前): 612-625
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-CODEX-008: pane @agent_cli=codex は配送経路の判定に反映される" {
    run bash -c '
        MOCK_PANE_CLI="codex"
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="claude"
        send_wakeup 2
    '
    [ "$status" -eq 0 ]
    ! grep -q "send-keys" "$MOCK_LOG"
    # codex は Stop hook を持たぬため「配送経路なし」として数える
    echo "$output" | grep -q "cli=codex"
    echo "$output" | grep -q "NO-AUTO-SEND"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_wakeup.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-CODEX-010: CLI 種別が解決できずとも打鍵は起きない
# 移動元行番号(除去前): 640-652
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-CODEX-010: CLI 種別が解決できずとも打鍵は起きない" {
    run bash -c '
        MOCK_PANE_CLI=""
        source "'"$TEST_HARNESS"'"
        CLI_TYPE=""
        send_cli_command "/clear"
        echo "RC=$?"
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "RC=1"
    ! grep -q "send-keys" "$MOCK_LOG"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_wakeup.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-CODEX-011: clear_command は送られず未読のまま残り、auto-recovery も走らない
# 移動元行番号(除去前): 656-696
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-CODEX-011: clear_command は送られず未読のまま残り、auto-recovery も走らない" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="codex"
        cat > "$INBOX" << "YAML"
messages:
  - id: msg_clear
    from: karo
    timestamp: "2026-02-10T14:00:00+09:00"
    type: clear_command
    content: redo
    read: false
YAML
        process_unread event
        "$VENV_PYTHON" - << "PY" "$INBOX"
import sys
import yaml

inbox_path = sys.argv[1]
with open(inbox_path, "r", encoding="utf-8") as f:
    data = yaml.safe_load(f) or {}

messages = data.get("messages", []) or []
msg_clear = [m for m in messages if m.get("id") == "msg_clear"]
assert len(msg_clear) == 1, "clear_command が消えている"
assert msg_clear[0].get("read") is False, "未送信なのに既読化された"

auto = [
    m for m in messages
    if m.get("from") == "inbox_watcher"
    and "[auto-recovery]" in (m.get("content") or "")
]
assert len(auto) == 0, "送っていない /clear の後始末が走っている"
print("OK")
PY
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "OK"
    ! grep -q "send-keys" "$MOCK_LOG"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_wakeup.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-OPENCODE-003: opencode の Escape 経路も打鍵を持たない
# 移動元行番号(除去前): 747-756
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-OPENCODE-003: opencode の Escape 経路も打鍵を持たない" {
    run bash -c '
        MOCK_PANE_CLI="opencode"
        source "'"$TEST_HARNESS"'"
        send_wakeup_with_escape 2
    '
    [ "$status" -eq 0 ]
    ! grep -q "send-keys" "$MOCK_LOG"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_wakeup.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-COPILOT-001: copilot の C-c + 再起動打鍵も送られない
# 移動元行番号(除去前): 862-873
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-COPILOT-001: copilot の C-c + 再起動打鍵も送られない" {
    run bash -c '
        MOCK_PANE_CLI="copilot"
        source "'"$TEST_HARNESS"'"
        send_cli_command "/clear"
        echo "RC=$?"
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "RC=1"
    ! grep -q "send-keys" "$MOCK_LOG"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_wakeup.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-COPILOT-002: copilot の /model も送られない
# 移動元行番号(除去前): 877-888
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-COPILOT-002: copilot の /model も送られない" {
    run bash -c '
        MOCK_PANE_CLI="copilot"
        source "'"$TEST_HARNESS"'"
        send_cli_command "/model x"
        echo "RC=$?"
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "RC=1"
    ! grep -q "send-keys" "$MOCK_LOG"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_wakeup.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-SHOGUN-003: 将軍 pane が active でも打鍵しない
# 移動元行番号(除去前): 914-925
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-SHOGUN-003: 将軍 pane が active でも打鍵しない" {
    run bash -c '
        MOCK_PANE_ACTIVE="1"
        MOCK_LIST_CLIENTS="/dev/pts/1: mock_session [200x50 xterm-256color]"
        source "'"$TEST_HARNESS"'"
        AGENT_ID="shogun"
        send_wakeup 2
    '
    [ "$status" -eq 0 ]
    ! grep -q "send-keys" "$MOCK_LOG"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_wakeup.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-SHOGUN-004: 将軍 pane が detached でも打鍵しない
# 移動元行番号(除去前): 929-940
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-SHOGUN-004: 将軍 pane が detached でも打鍵しない" {
    run bash -c '
        MOCK_PANE_ACTIVE="1"
        MOCK_LIST_CLIENTS=""
        source "'"$TEST_HARNESS"'"
        AGENT_ID="shogun"
        send_wakeup 2
    '
    [ "$status" -eq 0 ]
    ! grep -q "send-keys" "$MOCK_LOG"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_wakeup.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-SHOOK-004: 全既読になれば未配送カウンタがリセットされる (nudge throttle は廃止)
# 移動元行番号(除去前): 1125-1151
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-SHOOK-004: 全既読になれば未配送カウンタがリセットされる (nudge throttle は廃止)" {
    # ★cmd_754: nudge が消えたため throttle も廃止した。全既読時に残るのは
    #   「未配送カウンタのリセット」だけである。旧版はここで
    #   should_throttle_nudge を呼んでおり、関数が消えた後も rc=127 が
    #   `grep "rc=1"` に部分一致して★通ってしまう false pass であった。
    run bash -c '
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="codex"
        cat > "$INBOX" <<YAML
messages: []
YAML
        DELIVERY_BLOCK_COUNT=4
        FIRST_UNREAD_SEEN=123

        process_unread event

        echo "count=$DELIVERY_BLOCK_COUNT first_unread=$FIRST_UNREAD_SEEN"
        declare -f should_throttle_nudge >/dev/null 2>&1 && echo "THROTTLE_STILL_EXISTS"
        true
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "count=0"
    echo "$output" | grep -q "first_unread=0"
    ! echo "$output" | grep -q "THROTTLE_STILL_EXISTS"
    ! grep -q "send-keys" "$MOCK_LOG"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_wakeup.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-CODEX-016: 送信確認のための capture-pane 再読も行わない
# 移動元行番号(除去前): 1155-1166
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-CODEX-016: 送信確認のための capture-pane 再読も行わない" {
    run bash -c '
        MOCK_PANE_CLI="codex"
        source "'"$TEST_HARNESS"'"
        send_wakeup 1
    '
    [ "$status" -eq 0 ]
    ! grep -q "send-keys" "$MOCK_LOG"
    # 打鍵しない以上、送信確認のための capture-pane も要らぬ
    ! grep -q "capture-pane" "$MOCK_LOG"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_wakeup.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-CRESET-001: send_context_reset — 家老は元より対象外で、打鍵も無い
# 移動元行番号(除去前): 1170-1180
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-CRESET-001: send_context_reset — 家老は元より対象外で、打鍵も無い" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="karo"
        send_context_reset
        echo "RC=$?"
    '
    echo "$output" | grep -q "RC=1"
    ! grep -q "send-keys" "$MOCK_LOG"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_wakeup.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-CRESET-002: send_context_reset — 軍師も同様に打鍵しない
# 移動元行番号(除去前): 1184-1194
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-CRESET-002: send_context_reset — 軍師も同様に打鍵しない" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="gunshi"
        send_context_reset
        echo "RC=$?"
    '
    echo "$output" | grep -q "RC=1"
    ! grep -q "send-keys" "$MOCK_LOG"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_wakeup.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-CRESET-003: send_context_reset — 足軽へも /clear を送らず rc=1
# 移動元行番号(除去前): 1198-1210
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-CRESET-003: send_context_reset — 足軽へも /clear を送らず rc=1" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="ashigaru3"
        CLI_TYPE="claude"
        send_context_reset
        echo "RC=$?"
    '
    echo "$output" | grep -q "RC=1"
    ! grep -q "send-keys" "$MOCK_LOG"
    echo "$output" | grep -q "/clear"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_wakeup.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-CRESET-004: send_context_reset — opencode へも /new を送らず rc=1
# 移動元行番号(除去前): 1214-1226
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-CRESET-004: send_context_reset — opencode へも /new を送らず rc=1" {
    run bash -c '
        MOCK_PANE_CLI="opencode"
        source "'"$TEST_HARNESS"'"
        AGENT_ID="ashigaru3"
        send_context_reset
        echo "RC=$?"
    '
    echo "$output" | grep -q "RC=1"
    ! grep -q "send-keys" "$MOCK_LOG"
    echo "$output" | grep -q "/new"
}
