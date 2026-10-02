#!/usr/bin/env bash
# ════════════════════════════════════════════════════
# cmd_799 ③ headless claude の隔離検証
#   実行: bash tests/verify_cmd_799_headless_isolated.sh
#         CODD_YAML=<codd.yaml のパス> bash tests/verify_cmd_799_headless_isolated.sh
#     CODD_YAML を渡すとその ai_command を、省略すると同形の既定値
#     (claude --print --model opus --tools "" --setting-sources "")を B で検証する。
#   ★bats テストではない(実際に claude CLI を起動し、応答待ちが約 2 分かかる)。
#     `bats tests/unit` は拾わない。課金経路は claude CLI のサブスク内。
#   ★目的: 是正後の headless 呼出し(--tools "" と --setting-sources "" の両方あり)が
#     project の hook(SessionStart / Stop / PermissionRequest)を走らせないことを、
#     使い捨ての fixture project で確かめる。陽性対照(旧形=--setting-sources 無し)で
#     「hook が走れば fixture に記録が出る配線」であることを先に示す。
#   ★実 queue・実 inbox・実 /tmp の idle 印には触れない。fixture は mktemp -d で作り、
#     hook 本体も fixture 内の複製を使う。身元(agent_id)は fixture 専用の
#     test_parent を env で与え、tmux には一切触れない(TMUX/TMUX_PANE は子から外す)。
#   ★後始末の rm -rf は書かない(fixture は残る・消さない)。
#   ★SKIP=FAIL: 前提(claude/codd/inotifywait)が欠ければ FAIL で終わる。
# ════════════════════════════════════════════════════
set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
log() { echo -e "$*"; }
check() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        PASS=$((PASS + 1)); log "  ✅ ${name}"
    else
        FAIL=$((FAIL + 1)); log "  ❌ ${name}\n      期待: ${want}\n      実際: ${got}"
    fi
}

# ── 前提 ────────────────────────────────────────────────
for need in claude inotifywait timeout python3 codd; do
    command -v "$need" >/dev/null 2>&1 || { log "❌ 前提欠落: $need (SKIP=FAIL)"; exit 1; }
done
CODD_PY="$(head -1 "$(command -v codd)" | sed 's/^#!//')"
[ -x "$CODD_PY" ] || { log "❌ codd の python を解決できない: $CODD_PY"; exit 1; }
# ai_command の出所: CODD_YAML 指定があればそのファイル、無ければ同形の既定値
SAMPLE_AI_COMMAND='claude --print --model opus --tools "" --setting-sources ""'
CODD_YAML="${CODD_YAML:-}"
if [ -n "$CODD_YAML" ]; then
    [ -f "$CODD_YAML" ] || { log "❌ CODD_YAML が無い: $CODD_YAML"; exit 1; }
fi

# ── fixture project(使い捨て・出自は mktemp -d の stdout) ──────────
FIX="$(mktemp -d)"
case "$FIX" in /*) ;; *) log "❌ fixture が絶対パスでない: $FIX"; exit 1 ;; esac
mkdir -p "$FIX"/{scripts,logs,flags,.claude,.venv/bin} \
         "$FIX"/queue/{inbox,tasks} "$FIX"/queue/state/{permission_requests,permission_decisions}
cp "$PROJECT_ROOT"/.claude/settings.json "$FIX/.claude/settings.json"
for s in session_start_hook.sh stop_hook_inbox.sh permission_request_hook.sh inbox_write.sh; do
    cp "$PROJECT_ROOT/scripts/$s" "$FIX/scripts/$s"
done
ln -s /usr/bin/python3 "$FIX/.venv/bin/python3"
printf 'messages: []\n' > "$FIX/queue/inbox/test_parent.yaml"
printf 'messages: []\n' > "$FIX/queue/inbox/karo.yaml"
: > "$FIX/logs/session_start_hook.log"

# 子から外す env: 親セッションの身元・messaging socket・tmux
mapfile -t _strip < <(env | cut -d= -f1 | /usr/bin/grep -E '^(CLAUDE|CLAUDECODE|ANTHROPIC|TMUX)' || true)
CLEANENV=(env)
for v in "${_strip[@]}"; do CLEANENV+=(-u "$v"); done
CLEANENV+=(
    "__SESSION_START_HOOK_AGENT_ID=test_parent"
    "__STOP_HOOK_AGENT_ID=test_parent"
    "__PERMISSION_HOOK_AGENT_ID=test_parent"
    "IDLE_FLAG_DIR=$FIX/flags"
)

log "═══ cmd_799 ③ 隔離検証 (fixture=${FIX}) ═══"
log "子から外した env: ${_strip[*]:-(なし)}"
log ""

# ── 観測点 ──────────────────────────────────────────────
obs_log()   { /usr/bin/grep -c 'test_parent session_start_hook fired' "$FIX/logs/session_start_hook.log" 2>/dev/null || true; }
obs_karo()  { /usr/bin/grep -c 'from: test_parent' "$FIX/queue/inbox/karo.yaml" 2>/dev/null || true; }
obs_flag()  { [ -e "$FIX/flags/shogun_idle_test_parent" ] && echo present || echo absent; }
obs_perm()  { find "$FIX/queue/state/permission_requests" -type f 2>/dev/null | wc -l; }
# 実側の汚染監視(増えてはならない)
real_hits() {
    local n=0 c
    c=$(/usr/bin/grep -c 'test_parent' "$PROJECT_ROOT/queue/inbox/karo.yaml" 2>/dev/null || true); n=$((n + ${c:-0}))
    c=$(/usr/bin/grep -c 'test_parent' "$PROJECT_ROOT/logs/session_start_hook.log" 2>/dev/null || true); n=$((n + ${c:-0}))
    [ -e /tmp/shogun_idle_test_parent ] && n=$((n + 1))
    c=$(find "$PROJECT_ROOT/queue/state/permission_requests" -name 'test_parent_*' 2>/dev/null | wc -l); n=$((n + c))
    echo "$n"
}
REAL0="$(real_hits)"
log "実側の test_parent 痕跡(開始時): ${REAL0}"
log ""

PROMPT='タスク完了 とだけ返せ。'

# run_case <name> <expect: fire|quiet> <cmd...>
run_case() {
    local name="$1" expect="$2"; shift 2
    local l0 k0 p0 l1 k1 f1 p1 out rc
    l0=$(obs_log); k0=$(obs_karo); p0=$(obs_perm)
    out="$(cd "$FIX" && "${CLEANENV[@]}" timeout 240 "$@" 2>&1)"; rc=$?
    l1=$(obs_log); k1=$(obs_karo); f1=$(obs_flag); p1=$(obs_perm)
    log "▼ ${name}  (rc=${rc}, 子の応答: $(printf '%s' "$out" | head -c 80 | tr '\n' ' '))"
    log "    SessionStart記録 ${l0}→${l1} / 家老inbox(from test_parent) ${k0}→${k1} / idle印 ${f1} / 権限記録 ${p0}→${p1}"
    check "${name}: 子が正常終了した(rc=0)" "0" "$rc"
    if [ "$expect" = "fire" ]; then
        check "${name}: [陽性対照] SessionStart hook が発火した(記録増)" "yes" "$([ "$l1" -gt "$l0" ] && echo yes || echo no)"
        check "${name}: [陽性対照] Stop hook が idle 印を作った" "present" "$f1"
    else
        check "${name}: SessionStart hook が発火しない(記録増 0)" "0" "$((l1 - l0))"
        check "${name}: Stop hook が親名義の報告を書かない(家老inbox増 0)" "0" "$((k1 - k0))"
        check "${name}: Stop hook が idle 印を作らない" "absent" "$f1"
        check "${name}: PermissionRequest 記録が増えない" "0" "$((p1 - p0))"
    fi
}

# 順序: 静穏 case(quiet)を先に、陽性対照(fire)を最後に流す。
# → 静穏 case で idle 印が「無い」ことを、先に作られた印の残存と取り違えない。

CODD_DRIVER='
import sys, yaml
from pathlib import Path
from codd.ai_invoke import invoke_ai
src, prompt = sys.argv[1], sys.argv[2]
cmd = yaml.safe_load(Path(src).read_text())["ai_command"] if src != "-" else sys.argv[3]
print(invoke_ai(cmd, prompt))
'
if [ -n "$CODD_YAML" ]; then
    B_SRC="$CODD_YAML"; B_EXTRA=()
    AI_CMD_SHOWN="$(python3 -c "import sys,yaml;print(yaml.safe_load(open(sys.argv[1]))['ai_command'])" "$CODD_YAML" 2>/dev/null || echo '?')"
else
    B_SRC="-"; B_EXTRA=("$SAMPLE_AI_COMMAND"); AI_CMD_SHOWN="$SAMPLE_AI_COMMAND (既定値)"
fi

log "▼ ai_command(B で検証する値): ${AI_CMD_SHOWN}"
log ""

run_case "B codd経路(ai_command を codd の invoke_ai で起動)" quiet \
    "$CODD_PY" -c "$CODD_DRIVER" "$B_SRC" "$PROMPT" "${B_EXTRA[@]}"
run_case "C interpret_vsync_mail 形(stdin)" quiet \
    bash -c 'printf "%s" "$1" | claude -p --tools "" --setting-sources "" --model haiku --output-format text' _ "$PROMPT"
run_case "D tests/ 配下 2 本の形(stdin・--model 無し)" quiet \
    bash -c 'printf "%s" "$1" | claude -p --tools "" --setting-sources ""' _ "$PROMPT"
run_case "A [陽性対照] 旧形(--setting-sources 無し)" fire \
    bash -c 'printf "%s" "$1" | claude --print --model haiku --tools ""' _ "$PROMPT"  # headless-audit-exempt: 陽性対照(旧形を意図して再現)

log ""
REAL1="$(real_hits)"
check "実側の test_parent 痕跡が増えていない(実 queue/実 inbox/実 idle 印へ書いていない)" "$REAL0" "$REAL1"

log ""
log "═══ 結果: PASS=${PASS} FAIL=${FAIL} (fixture=${FIX}・消さない) ═══"
[ "$FAIL" -eq 0 ]
