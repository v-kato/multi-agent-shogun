#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# google_chat_inbox_watcher.sh — Google Chat 外部入力 inbox 監視
# Usage: bash scripts/google_chat_inbox_watcher.sh
#
# 設計思想:
#   queue/inbox/google_chat_inbox.yaml を inotify 監視
#   processed=false かつ rejected=false の「未通知 message_id」を家老へ通知
#   raw external text は通知に含めない (Prompt Injection 対策)
#   既存 inbox_watcher.sh への直接統合禁止 (cmd_503 確定方針・OSS追跡対象)
#   起動方式: tmux または supervisor 管理。systemd 化は後続 hardening。
#   cmd_506 G-2: message_id 単位の state 管理で通知ストーム恒久停止
# ═══════════════════════════════════════════════════════════════

# ─── Testing guard ───
# __GOOGLE_CHAT_INBOX_WATCHER_TESTING__=1 のときは関数定義のみロード
# テストコードが GOOGLE_CHAT_INBOX / SCRIPT_DIR 変数を外部から設定する
if [ "${__GOOGLE_CHAT_INBOX_WATCHER_TESTING__:-}" != "1" ]; then
    set -euo pipefail

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    GOOGLE_CHAT_INBOX="${SCRIPT_DIR}/queue/inbox/google_chat_inbox.yaml"

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

    echo "[$(date)] google_chat_inbox_watcher started — inbox: $GOOGLE_CHAT_INBOX" >&2
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
_watcher_state_path() {
    echo "${GOOGLE_CHAT_WATCHER_STATE:-${SCRIPT_DIR}/queue/state/google_chat_inbox_watcher_state.yaml}"
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
    local msg="Google Chat 外部入力 ${count} 件。queue/inbox/google_chat_inbox.yaml を確認せよ。"
    bash "${SCRIPT_DIR}/scripts/inbox_write.sh" karo "$msg" google_chat_received google_chat_inbox_watcher
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

while true; do
    set +e
    inotifywait -q -t "$INOTIFY_TIMEOUT" -e modify -e close_write "$GOOGLE_CHAT_INBOX" 2>/dev/null
    rc=$?
    set -e

    sleep 0.3
    check_and_notify
done

fi
