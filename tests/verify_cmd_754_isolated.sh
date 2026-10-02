#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# cmd_754 最終版の隔離tmux検証
#   実行: bash tests/verify_cmd_754_isolated.sh
#   ★bats テストではない(tmux server を立てるため)。`make test` は拾わない。
#     `bats tests/*.bats` は .bats だけを見るゆえ、本ファイルは対象外である。
#   ★稼働中の agent pane には一切触れない。専用ソケット (-L) の
#     tmux server 上にだけ pane を作り、そこで実挙動を確かめる。
#   ★D006 により tmux kill-server / kill-session は使わない。
#     後始末は「自分で作った素のシェル pane へ exit を入力する」で行う。
# ═══════════════════════════════════════════════════════════════
set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOCK="cmd754_verify_$$"
PASS=0
FAIL=0

log()  { echo -e "$*"; }
check() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        PASS=$((PASS+1)); log "  ✅ ${name}"
    else
        FAIL=$((FAIL+1)); log "  ❌ ${name}\n      期待: ${want}\n      実際: ${got}"
    fi
}

# ★隔離の担保: 専用ソケットにしか触らせない
itmux() { command tmux -L "$SOCK" "$@"; }

log "═══ cmd_754 最終版 隔離tmux検証 (socket=${SOCK}) ═══"
log ""

# ── 0. 隔離の確認 ──────────────────────────────────────────────
log "▼ 0. 隔離の確認"
itmux new-session -d -s verify -n w0 bash 2>/dev/null
sleep 1
sessions="$(itmux list-sessions -F '#{session_name}' 2>/dev/null | tr '\n' ',')"
check "隔離serverに verify セッションのみ存在する" "verify," "$sessions"
live_seen="$(itmux list-sessions -F '#{session_name}' 2>/dev/null | grep -cE '^(multiagent|shogun)$' || true)"
check "隔離serverから稼働中セッションは見えない" "0" "$live_seen"
PANE="verify:w0.0"

# ★ライブラリは本物を読む。tmux は「隔離ソケット固定の実行可能 shim」へ
#   差し替える。★シェル関数では駄目である: lib は `timeout tmux ...` と
#   呼ぶため、timeout が関数を見つけられず素の tmux(既定ソケット)を叩く。
#   実際、初回の試行はこれで pane_current_command が空になった。
SHIM_DIR="$(mktemp -d /tmp/cmd754_shim.XXXXXX)"
cat > "$SHIM_DIR/tmux" <<SHIM
#!/usr/bin/env bash
exec $(command -v tmux) -L "$SOCK" "\$@"
SHIM
chmod +x "$SHIM_DIR/tmux"
export PATH="$SHIM_DIR:$PATH"
check "shim 経由で隔離ソケットの前景プロセスを読める" "bash" "$(timeout 3 tmux display-message -t "$PANE" -p '#{pane_current_command}')"

source "$PROJECT_ROOT/lib/pane_preflight.sh"
log ""

# ── 1. 安全集合が空であること ─────────────────────────────────
log "▼ 1. 安全集合が空であること (E-1)"
check "preflight_safe_state_count" "0" "$(preflight_safe_state_count)"

for ctx in claude codex copilot kimi opencode shell "" unknown; do
    pane_send_preflight "$PANE" "$ctx"; rc=$?
    check "pane_send_preflight ctx=${ctx:-<empty>} は送信禁止" "1:automatic_send_forbidden" "${rc}:${PREFLIGHT_REASON}"
done
log ""

# ── 2. pane_is_bare_shell を実 pane で確かめる ───────────────
log "▼ 2. pane_is_bare_shell を実 pane で確かめる (E-5 の根拠)"
fg="$(pane_foreground_command "$PANE")"
log "  (実測: pane_current_command = '${fg}')"
pane_is_bare_shell "$PANE"; rc=$?
check "素のシェルの pane は bare_shell と判定される" "0" "$rc"
log "  (理由: ${PANE_SHELL_REASON})"

# 前景で別プログラムを走らせると bare_shell ではなくなること。
# ★これは「CLI が動いている pane」を模した状況である。
itmux send-keys -t "$PANE" "sleep 30" Enter
sleep 1.5
fg2="$(pane_foreground_command "$PANE")"
log "  (実測: 前景プログラム実行中の pane_current_command = '${fg2}')"
pane_is_bare_shell "$PANE"; rc=$?
check "前景に別プログラムが居れば bare_shell ではない" "1" "$rc"
log "  (理由: ${PANE_SHELL_REASON})"
check "理由に実際の前景プロセス名が入る" "foreground_not_shell:${fg2}" "${PANE_SHELL_REASON}"

# 存在せぬ session (★tmux は範囲外の pane 番号を丸めるため、番号ではなく
# session を存在せぬものにして確かめる)
pane_is_bare_shell "nosuchsession:0.0"; rc=$?
check "存在せぬ session は bare_shell ではない" "1:pane_absent" "${rc}:${PANE_SHELL_REASON}"
log "  (参考: tmux は範囲外の pane 番号を丸める。実測 verify:w0.99 → $(timeout 3 tmux display-message -t verify:w0.99 -p '#{pane_id}' 2>/dev/null))"
log ""

# sleep の終了を待つ
log "  (前景 sleep の終了を待つ…)"
for _ in $(seq 1 40); do
    [ "$(pane_foreground_command "$PANE")" = "bash" ] && break
    sleep 1
done
log ""

# ── 3. モーダルを描いた pane へ打鍵が起きないこと ─────────────
log "▼ 3. ★軍師反例: 確認モーダルを描いた pane へ打鍵が起きないこと"
# 実際の権限モーダルを模した画面を描く(描画するだけ。応答は待たない)
itmux send-keys -t "$PANE" "printf '╭──────────────────────────────╮\\n│ Bash command                 │\\n│   rm -rf /tmp/scratch        │\\n│ Do you want to proceed?      │\\n│ ❯ 1. Yes                     │\\n│   2. No                      │\\n╰──────────────────────────────╯\\n'" Enter
sleep 1
before="$(itmux capture-pane -t "$PANE" -p | md5sum | cut -d' ' -f1)"

# ★本物の inbox_watcher の関数を、この隔離 pane を相手に走らせる。
WORK="$(mktemp -d /tmp/cmd754_verify.XXXXXX)"
mkdir -p "$WORK/queue/inbox" "$WORK/scripts"
cat > "$WORK/queue/inbox/verify_agent.yaml" <<'YAML'
messages:
  - id: msg_v1
    from: karo
    timestamp: "2026-09-08T16:00:00+09:00"
    type: task_assigned
    content: このディレクトリは削除するな
    read: false
  - id: msg_v2
    from: karo
    timestamp: "2026-09-08T16:00:01+09:00"
    type: clear_command
    content: redo
    read: false
YAML
cat > "$WORK/scripts/inbox_write.sh" <<'FAKE'
#!/bin/bash
echo "target=$1 type=$3 from=$4" >> "$INBOX_WRITE_LOG"
echo "content=$2" >> "$INBOX_WRITE_LOG"
exit 0
FAKE
cat > "$WORK/scripts/ntfy.sh" <<'FAKE'
#!/bin/bash
echo "ntfy=$1" >> "$NTFY_LOG"
exit 0
FAKE
chmod +x "$WORK/scripts/inbox_write.sh" "$WORK/scripts/ntfy.sh"
export INBOX_WRITE_LOG="$WORK/inbox_write.log"
export NTFY_LOG="$WORK/ntfy.log"
# SCRIPT_DIR を偽 root へ向けても python3 が要るので venv を貸す
ln -s "$PROJECT_ROOT/.venv" "$WORK/.venv"

watcher_out="$( (
    AGENT_ID="verify_agent"
    PANE_TARGET="$PANE"
    CLI_TYPE="claude"
    INBOX="$WORK/queue/inbox/verify_agent.yaml"
    LOCKFILE="${INBOX}.lock"
    SCRIPT_DIR="$PROJECT_ROOT"
    export IDLE_FLAG_DIR="$WORK"
    touch "$WORK/shogun_idle_verify_agent"
    tmux() { command tmux -L "$SOCK" "$@"; }
    export -f tmux
    export __INBOX_WATCHER_TESTING__=1
    source "$PROJECT_ROOT/scripts/inbox_watcher.sh"
    SCRIPT_DIR="$WORK"          # 通知先を偽 root へ向ける
    DELIVERY_ALERT_THRESHOLD=2
    send_wakeup 2
    send_wakeup_with_escape 2
    send_cli_command "/clear" || true
    send_context_reset || true
    send_startup_prompt || true
    process_unread event
    echo "BLOCK_COUNT=$DELIVERY_BLOCK_COUNT"
) 2>&1 )"
after="$(itmux capture-pane -t "$PANE" -p | md5sum | cut -d' ' -f1)"
check "モーダル表示中の pane 画面は1文字も変わらない" "$before" "$after"
check "打鍵が起きていない(画面ハッシュ一致)" "unchanged" "$([ "$before" = "$after" ] && echo unchanged || echo CHANGED)"
log ""

# ── 4. 未配送の記録と人経路 ───────────────────────────────────
log "▼ 4. 未配送の記録と人経路 (E-3)"
echo "$watcher_out" | grep -q "NO-AUTO-SEND" && check "未配送がログに残る" "yes" "yes" || check "未配送がログに残る" "yes" "no"
if [ -s "$INBOX_WRITE_LOG" ]; then
    check "家老へ inbox 通知が出た" "karo" "$(grep -o 'target=[a-z]*' "$INBOX_WRITE_LOG" | head -1 | cut -d= -f2)"
    grep -q "dashboard.md 🚨要対応" "$INBOX_WRITE_LOG" \
        && check "通知文が dashboard 🚨要対応 への掲載を求める" "yes" "yes" \
        || check "通知文が dashboard 🚨要対応 への掲載を求める" "yes" "no"
else
    check "家老へ inbox 通知が出た" "yes" "no(ログ空)"
fi

# clear_command が未読のまま残っていること
unread="$("$PROJECT_ROOT/.venv/bin/python3" - "$WORK/queue/inbox/verify_agent.yaml" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
m = [x for x in d["messages"] if x["id"] == "msg_v2"][0]
print("read=%s" % m["read"])
PY
)"
check "送れなかった clear_command は未読のまま残る" "read=False" "$unread"
log ""

# ── 5. 家老自身が滞留したときの ntfy 経路 ─────────────────────
log "▼ 5. 家老自身が滞留したときの ntfy 経路 (E-3)"
: > "$NTFY_LOG"
karo_out="$( (
    AGENT_ID="karo"
    PANE_TARGET="$PANE"
    CLI_TYPE="claude"
    INBOX="$WORK/queue/inbox/verify_agent.yaml"
    LOCKFILE="${INBOX}.lock"
    SCRIPT_DIR="$PROJECT_ROOT"
    export IDLE_FLAG_DIR="$WORK"
    tmux() { command tmux -L "$SOCK" "$@"; }
    export -f tmux
    export __INBOX_WATCHER_TESTING__=1
    source "$PROJECT_ROOT/scripts/inbox_watcher.sh"
    SCRIPT_DIR="$WORK"
    DELIVERY_ALERT_THRESHOLD=1
    delivery_register_undeliverable "未読2件の起床通知" "no_delivery_channel"
) 2>&1 )"
[ -s "$NTFY_LOG" ] && check "家老滞留時は ntfy が殿へ鳴る" "yes" "yes" || check "家老滞留時は ntfy が殿へ鳴る" "yes" "no"
grep -q "gunshi" "$INBOX_WRITE_LOG" && check "同時に軍師へも記録が残る" "yes" "yes" || check "同時に軍師へも記録が残る" "yes" "no"
log ""

# ── 6. Stop hook が実際に配送を担うこと ───────────────────────
log "▼ 6. Stop hook が実際に配送を担うこと (E-2 の検証)"
mkdir -p "$WORK/hookroot/queue/inbox"
cat > "$WORK/hookroot/queue/inbox/verify_agent.yaml" <<'YAML'
messages:
  - id: msg_h1
    from: karo
    type: task_assigned
    content: 隔離検証用のメッセージ
    read: false
YAML
hook_out="$(echo '{}' | __STOP_HOOK_SCRIPT_DIR="$WORK/hookroot" __STOP_HOOK_AGENT_ID=verify_agent \
    bash "$PROJECT_ROOT/scripts/stop_hook_inbox.sh" 2>/dev/null)"
echo "$hook_out" | grep -q '"decision": *"block"' \
    && check "未読があれば stop を block して本人へ食わせる" "yes" "yes" \
    || check "未読があれば stop を block して本人へ食わせる" "yes" "no($hook_out)"
echo "$hook_out" | grep -q "隔離検証用のメッセージ" \
    && check "block の reason に本文が載る(打鍵ゼロで届く)" "yes" "yes" \
    || check "block の reason に本文が載る(打鍵ゼロで届く)" "yes" "no"
hook_keys="$(grep -v '^[[:space:]]*#' "$PROJECT_ROOT/scripts/stop_hook_inbox.sh" | grep -c 'send-keys' || true)"
check "Stop hook 自身は打鍵を持たない" "0" "$hook_keys"
log ""

# ── 7. 実運用の agent への配送経路(実測) ──────────────────────
log "▼ 7. 実運用 agent の配送経路 (E-4 の裏取り・読み取りのみ)"
sw_count=0        # agent 自前の self-watch
watcher_count=0   # inbox_watcher 自身の監視ループ
stophook_count=0  # ★Stop hook が未読を待っている間の inotifywait
while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    # ★pgrep -f はコマンドラインに文字列を含むだけのシェルも拾う
    #   (本スクリプト自身の pgrep 行がまさにそれである)。
    #   実体が inotifywait であるものだけを数える。
    [ "$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ')" = "inotifywait" ] || continue
    ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    pcmd="$(ps -o cmd= -p "$ppid" 2>/dev/null)"
    case "$pcmd" in
        *stop_hook_inbox.sh*)
            stophook_count=$((stophook_count+1)) ;;
        *inbox_watcher.sh*|*google_chat_inbox_watcher.sh*)
            watcher_count=$((watcher_count+1)) ;;
        *)
            sw_count=$((sw_count+1)); log "      (分類不能な inotifywait: pid=$pid parent=$pcmd)" ;;
    esac
done < <(pgrep -f "inotifywait.*queue/inbox" 2>/dev/null)
log "  実測: inbox_watcher の監視ループ=${watcher_count}本 / Stop hook の待機=${stophook_count}本 / agent 自前=${sw_count}本"
check "agent 自前の self-watch は実在しない(=0本)" "0" "$sw_count"
[ "$stophook_count" -gt 0 ] \
    && check "Stop hook が実際に未読を待っている(配送経路として稼働中)" "yes" "yes" \
    || log "  ⚠️  今この瞬間 Stop hook の待機は観測されず(全 agent が作業中なら正常)"
log "  ★E-4 の表はこの実測に基づく。self-watch を配送経路として数えない。"
log "  ★Stop hook の待機は1回あたり最大55秒である。窓を過ぎて idle になれば消える。"
log ""

# ── 8. 後始末 ─────────────────────────────────────────────────
# ★D006 により kill-server / kill-session は使わない。
#   自分で作った★素のシェル pane へ exit を入力して自然終了させる。
log "▼ 8. 後始末 (kill は使わぬ)"
rm -rf "$WORK"
if pane_is_bare_shell "$PANE"; then
    itmux send-keys -t "$PANE" "exit" Enter
    sleep 2
    if itmux has-session -t verify 2>/dev/null; then
        log "  ⚠️  隔離セッションが残っている。socket=${SOCK} を人が確認されたし"
    else
        log "  ✅ 隔離セッションは自然終了した (socket=${SOCK})"
    fi
else
    log "  ⚠️  隔離 pane が素のシェルでないため exit を送らぬ (${PANE_SHELL_REASON:-unknown})。socket=${SOCK} が残る"
fi
# ★shim の削除は tmux 操作を全て終えてから行う(先に消すと隔離が切れる)。
rm -rf "$SHIM_DIR"
log ""

log "═══ 結果: PASS=${PASS} FAIL=${FAIL} ═══"
[ "$FAIL" -eq 0 ]
