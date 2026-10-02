#!/usr/bin/env bash
# Codex CLI 版 SessionStart hook (cmd_757④, 2026-09-09 足軽6号実機検証で確立)
#
# scripts/session_start_hook.sh (Claude Code 版) は stdout の plain text を
# そのまま additionalContext として注入できるが、Codex CLI は実機検証の結果
# 同じ契約を満たさなかった(plain text は模型の応答に現れなかった)。
# Codex CLI で実際に注入が確認できたのは以下の JSON 封筒のみ:
#   {"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"<text>"}}
# (隔離 tmux session + 隔離 CODEX_HOME で、注入した marker 文字列をモデルが
#  そのまま引用できることを実測して確認した。plain text 版は同条件で注入
#  されなかった。)
#
# 本 hook は persona 再確立の本文生成を session_start_hook.sh へ委譲し
# (agent_id 判定・persona 文面ロジックは完全に共通)、その stdout を上記
# JSON 封筒へ包むだけの薄いラッパーである。
#
# ★cmd_757④redo1 (G757-CODEX-PERSONA-PATH-01是正): 初版は session_start_hook.sh を
# 無引数(= claude 向け)で呼び出しており、Codex 宛にも CLAUDE.md・
# instructions/${AGENT_ID}.md・/clear 前提の誤った文面を注入していた。
# 本版は明示的に "codex" 引数を渡し、AGENTS.md・
# instructions/generated/codex-{role}.md・/new 契約に沿った文面を生成させる。
#
# Codex hooks.json 側の配線 (.codex/hooks.json.template → generate_codex_hooks.sh
# が実行時の絶対パスで展開する。個人環境の絶対パスを配布正本に直書きしない):
#   "SessionStart": [ { "matcher": "*", "hooks": [
#     { "type": "command", "command": "<PROJECT_ROOT>/scripts/codex_session_start_hook.sh" }
#   ] } ]
#
# Environment:
#   __STOP_HOOK_SCRIPT_DIR 相当のオーバーライドは持たない
#   (TMUX_PANE 経由の agent_id 判定は session_start_hook.sh 内で完結する)
#   __SESSION_START_HOOK_AGENT_ID — テスト用の agent_id 上書き
#     (session_start_hook.sh へそのまま引き継がれる)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# stdin (Codex hook input JSON) は使わない。session_start_hook.sh も読まない。
cat >/dev/null

TEXT="$(bash "$SCRIPT_DIR/session_start_hook.sh" codex 2>/dev/null || true)"

if [ -z "$TEXT" ]; then
    # agent_id 未設定(multi-agent 環境外)など、注入する内容が無い場合は無干渉で許可
    echo '{}'
    exit 0
fi

TEXT="$TEXT" python3 -c "
import json, os
text = os.environ['TEXT']
print(json.dumps(
    {'hookSpecificOutput': {'hookEventName': 'SessionStart', 'additionalContext': text}},
    ensure_ascii=False,
))
" 2>/dev/null || echo '{}'

exit 0
