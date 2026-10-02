#!/usr/bin/env bash
# generate_codex_hooks.sh — .codex/hooks.json.template から .codex/hooks.json を生成する
# (cmd_757④redo1, G757-ABSOLUTE-PATH-06是正)
#
# 背景: Codex CLI の hooks.json は command を実行体への絶対パス1本でしか
# 発火しない(足軽6号の実機検証・cmd_757④で確認済み)。個人環境の絶対パスを
# track 対象の配布正本へ直書きすると、clone先が異なる環境で silent に
# 不発火する(G757-ABSOLUTE-PATH-06)。本スクリプトは配置時、または
# clone先/展開先が変わった際に実行し、現在の PROJECT_ROOT (本スクリプト
# 自身の絶対パスから算出、clone先に追随する)で .codex/hooks.json.template
# の __PROJECT_ROOT__ を置換して .codex/hooks.json を(再)生成する。
#
# .codex/hooks.json 自体は個人環境の絶対パスを含むため .gitignore 対象
# (track対象は本スクリプトと .codex/hooks.json.template のみ)。
#
# 実行しただけでは何も有効化しない。Codex 側で /hooks → t (trust all) を
# 別途行うまで Installed=1/Active=0 のまま完全に無効。
#
# Usage: bash scripts/generate_codex_hooks.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE="$PROJECT_ROOT/.codex/hooks.json.template"
OUTPUT="$PROJECT_ROOT/.codex/hooks.json"

if [ ! -f "$TEMPLATE" ]; then
    echo "エラー: テンプレートが見つからない: $TEMPLATE" >&2
    exit 1
fi

python3 - "$TEMPLATE" "$OUTPUT" "$PROJECT_ROOT" <<'PYEOF'
import sys

template_path, output_path, project_root = sys.argv[1], sys.argv[2], sys.argv[3]

with open(template_path, "r", encoding="utf-8") as f:
    content = f.read()

content = content.replace("__PROJECT_ROOT__", project_root)

with open(output_path, "w", encoding="utf-8") as f:
    f.write(content)
PYEOF

echo "生成完了: $OUTPUT (PROJECT_ROOT=$PROJECT_ROOT)"
echo "★これだけでは有効化されぬ。Codex CLI 側で /hooks → t (trust all) が別途必要。"
