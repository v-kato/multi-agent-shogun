#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# scripts/permission_decide.sh — PermissionRequest hook決定ファイル書込み
#                                  (cmd_775 Phase C)
# ═══════════════════════════════════════════════════════════════
#
# Usage:
#   permission_decide.sh <request_id> <deny|allow> --by <shogun|lord> \
#       --reason <文> [--machine-check <証跡ファイル>] [--lord-channel <ntfy|terminal>]
#   permission_decide.sh inquire <request_id> --by shogun --channel <ntfy|terminal>
#
# ★`defer`は決定の語彙から除外された(cmd_775 Phase D redo2・将軍裁定
#   (iii))。decisionは`deny`か`allow`のみ受理する。allowが殿権限で
#   将軍が殿へ判断を仰ぐ間は、決定を一切書かず下記`inquire`サブコマンド
#   を使うこと。
#
# allow は次のいずれかでのみ受理する(それ以外は非0終了・決定ファイルを
# 書かない=fail-closed。デフォルトへの自動降格はしない):
#   1. --by lord            — 無条件で受理する(殿の返答を将軍が転記する
#                              運用であり、転記者の誠実性は脅威モデル上
#                              「非敵対」の前提に含まれる)。
#   2. --by shogun かつ --machine-check <証跡ファイル> が指定され、
#      (a) 証跡ファイルが実在し読み取れる (b) 証跡ファイルが自己申告する
#      検査対象コマンド(checked_command)が、対応する記録ファイル
#      (queue/state/permission_requests/<request_id>.yaml)のtool_input.
#      commandと完全一致する (c) 証跡ファイルのverdictが明示的に "PASS"
#      である、の3条件を★全て満たす場合のみ。
#
# 1 request 1 決定(ln によるEEXIST検知・上書き不可)。決定ファイルは
# queue/state/permission_decisions/<request_id>.yaml に監査ログとして
# 残る(privategit保全対象)。
#
# ─── inquire サブコマンド(将軍裁定(iii)・決定ではない) ───
# `inquire`は決定ファイルを書かず、1 request 1決定のslotも消費しない
# (inquire後もallow/denyを正常に書ける)。記録ファイル(queue/state/
# permission_requests/<request_id>.yaml)へ`inquiry: {sent_at: <UTC>,
# channel: <ntfy|terminal>, by: shogun}`を原子的に追記するのみ(既存
# フィールドは変更しない)。将軍がallow判断を殿へ委ねる際、決定を書く
# 代わりにこれを使ってntfy/terminalで殿へ問う。hookは殿の返答(将軍が
# `allow --by lord`/`deny --by lord`として転記した決定)が来るまで
# ポーリングを継続し、timeout内に届かなければ通常モーダルへ落ちる
# (既存のtimeout機構をそのまま使う)。
#
# ★--reason には禁止だけでなく「通ってよい代替手段」を含めて書くこと
#   (agentへそのまま返るため。instructions/roles/karo_role.mdの同原則)。
#
# テスト用環境変数:
#   __PERMISSION_DECIDE_ROOT — プロジェクトroot上書き
#
set -uo pipefail

ROOT="${__PERMISSION_DECIDE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PYTHON="$ROOT/.venv/bin/python3"
REQUESTS_DIR="$ROOT/queue/state/permission_requests"
DECISIONS_DIR="$ROOT/queue/state/permission_decisions"

usage() {
    echo "使い方: permission_decide.sh <request_id> <deny|allow> --by <shogun|lord> --reason <文> [--machine-check <証跡ファイル>] [--lord-channel <ntfy|terminal>]" >&2
    echo "        permission_decide.sh inquire <request_id> --by shogun --channel <ntfy|terminal>" >&2
}

# ─── inquire サブコマンド(将軍裁定(iii)・決定ではない) ───
# 通常の <request_id> <decision> 位置引数とは順序が異なる(第1引数が
# "inquire"固定)ため、通常経路より前で検出して独立に処理する。
if [ "${1:-}" = "inquire" ]; then
    shift
    INQUIRE_REQUEST_ID="${1:-}"
    if [ -z "$INQUIRE_REQUEST_ID" ]; then
        echo "エラー: request_id は必須である" >&2
        exit 1
    fi
    shift
    case "$INQUIRE_REQUEST_ID" in
        *[!A-Za-z0-9_]*)
            echo "エラー: request_id に許可されない文字が含まれる(英数字・アンダースコアのみ許可): ${INQUIRE_REQUEST_ID}" >&2
            exit 1
            ;;
    esac

    INQUIRE_BY=""
    INQUIRE_CHANNEL=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --by)
                INQUIRE_BY="${2:-}"
                shift 2
                ;;
            --channel)
                INQUIRE_CHANNEL="${2:-}"
                shift 2
                ;;
            *)
                echo "エラー: 未知の引数: $1" >&2
                exit 1
                ;;
        esac
    done

    if [ "$INQUIRE_BY" != "shogun" ]; then
        echo "エラー: inquire の --by は shogun のみ許可される: ${INQUIRE_BY}" >&2
        exit 1
    fi
    case "$INQUIRE_CHANNEL" in
        ntfy|terminal) ;;
        *)
            echo "エラー: --channel は ntfy|terminal のいずれかでなければならない: ${INQUIRE_CHANNEL}" >&2
            exit 1
            ;;
    esac

    INQUIRE_RECORD="$REQUESTS_DIR/${INQUIRE_REQUEST_ID}.yaml"
    if [ ! -f "$INQUIRE_RECORD" ]; then
        echo "エラー: 対応する記録ファイルが存在しない(request_idを確認せよ): ${INQUIRE_RECORD}" >&2
        exit 1
    fi

    INQUIRE_SENT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if ! "$PYTHON" - "$INQUIRE_RECORD" "$INQUIRE_CHANNEL" "$INQUIRE_BY" "$INQUIRE_SENT_AT" <<'PYEOF'
import sys
import os
import tempfile
import yaml

path, channel, by, sent_at = sys.argv[1:5]

try:
    with open(path, encoding='utf-8') as f:
        doc = yaml.safe_load(f)
except Exception:
    sys.exit(1)

if not isinstance(doc, dict):
    sys.exit(1)

doc['inquiry'] = {'sent_at': sent_at, 'channel': channel, 'by': by}

directory = os.path.dirname(path)
try:
    fd, tmp_path = tempfile.mkstemp(dir=directory, suffix='.tmp')
except Exception:
    sys.exit(1)
try:
    with os.fdopen(fd, 'w', encoding='utf-8') as f:
        yaml.safe_dump(doc, f, default_flow_style=False, allow_unicode=True,
                        sort_keys=False)
    os.replace(tmp_path, path)
except Exception:
    try:
        os.unlink(tmp_path)
    except OSError:
        pass
    sys.exit(1)
PYEOF
    then
        echo "エラー: 問い合わせの記録に失敗した(記録ファイルの読み書きを確認せよ)" >&2
        exit 1
    fi

    echo "問い合わせを記録した: request_id=${INQUIRE_REQUEST_ID} channel=${INQUIRE_CHANNEL} by=${INQUIRE_BY}"
    exit 0
fi

if [ $# -lt 2 ]; then
    usage
    exit 1
fi

REQUEST_ID="$1"
DECISION="$2"
shift 2

BY=""
REASON=""
MACHINE_CHECK=""
LORD_CHANNEL=""

while [ $# -gt 0 ]; do
    case "$1" in
        --by)
            BY="${2:-}"
            shift 2
            ;;
        --reason)
            REASON="${2:-}"
            shift 2
            ;;
        --machine-check)
            MACHINE_CHECK="${2:-}"
            shift 2
            ;;
        --lord-channel)
            LORD_CHANNEL="${2:-}"
            shift 2
            ;;
        *)
            echo "エラー: 未知の引数: $1" >&2
            usage
            exit 1
            ;;
    esac
done

# ─── request_id の安全性検査(path traversal防止。実形式は
#     agent_id+UTC時刻+sha256先頭8文字であり英数字・アンダースコアのみ) ───
if [ -z "$REQUEST_ID" ]; then
    echo "エラー: request_id は必須である" >&2
    exit 1
fi
case "$REQUEST_ID" in
    *[!A-Za-z0-9_]*)
        echo "エラー: request_id に許可されない文字が含まれる(英数字・アンダースコアのみ許可): ${REQUEST_ID}" >&2
        exit 1
        ;;
esac

case "$DECISION" in
    deny|allow) ;;
    *)
        echo "エラー: decision は deny|allow のいずれかでなければならない(defer はcmd_775 Phase D redo2で廃止された): ${DECISION}" >&2
        exit 1
        ;;
esac

case "$BY" in
    shogun|lord) ;;
    *)
        echo "エラー: --by は shogun|lord のいずれかでなければならない(必須): ${BY}" >&2
        exit 1
        ;;
esac

if [ -z "$REASON" ]; then
    echo "エラー: --reason は必須である(空文字列不可)" >&2
    exit 1
fi

if [ -n "$LORD_CHANNEL" ]; then
    case "$LORD_CHANNEL" in
        ntfy|terminal) ;;
        *)
            echo "エラー: --lord-channel は ntfy|terminal のいずれかでなければならない: ${LORD_CHANNEL}" >&2
            exit 1
            ;;
    esac
fi

# ─── allowの権限検証(fail-closed。デフォルトへの自動降格はしない) ───
if [ "$DECISION" = "allow" ] && [ "$BY" = "shogun" ]; then
    if [ -z "$MACHINE_CHECK" ]; then
        echo "エラー: --by shogun によるallowは --machine-check の証跡が必須である(cmd_754の教訓: 画面を見て安全そうは不可)" >&2
        exit 1
    fi
    if [ ! -f "$MACHINE_CHECK" ] || [ ! -r "$MACHINE_CHECK" ]; then
        echo "エラー: --machine-check の証跡ファイルが実在しないか読み取れない: ${MACHINE_CHECK}" >&2
        exit 1
    fi
    REQUEST_RECORD="$REQUESTS_DIR/${REQUEST_ID}.yaml"
    if [ ! -f "$REQUEST_RECORD" ]; then
        echo "エラー: 対応する記録ファイルが存在しない(request_idを確認せよ): ${REQUEST_RECORD}" >&2
        exit 1
    fi
    if ! "$PYTHON" - "$REQUEST_RECORD" "$MACHINE_CHECK" <<'PYEOF' 2>/dev/null
import sys
import yaml

request_record_path, evidence_path = sys.argv[1], sys.argv[2]

try:
    with open(request_record_path, encoding='utf-8') as f:
        request_doc = yaml.safe_load(f)
except Exception:
    sys.exit(1)

if not isinstance(request_doc, dict):
    sys.exit(1)

tool_input = request_doc.get('tool_input')
if not isinstance(tool_input, dict):
    sys.exit(1)
command = tool_input.get('command')
if not isinstance(command, str) or not command:
    sys.exit(1)

try:
    with open(evidence_path, encoding='utf-8') as f:
        evidence = yaml.safe_load(f)
except Exception:
    sys.exit(1)

if not isinstance(evidence, dict):
    sys.exit(1)

checked_command = evidence.get('checked_command')
verdict = evidence.get('verdict')

# 部分一致・キーワード一致では受理しない(cmd_754の教訓)。完全一致のみ。
if not isinstance(checked_command, str):
    sys.exit(1)
if checked_command != command:
    sys.exit(1)
if verdict != 'PASS':
    sys.exit(1)

sys.exit(0)
PYEOF
    then
        echo "エラー: --machine-check の証跡が受理条件を満たさない(検査対象コマンドが記録ファイルのtool_input.commandと不一致、verdictがPASSでない、または記録/証跡ファイルが読み取れない、のいずれか)" >&2
        exit 1
    fi
fi
# --by lord のallowは無条件で受理する(machine-checkが与えられていても
# 無視してよい)。

# ─── 決定ファイルの原子的書込み(1 request 1 決定・ln によるEEXIST検知) ───
mkdir -p "$DECISIONS_DIR" || {
    echo "エラー: 決定ディレクトリの作成に失敗した: ${DECISIONS_DIR}" >&2
    exit 1
}

DECIDED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
FINAL_PATH="$DECISIONS_DIR/${REQUEST_ID}.yaml"

TMP="$(mktemp "$DECISIONS_DIR/.tmp.XXXXXX")" || {
    echo "エラー: 一時ファイルの作成に失敗した" >&2
    exit 1
}

if ! "$PYTHON" - "$TMP" "$REQUEST_ID" "$DECISION" "$BY" "$REASON" \
        "${MACHINE_CHECK:-}" "${LORD_CHANNEL:-}" "$DECIDED_AT" <<'PYEOF'
import sys
import yaml

(tmp_path, request_id, decision, by, reason,
 machine_check, lord_channel, decided_at) = sys.argv[1:9]

doc = {
    'request_id': request_id,
    'decision': decision,
    'by': by,
    'reason': reason,
    'machine_check': machine_check or None,
    'lord_channel': lord_channel or None,
    'decided_at': decided_at,
}

with open(tmp_path, 'w', encoding='utf-8') as f:
    yaml.safe_dump(doc, f, default_flow_style=False, allow_unicode=True,
                    sort_keys=False)
PYEOF
then
    rm -f "$TMP"
    echo "エラー: 決定内容の書込みに失敗した" >&2
    exit 1
fi

if ! ln "$TMP" "$FINAL_PATH" 2>/dev/null; then
    rm -f "$TMP"
    echo "エラー: request_id=${REQUEST_ID} は既に決定済みである(上書き不可)" >&2
    exit 1
fi
rm -f "$TMP"

echo "決定を記録した: request_id=${REQUEST_ID} decision=${DECISION} by=${BY}"
exit 0
