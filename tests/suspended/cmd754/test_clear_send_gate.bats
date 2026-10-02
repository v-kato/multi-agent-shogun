# 出所ファイル: tests/unit/test_clear_send_gate.bats

# ────────────────────────────────────────────────────────────────────
# 出所: tests/unit/test_clear_send_gate.bats (58ed69c 由来・cmd_754+cmd_755で追加)
# 元@testブロック名: T-CG-052: inbox_watcher に tmux send-keys は今も1つも無い
# 移動元行番号(除去前): 877-881
# 移動理由: cmd_760で7c59260(cmd_754直前)へ巻き戻されたため前提が崩れ、標準suiteでFAILしていた(将軍裁定20260910・shogun_ruling_20260910_skip_conflict・U-1)。cmd_757②再結線時に復帰させる。
# ────────────────────────────────────────────────────────────────────
@test "T-CG-052: inbox_watcher に tmux send-keys は今も1つも無い" {
    run bash -c "grep -v '^[[:space:]]*#' '$WATCHER_SCRIPT' | grep -c 'tmux send-keys' || true"
    [ "$output" = "0" ]
}
