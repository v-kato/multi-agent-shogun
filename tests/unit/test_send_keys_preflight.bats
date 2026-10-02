#!/usr/bin/env bats
# test_send_keys_preflight.bats — ★自動打鍵が存在しないことの単体テスト (cmd_754)
#
# 背景:
#   2026-09-08、確認モーダル表示中の pane へ inbox_watcher が nudge を送り、
#   その Enter が既定選択肢 `❯ 1. Yes` を選んで D002-E1 違反の削除が実行された。
#   以後4世代にわたり「画面から安全を証明する」試み(blocklist型 → marker片
#   認証 → 境界付きlayout認証 → cursor版有限allowlist)を重ねたが、4度とも
#   破れた。将軍はこれを実装の粗さではなく★問いが解けないことによると断じ、
#   ★自動打鍵の安全集合を空とする裁定を下した (E-1)。
#
# ★本ファイルの契約は反転した:
#   旧: 「安全と認証できた画面にだけ打鍵する」ことを検査していた
#   新: 「★いかなる画面・いかなる条件でも自動では打鍵しない」ことと、
#       「画面から安全を推論するコードが残っていない」ことを検査する
#
# テスト構成:
#   ── 安全集合が空であること (lib/pane_preflight.sh) ──
#   T-PF-001: preflight_safe_state_count は 0 を返す
#   T-PF-002: pane_send_preflight はいかなる引数でも送信禁止を返す
#   T-PF-003: 抑止理由は automatic_send_forbidden である
#   T-PF-004: pane_send_preflight は tmux を一度も呼ばない
#   T-PF-005: ライブラリに capture-pane が無い(画面推論の不在)
#   T-PF-006: ライブラリに打鍵系コマンドが無い
#   T-PF-007: cursor/layout 認証の痕跡が無い
#   T-PF-008: 画面認証の旧APIが存在しない
#   ── pane_is_bare_shell (前景プロセスという別の問い) ──
#   T-PF-010: 前景が bash なら素のシェルと判定する
#   T-PF-011: 各種シェル名を素のシェルと判定する
#   T-PF-012: 前景が CLI 名なら素のシェルではない
#   T-PF-013: 前景を読めなければ素のシェルではない(fail-safe)
#   T-PF-014: pane が存在しなければ素のシェルではない
#   T-PF-014b: 問い合わせ自体が失敗すれば素のシェルではない
#   T-PF-014c: pane_id と前景プロセスは一度の問い合わせで取る
#   T-PF-015: pane_target 未指定なら素のシェルではない
#   T-PF-016: 判定理由が PANE_SHELL_REASON に入る
#   T-PF-017: pane_is_bare_shell は capture-pane を呼ばない
#   ── inbox_watcher に打鍵が無いこと ──
#   T-PF-020: 実コードに tmux send-keys が1つも無い
#   T-PF-021: send_wakeup は打鍵しない
#   T-PF-022: send_wakeup_with_escape は打鍵しない
#   T-PF-023: send_cli_command は打鍵せず rc=1
#   T-PF-024: send_context_reset は打鍵せず rc=1
#   T-PF-025: send_startup_prompt は打鍵せず rc=1
#   T-PF-026: process_unread(未読0) は C-u も送らない
#   T-PF-027: process_unread(未読あり) も打鍵しない
#   T-PF-028: shogun への CLI コマンドは恒久skip(rc=2)
#   ── 特殊命令の既読化契約 ──
#   T-PF-030: clear_command は未送信ゆえ read:false のまま残る
#   T-PF-031: model_switch も未読のまま残る
#   T-PF-032: 不正 model_switch payload は終端skipとして既読化される
#   T-PF-033: shogun 宛の特殊命令は既読化される
#   T-PF-034: 未読のまま残るので次サイクルで再び数えられる
#   ── 特殊命令のみが未読のときの滞留 (cmd_754 redo1) ──
#   T-PF-035: clear_command 単独でも複数周期でカウンタが戻らず閾値へ届く
#   T-PF-036: model_switch 単独でも同じく閾値へ届く
#   T-PF-037: cli_restart 単独でも同じく閾値へ届く
#   T-PF-038: 特殊命令が既読化され全未読0になれば初めてカウンタが戻る
#   T-PF-039: 通常未読と特殊命令が混在しても総数が権威となる
#   ── 人経路 (E-3 / D-5) ──
#   T-PF-040: 閾値到達で家老へ inbox 通知が出る
#   T-PF-041: 通知はクールダウン中に連打されない
#   T-PF-042: 家老自身が対象なら通知先は軍師になる
#   T-PF-043: 家老が対象なら ntfy で殿へ到達する
#   T-PF-044: 将軍が対象なら ntfy で殿へ到達する
#   T-PF-045: 通常の足軽なら家老inboxのみ(ntfyは鳴らさない)
#   T-PF-046: 家老inboxへの書き込みが失敗したら ntfy へ切り替わる
#   T-PF-047: 未読が捌ければカウンタがリセットされる
#   T-PF-048: 通知文に人が取るべき手当てが書かれている
#   ── モーダル自動応答の不在 (厳禁事項) ──
#   T-PF-050: ライブラリはモーダルへ答える打鍵を持たない
#   T-PF-051: inbox_watcher も選択肢を答える打鍵を持たない
#   ── CLI 別配送経路の明示 (E-4) ──
#   T-PF-060: delivery_channel_for_cli — claude は stop_hook
#   T-PF-061: delivery_channel_for_cli — 他CLIは none(「たぶん届く」と書かぬ)
#   T-PF-062: CLI別配送経路の表が実装に併記されている
#   ── Stop hook が実在すること (E-2 の検証) ──
#   T-PF-070: Stop hook が .claude/settings.json に登録されている
#   T-PF-071: stop_hook_inbox.sh は未読があれば stop を block する
#   T-PF-072: stop_hook_inbox.sh は打鍵を持たない
#   T-PF-073: Stop hook の被覆限界(55秒窓)が実装に明記されている
#   ── 他スクリプトの残存経路 ──
#   T-PF-080: ratelimit_check.sh に打鍵が無い

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export WATCHER_SCRIPT="$PROJECT_ROOT/scripts/inbox_watcher.sh"
    export PREFLIGHT_LIB="$PROJECT_ROOT/lib/pane_preflight.sh"
    export STOP_HOOK="$PROJECT_ROOT/scripts/stop_hook_inbox.sh"
    export VENV_PYTHON="$PROJECT_ROOT/.venv/bin/python3"
    [ -f "$WATCHER_SCRIPT" ] || return 1
    [ -f "$PREFLIGHT_LIB" ] || return 1
    "$VENV_PYTHON" -c "import yaml" 2>/dev/null || return 1
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/preflight_test.XXXXXX")"
    export MOCK_LOG="$TEST_TMPDIR/tmux_calls.log"
    > "$MOCK_LOG"

    export MOCK_PGREP="$TEST_TMPDIR/mock_pgrep"
    cat > "$MOCK_PGREP" << 'MOCK'
#!/bin/bash
exit 1
MOCK
    chmod +x "$MOCK_PGREP"

    export TEST_INBOX_DIR="$TEST_TMPDIR/queue/inbox"
    mkdir -p "$TEST_INBOX_DIR"
    cat > "$TEST_INBOX_DIR/test_agent.yaml" << 'YAML'
messages: []
YAML

    # ── tmux モック制御 ──
    export MOCK_FOREGROUND="bash"     # #{pane_current_command} の返り値
    export MOCK_FOREGROUND_RC=0
    export MOCK_PANE_ID_RC=0          # pane 存在確認の rc
    export MOCK_PANE_CLI=""
    export MOCK_PANE_ACTIVE=""
    export MOCK_LIST_CLIENTS=""
    export MOCK_SENDKEYS_RC=0

    # ライブラリ単体を叩くための薄いハーネス (tmux をモックする)
    export LIB_HARNESS="$TEST_TMPDIR/lib_harness.sh"
    cat > "$LIB_HARNESS" << HARNESS
#!/bin/bash
tmux() {
    echo "tmux \$*" >> "$MOCK_LOG"
    if echo "\$*" | grep -q "pane_current_command"; then
        # ★実装は pane_id と前景プロセスを一度に問い合わせる
        [ "\${MOCK_FOREGROUND_RC:-0}" -ne 0 ] && return "\${MOCK_FOREGROUND_RC}"
        printf '%s|%s\n' "\${MOCK_PANE_ID-%0}" "\${MOCK_FOREGROUND:-}"
        return 0
    fi
    if echo "\$*" | grep -q "pane_id"; then
        return "\${MOCK_PANE_ID_RC:-0}"
    fi
    return 0
}
timeout() { shift; "\$@"; }
export -f tmux timeout
source "$PREFLIGHT_LIB"
HARNESS
    chmod +x "$LIB_HARNESS"

    export TEST_HARNESS="$TEST_TMPDIR/test_harness.sh"
    cat > "$TEST_HARNESS" << HARNESS
#!/bin/bash
AGENT_ID="\${TEST_AGENT_ID:-test_agent}"
PANE_TARGET="test:0.0"
CLI_TYPE="\${TEST_CLI_TYPE:-claude}"
INBOX="$TEST_INBOX_DIR/test_agent.yaml"
LOCKFILE="\${INBOX}.lock"
SCRIPT_DIR="$PROJECT_ROOT"
export IDLE_FLAG_DIR="$TEST_TMPDIR"

tmux() {
    echo "tmux \$*" >> "$MOCK_LOG"
    if echo "\$*" | grep -q "capture-pane"; then
        printf '%s\n' "\${MOCK_CAPTURE_PANE:-}"
        return 0
    fi
    if echo "\$*" | grep -q "send-keys"; then
        return \${MOCK_SENDKEYS_RC:-0}
    fi
    if echo "\$*" | grep -q "show-options"; then
        echo "\${MOCK_PANE_CLI:-}"
        return 0
    fi
    if echo "\$*" | grep -q "list-clients"; then
        [ -n "\${MOCK_LIST_CLIENTS:-}" ] && echo "\$MOCK_LIST_CLIENTS"
        return 0
    fi
    if echo "\$*" | grep -q "display-message"; then
        if echo "\$*" | grep -q "pane_current_command"; then
            printf '%s|%s\n' "\${MOCK_PANE_ID-%0}" "\${MOCK_FOREGROUND:-bash}"
            return 0
        fi
        if echo "\$*" | grep -q "pane_active"; then
            echo "\${MOCK_PANE_ACTIVE:-0}"
        else
            echo "mock_session"
        fi
        return 0
    fi
    return 0
}
timeout() { shift; "\$@"; }
pgrep() { "$MOCK_PGREP" "\$@"; }
sleep() { :; }
export -f tmux timeout pgrep sleep

export __INBOX_WATCHER_TESTING__=1
source "$WATCHER_SCRIPT"
HARNESS
    chmod +x "$TEST_HARNESS"

    # 既定: idle フラグを置き agent_is_busy() を idle にする
    touch "$TEST_TMPDIR/shogun_idle_test_agent"

    # 通知先モック (inbox_write.sh / ntfy.sh の呼び出しを記録する)
    export FAKE_ROOT="$TEST_TMPDIR/fake_root"
    mkdir -p "$FAKE_ROOT/scripts"
    # process_unread は "$SCRIPT_DIR/.venv/bin/python3" を使う。通知先を
    # 差し替えるために SCRIPT_DIR を FAKE_ROOT へ向けるテストでも python3 が
    # 引けるよう、venv を貸す。
    ln -sfn "$PROJECT_ROOT/.venv" "$FAKE_ROOT/.venv"
    export INBOX_WRITE_LOG="$TEST_TMPDIR/inbox_write.log"
    cat > "$FAKE_ROOT/scripts/inbox_write.sh" << 'FAKE'
#!/bin/bash
echo "target=$1 type=$3 from=$4" >> "$INBOX_WRITE_LOG"
echo "content=$2" >> "$INBOX_WRITE_LOG"
exit 0
FAKE
    chmod +x "$FAKE_ROOT/scripts/inbox_write.sh"

    export NTFY_LOG="$TEST_TMPDIR/ntfy.log"
    cat > "$FAKE_ROOT/scripts/ntfy.sh" << 'FAKENTFY'
#!/bin/bash
echo "ntfy=$1" >> "$NTFY_LOG"
exit 0
FAKENTFY
    chmod +x "$FAKE_ROOT/scripts/ntfy.sh"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

# ═══════════════════════════════════════════════════════
# 安全集合が空であること (lib/pane_preflight.sh)
# ═══════════════════════════════════════════════════════

@test "T-PF-001: preflight_safe_state_count は 0 を返す (安全集合は空)" {
    run bash -c "source '$PREFLIGHT_LIB' && preflight_safe_state_count"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "T-PF-002: pane_send_preflight はいかなる引数でも送信禁止を返す" {
    for args in "test:0.0 claude" "test:0.0 codex" "test:0.0 shell" "test:0.0" "" "test:0.0 unknown_cli"; do
        run bash -c "source '$PREFLIGHT_LIB'; pane_send_preflight $args"
        [ "$status" -eq 1 ]
    done
}

@test "T-PF-003: 抑止理由は automatic_send_forbidden である" {
    run bash -c "source '$PREFLIGHT_LIB'; pane_send_preflight test:0.0 claude; echo \"REASON=\$PREFLIGHT_REASON\""
    echo "$output" | grep -q "REASON=automatic_send_forbidden"
}

@test "T-PF-004: pane_send_preflight は tmux を一度も呼ばない (画面を覗かない)" {
    run bash -c "source '$LIB_HARNESS'; pane_send_preflight test:0.0 claude"
    [ "$status" -eq 1 ]
    [ ! -s "$MOCK_LOG" ]
}

@test "T-PF-005: ライブラリに capture-pane が無い (画面推論の不在)" {
    # コメントでは経緯として言及してよいが、★実コードには現れないこと
    run bash -c "grep -v '^[[:space:]]*#' '$PREFLIGHT_LIB' | grep -c 'capture-pane' || true"
    [ "$output" = "0" ]
}

@test "T-PF-006: ライブラリに打鍵系コマンドが無い" {
    run bash -c "grep -v '^[[:space:]]*#' '$PREFLIGHT_LIB' | grep -cE 'send-keys|paste-buffer|set-buffer|send -t' || true"
    [ "$output" = "0" ]
}

@test "T-PF-007: cursor/layout 認証の痕跡が無い (4度破れた問いを持ち込まない)" {
    # コメントでは経緯として言及してよいが、★実コードには残っていないこと
    run bash -c "grep -v '^[[:space:]]*#' '$PREFLIGHT_LIB' | grep -cE 'cursor_y|cursor_flag|pane_in_mode|bordered_input_frame|sidebar_input_frame|shell_prompt' || true"
    [ "$output" = "0" ]
}

@test "T-PF-008: 画面認証の旧APIが存在しない" {
    run bash -c "source '$PREFLIGHT_LIB'; for f in preflight_classify_pane_state detect_confirmation_prompt preflight_input_state_name preflight_processing_marker preflight_has_choice_structure; do declare -f \$f >/dev/null 2>&1 && echo \"STILL_EXISTS=\$f\"; done; true"
    [ -z "$output" ]
}

# ═══════════════════════════════════════════════════════
# pane_is_bare_shell — 「そもそも CLI が動いているか」という別の問い
# ═══════════════════════════════════════════════════════

@test "T-PF-010: 前景が bash なら素のシェルと判定する" {
    run bash -c "MOCK_FOREGROUND=bash; source '$LIB_HARNESS'; pane_is_bare_shell test:0.0"
    [ "$status" -eq 0 ]
}

@test "T-PF-011: 各種シェル名を素のシェルと判定する" {
    for sh in zsh sh dash fish ksh tcsh csh -bash -zsh; do
        run bash -c "MOCK_FOREGROUND='$sh'; source '$LIB_HARNESS'; pane_is_bare_shell test:0.0"
        [ "$status" -eq 0 ]
    done
}

@test "T-PF-012: 前景が CLI 名なら素のシェルではない" {
    for cmd in claude node codex copilot kimi opencode vim python3; do
        run bash -c "MOCK_FOREGROUND='$cmd'; source '$LIB_HARNESS'; pane_is_bare_shell test:0.0"
        [ "$status" -eq 1 ]
    done
}

@test "T-PF-013: 前景を読めなければ素のシェルではない (fail-safe)" {
    run bash -c "MOCK_FOREGROUND=''; source '$LIB_HARNESS'; pane_is_bare_shell test:0.0; rc=\$?; echo \"RC=\$rc REASON=\$PANE_SHELL_REASON\""
    echo "$output" | grep -q "RC=1"
    echo "$output" | grep -q "REASON=foreground_unreadable"
}

@test "T-PF-014: pane が存在しなければ素のシェルではない" {
    # ★実測(隔離tmux): 存在せぬ session を指すと tmux は rc=0 のまま
    #   pane_id を空で返す。ゆえに rc ではなく pane_id の空で判定する。
    run bash -c "MOCK_PANE_ID=''; MOCK_FOREGROUND=bash; source '$LIB_HARNESS'; pane_is_bare_shell test:0.0; rc=\$?; echo \"RC=\$rc REASON=\$PANE_SHELL_REASON\""
    echo "$output" | grep -q "RC=1"
    echo "$output" | grep -q "REASON=pane_absent"
}

@test "T-PF-014b: pane への問い合わせ自体が失敗すれば素のシェルではない" {
    run bash -c "MOCK_FOREGROUND_RC=1; source '$LIB_HARNESS'; pane_is_bare_shell test:0.0; rc=\$?; echo \"RC=\$rc REASON=\$PANE_SHELL_REASON\""
    echo "$output" | grep -q "RC=1"
    echo "$output" | grep -q "REASON=pane_query_failed"
}

@test "T-PF-014c: pane_id と前景プロセスは一度の問い合わせで取る (TOCTOU回避)" {
    run bash -c "MOCK_FOREGROUND=bash; source '$LIB_HARNESS'; pane_is_bare_shell test:0.0"
    [ "$status" -eq 0 ]
    # display-message は1回だけであること
    [ "$(grep -c 'display-message' "$MOCK_LOG")" -eq 1 ]
}

@test "T-PF-015: pane_target 未指定なら素のシェルではない" {
    run bash -c "source '$LIB_HARNESS'; pane_is_bare_shell ''; rc=\$?; echo \"RC=\$rc REASON=\$PANE_SHELL_REASON\""
    echo "$output" | grep -q "RC=1"
    echo "$output" | grep -q "REASON=pane_target_unset"
}

@test "T-PF-016: 判定理由が PANE_SHELL_REASON に入る" {
    run bash -c "MOCK_FOREGROUND=claude; source '$LIB_HARNESS'; pane_is_bare_shell test:0.0; echo \"REASON=\$PANE_SHELL_REASON\""
    echo "$output" | grep -q "REASON=foreground_not_shell:claude"
}

@test "T-PF-017: pane_is_bare_shell は capture-pane を呼ばない (画面を読まない)" {
    run bash -c "MOCK_FOREGROUND=bash; source '$LIB_HARNESS'; pane_is_bare_shell test:0.0"
    [ "$status" -eq 0 ]
    ! grep -q "capture-pane" "$MOCK_LOG"
}

# ═══════════════════════════════════════════════════════
# inbox_watcher に打鍵が無いこと
# ═══════════════════════════════════════════════════════










# ═══════════════════════════════════════════════════════
# 特殊命令の既読化契約 — 届かなかった命令を消さない
# ═══════════════════════════════════════════════════════



@test "T-PF-032: 不正 model_switch payload は終端skipとして既読化される" {
    cat > "$TEST_INBOX_DIR/test_agent.yaml" << 'YAML'
messages:
  - id: msg_bad
    from: karo
    timestamp: "2026-09-08T15:00:00+09:00"
    type: model_switch
    content: "garbage"
    read: false
YAML
    run bash -c "source '$TEST_HARNESS'; process_unread event"
    [ "$status" -eq 0 ]
    run "$VENV_PYTHON" -c "
import yaml
d=yaml.safe_load(open('$TEST_INBOX_DIR/test_agent.yaml'))
m=[x for x in d['messages'] if x['id']=='msg_bad'][0]
print('READ=%s' % m['read'])
"
    echo "$output" | grep -q "READ=True"
}

@test "T-PF-033: shogun 宛の特殊命令は恒久skipとして既読化される" {
    cat > "$TEST_INBOX_DIR/test_agent.yaml" << 'YAML'
messages:
  - id: msg_clear
    from: karo
    timestamp: "2026-09-08T15:00:00+09:00"
    type: clear_command
    content: redo
    read: false
YAML
    run bash -c "source '$TEST_HARNESS'; AGENT_ID=shogun; process_unread event"
    [ "$status" -eq 0 ]
    run "$VENV_PYTHON" -c "
import yaml
d=yaml.safe_load(open('$TEST_INBOX_DIR/test_agent.yaml'))
m=[x for x in d['messages'] if x['id']=='msg_clear'][0]
print('READ=%s' % m['read'])
"
    echo "$output" | grep -q "READ=True"
}


# ═══════════════════════════════════════════════════════
# 特殊命令のみが未読のときの滞留 (cmd_754 redo1)
#   旧実装は special を除いた count だけを見て「未読が捌けた」と誤認し、
#   同じ周期のうちに未配送カウンタを 0 へ戻していた。ゆえに
#   clear_command / model_switch / cli_restart だけの未読は★何周しても
#   閾値へ届かず、人へ一度も上がらぬまま read:false で沈んだ
#   (軍師QC G754-SPECIAL-ONLY-ESCALATION-RESET-01)。
# ═══════════════════════════════════════════════════════

_write_special_only_inbox() {
    local msg_type="$1" content="$2"
    cat > "$TEST_INBOX_DIR/test_agent.yaml" << YAML
messages:
  - id: msg_special
    from: karo
    timestamp: "2026-09-08T15:00:00+09:00"
    type: ${msg_type}
    content: "${content}"
    read: false
YAML
}

_run_special_only_cycles() {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        SCRIPT_DIR="'"$FAKE_ROOT"'"
        METRICS_FILE="'"$TEST_TMPDIR"'/metrics.yaml"
        DELIVERY_ALERT_THRESHOLD=2
        process_unread event
        echo "AFTER1=$DELIVERY_BLOCK_COUNT"
        process_unread event
        echo "AFTER2=$DELIVERY_BLOCK_COUNT"
    '
}

_assert_special_still_unread() {
    run "$VENV_PYTHON" -c "
import yaml
d=yaml.safe_load(open('$TEST_INBOX_DIR/test_agent.yaml'))
m=[x for x in d['messages'] if x['id']=='msg_special'][0]
print('READ=%s' % m['read'])
"
    echo "$output" | grep -q "READ=False"
}





@test "T-PF-039: 通常未読と特殊命令が混在しても総数が権威となる" {
    # 特殊命令が既読化されても通常未読が残るならリセットしない。
    cat > "$TEST_INBOX_DIR/test_agent.yaml" << 'YAML'
messages:
  - id: msg_bad
    from: karo
    timestamp: "2026-09-08T15:00:00+09:00"
    type: model_switch
    content: "garbage"
    read: false
  - id: msg_normal
    from: karo
    timestamp: "2026-09-08T15:00:01+09:00"
    type: task_assigned
    content: "作業開始せよ"
    read: false
YAML
    run bash -c '
        source "'"$TEST_HARNESS"'"
        SCRIPT_DIR="'"$FAKE_ROOT"'"
        METRICS_FILE="'"$TEST_TMPDIR"'/metrics.yaml"
        DELIVERY_ALERT_THRESHOLD=99
        DELIVERY_BLOCK_COUNT=3
        process_unread event
        echo "AFTER=$DELIVERY_BLOCK_COUNT"
    '
    [ "$status" -eq 0 ]
    # 不正payloadのmodel_switchは終端skipで既読化されるが、通常未読が
    # 残っているためカウンタは戻らない(3のまま、または滞留として増える)。
    ! echo "$output" | grep -q "AFTER=0"
}

# ═══════════════════════════════════════════════════════
# 人経路 (E-3 / D-5) — 届かぬことを人へ上げる
# ═══════════════════════════════════════════════════════










# ═══════════════════════════════════════════════════════
# モーダル自動応答の不在 (厳禁事項)
# ═══════════════════════════════════════════════════════

@test "T-PF-050: ライブラリはモーダルへ答える打鍵を持たない" {
    run bash -c "grep -v '^[[:space:]]*#' '$PREFLIGHT_LIB' | grep -cE \"send-keys.*(Yes|No|Enter|y|n)\" || true"
    [ "$output" = "0" ]
}


# ═══════════════════════════════════════════════════════
# CLI 別配送経路の明示 (E-4)
# ═══════════════════════════════════════════════════════




# ═══════════════════════════════════════════════════════
# Stop hook が実在すること (E-2 の検証)
# ═══════════════════════════════════════════════════════

@test "T-PF-070: Stop hook が .claude/settings.json に登録されている" {
    run "$VENV_PYTHON" -c "
import json
d=json.load(open('$PROJECT_ROOT/.claude/settings.json'))
cmds=[h['command'] for e in d.get('hooks',{}).get('Stop',[]) for h in e.get('hooks',[])]
print('FOUND' if any('stop_hook_inbox.sh' in c for c in cmds) else 'MISSING')
"
    [ "$output" = "FOUND" ]
}

@test "T-PF-071: stop_hook_inbox.sh は未読があれば stop を block する" {
    mkdir -p "$TEST_TMPDIR/hookroot/queue/inbox"
    cat > "$TEST_TMPDIR/hookroot/queue/inbox/ashigaru9.yaml" << 'YAML'
messages:
  - id: msg_1
    from: karo
    type: task_assigned
    content: 作業開始せよ
    read: false
YAML
    run bash -c "echo '{}' | __STOP_HOOK_SCRIPT_DIR='$TEST_TMPDIR/hookroot' __STOP_HOOK_AGENT_ID=ashigaru9 bash '$STOP_HOOK'"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"decision": *"block"'
    echo "$output" | grep -q "inbox未読1件"
}

@test "T-PF-072: stop_hook_inbox.sh は打鍵を持たない" {
    run bash -c "grep -v '^[[:space:]]*#' '$STOP_HOOK' | grep -cE 'send-keys|paste-buffer' || true"
    [ "$output" = "0" ]
}


# ═══════════════════════════════════════════════════════
# 他スクリプトの残存経路
# ═══════════════════════════════════════════════════════

@test "T-PF-080: ratelimit_check.sh に打鍵が無い" {
    run bash -c "grep -v '^[[:space:]]*#' '$PROJECT_ROOT/scripts/ratelimit_check.sh' | grep -cE 'send-keys' || true"
    [ "$output" = "0" ]
}
