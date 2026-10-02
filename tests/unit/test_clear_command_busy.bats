#!/usr/bin/env bats
# test_clear_command_busy.bats — codex/opencode宛て clear_command の未読保持試験 (cmd_792②③)
#
# 背景:
#   2026-09-30 16:15、Codex軍師への clear_command が、前タスクのQC中(busy)に
#   /new を送り、15秒後に起動プロンプトまで強行して作業中の文脈を失わせた。
#   原因は2段: ①get_unread_info が clear_command を★抽出時点で既読化するため、
#   busy で送れなかった要求が次巡回から消える ②send_startup_prompt が15秒待った
#   末になお busy でも強行する。
#   cmd_792② はこれを、実効CLIが codex/opencode かつ type=clear_command の組に
#   限って直す: 抽出時に既読化せず specials へ id を載せ、busy/permission保留・
#   送信失敗では read:false のまま保持し、reset(Codexは起動プロンプトまで)が
#   完了した ID だけを共有inbox lock+再読込+原子的replaceで既読化する。
#
# 設計: context/cmd_787_792_design_review.md §B「Batsと隔離tmuxの試験方針」。
#   ★本ファイルは get_unread_info → process_unread → send_cli_command の
#   ★実際の組合せを通す(個々の関数だけを切り出さない)。
#   ★既存 tests/unit/test_send_wakeup.bats のヘッダ(cmd_754時代の「常に打鍵しない」)
#   は現行契約と混在しているため、その文言を本ファイルの期待値へ転記していない。
#   現行契約は docs/delivery_channels.md の時点注記(cmd_760で nudge/clear/model は
#   復元済み。cmd_792②はそれを busy 時に狭める変更)に従う。
#
# 実関数は __INBOX_WATCHER_TESTING__=1 で source する。INBOX/LOCKFILE/METRICS_FILE/
#   IDLE_FLAG_DIR/PERMISSION_REQUESTS_DIR は全て試験用 fixture 領域へ向ける
#   (★本番 queue/inbox は一切読まない・書かない)。tmux・timeout・sleep は関数で
#   差し替えるので、稼働中のpane・agentには一切打鍵しない。各試験は本番と同じ
#   `set -euo pipefail` の下で process_unread を回す(set -e/-u による
#   watcher の突然死も検出する)。
#
# 試験表(設計書 §B)との対応:
#   行1  codex/opencode・clearのみ・busy 連続2周期以上
#          T-CCB-001 (codex) / T-CCB-002 (opencode)
#   行2  上記からidleへ変更して次周期 / さらに1周期でreset反復0
#          T-CCB-003 (codex) / T-CCB-004 (opencode)
#   行3  Codex: reset直前idle → startup時busy → 次周期idle
#          T-CCB-005
#   行4  内側guard の busy/permission 保留・tmux送信失敗
#          T-CCB-006 (permission) / T-CCB-007 (内側busy) /
#          T-CCB-008 (codex /new 本文失敗) / T-CCB-009 (opencode Enter失敗)
#   行5  同batch・IDの再読 / 抽出後に別IDが追加
#          T-CCB-010 (同batchの重複吸収) / T-CCB-011 (抽出後に追加された別ID)
#   行6  実効CLIが引数CLIと異なる
#          T-CCB-012
#   行7  Claude clear / 足軽4分 / model_switch / cli_restart / clearなしtask_assigned
#          T-CCB-013〜T-CCB-017
#   補助  T-CCB-018 shogun / T-CCB-019 startup strict / T-CCB-020 保留ID失効 /
#          T-CCB-021 既読化helper / T-CCB-022 本番inbox非参照(静的) /
#          T-CCB-023 startup送信失敗 / T-CCB-024 隔離tmux実機
#
# SKIP=0(CLAUDE.md Test Rules 1)。全試験が実アサーションを持つ。

setup() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export WATCHER_SCRIPT="${TEST_WATCHER_SCRIPT:-$PROJECT_ROOT/scripts/inbox_watcher.sh}"
    export VENV_PYTHON="$PROJECT_ROOT/.venv/bin/python3"
    export ISOLATED_TMUX_HELPER="$PROJECT_ROOT/scripts/isolated_tmux.sh"
    [ -f "$WATCHER_SCRIPT" ] || return 1
    [ -x "$VENV_PYTHON" ] || return 1

    # 一時領域は bats が試験ごとに作り自動で片付ける BATS_TEST_TMPDIR のみを使う
    # (test_claude_session_resume.bats と同じ流儀。本ファイルに再帰削除は無い)。
    export TEST_TMPDIR="$BATS_TEST_TMPDIR"
    mkdir -p "$TEST_TMPDIR/queue/inbox" "$TEST_TMPDIR/idle_flags" "$TEST_TMPDIR/permission_requests"
    export TEST_INBOX="$TEST_TMPDIR/queue/inbox/test_agent.yaml"
    export MOCK_LOG="$TEST_TMPDIR/tmux_calls.log"
    export MOCK_FAILED_LOG="$TEST_TMPDIR/tmux_failed.log"
    export MOCK_PANE_FILE="$TEST_TMPDIR/pane_screen"
    export MOCK_PANE_AFTER_NEW_FILE="$TEST_TMPDIR/pane_screen_after_new"
    export MOCK_PANE_CLI_FILE="$TEST_TMPDIR/pane_cli"
    export MOCK_FAIL_ON_FILE="$TEST_TMPDIR/fail_on"
    export SCENARIO_FILE="$TEST_TMPDIR/scenario.sh"
    export HARNESS="$TEST_TMPDIR/harness.sh"
    : > "$MOCK_LOG"
    : > "$MOCK_FAILED_LOG"

    # 画面見本。agent_is_busy_check(lib/agent_status.sh)が実際に使う判定語に合わせる。
    export CODEX_IDLE="$(printf '› \n  ? for shortcuts   100%% context left\n')"
    export CODEX_BUSY="$(printf '• Working (12s • esc to interrupt)\n')"
    export OPENCODE_IDLE="$(printf 'Ask anything\n  tab agents   ctrl+p commands\n')"
    export OPENCODE_BUSY="$(printf '■■■■■■■■  working\n  esc interrupt\n')"

    cat > "$HARNESS" <<'HARNESS_EOF'
#!/bin/bash
AGENT_ID="${TEST_AGENT_ID:-test_agent}"
PANE_TARGET="test:0.0"
CLI_TYPE="${TEST_CLI_TYPE:-codex}"
INBOX="$TEST_INBOX"
LOCKFILE="${INBOX}.lock"
SCRIPT_DIR="$PROJECT_ROOT"
IDLE_FLAG_DIR="$TEST_TMPDIR/idle_flags"
METRICS_FILE="$TEST_TMPDIR/metrics.yaml"
export IDLE_FLAG_DIR METRICS_FILE

# 失敗注入: MOCK_FAIL_ON_FILE の内容と send-keys の最終引数が一致したら失敗(非0)を返す。
tmux() {
    case "$*" in
        *send-keys*)
            if [ -f "$MOCK_FAIL_ON_FILE" ] && [ "${@: -1}" = "$(cat "$MOCK_FAIL_ON_FILE")" ]; then
                echo "tmux FAIL $*" >> "$MOCK_FAILED_LOG"
                return 1
            fi
            echo "tmux $*" >> "$MOCK_LOG"
            return 0
            ;;
    esac
    echo "tmux $*" >> "$MOCK_LOG"
    case "$*" in
        *show-options*)
            cat "$MOCK_PANE_CLI_FILE" 2>/dev/null
            return 0
            ;;
        *capture-pane*)
            # 「/new が受け付けられた後に画面が変わる」状況の再現(起動時busy)。
            if [ -f "$MOCK_PANE_AFTER_NEW_FILE" ] \
                && /usr/bin/grep -qE 'send-keys -t [^ ]+ /new$' "$MOCK_LOG"; then
                cat "$MOCK_PANE_AFTER_NEW_FILE"
            else
                cat "$MOCK_PANE_FILE" 2>/dev/null
            fi
            return 0
            ;;
    esac
    return 0
}
timeout() { shift; "$@"; }
sleep() { :; }
pgrep() { return 1; }
export -f tmux timeout sleep pgrep

export __INBOX_WATCHER_TESTING__=1
source "${TEST_WATCHER_SCRIPT:-$WATCHER_SCRIPT}"
PERMISSION_REQUESTS_DIR="$TEST_TMPDIR/permission_requests"
HARNESS_EOF
}

teardown() {
    # ★killは使わない。隔離tmuxを作った試験だけ、helperのteardown(exit送信+自然終了待ち)を呼ぶ。
    # 一時領域(BATS_TEST_TMPDIR)の後始末は bats に任せる。
    if [ -n "${TEST_HANDLE:-}" ] && [ -f "$TEST_HANDLE" ]; then
        bash "$ISOLATED_TMUX_HELPER" teardown "$TEST_HANDLE" >/dev/null 2>&1 || true
    fi
    return 0
}

# ─── 補助関数(export -f して scenario の子bashからも使う) ───

keys_new_count()     { /usr/bin/grep -cE 'send-keys -t [^ ]+ /new$' "$MOCK_LOG" || true; }
keys_clear_count()   { /usr/bin/grep -cE 'send-keys -t [^ ]+ /clear$' "$MOCK_LOG" || true; }
keys_total_count()   { /usr/bin/grep -c 'send-keys' "$MOCK_LOG" || true; }
keys_startup_count() { /usr/bin/grep -c 'Session Start' "$MOCK_LOG" || true; }
# 「入力欄クリア(C-u)」以外の打鍵数。未読0・idle のとき既存の else 枝が C-u を1つ送る
# (従来挙動・cmd_792②の対象外)ので、「コマンドを打っていない」の判定はこちらで行う。
keys_noncu_count()   { /usr/bin/grep 'send-keys' "$MOCK_LOG" | /usr/bin/grep -vcE ' C-u$' || true; }

read_flag() {
    "$VENV_PYTHON" -c "
import sys, yaml
d = yaml.safe_load(open('$TEST_INBOX'))
m = [x for x in d['messages'] if x['id'] == sys.argv[1]]
print(m[0]['read'] if m else 'ABSENT')
" "$1"
}

count_recovery() {
    "$VENV_PYTHON" -c "
import yaml
d = yaml.safe_load(open('$TEST_INBOX'))
print(sum(1 for m in d['messages'] if m.get('from') == 'inbox_watcher' and '[auto-recovery]' in (m.get('content') or '')))
"
}

export -f keys_new_count keys_clear_count keys_total_count keys_startup_count keys_noncu_count read_flag count_recovery

msg_yaml() {
    # msg_yaml <id> <type> [content]
    cat <<YAML
  - id: $1
    from: karo
    timestamp: "2026-10-01T10:00:00+09:00"
    type: $2
    content: "${3:-タスクYAMLを読んで作業開始せよ。}"
    read: false
YAML
}

write_inbox() {
    # write_inbox <id:type> ...
    {
        echo "messages:"
        local spec
        for spec in "$@"; do
            msg_yaml "${spec%%:*}" "${spec#*:}"
        done
    } > "$TEST_INBOX"
}

set_screen()           { printf '%s\n' "$1" > "$MOCK_PANE_FILE"; }
set_screen_after_new() { printf '%s\n' "$1" > "$MOCK_PANE_AFTER_NEW_FILE"; }
set_pane_cli()         { printf '%s\n' "$1" > "$MOCK_PANE_CLI_FILE"; }
fail_on()              { printf '%s' "$1" > "$MOCK_FAIL_ON_FILE"; }
export -f set_screen set_screen_after_new set_pane_cli fail_on

# scenario(stdin)を、harness を source した本番同等の strict shell で実行する。
run_scenario() {
    cat > "$SCENARIO_FILE"
    run bash -c 'source "$1"; set -euo pipefail; source "$2"' _ "$HARNESS" "$SCENARIO_FILE"
    # 調査用: CCB_DEBUG=1 で scenario の出力(stderrログ込み)を端末へ流す。
    if [ -n "${CCB_DEBUG:-}" ]; then
        echo "── scenario status=$status ──" >&3
        echo "$output" >&3
    fi
}

# ═══════════════════════════════════════════════════════════════
# 行1: codex/opencode・clearのみ・busy 連続2周期以上
# ═══════════════════════════════════════════════════════════════

@test "T-CCB-001: codex busy が連続3周期でも打鍵0・同IDread:false・理由ログ・auto-recovery0・reset状態を失わない" {
    write_inbox msg_clear_A:clear_command
    set_screen "$CODEX_BUSY"

    run_scenario <<'SCEN'
FIRST_UNREAD_SEEN=12345
process_unread event
process_unread timeout
process_unread event
echo "RESULT KEYS=$(keys_total_count) FUS=$FIRST_UNREAD_SEEN NCS=$NEW_CONTEXT_SENT PEND=[${PENDING_STARTUP_CLEAR_ID:-}]"
SCEN
    [ "$status" -eq 0 ]
    echo "$output" | /usr/bin/grep -q 'RESULT KEYS=0 FUS=12345 NCS=0 PEND=\[\]'
    [ "$(keys_total_count)" -eq 0 ]
    [ "$(read_flag msg_clear_A)" = "False" ]
    [ "$(count_recovery)" -eq 0 ]
    # 3周期とも理由ログ(id/CLI/理由)が出ている
    [ "$(echo "$output" | /usr/bin/grep -c 'CLEAR-HOLD.*id=msg_clear_A cli=codex reason=agent_busy')" -eq 3 ]
}

@test "T-CCB-002: opencode busy が連続3周期でも打鍵0・同IDread:false・理由ログ・auto-recovery0・reset状態を失わない" {
    write_inbox msg_clear_A:clear_command
    set_screen "$OPENCODE_BUSY"

    TEST_CLI_TYPE=opencode run_scenario <<'SCEN'
FIRST_UNREAD_SEEN=12345
process_unread event
process_unread timeout
process_unread event
echo "RESULT KEYS=$(keys_total_count) FUS=$FIRST_UNREAD_SEEN NCS=$NEW_CONTEXT_SENT"
SCEN
    [ "$status" -eq 0 ]
    echo "$output" | /usr/bin/grep -q 'RESULT KEYS=0 FUS=12345 NCS=0'
    [ "$(keys_total_count)" -eq 0 ]
    [ "$(read_flag msg_clear_A)" = "False" ]
    [ "$(count_recovery)" -eq 0 ]
    [ "$(echo "$output" | /usr/bin/grep -c 'CLEAR-HOLD.*id=msg_clear_A cli=opencode reason=agent_busy')" -eq 3 ]
}

# ═══════════════════════════════════════════════════════════════
# 行2: busy → idle の次周期で /new が1回・以後 reset 反復0
# ═══════════════════════════════════════════════════════════════

@test "T-CCB-003: codex busy→idle で /new が1回・read:true・起動プロンプト1回・auto-recovery1。以後の周期で反復0" {
    write_inbox msg_clear_A:clear_command
    set_screen "$CODEX_BUSY"

    run_scenario <<'SCEN'
process_unread event
process_unread event
echo "BUSY_PHASE KEYS=$(keys_total_count) READ=$(read_flag msg_clear_A)"
set_screen "$CODEX_IDLE"
process_unread event
echo "IDLE_PHASE NEW=$(keys_new_count) STARTUP=$(keys_startup_count) READ=$(read_flag msg_clear_A) REC=$(count_recovery) NCS=$NEW_CONTEXT_SENT"
process_unread event
process_unread timeout
echo "AFTER_PHASE NEW=$(keys_new_count) STARTUP=$(keys_startup_count) REC=$(count_recovery)"
SCEN
    [ "$status" -eq 0 ]
    echo "$output" | /usr/bin/grep -q 'BUSY_PHASE KEYS=0 READ=False'
    echo "$output" | /usr/bin/grep -q 'IDLE_PHASE NEW=1 STARTUP=1 READ=True REC=1 NCS=1'
    echo "$output" | /usr/bin/grep -q 'AFTER_PHASE NEW=1 STARTUP=1 REC=1'
}

@test "T-CCB-004: opencode busy→idle で /new が1回・read:true・auto-recovery1・起動プロンプトは追加されない。以後の周期で反復0" {
    write_inbox msg_clear_A:clear_command
    set_screen "$OPENCODE_BUSY"

    TEST_CLI_TYPE=opencode run_scenario <<'SCEN'
process_unread event
process_unread event
echo "BUSY_PHASE KEYS=$(keys_total_count) READ=$(read_flag msg_clear_A)"
set_screen "$OPENCODE_IDLE"
process_unread event
echo "IDLE_PHASE NEW=$(keys_new_count) STARTUP=$(keys_startup_count) READ=$(read_flag msg_clear_A) REC=$(count_recovery)"
process_unread event
process_unread timeout
echo "AFTER_PHASE NEW=$(keys_new_count) STARTUP=$(keys_startup_count) REC=$(count_recovery)"
SCEN
    [ "$status" -eq 0 ]
    echo "$output" | /usr/bin/grep -q 'BUSY_PHASE KEYS=0 READ=False'
    # OpenCodeにstartup送信は追加しない(agent定義は --agent で自動読込される)
    echo "$output" | /usr/bin/grep -q 'IDLE_PHASE NEW=1 STARTUP=0 READ=True REC=1'
    echo "$output" | /usr/bin/grep -q 'AFTER_PHASE NEW=1 STARTUP=0 REC=1'
}

# ═══════════════════════════════════════════════════════════════
# 行3: Codex — reset直前idle → startup時busy → 次周期idle
# ═══════════════════════════════════════════════════════════════

@test "T-CCB-005: codex /new 後の startup が busy なら強行せず同IDを保持し、次周期は /new を再送せず startup のみ送る" {
    write_inbox msg_clear_A:clear_command
    set_screen "$CODEX_IDLE"
    set_screen_after_new "$CODEX_BUSY"

    run_scenario <<'SCEN'
process_unread event
echo "CYCLE1 NEW=$(keys_new_count) STARTUP=$(keys_startup_count) READ=$(read_flag msg_clear_A) REC=$(count_recovery) NCS=$NEW_CONTEXT_SENT PEND=[$PENDING_STARTUP_CLEAR_ID]"
process_unread event
process_unread timeout
echo "CYCLE3 NEW=$(keys_new_count) STARTUP=$(keys_startup_count) READ=$(read_flag msg_clear_A) NCS=$NEW_CONTEXT_SENT PEND=[$PENDING_STARTUP_CLEAR_ID]"
rm -f "$MOCK_PANE_AFTER_NEW_FILE"
set_screen "$CODEX_IDLE"
process_unread event
echo "CYCLE4 NEW=$(keys_new_count) STARTUP=$(keys_startup_count) READ=$(read_flag msg_clear_A) REC=$(count_recovery) PEND=[$PENDING_STARTUP_CLEAR_ID]"
process_unread event
process_unread timeout
echo "CYCLE6 NEW=$(keys_new_count) STARTUP=$(keys_startup_count) REC=$(count_recovery)"
SCEN
    [ "$status" -eq 0 ]
    # 周期1: /new は1回送った。startup は busy ゆえ0。未読保持・保留ID保持・auto-recovery0・NCS=1維持
    echo "$output" | /usr/bin/grep -q 'CYCLE1 NEW=1 STARTUP=0 READ=False REC=0 NCS=1 PEND=\[msg_clear_A\]'
    # 周期2〜3(まだbusy): /new も startup も増えない。保留ID・NCSは失われない
    echo "$output" | /usr/bin/grep -q 'CYCLE3 NEW=1 STARTUP=0 READ=False NCS=1 PEND=\[msg_clear_A\]'
    # 周期4(idle): /new は再送されず(1のまま)、startup だけが1回。既読化・保留解除・auto-recovery1
    echo "$output" | /usr/bin/grep -q 'CYCLE4 NEW=1 STARTUP=1 READ=True REC=1 PEND=\[\]'
    # 以後の周期でも反復0
    echo "$output" | /usr/bin/grep -q 'CYCLE6 NEW=1 STARTUP=1 REC=1'
    # 強行しない旨・次巡回で startup のみ再判定する旨がログに残る
    echo "$output" | /usr/bin/grep -q 'startup prompt NOT forced'
    echo "$output" | /usr/bin/grep -q 'reason=agent_busy_startup_deferred'
}

# ═══════════════════════════════════════════════════════════════
# 行4: 内側guard の busy/permission 保留・tmux送信失敗
# ═══════════════════════════════════════════════════════════════

@test "T-CCB-006: permission_request 未決の間は打鍵0・未読保持。hook_result が書かれたら /new が1回だけ送られる" {
    write_inbox msg_clear_A:clear_command
    set_screen "$CODEX_IDLE"
    cat > "$TEST_TMPDIR/permission_requests/test_agent_20261001T000000Z_deadbeef.yaml" <<YAML
agent_id: "test_agent"
tool_name: "Bash"
received_at: '$(date -u +%Y-%m-%dT%H:%M:%SZ)'
YAML

    run_scenario <<'SCEN'
process_unread event
process_unread timeout
echo "PENDING_PHASE KEYS=$(keys_total_count) READ=$(read_flag msg_clear_A) REC=$(count_recovery)"
echo "hook_result: allow" >> "$TEST_TMPDIR/permission_requests/test_agent_20261001T000000Z_deadbeef.yaml"
process_unread event
echo "RESOLVED_PHASE NEW=$(keys_new_count) READ=$(read_flag msg_clear_A) REC=$(count_recovery)"
SCEN
    [ "$status" -eq 0 ]
    echo "$output" | /usr/bin/grep -q 'PENDING_PHASE KEYS=0 READ=False REC=0'
    echo "$output" | /usr/bin/grep -q 'reason=permission_request_pending'
    echo "$output" | /usr/bin/grep -q 'RESOLVED_PHASE NEW=1 READ=True REC=1'
}

@test "T-CCB-007: 外側guardを通った後に内側guardがbusyを検出しても成功扱いにならず、既読化・auto-recoveryも起きない" {
    write_inbox msg_clear_A:clear_command
    set_screen "$CODEX_IDLE"

    # agent_is_busy を差し替える: 1回目(handle_held_clear_command の外側判定)は idle、
    # 2回目以降(send_cli_command の内側判定)は busy を返す = TOCTOU の窓を再現する。
    run_scenario <<'SCEN'
BUSY_CALLS_FILE="$TEST_TMPDIR/busy_calls"
echo 0 > "$BUSY_CALLS_FILE"
agent_is_busy() {
    local n
    n=$(( $(cat "$BUSY_CALLS_FILE") + 1 ))
    echo "$n" > "$BUSY_CALLS_FILE"
    [ "$n" -ge 2 ]
}
process_unread event
echo "RESULT KEYS=$(keys_total_count) READ=$(read_flag msg_clear_A) REC=$(count_recovery) NCS=$NEW_CONTEXT_SENT PEND=[$PENDING_STARTUP_CLEAR_ID]"
SCEN
    [ "$status" -eq 0 ]
    echo "$output" | /usr/bin/grep -q 'RESULT KEYS=0 READ=False REC=0 NCS=0 PEND=\[\]'
    echo "$output" | /usr/bin/grep -q 'Agent is busy — /clear deferred to next cycle'
    echo "$output" | /usr/bin/grep -q 'reason=not_sent_rc=1'
}

@test "T-CCB-008: codex の /new 本文の送信が失敗したら成功扱いにせず未読保持。復旧後の次周期で /new が1回送られる" {
    write_inbox msg_clear_A:clear_command
    set_screen "$CODEX_IDLE"
    fail_on "/new"

    run_scenario <<'SCEN'
process_unread event
echo "FAILED_PHASE NEW=$(keys_new_count) READ=$(read_flag msg_clear_A) REC=$(count_recovery) NCS=$NEW_CONTEXT_SENT STARTUP=$(keys_startup_count)"
rm -f "$MOCK_FAIL_ON_FILE"
process_unread event
echo "RECOVERED_PHASE NEW=$(keys_new_count) READ=$(read_flag msg_clear_A) REC=$(count_recovery)"
SCEN
    [ "$status" -eq 0 ]
    # 失敗周期: 受け付けられた /new は0(失敗した呼出しは失敗ログへ)。Enter も送られていない
    echo "$output" | /usr/bin/grep -q 'FAILED_PHASE NEW=0 READ=False REC=0 NCS=0 STARTUP=0'
    echo "$output" | /usr/bin/grep -q "send-keys failed at '/new-text'"
    echo "$output" | /usr/bin/grep -q 'RECOVERED_PHASE NEW=1 READ=True REC=1'
    # 本文の送信に失敗した周期では Enter を送っていない
    [ "$(/usr/bin/grep -c ' Enter$' "$MOCK_LOG")" -eq 2 ]
}

@test "T-CCB-009: opencode の Enter 送信が失敗したら成功扱いにせず未読保持・NEW_CONTEXT_SENTも立てない。復旧後に完了する" {
    write_inbox msg_clear_A:clear_command
    set_screen "$OPENCODE_IDLE"
    fail_on "Enter"

    TEST_CLI_TYPE=opencode run_scenario <<'SCEN'
process_unread event
echo "FAILED_PHASE READ=$(read_flag msg_clear_A) REC=$(count_recovery) NCS=$NEW_CONTEXT_SENT"
rm -f "$MOCK_FAIL_ON_FILE"
process_unread event
echo "RECOVERED_PHASE READ=$(read_flag msg_clear_A) REC=$(count_recovery) NCS=$NEW_CONTEXT_SENT"
SCEN
    [ "$status" -eq 0 ]
    echo "$output" | /usr/bin/grep -q 'FAILED_PHASE READ=False REC=0 NCS=0'
    echo "$output" | /usr/bin/grep -q "send-keys failed at '/new-enter'"
    echo "$output" | /usr/bin/grep -q 'RECOVERED_PHASE READ=True REC=1 NCS=1'
}

# ═══════════════════════════════════════════════════════════════
# 行5: 同batch・IDの再読 / 抽出後に別IDが追加
# ═══════════════════════════════════════════════════════════════

@test "T-CCB-010: 同じbatchに clear が2件あっても /new は1回。後続は重複として吸収し両方 read:true、auto-recoveryは1件" {
    write_inbox msg_clear_A:clear_command msg_clear_B:clear_command
    set_screen "$CODEX_IDLE"

    run_scenario <<'SCEN'
process_unread event
echo "CYCLE1 NEW=$(keys_new_count) STARTUP=$(keys_startup_count) A=$(read_flag msg_clear_A) B=$(read_flag msg_clear_B) REC=$(count_recovery)"
process_unread event
process_unread timeout
echo "CYCLE3 NEW=$(keys_new_count) STARTUP=$(keys_startup_count) REC=$(count_recovery)"
SCEN
    [ "$status" -eq 0 ]
    echo "$output" | /usr/bin/grep -q 'CYCLE1 NEW=1 STARTUP=1 A=True B=True REC=1'
    echo "$output" | /usr/bin/grep -q 'CYCLE3 NEW=1 STARTUP=1 REC=1'
    echo "$output" | /usr/bin/grep -q 'absorbing duplicate clear_command'
}

@test "T-CCB-011: 抽出後に追加された別IDの clear は既読化に巻き込まれない(完了したIDだけ read:true)" {
    write_inbox msg_clear_A:clear_command
    set_screen "$CODEX_IDLE"

    # send_cli_command を包み、送信の最中(= get_unread_info の抽出後)に別ID B を
    # inbox へ追記する。完了した A の既読化が B を巻き込まないことを確かめる。
    run_scenario <<'SCEN'
eval "$(declare -f send_cli_command | sed '1s/^send_cli_command/__orig_send_cli_command/')"
send_cli_command() {
    "$VENV_PYTHON" - <<'PY'
import os, yaml
p = os.environ["TEST_INBOX"]
d = yaml.safe_load(open(p))
d["messages"].append({"id": "msg_clear_B", "from": "karo", "type": "clear_command",
                      "content": "追加", "read": False, "timestamp": "2026-10-01T10:05:00+09:00"})
yaml.safe_dump(d, open(p, "w"), allow_unicode=True, sort_keys=False)
PY
    __orig_send_cli_command "$@"
}
process_unread event
echo "CYCLE1 NEW=$(keys_new_count) A=$(read_flag msg_clear_A) B=$(read_flag msg_clear_B)"
process_unread event
echo "CYCLE2 NEW=$(keys_new_count) STARTUP=$(keys_startup_count) A=$(read_flag msg_clear_A) B=$(read_flag msg_clear_B)"
SCEN
    [ "$status" -eq 0 ]
    # 周期1: A は完了して read:true。抽出後に追加された B は未読のまま
    echo "$output" | /usr/bin/grep -q 'CYCLE1 NEW=1 A=True B=False'
    # 周期2: B は同batchの重複として吸収(/new・startup は増えない)
    echo "$output" | /usr/bin/grep -q 'CYCLE2 NEW=1 STARTUP=1 A=True B=True'
}

# ═══════════════════════════════════════════════════════════════
# 行6: 実効CLIが引数CLIと異なる(pane優先の現行CLI解決で対象範囲を判定)
# ═══════════════════════════════════════════════════════════════

@test "T-CCB-012: 引数CLI=claude でも pane の @agent_cli=codex なら保持対象。引数CLI=codex でも pane=claude なら従来どおり抽出時に既読化" {
    # (a) 引数 claude / pane codex / busy → 保持される(対象)
    write_inbox msg_clear_A:clear_command
    set_screen "$CODEX_BUSY"
    set_pane_cli codex
    TEST_CLI_TYPE=claude run_scenario <<'SCEN'
process_unread event
echo "PANE_CODEX KEYS=$(keys_total_count) READ=$(read_flag msg_clear_A)"
SCEN
    [ "$status" -eq 0 ]
    echo "$output" | /usr/bin/grep -q 'PANE_CODEX KEYS=0 READ=False'
    echo "$output" | /usr/bin/grep -q 'CLEAR-HOLD.*cli=codex reason=agent_busy'

    # (b) 引数 codex / pane claude / busy(idleフラグ無し) → 対象外: 従来どおり抽出時に既読化
    write_inbox msg_clear_B:clear_command
    : > "$MOCK_LOG"
    rm -f "$TEST_TMPDIR/idle_flags/shogun_idle_test_agent"
    set_pane_cli claude
    TEST_CLI_TYPE=codex run_scenario <<'SCEN'
process_unread event
echo "PANE_CLAUDE NONCU=$(keys_noncu_count) READ=$(read_flag msg_clear_B)"
SCEN
    [ "$status" -eq 0 ]
    echo "$output" | /usr/bin/grep -q 'PANE_CLAUDE NONCU=0 READ=True'
    ! echo "$output" | /usr/bin/grep -q 'CLEAR-HOLD'
}

# ═══════════════════════════════════════════════════════════════
# 行7: 既存挙動が不変であること
# ═══════════════════════════════════════════════════════════════

@test "T-CCB-013: Claude の clear_command は従来どおり(抽出時に既読化・C-c+/clear+Enter・auto-recovery1)" {
    write_inbox msg_clear_A:clear_command
    touch "$TEST_TMPDIR/idle_flags/shogun_idle_test_agent"
    set_pane_cli claude

    TEST_CLI_TYPE=claude run_scenario <<'SCEN'
process_unread event
echo "RESULT CLEAR=$(keys_clear_count) NEW=$(keys_new_count) READ=$(read_flag msg_clear_A) REC=$(count_recovery)"
SCEN
    [ "$status" -eq 0 ]
    echo "$output" | /usr/bin/grep -q 'RESULT CLEAR=1 NEW=0 READ=True REC=1'
    /usr/bin/grep -q 'send-keys -t test:0.0 C-c' "$MOCK_LOG"
    # hold 経路(CLEAR-HOLD / CLEAR-ACK)は通らない
    ! echo "$output" | /usr/bin/grep -q 'CLEAR-HOLD'
    ! echo "$output" | /usr/bin/grep -q 'CLEAR-ACK'
}

@test "T-CCB-014: Claude が busy のとき clear_command は従来どおり抽出時に既読化され、コマンド打鍵は出ない(hold対象外)" {
    write_inbox msg_clear_A:clear_command
    rm -f "$TEST_TMPDIR/idle_flags/shogun_idle_test_agent"
    set_pane_cli claude

    TEST_CLI_TYPE=claude run_scenario <<'SCEN'
process_unread event
echo "RESULT NONCU=$(keys_noncu_count) READ=$(read_flag msg_clear_A) REC=$(count_recovery)"
SCEN
    [ "$status" -eq 0 ]
    echo "$output" | /usr/bin/grep -q 'RESULT NONCU=0 READ=True REC=0'
    echo "$output" | /usr/bin/grep -q 'clear_command) deferred to next cycle'
    ! echo "$output" | /usr/bin/grep -q 'CLEAR-HOLD'
}

@test "T-CCB-015: codex でも model_switch は従来どおり抽出時に既読化、cli_restart は未読のまま。両者ともコマンド打鍵なし" {
    write_inbox msg_model:model_switch msg_restart:cli_restart
    "$VENV_PYTHON" - <<PY
import yaml
p = "$TEST_INBOX"
d = yaml.safe_load(open(p))
for m in d["messages"]:
    if m["id"] == "msg_model":
        m["content"] = "/model opus"
yaml.safe_dump(d, open(p, "w"), allow_unicode=True, sort_keys=False)
PY
    set_screen "$CODEX_IDLE"

    run_scenario <<'SCEN'
process_unread event
echo "RESULT NONCU=$(keys_noncu_count) MODEL=$(read_flag msg_model) RESTART=$(read_flag msg_restart) REC=$(count_recovery)"
SCEN
    [ "$status" -eq 0 ]
    echo "$output" | /usr/bin/grep -q 'RESULT NONCU=0 MODEL=True RESTART=False REC=0'
    echo "$output" | /usr/bin/grep -q 'Skipping /model opus (not supported on codex)'
    echo "$output" | /usr/bin/grep -q 'CLI-RESTART-HUMAN-PATH'
}

@test "T-CCB-016: clearなしの task_assigned は従来どおり。足軽(codex)は /new+startup、軍師(codex)は reset を抑止する" {
    # 足軽相当(test_agent): send_context_reset が /new と startup を送る
    write_inbox msg_task:task_assigned
    set_screen "$CODEX_IDLE"
    run_scenario <<'SCEN'
process_unread event
echo "ASHIGARU NEW=$(keys_new_count) STARTUP=$(keys_startup_count) READ=$(read_flag msg_task)"
SCEN
    [ "$status" -eq 0 ]
    echo "$output" | /usr/bin/grep -q 'ASHIGARU NEW=1 STARTUP=1 READ=False'
    ! echo "$output" | /usr/bin/grep -q 'CLEAR-HOLD'

    # 軍師: task_assigned だけでは reset しない(command-layer agent)
    write_inbox msg_task:task_assigned
    : > "$MOCK_LOG"
    TEST_AGENT_ID=gunshi run_scenario <<'SCEN'
process_unread event
echo "GUNSHI NEW=$(keys_new_count) STARTUP=$(keys_startup_count)"
SCEN
    [ "$status" -eq 0 ]
    echo "$output" | /usr/bin/grep -q 'GUNSHI NEW=0 STARTUP=0'
    echo "$output" | /usr/bin/grep -q 'suppressing context reset (command-layer agent)'
}

@test "T-CCB-017: 足軽の4分エスカレーションは従来どおり(Claude・未読が4分超なら /clear を送る)" {
    write_inbox msg_report:report_received
    touch "$TEST_TMPDIR/idle_flags/shogun_idle_test_agent"
    set_pane_cli claude

    TEST_CLI_TYPE=claude run_scenario <<'SCEN'
FIRST_UNREAD_SEEN=$(( $(date +%s) - 300 ))
LAST_CLEAR_TS=0
process_unread event
echo "RESULT CLEAR=$(keys_clear_count) NEW=$(keys_new_count)"
SCEN
    [ "$status" -eq 0 ]
    echo "$output" | /usr/bin/grep -q 'ESCALATION Phase 3'
    echo "$output" | /usr/bin/grep -q 'RESULT CLEAR=1 NEW=0'
    ! echo "$output" | /usr/bin/grep -q 'CLEAR-HOLD'
}

# ═══════════════════════════════════════════════════════════════
# 補助
# ═══════════════════════════════════════════════════════════════

@test "T-CCB-018: shogun は codex 設定でも hold 対象外 — 従来どおり抽出時に既読化し、コマンドを一切打鍵しない" {
    write_inbox msg_clear_A:clear_command
    set_screen "$CODEX_IDLE"

    TEST_AGENT_ID=shogun run_scenario <<'SCEN'
process_unread event
echo "RESULT NONCU=$(keys_noncu_count) READ=$(read_flag msg_clear_A) REC=$(count_recovery)"
SCEN
    [ "$status" -eq 0 ]
    echo "$output" | /usr/bin/grep -q 'RESULT NONCU=0 READ=True REC=0'
    echo "$output" | /usr/bin/grep -q 'shogun: suppressing CLI command injection'
    ! echo "$output" | /usr/bin/grep -q 'CLEAR-HOLD'
}

@test "T-CCB-019: send_startup_prompt — strict は15秒待った末も busy なら強行せず非0。引数なしは従来どおり強行して0" {
    write_inbox msg_unused:report_received
    set_screen "$CODEX_BUSY"

    run_scenario <<'SCEN'
rc=0
send_startup_prompt strict || rc=$?
echo "STRICT RC=$rc KEYS=$(keys_total_count) STARTUP=$(keys_startup_count) SENT=$STARTUP_PROMPT_SENT"
rc=0
send_startup_prompt || rc=$?
echo "DEFAULT RC=$rc STARTUP=$(keys_startup_count) SENT=$STARTUP_PROMPT_SENT"
SCEN
    [ "$status" -eq 0 ]
    echo "$output" | /usr/bin/grep -q 'STRICT RC=1 KEYS=0 STARTUP=0 SENT=0'
    echo "$output" | /usr/bin/grep -q 'DEFAULT RC=0 STARTUP=1 SENT=1'
    echo "$output" | /usr/bin/grep -q 'proceeding with startup prompt anyway'
}

@test "T-CCB-020: 保留中IDが外部で既読化されたら保留を捨てる(後続の別IDを永久に塞がない)。get_unread_info失敗周期では捨てない" {
    write_inbox msg_clear_A:clear_command
    set_screen "$CODEX_IDLE"
    set_screen_after_new "$CODEX_BUSY"

    run_scenario <<'SCEN'
process_unread event
echo "PENDING_SET PEND=[$PENDING_STARTUP_CLEAR_ID]"

# get_unread_info が失敗(空specials)した周期は「既読になった」と誤認しない
eval "$(declare -f get_unread_info | sed '1s/^get_unread_info/__orig_get_unread_info/')"
get_unread_info() { echo '{"count": 0, "specials": []}'; }
process_unread event
echo "AFTER_FAILED_READ PEND=[$PENDING_STARTUP_CLEAR_ID]"
eval "$(declare -f __orig_get_unread_info | sed '1s/^__orig_get_unread_info/get_unread_info/')"

# 外部(エージェント自身など)が msg_clear_A を既読化した
"$VENV_PYTHON" - <<'PY'
import os, yaml
p = os.environ["TEST_INBOX"]
d = yaml.safe_load(open(p))
for m in d["messages"]:
    if m["id"] == "msg_clear_A":
        m["read"] = True
yaml.safe_dump(d, open(p, "w"), allow_unicode=True, sort_keys=False)
PY
KEYS_BEFORE=$(keys_total_count)
process_unread event
echo "AFTER_EXTERNAL_READ PEND=[$PENDING_STARTUP_CLEAR_ID] NEWKEYS=$(( $(keys_total_count) - KEYS_BEFORE ))"
SCEN
    [ "$status" -eq 0 ]
    echo "$output" | /usr/bin/grep -q 'PENDING_SET PEND=\[msg_clear_A\]'
    echo "$output" | /usr/bin/grep -q 'AFTER_FAILED_READ PEND=\[msg_clear_A\]'
    echo "$output" | /usr/bin/grep -q 'AFTER_EXTERNAL_READ PEND=\[\] NEWKEYS='
    echo "$output" | /usr/bin/grep -q 'is no longer unread — dropping pending state'
}

@test "T-CCB-021: mark_clear_command_read — 対象IDだけを既読化し、type不一致・欠落・id無しでは何も変えない。ロック不可なら未読のまま" {
    write_inbox msg_clear_A:clear_command msg_clear_B:clear_command msg_task:task_assigned

    run_scenario <<'SCEN'
mark_clear_command_read msg_clear_A
echo "ACK_A RC=$? A=$(read_flag msg_clear_A) B=$(read_flag msg_clear_B) TASK=$(read_flag msg_task)"

rc=0; mark_clear_command_read msg_clear_A || rc=$?
echo "ALREADY RC=$rc"

rc=0; mark_clear_command_read msg_task || rc=$?
echo "MISMATCH RC=$rc TASK=$(read_flag msg_task)"

rc=0; mark_clear_command_read msg_absent || rc=$?
echo "MISSING RC=$rc"

rc=0; mark_clear_command_read "" || rc=$?
echo "NOID RC=$rc B=$(read_flag msg_clear_B)"

# 他者が共有inbox lockを保持中: 既読化できず、未読のまま残る
mkdir "${LOCKFILE}.d"
rc=0; mark_clear_command_read msg_clear_B || rc=$?
echo "LOCKED RC=$rc B=$(read_flag msg_clear_B)"
SCEN
    [ "$status" -eq 0 ]
    echo "$output" | /usr/bin/grep -q 'ACK_A RC=0 A=True B=False TASK=False'
    echo "$output" | /usr/bin/grep -q 'ALREADY RC=0'
    echo "$output" | /usr/bin/grep -q 'MISMATCH RC=1 TASK=False'
    echo "$output" | /usr/bin/grep -q 'MISSING RC=0'
    echo "$output" | /usr/bin/grep -q 'NOID RC=1 B=False'
    echo "$output" | /usr/bin/grep -q 'LOCKED RC=1 B=False'
    echo "$output" | /usr/bin/grep -q 'result=LOCK_FAILED'
}

@test "T-CCB-022: 新設関数は fixture の INBOX/LOCKFILE だけを使い、本番 queue/inbox を直接指さない(静的検査)" {
    local fn body
    for fn in get_unread_info mark_clear_command_read handle_held_clear_command; do
        body="$(awk "/^${fn}\\(\\) \\{/,/^}/" "$WATCHER_SCRIPT")"
        [ -n "$body" ]
        # 本番inboxパスの直書きが無い
        ! echo "$body" | /usr/bin/grep -qE 'queue/inbox|shogun/queue'
    done
    # 既読化helperは fixture 変数を経由し、共有inbox lock を取り、原子的replaceで書く
    body="$(awk '/^mark_clear_command_read\(\) \{/,/^}/' "$WATCHER_SCRIPT")"
    echo "$body" | /usr/bin/grep -q 'INBOX_PATH="\$INBOX"'
    echo "$body" | /usr/bin/grep -q 'acquire_inbox_lock'
    echo "$body" | /usr/bin/grep -q 'release_inbox_lock'
    echo "$body" | /usr/bin/grep -q 'os.replace'
    echo "$body" | /usr/bin/grep -q 'target.get("type") != "clear_command"'
}

@test "T-CCB-023: startup の送信が失敗したら strict は成功扱いにしない(STARTUP_PROMPT_SENT を立てず非0)" {
    write_inbox msg_unused:report_received
    set_screen "$CODEX_IDLE"
    fail_on "Enter"

    run_scenario <<'SCEN'
rc=0
send_startup_prompt strict || rc=$?
echo "STRICT_FAIL RC=$rc SENT=$STARTUP_PROMPT_SENT"
SCEN
    [ "$status" -eq 0 ]
    echo "$output" | /usr/bin/grep -q 'STRICT_FAIL RC=1 SENT=0'
    echo "$output" | /usr/bin/grep -q "send-keys failed at 'startup-enter'"
}

# ═══════════════════════════════════════════════════════════════
# 隔離tmux実機(scripts/isolated_tmux.sh の create/teardown のみ使用)
#   ★watcherへ渡す tmux は PATH 上の shim 経由で常に専用socketへ束縛する。
#   既定socketや稼働中の multiagent/shogun セッションには解決され得ない。
#   pane は自作の素のbash(PS1空)で、busy/idle は表示の出力だけで用意する
#   (稼働agent CLIには状態を演じさせない)。後始末は teardown が素shellへ
#   exit を入力して閉じる。kill系・使い捨ての再帰削除は使わない。
# ═══════════════════════════════════════════════════════════════

@test "T-CCB-024: 隔離tmux実機 — busy な codex 風 pane には打鍵が1つも届かず、idle にすると /new が1回だけ届く" {
    local sock="ccb024_${BATS_TEST_NUMBER}_$$_${RANDOM}"
    TEST_HANDLE="$(bash "$ISOLATED_TMUX_HELPER" create -L "$sock")"
    [ -f "$TEST_HANDLE" ]
    local sock_path pane_id
    sock_path="$(/usr/bin/grep -E '^SOCKET_PATH=' "$TEST_HANDLE" | cut -d= -f2-)"
    pane_id="$(/usr/bin/grep -E '^PANE_ID=' "$TEST_HANDLE" | cut -d= -f2-)"
    [ -n "$sock_path" ] && [ -n "$pane_id" ]

    local shim_dir real_tmux
    shim_dir="$(mktemp -d "${TEST_TMPDIR}/shim.XXXXXX")"
    real_tmux="$(command -v tmux)"
    cat > "$shim_dir/tmux" <<SHIM
#!/usr/bin/env bash
exec "$real_tmux" -S "$sock_path" "\$@"
SHIM
    chmod +x "$shim_dir/tmux"

    # 実paneの表示を用意する(busy: 状態語を含む最終行)。PS1を空にして余計な行を出さない。
    "$real_tmux" -S "$sock_path" send-keys -t "$pane_id" "PS1=''; clear; printf 'Working (3s • esc to interrupt)\\n'" Enter
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        "$real_tmux" -S "$sock_path" capture-pane -t "$pane_id" -p | /usr/bin/grep -q 'esc to interrupt' && break
        command sleep 0.2
    done
    "$real_tmux" -S "$sock_path" capture-pane -t "$pane_id" -p | /usr/bin/grep -q 'esc to interrupt'

    write_inbox msg_clear_A:clear_command

    # 実tmuxへ向ける harness: tmux/timeout は差し替えず PATH の shim を使う。sleep は短縮のみ。
    local real_harness="$TEST_TMPDIR/harness_real.sh"
    cat > "$real_harness" <<'REAL_EOF'
#!/bin/bash
AGENT_ID="test_agent"
PANE_TARGET="$ISO_PANE_ID"
CLI_TYPE="codex"
INBOX="$TEST_INBOX"
LOCKFILE="${INBOX}.lock"
SCRIPT_DIR="$PROJECT_ROOT"
IDLE_FLAG_DIR="$TEST_TMPDIR/idle_flags"
METRICS_FILE="$TEST_TMPDIR/metrics.yaml"
export IDLE_FLAG_DIR METRICS_FILE
pgrep() { return 1; }
export __INBOX_WATCHER_TESTING__=1
source "$WATCHER_SCRIPT"
PERMISSION_REQUESTS_DIR="$TEST_TMPDIR/permission_requests"
sleep() { command sleep 0.2; }
REAL_EOF

    cat > "$SCENARIO_FILE" <<'SCEN'
process_unread event
process_unread timeout
echo "BUSY_PHASE READ=$(read_flag msg_clear_A) REC=$(count_recovery)"
SCEN
    run env PATH="$shim_dir:$PATH" ISO_PANE_ID="$pane_id" \
        bash -c 'source "$1"; set -euo pipefail; source "$2"' _ "$real_harness" "$SCENARIO_FILE"
    [ "$status" -eq 0 ]
    echo "$output" | /usr/bin/grep -q 'BUSY_PHASE READ=False REC=0'
    echo "$output" | /usr/bin/grep -q 'reason=agent_busy'
    # busy の間は専用socketのpaneに何も届いていない
    run "$real_tmux" -S "$sock_path" capture-pane -t "$pane_id" -p
    [ "$status" -eq 0 ]
    [[ "$output" != *"/new"* ]]
    [[ "$output" != *"Session Start"* ]]

    # idle 表示へ切り替える(表示の出力だけ)
    "$real_tmux" -S "$sock_path" send-keys -t "$pane_id" "clear; printf '? for shortcuts\\n'" Enter
    for i in 1 2 3 4 5 6 7 8 9 10; do
        "$real_tmux" -S "$sock_path" capture-pane -t "$pane_id" -p | /usr/bin/grep -q 'for shortcuts' && break
        command sleep 0.2
    done

    cat > "$SCENARIO_FILE" <<'SCEN'
process_unread event
echo "IDLE_PHASE READ=$(read_flag msg_clear_A) REC=$(count_recovery) NCS=$NEW_CONTEXT_SENT"
SCEN
    run env PATH="$shim_dir:$PATH" ISO_PANE_ID="$pane_id" \
        bash -c 'source "$1"; set -euo pipefail; source "$2"' _ "$real_harness" "$SCENARIO_FILE"
    [ "$status" -eq 0 ]
    echo "$output" | /usr/bin/grep -q 'IDLE_PHASE READ=True REC=1 NCS=1'
    # 専用socketのpane上で /new が1回だけ実行された(素のbashは「No such file」を返す)
    run "$real_tmux" -S "$sock_path" capture-pane -t "$pane_id" -p -S -50
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | /usr/bin/grep -c '/new: No such file or directory')" -eq 1 ]
}
