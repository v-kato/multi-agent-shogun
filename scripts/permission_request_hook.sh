#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# scripts/permission_request_hook.sh — PermissionRequest hook (cmd_775 Phase C)
# ═══════════════════════════════════════════════════════════════
#
# 足軽・家老・軍師(Claude系のみ)の確認モーダル停止を、PermissionRequest
# hookで指揮系統へデータとしてルーティングする(打鍵は一切発生しない)。
# 将軍自身のpaneは対象外(agent_id=="shogun"なら即座に何も出力せずexit 1)。
#
# 設計: context/cmd_775_phaseA_design.md §5。仕様: instructions/common/
# protocol.md「権限要求ルーティング (cmd_775)」節。将軍裁定:
# queue/shogun_to_karo.yaml cmd_775 の shogun_ruling_20260917_phase1_go
# (a)〜(e)。
#
# ★あらゆる失敗で「何も出力せずexit 1」に倒れる(=Claude Codeの通常の
#   permission flow〈確認モーダル〉へフォールバック。公式仕様: exit≠0は
#   non-blocking errorとして扱われ通常flowへ落ちる)。
#   `"behavior": "allow"` を出力するコードパスは本ファイル中に1箇所のみ
#   存在する(下記「決定ファイルポーリング」セクションのpython内)。
#
# ★将軍裁定(ii)(cmd_775 Phase D redo2): 記録ファイル書込み成功後の
#   あらゆる退出経路は、退出**直前**に記録ファイル(queue/state/
#   permission_requests/<request_id>.yaml。decide.shが書く決定ファイル
#   とは別物)へ`hook_result: {outcome: allow|deny|defer_timeout|failed,
#   returned_at: <UTC>}`を原子的に追記してから終了する(`finish()`関数)。
#   inbox_watcher.shの打鍵抑制guardは、この`hook_result`が書かれるまで
#   解除しない。記録ファイル自体が書けなかった失敗(記録作成前の失敗)は
#   追記対象が無いため対象外。hook_result書込みの成否は、決定そのものの
#   送達(allow/denyのstdout出力・exit code)を変えない(bookkeeping失敗
#   のためにallow/denyの送達を止めては本末転倒であるため)。
#
# 入力: stdin JSON (hook input)。出力: 成功時のみ stdout に
#   hookSpecificOutput JSON。失敗時は何も出力せず exit 1。
#
# テスト用環境変数 (production では未設定。__ 始まりは全てtest専用):
#   __PERMISSION_HOOK_ROOT                  — プロジェクトroot上書き
#   __PERMISSION_HOOK_AGENT_ID              — agent_id上書き(設定時はtmuxを
#                                             呼ばない。空文字列でも「設定
#                                             扱い」となりtmux解決をskipする)
#   __PERMISSION_HOOK_POLL_INTERVAL_SECONDS — ポーリング間隔上書き(既定5)
#   __PERMISSION_HOOK_MARGIN_SECONDS        — timeoutからの安全マージン
#                                             上書き(既定10)
#   __PERMISSION_HOOK_UTC_TS_OVERRIDE       — request_id内のUTC時刻部分の
#                                             上書き(複数回のhook起動間で
#                                             request_idを決定的に揃える
#                                             ためのtest専用フック)
#
# 本番用環境変数(.claude/settings.json の command 文字列内でexportする。
# settings.json側の当該hookの"timeout"フィールドと必ず同じ数値にすること
# — 同一JSONオブジェクト内に両方が並ぶため、二重管理をgrep/目視で即座に
# 確認できる。詳細はtests/unit/test_permission_request_hook_settings.bats):
#   PERMISSION_HOOK_TIMEOUT_SECONDS — このhook自身のtimeout値(既定1800)
#
set -uo pipefail

ROOT="${__PERMISSION_HOOK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PYTHON="$ROOT/.venv/bin/python3"

TIMEOUT_SECONDS="${PERMISSION_HOOK_TIMEOUT_SECONDS:-1800}"
POLL_INTERVAL_SECONDS="${__PERMISSION_HOOK_POLL_INTERVAL_SECONDS:-5}"
MARGIN_SECONDS="${__PERMISSION_HOOK_MARGIN_SECONDS:-10}"

REQUESTS_DIR="$ROOT/queue/state/permission_requests"
DECISIONS_DIR="$ROOT/queue/state/permission_decisions"

# ─── stdin全文を一時fileへ退避する ───
# python へ `-` で script 本体を heredoc 渡しすると stdin は script 側に
# 消費されるため、hook自身の stdin(hook入力JSON)は file 経由で渡す。
STDIN_TMP="$(mktemp)" || exit 1
trap 'rm -f "$STDIN_TMP"' EXIT
cat > "$STDIN_TMP" || exit 1

# ─── 手順1: JSON parse + 必須field検証(fail-closed) ───
PARSE_OUT="$("$PYTHON" - "$STDIN_TMP" <<'PYEOF' 2>/dev/null
import sys
import json
import shlex

path = sys.argv[1]
with open(path, encoding='utf-8') as f:
    raw = f.read()

try:
    data = json.loads(raw)
except Exception:
    sys.exit(1)

if not isinstance(data, dict):
    sys.exit(1)

session_id = data.get('session_id')
tool_name = data.get('tool_name')
cwd = data.get('cwd')
tool_input = data.get('tool_input')

if not isinstance(session_id, str) or not session_id:
    sys.exit(1)
if not isinstance(tool_name, str) or not tool_name:
    sys.exit(1)
if not isinstance(cwd, str) or not cwd:
    sys.exit(1)
if not isinstance(tool_input, dict):
    sys.exit(1)

tool_use_id = data.get('tool_use_id')
if not isinstance(tool_use_id, str):
    tool_use_id = ''

# permission_suggestions は出現が不安定と実測されている(cmd_775 redo1)。
# 一切ロジックに依存せず、存在すれば記録に転記するだけの値として扱う。
permission_suggestions = data.get('permission_suggestions')
permission_suggestions_json = ''
if permission_suggestions is not None:
    try:
        permission_suggestions_json = json.dumps(permission_suggestions)
    except Exception:
        permission_suggestions_json = ''

tool_input_json_raw = json.dumps(tool_input, ensure_ascii=False)
tool_input_json_canonical = json.dumps(tool_input, sort_keys=True, ensure_ascii=False)


def emit(name, value):
    print(f'{name}={shlex.quote(value)}')


emit('HOOK_SESSION_ID', session_id)
emit('HOOK_TOOL_USE_ID', tool_use_id)
emit('HOOK_TOOL_NAME', tool_name)
emit('HOOK_CWD', cwd)
emit('HOOK_TOOL_INPUT_JSON', tool_input_json_raw)
emit('HOOK_TOOL_INPUT_JSON_CANONICAL', tool_input_json_canonical)
emit('HOOK_PERMISSION_SUGGESTIONS_JSON', permission_suggestions_json)
PYEOF
)"
if [ $? -ne 0 ] || [ -z "$PARSE_OUT" ]; then
    exit 1
fi
eval "$PARSE_OUT"

# ─── 手順2: 自pane判定(agent_id解決。将軍裁定(a): tool_use_id・
#     permission_suggestionsのいずれにも依存しない) ───
if [ -n "${__PERMISSION_HOOK_AGENT_ID+x}" ]; then
    AGENT_ID="$__PERMISSION_HOOK_AGENT_ID"
elif [ -n "${TMUX_PANE:-}" ]; then
    AGENT_ID="$(tmux display-message -t "$TMUX_PANE" -p '#{@agent_id}' 2>/dev/null)" || AGENT_ID=""
else
    AGENT_ID=""
fi

if [ -z "$AGENT_ID" ]; then
    exit 1   # fail-closed: agent_id 取得失敗(TMUX_PANE未設定・tmux失敗等)
fi

if [ "$AGENT_ID" = "shogun" ]; then
    # 殿の端末の確認を横取りしない。記録ファイル・inbox通知は一切行わない。
    exit 1
fi

# ─── 手順3〜5: request_id組み立て + 記録ファイルの原子的書込み ───
# 将軍裁定(a): record IDは agent_id + UTC時刻 + sha256(session_id+tool_input)
# 先頭8文字。tool_use_idは7回全ての実測で欠落したため依存しない。
HASH8="$(printf '%s' "${HOOK_SESSION_ID}${HOOK_TOOL_INPUT_JSON_CANONICAL}" | sha256sum | cut -c1-8)"
# __PERMISSION_HOOK_UTC_TS_OVERRIDE はtest専用: 複数回のhook起動間で
# request_id(ひいてはrequest_id依存の決定ファイルpath)を決定的に
# 揃えるためだけに存在し、productionでは未設定(通常のdate -uを使う)。
UTC_TS="${__PERMISSION_HOOK_UTC_TS_OVERRIDE:-$(date -u +%Y%m%dT%H%M%SZ)}"
REQUEST_ID="${AGENT_ID}_${UTC_TS}_${HASH8}"
RECEIVED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TASK_YAML_PATH="$ROOT/queue/tasks/${AGENT_ID}.yaml"

if ! "$PYTHON" - \
        "$REQUEST_ID" "$AGENT_ID" "$HOOK_SESSION_ID" "$HOOK_TOOL_USE_ID" \
        "$HOOK_TOOL_NAME" "$HOOK_CWD" "$HOOK_TOOL_INPUT_JSON" \
        "$HOOK_PERMISSION_SUGGESTIONS_JSON" "$TASK_YAML_PATH" \
        "$REQUESTS_DIR" "$RECEIVED_AT" \
        >/dev/null 2>/dev/null <<'PYEOF'
import sys
import os
import json
import tempfile
import yaml

(request_id, agent_id, session_id, tool_use_id, tool_name, cwd,
 tool_input_json, permission_suggestions_json, task_yaml_path,
 output_dir, received_at) = sys.argv[1:12]

try:
    tool_input = json.loads(tool_input_json)
except Exception:
    sys.exit(1)

permission_suggestions = None
if permission_suggestions_json:
    try:
        permission_suggestions = json.loads(permission_suggestions_json)
    except Exception:
        permission_suggestions = None

# task_id/parent_cmd は queue/tasks/<agent>.yaml から読む。無ければ(または
# 形式不正なら)両方 null とし、それ以上の推測はしない。
task_id = None
parent_cmd = None
if os.path.isfile(task_yaml_path):
    try:
        with open(task_yaml_path, encoding='utf-8') as f:
            task_doc = yaml.safe_load(f)
        task = task_doc.get('task') if isinstance(task_doc, dict) else None
        if isinstance(task, dict):
            task_id = task.get('task_id')
            parent_cmd = task.get('parent_cmd')
    except Exception:
        task_id = None
        parent_cmd = None

record = {
    'request_id': request_id,
    'agent_id': agent_id,
    'session_id': session_id,
    'tool_use_id': tool_use_id or None,
    'permission_suggestions': permission_suggestions,
    'tool_name': tool_name,
    'tool_input': tool_input,
    'cwd': cwd,
    'task_id': task_id,
    'parent_cmd': parent_cmd,
    'received_at': received_at,
}

try:
    os.makedirs(output_dir, exist_ok=True)
except Exception:
    sys.exit(1)

final_path = os.path.join(output_dir, request_id + '.yaml')
try:
    fd, tmp_path = tempfile.mkstemp(dir=output_dir, suffix='.tmp')
except Exception:
    sys.exit(1)
try:
    with os.fdopen(fd, 'w', encoding='utf-8') as f:
        yaml.safe_dump(record, f, default_flow_style=False, allow_unicode=True,
                        sort_keys=False)
    os.replace(tmp_path, final_path)
except Exception:
    try:
        os.unlink(tmp_path)
    except OSError:
        pass
    sys.exit(1)
PYEOF
then
    exit 1   # fail-closed: 記録ファイル書込み失敗(allowへ倒れる経路なし)
fi

# ─── hook_result書込み(将軍裁定(ii)) ───
# 記録ファイルが実在することが保証された(直前のブロックで書込み成功)
# 以後のあらゆる退出経路で呼ぶ。既存フィールド(agent_id・session_id・
# tool_input等)は読み込んだdictへの追加のみで上書き・削除しない
# (mkstemp→os.replaceで記録ファイル書込みと同じ原子性を保つ)。
finish() {
    local outcome="$1"
    local exit_code="$2"
    local returned_at
    returned_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    "$PYTHON" - "$REQUESTS_DIR/${REQUEST_ID}.yaml" "$outcome" "$returned_at" \
        >/dev/null 2>/dev/null <<'PYEOF'
import sys
import os
import tempfile
import yaml

path, outcome, returned_at = sys.argv[1:4]

try:
    with open(path, encoding='utf-8') as f:
        doc = yaml.safe_load(f)
except Exception:
    sys.exit(1)

if not isinstance(doc, dict):
    sys.exit(1)

doc['hook_result'] = {'outcome': outcome, 'returned_at': returned_at}

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
    exit "$exit_code"
}

# ─── 手順6: 家老inbox通知 ───
# 失敗しても処理は継続する(記録ファイルが既に書けており主たる真実源で
# あるため。家老・将軍がdashboard等の別経路で気づいて決定ファイルを書けば
# 後続のポーリングが拾う)。
bash "$ROOT/scripts/inbox_write.sh" karo \
    "権限要求 ${REQUEST_ID}: ${AGENT_ID}が${HOOK_TOOL_NAME}の許可判断を求めている。queue/state/permission_requests/${REQUEST_ID}.yaml を見よ。" \
    permission_request "$AGENT_ID" >/dev/null 2>&1 || true

# ─── 手順7: 決定ファイルをポーリングし、決定に従って返却する ───
# `"behavior": "allow"` を出力するコードパスは、直下のpython内(decision
# ファイルの存在確認→schema検証→decisionフィールドが文字列allow、の
# 3条件が全て真の場合)の1箇所のみである。★将軍裁定(iii)(cmd_775
# Phase D redo2): `defer`は決定の語彙から除外された。decisionがdeny・
# allowのいずれでもない値(旧`defer`を含む)は、下のschema不正判定と
# 同じfail-closed経路へ合流する。
#
# 内側pythonのexit codeは意味づけされた識別子である(0=allow・1=deny・
# 2=schema不正/未知の値=fail-closed)。汎用的な成功/失敗の慣習ではなく、
# 直後のbash側でどのhook_result outcomeを記録するかを一意に決めるための
# 識別子として使う(このpython呼出し1回のみのローカルな取り決め)。
DECISION_FILE="$DECISIONS_DIR/${REQUEST_ID}.yaml"
DEADLINE=$(( TIMEOUT_SECONDS - MARGIN_SECONDS ))
if [ "$DEADLINE" -lt 0 ]; then
    DEADLINE=0
fi

SECONDS=0
while [ "$SECONDS" -lt "$DEADLINE" ]; do
    if [ -f "$DECISION_FILE" ]; then
        OUT="$("$PYTHON" - "$DECISION_FILE" "$REQUEST_ID" <<'PYEOF' 2>/dev/null
import sys
import json
import yaml

path, expected_request_id = sys.argv[1], sys.argv[2]

try:
    with open(path, encoding='utf-8') as f:
        doc = yaml.safe_load(f)
except Exception:
    sys.exit(2)

if not isinstance(doc, dict):
    sys.exit(2)

decision = doc.get('decision')
reason = doc.get('reason')
request_id = doc.get('request_id')

# request_id の相互照合(defense in depth): ファイル名だけでなく本文の
# request_idも一致していることを確認する。
if request_id != expected_request_id:
    sys.exit(2)
if decision not in ('deny', 'allow'):
    sys.exit(2)
if decision == 'deny' and not isinstance(reason, str):
    sys.exit(2)

if decision == 'deny':
    print(json.dumps({
        'hookSpecificOutput': {
            'hookEventName': 'PermissionRequest',
            'decision': {
                'behavior': 'deny',
                'message': reason,
                'interrupt': False,
            },
        }
    }))
    sys.exit(1)

if decision == 'allow':
    print(json.dumps({
        'hookSpecificOutput': {
            'hookEventName': 'PermissionRequest',
            'decision': {'behavior': 'allow'},
        }
    }))
    sys.exit(0)

# 到達不能(直前の判定でdecisionはdeny|allowのいずれかに絞り込み済み)。
# 防御的にfail-closedへ倒す。
sys.exit(2)
PYEOF
)"
        RC=$?
        if [ "$RC" -eq 0 ] && [ -n "$OUT" ]; then
            printf '%s\n' "$OUT"
            finish allow 0
        fi
        if [ "$RC" -eq 1 ] && [ -n "$OUT" ]; then
            printf '%s\n' "$OUT"
            finish deny 0
        fi
        # RC==2(schema不正・旧defer値を含む) / OUTが空、いずれもfail-closed
        finish failed 1
    fi
    sleep "$POLL_INTERVAL_SECONDS"
done

# deadline到達: 決定が届かなかった。fail-closed(通常モーダルへ委ねる)。
finish defer_timeout 1
