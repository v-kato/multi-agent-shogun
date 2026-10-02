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
#   とは別物)へ`hook_result: {outcome: allow|deny|defer_timeout|failed|aborted,
#   returned_at: <UTC>}`を原子的に追記してから終了する(`finish()`関数)。
#   inbox_watcher.shの打鍵抑制guardは、この`hook_result`が書かれるまで
#   解除しない。記録ファイル自体が書けなかった失敗(記録作成前の失敗)は
#   追記対象が無いため対象外。hook_result書込みの成否は、決定そのものの
#   送達(allow/denyのstdout出力・exit code)を変えない(bookkeeping失敗
#   のためにallow/denyの送達を止めては本末転倒であるため)。
#
# ★cmd_799 ④: 手動のNo/Escでモーダルが閉じられると、Claude Codeはhookを
#   (SIGTERM系で)終了させ、hookはfinish()を通らずEXIT trapだけで退出する
#   (実測: context/cmd_775_manual_answer_test.md Case B/B2)。この経路でも
#   結果が記録されないとguardがfail-safe timeout(約30分)まで解けないため、
#   EXIT trapが「記録ファイル作成後・finish()未経由」の退出に限り
#   `outcome: aborted`を記帳する。記帳は check-and-set(記録に既に
#   hook_resultがあれば何も書かない)であり、通常退出経路との二重記帳は
#   起きない。判定(allow/deny)の中身・timeout値は変えない。
#
# ★cmd_799 ④ 堅牢化(QC REDO: 隔離実機22回で17回しか記録されなかった。
#   context/cmd_799_hook_qc.md §1)。Claude Codeは中断時にSIGTERMを送り、
#   約1.4秒後にSIGKILL(trap不能)で止める。この約1.4秒の猶予に確実に収める
#   ため次の3点を取る:
#   (1) TERM/HUP/INTを明示的にtrapして`exit`し、EXIT trapへ確実に入る。
#       待機は`sleep & wait`の中断可能な待ちにする(前景のsleepだと、bashだけに
#       signalが来た場合にsleepが終わるまでtrapが遅れる)。
#   (2) trap内の記帳はbash組込みだけで行う(python・date等の外部プロセスを
#       起動しない)。check-and-setは記録を先に読んで`^hook_result:`行の有無を
#       見る(watcherと同じ判定)。追記は`>>`の1回(O_APPEND)。
#   (3) 退出処理中に届く追加のsignalで記帳が途切れぬよう、trap内では
#       TERM/HUP/INTを無視する。
#   それでも、猶予内にSIGKILLが先行する場合は原理的に記録できない(trap不能)。
#   その場合は従来どおりfail-safe timeoutが解除し、孤児記録の退避手順
#   (scripts/permission_orphans.sh・cmd_799 ⑤)が受け皿になる。
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

# ─── hook_result記帳 + EXIT trap(cmd_799 ④) ───
# HOOK_RECORD_PATH: 記録ファイルの書込みに成功した後でだけ設定する(それ以前の
#   失敗・早期exitでは記帳対象が無いため、trapは何も記帳しない)。
# HOOK_RESULT_HANDLED: finish()が結果記帳を終えたら1(記帳の試行後に立てる。
#   立てた後はtrapは再記帳しない=allow/deny/defer_timeout/failedを後から
#   abortedで上書き・二重記帳しない)。記帳の途中でsignalが来た場合は
#   立っていないのでtrapがabortedを記帳する。どちらの記帳もファイル側の
#   check-and-set(`hook_result`の有無)が第2の防壁になる。
HOOK_RECORD_PATH=""
HOOK_RESULT_HANDLED=0

# 通常の退出経路(finish)用。記録ファイルへ`hook_result: {outcome,
# returned_at}`を原子的に追記する。
# 既に`hook_result`があれば何も書かない(1記録につき高々1回)。既存フィールド
# (agent_id・session_id・tool_input等)は読み込んだdictへの追加のみで上書き・
# 削除しない(mkstemp→os.replaceで記録ファイル書込みと同じ原子性を保つ)。
# 失敗しても呼出し元の退出(exit code・stdout)には影響させない。
# ★python起動を伴い遅い(静穏時 約45ms・負荷時 約200ms)ため、SIGTERM後の
#   約1.4秒の猶予に収める必要がある中断経路(EXIT trap)では使わない
#   (→ write_hook_result_aborted)。
write_hook_result() {
    local outcome="$1"
    local returned_at
    returned_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    "$PYTHON" - "$HOOK_RECORD_PATH" "$outcome" "$returned_at" \
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

# check-and-set: 既に結果が記帳されていれば二重に書かない。
if 'hook_result' in doc:
    sys.exit(0)

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
    return 0
}

# 中断経路(EXIT trap)用。`outcome: aborted`の`hook_result`を、bash組込み
# だけで(外部プロセスを起動せず)記録ファイルの末尾へ追記する。
# - check-and-set: 記録を先に読み、トップレベルに`hook_result:`行が既にあれば
#   何も書かない(watcherの`^hook_result:`と同じ判定・二重記帳しない)。
# - 追記は`>>`の1回(O_APPEND)でwrite(2)も1回。bashのprintfは改行ごとにwrite(2)
#   を分けて出す(strace実測)ため、中途半端な記録を残さぬよう末尾の改行1つだけの
#   1行(YAMLのフロー形式。yaml.safe_loadでは通常の`hook_result`と同じdict)で書く。
#   returned_atはpython記帳と同じ単引用符付きの文字列(UTC)。記録(末尾は改行)の
#   既存フィールドには触れない。
# - 記録ファイルが無ければ何もしない(`>>`が記録を新規作成するのを防ぐ)。
# 失敗しても退出(exit code・stdout)には影響させない。
write_hook_result_aborted() {
    local content='' returned_at=''
    [ -f "$HOOK_RECORD_PATH" ] || return 0
    IFS= read -r -d '' content 2>/dev/null < "$HOOK_RECORD_PATH"
    case $'\n'"$content" in
        *$'\n'hook_result:*) return 0 ;;
    esac
    TZ=UTC printf -v returned_at '%(%Y-%m-%dT%H:%M:%SZ)T' -1
    printf "hook_result: {outcome: aborted, returned_at: '%s'}\n" "$returned_at" \
        >> "$HOOK_RECORD_PATH" 2>/dev/null
    return 0
}

# EXIT trap: 記録作成後にfinish()を経ず退出する場合(手動No/Escに伴うhook終了
# =SIGTERM系など)は outcome=aborted を記帳し、その後でstdin退避fileを消す
# (記帳を最優先にする)。trap内ではexitを呼ばない(元の退出状態を変えない)。
# 退出処理中に届く追加のsignal(重ねてのTERM等)で記帳が途切れぬよう、まず
# TERM/HUP/INTを無視にする。
cleanup_on_exit() {
    trap '' TERM HUP INT
    if [ -n "$HOOK_RECORD_PATH" ] && [ "$HOOK_RESULT_HANDLED" -ne 1 ]; then
        write_hook_result_aborted
    fi
    rm -f "$STDIN_TMP"
}
trap cleanup_on_exit EXIT
# TERM/HUP/INTを明示的にtrapして`exit`し、EXIT trapへ確実に入る(既定の
# 動作任せだとEXIT trapへ入る前にSIGKILLが先行して記録されない実測がある)。
# 終了コードは慣例の128+signal(Claude Codeはexit 2だけをblocking扱いとし、
# 129/130/143は通常のnon-blocking errorとして扱われる)。
trap 'exit 143' TERM
trap 'exit 129' HUP
trap 'exit 130' INT
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

# ─── 記録ファイル作成済み: 以後の退出はhook_resultを記帳する(将軍裁定(ii)) ───
# 記録ファイルが実在することが保証された(直前のブロックで書込み成功)
# ので、ここからEXIT trapのabortedフォールバックも有効にする(cmd_799 ④)。
HOOK_RECORD_PATH="$REQUESTS_DIR/${REQUEST_ID}.yaml"

# 通常の退出経路で呼ぶ。結果記帳(write_hook_result)を終えてから終了する。
# HOOK_RESULT_HANDLEDは記帳の試行後に立てる: trapがabortedで重ねて記帳しない
# ため(bookkeeping失敗でもallow/denyの送達は変えない・outcomeを誤記しない)。
# 記帳の途中でsignalが来た場合は未設定のままtrapへ入り、trapのabortedが
# 記録を残す(結果が何も記録されず guardが長く残るよりよい)。
finish() {
    local outcome="$1"
    local exit_code="$2"
    write_hook_result "$outcome"
    HOOK_RESULT_HANDLED=1
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
    # 中断可能な待ち(cmd_799 ④): 前景のsleepだと、bashだけにTERMが来た場合に
    # sleepが終わるまでtrapが遅れる。`wait`はtrap済みsignalで即座に戻る。
    # sleepはstdout/stderrを掴ませない(残ってもhookのpipeを塞がない)。
    sleep "$POLL_INTERVAL_SECONDS" >/dev/null 2>&1 &
    wait $!
done

# deadline到達: 決定が届かなかった。fail-closed(通常モーダルへ委ねる)。
finish defer_timeout 1
