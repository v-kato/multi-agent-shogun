#!/usr/bin/env bash
# codd_wave_dispatcher.sh — Wave cmd YAML テンプレを shogun_to_karo.yaml に追記 (v2.14対応)
# Usage: bash skills/shogun-codd/scripts/codd_wave_dispatcher.sh <project> <n_waves> [wave_names_csv]
#   project       : codd プロジェクト名 (例: myproj)
#   n_waves       : Wave 数 (例: 3)
#   wave_names_csv: Wave 名をカンマ区切り (例: "受入基準+ADR,システム設計,詳細設計")
#                   省略時は "Wave 1", "Wave 2", ... が自動設定される
#
# 出力: queue/shogun_to_karo.yaml に N 個の codd_wave cmd を追記

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
YAML_FILE="$ROOT_DIR/queue/shogun_to_karo.yaml"

PROJECT="${1:-}"
N_WAVES="${2:-}"
WAVE_NAMES_CSV="${3:-}"

if [ -z "$PROJECT" ] || [ -z "$N_WAVES" ]; then
    echo "Usage: bash skills/shogun-codd/scripts/codd_wave_dispatcher.sh <project> <n_waves> [wave_names_csv]" >&2
    exit 1
fi

if ! [[ "$N_WAVES" =~ ^[0-9]+$ ]] || [ "$N_WAVES" -lt 1 ]; then
    echo "❌ n_waves は正の整数で指定してください。" >&2
    exit 1
fi

PROJECT_DIR="/mnt/e/WORK/codd_${PROJECT}"
TIMESTAMP=$(date "+%Y-%m-%dT%H:%M:%S+09:00")

# Wave 名の配列化
IFS=',' read -ra WAVE_NAME_ARRAY <<< "$WAVE_NAMES_CSV"

get_wave_name() {
    local idx=$((${1} - 1))
    if [ "${#WAVE_NAME_ARRAY[@]}" -gt "$idx" ] && [ -n "${WAVE_NAME_ARRAY[$idx]:-}" ]; then
        echo "${WAVE_NAME_ARRAY[$idx]}"
    else
        echo "Wave ${1}"
    fi
}

# shogun_to_karo.yaml が存在することを確認
if [ ! -f "$YAML_FILE" ]; then
    echo "❌ $YAML_FILE が見つかりません。" >&2
    exit 1
fi

echo "=== codd_wave_dispatcher: $PROJECT ($N_WAVES Waves) ==="

# YAML に追記 (flock で排他制御)
(
    flock -x 200
    echo "" >> "$YAML_FILE"
    echo "# --- codd_wave cmds for $PROJECT (generated $(date)) ---" >> "$YAML_FILE"

    for i in $(seq 1 "$N_WAVES"); do
        WAVE_NAME=$(get_wave_name "$i")
        CMD_ID="cmd_codd_${PROJECT}_W${i}"

        if [ "$i" -eq 1 ]; then
            DEPENDS_LINE=""
        else
            PREV=$((i - 1))
            DEPENDS_LINE="  depends_on: cmd_codd_${PROJECT}_W${PREV}"
        fi

        cat >> "$YAML_FILE" << ENDYAML
- id: ${CMD_ID}
  type: codd_wave
  wave_number: ${i}
  wave_name: "${WAVE_NAME}"
  project: ${PROJECT}
  project_dir: ${PROJECT_DIR}
${DEPENDS_LINE}
  timestamp: '${TIMESTAMP}'
  north_star: "${WAVE_NAME} の成果物を確定する"
  purpose: "Wave${i}: ${WAVE_NAME} の並列ドキュメント生成とQCゲート通過"
  acceptance_criteria:
    - 全 parallel_docs が codd validate pass
    - 軍師レビューで一貫性問題なし
    - dashboard Wave進捗表が更新済
  parallel_docs: []
  qc_command: "codd validate --wave ${i}"
  qc_assignee: gunshi
  qc_extra_criteria:
    - 循環依存の有無
    - 冗長記述の検出
    - 曖昧性（"適切に"等）の検出
  status: pending
  started_at: null
  completed_at: null
  qc_result: null
  qc_notes: null
ENDYAML

        echo "  ✅ $CMD_ID (Wave $i: $WAVE_NAME)"
    done
) 200>"$YAML_FILE.lock"

rm -f "$YAML_FILE.lock"

echo ""
echo "✅ $N_WAVES 個の codd_wave cmd を $YAML_FILE に追記しました。"
echo "   ⚠️  parallel_docs は家老が手動で埋める必要があります (codd plan --waves 出力を参照)。"
