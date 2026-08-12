#!/usr/bin/env bats
# test_cdp_identity_preflight.bats — ps-bridge.ps1 port-owner action と
# identity_preflight.py CLI の実機テスト (cmd_675)
#
# cmd_673で発生した罠7(WSL側Electronへ接続したつもりがWindows側に残存していた別
# インスタンスへ誤接続。navigator.platformがWin32を返す不審な兆候から発覚・実害
# なしと確認済み)の再発防止として追加したidentity preflight機構の実機検証。
#
# navigator.platform/title/url照合はEletron/Chrome等の実CDPターゲットを要するため
# 本batsの対象外とし(純粋ロジックはモックベースの
# tests/unit/test_cdp_identity_preflight_unit.py でカバー、実機での故障注入・正常系
# 実証はcmd_675完了報告のPhase C記録を参照)、本batsではCDPを介さないport-owner系統
# (Windows側プロセス占有照合)のみを対象にする。
#
# 前提: powershell.exe (WSL2→Windows側) が呼び出せる環境でのみ実行する。
# ダミーリスナーはWindows側で起動主(本テスト)のみが起動・終了させ、既存プロセスには
# 一切触れない(D006・cmd_627原則)。teardownで確実にStop-Processする。

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
CDP_DIR="$SCRIPT_DIR/skills/shogun-cdp-automation/scripts/cdp"
PS_BRIDGE="$SCRIPT_DIR/skills/shogun-cdp-automation/scripts/ps-bridge.ps1"
TEST_PORT=19871   # 実運用ポート(9222/9223)と衝突しない固定テスト用ポート
FREE_PORT=19999   # 常に未使用であることを期待するポート (status=none 確認用)
DUAL_PORT=19872   # 複数owner共存テスト専用ポート (cmd_675 redo1・C675-QC-01回帰)

setup_file() {
    command -v powershell.exe >/dev/null 2>&1 || skip "powershell.exe not available (not WSL2/Windows env)"
    command -v wslpath >/dev/null 2>&1 || skip "wslpath not available (not WSL2 env)"
    command -v iconv >/dev/null 2>&1 || skip "iconv not available"
}

# Helper: ps-bridge.ps1をAction/引数付きで実行し、CP932->UTF-8変換した出力を返す
# (test_ps_bridge_path_guard.batsと同一パターン)
run_ps_bridge() {
    local win_ps1
    win_ps1="$(wslpath -w "$PS_BRIDGE")"
    local raw_output
    raw_output="$(powershell.exe -ExecutionPolicy Bypass -File "$win_ps1" "$@" 2>&1)"
    local rc=$?
    printf '%s' "$raw_output" | iconv -f CP932 -t UTF-8 2>/dev/null || printf '%s' "$raw_output"
    return "$rc"
}

# Windows側にTEST_PORTをLISTENするダミーpowershellプロセスを起動する。
# Start-Process -PassThru で確実にそのプロセス固有のPIDのみを捕捉し、
# teardownでPID限定のStop-Processのみ行う(名前一致の一括killは絶対に行わない)。
start_dummy_listener() {
    DUMMY_SCRIPT="$(mktemp "$BATS_TMPDIR/dummy_listener.XXXXXX.ps1")"
    cat > "$DUMMY_SCRIPT" <<PS1EOF
\$l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $TEST_PORT)
\$l.Start()
Start-Sleep -Seconds 90
PS1EOF
    local listener_win
    listener_win="$(wslpath -w "$DUMMY_SCRIPT")"

    DUMMY_PID="$(powershell.exe -NoProfile -Command \
        "(Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File','$listener_win') -PassThru -WindowStyle Hidden).Id" \
        2>/dev/null | tr -d '\r\n')"

    [[ "$DUMMY_PID" =~ ^[0-9]+$ ]] || return 1

    # LISTEN確立まで待機 (最大5秒)
    local i
    for i in $(seq 1 25); do
        run run_ps_bridge -Action port-owner -Port "$TEST_PORT"
        if [[ "$output" == *'"status":"found"'* ]]; then
            return 0
        fi
        sleep 0.2
    done
    return 1
}

stop_dummy_listener() {
    if [[ "${DUMMY_PID:-}" =~ ^[0-9]+$ ]]; then
        powershell.exe -NoProfile -Command "Stop-Process -Id $DUMMY_PID -Force -ErrorAction SilentlyContinue" >/dev/null 2>&1
    fi
    [ -n "${DUMMY_SCRIPT:-}" ] && rm -f "$DUMMY_SCRIPT"
    unset DUMMY_PID DUMMY_SCRIPT
}

# cmd_675 redo1 (C675-QC-01回帰用): DUAL_PORT上に指定LocalAddressでダミーlistenerを
# 追加起動する。同一ポートに複数owner(異なるLocalAddress)を共存させ、ps-bridge.ps1の
# port-ownerが全件列挙することを検証する(軍師実機故障注入の再現: Windows側0.0.0.0
# bindを先に起動し、127.0.0.1 bindを後から起動しても両者は共存する)。
DUAL_PIDS=()
DUAL_SCRIPTS=()

start_dual_listener() {
    local addr="$1"
    local script
    script="$(mktemp "$BATS_TMPDIR/dummy_dual_listener.XXXXXX.ps1")"
    cat > "$script" <<PS1EOF
\$l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Parse("$addr"), $DUAL_PORT)
\$l.Start()
Start-Sleep -Seconds 90
PS1EOF
    local listener_win dpid
    listener_win="$(wslpath -w "$script")"
    dpid="$(powershell.exe -NoProfile -Command \
        "(Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File','$listener_win') -PassThru -WindowStyle Hidden).Id" \
        2>/dev/null | tr -d '\r\n')"
    [[ "$dpid" =~ ^[0-9]+$ ]] || return 1
    DUAL_PIDS+=("$dpid")
    DUAL_SCRIPTS+=("$script")
    return 0
}

stop_dual_listeners() {
    local p
    for p in "${DUAL_PIDS[@]}"; do
        [[ "$p" =~ ^[0-9]+$ ]] && powershell.exe -NoProfile -Command "Stop-Process -Id $p -Force -ErrorAction SilentlyContinue" >/dev/null 2>&1
    done
    local s
    for s in "${DUAL_SCRIPTS[@]}"; do
        [ -n "$s" ] && rm -f "$s"
    done
    DUAL_PIDS=()
    DUAL_SCRIPTS=()
}

teardown() {
    stop_dummy_listener
    stop_dual_listeners
}

# --- ps-bridge.ps1 -Action port-owner (読取専用) ---

@test "port-owner: 未使用ポートはstatus=noneを返す" {
    run run_ps_bridge -Action port-owner -Port "$FREE_PORT"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status":"none"'* ]]
    [[ "$output" == *"\"port\":$FREE_PORT"* ]]
}

@test "port-owner: 占有中ポートはPID付きstatus=foundを返す(Stop-Processは呼ばない)" {
    start_dummy_listener || skip "dummy listener起動に失敗(環境依存)"
    run run_ps_bridge -Action port-owner -Port "$TEST_PORT"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status":"found"'* ]]
    [[ "$output" == *"\"port\":$TEST_PORT"* ]]
    [[ "$output" == *'"pid":'"$DUMMY_PID"* ]]
    [[ "$output" == *'"processName":"powershell"'* ]]
    # port-owner呼出だけではプロセスが終了していないことを確認 (read-only保証)
    run powershell.exe -NoProfile -Command "(Get-Process -Id $DUMMY_PID -ErrorAction SilentlyContinue) -ne \$null"
    [[ "$output" == *"True"* ]]
}

@test "port-owner: 存在しないポート番号(0)を渡してもクラッシュしない" {
    run run_ps_bridge -Action port-owner -Port 0
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status":"none"'* ]]
}

@test "port-owner: 同一ポートに異なるLocalAddressの複数LISTEN ownerが共存する場合は全件を返す(C675-QC-01回帰)" {
    # 軍師実機故障注入の再現: Windows側ネイティブ(0.0.0.0)を先に起動し、
    # wslrelay相当(127.0.0.1)を後から起動しても両者は同一ポートで共存する。
    start_dual_listener "0.0.0.0" || skip "dual listener(0.0.0.0)起動に失敗(環境依存)"
    start_dual_listener "127.0.0.1" || skip "dual listener(127.0.0.1)起動に失敗(環境依存・同一ポート2バインド不可の可能性)"

    local i found_count=0
    for i in $(seq 1 25); do
        run run_ps_bridge -Action port-owner -Port "$DUAL_PORT"
        found_count=$(printf '%s' "$output" | grep -o '"pid"' | wc -l)
        [ "$found_count" -ge 2 ] && break
        sleep 0.2
    done

    [ "$found_count" -ge 2 ]
    [[ "$output" == *'"status":"found"'* ]]
    [[ "$output" == *"\"port\":$DUAL_PORT"* ]]
    # 先頭1件への縮退が無いこと(Select-Object -First 1除去)の直接確認: 両PIDが出力に含まれる
    [[ "$output" == *"\"pid\":${DUAL_PIDS[0]}"* ]]
    [[ "$output" == *"\"pid\":${DUAL_PIDS[1]}"* ]]
    [[ "$output" == *'"localAddress":"0.0.0.0"'* ]]
    [[ "$output" == *'"localAddress":"127.0.0.1"'* ]]
}

# --- identity_preflight.py CLI (--expect-port-owner) ---

@test "identity_preflight.py: --expect-port-owner none は未使用ポートでexit0" {
    run python3 "$CDP_DIR/identity_preflight.py" --port "$FREE_PORT" --expect-port-owner none
    [ "$status" -eq 0 ]
    [[ "$output" == *"MATCH: port_owner"* ]]
    [[ "$output" == *"OK: identity preflight passed"* ]]
}

@test "identity_preflight.py: --expect-port-owner none は占有中ポートでexit64(罠7再現・停止して報告のみ)" {
    start_dummy_listener || skip "dummy listener起動に失敗(環境依存)"
    run python3 "$CDP_DIR/identity_preflight.py" --port "$TEST_PORT" --expect-port-owner none
    [ "$status" -eq 64 ]
    [[ "$output" == *"MISMATCH: port_owner expected='none'"* ]]
    [[ "$output" == *"STOP: identity preflight failed"* ]]
    [[ "$output" == *"占有プロセスの自動終了は行っていません"* ]]
    # 停止判定を返しただけでプロセスは生存していること(自動終了しない制約の直接確認)
    run powershell.exe -NoProfile -Command "(Get-Process -Id $DUMMY_PID -ErrorAction SilentlyContinue) -ne \$null"
    [[ "$output" == *"True"* ]]
}

@test "identity_preflight.py: --expect-port-owner に占有プロセス名を指定すると一致でexit0" {
    start_dummy_listener || skip "dummy listener起動に失敗(環境依存)"
    run python3 "$CDP_DIR/identity_preflight.py" --port "$TEST_PORT" --expect-port-owner powershell
    [ "$status" -eq 0 ]
    [[ "$output" == *"MATCH: port_owner"* ]]
}

@test "identity_preflight.py: --expect-port-owner に無関係な文字列を指定すると不一致でexit64" {
    start_dummy_listener || skip "dummy listener起動に失敗(環境依存)"
    run python3 "$CDP_DIR/identity_preflight.py" --port "$TEST_PORT" --expect-port-owner "totally-unrelated-app-name"
    [ "$status" -eq 64 ]
    [[ "$output" == *"MISMATCH: port_owner"* ]]
}

@test "identity_preflight.py: 期待値を一切渡さない場合は全項目skipでexit0(CDP接続不要)" {
    run python3 "$CDP_DIR/identity_preflight.py" --port "$FREE_PORT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK: identity preflight passed"* ]]
}

@test "identity_preflight.py: --expect-port-ownerのみ指定時はCDPターゲット解決を要求しない" {
    # target-id解決 (get_first_target_id) はCDP接続失敗時にexit1で止まるが、
    # --expect-port-ownerのみの場合はCDPに触れず完結するはず(exit0/64のいずれか、
    # 少なくともCDP接続エラーのexit1にはならないことを確認する)
    run python3 "$CDP_DIR/identity_preflight.py" --port "$FREE_PORT" --expect-port-owner none
    [ "$status" -ne 1 ]
}

# --- identity_preflight.py CLI (--strict, cmd_675 redo1・C675-QC-02回帰) ---

@test "identity_preflight.py: --strict指定でも判定不能がなければexit0(正常系への影響なし)" {
    run python3 "$CDP_DIR/identity_preflight.py" --port "$FREE_PORT" --expect-port-owner none --strict
    [ "$status" -eq 0 ]
    [[ "$output" == *"MATCH: port_owner"* ]]
    [[ "$output" == *"OK: identity preflight passed"* ]]
}

@test "identity_preflight.py: PATH改変でpowershell.exe不在時、--strict未指定ならexit0のまま(旧来のfail-open挙動の記録)" {
    run env PATH=/usr/bin python3 "$CDP_DIR/identity_preflight.py" --port "$FREE_PORT" --expect-port-owner none
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARN: port_owner"* ]]
    [[ "$output" == *"OK: identity preflight passed"* ]]
}

@test "identity_preflight.py: PATH改変でpowershell.exe不在時、--strict指定なら非0終了する(C675-QC-02の直接回帰)" {
    # 軍師実機故障注入の再現: PATH=/usr/bin (powershell.exeが見つからない状態)。
    # 修正前はWARN直後にOK・exit 0となるfail-openだった。
    run env PATH=/usr/bin python3 "$CDP_DIR/identity_preflight.py" --port "$FREE_PORT" --expect-port-owner none --strict
    [ "$status" -ne 0 ]
    [[ "$output" == *"WARN: port_owner"* ]]
    [[ "$output" == *"STOP: identity preflight failed"* ]]
    [[ "$output" == *"判定不能"* ]]
}
