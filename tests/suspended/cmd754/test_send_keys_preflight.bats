# 出所ファイル: tests/unit/test_send_keys_preflight.bats

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_keys_preflight.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-PF-020: inbox_watcher.sh の実コードに tmux send-keys が1つも無い
# 移動元行番号(除去前): 351-355
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-PF-020: inbox_watcher.sh の実コードに tmux send-keys が1つも無い" {
    run bash -c "grep -v '^[[:space:]]*#' '$WATCHER_SCRIPT' | grep -c 'tmux send-keys' || true"
    [ "$output" = "0" ]
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_keys_preflight.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-PF-021: send_wakeup は打鍵しない
# 移動元行番号(除去前): 357-362
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-PF-021: send_wakeup は打鍵しない" {
    run bash -c "source '$TEST_HARNESS'; send_wakeup 3"
    [ "$status" -eq 0 ]
    ! grep -q "send-keys" "$MOCK_LOG"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_keys_preflight.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-PF-022: send_wakeup_with_escape は打鍵しない
# 移動元行番号(除去前): 364-369
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-PF-022: send_wakeup_with_escape は打鍵しない" {
    run bash -c "source '$TEST_HARNESS'; send_wakeup_with_escape 3"
    [ "$status" -eq 0 ]
    ! grep -q "send-keys" "$MOCK_LOG"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_keys_preflight.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-PF-023: send_cli_command は打鍵せず rc=1 を返す
# 移動元行番号(除去前): 371-376
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-PF-023: send_cli_command は打鍵せず rc=1 を返す" {
    run bash -c "source '$TEST_HARNESS'; send_cli_command '/clear'; echo RC=\$?"
    echo "$output" | grep -q "RC=1"
    ! grep -q "send-keys" "$MOCK_LOG"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_keys_preflight.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-PF-024: send_context_reset は打鍵せず rc=1 を返す
# 移動元行番号(除去前): 378-383
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-PF-024: send_context_reset は打鍵せず rc=1 を返す" {
    run bash -c "source '$TEST_HARNESS'; AGENT_ID=ashigaru3; send_context_reset; echo RC=\$?"
    echo "$output" | grep -q "RC=1"
    ! grep -q "send-keys" "$MOCK_LOG"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_keys_preflight.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-PF-025: send_startup_prompt は打鍵せず rc=1 を返す
# 移動元行番号(除去前): 385-390
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-PF-025: send_startup_prompt は打鍵せず rc=1 を返す" {
    run bash -c "source '$TEST_HARNESS'; send_startup_prompt; echo RC=\$?"
    echo "$output" | grep -q "RC=1"
    ! grep -q "send-keys" "$MOCK_LOG"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_keys_preflight.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-PF-026: process_unread(未読0) は入力欄クリアの C-u も送らない
# 移動元行番号(除去前): 392-397
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-PF-026: process_unread(未読0) は入力欄クリアの C-u も送らない" {
    run bash -c "source '$TEST_HARNESS'; process_unread timeout"
    [ "$status" -eq 0 ]
    ! grep -q "send-keys" "$MOCK_LOG"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_keys_preflight.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-PF-027: process_unread(未読あり) も打鍵しない
# 移動元行番号(除去前): 399-413
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-PF-027: process_unread(未読あり) も打鍵しない" {
    cat > "$TEST_INBOX_DIR/test_agent.yaml" << 'YAML'
messages:
  - id: msg_1
    from: karo
    timestamp: "2026-09-08T15:00:00+09:00"
    type: task_assigned
    content: 作業開始せよ
    read: false
YAML
    run bash -c "source '$TEST_HARNESS'; process_unread event"
    [ "$status" -eq 0 ]
    ! grep -q "send-keys" "$MOCK_LOG"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_keys_preflight.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-PF-028: shogun への CLI コマンドは恒久skip(rc=2)である
# 移動元行番号(除去前): 415-420
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-PF-028: shogun への CLI コマンドは恒久skip(rc=2)である" {
    run bash -c "source '$TEST_HARNESS'; AGENT_ID=shogun; send_cli_command '/clear'; echo RC=\$?"
    echo "$output" | grep -q "RC=2"
    ! grep -q "send-keys" "$MOCK_LOG"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_keys_preflight.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-PF-030: clear_command は未送信ゆえ read:false のまま残る
# 移動元行番号(除去前): 426-446
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-PF-030: clear_command は未送信ゆえ read:false のまま残る" {
    cat > "$TEST_INBOX_DIR/test_agent.yaml" << 'YAML'
messages:
  - id: msg_clear
    from: karo
    timestamp: "2026-09-08T15:00:00+09:00"
    type: clear_command
    content: redo
    read: false
YAML
    run bash -c "source '$TEST_HARNESS'; process_unread event"
    [ "$status" -eq 0 ]
    run "$VENV_PYTHON" -c "
import yaml,sys
d=yaml.safe_load(open('$TEST_INBOX_DIR/test_agent.yaml'))
m=[x for x in d['messages'] if x['id']=='msg_clear'][0]
print('READ=%s' % m['read'])
"
    echo "$output" | grep -q "READ=False"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_keys_preflight.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-PF-031: model_switch も未読のまま残る
# 移動元行番号(除去前): 448-468
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-PF-031: model_switch も未読のまま残る" {
    cat > "$TEST_INBOX_DIR/test_agent.yaml" << 'YAML'
messages:
  - id: msg_model
    from: karo
    timestamp: "2026-09-08T15:00:00+09:00"
    type: model_switch
    content: "/model opus"
    read: false
YAML
    run bash -c "source '$TEST_HARNESS'; process_unread event"
    [ "$status" -eq 0 ]
    run "$VENV_PYTHON" -c "
import yaml
d=yaml.safe_load(open('$TEST_INBOX_DIR/test_agent.yaml'))
m=[x for x in d['messages'] if x['id']=='msg_model'][0]
print('READ=%s' % m['read'])
"
    echo "$output" | grep -q "READ=False"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_keys_preflight.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-PF-034: 未送信のまま残った命令は次サイクルで再び数えられる
# 移動元行番号(除去前): 512-524
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-PF-034: 未送信のまま残った命令は次サイクルで再び数えられる" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        SCRIPT_DIR="'"$FAKE_ROOT"'"
        DELIVERY_ALERT_THRESHOLD=99
        send_cli_command "/clear" || true
        send_cli_command "/clear" || true
        send_cli_command "/clear" || true
        echo "COUNT=$DELIVERY_BLOCK_COUNT"
    '
    echo "$output" | grep -q "COUNT=3"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_keys_preflight.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-PF-035: clear_command 単独でも複数周期でカウンタが戻らず閾値へ届く
# 移動元行番号(除去前): 571-584
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-PF-035: clear_command 単独でも複数周期でカウンタが戻らず閾値へ届く" {
    _write_special_only_inbox clear_command "redo"
    _run_special_only_cycles
    [ "$status" -eq 0 ]
    # ★旧実装はここが AFTER1=0 / AFTER2=0 であった(同一周期内リセット)
    echo "$output" | grep -q "AFTER1=1"
    echo "$output" | grep -q "AFTER2=2"
    # 閾値2に到達して人経路(家老inbox)へ上がっていること
    grep -q "target=karo" "$INBOX_WRITE_LOG"
    grep -q "type=delivery_alert" "$INBOX_WRITE_LOG"
    # 届かなかった命令は消さない
    _assert_special_still_unread
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_keys_preflight.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-PF-036: model_switch 単独でも同じく閾値へ届く
# 移動元行番号(除去前): 586-595
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-PF-036: model_switch 単独でも同じく閾値へ届く" {
    _write_special_only_inbox model_switch "/model opus"
    _run_special_only_cycles
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "AFTER1=1"
    echo "$output" | grep -q "AFTER2=2"
    grep -q "target=karo" "$INBOX_WRITE_LOG"
    _assert_special_still_unread
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_keys_preflight.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-PF-037: cli_restart 単独でも同じく閾値へ届く
# 移動元行番号(除去前): 597-606
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-PF-037: cli_restart 単独でも同じく閾値へ届く" {
    _write_special_only_inbox cli_restart "codex"
    _run_special_only_cycles
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "AFTER1=1"
    echo "$output" | grep -q "AFTER2=2"
    grep -q "target=karo" "$INBOX_WRITE_LOG"
    _assert_special_still_unread
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_keys_preflight.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-PF-038: 特殊命令が既読化され全未読0になれば初めてカウンタが戻る
# 移動元行番号(除去前): 608-625
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-PF-038: 特殊命令が既読化され全未読0になれば初めてカウンタが戻る" {
    # shogun 宛の特殊命令は恒久skip(rc=2)で既読化される。既読化後の
    # ★全未読総数を読み直したうえで 0 と確認できるからリセットしてよい。
    _write_special_only_inbox clear_command "redo"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        SCRIPT_DIR="'"$FAKE_ROOT"'"
        METRICS_FILE="'"$TEST_TMPDIR"'/metrics.yaml"
        AGENT_ID="shogun"
        DELIVERY_ALERT_THRESHOLD=99
        DELIVERY_BLOCK_COUNT=3
        process_unread event
        echo "AFTER=$DELIVERY_BLOCK_COUNT"
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "AFTER=0"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_keys_preflight.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-PF-040: 閾値到達で家老へ inbox 通知が出る
# 移動元行番号(除去前): 663-675
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-PF-040: 閾値到達で家老へ inbox 通知が出る" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        SCRIPT_DIR="'"$FAKE_ROOT"'"
        DELIVERY_ALERT_THRESHOLD=2
        delivery_register_undeliverable "未読1件" "no_delivery_channel"
        delivery_register_undeliverable "未読1件" "no_delivery_channel"
    '
    [ "$status" -eq 0 ]
    grep -q "target=karo" "$INBOX_WRITE_LOG"
    grep -q "type=delivery_alert" "$INBOX_WRITE_LOG"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_keys_preflight.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-PF-041: 通知はクールダウン中に連打されない
# 移動元行番号(除去前): 677-690
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-PF-041: 通知はクールダウン中に連打されない" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        SCRIPT_DIR="'"$FAKE_ROOT"'"
        DELIVERY_ALERT_THRESHOLD=1
        DELIVERY_ALERT_COOLDOWN_SEC=900
        delivery_register_undeliverable "未読1件" "no_delivery_channel"
        delivery_register_undeliverable "未読1件" "no_delivery_channel"
        delivery_register_undeliverable "未読1件" "no_delivery_channel"
    '
    [ "$status" -eq 0 ]
    [ "$(grep -c '^target=' "$INBOX_WRITE_LOG")" -eq 1 ]
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_keys_preflight.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-PF-042: 家老自身が対象なら通知先は軍師になる
# 移動元行番号(除去前): 692-703
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-PF-042: 家老自身が対象なら通知先は軍師になる" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        SCRIPT_DIR="'"$FAKE_ROOT"'"
        AGENT_ID="karo"
        DELIVERY_ALERT_THRESHOLD=1
        delivery_register_undeliverable "未読1件" "no_delivery_channel"
    '
    [ "$status" -eq 0 ]
    grep -q "target=gunshi" "$INBOX_WRITE_LOG"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_keys_preflight.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-PF-043: 家老が対象なら inbox に加え ntfy で殿へ到達する
# 移動元行番号(除去前): 705-717
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-PF-043: 家老が対象なら inbox に加え ntfy で殿へ到達する" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        SCRIPT_DIR="'"$FAKE_ROOT"'"
        AGENT_ID="karo"
        DELIVERY_ALERT_THRESHOLD=1
        delivery_register_undeliverable "未読1件" "no_delivery_channel"
    '
    [ "$status" -eq 0 ]
    [ -s "$NTFY_LOG" ]
    grep -q "要対応" "$NTFY_LOG"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_keys_preflight.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-PF-044: 将軍が対象なら ntfy で殿へ到達する
# 移動元行番号(除去前): 719-730
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-PF-044: 将軍が対象なら ntfy で殿へ到達する" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        SCRIPT_DIR="'"$FAKE_ROOT"'"
        AGENT_ID="shogun"
        DELIVERY_ALERT_THRESHOLD=1
        delivery_register_undeliverable "未読1件" "no_delivery_channel"
    '
    [ "$status" -eq 0 ]
    [ -s "$NTFY_LOG" ]
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_keys_preflight.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-PF-045: 通常の足軽なら家老inboxのみ(ntfyは鳴らさない)
# 移動元行番号(除去前): 732-744
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-PF-045: 通常の足軽なら家老inboxのみ(ntfyは鳴らさない)" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        SCRIPT_DIR="'"$FAKE_ROOT"'"
        AGENT_ID="ashigaru3"
        DELIVERY_ALERT_THRESHOLD=1
        delivery_register_undeliverable "未読1件" "no_delivery_channel"
    '
    [ "$status" -eq 0 ]
    grep -q "target=karo" "$INBOX_WRITE_LOG"
    [ ! -s "$NTFY_LOG" ]
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_keys_preflight.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-PF-046: 家老inboxへの書き込みが失敗したら ntfy へ切り替わる
# 移動元行番号(除去前): 746-762
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-PF-046: 家老inboxへの書き込みが失敗したら ntfy へ切り替わる" {
    cat > "$FAKE_ROOT/scripts/inbox_write.sh" << 'FAKE'
#!/bin/bash
exit 1
FAKE
    chmod +x "$FAKE_ROOT/scripts/inbox_write.sh"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        SCRIPT_DIR="'"$FAKE_ROOT"'"
        AGENT_ID="ashigaru3"
        DELIVERY_ALERT_THRESHOLD=1
        delivery_register_undeliverable "未読1件" "no_delivery_channel"
    '
    [ "$status" -eq 0 ]
    [ -s "$NTFY_LOG" ]
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_keys_preflight.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-PF-047: 未読が捌ければカウンタがリセットされる
# 移動元行番号(除去前): 764-775
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-PF-047: 未読が捌ければカウンタがリセットされる" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        SCRIPT_DIR="'"$FAKE_ROOT"'"
        DELIVERY_ALERT_THRESHOLD=99
        delivery_register_undeliverable "未読1件" "no_delivery_channel"
        delivery_reset_counter
        echo "COUNT=$DELIVERY_BLOCK_COUNT"
    '
    echo "$output" | grep -q "COUNT=0"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_keys_preflight.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-PF-048: 通知文に人が取るべき手当てが書かれている
# 移動元行番号(除去前): 777-789
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-PF-048: 通知文に人が取るべき手当てが書かれている" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        SCRIPT_DIR="'"$FAKE_ROOT"'"
        AGENT_ID="ashigaru3"
        DELIVERY_ALERT_THRESHOLD=1
        delivery_register_undeliverable "未読1件の起床通知 (cli=codex)" "no_delivery_channel"
    '
    [ "$status" -eq 0 ]
    grep -q "dashboard.md 🚨要対応" "$INBOX_WRITE_LOG"
    grep -q "人が起こすほかに出口は無い" "$INBOX_WRITE_LOG"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_keys_preflight.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-PF-051: inbox_watcher も選択肢を答える打鍵を持たない
# 移動元行番号(除去前): 800-804
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-PF-051: inbox_watcher も選択肢を答える打鍵を持たない" {
    run bash -c "grep -v '^[[:space:]]*#' '$WATCHER_SCRIPT' | grep -cE \"send-keys\" || true"
    [ "$output" = "0" ]
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_keys_preflight.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-PF-060: delivery_channel_for_cli — claude は stop_hook
# 移動元行番号(除去前): 810-814
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-PF-060: delivery_channel_for_cli — claude は stop_hook" {
    run bash -c "source '$TEST_HARNESS'; delivery_channel_for_cli claude"
    [ "$output" = "stop_hook" ]
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_keys_preflight.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-PF-061: delivery_channel_for_cli — 他CLIは none (「たぶん届く」と書かぬ)
# 移動元行番号(除去前): 816-822
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-PF-061: delivery_channel_for_cli — 他CLIは none (「たぶん届く」と書かぬ)" {
    for cli in codex opencode copilot kimi "" unknown; do
        run bash -c "source '$TEST_HARNESS'; delivery_channel_for_cli '$cli'"
        [ "$output" = "none" ]
    done
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_keys_preflight.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-PF-062: CLI別配送経路の表が実装に併記されている
# 移動元行番号(除去前): 824-830
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-PF-062: CLI別配送経路の表が実装に併記されている" {
    grep -q "CLI 別・実際に配送を担うもの" "$WATCHER_SCRIPT"
    grep -q "agent self-watch" "$WATCHER_SCRIPT"
    # self-watch が実在しないことを正直に書いてあること
    grep -q "実在せぬ" "$WATCHER_SCRIPT"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_send_keys_preflight.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-PF-073: Stop hook の被覆限界(55秒窓)が実装に明記されている
# 移動元行番号(除去前): 867-871
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-PF-073: Stop hook の被覆限界(55秒窓)が実装に明記されている" {
    grep -q "最大55秒" "$WATCHER_SCRIPT"
    grep -q "窓を過ぎて完全に idle" "$WATCHER_SCRIPT"
}
