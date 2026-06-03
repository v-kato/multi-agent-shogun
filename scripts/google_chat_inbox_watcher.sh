#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# google_chat_inbox_watcher.sh — Google Chat 外部入力 inbox 監視
# Usage: bash scripts/google_chat_inbox_watcher.sh [--inbox <path>] [--target <agent>]
#
# 設計思想:
#   queue/inbox/google_chat_inbox.yaml を inotify 監視
#   processed=false かつ rejected=false の「未通知 message_id」を家老へ通知
#   raw external text は通知に含めない (Prompt Injection 対策)
#   既存 inbox_watcher.sh への直接統合禁止 (cmd_503 確定方針・OSS追跡対象)
#   起動方式: tmux または supervisor 管理。systemd 化は後続 hardening。
#   cmd_506 G-2: message_id 単位の state 管理で通知ストーム恒久停止
#   cmd_544 G-3: --inbox/--target 引数尊重 + 親ディレクトリ moved_to 監視
# ═══════════════════════════════════════════════════════════════

# ─── 引数解析ヘルパー (テスト/非テスト共通) ───
# テストから _parse_watcher_args を直接呼び出して引数解析を検証可能
_parse_watcher_args() {
    _PARSED_INBOX=""
    _PARSED_TARGET="karo"
    _PARSED_SHOGUN_ROOT=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --inbox)       _PARSED_INBOX="$2";       shift 2 ;;
            --target)      _PARSED_TARGET="$2";      shift 2 ;;
            --shogun-root) _PARSED_SHOGUN_ROOT="$2"; shift 2 ;;
            *)             shift ;;
        esac
    done
}

# ─── Testing guard ───
# __GOOGLE_CHAT_INBOX_WATCHER_TESTING__=1 のときは関数定義のみロード
# テストコードが GOOGLE_CHAT_INBOX / SCRIPT_DIR 変数を外部から設定する
if [ "${__GOOGLE_CHAT_INBOX_WATCHER_TESTING__:-}" != "1" ]; then
    set -euo pipefail

    # SCRIPT_DIR: scripts/inbox_write.sh / .venv 探索用。GOOGLE_CHAT_SCRIPT_DIR で override 可能
    if [ -n "${GOOGLE_CHAT_SCRIPT_DIR:-}" ]; then
        SCRIPT_DIR="$GOOGLE_CHAT_SCRIPT_DIR"
    else
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    fi

    # 引数解析
    _parse_watcher_args "$@"

    # inbox path 解決: --inbox 引数優先 (相対パスは起動 cwd 基準で絶対化)
    if [ -n "$_PARSED_INBOX" ]; then
        if [[ "$_PARSED_INBOX" == /* ]]; then
            GOOGLE_CHAT_INBOX="$_PARSED_INBOX"
        else
            GOOGLE_CHAT_INBOX="$(pwd)/$_PARSED_INBOX"
        fi
    else
        GOOGLE_CHAT_INBOX="${SCRIPT_DIR}/queue/inbox/google_chat_inbox.yaml"
    fi

    # 通知先エージェント
    NOTIFY_TARGET="$_PARSED_TARGET"

    if ! command -v inotifywait &>/dev/null; then
        echo "[google_chat_inbox_watcher] ERROR: inotifywait not found. Install: sudo apt install inotify-tools" >&2
        exit 1
    fi

    if [ ! -f "$GOOGLE_CHAT_INBOX" ]; then
        mkdir -p "$(dirname "$GOOGLE_CHAT_INBOX")"
        printf 'inbox: []\n' > "$GOOGLE_CHAT_INBOX"
    fi

    # ★単一起動保証 (PID file)
    _WATCHER_PID_FILE="${GOOGLE_CHAT_WATCHER_PID_FILE:-/tmp/google_chat_inbox_watcher.pid}"
    if [ -f "$_WATCHER_PID_FILE" ]; then
        _raw_pid=$(cat "$_WATCHER_PID_FILE" 2>/dev/null || true)
        # 空・非数値・複数行 → stale 扱い
        _existing_pid=$(echo "$_raw_pid" | head -1 | tr -d '[:space:]')
        if [[ "$_existing_pid" =~ ^[0-9]+$ ]]; then
            if kill -0 "$_existing_pid" 2>/dev/null; then
                # PID reuse 対策: /proc/$pid/cmdline でスクリプト名確認
                _cmdline=$(cat "/proc/$_existing_pid/cmdline" 2>/dev/null | tr '\0' ' ' || true)
                if echo "$_cmdline" | grep -q "google_chat_inbox_watcher"; then
                    echo "[google_chat_inbox_watcher] ERROR: 二重起動を拒否 (PID=$_existing_pid 稼働中)。既存プロセスを停止してから再起動してください。" >&2
                    exit 1
                else
                    echo "[google_chat_inbox_watcher] PID=$_existing_pid は別プロセス (cmdline不一致)。stale PID file を上書き。" >&2
                fi
            else
                echo "[google_chat_inbox_watcher] stale PID file を上書き (PID=$_existing_pid)" >&2
            fi
        else
            echo "[google_chat_inbox_watcher] PID file の内容が不正 (空/非数値)。上書きします。" >&2
        fi
    fi
    echo $$ > "$_WATCHER_PID_FILE"
    trap 'rm -f "$_WATCHER_PID_FILE"' EXIT
    echo "[$(date)] PID file 作成: $_WATCHER_PID_FILE (PID=$$)" >&2

    echo "[$(date)] google_chat_inbox_watcher started — inbox: $GOOGLE_CHAT_INBOX — target: ${NOTIFY_TARGET}" >&2
fi

# ─── Python インタプリタ解決 ───
_python3() {
    local py_bin
    if [ -f "${SCRIPT_DIR:-}/.venv/bin/python3" ]; then
        py_bin="${SCRIPT_DIR}/.venv/bin/python3"
    else
        py_bin="python3"
    fi
    "$py_bin" "$@"
}

# ─── State ファイルパス ───
# テスト時は GOOGLE_CHAT_WATCHER_STATE 環境変数で上書き可能
# 非テスト時は inbox の 2 段上 (queue/) から state/ を導出し inbox と同 root に揃える
_watcher_state_path() {
    if [ -n "${GOOGLE_CHAT_WATCHER_STATE:-}" ]; then
        echo "$GOOGLE_CHAT_WATCHER_STATE"
    else
        local inbox_dir queue_dir
        inbox_dir="$(dirname "$GOOGLE_CHAT_INBOX")"
        queue_dir="$(dirname "$inbox_dir")"
        echo "${queue_dir}/state/google_chat_inbox_watcher_state.yaml"
    fi
}

# ─── inbox_write.sh が書く project root 解決 ───
# notify_karo が呼ぶ inbox_write.sh のプロジェクトルートを決定する。
# worktree から起動した場合でも実 shogun root の inbox に通知できるよう root 分離設計。
# 優先順: 1) GOOGLE_CHAT_INBOX_WRITE_ROOT env (テスト/live 両対応 override)
#         2) SHOGUN_ROOT env
#         3) --shogun-root 引数 (_PARSED_SHOGUN_ROOT)
#         4) GOOGLE_CHAT_INBOX から推定 (queue/inbox/xxx.yaml の 3 段上 = project root)
_watcher_inbox_write_root() {
    if [ -n "${GOOGLE_CHAT_INBOX_WRITE_ROOT:-}" ]; then
        echo "$GOOGLE_CHAT_INBOX_WRITE_ROOT"
    elif [ -n "${SHOGUN_ROOT:-}" ]; then
        echo "$SHOGUN_ROOT"
    elif [ -n "${_PARSED_SHOGUN_ROOT:-}" ]; then
        echo "$_PARSED_SHOGUN_ROOT"
    else
        local inbox_dir queue_dir
        inbox_dir="$(dirname "${GOOGLE_CHAT_INBOX:-}")"
        queue_dir="$(dirname "$inbox_dir")"
        dirname "$queue_dir"
    fi
}

# ─── 未処理件数カウント ───
# processed=false かつ rejected=false のエントリ数を stdout に出力
count_unprocessed() {
    INBOX_PATH="${GOOGLE_CHAT_INBOX}" _python3 - << 'PY'
import os
import sys
try:
    import yaml
except ImportError:
    print(0)
    sys.exit(0)

inbox_path = os.environ.get("INBOX_PATH", "")
try:
    with open(inbox_path, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
    entries = data.get("inbox", []) or []
    count = sum(
        1 for e in entries
        if not e.get("processed", False)
        and not e.get("rejected", False)
    )
    print(count)
except Exception as e:
    print(f"[google_chat_inbox_watcher] count_unprocessed error: {e}", file=sys.stderr)
    print(0)
PY
}

# ─── 未通知かつ未処理の message_id リスト ───
# inbox から processed=false+rejected=false の entry を抽出し、
# state file の notified_message_ids にないものだけを改行区切りで stdout に出力
list_unnotified_message_ids() {
    local state_path
    state_path=$(_watcher_state_path)
    INBOX_PATH="${GOOGLE_CHAT_INBOX}" STATE_PATH="$state_path" _python3 - << 'PY'
import os, sys
try:
    import yaml
except ImportError:
    sys.exit(0)

inbox_path = os.environ.get("INBOX_PATH", "")
state_path = os.environ.get("STATE_PATH", "")

try:
    with open(inbox_path, "r", encoding="utf-8") as f:
        inbox_data = yaml.safe_load(f) or {}
    entries = inbox_data.get("inbox", []) or []
    unprocessed_ids = [
        e.get("message_id")
        for e in entries
        if not e.get("processed", False)
        and not e.get("rejected", False)
        and e.get("message_id")
    ]
except Exception as e:
    print(f"[watcher] inbox 読込エラー: {e}", file=sys.stderr)
    sys.exit(0)

notified_ids = set()
if os.path.exists(state_path):
    try:
        with open(state_path, "r", encoding="utf-8") as f:
            state = yaml.safe_load(f) or {}
        notified_ids = set(state.get("notified_message_ids", []) or [])
    except Exception as e:
        # state file 破損時は安全に初期化 (W-G2-005)
        print(f"[watcher] state file 破損、初期化します: {e}", file=sys.stderr)

for mid in unprocessed_ids:
    if mid not in notified_ids:
        print(mid)
PY
}

# ─── 通知後に state file を更新 ───
# 通知済み message_id を state file に追記。flock + temp + rename。
# inbox に存在しない / processed 済みの古いエントリは pruning する。
update_state_after_notify() {
    local new_ids="$1"
    local state_path
    state_path=$(_watcher_state_path)
    mkdir -p "$(dirname "$state_path")"
    INBOX_PATH="${GOOGLE_CHAT_INBOX}" STATE_PATH="$state_path" NEW_IDS="$new_ids" _python3 - << 'PY'
import fcntl, os, sys, tempfile
from datetime import datetime, timezone
try:
    import yaml
except ImportError:
    sys.exit(0)

inbox_path = os.environ.get("INBOX_PATH", "")
state_path = os.environ.get("STATE_PATH", "")
new_ids_raw = os.environ.get("NEW_IDS", "")

new_ids = [mid for mid in new_ids_raw.strip().splitlines() if mid.strip()]
if not new_ids:
    sys.exit(0)

# inbox の全 message_id を収集 (pruning 用)
known_inbox_ids = set()
if os.path.exists(inbox_path):
    try:
        with open(inbox_path, "r", encoding="utf-8") as f:
            inbox_data = yaml.safe_load(f) or {}
        entries = inbox_data.get("inbox", []) or []
        for e in entries:
            mid = e.get("message_id")
            # processed/rejected 済みはpruning対象 (state には残さない)
            if mid and not (e.get("processed", False) or e.get("rejected", False)):
                known_inbox_ids.add(mid)
    except Exception:
        pass

lock_path = state_path + ".lock"
tmp_path = None
try:
    with open(lock_path, "w") as lf:
        fcntl.flock(lf, fcntl.LOCK_EX)
        try:
            if os.path.exists(state_path):
                with open(state_path, "r", encoding="utf-8") as f:
                    state = yaml.safe_load(f) or {}
            else:
                state = {}
            existing = list(state.get("notified_message_ids", []) or [])
            # pruning: inbox に未処理として存在するもののみ保持 + 新規追加
            pruned = [mid for mid in existing if mid in known_inbox_ids]
            for mid in new_ids:
                if mid not in pruned:
                    pruned.append(mid)
            state["notified_message_ids"] = pruned
            state["updated_at"] = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            parent = os.path.dirname(state_path)
            os.makedirs(parent, exist_ok=True)
            with tempfile.NamedTemporaryFile(
                mode="w", encoding="utf-8", dir=parent, suffix=".tmp", delete=False
            ) as tmp:
                yaml.dump(state, tmp, allow_unicode=True, default_flow_style=False, sort_keys=False)
                tmp_path = tmp.name
            os.replace(tmp_path, state_path)
            tmp_path = None
        finally:
            if tmp_path and os.path.exists(tmp_path):
                os.unlink(tmp_path)
            fcntl.flock(lf, fcntl.LOCK_UN)
except Exception as e:
    print(f"[watcher] state 更新失敗: {e}", file=sys.stderr)
PY
}

# ─── 家老通知 ───
# 件数とファイルパスのみを含む短文。raw text は一切含めない (Prompt Injection 対策)
# 成功時 exit 0、失敗時 non-zero を返す
notify_karo() {
    local count="$1"
    if [ "${count:-0}" -le 0 ] 2>/dev/null; then
        return 0
    fi
    local msg="Google Chat 外部入力 ${count} 件。${GOOGLE_CHAT_INBOX} を確認せよ。"
    local _inbox_write_root
    _inbox_write_root=$(_watcher_inbox_write_root)
    bash "${_inbox_write_root}/scripts/inbox_write.sh" "${NOTIFY_TARGET:-karo}" "$msg" google_chat_received google_chat_inbox_watcher
    return $?
}

# ─── 変更検知 & 通知 (message_id 単位 dedup) ───
# 未通知かつ未処理の message_id がある場合のみ通知する。
# timeout / file modify どちらのトリガーでも同じロジック (W-G2-007)。
check_and_notify() {
    local unnotified_ids
    unnotified_ids=$(list_unnotified_message_ids)
    local new_count
    new_count=$(echo "$unnotified_ids" | grep -c '[^[:space:]]' 2>/dev/null || echo 0)

    if [ "${new_count:-0}" -gt 0 ] 2>/dev/null; then
        local total_count
        total_count=$(count_unprocessed)
        if notify_karo "$total_count"; then
            update_state_after_notify "$unnotified_ids"
            echo "[$(date)] karo へ通知: 未通知 ${new_count} 件 (total未処理: ${total_count} 件)" >&2
        else
            echo "[$(date)] inbox_write 失敗 — state 未更新 (次回再通知)" >&2
        fi
    else
        echo "[$(date)] 未通知の未処理なし — 通知スキップ (message_id state 確認済み)" >&2
    fi
}

# ─── 起動時チェック ───
# watcher 停止中に listener が inbox に永続化したエントリを起動直後に検出
check_on_start() {
    echo "[$(date)] 起動時チェック — 未処理エントリを確認" >&2
    check_and_notify
}

# ─── メインループ (テストモード時スキップ) ───
if [ "${__GOOGLE_CHAT_INBOX_WATCHER_TESTING__:-}" != "1" ]; then

check_on_start

INOTIFY_TIMEOUT="${INOTIFY_TIMEOUT:-30}"

# 親ディレクトリ監視: atomic rename (os.replace) の moved_to を確実に捕捉する
INBOX_DIR="$(dirname "$GOOGLE_CHAT_INBOX")"
INBOX_BASENAME="$(basename "$GOOGLE_CHAT_INBOX")"

while true; do
    set +e
    inotify_output=$(inotifywait -q -t "$INOTIFY_TIMEOUT" \
        -e modify -e close_write -e moved_to \
        --format '%f' "$INBOX_DIR" 2>/dev/null)
    rc=$?
    set -e

    sleep 0.3

    if [ "$rc" -eq 0 ]; then
        # イベント発生: 対象 basename のイベントのみ即時処理 (basename filter)
        if [ "$inotify_output" = "$INBOX_BASENAME" ]; then
            check_and_notify
        fi
        # 対象外ファイルのイベントはスキップ (timeout 経路の safety net で後処理)
    else
        # timeout (rc!=0): safety net として check_and_notify
        check_and_notify
    fi
done

fi
