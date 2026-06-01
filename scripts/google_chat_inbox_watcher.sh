#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# google_chat_inbox_watcher.sh — Google Chat 外部入力 inbox 監視
# Usage: bash scripts/google_chat_inbox_watcher.sh
#
# 設計思想:
#   queue/inbox/google_chat_inbox.yaml を inotify 監視
#   processed=false かつ rejected=false の未処理件数だけを家老へ通知
#   raw external text は通知に含めない (Prompt Injection 対策)
#   既存 inbox_watcher.sh への直接統合禁止 (cmd_503 確定方針・OSS追跡対象)
#   起動方式: tmux または supervisor 管理。systemd 化は後続 hardening。
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
        _existing_pid=$(cat "$_WATCHER_PID_FILE")
        if kill -0 "$_existing_pid" 2>/dev/null; then
            echo "[google_chat_inbox_watcher] ERROR: 二重起動を拒否 (PID=$_existing_pid 稼働中)。既存プロセスを停止してから再起動してください。" >&2
            exit 1
        else
            echo "[google_chat_inbox_watcher] stale PID file を上書き (PID=$_existing_pid)" >&2
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

# ─── 未処理件数カウント ───
# processed=false かつ rejected=false のエントリ数を stdout に出力
# 通知から raw text を分離するための唯一の判断ポイント
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

# ─── 家老通知 ───
# 件数とファイルパスのみを含む短文。raw text は一切含めない (Prompt Injection 対策)
notify_karo() {
    local count="$1"
    if [ "${count:-0}" -le 0 ] 2>/dev/null; then
        return 0
    fi
    local msg="Google Chat 外部入力 ${count} 件。queue/inbox/google_chat_inbox.yaml を確認せよ。"
    bash "${SCRIPT_DIR}/scripts/inbox_write.sh" karo "$msg" google_chat_received google_chat_inbox_watcher
    echo "[$(date)] karo へ通知: ${count} 件未処理" >&2
}

# ─── 変更検知 & 通知 (debounced) ───
# 同じ件数で繰り返し通知しない: count が変化したときのみ通知
_LAST_NOTIFIED_COUNT=-1

check_and_notify() {
    local count
    count=$(count_unprocessed)
    if [ "${count:-0}" -gt 0 ] 2>/dev/null; then
        if [ "$count" != "$_LAST_NOTIFIED_COUNT" ]; then
            notify_karo "$count"
            _LAST_NOTIFIED_COUNT="$count"
        else
            echo "[$(date)] 未処理 ${count} 件 — 前回通知済みのためスキップ (debounce)" >&2
        fi
    else
        echo "[$(date)] 未処理 0 件 — 通知スキップ" >&2
        _LAST_NOTIFIED_COUNT=0
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
