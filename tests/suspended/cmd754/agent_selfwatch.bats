# 出所ファイル: tests/agent_selfwatch.bats

# ────────────────────────────────────────────────────────────────────
# 出所: tests/agent_selfwatch.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: TC-FR-003: get_unread_info routes task/special messages correctly
# 移動元行番号(除去前): 100-150
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "TC-FR-003: get_unread_info routes task/special messages correctly" {
    cat > "$TEST_INBOX" << 'YAML'
messages:
  - id: msg_task
    from: karo
    timestamp: "2026-02-09T21:00:00"
    type: task_assigned
    content: task
    read: false
  - id: msg_clear
    from: karo
    timestamp: "2026-02-09T21:00:01"
    type: clear_command
    content: /clear
    read: false
  - id: msg_model
    from: karo
    timestamp: "2026-02-09T21:00:02"
    type: model_switch
    content: /model opus
    read: false
YAML

    run bash -c "source '$TEST_HARNESS'; get_unread_info"
    [ "$status" -eq 0 ]

    # ★cmd_754 redo1 で契約が変わった: get_unread_info は type 別に振り分ける
    #   だけで既読化しない。特殊命令の既読化は「送信できた/仕様上終端」と
    #   確定した後に mark_inbox_message_read() が id 単位で行う。
    #   旧契約(抽出時点で read:true)は、preflight が打鍵を抑止したときに
    #   命令そのものを永久消失させていた(軍師QC G754-SPECIAL-ACK-BEFORE-
    #   PREFLIGHT-02)。id が payload に載ることも併せて検査する。
    "$VENV_PYTHON" - << 'PY' "$output" "$TEST_INBOX"
import json, sys, yaml
payload = json.loads(sys.argv[1])
inbox_path = sys.argv[2]
assert payload["count"] == 1, payload
assert len(payload["specials"]) == 2, payload
assert {s["type"] for s in payload["specials"]} == {"clear_command", "model_switch"}, payload
assert {s["id"] for s in payload["specials"]} == {"msg_clear", "msg_model"}, payload

with open(inbox_path) as f:
    data = yaml.safe_load(f)
by_id = {m["id"]: m for m in data["messages"]}
assert by_id["msg_task"]["read"] is False
assert by_id["msg_clear"]["read"] is False
assert by_id["msg_model"]["read"] is False
print("OK")
PY
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/agent_selfwatch.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: TC-FR-003b: get_unread_info を繰り返し呼んでも特殊命令は消えない
# 移動元行番号(除去前): 152-168
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "TC-FR-003b: get_unread_info を繰り返し呼んでも特殊命令は消えない" {
    cat > "$TEST_INBOX" << 'YAML'
messages:
  - id: msg_clear
    from: karo
    timestamp: "2026-02-09T21:00:01"
    type: clear_command
    content: /clear
    read: false
YAML

    run bash -c "source '$TEST_HARNESS'; get_unread_info; get_unread_info"
    [ "$status" -eq 0 ]
    # 2回とも specials に現れること(初回で既読化されない)
    [ "$(echo "$output" | grep -c 'msg_clear')" -eq 2 ]
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/agent_selfwatch.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: TC-FR-004 [RED]: read-update path uses lock/atomic protections
# 移動元行番号(除去前): 170-184
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "TC-FR-004 [RED]: read-update path uses lock/atomic protections" {
    # ★read更新の担い手は mark_inbox_message_read() へ移った (cmd_754 redo1)。
    #   FR-004「競合時でもYAML破損せず read更新が巻き戻らない」の検査対象も
    #   そちらへ移す。get_unread_info 側は読み取りの排他のみを担う。
    body="$(awk '/^mark_inbox_message_read\(\)/,/^}/' "$WATCHER_SCRIPT")"
    [ -n "$body" ]
    echo "$body" | grep -q "acquire_inbox_lock"
    echo "$body" | grep -q "os.replace"

    reader="$(awk '/get_unread_info\\(\\)/,/^}/' "$WATCHER_SCRIPT")"
    echo "$reader" | grep -q "flock"
    # ★読み取り側が書き戻さないこと(事前既読化の再発防止)
    ! echo "$reader" | grep -q "os.replace"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/agent_selfwatch.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: TC-FR-008: normal nudge は「無効化できる」ではなく★存在しない (cmd_754 E-1)
# 移動元行番号(除去前): 226-234
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "TC-FR-008: normal nudge は「無効化できる」ではなく★存在しない (cmd_754 E-1)" {
    # 旧: disable_normal_nudge 関数の存在を検査していた。cmd_754 で nudge 自体を
    #     廃したため、関数も削除した。文字列 grep のままでは削除を告げる
    #     コメントに当たって★通ってしまう(false pass)ので、実行して確かめる。
    run bash -c "source '$TEST_HARNESS'; declare -f disable_normal_nudge >/dev/null 2>&1 && echo STILL_EXISTS; true"
    [ "$status" -eq 0 ]
    ! echo "$output" | grep -q "STILL_EXISTS"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/agent_selfwatch.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: TC-FR-009: 特殊命令は codex でも送らず、人が打つべき手順を添えて未送信を返す (cmd_754 E-1)
# 移動元行番号(除去前): 236-250
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "TC-FR-009: 特殊命令は codex でも送らず、人が打つべき手順を添えて未送信を返す (cmd_754 E-1)" {
    # ★かつては codex で /clear→/new へ変換して打鍵していた。cmd_754 の
    #   裁定 E-1 により、稼働 pane への自動打鍵は全廃した。
    run bash -c "TEST_CLI_TYPE=codex; source '$TEST_HARNESS'; send_cli_command /clear; echo RC=\$?"
    echo "$output" | grep -q "RC=1"
    ! grep -q "send-keys" "$MOCK_LOG"
    # codex/opencode には /new を人手で入れよ、と案内する
    echo "$output" | grep -q "/new"

    > "$MOCK_LOG"
    run bash -c "TEST_CLI_TYPE=codex; source '$TEST_HARNESS'; send_cli_command '/model opus'; echo RC=\$?"
    echo "$output" | grep -q "RC=1"
    ! grep -q "send-keys" "$MOCK_LOG"
}

# ────────────────────────────────────────────────────────────────────
# 出所: tests/agent_selfwatch.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: TC-FR-011: send-keys は最終手段ですらなく、★1つも存在しない (cmd_754 E-1)
# 移動元行番号(除去前): 257-263
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "TC-FR-011: send-keys は最終手段ですらなく、★1つも存在しない (cmd_754 E-1)" {
    # 旧: FINAL_ESCALATION_ONLY 旗で「最終手段に限る」ことを表明していた
    # 新: 打鍵そのものが無い。旗ではなく★構造としての不在を検査する
    run bash -c "grep -v '^[[:space:]]*#' '$WATCHER_SCRIPT' | grep -c 'tmux send-keys' || true"
    [ "$output" = "0" ]
}
