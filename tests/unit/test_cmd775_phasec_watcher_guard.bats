#!/usr/bin/env bats
# test_cmd775_phasec_watcher_guard.bats — cmd_775 Phase C / Phase D redo2
#
# inbox_watcher.sh に追加した permission_request 打鍵抑制guard
# (将軍裁定(c)・has_pending_permission_request())の隔離試験。
#
# hookがdecision待ちの間、確認モーダルが画面に出たままになる
# (Phase 0隔離PoC③・redo1③'で実測済み)。この間にnudge・/clear・
# model_switchの打鍵が届くと2026-09-08型の誤爆(打鍵のEnterがモーダルの
# 既定選択肢を押す事故)が再発し得るため、当該agentの未決
# permission_request記録が存在する間は一切の打鍵を送らないことを検証する。
#
# ★Phase D redo2(将軍裁定 shogun_ruling_20260917_phaseD (ii)): 足軽7号
# Phase D QC§4.3が「guardの解除条件=決定ファイルの存在は、モーダルが
# 消えたことと同値ではない(defer/timeout/決定schema不正の3経路でモーダル
# 残存のまま解除されうる)」設計上の穴を発見し、将軍が解除条件を
# 「記録ファイル自身のhook_resultフィールドの有無」へ変更する裁定を下した。
# 本ファイルはこの変更に合わせ、決定ファイルベースだったT-775C-002/006を
# hook_resultベースへ更新し、fail-safe timeout系の新設試験を追加する。
#
# cmd_760 U-2 (tests/unit/test_cmd760_current_contract.bats) で確立した
# 「実tmux(isolated_tmux.sh の隔離server上の素シェルpane)への実際の
# 到達/非到達をcapture-paneで確認する。モックは使わない」という原則を
# そのまま踏襲する。稼働中の他agent pane(multiagent/shogun等の本番tmux
# サーバ)には一切触れない — 本ファイルが新規作成する隔離ソケット上の
# pane以外は一切操作しない。
#
# テスト構成:
#   T-775C-001: hook_resultが無い(timeout+マージン未超過)permission_request
#               記録があるagentへ、5つの打鍵送信箇所(send_wakeup /
#               send_wakeup_with_escape / send_cli_command "/clear" /
#               send_cli_command "/model" / send_context_reset)いずれも
#               実tmux上で送信されないこと
#   T-775C-002: hook_resultが書かれた後(決定ファイルは無くとも)は、
#               nudgeが通常どおり実tmux上で送信されること
#               (cmd_760 U-2 T-760U2-002と同型)
#   T-775C-003: 記録・決定ディレクトリが存在しない通常時、nudgeはguardの
#               影響を受けず実tmux上で送信されること(通常運用の再現)
#   T-775C-004: has_pending_permission_request はディレクトリ不在時に
#               エラーにならず即falseを返す(関数単体・高速スキップ経路)
#   T-775C-005: 他agentの未決記録は、別agentのguard判定に影響しない
#               (agent_id前方一致による誤検出が無いことの確認)
#   T-775C-006: has_pending_permission_request は、決定ファイルが存在
#               していてもhook_resultが無い記録を引き続き「未決」として
#               数える(旧ロジック=決定ファイル存在との違いの明示的検証)
#   T-775C-007: hook_resultのoutcome値(allow/deny/defer_timeout/failed)
#               いずれであっても「解決済み」と判定される(関数単体)
#   T-775C-008: hook_resultが無いままreceived_atからtimeout+マージンを
#               超過した記録はfail-safe側の例外として解決済み扱いになり、
#               超過前は引き続き未決のままであること(関数単体・境界値)
#
# SKIP=0(CLAUDE.md Test Rules 1)。全試験が実アサーションを持つ。

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    WATCHER_SCRIPT="$PROJECT_ROOT/scripts/inbox_watcher.sh"
    ISOLATED_TMUX_HELPER="$PROJECT_ROOT/scripts/isolated_tmux.sh"
    [ -f "$WATCHER_SCRIPT" ] || return 1
    [ -f "$ISOLATED_TMUX_HELPER" ] || return 1

    TEST_TMPDIR="$(mktemp -d "${BATS_TMPDIR}/cmd775c.XXXXXX")"
    TEST_SOCK="cmd775c_${BATS_TEST_NUMBER}_$$_${RANDOM}"
    TEST_HANDLE=""
}

teardown() {
    # ★killは使わない。helperのteardown(内部でexit送信+自然終了待ち)だけを呼ぶ(D006)。
    if [ -n "${TEST_HANDLE:-}" ] && [ -f "$TEST_HANDLE" ]; then
        bash "$ISOLATED_TMUX_HELPER" teardown "$TEST_HANDLE" >/dev/null 2>&1 || true
        rm -f "$TEST_HANDLE"
    fi
    # ★D002-E1: mktemp -dで直接捕捉した変数をそのまま渡すのみ。
    [ -n "${TEST_TMPDIR:-}" ] && rm -rf "$TEST_TMPDIR"
}

handle_field() {
    /usr/bin/grep -E "^${2}=" "$1" | cut -d= -f2-
}

# 隔離tmuxサーバ+素シェルpaneを作り、無修飾`tmux`呼出しをそこへ向ける
# shimをTEST_TMPDIR配下に用意する(test_cmd760_current_contract.bats
# T-760U2-002 と同型の手法)。SOCK_PATH / PANE_ID / SHIM_DIR を設定する。
setup_isolated_pane() {
    TEST_HANDLE="$(bash "$ISOLATED_TMUX_HELPER" create -L "$TEST_SOCK")"
    [ -f "$TEST_HANDLE" ]
    SOCK_PATH="$(handle_field "$TEST_HANDLE" SOCKET_PATH)"
    PANE_ID="$(handle_field "$TEST_HANDLE" PANE_ID)"

    SHIM_DIR="$(mktemp -d "${TEST_TMPDIR}/shim.XXXXXX")"
    local real_tmux
    real_tmux="$(command -v tmux)"
    cat > "$SHIM_DIR/tmux" <<SHIM
#!/usr/bin/env bash
exec "$real_tmux" -S "$SOCK_PATH" "\$@"
SHIM
    chmod +x "$SHIM_DIR/tmux"
}

# --- T-775C-001: hook_resultが無い(timeout未超過)記録は5つの打鍵送信箇所いずれも抑止する ---

@test "T-775C-001: hook_resultが無い(timeout未超過)permission_request記録は5送信箇所いずれも実tmux上へ送信させない" {
    setup_isolated_pane

    local fake_agent="cmd775c_agent1_$$"
    local idle_flag_dir="$TEST_TMPDIR/idle_flags"
    mkdir -p "$idle_flag_dir"
    touch "${idle_flag_dir}/shogun_idle_${fake_agent}"

    local perm_root="$TEST_TMPDIR/script_root"
    mkdir -p "$perm_root/queue/state/permission_requests"
    local recent_received_at
    recent_received_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    # ★hook_resultフィールドを持たない(=hookが未返却)記録。received_atは
    # 現在時刻に近く、fail-safe timeout(1800+10秒)には遠く満たない。
    cat > "$perm_root/queue/state/permission_requests/${fake_agent}_20260917T030000Z_deadbeef.yaml" <<YAML
agent_id: "${fake_agent}"
tool_name: "Bash"
received_at: '${recent_received_at}'
YAML

    # 送信前: paneは空(誤検出防止の事前確認)。
    run tmux -S "$SOCK_PATH" capture-pane -t "$PANE_ID" -p
    [ "$status" -eq 0 ]
    [[ "$output" != *"inbox9"* ]]

    local common_env=(
        AGENT_ID="$fake_agent"
        PANE_TARGET="$PANE_ID"
        CLI_TYPE="claude"
        IDLE_FLAG_DIR="$idle_flag_dir"
        SCRIPT_DIR="$perm_root"
        __INBOX_WATCHER_TESTING__=1
    )

    run env PATH="$SHIM_DIR:$PATH" "${common_env[@]}" \
        bash -c "source '$WATCHER_SCRIPT'; send_wakeup 9; echo RC=\$?"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "RC=0"

    run env PATH="$SHIM_DIR:$PATH" "${common_env[@]}" \
        bash -c "source '$WATCHER_SCRIPT'; send_wakeup_with_escape 9; echo RC=\$?"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "RC=0"

    run env PATH="$SHIM_DIR:$PATH" "${common_env[@]}" \
        bash -c "source '$WATCHER_SCRIPT'; send_cli_command /clear; echo RC=\$?"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "RC=1"

    run env PATH="$SHIM_DIR:$PATH" "${common_env[@]}" \
        bash -c "source '$WATCHER_SCRIPT'; send_cli_command '/model opus'; echo RC=\$?"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "RC=1"

    run env PATH="$SHIM_DIR:$PATH" "${common_env[@]}" \
        bash -c "source '$WATCHER_SCRIPT'; send_context_reset; echo RC=\$?"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "RC=1"

    # 5箇所いずれも、実paneに一切の痕跡を残していないこと。
    run tmux -S "$SOCK_PATH" capture-pane -t "$PANE_ID" -p
    [ "$status" -eq 0 ]
    [[ "$output" != *"inbox9"* ]]
    [[ "$output" != *"/clear"* ]]
    [[ "$output" != *"/model"* ]]
    [[ "$output" != *"/new"* ]]
}

# --- T-775C-002: hook_resultが書かれればnudgeは通常どおり実tmux上へ届く(決定ファイルは無くともよい) ---

@test "T-775C-002: hook_resultが書かれた後はnudgeが通常どおり実tmux上で送信される(決定ファイル無し)" {
    setup_isolated_pane

    local fake_agent="cmd775c_agent2_$$"
    local idle_flag_dir="$TEST_TMPDIR/idle_flags2"
    mkdir -p "$idle_flag_dir"
    touch "${idle_flag_dir}/shogun_idle_${fake_agent}"

    local perm_root="$TEST_TMPDIR/script_root2"
    local request_id="${fake_agent}_20260917T030300Z_1234abcd"
    # ★決定ディレクトリ自体を作らない — 将軍裁定(ii)により、guard解除は
    # 決定ファイルの存在に一切依存しないことを明示的に検証する。
    mkdir -p "$perm_root/queue/state/permission_requests"
    cat > "$perm_root/queue/state/permission_requests/${request_id}.yaml" <<YAML
agent_id: "${fake_agent}"
hook_result:
  outcome: allow
  returned_at: '2026-09-17T03:03:05Z'
YAML

    run tmux -S "$SOCK_PATH" capture-pane -t "$PANE_ID" -p
    [ "$status" -eq 0 ]
    [[ "$output" != *"inbox5"* ]]

    run env PATH="$SHIM_DIR:$PATH" \
        AGENT_ID="$fake_agent" \
        PANE_TARGET="$PANE_ID" \
        CLI_TYPE="claude" \
        IDLE_FLAG_DIR="$idle_flag_dir" \
        SCRIPT_DIR="$perm_root" \
        __INBOX_WATCHER_TESTING__=1 \
        bash -c "source '$WATCHER_SCRIPT'; send_wakeup 5"
    [ "$status" -eq 0 ]

    run tmux -S "$SOCK_PATH" capture-pane -t "$PANE_ID" -p
    [ "$status" -eq 0 ]
    [[ "$output" == *"inbox5"* ]]
}

# --- T-775C-003: 記録・決定ディレクトリ不在の通常時、guardは影響しない ---

@test "T-775C-003: 記録・決定ディレクトリが存在しない通常時、nudgeはguardの影響を受けず送信される" {
    setup_isolated_pane

    local fake_agent="cmd775c_agent3_$$"
    local idle_flag_dir="$TEST_TMPDIR/idle_flags3"
    mkdir -p "$idle_flag_dir"
    touch "${idle_flag_dir}/shogun_idle_${fake_agent}"

    # ★queue/state/permission_requests・permission_decisions のいずれも
    # 作らない(hookが一度も発火していない通常運用時の再現)。
    local perm_root="$TEST_TMPDIR/script_root3"
    mkdir -p "$perm_root"
    [ ! -d "$perm_root/queue/state/permission_requests" ]

    run env PATH="$SHIM_DIR:$PATH" \
        AGENT_ID="$fake_agent" \
        PANE_TARGET="$PANE_ID" \
        CLI_TYPE="claude" \
        IDLE_FLAG_DIR="$idle_flag_dir" \
        SCRIPT_DIR="$perm_root" \
        __INBOX_WATCHER_TESTING__=1 \
        bash -c "source '$WATCHER_SCRIPT'; send_wakeup 7"
    [ "$status" -eq 0 ]

    run tmux -S "$SOCK_PATH" capture-pane -t "$PANE_ID" -p
    [ "$status" -eq 0 ]
    [[ "$output" == *"inbox7"* ]]
}

# --- T-775C-004: ディレクトリ不在時、has_pending_permission_request はエラーなく即false ---

@test "T-775C-004: has_pending_permission_request はディレクトリ不在時にエラーなく即falseを返す" {
    local fake_agent="cmd775c_unit1_$$"
    local perm_root="$TEST_TMPDIR/unit_root1"
    mkdir -p "$perm_root"

    run env AGENT_ID="$fake_agent" \
        SCRIPT_DIR="$perm_root" \
        PANE_TARGET="dummy:0.0" \
        __INBOX_WATCHER_TESTING__=1 \
        bash -c "source '$WATCHER_SCRIPT'; has_pending_permission_request"
    [ "$status" -eq 1 ]
}

# --- T-775C-005: 他agentの未決記録は別agentに影響しない ---

@test "T-775C-005: 他agentの未決記録は別agentのguard判定に影響しない" {
    local agent_a="cmd775c_agentA_$$"
    local agent_b="cmd775c_agentB_$$"
    local perm_root="$TEST_TMPDIR/unit_root2"
    mkdir -p "$perm_root/queue/state/permission_requests"
    cat > "$perm_root/queue/state/permission_requests/${agent_a}_20260917T031000Z_aaaaaaaa.yaml" <<YAML
agent_id: "${agent_a}"
YAML

    run env AGENT_ID="$agent_a" \
        SCRIPT_DIR="$perm_root" \
        PANE_TARGET="dummy:0.0" \
        __INBOX_WATCHER_TESTING__=1 \
        bash -c "source '$WATCHER_SCRIPT'; has_pending_permission_request"
    [ "$status" -eq 0 ]

    run env AGENT_ID="$agent_b" \
        SCRIPT_DIR="$perm_root" \
        PANE_TARGET="dummy:0.0" \
        __INBOX_WATCHER_TESTING__=1 \
        bash -c "source '$WATCHER_SCRIPT'; has_pending_permission_request"
    [ "$status" -eq 1 ]
}

# --- T-775C-006: 決定ファイルが存在してもhook_resultが無ければ未決のまま(旧ロジックとの違いの明示的検証) ---

@test "T-775C-006: has_pending_permission_request は決定ファイルが存在してもhook_resultが無い記録を未決として数える" {
    local fake_agent="cmd775c_unit3_$$"
    local perm_root="$TEST_TMPDIR/unit_root3"
    local request_id="${fake_agent}_20260917T031500Z_bbbbbbbb"
    local recent_received_at
    recent_received_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mkdir -p "$perm_root/queue/state/permission_requests" "$perm_root/queue/state/permission_decisions"
    # ★旧ロジック(Phase C)なら本記録は「決定ファイルあり」で解決済み扱い
    # だった。Phase D redo2の新ロジックはhook_resultの有無のみを見るため、
    # 決定ファイルが存在してもhook_resultが無ければ未決のままとなることを
    # 明示的に検証する(旧仕様からの意図的な後方非互換)。
    cat > "$perm_root/queue/state/permission_requests/${request_id}.yaml" <<YAML
agent_id: "${fake_agent}"
received_at: '${recent_received_at}'
YAML
    cat > "$perm_root/queue/state/permission_decisions/${request_id}.yaml" <<YAML
request_id: "${request_id}"
decision: deny
YAML

    run env AGENT_ID="$fake_agent" \
        SCRIPT_DIR="$perm_root" \
        PANE_TARGET="dummy:0.0" \
        __INBOX_WATCHER_TESTING__=1 \
        bash -c "source '$WATCHER_SCRIPT'; has_pending_permission_request"
    [ "$status" -eq 0 ]
}

# --- T-775C-007: hook_resultはoutcomeの値によらず解決済みと判定される ---

@test "T-775C-007: hook_resultのoutcome値(allow/deny/defer_timeout/failed)いずれでも解決済みと判定される" {
    local perm_root="$TEST_TMPDIR/unit_root4"
    mkdir -p "$perm_root/queue/state/permission_requests"

    local outcome
    for outcome in allow deny defer_timeout failed; do
        local fake_agent="cmd775c_unit4_${outcome}_$$"
        local request_id="${fake_agent}_20260917T032000Z_cccccccc"
        cat > "$perm_root/queue/state/permission_requests/${request_id}.yaml" <<YAML
agent_id: "${fake_agent}"
hook_result:
  outcome: ${outcome}
  returned_at: '2026-09-17T03:20:05Z'
YAML

        run env AGENT_ID="$fake_agent" \
            SCRIPT_DIR="$perm_root" \
            PANE_TARGET="dummy:0.0" \
            __INBOX_WATCHER_TESTING__=1 \
            bash -c "source '$WATCHER_SCRIPT'; has_pending_permission_request"
        [ "$status" -eq 1 ]
    done
}

# --- T-775C-008: fail-safe timeoutの境界(超過で解決済み・未超過で未決) ---

@test "T-775C-008: hook_resultが無くreceived_atがtimeout+マージンを超過した記録はfail-safeで解決済み扱いになり、超過前は未決のままである" {
    local perm_root="$TEST_TMPDIR/unit_root5"
    mkdir -p "$perm_root/queue/state/permission_requests"
    local now_epoch
    now_epoch="$(date -u +%s)"

    # 局面A: timeout(1800)+マージン(10、hook側既定PERMISSION_HOOK_TIMEOUT_
    # SECONDS/__PERMISSION_HOOK_MARGIN_SECONDSと同値)=1810秒を50秒超過
    # — fail-safeとして解決済み扱い(打鍵許可)になるべき。
    local agent_expired="cmd775c_unit5_expired_$$"
    local expired_received_at
    expired_received_at="$(date -u -d "@$((now_epoch - 1860))" +%Y-%m-%dT%H:%M:%SZ)"
    cat > "$perm_root/queue/state/permission_requests/${agent_expired}_20260917T033000Z_dddddddd.yaml" <<YAML
agent_id: "${agent_expired}"
received_at: '${expired_received_at}'
YAML

    run env AGENT_ID="$agent_expired" \
        SCRIPT_DIR="$perm_root" \
        PANE_TARGET="dummy:0.0" \
        __INBOX_WATCHER_TESTING__=1 \
        bash -c "source '$WATCHER_SCRIPT'; has_pending_permission_request"
    [ "$status" -eq 1 ]

    # 局面B: 1810秒に50秒満たない — 引き続き未決(打鍵禁止)のままであるべき。
    local agent_notyet="cmd775c_unit5_notyet_$$"
    local notyet_received_at
    notyet_received_at="$(date -u -d "@$((now_epoch - 1760))" +%Y-%m-%dT%H:%M:%SZ)"
    cat > "$perm_root/queue/state/permission_requests/${agent_notyet}_20260917T033100Z_eeeeeeee.yaml" <<YAML
agent_id: "${agent_notyet}"
received_at: '${notyet_received_at}'
YAML

    run env AGENT_ID="$agent_notyet" \
        SCRIPT_DIR="$perm_root" \
        PANE_TARGET="dummy:0.0" \
        __INBOX_WATCHER_TESTING__=1 \
        bash -c "source '$WATCHER_SCRIPT'; has_pending_permission_request"
    [ "$status" -eq 0 ]
}
