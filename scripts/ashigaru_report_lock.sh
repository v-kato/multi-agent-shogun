#!/usr/bin/env bash
# ashigaru_report_lock.sh — queue/reports/ashigaru{N}_report.yaml の追記(append)・
# 移管(archive)を排他ロック経由で行う (cmd_734)。
#
# 背景: flock は advisory であり、全ての書き手が同じロックを取らない限り
# 意味を持たない。gunshi_report_lock.sh (cmd_699) は軍師report専用に同様の
# 排他制御を導入済みだが、足軽report(当初ashigaru3〜7_report.yaml)には同じ
# 仕組みが無いまま肥大化していた。本スクリプトは gunshi_report_lock.sh と
# 同型のロック共有パターン(mkdir + flock の二重ロック、tempfile + os.replace
# によるatomic書き込み、'---'区切りのraw chunk分割保持)を、agent_id引数で
# 対象ファイルを切り替える形で足軽reportに適用する(当初ashigaru3〜7の5人分、
# cmd_734是正でashigaru1・ashigaru2を追加し計7人分)。複数ファイル分を
# 1本のスクリプトで扱い、agentごとに個別スクリプトを作ることを避ける。
#
# 使い方:
#   bash scripts/ashigaru_report_lock.sh append <agent_id> <content_file>
#     content_file には '---' 区切りを含まない単一の YAML マッピング文書を書いておくこと。
#   bash scripts/ashigaru_report_lock.sh archive <agent_id> <cmd_id_list_file>
#     ashigaru{N}_report.yaml から、cmd_id_list_file に1行1件で列挙された
#     parent_cmd のいずれかに一致する文書を ashigaru{N}_report_archive.yaml へ移す。
#     該当なしは0件移動として正常終了する。
#
#     ★足軽reportには、複数エントリが1つの'---'区切りチャンクに
#     `- task_id: ... \n  parent_cmd: ...` という list 形式でまとめられている
#     箇所が過去分に存在する(gunshi reportには存在しないパターン)。
#     list形式のチャンクは複数のparent_cmdが混在しうるため、チャンク単位でしか
#     移動できない本方式では、チャンク内の個々のエントリを分割して一部だけ
#     移すことはしない(cmd_734で維持確定)。その代わり、チャンク内の★全エントリの
#     parent_cmdが完了済cmd_idであると個別に確認できた場合に限り、チャンク全体を
#     移動する。1件でも未完了・不明(parent_cmd欠落を含む)なエントリがあれば、
#     チャンク全体をkeep側に残す(fail-safe。混在チャンクへの対応強化はscope外)。
#     dict形式(1チャンク=1エントリ)は元々この規則の特殊ケースとして扱われる。
#
#     ★archiveの結果、report側の残りチャンクが0件になる場合は、0バイト
#     ファイルではなく最小のstub文書を書く(cmd_734)。yaml.safe_load は0バイト
#     入力に対し{}ではなくNoneを返し、.get()等を呼ぶ読み手が例外になりうる
#     ため。同じ理由で、report側が既に0バイトの状態でarchiveが呼ばれた場合も
#     同じstubへ自己修復する。
#
# <agent_id>: ashigaru1 〜 ashigaru7 のみ受理(allowlist完全一致)。
#             他の値は使い方エラーとして拒否する。
#
# 読み取りのみ(件数確認等)にはロックは不要。read-modify-write の一連(この
# スクリプト経由の append/archive)だけをロックで囲む。

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="$1"
AGENT_ID="$2"

PYTHON="$SCRIPT_DIR/.venv/bin/python3"

_ALLOWLIST="ashigaru1 ashigaru2 ashigaru3 ashigaru4 ashigaru5 ashigaru6 ashigaru7"

usage() {
    echo "使い方: ashigaru_report_lock.sh append <agent_id> <content_file> | archive <agent_id> <cmd_id_list_file>" >&2
    echo "  <agent_id>: $_ALLOWLIST のいずれか" >&2
}

_allowlist_check() {
    local candidate="$1"
    local a
    for a in $_ALLOWLIST; do
        [ "$a" = "$candidate" ] && return 0
    done
    return 1
}

if [ -z "$ACTION" ] || [ -z "$AGENT_ID" ]; then
    usage
    exit 1
fi

if ! _allowlist_check "$AGENT_ID"; then
    echo "[ashigaru_report_lock] エラー: agent_id '$AGENT_ID' はallowlistに一致しません" >&2
    usage
    exit 1
fi

REPORT="$SCRIPT_DIR/queue/reports/${AGENT_ID}_report.yaml"
ARCHIVE="$SCRIPT_DIR/queue/reports/${AGENT_ID}_report_archive.yaml"
LOCKFILE="$SCRIPT_DIR/queue/reports/.${AGENT_ID}_report.lock"
LOCK_DIR="${LOCKFILE}.d"

mkdir -p "$(dirname "$REPORT")"

# プロセス間ロック: mkdir で相互排他を確立し、flock があれば追加で使う。
# gunshi_report_lock.sh / inbox_write.sh と同じ二重ロック方式。
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
    CONTENT_FILE="$3"
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
    print('[ashigaru_report_lock] エラー: content_file が空です', file=sys.stderr)
    sys.exit(1)

try:
    parsed = yaml.safe_load(new_text)
except yaml.YAMLError as e:
    print(f'[ashigaru_report_lock] エラー: content_file が正しい YAML ではありません: {e}', file=sys.stderr)
    sys.exit(1)

if not isinstance(parsed, dict):
    print(
        "[ashigaru_report_lock] エラー: content_file は単一の YAML マッピング文書で"
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

print(f'[ashigaru_report_lock] 1件追記しました ({len(new_text_norm)} bytes)')
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
                echo "[ashigaru_report_lock] ロック取得タイムアウト (試行 $attempt/$max_attempts)、再試行します..." >&2
                sleep 1
            else
                echo "[ashigaru_report_lock] $max_attempts 回試行してもロックを取得できませんでした" >&2
                exit 1
            fi
        fi
    done
    exit 1
    ;;

  archive)
    CMD_LIST_FILE="$3"
    if [ -z "$CMD_LIST_FILE" ] || [ ! -f "$CMD_LIST_FILE" ]; then
        usage
        exit 1
    fi

    attempt=0
    max_attempts=3
    while [ $attempt -lt $max_attempts ]; do
        if _acquire_lock; then
            trap _release_lock EXIT
            if "$PYTHON" - "$REPORT" "$ARCHIVE" "$CMD_LIST_FILE" <<'PYEOF'
import os
import re
import sys
import tempfile

import yaml

report_path, archive_path, cmd_list_path = sys.argv[1], sys.argv[2], sys.argv[3]

with open(cmd_list_path, encoding='utf-8') as f:
    parent_cmds = {line.strip() for line in f if line.strip()}

if not parent_cmds:
    print('[ashigaru_report_lock] エラー: cmd_id_list_file が空です', file=sys.stderr)
    sys.exit(1)


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


# 全エントリがarchive済みで active 側が0件になった場合、0バイトファイルではなく
# この最小stub(単一dict文書)を書く。yaml.safe_load は0バイト入力に対し {} では
# なく None を返すため、.get() 等を呼ぶ将来の読み手が例外になる余地を残さない
# (cmd_734)。task_id を持たないため既存の実データ(dict/list いずれもtask_idを
# 持つ)とは判別可能。parent_cmd も持たないため、archive() 再実行時は
# 「不明(未完了扱い)」として自然にkeep側に残り続け、特別扱いのコードを
# 追加で必要としない。
EMPTY_REPORT_STUB = (
    'report_stub: true\n'
    'status: empty\n'
    'note: "全エントリがarchive済みのため、有効なYAML文書として残すために書かれたstubです(cmd_734)"\n'
)

if not os.path.exists(report_path):
    print('[ashigaru_report_lock] 0件移動しました (report ファイルが存在しません)')
    sys.exit(0)

if os.path.getsize(report_path) == 0:
    # 是正前ロジックが残した0バイト状態、または他要因での0バイト化を、
    # archive呼び出しのタイミングで自己修復する(cmd_734)。
    atomic_write(report_path, EMPTY_REPORT_STUB)
    print(
        '[ashigaru_report_lock] 0件移動しました '
        '(report ファイルが0バイトだったため、有効な空stubへ是正しました)'
    )
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

moved_entry_count = 0
moved_dict_chunk_count = 0
moved_list_chunk_count = 0
moved_list_entry_count = 0

kept_list_mixed_chunk_count = 0
kept_list_mixed_entry_count = 0
kept_other_chunk_count = 0

for chunk in chunks:
    try:
        parsed = yaml.safe_load(chunk)
    except yaml.YAMLError as e:
        print(
            f'[ashigaru_report_lock] エラー: 既存文書の解析に失敗したため、'
            f'変更を行わず中断します: {e}',
            file=sys.stderr,
        )
        sys.exit(1)

    if isinstance(parsed, dict):
        if parsed.get('parent_cmd') in parent_cmds:
            moved_chunks.append(chunk)
            moved_dict_chunk_count += 1
            moved_entry_count += 1
        else:
            keep_chunks.append(chunk)
        continue

    if isinstance(parsed, list) and len(parsed) > 0 and all(isinstance(e, dict) for e in parsed):
        # list形式chunk(1チャンクに複数エントリ): 全エントリのparent_cmdが
        # 完了済の場合に限りchunk全体を移動する。1件でも未完了・不明
        # (parent_cmd欠落含む)ならchunk全体をkeepに残す(混在fail-safeを維持。
        # 混在chunkへの対応強化はscope外)。
        if all(e.get('parent_cmd') in parent_cmds for e in parsed):
            moved_chunks.append(chunk)
            moved_list_chunk_count += 1
            moved_list_entry_count += len(parsed)
            moved_entry_count += len(parsed)
        else:
            keep_chunks.append(chunk)
            kept_list_mixed_chunk_count += 1
            kept_list_mixed_entry_count += len(parsed)
        continue

    # dict でも「全エントリdictのlist」でもない(空list・scalar・None・
    # 非dictエントリを含むlist等) — 完了判定不能として常にkeepする(fail-safe)。
    keep_chunks.append(chunk)
    kept_other_chunk_count += 1

if not moved_chunks:
    print(
        f'[ashigaru_report_lock] 0件移動しました '
        f'(一致するエントリなし。list形式で一部未完了のためkeepしたchunk: '
        f'{kept_list_mixed_chunk_count}件〈entries {kept_list_mixed_entry_count}件〉、'
        f'判定対象外〈非dict/非list形式〉chunk数: {kept_other_chunk_count})'
    )
    sys.exit(0)


def join_chunks(items):
    normalized = [c.strip('\n') + '\n' for c in items]
    return '---\n'.join(normalized)


new_report_content = join_chunks(keep_chunks) if keep_chunks else EMPTY_REPORT_STUB

if os.path.exists(archive_path) and os.path.getsize(archive_path) > 0:
    with open(archive_path, encoding='utf-8') as f:
        existing_archive = f.read()
    existing_archive_norm = existing_archive if existing_archive.endswith('\n') else existing_archive + '\n'
    new_archive_content = existing_archive_norm + '---\n' + join_chunks(moved_chunks)
else:
    new_archive_content = join_chunks(moved_chunks)


atomic_write(archive_path, new_archive_content)
atomic_write(report_path, new_report_content)

print(
    f'[ashigaru_report_lock] {moved_entry_count}件を archive へ移動しました'
    f'(dict形式chunk: {moved_dict_chunk_count}件、'
    f'list形式chunk全体移動: {moved_list_chunk_count}件〈entries {moved_list_entry_count}件〉)。'
    f'残り{len(keep_chunks)}chunk'
    f'(list形式で一部未完了のためkeepしたchunk: {kept_list_mixed_chunk_count}件'
    f'〈entries {kept_list_mixed_entry_count}件〉、'
    f'判定対象外〈非dict/非list形式〉chunk: {kept_other_chunk_count}件)'
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
                echo "[ashigaru_report_lock] ロック取得タイムアウト (試行 $attempt/$max_attempts)、再試行します..." >&2
                sleep 1
            else
                echo "[ashigaru_report_lock] $max_attempts 回試行してもロックを取得できませんでした" >&2
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
