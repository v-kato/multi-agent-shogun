#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# scripts/send_clear_gated.sh — 条件つき context reset 送信 (cmd_757②)
# ═══════════════════════════════════════════════════════════════
#
# ★lib/clear_send_gate.sh の唯一の入口である。判定も送信も全て
#   ライブラリ側に在り、本スクリプトは引数を渡してログを出すだけである。
#
# ★★cmd_754 E-1(自動打鍵の安全集合は空)は生きている。本スクリプトは
#   その上に積まれた「一命令・二条件」の限定例外であり、条件を
#   1つでも欠けば★送らずに終わる。既定は今も「送らない」である。
#
# ★★「`idle`は安全な入力受領の十分条件ではない。①が実証したのは『試した確認モーダルが`idle`から排除される』ことのみである」
#   ゆえに条件1(本人の申告)だけでは足りず、条件2(画面での★危険の否認と
#   ★唯一許可された既知の安全形への一致)を保険として併せて課す。
#   ★条件2 は安全を証明しない。拒否側にしか効かない。
#
# ★対象は `/clear`(★claude のみ)ただ一つ。
#   ★redo1 (2026-09-09) で次の3点を締めた:
#     ・claude 以外の CLI …… 権威的な状態源を pane 実体へ束縛できぬゆえ
#       ★不許可(人経路のまま)。`/new` は送らない。
#     ・`inbox_type` …… ★必須引数。`clear_command` 以外は送らない。
#     ・pane の実体 …… argv[0] が `claude` で、かつ pane 配下で走って
#       いることを★カーネル(/proc)と tmux の事実で確かめる。
#   ★redo2 (2026-09-09) で更に2点を締めた:
#     ・宛先 …… 入口で★一度だけ canonical pane_id(`%N`)へ解決する。
#       `session:window.index` は★不変の identity ではなく、pane が終了
#       すると★別の新しい pane へ再解決される(隔離検証で実証)。以後の
#       検査も打鍵も★不変 ID だけを使う。
#     ・`agent_id` …… ★必須引数。対象 pane の `@agent_id` と★完全一致
#       しなければ送らない(欠落・不一致は fail-closed)。
#   ★nudge(裸の Enter)は永久に不許可。model_switch / cli_restart は
#   引き続き人手経路(`scripts/switch_cli.sh --human-initiated`)のまま。
#
# 使い方:
#   bash scripts/send_clear_gated.sh <pane_target> <cli> <inbox_type> <agent_id>
#   例: bash scripts/send_clear_gated.sh multiagent:0.7 claude clear_command ashigaru7
#   ★4引数すべてが必須である。1つでも欠ければ引数不正(2)で終わる。
#
# 終了コード:
#   0 = 送信した
#   1 = 送らなかった (理由を stderr へ出す)
#   2 = 引数不正
# ═══════════════════════════════════════════════════════════════
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ "$#" -lt 4 ]; then
    echo "usage: send_clear_gated.sh <pane_target> <cli> <inbox_type> <agent_id>" >&2
    echo '  ★inbox_type は必須である (clear_command 以外は送らない)。' >&2
    echo '  ★agent_id も必須である (対象 pane の @agent_id と一致せねば送らない)。' >&2
    exit 2
fi

PANE_TARGET="$1"
CLI_TYPE="$2"
INBOX_TYPE="$3"
AGENT_ID="$4"

# shellcheck source=../lib/clear_send_gate.sh
source "$PROJECT_ROOT/lib/clear_send_gate.sh"

if gate_send_context_reset "$PANE_TARGET" "$CLI_TYPE" "$INBOX_TYPE" "$AGENT_ID"; then
    echo "[$(date)] [GATED-SEND] ${AGENT_ID}(pane=${GATE_PANE_ID:-?}): ${GATE_REASON}" >&2
    exit 0
fi

# ★送らなかった場合は cmd_754 の世界のままである。人経路へ倒れる。
echo "[$(date)] [NO-SEND] ${AGENT_ID}(pane=${PANE_TARGET}, type=${INBOX_TYPE}): ${GATE_REASON}" >&2
echo "[$(date)] [NO-SEND] 条件のいずれかを欠いたゆえ送らぬ。必要なら人手で当該 pane へ入力されたし。" >&2
exit 1
