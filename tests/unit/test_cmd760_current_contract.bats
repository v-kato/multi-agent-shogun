#!/usr/bin/env bats
# test_cmd760_current_contract.bats — cmd_760 A-3 scope差替 U-2
#
# ★将軍裁定(2026-09-10・queue/shogun_to_karo.yaml の
#   shogun_ruling_20260910_skip_conflict)により、旧A-3受入条件
#   (「skip+理由で保存」)はCLAUDE.md Test Rules 1(SKIP=FAIL)と
#   衝突するため無効化された。cmd_754巻き戻し(commit 7c59260)前提の
#   失敗71件はU-1で tests/suspended/cmd754/ へ退避した。
#
# ★本ファイルはU-2として要求された、現行契約(7c59260・cmd_754巻き戻し後
#   の実際の挙動)を検査する★正の試験である。「無いことの証明」ではなく
#   「在ることの証明」で書く(cmd_757④で確立した原則と同型)。
#
#   - T-760U2-001: send_wakeup() 関数本体に実tmux send-keys呼出しが
#     ★在ることを静的に検査する。cmd_754時代のT-PF-100
#     (tests/unit/test_isolated_tmux_helper.bats:145 のコメント参照)が
#     「send-keys 出現数0」を検査していたのと同型の裏返しであり、
#     現行契約ではこの出現数は0ではない。
#   - T-760U2-002: idle agentへのnudgeが、隔離tmux
#     (scripts/isolated_tmux.sh が作る自分専用serverの素シェルpane・
#     稼働中のmultiagent/shogun paneには一切触れない)に対して★実際に
#     打鍵として発火することを、モックを一切使わず実tmuxのcapture-pane
#     で確認する。
#
# ★重複回避: 標準suiteの他試験(tests/unit/test_send_wakeup.bats等・
#   本cmdのU-1でtests/suspended/cmd754/へ33件を移した後の残存分)は、
#   MOCK_LOGへ記録された仮想tmux関数呼出しを検査する「送られない」
#   ことの試験のみが残る。本ファイルは実tmuxプロセスに対して「送られる」
#   ことを検査する点で重複しない。

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    WATCHER_SCRIPT="$PROJECT_ROOT/scripts/inbox_watcher.sh"
    ISOLATED_TMUX_HELPER="$PROJECT_ROOT/scripts/isolated_tmux.sh"
    [ -f "$WATCHER_SCRIPT" ] || return 1
    [ -f "$ISOLATED_TMUX_HELPER" ] || return 1

    TEST_TMPDIR="$(mktemp -d "${BATS_TMPDIR}/cmd760u2.XXXXXX")"
    TEST_SOCK="cmd760u2_${BATS_TEST_NUMBER}_$$_${RANDOM}"
    TEST_HANDLE=""
}

teardown() {
    # ★killは使わない。helperのteardown(内部でexit送信+自然終了待ち)
    #   だけを呼ぶ(D006)。
    if [ -n "${TEST_HANDLE:-}" ] && [ -f "$TEST_HANDLE" ]; then
        bash "$ISOLATED_TMUX_HELPER" teardown "$TEST_HANDLE" >/dev/null 2>&1 || true
        rm -f "$TEST_HANDLE"
    fi
    # ★D002-E1: mktemp -dで直接捕捉した変数をそのまま渡すのみ。
    [ -n "${TEST_TMPDIR:-}" ] && rm -rf "$TEST_TMPDIR"
}

# handle file から1 fieldの値だけを取り出す(test_isolated_tmux_helper.bats
# のhandle_field()と同型)。
handle_field() {
    /usr/bin/grep -E "^${2}=" "$1" | cut -d= -f2-
}

@test "T-760U2-001: send_wakeup() は実tmux send-keysを実際に呼び出すコードを持つ(cmd_754巻き戻し後の現行契約・旧T-PF-100の裏返し)" {
    run sed -n '/^send_wakeup() {/,/^}/p' "$WATCHER_SCRIPT"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    call_count="$(echo "$output" | /usr/bin/grep -c 'tmux send-keys')"
    [ "$call_count" -gt 0 ]
}

@test "T-760U2-002: idle agentへのnudgeは隔離tmux上の素シェルpaneに実際に打鍵として届く(実動作・モック無し)" {
    TEST_HANDLE="$(bash "$ISOLATED_TMUX_HELPER" create -L "$TEST_SOCK")"
    [ -f "$TEST_HANDLE" ]
    local sock_path pane_id
    sock_path="$(handle_field "$TEST_HANDLE" SOCKET_PATH)"
    pane_id="$(handle_field "$TEST_HANDLE" PANE_ID)"

    # ★nudge送信前: paneにはまだ何も打たれていない(誤検出防止の事前確認)。
    run tmux -S "$sock_path" capture-pane -t "$pane_id" -p
    [ "$status" -eq 0 ]
    [[ "$output" != *"inbox3"* ]]

    # send_wakeup内部の無修飾 `tmux` 呼出しをこの隔離serverへだけ向ける
    # ためのPATH shim。tests/verify_cmd_754_isolated.sh および
    # tests/unit/test_isolated_tmux_helper.bats T-IT-039 と同型の手法
    # (シェル関数ではなく実行可能fileにする理由も同じ: 呼出し元は
    # `timeout tmux ...` の形でtmuxを呼ぶため、関数では見つからず素の
    # tmuxを叩いてしまう)。isolated_tmux.sh自体(create/teardown呼出し)
    # はこのshimを経由させない素のPATHで動かすため干渉しない。
    local shim_dir real_tmux
    shim_dir="$(mktemp -d "${TEST_TMPDIR}/shim.XXXXXX")"
    real_tmux="$(command -v tmux)"
    cat > "$shim_dir/tmux" <<SHIM
#!/usr/bin/env bash
exec "$real_tmux" -S "$sock_path" "\$@"
SHIM
    chmod +x "$shim_dir/tmux"

    local idle_flag_dir fake_agent
    idle_flag_dir="$TEST_TMPDIR/idle_flags"
    mkdir -p "$idle_flag_dir"
    fake_agent="cmd760u2_fakeagent_$$"
    # agent_is_busy(): CLI_TYPE=claude 経路はフラグfileの有無で判定する
    # (フラグ在り=idle)。あらかじめidleを装う。
    # agent_has_self_watch(): pgrepは架空agent_idの inbox/*.yaml パターン
    # には実プロセスが一致しないため、自然に「self-watch無し」判定となり
    # 素通りする(モック不要)。
    touch "${idle_flag_dir}/shogun_idle_${fake_agent}"

    run env PATH="$shim_dir:$PATH" \
        AGENT_ID="$fake_agent" \
        PANE_TARGET="$pane_id" \
        CLI_TYPE="claude" \
        IDLE_FLAG_DIR="$idle_flag_dir" \
        __INBOX_WATCHER_TESTING__=1 \
        bash -c "source '$WATCHER_SCRIPT'; send_wakeup 3"
    [ "$status" -eq 0 ]

    # ★実際に打鍵が届いたことを、shimを経由しない独立した経路
    #   (直接 -S 指定)で確認する。
    run tmux -S "$sock_path" capture-pane -t "$pane_id" -p
    [ "$status" -eq 0 ]
    [[ "$output" == *"inbox3"* ]]
}
