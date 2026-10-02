#!/usr/bin/env bats
# test_hook_cwd_launch.bats — hook command の cwd 依存起動失敗の回帰試験
# (cmd_775 scope内・subtask_775_hook_cwd_fix・将軍裁定
# shogun_ruling_20260917_hook_cwd)
#
# ═══════════════════════════════════════════════════════════════
# 背景
# ═══════════════════════════════════════════════════════════════
# 2026-09-17、足軽3号がプロジェクト直下でない skill ディレクトリ
# `skills/<skill>/` 配下(cwdがプロジェクト直下でない状態)で作業中、
# 確認モーダルで長時間停止した。
# 将軍が特定した真因: `.claude/settings.json` の hook `command` が
# 相対パス(`bash scripts/<script>`)であり、Claude Code の hook は
# 「cwd follows Claude」(公式 hooks リファレンス原文)で実行される
# ため、cwd がプロジェクト直下でない agent では hook 起動そのものが
# `bash: scripts/<script>: No such file or directory` でサイレントに
# 失敗し(記録なし・家老通知なし)、素の確認モーダルへ落ちていた。
# 家老が `.claude/settings.json` の SessionStart/Stop/PermissionRequest
# 3 hook すべての `command` を `bash "${CLAUDE_PROJECT_DIR}/scripts/
# <script>"`(絶対パス)形式へ是正済み(本 task の前提・本ファイルは
# その是正の正しさを実測で示す)。
#
# ═══════════════════════════════════════════════════════════════
# ★なぜ隔離tmuxを使うか(設計判断の記録・批判的検討)
# ═══════════════════════════════════════════════════════════════
# 本欠陥の機序そのもの(`bash <相対path>` がcwd次第で見つからない/
# 見つかる)は、tmuxの有無に一切依存しない、純粋なbash/ファイル
# システムの一般的事実である——`cd <dir> && bash scripts/x.sh` は、
# それがtmux paneの中で動くbashであろうと、bats自身のsubshellで
# あろうと、byte一致の結果になる(tmuxは端末多重化を担うのみで、
# 起動されるhookサブプロセスのcwd解決に一切関与しない)。
#
# ★それでもなお本ファイルは `scripts/isolated_tmux.sh` で作る実際の
# 隔離tmux pane上で全試験を実行する。理由は2つ: (1) 本taskの発令文が
# 明示的に「隔離tmux...上で...起動し...検証すること」を指示しており、
# これは足軽3号の実際の事故環境(agentのBash toolが動く、tmux pane
# 上でホストされたシェル)への視覚的忠実性を狙ったものと解釈できる
# ため、その指示に文字どおり従う。(2) hookスクリプト自身が内部で
# `tmux display-message -t "$TMUX_PANE" -p '#{@agent_id}'` を呼んで
# agent_idを解決するくだり(session_start_hook.sh・stop_hook_inbox.sh・
# permission_request_hook.sh いずれも)を、test専用のenv var override
# (`__SESSION_START_HOOK_AGENT_ID`等)に頼らず「本物のtmux解決経路」で
# 検査できる副次効果があるため、単なるcwd検証を超えた実利がある。
#
# 隔離tmux pane はテスト対象コマンドを打鍵として`tmux send-keys`で
# 送り込み、完了を`tmux wait-for`(イベント駆動・固定sleepなし)で
# 待つ。稼働中のmultiagent/shogun本番tmuxソケットへは一切触れない
# (D006遵守・scripts/isolated_tmux.sh使用)。
#
# ═══════════════════════════════════════════════════════════════
# 試験構成(3 hook × {絶対パス化前の相対形式=失敗 / 絶対パス化後の
# 形式=成功} の対比。settings.json の実際の command 文字列をそのまま
# 使う——絶対パス側は `bash "${CLAUDE_PROJECT_DIR}/scripts/<script>"`
# であり、PermissionRequest の `PERMISSION_HOOK_TIMEOUT_SECONDS=1800`
# のみ試験時間短縮のため`1`に差し替える。cwd起動可否とは無関係な
# パラメータである)
# ═══════════════════════════════════════════════════════════════
#   T-HCWD-001: session_start_hook.sh   相対形式・非プロジェクト直下cwd → 起動失敗(rc=127・No such file)
#   T-HCWD-002: session_start_hook.sh   絶対形式・同cwd                → 正常起動(rc=0・出力・ログ)
#   T-HCWD-003: stop_hook_inbox.sh      相対形式・同cwd                → 起動失敗(rc=127・No such file)
#   T-HCWD-004: stop_hook_inbox.sh      絶対形式・同cwd                → 正常起動(rc=0・block JSON)
#   T-HCWD-005: permission_request_hook.sh 相対形式・同cwd             → 起動失敗(rc=127・記録ファイル0件)
#   T-HCWD-006: permission_request_hook.sh 絶対形式・同cwd             → 正常起動(記録ファイル1件・hook_result記録)

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
ISOLATED_TMUX="$SCRIPT_DIR/scripts/isolated_tmux.sh"
REAL_PROJECT_ROOT="$SCRIPT_DIR"

# ─── ファイル全体で1つの隔離tmux paneを使い回す(bats: setup_file/
#     teardown_fileは各testの本体とは別processで動くため、shell変数を
#     直接は共有できない。$BATS_FILE_TMPDIR上のfile経由で受け渡す) ───
setup_file() {
    local handle_file
    handle_file="$(bash "$ISOLATED_TMUX" create -L "hcwd$$")"
    [ -n "$handle_file" ]
    echo "$handle_file" > "$BATS_FILE_TMPDIR/handle_path"

    local socket_path pane_id
    socket_path="$(grep '^SOCKET_PATH=' "$handle_file" | cut -d= -f2-)"
    pane_id="$(grep '^PANE_ID=' "$handle_file" | cut -d= -f2-)"
    [ -n "$socket_path" ]
    [ -n "$pane_id" ]
    # 本物のtmux解決経路(hookが内部で呼ぶtmux display-message)が
    # 実際に働くよう、隔離pane自身に@agent_idを設定する。
    tmux -S "$socket_path" set-option -p -t "$pane_id" @agent_id "ashigaru_cwdtest"
}

teardown_file() {
    if [ -f "$BATS_FILE_TMPDIR/handle_path" ]; then
        local handle_file
        handle_file="$(cat "$BATS_FILE_TMPDIR/handle_path")"
        bash "$ISOLATED_TMUX" teardown "$handle_file" || true
    fi
}

setup() {
    local handle_file
    handle_file="$(cat "$BATS_FILE_TMPDIR/handle_path")"
    ISO_SOCKET_PATH="$(grep '^SOCKET_PATH=' "$handle_file" | cut -d= -f2-)"
    ISO_PANE_ID="$(grep '^PANE_ID=' "$handle_file" | cut -d= -f2-)"

    TEST_TMP="$(mktemp -d)"
    mkdir -p "$TEST_TMP/fakecwd"
    mkdir -p "$TEST_TMP/scripts"
    mkdir -p "$TEST_TMP/queue/inbox"
    mkdir -p "$TEST_TMP/queue/tasks"
    mkdir -p "$TEST_TMP/queue/state/permission_requests"
    mkdir -p "$TEST_TMP/queue/state/permission_decisions"
    ln -s "$SCRIPT_DIR/.venv" "$TEST_TMP/.venv"

    cat > "$TEST_TMP/scripts/inbox_write.sh" << 'MOCK'
#!/bin/bash
echo "$@" >> "$(dirname "$0")/../inbox_write_calls.log"
MOCK
    chmod +x "$TEST_TMP/scripts/inbox_write.sh"
}

teardown() {
    rm -rf "$TEST_TMP"
}

# run_in_pane <cmd>
#   隔離pane自身のbashへ<cmd>を打鍵として送り込み、完了を
#   `tmux wait-for`(イベント駆動)で待つ。RC/OUT/ERRへ結果を格納する。
#   <cmd>の中で使うpathは全て mktemp -d 由来かつ空白を含まない
#   ($TEST_TMP配下)ため、単純なsingle-quote embeddingで安全である。
run_in_pane() {
    local cmd="$1"
    local chan="hcwd_$$_${RANDOM}"
    local out_f="$TEST_TMP/pane_out" err_f="$TEST_TMP/pane_err" rc_f="$TEST_TMP/pane_rc"
    rm -f "$out_f" "$err_f" "$rc_f"

    local full="{ ${cmd} ; } >'${out_f}' 2>'${err_f}'; echo \$? >'${rc_f}'; tmux -S '${ISO_SOCKET_PATH}' wait-for -S '${chan}'"

    tmux -S "$ISO_SOCKET_PATH" send-keys -t "$ISO_PANE_ID" "$full" Enter
    if ! timeout 30 tmux -S "$ISO_SOCKET_PATH" wait-for "$chan"; then
        echo "run_in_pane: 完了通知(wait-for)がタイムアウトした" >&2
        return 1
    fi

    RC="$(cat "$rc_f" 2>/dev/null || echo -1)"
    OUT="$(cat "$out_f" 2>/dev/null || true)"
    ERR="$(cat "$err_f" 2>/dev/null || true)"
}

request_files() {
    find "$TEST_TMP/queue/state/permission_requests" -maxdepth 1 -name '*.yaml' -type f
}

# ═══════════════════════════════════════════════════════════════
# session_start_hook.sh
# ═══════════════════════════════════════════════════════════════

@test "T-HCWD-001: session_start_hook.sh (relative path, non-root cwd) fails to launch" {
    local invocation='bash scripts/session_start_hook.sh'
    local cmd="export CLAUDE_PROJECT_DIR='${REAL_PROJECT_ROOT}'; cd '${TEST_TMP}/fakecwd'; __SESSION_START_HOOK_LOG_DIR='${TEST_TMP}/logs_rel' ${invocation}"
    run_in_pane "$cmd"

    [ "$RC" -eq 127 ]
    [ -z "$OUT" ]
    [[ "$ERR" == *"scripts/session_start_hook.sh"* ]]
    [[ "$ERR" == *"No such file or directory"* ]]
    # 起動できていないため、スクリプト内部のログ書込みも一切発生しない
    [ ! -d "$TEST_TMP/logs_rel" ]
}

@test "T-HCWD-002: session_start_hook.sh (absolute \${CLAUDE_PROJECT_DIR} path, non-root cwd) launches correctly" {
    local invocation='bash "${CLAUDE_PROJECT_DIR}/scripts/session_start_hook.sh"'
    local cmd="export CLAUDE_PROJECT_DIR='${REAL_PROJECT_ROOT}'; cd '${TEST_TMP}/fakecwd'; __SESSION_START_HOOK_LOG_DIR='${TEST_TMP}/logs_abs' ${invocation}"
    run_in_pane "$cmd"

    [ "$RC" -eq 0 ]
    [[ "$OUT" == *"ashigaru_cwdtest"* ]]
    [[ "$OUT" == *"足軽用軽量手順"* ]]
    [ -z "$ERR" ]
    [ -f "$TEST_TMP/logs_abs/session_start_hook.log" ]
    grep -q "ashigaru_cwdtest session_start_hook fired" "$TEST_TMP/logs_abs/session_start_hook.log"
}

# ═══════════════════════════════════════════════════════════════
# stop_hook_inbox.sh
# ═══════════════════════════════════════════════════════════════

@test "T-HCWD-003: stop_hook_inbox.sh (relative path, non-root cwd) fails to launch" {
    cat > "$TEST_TMP/stdin_stop.json" << 'JSON'
{"stop_hook_active": false, "last_assistant_message": ""}
JSON

    local invocation='bash scripts/stop_hook_inbox.sh'
    local cmd="export CLAUDE_PROJECT_DIR='${REAL_PROJECT_ROOT}'; cd '${TEST_TMP}/fakecwd'; __STOP_HOOK_SCRIPT_DIR='${TEST_TMP}' IDLE_FLAG_DIR='${TEST_TMP}' ${invocation} < '${TEST_TMP}/stdin_stop.json'"
    run_in_pane "$cmd"

    [ "$RC" -eq 127 ]
    [ -z "$OUT" ]
    [[ "$ERR" == *"scripts/stop_hook_inbox.sh"* ]]
    [[ "$ERR" == *"No such file or directory"* ]]
}

@test "T-HCWD-004: stop_hook_inbox.sh (absolute \${CLAUDE_PROJECT_DIR} path, non-root cwd) launches correctly" {
    cat > "$TEST_TMP/queue/inbox/ashigaru_cwdtest.yaml" << 'YAML'
messages:
  - id: msg_001
    from: karo
    type: task_assigned
    content: "新タスクだ"
    read: false
YAML
    cat > "$TEST_TMP/stdin_stop.json" << 'JSON'
{"stop_hook_active": false, "last_assistant_message": ""}
JSON

    local invocation='bash "${CLAUDE_PROJECT_DIR}/scripts/stop_hook_inbox.sh"'
    local cmd="export CLAUDE_PROJECT_DIR='${REAL_PROJECT_ROOT}'; cd '${TEST_TMP}/fakecwd'; __STOP_HOOK_SCRIPT_DIR='${TEST_TMP}' IDLE_FLAG_DIR='${TEST_TMP}' ${invocation} < '${TEST_TMP}/stdin_stop.json'"
    run_in_pane "$cmd"

    [ "$RC" -eq 0 ]
    [[ "$OUT" == *'"decision"'* ]]
    [[ "$OUT" == *'"block"'* ]]
}

# ═══════════════════════════════════════════════════════════════
# permission_request_hook.sh
# ═══════════════════════════════════════════════════════════════

default_prh_json() {
    "$SCRIPT_DIR/.venv/bin/python3" -c "
import json
print(json.dumps({
    'session_id': 'sess_hcwd_test',
    'tool_name': 'Bash',
    'tool_input': {'command': 'echo hcwd_test', 'description': 'hook cwd launch test'},
    'cwd': '${REAL_PROJECT_ROOT}',
}))
"
}

@test "T-HCWD-005: permission_request_hook.sh (relative path, non-root cwd) fails to launch" {
    default_prh_json > "$TEST_TMP/stdin_prh.json"

    local invocation='bash scripts/permission_request_hook.sh'
    local cmd="export CLAUDE_PROJECT_DIR='${REAL_PROJECT_ROOT}'; cd '${TEST_TMP}/fakecwd'; PERMISSION_HOOK_TIMEOUT_SECONDS=1 __PERMISSION_HOOK_MARGIN_SECONDS=0 __PERMISSION_HOOK_ROOT='${TEST_TMP}' ${invocation} < '${TEST_TMP}/stdin_prh.json'"
    run_in_pane "$cmd"

    [ "$RC" -eq 127 ]
    [ -z "$OUT" ]
    [[ "$ERR" == *"scripts/permission_request_hook.sh"* ]]
    [[ "$ERR" == *"No such file or directory"* ]]
    # 起動できていないため、記録ファイルは1件も書かれない
    [ -z "$(request_files)" ]
}

@test "T-HCWD-006: permission_request_hook.sh (absolute \${CLAUDE_PROJECT_DIR} path, non-root cwd) launches correctly" {
    default_prh_json > "$TEST_TMP/stdin_prh.json"

    local invocation='bash "${CLAUDE_PROJECT_DIR}/scripts/permission_request_hook.sh"'
    local cmd="export CLAUDE_PROJECT_DIR='${REAL_PROJECT_ROOT}'; cd '${TEST_TMP}/fakecwd'; PERMISSION_HOOK_TIMEOUT_SECONDS=1 __PERMISSION_HOOK_MARGIN_SECONDS=0 __PERMISSION_HOOK_POLL_INTERVAL_SECONDS=1 __PERMISSION_HOOK_ROOT='${TEST_TMP}' ${invocation} < '${TEST_TMP}/stdin_prh.json'"
    run_in_pane "$cmd"

    # 決定ファイルを一切与えていないため、起動はしても最終的には
    # fail-closed(defer_timeout・rc=1)で終わる。これはT-HCWD-005の
    # rc=127(起動そのものの失敗)とは意味が異なる——rc=1は「起動し、
    # 記録も書き、決定を待ったが来なかったので設計どおり安全側へ
    # 倒れた」という★正常系の一形態である。
    [ "$RC" -eq 1 ]
    [ -z "$OUT" ]

    local f
    f="$(request_files)"
    [ -n "$f" ]
    run "$SCRIPT_DIR/.venv/bin/python3" -c "
import yaml
with open('$f') as fh:
    d = yaml.safe_load(fh)
assert d['agent_id'] == 'ashigaru_cwdtest', d
assert d['hook_result']['outcome'] == 'defer_timeout', d
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}
