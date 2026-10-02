#!/usr/bin/env bash
# lib/claude_session_resume.sh — 出陣やり直し時の Claude 会話 resume (cmd_785)
#
# 目的: Remote Control を常時 ON にした環境では、出陣やり直しのたびに Claude 系
#   agent の数だけ Claude アプリ(Code タブ)へ孤児セッションが残る。撤収の直前に
#   各 agent の会話 ID(sessionId)を採取し、起動時に `claude --resume <id>` で
#   同じ会話を再開すれば、その会話に記録された Remote Control セッションへ
#   再接続され、新しい項目は増えない(cmd_785 Phase 0 PoC:
#   context/cmd_785_resume_poc.md)。
#
# ★opt-in: config/settings.yaml の `cli.claude_session_resume: true` の時だけ働く
#   (未記載・false は無効=従来どおり新規起動)。
# ★採取・照合のどこで失敗しても、その agent は従来の新規起動へ落ちる。出陣は
#   止めない。存在しない ID を渡すと claude は rc=1 で即終了し pane が空になる
#   (PoC §5-3)ため、転写の実在を確かめた ID しか返さない。
# ★それでも `--resume` 起動が起動直後に自ら非0で終わった時(転写の破損・読取後の
#   変化・CLI の拒否など、事前確認で塞げない失敗)は、同じ打鍵1回の中で1回だけ
#   従来の新規起動へ倒す(claude_resume_launch_cmd。cmd_785 G785-Q01)。上限秒数を
#   越えて動いた後の終了・rc=0・signal による終了・resume でない起動は倒さない。
#   経過は単調時計(/proc/uptime)で測り、測れなければ倒さない(cmd_794)。
# ★素の `--resume`・`--resume <name>`・`--continue` は使わない(picker が開く、
#   または同じ cwd の agent 全員が同じ会話を掴む。PoC (iv))。
# ★本ファイルは読み取りと queue/state/ への記録だけを行う。pane への打鍵・
#   プロセスへの signal・~/.claude/ への書込みは一切しない。
# ★cmd_796 の前回スナップショット再利用は別の opt-in
#   (cli.claude_session_resume_previous_snapshot: true。下記)。
#
# ─── 提供関数 ───
#
#   claude_resume_enabled
#       → 0=有効(settings の cli.claude_session_resume が真) 1=無効。
#         lib/cli_adapter.sh の _cli_adapter_read_yaml が無ければ無効。
#   claude_resume_valid_session_id <id>
#       → 0=小文字16進の UUID 形式。値をシェルへ渡す前の検査に使う。
#   claude_resume_project_slug <cwd>
#       → 本体の project dir 名(英数字以外を '-' へ。例 /home/a/x.y → -home-a-x-y)。
#   claude_resume_config_dir
#       → ${CLAUDE_CONFIG_DIR:-$HOME/.claude}
#   claude_resume_proc_starttime <pid>
#       → /proc/<pid>/stat の第22欄(starttime)。
#   claude_resume_child_claude_pid <parent_pid>
#       → parent の直接の子で comm が "claude" のもの。0件・複数件は空。
#   claude_resume_read_record <pid> <agent_id>
#       → sessions/<pid>.json を検証し "OK<TAB>sessionId<TAB>bridgeSessionId" か
#         "NG<TAB>理由" を出力。pid 欄・procStart(現プロセスの starttime)・name・
#         sessionId 形式が全て一致した時だけ OK。
#   claude_resume_snapshot <out_file> <run_token>
#       → 出陣の shogun/multiagent セッションにある Claude 系 pane を走査し、
#         検証を通った agent の sessionId を <out_file> へ atomic に書く
#         (一時ファイル+rename)。セッションが無くても空の記録を書く。
#         Returns: 0=書けた 1=書けなかった。
#   claude_resume_lookup <snapshot_file> <run_token> <agent_id> <launch_cwd>
#       → 同じ出陣(run_token 一致)で採取され、形式が正しく、起動 cwd の
#         project dir に転写 <id>.jsonl が実在する sessionId だけを出力する。
#         Returns: 0=出力あり 1=該当なし(従来の新規起動へ)。
#   claude_resume_launch_cmd <session_id> <resume_cmd> <fresh_cmd>
#       → pane のシェルへ打鍵する起動コマンド(1行)を出力する。常に 0 を返す。
#         session_id が空なら <fresh_cmd> をそのまま出す。<resume_cmd> が
#         <fresh_cmd> に ` --resume <session_id>` を1つ足しただけの形であることなど
#         (下記)を確かめ、満たせば「resume 起動 → 起動から
#         CLAUDE_RESUME_FALLBACK_WINDOW_SEC 秒未満に rc 1〜127 で終わった時だけ
#         <fresh_cmd> を1回」の複合コマンドを出す。満たさなければ <fresh_cmd>
#         をそのまま出す(警告は stderr)。
#
# ─── 前回スナップショットの再利用(cmd_796・別 opt-in・既定 OFF) ───
#
#   WSL 再起動・クラッシュの後の出陣では、撤収前に採る相手(稼働中の claude)が
#   いない。撤収前の観測で対象が確かに「いなかった(absent)」agent に限り、前回の
#   出陣で採った正本(queue/state/claude_session_snapshot.yaml)の ID を、全条件
#   (context/cmd_796_design_review.md §3〜§6)を通した時だけ候補にする。
#   ★正本は「最後の実採取記録」。今回の採取は別ファイル(current)へ書き、同じ出陣の
#     照合(claude_resume_lookup)は current を読む。全対象が absent の時は正本を
#     byte 単位で残し、稼働対象がいた時だけ今回の実採取で置き換える。
#   ★「採れなかった(unknown)」と「いなかった(absent)」を分ける。tmux の非0や
#     空の出力だけで absent を作らない。現生存の Claude は /proc から列挙し、
#     記録の無い・壊れた・照合の合わない生存 Claude が1つでもいれば前回経路を閉じる。
#   ★起動計画(plan)は出陣1回に固定し、全 agent の ID・bridge の重複を拒否する。
#     前回由来の起動だけ、pane が CLI を実行する直前に本ファイルを
#     `--check-previous` で実行し、live 条件と plan・token の一致を再確認する。
#     通れば従来の resume 起動、拒否・エラーなら従来の新規起動を1回だけ。
#
#   claude_resume_previous_enabled
#       → 0=通常 resume(cli.claude_session_resume)と前回再利用
#         (cli.claude_session_resume_previous_snapshot)の両方が真。
#   claude_resume_new_token
#       → 出陣1回の run_token(時刻・PID・乱数 UUID。時計段差で衝突しない)。
#   claude_resume_child_claude_scan <parent_pid>
#       → 直接の子の comm=claude を "ONE <pid>"・"NONE"・"MULTI"・"ERR" の三値+で返す。
#         ps の終了コードを捨てず、0件と読むのは /proc の子一覧で裏取りできた時だけ。
#   claude_resume_live_observe
#       → 同じ実行ユーザーの現生存 Claude を /proc から列挙し JSON 1行で出す
#         ({"ok": 全員の記録を検証できたか, "reasons": [...], "procs": [...]})。
#   claude_resume_plan <canonical> <current> <plan_out> <run_token> <targets> <launch_cwd> <prev_on>
#       → current の同一 run 照合と前回候補の全条件・計画全体の重複排除から
#         起動計画を <plan_out> へ atomic に書き、"PLAN<TAB>agent<TAB>source<TAB>id<TAB>理由"
#         を出す。正本は読むだけ(置換は claude_resume_commit_canonical)。
#   claude_resume_commit_canonical <canonical> <current> <targets>
#       → 全対象が absent なら正本を残し("preserved")、それ以外は current で置換("replaced")。
#   claude_resume_invalidate <canonical> <reason>
#       → 再利用不可の記録を正本へ atomic に書く(--clean・採取失敗)。
#   claude_resume_withdraw_previous <canonical> <run_token> <agent>...
#       → 起動を送ったが live 記録の出現を確かめられなかった前回候補を正本から外す。
#   claude_resume_wait_live_record <pane_pid> <agent_id> <秒>
#       → pane の直接の子 claude の記録が検証できるまで有限時間だけ待つ。
#   claude_resume_previous_check <plan> <run_token> <agent_id> <session_id>
#       → 前回由来の起動の直前確認。0=通過 1=拒否(理由は stderr)。
#   claude_resume_previous_launch_cmd <plan> <run_token> <agent_id> <session_id> <resume_cmd> <fresh_cmd>
#       → 「直前確認 → 通れば claude_resume_launch_cmd の1行、拒否なら新規起動1回」の
#         1行を出す。組めなければ <fresh_cmd> だけ。
#   (実行) bash lib/claude_session_resume.sh --check-previous <plan> <run_token> <agent_id> <session_id>
#       → pane から呼ぶ直前確認の入口。観測の差し替え口は無い(本物の /proc を読む)。
# ═══════════════════════════════════════════════════════════════

CLAUDE_RESUME_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_RESUME_PROJECT_ROOT="$(cd "${CLAUDE_RESUME_LIB_DIR}/.." && pwd)"
# 採取対象の tmux セッション(出陣が kill-session する2つ)
CLAUDE_RESUME_SESSIONS="${CLAUDE_RESUME_SESSIONS:-shogun multiagent}"

# resume 起動の「起動直後」とみなす上限秒数(cmd_785 G785-Q01)。この秒数未満に
# rc 1〜127 で終わった時だけ、1回だけ従来の新規起動へ倒す。環境変数では変えない。
# 根拠:
#   - 起動失敗の実測は約2秒(PoC E: 存在しない ID で 21:37:31 起動 → 21:37:33 に
#     rc=1。context/cmd_785_resume_poc.md)。現存最大の転写(57MB・28204行)の
#     JSON 解析は 0.42 秒(Python で読み取りのみ計測)で、転写の読込を含めても起動
#     失敗は数秒で出る。出陣は Claude 系 agent を最大9本ほぼ同時に起こすため、負荷
#     による遅れへ約10倍の余裕を取る。
#   - resume 後の agent は入力が来るまで作業を始めない。短すぎれば復旧を取り逃して
#     pane が空のまま残る(purpose 違反)一方、長すぎても余分に起こるのは高々1回の
#     新規起動である。この非対称から、例示幅(15〜30秒)の上端を採る。
CLAUDE_RESUME_FALLBACK_WINDOW_SEC=30

# 前回スナップショットの鮮度の上限秒数(cmd_796。7日。ちょうど7日は許可・超過は拒否)。
# 復旧候補を許す運用値であり、bridge の保持期限や時計精度の保証ではない。環境変数では変えない。
CLAUDE_RESUME_PREVIOUS_MAX_AGE_SEC=604800
# 前回由来の起動を送った後、その claude の記録が出るまで待つ上限秒数(cmd_796 §5.2-5)。
# 出ない時は待ちを打ち切り、次の出陣へは「未確定」として渡す(正本から外す)。
CLAUDE_RESUME_SETTLE_SEC=20

_claude_resume_python() {
    local venv_python="${CLAUDE_RESUME_PROJECT_ROOT}/.venv/bin/python3"
    if [ -n "${CLAUDE_RESUME_PYTHON:-}" ]; then
        printf '%s' "$CLAUDE_RESUME_PYTHON"
    elif [ -x "$venv_python" ]; then
        printf '%s' "$venv_python"
    else
        printf '%s' "python3"
    fi
}

claude_resume_enabled() {
    declare -F _cli_adapter_read_yaml >/dev/null 2>&1 || return 1
    local value
    value=$(_cli_adapter_read_yaml "cli.claude_session_resume" "false")
    case "$value" in
        True|true|yes|on|1) return 0 ;;
        *) return 1 ;;
    esac
}

# 前回スナップショットの再利用(cmd_796)は、通常 resume と両方が真の時だけ。
# 真と読む値は claude_resume_enabled と同じ。設定を読めなければ偽(OFF)。
claude_resume_previous_enabled() {
    claude_resume_enabled || return 1
    local value
    value=$(_cli_adapter_read_yaml "cli.claude_session_resume_previous_snapshot" "false")
    case "$value" in
        True|true|yes|on|1) return 0 ;;
        *) return 1 ;;
    esac
}

claude_resume_valid_session_id() {
    [[ "${1:-}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
}

# run_token に使える形(英数字と '-'。シェルへ引用なしで渡せる)
claude_resume_valid_token() {
    [[ "${1:-}" =~ ^[0-9A-Za-z][0-9A-Za-z-]{0,127}$ ]]
}

# 出陣1回の run_token。時刻と PID だけでは時計の段差で前回と衝突し得るため、
# 乱数の UUID を足す(cmd_796 §4-1)。
claude_resume_new_token() {
    local rnd=""
    rnd=$(cat /proc/sys/kernel/random/uuid 2>/dev/null) || rnd=""
    if ! [[ "$rnd" =~ ^[0-9a-f-]{36}$ ]]; then
        rnd=$("$(_claude_resume_python)" -c 'import uuid; print(uuid.uuid4())' 2>/dev/null) || rnd=""
    fi
    [[ "$rnd" =~ ^[0-9a-f-]{36}$ ]] || rnd="${RANDOM}${RANDOM}${RANDOM}"
    printf '%s-%s-%s\n' "$(date +%s)" "$$" "$rnd"
}

# 現在時刻の観測 "現実時計(epoch秒)<TAB>/proc/uptime の先頭値<TAB>boot_id" を1行で出す。
# 読めない値は空。鮮度判定の時計(cmd_796 §6)はここからだけ取る。
_claude_resume_clock() {
    local up="" x="" bid="" wall
    { read -r up x < /proc/uptime; } 2>/dev/null || up=""
    bid=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null) || bid=""
    wall=$(date +%s.%N 2>/dev/null) || wall=""
    [[ "$wall" =~ ^[0-9]+\.[0-9]+$ ]] || wall=$(date +%s 2>/dev/null) || wall=""
    # 空の欄は '-'(タブ区切りの read が空欄を潰して欄がずれないように)
    printf '%s\t%s\t%s\n' "${wall:--}" "${up:--}" "${bid:--}"
}

claude_resume_project_slug() {
    local cwd="${1:-}"
    [ -n "$cwd" ] || return 1
    printf '%s' "${cwd//[^A-Za-z0-9]/-}"
}

claude_resume_config_dir() {
    printf '%s' "${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}"
}

claude_resume_proc_starttime() {
    local pid="${1:-}" stat rest
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    [ -r "/proc/${pid}/stat" ] || return 1
    stat=$(cat "/proc/${pid}/stat" 2>/dev/null) || return 1
    # 第2欄 comm は括弧で囲まれ空白を含み得るため、最後の ") " 以降を切る
    rest="${stat##*) }"
    local -a fields
    read -ra fields <<< "$rest"
    [ -n "${fields[19]:-}" ] || return 1
    printf '%s' "${fields[19]}"
}

# _claude_resume_proc_no_child <pid>
#   /proc/<pid>/task/*/children(全スレッドの直接の子)が全て読めて空なら 0。
#   1つでも読めない・子が1つでもある・スレッドが見つからない(親が既に居ない)なら 1。
#   ps が「0件」と答えた時の裏取りにだけ使う(ps の rc=1 は 0件と失敗を区別できない)。
_claude_resume_proc_no_child() {
    local pid="${1:-}" f kids seen=0
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    for f in /proc/"$pid"/task/*/children; do
        [ -f "$f" ] || return 1
        kids=$(cat "$f" 2>/dev/null) || return 1
        [ -z "${kids//[[:space:]]/}" ] || return 1
        seen=1
    done
    [ "$seen" -eq 1 ]
}

# 直接の子の comm=claude を数え、"ONE <pid>"・"NONE"(0件)・"MULTI"(複数)・
# "ERR"(探索できない)のどれかを1行で出す(cmd_796 §3.2: 0件と探索失敗を区別する)。
#   先に親が ps で見えることを確かめ、子一覧の ps は終了コードを保持して読む
#   (G796-Q01: 終了コードを捨てると、出力の無い失敗が 0件に化ける)。
#   rc=0: 標準エラーも同じ出力で受け、"pid comm" の形でない行が1行でもあるか、
#         行が1つも無ければ探索失敗。
#   rc=1: ps は選択が0件の時も、オプションの誤り等の失敗の時も 1 を返す。何も出ず、
#         かつ /proc の子一覧で 0件を裏取りできた時だけ 0件。それ以外は探索失敗。
#   それ以外(2 以上・signal 相当の 128 以上): 探索失敗。
claude_resume_child_claude_scan() {
    local parent_pid="${1:-}" out rc=0 pid comm found="" n=0 rows=0
    case "$parent_pid" in ''|*[!0-9]*) echo "ERR"; return 0 ;; esac
    if ! ps -p "$parent_pid" -o pid= >/dev/null 2>&1; then
        echo "ERR"
        return 0
    fi
    out=$(ps --ppid "$parent_pid" -o pid=,comm= 2>&1) || rc=$?
    case "$rc" in
        0) ;;
        1)
            if [ -z "$out" ] && _claude_resume_proc_no_child "$parent_pid"; then
                echo "NONE"
            else
                echo "ERR"
            fi
            return 0
            ;;
        *) echo "ERR"; return 0 ;;
    esac
    while read -r pid comm; do
        [ -n "$pid" ] || continue
        case "$pid" in *[!0-9]*) echo "ERR"; return 0 ;; esac
        [ -n "$comm" ] || { echo "ERR"; return 0; }
        rows=$((rows + 1))
        [ "$comm" = "claude" ] || continue
        n=$((n + 1))
        found="$pid"
    done <<< "$out"
    [ "$rows" -gt 0 ] || { echo "ERR"; return 0; }
    case "$n" in
        0) echo "NONE" ;;
        1) echo "ONE $found" ;;
        *) echo "MULTI" ;;   # 複数該当は判定不能(どれか1つを選ぶと別 agent の会話を掴み得る)
    esac
}

claude_resume_child_claude_pid() {
    local scan
    scan=$(claude_resume_child_claude_scan "${1:-}")
    case "$scan" in
        "ONE "*) echo "${scan#ONE }" ;;
        *) echo "" ;;
    esac
}

claude_resume_read_record() {
    local pid="${1:-}" agent_id="${2:-}" starttime record
    case "$pid" in ''|*[!0-9]*) printf 'NG\tinvalid_pid\n'; return 1 ;; esac
    [ -n "$agent_id" ] || { printf 'NG\tno_agent_id\n'; return 1; }
    record="$(claude_resume_config_dir)/sessions/${pid}.json"
    [ -f "$record" ] || { printf 'NG\tno_record\n'; return 1; }
    starttime=$(claude_resume_proc_starttime "$pid") || { printf 'NG\tno_process\n'; return 1; }

    local out
    out=$("$(_claude_resume_python)" - "$record" "$pid" "$agent_id" "$starttime" <<'PY' 2>/dev/null
import json, re, sys
path, pid, agent_id, starttime = sys.argv[1:5]
UUID = re.compile(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
BRIDGE = re.compile(r'^session_[A-Za-z0-9]+$')
def ng(reason):
    print("NG\t" + reason)
    sys.exit(0)
try:
    with open(path, encoding="utf-8") as f:
        d = json.load(f)
except Exception:
    ng("broken_record")
if not isinstance(d, dict):
    ng("broken_record")
rec_pid = d.get("pid")
if not isinstance(rec_pid, int) or isinstance(rec_pid, bool) or rec_pid != int(pid):
    ng("pid_mismatch")
if str(d.get("procStart")) != starttime:
    ng("proc_start_mismatch")
if d.get("name") != agent_id:
    ng("name_mismatch")
sid = d.get("sessionId")
if not isinstance(sid, str) or not UUID.match(sid):
    ng("invalid_session_id")
bridge = d.get("bridgeSessionId")
if not isinstance(bridge, str) or not BRIDGE.match(bridge):
    bridge = ""
print("OK\t" + sid + "\t" + bridge)
PY
    )
    [ -n "$out" ] || { printf 'NG\tread_failed\n'; return 1; }
    printf '%s\n' "$out"
    [ "${out%%$'\t'*}" = "OK" ]
}

# ─── 判定・記録の本体(Python。cmd_796) ───
# 1つのプログラムを mode 別に呼ぶ(_claude_resume_py <mode> ...)。値は argv と stdin で
# 受け、シェルへは検査済みの値だけを返す。読取りの失敗・破損は全て「使わない」側へ倒す。
#   live      : 同じ実行ユーザーの現生存 Claude を /proc から列挙(cmd_796 §5.1)
#   snapshot  : 採取結果を三値の観測付きで atomic に書く(cmd_785 の採取の書き手を拡張)
#   plan      : 起動計画(同一 run の照合結果・前回候補の全条件・計画全体の重複排除)
#   commit    : 正本の保存方針(全対象 absent なら残す・それ以外は今回の実採取で置換)
#   invalidate: 再利用不可の記録を正本へ書く(--clean・採取失敗)
#   withdraw  : 起動を確かめられなかった前回候補を正本から外す(§5.2-5)
#   check     : 前回由来の起動の直前確認(plan・token の一致と live 条件)
_CLAUDE_RESUME_PY=''
read -r -d '' _CLAUDE_RESUME_PY <<'PY' || true
import datetime, json, math, os, re, stat as statmod, sys, tempfile, time, uuid
import yaml

UUID = re.compile(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
BRIDGE = re.compile(r'^session_[A-Za-z0-9]+$')
ANY_BRIDGE = re.compile(r'^(?:session|cse)_([A-Za-z0-9]+)$')
AGENT = re.compile(r'^(shogun|karo|gunshi|ashigaru[0-9]+)$')
TOKEN = re.compile(r'^[0-9A-Za-z][0-9A-Za-z-]{0,127}$')
HEADER_SNAPSHOT = (
    "# claude_session_snapshot.yaml — 機械生成(cmd_785)。手で編集するな。\n"
    "# 出陣が撤収(kill-session)の直前に採取する。今回の採取は *.current.yaml、正本(.current の\n"
    "# 付かない方)は最後の実採取記録(cmd_796)。詳細: docs/claude_session_resume.md\n")
HEADER_PLAN = (
    "# claude_session_plan.yaml — 機械生成(cmd_796)。手で編集するな。\n"
    "# 出陣1回分の起動計画。前回由来の起動は pane の直前確認がこの内容と run_token を照合する。\n")
V2_KEYS = {'schema_version', 'captured_at', 'run_token', 'sessions_found', 'agents', 'skipped',
           'observations', 'observation_complete', 'boot_id', 'captured_uptime', 'cwd',
           'config_dir', 'withdrawn'}
LEGACY_KEYS = {'captured_at', 'run_token', 'sessions_found', 'agents', 'skipped', 'withdrawn'}


class StrictLoader(yaml.SafeLoader):
    pass


def _strict_mapping(loader, node, deep=False):
    seen = set()
    for knode, _ in node.value:
        key = loader.construct_object(knode, deep=True)
        try:
            hash(key)
        except TypeError:
            raise yaml.constructor.ConstructorError(None, None, 'unhashable key', knode.start_mark)
        if key in seen:
            raise yaml.constructor.ConstructorError(None, None, 'duplicate key', knode.start_mark)
        seen.add(key)
    return yaml.SafeLoader.construct_mapping(loader, node, deep=deep)


StrictLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _strict_mapping)


def load_strict(data):
    return yaml.load(data.decode('utf-8'), Loader=StrictLoader)


def read_bytes(path):
    with open(path, 'rb') as fh:
        return fh.read()


def dump(doc):
    return yaml.safe_dump(doc, allow_unicode=True, sort_keys=False, default_flow_style=False)


def atomic_write(path, data):
    if isinstance(data, str):
        data = data.encode('utf-8')
    d = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(dir=d, prefix='.' + os.path.basename(path) + '.', suffix='.tmp')
    try:
        with os.fdopen(fd, 'wb') as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    # クラッシュ後も残すための書込みなので、親 dir も fsync する(対応しない FS だけ見逃す)
    dfd = os.open(d, os.O_RDONLY)
    try:
        os.fsync(dfd)
    except OSError as e:
        if e.errno not in (22, 95):
            raise
    finally:
        os.close(dfd)


def opt(v):
    return '' if v in (None, '-') else v


def wall_of(v):
    try:
        f = float(opt(v))
    except ValueError:
        return None
    return f if math.isfinite(f) else None


def iso_from_wall(wall):
    # 秒未満は切り捨てる(採取時刻を実際より古く書く向き=鮮度を延ばさない)
    return datetime.datetime.fromtimestamp(int(wall)).astimezone().isoformat()


def parse_ts(v):
    if isinstance(v, datetime.datetime):
        dt = v
    elif isinstance(v, str):
        try:
            dt = datetime.datetime.fromisoformat(v)
        except ValueError:
            return None
    else:
        return None
    if dt.tzinfo is None or dt.utcoffset() is None:
        return None
    return dt.timestamp()


def norm_bridge(b):
    m = ANY_BRIDGE.match(b) if isinstance(b, str) else None
    return m.group(1) if m else None


def slug(cwd):
    return re.sub(r'[^A-Za-z0-9]', '-', cwd)


# ─── live: 現生存 Claude の列挙(§5.1) ───
def proc_stat(pid):
    raw = read_bytes('/proc/%d/stat' % pid).decode('utf-8', 'replace')
    rest = raw[raw.rindex(') ') + 2:].split()
    return rest[0], rest[19]


def is_claude_like(pid):
    # comm が claude のもの(native 本体)に加え、判別できる別形式も Claude として扱い、
    # 記録の検証を求める(未対応の形式を「Claude なし」にしない)
    comm = read_bytes('/proc/%d/comm' % pid).decode('utf-8', 'replace').strip()
    if comm == 'claude':
        return True
    try:
        argv = [a.decode('utf-8', 'replace') for a in read_bytes('/proc/%d/cmdline' % pid).split(b'\0') if a]
    except (FileNotFoundError, ProcessLookupError):
        raise
    except OSError:
        argv = []
    base = [os.path.basename(a) for a in argv[:2]]
    if base and base[0] == 'claude':
        return True
    if len(argv) > 1 and base[0] in ('node', 'nodejs', 'bun', 'deno') and \
            ('claude' in base[1] or '@anthropic-ai/claude-code' in argv[1]):
        return True
    try:
        exe = os.readlink('/proc/%d/exe' % pid)
    except OSError:
        return False
    return '/claude/versions/' in exe or os.path.basename(exe) == 'claude'


def config_dir_of(pid):
    vals = {}
    for item in read_bytes('/proc/%d/environ' % pid).split(b'\0'):
        k, sep, v = item.partition(b'=')
        if sep and k in (b'CLAUDE_CONFIG_DIR', b'HOME'):
            vals[k] = v.decode('utf-8', 'surrogateescape')
    if vals.get(b'CLAUDE_CONFIG_DIR'):
        return vals[b'CLAUDE_CONFIG_DIR']
    if vals.get(b'HOME'):
        return os.path.join(vals[b'HOME'], '.claude')
    return None


def verify_record(path, pid, starttime):
    d = json.loads(read_bytes(path).decode('utf-8'))
    if not isinstance(d, dict):
        return None, 'broken_record'
    rp = d.get('pid')
    if not isinstance(rp, int) or isinstance(rp, bool) or rp != pid:
        return None, 'pid_mismatch'
    if str(d.get('procStart')) != starttime:
        return None, 'proc_start_mismatch'
    sid = d.get('sessionId')
    if not isinstance(sid, str) or not UUID.match(sid):
        return None, 'invalid_session_id'
    name = d.get('name')
    if name is not None and not isinstance(name, str):
        return None, 'invalid_name'
    bridge = d.get('bridgeSessionId')
    if not isinstance(bridge, str) or not BRIDGE.match(bridge):
        bridge = ''
    return {'sessionId': sid, 'name': name or '', 'bridge': bridge}, ''


def observe_claude(pid, attempts=5, delay=0.1):
    # 記録を2回読み、その間の starttime と内容が変わらない時だけ使う(PID 再利用・
    # /clear 中の記録更新)。安定しなければ数回だけ読み直し、それでも駄目なら unknown。
    last = 'unstable_record'
    for i in range(attempts):
        if i:
            time.sleep(delay)
        try:
            state, st1 = proc_stat(pid)
        except (FileNotFoundError, ProcessLookupError):
            return None, 'gone'
        except (OSError, ValueError, IndexError):
            last = 'stat_unreadable'
            continue
        if state in ('Z', 'X'):
            return None, 'gone'
        try:
            cfg = config_dir_of(pid)
        except (FileNotFoundError, ProcessLookupError):
            return None, 'gone'
        except OSError:
            last = 'environ_unreadable'
            continue
        if not cfg:
            last = 'config_dir_unknown'
            continue
        path = os.path.join(cfg, 'sessions', '%d.json' % pid)
        try:
            r1, why = verify_record(path, pid, st1)
            if r1 is None:
                last = why
                continue
            _, st2 = proc_stat(pid)
            r2, _ = verify_record(path, pid, st2)
        except FileNotFoundError:
            if not os.path.exists('/proc/%d' % pid):
                return None, 'gone'
            last = 'no_record'
            continue
        except ProcessLookupError:
            return None, 'gone'
        except (OSError, ValueError, IndexError, UnicodeDecodeError):
            last = 'broken_record'
            continue
        if r2 is None or st2 != st1 or r1 != r2:
            last = 'unstable_record'
            continue
        r1.update({'pid': pid, 'starttime': st1, 'config_dir': cfg})
        return r1, ''
    return None, last


def gather_live():
    if not os.path.isfile('/proc/self/stat'):
        return {'ok': False, 'reasons': ['proc_unavailable'], 'procs': []}
    try:
        names = os.listdir('/proc')
    except OSError:
        return {'ok': False, 'reasons': ['proc_unreadable'], 'procs': []}
    uid, me = os.getuid(), os.getpid()
    procs, reasons = [], []
    for n in names:
        if not n.isdigit():
            continue
        pid = int(n)
        if pid == me:
            continue
        try:
            if os.stat('/proc/%d' % pid).st_uid != uid:
                continue
            if not is_claude_like(pid):
                continue
        except (FileNotFoundError, ProcessLookupError):
            continue
        except OSError:
            reasons.append('%d:unreadable' % pid)
            continue
        entry, why = observe_claude(pid)
        if why == 'gone':
            continue
        if entry is None:
            reasons.append('%d:%s' % (pid, why))
            continue
        procs.append(entry)
    return {'ok': not reasons, 'reasons': reasons, 'procs': procs}


def live_view(live):
    ok = isinstance(live, dict) and live.get('ok') is True and isinstance(live.get('procs'), list)
    procs = []
    if isinstance(live, dict) and isinstance(live.get('procs'), list):
        procs = [p for p in live['procs'] if isinstance(p, dict)]
    return ok, procs


def live_conflict(procs, ok, agent, sid, bridge):
    # 確定した衝突を先に、判定不能を後に返す(理由の順序を固定する)
    if any(p.get('sessionId') == sid for p in procs):
        return 'session_in_use'
    nb = norm_bridge(bridge)
    if nb is not None and any(norm_bridge(p.get('bridge')) == nb for p in procs):
        return 'bridge_in_use'
    if any(p.get('name') == agent for p in procs):
        return 'role_live'
    if not ok:
        return 'live_unknown'
    return ''


def mode_live(a):
    print(json.dumps(gather_live()))
    return 0


# ─── snapshot: 採取の書き手(三値の観測つき) ───
def mode_snapshot(a):
    out_file, run_token, found, targets_s, wall, uptime, boot_id, cwd, config_dir = a
    agents, skipped, sessions, rows, obs, live = {}, [], {}, [], {}, None
    for line in sys.stdin.read().splitlines():
        f = line.split('\t')
        if f[0] == 'AGENT' and len(f) >= 6:
            agents[f[1]] = {'session_id': f[4], 'bridge_session_id': f[5] or None,
                            'pid': int(f[3]), 'pane': f[2]}
        elif f[0] == 'SKIP' and len(f) >= 4:
            skipped.append({'agent_id': f[1], 'pane': f[2], 'reason': f[3]})
        elif f[0] == 'SESSION' and len(f) >= 3:
            sessions[f[1]] = f[2]
        elif f[0] == 'ROW' and len(f) >= 4:
            rows.append({'agent': f[1], 'pane': f[2], 'cli': f[3]})
        elif f[0] == 'OBS' and len(f) >= 5:
            obs.setdefault(f[1], []).append((f[3], f[4]))
        elif f[0] == 'LIVE' and len(f) >= 2:
            try:
                live = json.loads(f[1])
            except ValueError:
                live = None
    targets = [t for t in targets_s.split() if t]
    tmux_ok = bool(sessions) and all(v in ('ok', 'missing') for v in sessions.values())
    live_ok, procs = live_view(live)
    live_names = {p.get('name') for p in procs}

    def observe(agent):
        # present: pane の直接の子の Claude の記録が照合を通った / absent: 読めた観測で
        # Claude 0件かつ他所に同役の生存 Claude も無い / unknown: それ以外(採れなかった)
        if not tmux_ok:
            return 'unknown', 'tmux_unreadable'
        mine = [r for r in rows if r['agent'] == agent]
        if len(mine) > 1:
            return 'unknown', 'duplicate_pane'
        if mine and mine[0]['cli'] == 'claude':
            o = obs.get(agent) or []
            if len(o) != 1:
                return 'unknown', 'not_observed'
            state, why = o[0]
            if state == 'present':
                return 'present', ''
            if state != 'none':
                return 'unknown', why or 'unknown'
        if not live_ok:
            return 'unknown', 'live_unknown'
        if agent in live_names:
            return 'unknown', 'same_role_live'
        return 'absent', ''

    consider = []
    for t in targets + [r['agent'] for r in rows if r['cli'] == 'claude' and AGENT.match(r['agent'])]:
        if t not in consider:
            consider.append(t)
    observations = {}
    for t in consider:
        s, w = observe(t)
        observations[t] = {'state': s, 'reason': w} if w else {'state': s}
    w = wall_of(wall)
    up = wall_of(uptime)
    doc = {
        'schema_version': 2,
        'captured_at': iso_from_wall(w if w is not None else time.time()),
        'run_token': run_token,
        'sessions_found': found == '1',
        'agents': agents,
        'skipped': skipped,
        'observations': observations,
        'observation_complete': tmux_ok and live_ok,
        'boot_id': opt(boot_id) if UUID.match(opt(boot_id)) else None,
        'captured_uptime': up,
        'cwd': cwd,
        'config_dir': config_dir,
    }
    atomic_write(out_file, HEADER_SNAPSHOT + dump(doc))
    return 0


# ─── 正本の読取り(§3.3-2・§4 旧形式) ───
def read_canonical(path):
    try:
        data = read_bytes(path)
    except FileNotFoundError:
        return None, 'no_canonical', None
    except OSError:
        return None, 'canonical_unreadable', None
    try:
        doc = load_strict(data)
    except Exception:
        return None, 'canonical_broken', None
    if not isinstance(doc, dict):
        return None, 'canonical_broken', None
    if 'invalidated' in doc:
        return None, ('canonical_invalidated' if doc.get('invalidated') is True else 'canonical_broken'), None
    keys = set(doc)
    if 'schema_version' in doc:
        if doc.get('schema_version') != 2 or isinstance(doc.get('schema_version'), bool) or not keys <= V2_KEYS:
            return None, 'canonical_schema', None
        fmt = 'v2'
        if not (isinstance(doc.get('boot_id'), str) and UUID.match(doc['boot_id'])):
            return None, 'canonical_boot_id', None
        cu = doc.get('captured_uptime')
        if isinstance(cu, bool) or not isinstance(cu, (int, float)) or not math.isfinite(cu) or cu < 0:
            return None, 'canonical_uptime', None
        for k in ('cwd', 'config_dir'):
            if not (isinstance(doc.get(k), str) and doc[k].startswith('/')):
                return None, 'canonical_' + k, None
    else:
        if not keys <= LEGACY_KEYS:
            return None, 'canonical_schema', None
        fmt = 'legacy'
    tok = doc.get('run_token')
    if not isinstance(tok, str) or not tok.strip():
        return None, 'canonical_token', None
    ts = parse_ts(doc.get('captured_at'))
    if ts is None:
        return None, 'canonical_captured_at', None
    if not isinstance(doc.get('agents'), dict):
        return None, 'canonical_agents', None
    wd = doc.get('withdrawn', [])
    if not isinstance(wd, list):
        return None, 'canonical_withdrawn', None
    doc['_ts'] = ts
    doc['_withdrawn'] = {x.get('agent_id') for x in wd if isinstance(x, dict)}
    return doc, '', fmt


def freshness(fmt, pdoc, now_wall, now_up, now_boot):
    # 同じ boot と分かる新形式は単調時計(/proc/uptime)の差。boot が違う・旧形式は
    # timezone 付き captured_at と現実時計の差。前 boot の uptime を引かない(§6)。
    if fmt == 'v2':
        if not UUID.match(now_boot):
            return 'boot_id_unreadable', None
        if pdoc['boot_id'] == now_boot:
            if now_up is None:
                return 'uptime_unreadable', None
            age = now_up - float(pdoc['captured_uptime'])
            if age < 0:
                return 'uptime_regressed', None
            return 'uptime_same_boot', age
        if now_wall is None:
            return 'wallclock_unreadable', None
        return 'wallclock_other_boot', now_wall - pdoc['_ts']
    if now_wall is None:
        return 'wallclock_unreadable', None
    return 'wallclock_legacy', now_wall - pdoc['_ts']


def check_transcript(path, sid, bridge, now_wall, max_age):
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return 'no_transcript'
    except OSError:
        return 'transcript_unreadable'
    if not statmod.S_ISREG(st.st_mode):
        return 'transcript_not_regular'
    if st.st_size == 0:
        return 'transcript_empty'
    if now_wall is None:
        return 'wallclock_unreadable'
    if st.st_mtime > now_wall:
        return 'transcript_future'
    if now_wall - st.st_mtime > max_age:
        return 'transcript_stale'
    last = None
    try:
        with open(path, 'rb') as fh:
            for raw in fh:
                if not raw.strip():
                    continue
                d = json.loads(raw.decode('utf-8'))
                if not isinstance(d, dict):
                    return 'transcript_broken'
                if d.get('type') == 'bridge-session':
                    s = d.get('sessionId')
                    if s is not None and s != sid:
                        return 'transcript_session_mismatch'
                    b = d.get('bridgeSessionId')
                    last = b if isinstance(b, str) else ''
    except (ValueError, UnicodeDecodeError):
        return 'transcript_broken'
    except OSError:
        return 'transcript_unreadable'
    if last is None:
        return 'transcript_no_bridge'
    if last == '':
        return 'bridge_disconnected'
    if norm_bridge(last) is None or norm_bridge(last) != norm_bridge(bridge):
        return 'bridge_mismatch'
    return ''


def counter(values):
    c = {}
    for v in values:
        if v is not None:
            c[v] = c.get(v, 0) + 1
    return c


# ─── plan: 起動計画(§3.3・§5.2) ───
def mode_plan(a):
    (canonical, current, plan_out, run_token, targets_s, launch_cwd, config_dir,
     prev_on, wall, uptime, boot_id, max_age) = a
    max_age = int(max_age)
    now_wall, now_up, now_boot = wall_of(wall), wall_of(uptime), opt(boot_id)
    prev_on = prev_on == '1'
    live, cur_ids = None, {}
    for line in sys.stdin.read().splitlines():
        f = line.split('\t')
        if f[0] == 'LIVE' and len(f) >= 2:
            try:
                live = json.loads(f[1])
            except ValueError:
                live = None
        elif f[0] == 'CURRENT' and len(f) >= 3 and f[2]:
            cur_ids[f[1]] = f[2]
    live_ok, procs = live_view(live)
    targets = [t for t in targets_s.split() if t]
    counts = counter(targets)
    order = list(dict.fromkeys(targets))

    cur_doc, cur_err = None, ''
    try:
        cur_doc = load_strict(read_bytes(current))
        if not isinstance(cur_doc, dict) or cur_doc.get('schema_version') != 2 \
                or cur_doc.get('run_token') != run_token:
            cur_doc, cur_err = None, 'current_mismatch'
    except Exception:
        cur_doc, cur_err = None, 'current_unreadable'
    obs = cur_doc.get('observations') if cur_doc else None
    obs = obs if isinstance(obs, dict) else {}
    cur_agents = cur_doc.get('agents') if cur_doc else None
    cur_agents = cur_agents if isinstance(cur_agents, dict) else {}

    def fresh(reason):
        return {'source': 'fresh', 'reason': reason}

    def state_of(agent):
        o = obs.get(agent)
        return o.get('state') if isinstance(o, dict) else None

    result = {}
    current = {}
    for agent in order:
        if counts[agent] != 1:
            result[agent] = fresh('duplicate_target')
            continue
        sid = cur_ids.get(agent)
        if not sid:
            continue
        ent = cur_agents.get(agent)
        if cur_doc is None or not UUID.match(sid) or not isinstance(ent, dict) or ent.get('session_id') != sid:
            result[agent] = fresh('current_mismatch')
            continue
        if state_of(agent) != 'present':
            result[agent] = fresh('current_not_present')
            continue
        b = ent.get('bridge_session_id')
        current[agent] = {'sid': sid, 'bridge': b if isinstance(b, str) and BRIDGE.match(b) else None}
    c_sid = counter(c['sid'] for c in current.values())
    c_br = counter(norm_bridge(c['bridge']) for c in current.values())
    for agent, c in current.items():
        if c_sid[c['sid']] > 1 or (c['bridge'] and c_br[norm_bridge(c['bridge'])] > 1):
            result[agent] = fresh('duplicate_current')
        else:
            result[agent] = {'source': 'current', 'session_id': c['sid'], 'bridge_session_id': c['bridge']}
    taken_sids = {e.get('session_id') for e in cur_agents.values() if isinstance(e, dict)}
    taken_sids |= {c['sid'] for c in current.values()}
    taken_br = {norm_bridge(e.get('bridge_session_id')) for e in cur_agents.values() if isinstance(e, dict)}
    taken_br.discard(None)

    pdoc, perr, pfmt = (None, 'previous_disabled', None)
    if prev_on:
        pdoc, perr, pfmt = read_canonical(canonical)

    def eval_previous(agent):
        if cur_doc is None:
            return None, cur_err
        st = state_of(agent)
        if st != 'absent':
            return None, 'not_absent:%s' % (st or 'unobserved')
        if pdoc is None:
            return None, perr
        if not AGENT.match(agent):
            return None, 'invalid_agent_id'
        if agent in pdoc['_withdrawn']:
            return None, 'withdrawn'
        ent = pdoc['agents'].get(agent)
        if ent is None:
            return None, 'no_previous_entry'
        if not isinstance(ent, dict):
            return None, 'previous_entry_broken'
        sid = ent.get('session_id')
        if not (isinstance(sid, str) and UUID.match(sid)):
            return None, 'invalid_session_id'
        bridge = ent.get('bridge_session_id')
        if not (isinstance(bridge, str) and BRIDGE.match(bridge)):
            return None, 'no_bridge'
        if pfmt == 'v2':
            if pdoc['cwd'] != launch_cwd:
                return None, 'cwd_mismatch'
            if pdoc['config_dir'] != config_dir:
                return None, 'config_dir_mismatch'
        basis, age = freshness(pfmt, pdoc, now_wall, now_up, now_boot)
        if age is None:
            return None, basis
        if age < 0:
            return None, 'snapshot_future'
        if age > max_age:
            return None, 'snapshot_stale'
        why = check_transcript(os.path.join(config_dir, 'projects', slug(launch_cwd), sid + '.jsonl'),
                               sid, bridge, now_wall, max_age)
        if why:
            return None, why
        why = live_conflict(procs, live_ok, agent, sid, bridge)
        if why:
            return None, why
        return {'source': 'previous_snapshot', 'session_id': sid, 'bridge_session_id': bridge,
                'original_run_token': pdoc['run_token'], 'original_captured_at': str(pdoc['captured_at']),
                'snapshot_format': pfmt, 'age_basis': basis, 'age_seconds': int(age)}, ''

    prev = {}
    for agent in order:
        if agent in result:
            continue
        if not prev_on:
            result[agent] = fresh('previous_disabled')
            continue
        cand, why = eval_previous(agent)
        if cand is None:
            result[agent] = fresh(why)
        else:
            prev[agent] = cand
    p_sid = counter(c['session_id'] for c in prev.values())
    p_br = counter(norm_bridge(c['bridge_session_id']) for c in prev.values())
    for agent, c in prev.items():
        nb = norm_bridge(c['bridge_session_id'])
        if c['session_id'] in taken_sids or nb in taken_br:
            result[agent] = fresh('conflict_current')
        elif p_sid[c['session_id']] > 1 or p_br[nb] > 1:
            result[agent] = fresh('duplicate_previous')
        else:
            result[agent] = c
    plan = {
        'schema_version': 1,
        'run_token': run_token,
        'created_at': iso_from_wall(now_wall if now_wall is not None else time.time()),
        'previous_enabled': prev_on,
        'canonical_status': (perr or 'ok') if prev_on else 'previous_disabled',
        'canonical_format': pfmt,
        'agents': {agent: result[agent] for agent in order},
    }
    atomic_write(plan_out, HEADER_PLAN + dump(plan))
    for agent in order:
        r = result[agent]
        if r['source'] == 'previous_snapshot':
            info = 'basis=%s age=%ss token=%s at=%s' % (r['age_basis'], r['age_seconds'],
                                                     r['original_run_token'], r['original_captured_at'])
        else:
            info = r.get('reason', '')
        print('PLAN\t%s\t%s\t%s\t%s' % (agent, r['source'], r.get('session_id') or '', info))
    return 0


# ─── commit / invalidate / withdraw: 正本の保存方針(§4) ───
def mode_commit(a):
    canonical, current, targets_s = a
    data = read_bytes(current)
    doc = load_strict(data)
    if not isinstance(doc, dict) or doc.get('schema_version') != 2 or not isinstance(doc.get('observations'), dict):
        raise ValueError('current')
    obs = doc['observations']
    targets = [t for t in targets_s.split() if t]
    if all(isinstance(obs.get(t), dict) and obs[t].get('state') == 'absent' for t in targets):
        print('preserved')
        return 0
    atomic_write(canonical, data)
    print('replaced')
    return 0


def mode_invalidate(a):
    canonical, reason, wall = a
    w = wall_of(wall)
    doc = {'schema_version': 2, 'invalidated': True, 'reason': reason,
           'captured_at': iso_from_wall(w if w is not None else time.time()),
           'run_token': 'invalidated-' + str(uuid.uuid4()), 'agents': {}}
    atomic_write(canonical, HEADER_SNAPSHOT + dump(doc))
    return 0


def mode_withdraw(a):
    canonical, run_token, wall = a[:3]
    try:
        data = read_bytes(canonical)
    except FileNotFoundError:
        return 0
    doc = load_strict(data)
    if not isinstance(doc, dict) or doc.get('invalidated') is True or not isinstance(doc.get('agents'), dict):
        return 0
    wd = doc.get('withdrawn')
    wd = wd if isinstance(wd, list) else []
    w = wall_of(wall)
    at = iso_from_wall(w if w is not None else time.time())
    for agent in a[3:]:
        doc['agents'].pop(agent, None)
        wd.append({'agent_id': agent, 'reason': 'previous_launch_unconfirmed', 'run_token': run_token, 'at': at})
    doc['withdrawn'] = wd
    atomic_write(canonical, HEADER_SNAPSHOT + dump(doc))
    return 0


# ─── check: 前回由来の起動の直前確認(§5.2-3) ───
def mode_check(a):
    plan_file, run_token, agent, sid = a

    def no(why):
        sys.stderr.write('[claude_session_resume] 前回記録の直前確認で拒否: %s (agent=%s)\n' % (why, agent))
        return 1
    if not (TOKEN.match(run_token) and AGENT.match(agent) and UUID.match(sid)):
        return no('invalid_argument')
    try:
        plan = load_strict(read_bytes(plan_file))
    except Exception:
        return no('plan_unreadable')
    if not isinstance(plan, dict) or plan.get('schema_version') != 1:
        return no('plan_broken')
    if plan.get('run_token') != run_token:
        return no('plan_token_mismatch')
    ags = plan.get('agents')
    ent = ags.get(agent) if isinstance(ags, dict) else None
    if not isinstance(ent, dict) or ent.get('source') != 'previous_snapshot':
        return no('plan_entry_mismatch')
    if ent.get('session_id') != sid:
        return no('plan_session_mismatch')
    bridge = ent.get('bridge_session_id')
    if not (isinstance(bridge, str) and BRIDGE.match(bridge)):
        return no('plan_bridge_invalid')
    live = None
    for line in sys.stdin.read().splitlines():
        f = line.split('\t')
        if f[0] == 'LIVE' and len(f) >= 2:
            try:
                live = json.loads(f[1])
            except ValueError:
                live = None
    ok, procs = live_view(live)
    why = live_conflict(procs, ok, agent, sid, bridge)
    if why:
        return no(why)
    return 0


MODES = {'live': mode_live, 'snapshot': mode_snapshot, 'plan': mode_plan, 'commit': mode_commit,
         'invalidate': mode_invalidate, 'withdraw': mode_withdraw, 'check': mode_check}
mode = sys.argv[1] if len(sys.argv) > 1 else ''
try:
    rc = MODES[mode](sys.argv[2:])
except Exception as e:
    sys.stderr.write('[claude_session_resume] %s: %s\n' % (mode or '?', type(e).__name__))
    rc = 1
sys.exit(rc or 0)
PY

_claude_resume_py() {
    "$(_claude_resume_python)" -c "$_CLAUDE_RESUME_PY" "$@"
}

# 現生存 Claude の観測(JSON 1行)。Python が走らなければ「判定不能」を返す。
claude_resume_live_observe() {
    local out
    out=$(_claude_resume_py live 2>/dev/null) || out=""
    [ -n "$out" ] || out='{"ok": false, "reasons": ["live_observe_failed"], "procs": []}'
    printf '%s\n' "$out"
}

# 出陣セッションの状態と pane を、区切り US(\037。空の欄を潰さない)で列挙する。
#   SESSION<US>名前<US>ok|missing|error
#   ROW<US>pane<US>pane_pid<US>@agent_id<US>@agent_cli
# セッションが無いこと(missing)は、tmux が「無い」と明言した時だけ認める(cmd_796 §3.2:
# tmux の非0や空の出力だけで absence を作らない)。それ以外の失敗は error。
_claude_resume_pane_scan() {
    local session err out line
    for session in $CLAUDE_RESUME_SESSIONS; do
        if err=$(tmux has-session -t "=${session}" 2>&1 >/dev/null); then
            if out=$(tmux list-panes -s -t "=${session}" \
                -F "#{session_name}:#{window_index}.#{pane_index}"$'\t'"#{pane_pid}"$'\t'"#{@agent_id}"$'\t'"#{@agent_cli}" \
                2>/dev/null); then
                printf 'SESSION\037%s\037ok\n' "$session"
                while IFS= read -r line; do
                    [ -n "$line" ] || continue
                    printf 'ROW\037%s\n' "${line//$'\t'/$'\037'}"
                done <<< "$out"
            else
                printf 'SESSION\037%s\037error\n' "$session"
            fi
        else
            case "$err" in
                *"can't find session"*|*"no server running on "*|*"error connecting to "*"(No such file or directory)"*)
                    printf 'SESSION\037%s\037missing\n' "$session" ;;
                *)
                    printf 'SESSION\037%s\037error\n' "$session" ;;
            esac
        fi
    done
}

claude_resume_snapshot() {
    local out_file="${1:-}" run_token="${2:-}" targets="${3:-}"
    [ -n "$out_file" ] && [ -n "$run_token" ] || return 1

    local -a lines=()
    local kind f1 f2 f3 f4 pane pane_pid agent_id agent_cli scan claude_pid result status sid bridge
    local found_sessions=0
    while IFS=$'\037' read -r kind f1 f2 f3 f4; do
        case "$kind" in
            SESSION)
                lines+=("SESSION"$'\t'"${f1}"$'\t'"${f2}")
                continue
                ;;
            ROW) pane=$f1 pane_pid=$f2 agent_id=$f3 agent_cli=$f4 ;;
            *) continue ;;
        esac
        [ -n "$pane" ] || continue
        found_sessions=1
        lines+=("ROW"$'\t'"${agent_id}"$'\t'"${pane}"$'\t'"${agent_cli}")
        # Codex 系など claude 以外の pane は対象外(記録にも載せない)
        [ "$agent_cli" = "claude" ] || continue
        if ! [[ "$agent_id" =~ ^(shogun|karo|gunshi|ashigaru[0-9]+)$ ]]; then
            lines+=("SKIP"$'\t'"${agent_id:-?}"$'\t'"${pane}"$'\t'"invalid_agent_id")
            continue
        fi
        scan=$(claude_resume_child_claude_scan "$pane_pid")
        case "$scan" in
            "ONE "*)
                claude_pid="${scan#ONE }"
                ;;
            NONE)
                lines+=("SKIP"$'\t'"${agent_id}"$'\t'"${pane}"$'\t'"claude_pid_not_found")
                lines+=("OBS"$'\t'"${agent_id}"$'\t'"${pane}"$'\t'"none"$'\t'"claude_pid_not_found")
                continue
                ;;
            MULTI)
                lines+=("SKIP"$'\t'"${agent_id}"$'\t'"${pane}"$'\t'"multiple_claude_pids")
                lines+=("OBS"$'\t'"${agent_id}"$'\t'"${pane}"$'\t'"unknown"$'\t'"multiple_claude_pids")
                continue
                ;;
            *)
                lines+=("SKIP"$'\t'"${agent_id}"$'\t'"${pane}"$'\t'"child_scan_failed")
                lines+=("OBS"$'\t'"${agent_id}"$'\t'"${pane}"$'\t'"unknown"$'\t'"child_scan_failed")
                continue
                ;;
        esac
        result=$(claude_resume_read_record "$claude_pid" "$agent_id") || true
        IFS=$'\t' read -r status sid bridge <<< "$result"
        if [ "$status" = "OK" ]; then
            lines+=("AGENT"$'\t'"${agent_id}"$'\t'"${pane}"$'\t'"${claude_pid}"$'\t'"${sid}"$'\t'"${bridge}")
            lines+=("OBS"$'\t'"${agent_id}"$'\t'"${pane}"$'\t'"present"$'\t'"")
        else
            lines+=("SKIP"$'\t'"${agent_id}"$'\t'"${pane}"$'\t'"${sid:-unknown}")
            lines+=("OBS"$'\t'"${agent_id}"$'\t'"${pane}"$'\t'"unknown"$'\t'"${sid:-unknown}")
        fi
    done < <(_claude_resume_pane_scan)
    lines+=("LIVE"$'\t'"$(claude_resume_live_observe)")

    local clock wall up bid
    clock=$(_claude_resume_clock)
    IFS=$'\t' read -r wall up bid <<< "$clock"
    mkdir -p "$(dirname "$out_file")" 2>/dev/null || return 1
    printf '%s\n' "${lines[@]}" | _claude_resume_py snapshot \
        "$out_file" "$run_token" "$found_sessions" "$targets" "${wall:--}" "${up:--}" "${bid:--}" \
        "$(pwd)" "$(claude_resume_config_dir)"
}

claude_resume_lookup() {
    local snapshot_file="${1:-}" run_token="${2:-}" agent_id="${3:-}" launch_cwd="${4:-}"
    [ -n "$snapshot_file" ] && [ -n "$run_token" ] && [ -n "$agent_id" ] && [ -n "$launch_cwd" ] || return 1
    [ -f "$snapshot_file" ] || return 1

    local sid
    sid=$("$(_claude_resume_python)" - "$snapshot_file" "$run_token" "$agent_id" <<'PY' 2>/dev/null
import sys
import yaml
path, run_token, agent_id = sys.argv[1:4]
try:
    with open(path, encoding="utf-8") as f:
        d = yaml.safe_load(f)
except Exception:
    sys.exit(1)
if not isinstance(d, dict) or d.get("run_token") != run_token:
    sys.exit(1)
agents = d.get("agents")
entry = agents.get(agent_id) if isinstance(agents, dict) else None
sid = entry.get("session_id") if isinstance(entry, dict) else None
if not isinstance(sid, str):
    sys.exit(1)
print(sid)
PY
    ) || return 1

    # 値をシェルへ渡す前に形式を検査する(記録の取り違え・破損への備え)
    claude_resume_valid_session_id "$sid" || return 1

    local slug transcript
    slug=$(claude_resume_project_slug "$launch_cwd") || return 1
    transcript="$(claude_resume_config_dir)/projects/${slug}/${sid}.jsonl"
    [ -f "$transcript" ] && [ -r "$transcript" ] || return 1

    printf '%s\n' "$sid"
}

# 包む起動コマンドに在ってはならぬ文字: 改行・制御演算子・リダイレクト・展開・
# 引用・コメント・履歴展開(`!`)。1つでも在れば複合コマンドの構造が変わり得る
# (例: `#` 以降が注釈になり `fi` が消えると、シェルが続きの入力を待って起動が
# 止まる)。build_cli_command が組む claude の起動コマンドはどれも含まない。
_CLAUDE_RESUME_UNSAFE_RE=$'[\n\r#;&|`$()<>\\\\!\'"]'

# 1行の複合コマンドの雛形(printf 書式。%%%% は展開 ${…%%.*} の %%)。
#   _csr_t0/_csr_t1: resume 起動の直前・直後の単調時計の整数秒 / _csr_rc: その終了コード /
#   _csr_dt: 経過秒(測れた時だけ値が入り、測れなければ空)
#   - 経過は /proc/uptime(CLOCK_BOOTTIME。起動からの秒)の整数部の差で測る(cmd_794)。
#     現実時計(date +%s)は時刻同期で巻き戻され得る。WSL2 ではゲスト時計の進みを
#     約30秒ごとに約3秒戻す実測があり、段差を挟むと起動失敗の経過が負になって倒さず
#     pane が空のまま残る・30秒を越えて動いた失敗が30秒未満に見える、の両方が起きた
#     (cmd_791)。/proc/uptime は時刻の設定・同期で戻らず、単調に増える。
#   - 読む前に変数を空にする(読めない時に前回の値が残らない)。読取りの失敗・空・非数値・
#     t1 < t0 は「経過を測れない」として _csr_dt を空のままにし、倒さない(fail-closed)。
#     date へは倒さない。rc 1〜127 で測れなかった時は、倒さなかった旨を stderr に残す。
#   - 倒すのは rc が 1〜127(claude が自ら非0で終わった)かつ 0 <= 経過 < 上限の時だけ。
#     rc>=128 は signal による終了・停止(撤収の SIGHUP、Ctrl-Z の停止=148 など)で、
#     起動失敗ではない。停止中の claude の横で新規起動すると pane に claude が2つ並ぶ。
#   - 新規起動は then 節の1回だけ。その終了後に判定し直す経路は無い(ループしない)。
#     elif 節は警告を出すだけで何も起動しない。
#   - resume 起動も新規起動も pane のシェルの直接の子として走る(次の撤収前の採取が
#     pane_pid の直接の子 claude を引く前提を崩さない)。
#   - 対話 bash へ打鍵する1行なので、履歴展開の `!` を使わない(dash でも動く POSIX の形)。
_CLAUDE_RESUME_LAUNCH_FMT='_csr_u=; read -r _csr_u _csr_x 2>/dev/null < /proc/uptime; _csr_t0=${_csr_u%%%%.*}; %s; _csr_rc=$?; _csr_u=; read -r _csr_u _csr_x 2>/dev/null < /proc/uptime; _csr_t1=${_csr_u%%%%.*}; _csr_dt=; [ "$_csr_t0" -ge 0 ] 2>/dev/null && [ "$_csr_t1" -ge "$_csr_t0" ] 2>/dev/null && _csr_dt=$(( _csr_t1 - _csr_t0 )); if [ "$_csr_rc" -ge 1 ] && [ "$_csr_rc" -le 127 ] && [ -n "$_csr_dt" ] && [ "$_csr_dt" -lt %s ]; then echo "[shutsujin] claude --resume が起動直後に終了 (rc=$_csr_rc, ${_csr_dt}秒)。従来の新規起動へ切り替える (1回のみ)"; %s; elif [ "$_csr_rc" -ge 1 ] && [ "$_csr_rc" -le 127 ] && [ -z "$_csr_dt" ]; then echo "[shutsujin] claude --resume が rc=$_csr_rc で終了したが、経過秒を単調時計 (/proc/uptime) で測れないため新規起動へ切り替えない" >&2; fi\n'

claude_resume_launch_cmd() {
    local sid="${1:-}" resume_cmd="${2:-}" fresh_cmd="${3:-}"
    local window="$CLAUDE_RESUME_FALLBACK_WINDOW_SEC" reason=""

    # resume しない起動は従来のコマンドそのまま(復旧経路も付けない)
    if [ -z "$sid" ]; then
        printf '%s\n' "$fresh_cmd"
        return 0
    fi

    if [ -z "$fresh_cmd" ]; then
        reason="fresh_cmd_empty"
    elif ! claude_resume_valid_session_id "$sid"; then
        reason="invalid_session_id"
    elif ! [[ "$window" =~ ^[1-9][0-9]*$ ]]; then
        reason="invalid_window"
    elif [[ "$fresh_cmd" == *--resume* ]]; then
        # 新規起動の側に resume が紛れていれば「同じ従来引数」の保証が崩れる
        reason="fresh_cmd_has_resume"
    elif [[ "$resume_cmd" != *" --resume $sid "* ]] \
        || [ "${resume_cmd/ --resume $sid / }" != "$fresh_cmd" ]; then
        # resume 側は新規起動に ` --resume <id>` を1つ足しただけの形に限る
        reason="resume_cmd_mismatch"
    elif [[ "$fresh_cmd" =~ $_CLAUDE_RESUME_UNSAFE_RE ]]; then
        reason="unsafe_char"
    fi

    if [ -n "$reason" ]; then
        echo "[claude_session_resume] 起動直後失敗の復旧経路を組めないため、従来の新規起動にする(理由: ${reason})" >&2
        printf '%s\n' "$fresh_cmd"
        return 0
    fi

    # shellcheck disable=SC2059  # 書式は上の定数(値は %s で差し込む)
    printf "$_CLAUDE_RESUME_LAUNCH_FMT" "$resume_cmd" "$window" "$fresh_cmd"
}

# ═══════════════════════════════════════════════════════════════
# 前回スナップショットの再利用(cmd_796)— 計画・正本・直前確認
# ═══════════════════════════════════════════════════════════════

_CLAUDE_RESUME_AGENT_RE='^(shogun|karo|gunshi|ashigaru[0-9]+)$'
# pane へ打鍵する直前確認のパス(引用せずに渡すので、空白・引用・展開の文字を許さない)
_CLAUDE_RESUME_SAFE_PATH_RE='^/[A-Za-z0-9._/+-]+$'

# claude_resume_plan <canonical> <current> <plan_out> <run_token> <targets> <launch_cwd> <prev_on>
#   起動計画を作る。current の同一 run 照合(claude_resume_lookup。run_token 完全一致・
#   転写の実在)の結果と、prev_on=1 の時だけ前回候補(正本・§3.3 の全条件)を合わせ、
#   計画全体の ID・bridge の重複を拒否して <plan_out> へ atomic に書く。
#   正本は読むだけ(呼ぶ側が、この後で claude_resume_commit_canonical を呼ぶ)。
claude_resume_plan() {
    local canonical="${1:-}" current="${2:-}" plan_out="${3:-}" run_token="${4:-}"
    local targets="${5:-}" launch_cwd="${6:-}" prev_on="${7:-0}"
    [ -n "$canonical" ] && [ -n "$current" ] && [ -n "$plan_out" ] && [ -n "$launch_cwd" ] || return 1
    claude_resume_valid_token "$run_token" || return 1
    [ "$prev_on" = 1 ] || prev_on=0

    local -a lines=()
    local agent sid
    for agent in $targets; do
        sid=$(claude_resume_lookup "$current" "$run_token" "$agent" "$launch_cwd") || sid=""
        [ -z "$sid" ] || lines+=("CURRENT"$'\t'"${agent}"$'\t'"${sid}")
    done
    if [ "$prev_on" = 1 ]; then
        lines+=("LIVE"$'\t'"$(claude_resume_live_observe)")
    fi
    local clock wall up bid
    clock=$(_claude_resume_clock)
    IFS=$'\t' read -r wall up bid <<< "$clock"
    mkdir -p "$(dirname "$plan_out")" 2>/dev/null || return 1
    printf '%s\n' "${lines[@]+"${lines[@]}"}" | _claude_resume_py plan \
        "$canonical" "$current" "$plan_out" "$run_token" "$targets" "$launch_cwd" \
        "$(claude_resume_config_dir)" "$prev_on" "${wall:--}" "${up:--}" "${bid:--}" \
        "$CLAUDE_RESUME_PREVIOUS_MAX_AGE_SEC"
}

# claude_resume_commit_canonical <canonical> <current> <targets>
#   撤収前に全対象が確実に absent なら正本を byte 単位で残す("preserved")。稼働対象が
#   いた・観測できなかった時は、今回の実採取(current)で正本を置き換える("replaced")。
#   失敗したagentの穴へ前回 ID を混ぜない(cmd_796 §4-4・§4-5)。
claude_resume_commit_canonical() {
    local canonical="${1:-}" current="${2:-}" targets="${3:-}"
    [ -n "$canonical" ] && [ -f "$current" ] || return 1
    _claude_resume_py commit "$canonical" "$current" "$targets"
}

# claude_resume_invalidate <canonical> <reason>
#   再利用不可の記録(invalidated: true)を正本へ atomic に書く。--clean(resume の
#   スイッチが OFF でも)・採取失敗の時に使い、前回候補を次回へ持ち越さない(§4-6)。
claude_resume_invalidate() {
    local canonical="${1:-}" reason="${2:-}" clock wall up bid
    [ -n "$canonical" ] && [[ "$reason" =~ ^[a-z_]+$ ]] || return 1
    clock=$(_claude_resume_clock)
    IFS=$'\t' read -r wall up bid <<< "$clock"
    mkdir -p "$(dirname "$canonical")" 2>/dev/null || return 1
    _claude_resume_py invalidate "$canonical" "$reason" "${wall:--}"
}

# claude_resume_withdraw_previous <canonical> <run_token> <agent_id>...
#   前回由来の起動を送ったが、有限の待ちのうちに live 記録の出現を確かめられなかった
#   agent を正本から外す(次の出陣が「起動前の窓」を absence として使わない。§5.2-5)。
#   元の run_token・採取時刻は書き換えない。
claude_resume_withdraw_previous() {
    local canonical="${1:-}" run_token="${2:-}" a clock wall up bid
    [ -n "$canonical" ] || return 1
    shift 2 2>/dev/null || return 1
    [ "$#" -gt 0 ] || return 0
    for a in "$@"; do
        [[ "$a" =~ $_CLAUDE_RESUME_AGENT_RE ]] || return 1
    done
    clock=$(_claude_resume_clock)
    IFS=$'\t' read -r wall up bid <<< "$clock"
    _claude_resume_py withdraw "$canonical" "$run_token" "${wall:--}" "$@"
}

# claude_resume_wait_live_record <pane_pid> <agent_id> <秒>
#   pane の直接の子 claude が1つで、その記録(pid・procStart・name・sessionId)が照合を
#   通るまで、0.2 秒おきに最大 <秒> だけ待つ。通れば pid を出して 0、時間切れは 1。
#   後続の前回由来の起動の直前確認が、起動直後で記録の無い claude を「判定不能」として
#   拒否しないよう、記録が出てから次へ進むために使う(§5.2-5)。
claude_resume_wait_live_record() {
    local pane_pid="${1:-}" agent="${2:-}" limit="${3:-}" scan pid i=0 n
    case "$limit" in ''|*[!0-9]*) return 1 ;; esac
    [[ "$agent" =~ $_CLAUDE_RESUME_AGENT_RE ]] || return 1
    n=$(( limit * 5 ))
    while [ "$i" -lt "$n" ]; do
        scan=$(claude_resume_child_claude_scan "$pane_pid")
        if [ "${scan%% *}" = "ONE" ]; then
            pid="${scan#ONE }"
            if claude_resume_read_record "$pid" "$agent" >/dev/null 2>&1; then
                printf '%s\n' "$pid"
                return 0
            fi
        fi
        sleep 0.2
        i=$((i + 1))
    done
    return 1
}

# claude_resume_previous_check <plan> <run_token> <agent_id> <session_id>
#   前回由来の起動の直前確認。plan の当該 agent が previous_snapshot で同じ ID・同じ
#   run_token であること、現生存 Claude にその ID・その bridge・同じ役名の使用者が
#   いないこと、全ての生存 Claude の記録を検証できたことを確かめる。
#   0=通過 1=拒否(理由は stderr)。
claude_resume_previous_check() {
    local plan="${1:-}" token="${2:-}" agent="${3:-}" sid="${4:-}"
    if ! claude_resume_valid_token "$token" || ! claude_resume_valid_session_id "$sid" \
        || ! [[ "$agent" =~ $_CLAUDE_RESUME_AGENT_RE ]] || [ ! -f "$plan" ]; then
        echo "[claude_session_resume] 前回記録の直前確認で拒否: invalid_argument (agent=${agent})" >&2
        return 1
    fi
    printf 'LIVE\t%s\n' "$(claude_resume_live_observe)" | _claude_resume_py check "$plan" "$token" "$agent" "$sid"
}

# claude_resume_previous_launch_cmd <plan> <run_token> <agent_id> <session_id> <resume_cmd> <fresh_cmd>
#   前回由来の起動の1行を出す。常に 0 を返す。
#     if bash <本ファイル> --check-previous <plan> <token> <agent> <id>; then
#         <claude_resume_launch_cmd の1行(resume 起動・起動直後失敗なら新規1回)>;
#     else echo ...; <fresh_cmd>; fi
#   直前確認は pane のシェルの子として走り終えてから、claude を従来どおり pane の
#   シェルの直接の子として起こす(次回の採取の前提を崩さない)。候補 ID を外部コマンドの
#   本文へ eval しない(値は形式を検査した引数として渡すだけ)。
#   組めない時(パス・token・ID の形式、包めない起動コマンド)は <fresh_cmd> だけ。
claude_resume_previous_launch_cmd() {
    local plan="${1:-}" token="${2:-}" agent="${3:-}" sid="${4:-}" resume_cmd="${5:-}" fresh_cmd="${6:-}"
    local lib="${CLAUDE_RESUME_LIB_DIR}/claude_session_resume.sh" inner="" reason=""
    if ! [[ "$plan" =~ $_CLAUDE_RESUME_SAFE_PATH_RE ]] || ! [[ "$lib" =~ $_CLAUDE_RESUME_SAFE_PATH_RE ]]; then
        reason="unsafe_path"
    elif ! claude_resume_valid_token "$token"; then
        reason="invalid_token"
    elif ! [[ "$agent" =~ $_CLAUDE_RESUME_AGENT_RE ]]; then
        reason="invalid_agent_id"
    elif ! claude_resume_valid_session_id "$sid"; then
        reason="invalid_session_id"
    else
        inner=$(claude_resume_launch_cmd "$sid" "$resume_cmd" "$fresh_cmd")
        [ "$inner" != "$fresh_cmd" ] || reason="launch_cmd_unwrapped"
    fi
    if [ -n "$reason" ]; then
        echo "[claude_session_resume] 前回記録の起動を組めないため、従来の新規起動にする(理由: ${reason})" >&2
        printf '%s\n' "$fresh_cmd"
        return 0
    fi
    printf 'if bash %s --check-previous %s %s %s %s; then %s; else echo "[shutsujin] 前回記録の直前確認で拒否されたため、従来の新規起動にする (1回のみ)"; %s; fi\n' \
        "$lib" "$plan" "$token" "$agent" "$sid" "$inner" "$fresh_cmd"
}

# ─── 実行の入口(pane の直前確認・cmd_796) ───
# source された時は何もしない。直接実行された時だけ --check-previous を受ける。
# 観測の差し替え口は作らない: Python は作業木の venv に固定し(CLAUDE_RESUME_PYTHON を
# 外す)、現生存 Claude は本物の /proc から読む。
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    unset CLAUDE_RESUME_PYTHON
    case "${1:-}" in
        --check-previous)
            shift
            if [ ! -x "${CLAUDE_RESUME_PROJECT_ROOT}/.venv/bin/python3" ]; then
                echo "[claude_session_resume] 前回記録の直前確認で拒否: no_python" >&2
                exit 1
            fi
            claude_resume_previous_check "$@"
            exit $?
            ;;
        *)
            echo "usage: bash lib/claude_session_resume.sh --check-previous <plan> <run_token> <agent_id> <session_id>" >&2
            exit 2
            ;;
    esac
fi
