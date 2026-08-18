#!/usr/bin/env bash
# gunshi_report_lock.sh — gunshi_report.yaml の追記(append)・移管(archive)を
# 排他ロック経由で行う (cmd_699)。
#
# 背景: flock は advisory であり、全ての書き手が同じロックを取らない限り
# 意味を持たない。軍師の追記(report_written)と家老の移管(cmd完了時の
# gunshi_report_archive.yaml への退避)が生の Read/Edit/Write で並行実行されると
# read-modify-write の lost update が起きる。inbox_write.sh (mkdir + flock の
# 二重ロック) と同形の薄いラッパーとして、追記・削除の双方に同じロックファイル
# (queue/reports/.gunshi_report.lock) を強制する。
#
# 使い方:
#   bash scripts/gunshi_report_lock.sh append <content_file>
#     content_file には '---' 区切りを含まない単一の YAML マッピング文書を書いておくこと。
#   bash scripts/gunshi_report_lock.sh archive <parent_cmd_id>
#     gunshi_report.yaml から parent_cmd が一致する全文書を
#     gunshi_report_archive.yaml へ移す。該当なしは 0 件移動として正常終了する。
#
# 読み取りのみ(件数確認等)にはロックは不要。read-modify-write の一連(このスクリプト
# 経由の append/archive)だけをロックで囲む。

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="$1"

REPORT="$SCRIPT_DIR/queue/reports/gunshi_report.yaml"
ARCHIVE="$SCRIPT_DIR/queue/reports/gunshi_report_archive.yaml"
LOCKFILE="$SCRIPT_DIR/queue/reports/.gunshi_report.lock"
LOCK_DIR="${LOCKFILE}.d"
PYTHON="$SCRIPT_DIR/.venv/bin/python3"

usage() {
    echo "使い方: gunshi_report_lock.sh append <content_file> | archive <parent_cmd_id>" >&2
}

if [ -z "$ACTION" ]; then
    usage
    exit 1
fi

mkdir -p "$(dirname "$REPORT")"

# プロセス間ロック: mkdir で相互排他を確立し、flock があれば追加で使う。
# inbox_write.sh と同じ二重ロック方式。
_acquire_lock() {
    local i=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        sleep 0.1
        i=$((i + 1))
        [ $i -ge 50 ] && return 1  # 5s timeout
    done

    if command -v flock &>/dev/null; then
        exec 200>"$LOCKFILE"
        flock -w 5 200 || {
            rmdir "$LOCK_DIR" 2>/dev/null
            return 1
        }
    fi
    return 0
}

_release_lock() {
    if command -v flock &>/dev/null; then
        exec 200>&-
    fi
    rmdir "$LOCK_DIR" 2>/dev/null || true
}

case "$ACTION" in
  append)
    CONTENT_FILE="$2"
    if [ -z "$CONTENT_FILE" ] || [ ! -f "$CONTENT_FILE" ]; then
        usage
        exit 1
    fi

    attempt=0
    max_attempts=3
    while [ $attempt -lt $max_attempts ]; do
        if _acquire_lock; then
            trap _release_lock EXIT
            if "$PYTHON" - "$REPORT" "$CONTENT_FILE" <<'PYEOF'
import os
import sys
import tempfile

import yaml

report_path, content_path = sys.argv[1], sys.argv[2]

with open(content_path, encoding='utf-8') as f:
    new_text = f.read()

if not new_text.strip():
    print('[gunshi_report_lock] エラー: content_file が空です', file=sys.stderr)
    sys.exit(1)

try:
    parsed = yaml.safe_load(new_text)
except yaml.YAMLError as e:
    print(f'[gunshi_report_lock] エラー: content_file が正しい YAML ではありません: {e}', file=sys.stderr)
    sys.exit(1)

if not isinstance(parsed, dict):
    print(
        "[gunshi_report_lock] エラー: content_file は単一の YAML マッピング文書で"
        "なければなりません('---' 区切りは不可)",
        file=sys.stderr,
    )
    sys.exit(1)

new_text_norm = new_text if new_text.endswith('\n') else new_text + '\n'

report_has_content = os.path.exists(report_path) and os.path.getsize(report_path) > 0
if report_has_content:
    with open(report_path, encoding='utf-8') as f:
        existing = f.read()
    existing_norm = existing if existing.endswith('\n') else existing + '\n'
    combined = existing_norm + '---\n' + new_text_norm
else:
    combined = new_text_norm

d = os.path.dirname(report_path) or '.'
fd, tmp = tempfile.mkstemp(dir=d, suffix='.tmp')
try:
    with os.fdopen(fd, 'w', encoding='utf-8') as f:
        f.write(combined)
    os.replace(tmp, report_path)
except Exception:
    os.unlink(tmp)
    raise

print(f'[gunshi_report_lock] 1件追記しました ({len(new_text_norm)} bytes)')
PYEOF
            then
                STATUS=0
            else
                STATUS=$?
            fi
            _release_lock
            trap - EXIT
            [ $STATUS -eq 0 ] && exit 0
            attempt=$((attempt + 1))
            [ $attempt -lt $max_attempts ] && sleep 1
        else
            attempt=$((attempt + 1))
            if [ $attempt -lt $max_attempts ]; then
                echo "[gunshi_report_lock] ロック取得タイムアウト (試行 $attempt/$max_attempts)、再試行します..." >&2
                sleep 1
            else
                echo "[gunshi_report_lock] $max_attempts 回試行してもロックを取得できませんでした" >&2
                exit 1
            fi
        fi
    done
    exit 1
    ;;

  archive)
    PARENT_CMD="$2"
    if [ -z "$PARENT_CMD" ]; then
        usage
        exit 1
    fi

    attempt=0
    max_attempts=3
    while [ $attempt -lt $max_attempts ]; do
        if _acquire_lock; then
            trap _release_lock EXIT
            if "$PYTHON" - "$REPORT" "$ARCHIVE" "$PARENT_CMD" <<'PYEOF'
import os
import re
import sys
import tempfile

import yaml

report_path, archive_path, parent_cmd = sys.argv[1], sys.argv[2], sys.argv[3]

if not os.path.exists(report_path) or os.path.getsize(report_path) == 0:
    print('[gunshi_report_lock] 0件移動しました (report ファイルが空または存在しません)')
    sys.exit(0)

with open(report_path, encoding='utf-8') as f:
    text = f.read()

# ドキュメント境界(行頭の "---" のみの行)で分割する。区切り行自体は捨て、
# 各チャンクの生テキストはそのまま保持する(yaml.dump による再フォーマットで
# 無関係な既存エントリの見た目が変わるのを避けるため)。
raw_chunks = re.split(r'(?m)^---[ \t]*$\n?', text)
chunks = [c for c in raw_chunks if c.strip()]

keep_chunks = []
moved_chunks = []
for chunk in chunks:
    try:
        parsed = yaml.safe_load(chunk)
    except yaml.YAMLError as e:
        print(
            f'[gunshi_report_lock] エラー: 既存文書の解析に失敗したため、'
            f'変更を行わず中断します: {e}',
            file=sys.stderr,
        )
        sys.exit(1)
    if isinstance(parsed, dict) and parsed.get('parent_cmd') == parent_cmd:
        moved_chunks.append(chunk)
    else:
        keep_chunks.append(chunk)

if not moved_chunks:
    print(f'[gunshi_report_lock] 0件移動しました (parent_cmd={parent_cmd} に一致する文書なし)')
    sys.exit(0)


def join_chunks(items):
    normalized = [c.strip('\n') + '\n' for c in items]
    return '---\n'.join(normalized)


new_report_content = join_chunks(keep_chunks) if keep_chunks else ''

if os.path.exists(archive_path) and os.path.getsize(archive_path) > 0:
    with open(archive_path, encoding='utf-8') as f:
        existing_archive = f.read()
    existing_archive_norm = existing_archive if existing_archive.endswith('\n') else existing_archive + '\n'
    new_archive_content = existing_archive_norm + '---\n' + join_chunks(moved_chunks)
else:
    new_archive_content = join_chunks(moved_chunks)


def atomic_write(path, content):
    d = os.path.dirname(path) or '.'
    fd, tmp = tempfile.mkstemp(dir=d, suffix='.tmp')
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            f.write(content)
        os.replace(tmp, path)
    except Exception:
        os.unlink(tmp)
        raise


atomic_write(archive_path, new_archive_content)
atomic_write(report_path, new_report_content)

print(
    f'[gunshi_report_lock] {len(moved_chunks)}件を archive へ移動しました '
    f'(parent_cmd={parent_cmd})。残り {len(keep_chunks)} 件'
)
PYEOF
            then
                STATUS=0
            else
                STATUS=$?
            fi
            _release_lock
            trap - EXIT
            [ $STATUS -eq 0 ] && exit 0
            attempt=$((attempt + 1))
            [ $attempt -lt $max_attempts ] && sleep 1
        else
            attempt=$((attempt + 1))
            if [ $attempt -lt $max_attempts ]; then
                echo "[gunshi_report_lock] ロック取得タイムアウト (試行 $attempt/$max_attempts)、再試行します..." >&2
                sleep 1
            else
                echo "[gunshi_report_lock] $max_attempts 回試行してもロックを取得できませんでした" >&2
                exit 1
            fi
        fi
    done
    exit 1
    ;;

  *)
    usage
    exit 1
    ;;
esac
