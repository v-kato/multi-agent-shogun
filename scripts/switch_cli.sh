#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# switch_cli.sh — エージェントのCLIセッションを安全に切り替える
#
# Usage:
#   bash scripts/switch_cli.sh <agent_id> --human-initiated [--type <cli_type>] [--model <model_name>] [--variant <variant>]
#
# ★--human-initiated は必須である (cmd_754 将軍裁定 E-1)。
#   本スクリプトは agent CLI が動いている pane へ /exit を打ち込む。そこへの
#   ★自動打鍵は廃止された。旗を付けられるのは「人が今この切替を命じ、当該
#   pane を見ている」場合だけであり、自動経路は決して付けてはならぬ。
#
# Examples:
#   # settings.yaml の現在値で再起動（CLI種別/モデル変更なし）
#   bash scripts/switch_cli.sh ashigaru3 --human-initiated
#
#   # Codex Spark → Claude Sonnet に切替（別名。5.5系へ解決される。旧版互換で
#   # 明示IDを使うなら --model claude-sonnet-4-6 も引き続き利用可）
#   bash scripts/switch_cli.sh ashigaru3 --human-initiated --type claude --model sonnet
#
#   # OpenCode で provider/model を直接指定（role 定義は --agent、モデル変更は再起動で反映）
#   bash scripts/switch_cli.sh ashigaru3 --human-initiated --type opencode --model openai/gpt-5.4-mini
#
#   # OpenCode provider-specific reasoning variant
#   bash scripts/switch_cli.sh ashigaru3 --human-initiated --type opencode --model openrouter/minimax/minimax-m2.5 --variant xhigh
#
#   # 同一CLI内でモデルだけ変更（Sonnet → Opus、別名。5.5系へ解決される）
#   bash scripts/switch_cli.sh ashigaru3 --human-initiated --model opus
#
#   # 全足軽を一括切替（人が見ている前提で一括して命じる場合）
#   for i in $(seq 1 7); do bash scripts/switch_cli.sh ashigaru$i --human-initiated --type claude --model sonnet; done
#
# Flow:
#   1. (Optional) settings.yaml を更新
#   2. 現在のCLIに /exit を送信
#   3. シェルプロンプトの復帰を待機
#   4. build_cli_command() で新CLIコマンドを構築
#   5. tmux send-keys で新CLIを起動
#   6. tmux pane metadata を更新（@agent_cli, @model_name）
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SETTINGS_FILE="${PROJECT_ROOT}/config/settings.yaml"
LOG_FILE="${PROJECT_ROOT}/logs/switch_cli.log"

# cli_adapter.sh をロード
source "${PROJECT_ROOT}/lib/cli_adapter.sh"
source "${PROJECT_ROOT}/lib/agent_registry.sh"

# ─── ★打鍵は人手起動のときだけ (cmd_754 将軍裁定 E-1) ───
# 本スクリプトは pane へ /exit と起動コマンドを打ち込む。打ち込む先は
# ★agent CLI が動いている pane である。将軍裁定 E-1 により、そこへの
# ★自動打鍵は廃した。
#
# ゆえに本スクリプトは、既定では★一切打鍵しない。打鍵するのは
# `--human-initiated` を明示して起動されたときだけである。この旗は
# 「人が今この切替を命じ、当該 pane を見ている」ことの表明であり、
# ★自動経路(inbox_watcher の cli_restart 等)は決してこれを付けない。
# 付けてよいのは、殿の指示で将軍が手ずから叩く場合のみである。
#
# ★旗を付けても、画面から安全を推し量ることは一切しない。4世代にわたり
#   破れた問いを持ち込まぬためである。安全を担保するのは「人が見ている」
#   という事実だけであり、それは画面からは分からぬ。ゆえに旗にする。
#
# ★残余リスク(正直に記す): 人が旗を付けて起動したその瞬間に、pane が
#   確認モーダルを表示していれば /exit の Enter がそれを答え得る。旗は
#   その危険を消さず、★責任の所在を人へ移すだけである。
_pane_preflight_lib="${PROJECT_ROOT}/lib/pane_preflight.sh"
if [ -f "$_pane_preflight_lib" ]; then
    # shellcheck source=../lib/pane_preflight.sh
    source "$_pane_preflight_lib"
fi

# 人手起動の表明。--human-initiated が渡されたときだけ 1 になる。
SC_HUMAN_INITIATED=0

# ─── ログ ───
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [switch_cli] $*"
    echo "$msg" >&2
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

# ─── Usage ───
usage() {
    echo "Usage: $0 <agent_id> [--type <cli_type>] [--model <model_name>] [--variant <variant>]"
    echo ""
    echo "  agent_id   Agent configured in config/settings.yaml (e.g. karo, ashigaru1, gunshi)"
    echo "  --type     claude | codex | copilot | kimi | opencode"
    echo "  --model    fable | sonnet | opus | gpt-6-sol | gpt-6.1-sol | gpt-6-luna | openai/gpt-5.4-mini | etc."
    echo "  --variant  OpenCode model variant such as xhigh, high, max, minimal"
    echo "  --human-initiated  ★必須。人が今この切替を命じ、当該paneを見ていることの表明。"
    echo "                     これ無しでは打鍵しない (cmd_754 将軍裁定 E-1)。"
    echo "                     自動経路(inbox_watcher 等)は決して付けてはならぬ。"
    echo ""
    echo "If --type/--model omitted, uses current settings.yaml values."
    exit 1
}

# ─── Agent ID → tmux pane 解決 ───
# @agent_id メタデータから動的にペインを検索する（ペイン番号のズレに対応）
# フォールバック: メタデータが見つからない場合は従来の固定マッピングを使用
resolve_pane() {
    local agent_id="$1"

    # Phase 1: @agent_id メタデータから動的検索
    local pane_count
    pane_count=$(tmux list-panes -t "multiagent:agents" 2>/dev/null | wc -l)
    if [[ "$pane_count" -gt 0 ]]; then
        for i in $(seq 0 $((pane_count - 1))); do
            local aid
            aid=$(tmux display-message -t "multiagent:agents.$i" -p '#{@agent_id}' 2>/dev/null)
            if [[ "$aid" == "$agent_id" ]]; then
                echo "multiagent:agents.$i"
                return 0
            fi
        done
        log "WARN: @agent_id=$agent_id not found in any pane. Falling back to fixed mapping."
    fi

    # Phase 2: フォールバック（settings.yaml の編成順から解決）
    local pane_base
    pane_base=$(tmux show-options -t multiagent -v @pane_base 2>/dev/null || echo "0")

    if agent_registry_multiagent_pane_for_agent "$agent_id" "$pane_base"; then
        return 0
    fi

    log "ERROR: Unknown agent_id: $agent_id"
    return 1
}

# ─── settings.yaml 更新 (Python使用) ───
update_settings_yaml() {
    local agent_id="$1"
    local new_type="${2:-}"
    local new_model="${3:-}"
    local new_variant="${4:-}"

    if [[ -z "$new_type" && -z "$new_model" && -z "$new_variant" ]]; then
        return 0
    fi

    log "Updating settings.yaml: ${agent_id} → type=${new_type:-<unchanged>}, model=${new_model:-<unchanged>}, variant=${new_variant:-<unchanged>}"

    "${PROJECT_ROOT}/.venv/bin/python3" << PYEOF
import yaml, sys, os, datetime

settings_path = "${SETTINGS_FILE}"
agent_id = "${agent_id}"
new_type = "${new_type}" or None
new_model = "${new_model}" or None
new_variant = "${new_variant}" or None

with open(settings_path, 'r', encoding='utf-8') as f:
    content = f.read()

with open(settings_path, 'r', encoding='utf-8') as f:
    data = yaml.safe_load(f) or {}

cli = data.setdefault('cli', {})
agents = cli.setdefault('agents', {})
agent_cfg = agents.get(agent_id)
if not isinstance(agent_cfg, dict):
    agent_cfg = {}
    agents[agent_id] = agent_cfg

timestamp = datetime.datetime.now().strftime('%Y-%m-%d')
comment = f"# {timestamp}: switch_cli.sh による切替"

if new_type:
    agent_cfg['type'] = new_type
if new_model:
    agent_cfg['model'] = new_model
if new_variant:
    agent_cfg['variant'] = new_variant

data['cli']['agents'][agent_id] = agent_cfg

# コメント保持のため、対象エージェント行だけsedで置換する方が安全だが
# 完全性のためyaml.dumpを使用。コメントは失われる。
# → 代わりにsed的なアプローチ: 対象ブロックだけ書き換える

# Simple approach: read lines, find agent block, replace
lines = content.split('\n')
new_lines = []
in_agent_block = False
agent_indent = None
skip_until_next = False
agent_block_found = False

i = 0
while i < len(lines):
    line = lines[i]
    stripped = line.lstrip()

    # Detect our agent's block start
    if stripped.startswith(f'{agent_id}:'):
        agent_block_found = True
        in_agent_block = True
        agent_indent = len(line) - len(stripped)
        new_lines.append(line)
        # Write the updated fields
        inner_indent = ' ' * (agent_indent + 2)
        if new_type:
            new_lines.append(f'{inner_indent}type: {new_type}')
        if new_model:
            new_lines.append(f'{inner_indent}model: {new_model}  {comment}')
        if new_variant:
            new_lines.append(f'{inner_indent}variant: {new_variant}  {comment}')
        # Skip old sub-fields
        i += 1
        while i < len(lines):
            next_line = lines[i]
            next_stripped = next_line.lstrip()
            if next_stripped == '' or next_stripped.startswith('#'):
                # Keep blank lines and comments between blocks
                if next_stripped.startswith('#') and len(next_line) - len(next_stripped) > agent_indent:
                    i += 1
                    continue
                break
            next_indent = len(next_line) - len(next_stripped)
            if next_indent <= agent_indent:
                break  # Next agent or section
            i += 1
        in_agent_block = False
        continue
    else:
        new_lines.append(line)
    i += 1

if not agent_block_found:
    # Agent block not found: fall back to yaml.dump (adds new block, comments lost)
    with open(settings_path, 'w', encoding='utf-8') as f:
        yaml.dump(data, f, allow_unicode=True, default_flow_style=False)
else:
    with open(settings_path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(new_lines))
        if not content.endswith('\n'):
            pass
        else:
            f.write('\n') if not '\n'.join(new_lines).endswith('\n') else None

print("OK")
PYEOF
}

# ─── OpenCode runtime agent frontmatter 同期 ───
# OpenCode TUI は `opencode run` と違って --variant を受け付けない。
# provider固有variantは git-ignored の .opencode/agents/<agent>-runtime.md に同期する。
sync_opencode_agent_frontmatter() {
    local agent_id="$1"
    local model="${2:-}"
    local variant="${3:-}"
    local base_file="${PROJECT_ROOT}/.opencode/agents/${agent_id}.md"
    local runtime_file="${PROJECT_ROOT}/.opencode/agents/${agent_id}-runtime.md"
    local normalized_model

    [[ -f "$base_file" ]] || return 0

    normalized_model="$(normalize_opencode_model "$model")"

    if [[ -z "$variant" ]]; then
        rm -f "$runtime_file"
        return 0
    fi

    log "Syncing OpenCode runtime agent: ${agent_id}-runtime → model=${normalized_model:-<unset>}, variant=${variant}"

    "${PROJECT_ROOT}/.venv/bin/python3" - "$base_file" "$runtime_file" "$normalized_model" "$variant" <<'PYEOF'
import sys
from pathlib import Path

import yaml

source = Path(sys.argv[1])
dest = Path(sys.argv[2])
model = sys.argv[3] or None
variant = sys.argv[4] or None

text = source.read_text(encoding="utf-8")
if not text.startswith("---\n"):
    raise SystemExit(0)

parts = text.split("---", 2)
if len(parts) < 3:
    raise SystemExit(0)

body = parts[2]
route = {}
if model:
    route["model"] = model
if variant:
    route["variant"] = variant
route_lines = yaml.safe_dump(route, allow_unicode=True, sort_keys=False).splitlines() if route else []

frontmatter_lines = parts[1].lstrip("\n").splitlines()
new_lines = []
inserted = False
for line in frontmatter_lines:
    stripped = line.lstrip()
    indent = len(line) - len(stripped)
    if indent == 0 and (stripped.startswith("model:") or stripped.startswith("variant:")):
        continue
    if not inserted and indent == 0 and stripped.startswith("permission:"):
        new_lines.extend(route_lines)
        inserted = True
    new_lines.append(line)

if not inserted:
    new_lines.extend(route_lines)

frontmatter_text = "\n".join(new_lines).rstrip()

dest.write_text(f"---\n{frontmatter_text}\n---{body}", encoding="utf-8")
PYEOF
}

# ─── 現在のCLI種別を取得（tmux metadata） ───
get_current_pane_cli() {
    local pane="$1"
    tmux show-options -p -t "$pane" -v @agent_cli 2>/dev/null | tr -d '[:space:]' || echo "claude"
}

# ─── 打鍵の入口 (cmd_754 E-1) ───
# sc_human_gate <purpose>
#   人手起動でなければ打鍵しない。★画面は一切見ない。
# Returns: 0 = 人手起動である / 1 = 自動起動ゆえ打鍵しない
sc_human_gate() {
    local purpose="$1"
    if [ "${SC_HUMAN_INITIATED:-0}" = "1" ]; then
        return 0
    fi
    log "[NO-AUTO-SEND] ${purpose} を送らぬ。agent CLI 稼働paneへの自動打鍵は cmd_754 の裁定により廃止した"
    log "                人手で切り替えるなら --human-initiated を付けて実行せよ (当該paneを見ている人が責を負う)"
    return 1
}

# sc_send_keys <pane> <ctx> <purpose> <send-keys引数...>
# ★人手起動のときだけ送る。ctx は記録のためだけに受け取る(判定には使わぬ)。
# ★配送失敗を握り潰さぬこと (cmd_754 redo3 D-6-1 /
#   G754-SEND-FAILURE-ACK-REDO2-02)。redo2 は tmux send-keys の失敗を
#   `|| true` で捨てており、/exit が届いていなくても次の打鍵へ進み、
#   最終的に「再起動できた」ことにされていた。
# Returns: 0 = 送った / 1 = 送らなかった(自動起動) / 2 = ★配送に失敗した
#          (1 も 2 も「送っていない」ゆえ、呼出側は以降の打鍵を中止すること)
sc_send_keys() {
    local pane="$1"
    local ctx="$2"
    local purpose="$3"
    shift 3

    sc_human_gate "${purpose} (pane=${pane}, ctx=${ctx})" || return 1
    local send_rc=0
    tmux send-keys -t "$pane" "$@" 2>/dev/null || send_rc=$?
    if [ "$send_rc" -ne 0 ]; then
        log "[SEND-FAILURE] ${purpose} の打鍵送信が失敗した (rc=${send_rc}, pane=${pane})。以降の打鍵は送らぬ"
        return 2
    fi
    return 0
}

# ─── /exit送信 ───
# ★打鍵先は agent CLI が動いている pane である。人手起動でなければ1打鍵も
#   送らない (cmd_754 E-1)。送信に失敗したら以降を送らず非0で戻る。
# ★人手起動であっても、その瞬間 pane がモーダルを出していれば /exit の
#   Enter がそれを答え得る。この危険は消せぬ。旗はそれを人の責任として
#   引き受ける表明である。
# Returns: 0 = 一連の打鍵を送り切った / 1 = 送らずに中断した
send_exit() {
    local pane="$1"
    local current_cli="$2"

    log "Sending exit command to ${pane} (current CLI: ${current_cli})"

    case "$current_cli" in
        codex)
            # Codex: suggestion UI dismissal → Ctrl-C → /exit
            sc_send_keys "$pane" "$current_cli" "/exit手順のEscape" Escape || return 1
            sleep 0.3
            sc_send_keys "$pane" "$current_cli" "/exit手順のC-c" C-c || return 1
            sleep 0.5
            sc_send_keys "$pane" "$current_cli" "/exit文字列の入力" "/exit" || return 1
            sleep 0.3
            sc_send_keys "$pane" "$current_cli" "/exit確定のEnter" Enter || return 1
            ;;
        claude)
            sc_send_keys "$pane" "$current_cli" "/exit文字列の入力" "/exit" || return 1
            sleep 0.3
            sc_send_keys "$pane" "$current_cli" "/exit確定のEnter" Enter || return 1
            ;;
        copilot|kimi)
            sc_send_keys "$pane" "$current_cli" "/exit手順のC-c" C-c || return 1
            sleep 0.5
            sc_send_keys "$pane" "$current_cli" "/exit文字列の入力" "/exit" || return 1
            sleep 0.3
            sc_send_keys "$pane" "$current_cli" "/exit確定のEnter" Enter || return 1
            ;;
        *)
            sc_send_keys "$pane" "$current_cli" "/exit文字列の入力" "/exit" || return 1
            sleep 0.3
            sc_send_keys "$pane" "$current_cli" "/exit確定のEnter" Enter || return 1
            ;;
    esac
    return 0
}

# ─── 新CLI起動打鍵 ───
# ★/exit 後の pane は「CLI 終了後のシェル」であるはずである。それを
#   ★画面の見た目ではなく pane の前景プロセス(#{pane_current_command})で
#   確かめる。前景が素のシェルなら TUI は存在せず、したがってモーダルも
#   既定選択肢も存在しない(lib/pane_preflight.sh の pane_is_bare_shell)。
#   /exit が効かず CLI が生きていれば前景は CLI のままであり、そこへ
#   起動コマンドを打ち込むことはしない。
# Returns: 0 = 起動打鍵を送った / 3 = 中止した
launch_new_cli() {
    local pane="$1"
    local target_cmd="$2"

    if ! declare -f pane_is_bare_shell >/dev/null 2>&1; then
        log "ERROR: lib/pane_preflight.sh を読み込めておらぬ。pane が素のシェルか確かめられぬゆえ新CLIを起動せず中止する (pane=${pane})"
        return 3
    fi
    if ! pane_is_bare_shell "$pane"; then
        log "ERROR: /exit 後も pane の前景が素のシェルではない (理由=${PANE_SHELL_REASON:-unknown}, pane=${pane})。"
        log "       ★CLI が終了できておらぬ見込みである。起動打鍵は送らず中止する。人が当該paneを確認せよ。"
        return 3
    fi

    if ! sc_send_keys "$pane" shell "新CLI起動コマンドの入力" "$target_cmd"; then
        log "ERROR: 新CLI起動コマンドを送らなかった。CLI切替を中止する (pane=${pane})"
        return 3
    fi
    sleep 0.3
    if ! sc_send_keys "$pane" shell "新CLI起動のEnter" Enter; then
        log "ERROR: 新CLI起動のEnterを送らなかった。CLI切替を中止する (pane=${pane})"
        log "       ★起動コマンドの文字列は入力欄に残るが、Enterを送らぬ限り実行されぬ。人が確認せよ。"
        return 3
    fi
    return 0
}
# ─── (preflight gate 対象打鍵ここまで) ───

# ─── シェルへ戻るのを待つ（最大15秒） ───
# ★cmd_754: 旧版は capture-pane の文字列から「プロンプトらしき行」や
#   「Bye 等の終了メッセージ」を探していた。これは画面からの推論であり、
#   本 cmd が4世代にわたり破ってきた問いと同じ病である(`Continue#` の
#   一行だけで shell と誤認した実例がある)。
#   ★よって画面は読まず、pane の前景プロセスが素のシェルへ戻ったことを
#   待つ。前景プロセスは描画物ではなく職制御の事実である。
# ★本関数は待つだけで、打鍵を許可しない。許可の判断は launch_new_cli が
#   改めて pane_is_bare_shell で行う。
wait_for_shell_prompt() {
    local pane="$1"
    local max_wait=15
    local waited=0

    log "Waiting for the pane to return to a bare shell: ${pane}"

    while [ "$waited" -lt "$max_wait" ]; do
        sleep 1
        waited=$((waited + 1))

        if declare -f pane_is_bare_shell >/dev/null 2>&1 && pane_is_bare_shell "$pane"; then
            log "Bare shell detected after ${waited}s (${PANE_SHELL_REASON:-unknown})"
            return 0
        fi
    done

    log "WARN: pane did not return to a bare shell within ${max_wait}s. 判定は launch_new_cli に委ねる。"
    return 0  # タイムアウトしても続行（launch_new_cli が改めて確かめて中止する）
}

# ─── モデル表示名の正規化（cli_adapter.sh の get_model_display_name を使用） ───
# get_model_display_name は cli_adapter.sh から source 済み

# ─── tmux pane metadata 更新 ───
update_pane_metadata() {
    local pane="$1"
    local new_cli_type="$2"
    local display_name="$3"

    log "Updating pane metadata: @agent_cli=${new_cli_type}, @model_name=${display_name}"

    tmux set-option -p -t "$pane" @agent_cli "$new_cli_type" 2>/dev/null || true
    tmux set-option -p -t "$pane" @model_name "$display_name" 2>/dev/null || true
    tmux select-pane -t "$pane" -T "$display_name" 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════
# メイン処理
# ═══════════════════════════════════════════════════════════════

# 引数パース
if [ $# -lt 1 ]; then
    usage
fi

# --help が第1引数の場合
if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    usage
fi

AGENT_ID="$1"
shift

NEW_TYPE=""
NEW_MODEL=""
NEW_VARIANT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --type)
            NEW_TYPE="$2"
            shift 2
            ;;
        --model)
            NEW_MODEL="$2"
            shift 2
            ;;
        --variant)
            NEW_VARIANT="$2"
            shift 2
            ;;
        --human-initiated)
            # ★人が今この切替を命じ、当該 pane を見ていることの表明。
            #   自動経路は決してこれを付けない (cmd_754 E-1)。
            SC_HUMAN_INITIATED=1
            shift
            ;;
        --help|-h)
            usage
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            ;;
    esac
done

# バリデーション
if [[ -n "$NEW_TYPE" ]] && ! _cli_adapter_is_valid_cli "$NEW_TYPE"; then
    log "ERROR: Invalid CLI type: ${NEW_TYPE}. Allowed: ${CLI_ADAPTER_ALLOWED_CLIS}"
    exit 1
fi

# Step 0: pane解決
PANE_TARGET=$(resolve_pane "$AGENT_ID")
if [ -z "$PANE_TARGET" ]; then
    exit 1
fi
log "=== Starting CLI switch for ${AGENT_ID} (pane: ${PANE_TARGET}) ==="

# Step 0.5: --model指定時に--type未指定なら、CLI種別を安全に補完する
if [[ -n "$NEW_MODEL" && -z "$NEW_TYPE" ]]; then
    case "$NEW_MODEL" in
        # gpt-6 系は世代の直後が '-' か '.' のものだけ(gpt-6-sol / gpt-6.1-sol)。
        # 'gpt-6*' まで緩めると gpt-60・gpt-6x 等の別系統名も codex と誤判定する。
        gpt-5.3-codex*|gpt-5-codex*|gpt-5.6-*|gpt-6-*|gpt-6.*|gpt-reserve)
            NEW_TYPE="codex"
            log "Auto-inferred type=codex from model=${NEW_MODEL}"
            ;;
        */*)
            if [[ "$(get_cli_type "$AGENT_ID")" == "opencode" ]]; then
                NEW_TYPE="opencode"
                log "Preserving type=opencode for provider-qualified model=${NEW_MODEL}"
            else
                log "ERROR: provider-qualified model IDs are ambiguous without --type; use --type opencode --model ${NEW_MODEL}"
                exit 1
            fi
            ;;
        claude-*|fable|sonnet|opus)
            NEW_TYPE="claude"
            log "Auto-inferred type=claude from model=${NEW_MODEL}"
            ;;
    esac
fi

# Step 0.6: ★着手前の gate (cmd_754 E-1)。
#   自動起動なら★settings.yaml を書き換える前にここで止める。後段の各打鍵
#   でも止まるが、ここで止めれば「設定だけ書き換わって実CLIは旧のまま」と
#   いう乖離を作らずに済む。
#   ★引数の検証(直前の型補完)より★後に置く。引数の誤りは pane に触れずとも
#   分かることであり、人手起動かどうかに関わらず同じ理由で失敗させるべき
#   だからである(自動起動でも「その引数は曖昧である」と返る方が親切であり、
#   既存の契約でもある)。gate を先に置くと、曖昧な --model を渡した呼出しが
#   「曖昧である」ではなく「自動起動ゆえ中止」で返り、誤りが隠れる。
if ! sc_human_gate "CLI切替の着手 (${AGENT_ID}, pane=${PANE_TARGET})"; then
    log "ERROR: 自動起動ゆえ CLI 切替を行わぬ。settings.yaml も書き換えぬ (${AGENT_ID})"
    log "       ★人手で切り替えるなら: bash scripts/switch_cli.sh ${AGENT_ID} --human-initiated [--type ...] [--model ...]"
    exit 3
fi

# Step 1: settings.yaml 更新（--type/--model/--variant 指定時のみ）
if [[ -n "$NEW_TYPE" || -n "$NEW_MODEL" || -n "$NEW_VARIANT" ]]; then
    update_settings_yaml "$AGENT_ID" "$NEW_TYPE" "$NEW_MODEL" "$NEW_VARIANT"
fi

# Step 2: 切替後のCLI情報を取得（settings.yaml反映後）
TARGET_CLI_TYPE=$(get_cli_type "$AGENT_ID")
TARGET_MODEL=$(get_agent_model "$AGENT_ID")
TARGET_VARIANT=$(_cli_adapter_read_yaml "cli.agents.${AGENT_ID}.variant" "")
if [[ "$TARGET_CLI_TYPE" == "opencode" ]]; then
    sync_opencode_agent_frontmatter "$AGENT_ID" "$TARGET_MODEL" "$TARGET_VARIANT"
fi
TARGET_CMD=$(build_cli_command "$AGENT_ID")

log "Target: cli=${TARGET_CLI_TYPE}, model=${TARGET_MODEL}, cmd=${TARGET_CMD}"

# Step 3: 現在のCLIを /exit で終了
CURRENT_CLI=$(get_current_pane_cli "$PANE_TARGET")
log "Current CLI: ${CURRENT_CLI}"
if ! send_exit "$PANE_TARGET" "$CURRENT_CLI"; then
    log "ERROR: 確認待ち等により /exit の打鍵を抑止した。CLI切替を中止する (${AGENT_ID}, pane=${PANE_TARGET})"
    log "       ★モーダルへ答えるのは人である。当該paneを人が処理した後に再実行せよ。"
    exit 3
fi

# Step 4: シェルプロンプトを待つ
wait_for_shell_prompt "$PANE_TARGET"

# Step 5: 新しいCLIコマンドを送信
# ★ここでの pane は CLI 終了後のシェルである。ctx=shell で認証する。
#   /exit 後に確認モーダル等へ遷移していた場合、この Enter が
#   その選択を確定してしまう。入口の capture は後段の状態を証明せぬ。
log "Launching new CLI: ${TARGET_CMD}"
if ! launch_new_cli "$PANE_TARGET" "$TARGET_CMD"; then
    log "ERROR: 新CLIの起動打鍵を抑止した。CLI切替を中止する (${AGENT_ID}, pane=${PANE_TARGET})"
    exit 3
fi

# Step 6: tmux pane metadata 更新
DISPLAY_NAME=$(get_model_display_name "$AGENT_ID")
update_pane_metadata "$PANE_TARGET" "$TARGET_CLI_TYPE" "$DISPLAY_NAME"

log "=== CLI switch complete: ${AGENT_ID} → ${TARGET_CLI_TYPE}/${TARGET_MODEL} (${DISPLAY_NAME}) ==="
echo "OK: ${AGENT_ID} → ${TARGET_CLI_TYPE}/${TARGET_MODEL}"
