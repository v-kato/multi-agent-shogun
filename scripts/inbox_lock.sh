#!/usr/bin/env bash
# inbox_lock.sh — queue/inbox/*.yaml の既読更新(mark-read)を、inbox_write.sh /
# inbox_watcher.sh と同じロックファイル(${INBOX}.lock / ${INBOX}.lock.d)を
# 共有して排他制御するラッパー (cmd_706 Phase B)。
#
# 背景: flock は advisory であり、全ての書き手が同じロックを取らない限り
# 意味を持たない。受信側エージェント自身の既読更新(旧: Edit toolでの直接
# 書換え)はロックを取らず、inbox_write.shの並行書込みと競合すると行ずれ・
# インデント崩れを起こしていた。本スクリプトは cmd_699 (gunshi_report_lock.sh)
# と同型のロック共有パターンを受信箱に適用し、既読更新もロック配下の
# read-modify-writeとして原子化する。設計の詳細・根拠は
# context/cmd_706_design.md (Phase A確定版・redo2) を正本とする。
#
# ★認可層の撤去について (cmd_706 Phase B redo1):
# 初版は呼び出し元(caller)をtmux `@agent_id`で識別し、他者inbox操作
# (`--repair`)をkaro限定で許可する認可層(_inbox_lock_get_caller /
# _inbox_lock_authorize)を持っていた。軍師QCが、実inboxを一切変更せずに
# `TMUX_PANE`環境変数を他agentのpane IDへ差し替えるだけで`@agent_id`を
# 詐称できることを独立再現し、将軍裁定によりこの認可層そのものを撤去した
# (「TTY照合方式への再設計」ではなく撤去)。理由:
#   (1) 現在どの足軽もEdit toolで任意inbox YAMLを書き換えられ、認可は
#       元々存在しない。本スクリプトに認可が無くとも現状より悪化しない。
#   (2) 本スクリプトの目的はYAML破損防止であり権限分離ではない。ロック
#       共有のみで目的は達する。
#   (3) 家老による他agentのinbox修復は正当な運用(2026-08-17に実例あり)
#       であり、厳格な自分専用ロックはこれを壊す。認可を作れば例外
#       (cross-agent repair)が要り、例外があれば詐称の的が残る。
# normal/repairの2モードはcaller-target一致判定という認可ロジックに
# 存在理由が紐づいていたため、認可撤去に伴いモードを分ける理由も消えた。
# よって`--repair`フラグ自体を廃止し、単一経路(`<agent_id>`を第一引数に
# 取るだけ)へ統合した。詳細・撤去理由の全文はcontext/cmd_706_design.md
# §3.4.2(無効化・更新済み)を参照。
#
# 使い方:
#   bash scripts/inbox_lock.sh mark-read <agent_id> --id <msg_id> [<msg_id> ...]
#   bash scripts/inbox_lock.sh archive   <agent_id> --id <msg_id> [<msg_id> ...]
#
# <agent_id>: 対象受信箱の所有者。固定allowlist(下記)への完全一致のみ受理する。
#             他agentのinboxを対象にしてよい(認可判定を行わない)。
# --id: 対象とするメッセージIDを1件以上指定する(省略・0件は使い方エラー)。
#
# raw --all(ロック取得時点の全read:falseを無条件既読化する動詞)はTOCTOUを
# 生むため標準I/Fに存在しない。「全件処理」は呼び出し元が事前に読んだ
# read:false一覧のIDを--idへ明示列挙して表現する。archiveサブコマンドも
# 同じ理由で「read:true全件」のような暗黙一括指定は持たず、--idで明示
# 列挙されたものだけを扱う (cmd_734 A-3)。
#
# ★archiveサブコマンド (cmd_734 A-3):
# 指定--idの各エントリを、mark-readと同じロック(対象inboxの${INBOX}.lock /
# ${INBOX}.lock.d)の下でqueue/inbox/archive/<agent_id>.yamlへ追記し、元inbox
# から削除する。1件でもread:falseなら全体を拒否する(exit 6・all-or-nothing、
# A-2「read:falseは1件も動かすな」の安全策)。書込順序はarchive→inboxの順
# (逆ではない): 途中でクラッシュしても「両方に残る(重複・後で気付ける)」
# に倒し、「両方から消える(消失)」には倒さない。archive側に既に同idが
# 存在する場合(上記クラッシュ後の再実行等)は再追記せずスキップする。
#
# exit code:
#   0  成功(指定idを処理した、またはmark-readで既に既読につき変更不要だった)
#   1  使い方エラー(--id未指定/0件、未知の引数、不明なサブコマンド 等)
#   2  対象inboxファイルが存在しない
#   3  指定--idのうち1件以上がinbox内に存在しない(all-or-nothing)
#   4  ロック取得失敗(5秒タイムアウト×3回試行後も失敗)
#   5  agent_idがallowlistに一致しない、pre-lock path resolutionの検証に
#      失敗した、または書込直前のrealpath二重確認(H-1)に失敗した
#   6  archive限定: 指定--idのうち1件以上がread:false(A-2安全策・archive不可)
#
# ★監査ログ(参考値・認可判断には使わない): 成功時、標準エラーに
# `[inbox_lock] AUDIT: target=<agent_id> ids=<...> caller_ref=<値> at=<timestamp>`
# を出力する。`caller_ref`は呼び出し時点の`TMUX_PANE`から解決できた
# `@agent_id`(解決できなければ`unknown`)であり、TMUX_PANE環境変数を
# 書き換えるだけで偽装できる値である。事後の状況把握用のヒントに留め、
# 正当性の証明や認可判定には一切用いない。

# ─── Testing guard ───
# __INBOX_LOCK_TESTING__=1 のとき、set -e を適用せず、末尾の
# 引数解析・dispatchブロックも実行しない。test はこのモードでsourceして
# 内部関数(allowlist検証・pathガード)を直接呼び出す(方式(a))。
if [ "${__INBOX_LOCK_TESTING__:-}" != "1" ]; then
    set -e
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="$SCRIPT_DIR/.venv/bin/python3"

_INBOX_LOCK_ALLOWLIST="shogun karo gunshi ashigaru1 ashigaru2 ashigaru3 ashigaru4 ashigaru5 ashigaru6 ashigaru7"

usage() {
    echo "使い方: inbox_lock.sh mark-read <agent_id> --id <msg_id> [<msg_id> ...]" >&2
    echo "      : inbox_lock.sh archive   <agent_id> --id <msg_id> [<msg_id> ...]" >&2
}

# ─── allowlist検証 (A-3 §3.4.1) ───
_inbox_lock_allowlist_check() {
    local candidate="$1"
    local a
    for a in $_INBOX_LOCK_ALLOWLIST; do
        [ "$a" = "$candidate" ] && return 0
    done
    return 1
}

# ─── path resolution固定の第二防御 (A-3 §3.4.1) ───
# <agent_id>はallowlist(完全一致)を通過した固定文字列のみを取りうるため、
# 通常運用でこのガードが発火することはない。symlink差し替え等による迂回の
# フェイルセーフとして、対象ファイルが既に存在しsymlinkである場合、その
# 実体がqueue/inbox配下に留まっていることを確認する。
# ★これはロック取得"前"に一度だけ呼ばれる第一防御。ロック取得後・
# 実際の書込直前(os.replace直前)にも独立した第二防御(realpath二重確認、
# H-1)がPython側に存在する(下記PYEOF内)。両者は判定タイミングが異なり、
# 互いを代替しない。
_inbox_lock_path_guard_dir() {
    local dir="$1" candidate="$2"
    local dir_real
    dir_real="$(cd "$dir" 2>/dev/null && pwd -P)" || return 1
    if [ -L "$candidate" ]; then
        local link_real
        link_real="$(cd "$(dirname "$(readlink -f "$candidate")")" 2>/dev/null && pwd -P)" || return 1
        [ "$link_real" = "$dir_real" ] || return 1
    fi
    return 0
}

_inbox_lock_path_guard() {
    local target="$1"
    _inbox_lock_path_guard_dir "$SCRIPT_DIR/queue/inbox" "$SCRIPT_DIR/queue/inbox/${target}.yaml"
}

# ─── 監査参考値の取得(認可判断には一切使わない・詐称可能) ───
# tmux lookupが失敗する状況(pane情報未設定・tmux外実行・誤ったTMUX_PANE等)
# では"unknown"を返す。戻り値は常に0(標準出力に値を1行返すだけ)であり、
# 処理継続可否には一切影響しない(fail-closedしない)。
_inbox_lock_audit_ref() {
    local ref=""
    case "${TMUX_PANE:-}" in
        %[0-9]*)
            ref="$(tmux display-message -t "$TMUX_PANE" -p '#{@agent_id}' 2>/dev/null || true)"
            ;;
    esac
    if [ -n "$ref" ]; then
        echo "$ref"
    else
        echo "unknown"
    fi
}

# ─── ロック取得・解放 (gunshi_report_lock.sh の _acquire_lock/_release_lock を
# そのまま踏襲・パスのみ対象inboxのLOCKFILE/LOCK_DIRに差し替え) ───
_inbox_lock_acquire() {
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

_inbox_lock_release() {
    if command -v flock &>/dev/null; then
        exec 200>&-
    fi
    rmdir "$LOCK_DIR" 2>/dev/null || true
}

# ─── Production entrypoint ───
if [ "${__INBOX_LOCK_TESTING__:-}" != "1" ]; then

ACTION="${1:-}"
case "$ACTION" in
    mark-read|archive)
        ;;
    *)
        usage
        exit 1
        ;;
esac
shift || true

TARGET="${1:-}"
case "$TARGET" in
    ""|-*)
        usage
        exit 1
        ;;
esac
shift || true

IDS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --id)
            shift
            # option様token(--で始まる)が現れたら値走査を打ち切り、外側の
            # dispatchへ処理を戻す。次の--idなら継続扱い、それ以外の
            # --xxxならouter caseの*)分岐でexit 1になる (H-3)。
            while [ $# -gt 0 ]; do
                case "$1" in
                    --*)
                        break
                        ;;
                esac
                IDS+=("$1")
                shift
            done
            ;;
        *)
            usage
            exit 1
            ;;
    esac
done

if [ ${#IDS[@]} -eq 0 ]; then
    usage
    exit 1
fi

if ! _inbox_lock_allowlist_check "$TARGET"; then
    echo "[inbox_lock] エラー: agent_id '$TARGET' はallowlistに一致しません" >&2
    exit 5
fi

if ! _inbox_lock_path_guard "$TARGET"; then
    echo "[inbox_lock] エラー: path resolutionの検証に失敗しました(target=$TARGET)" >&2
    exit 5
fi

INBOX="$SCRIPT_DIR/queue/inbox/${TARGET}.yaml"
if [ ! -f "$INBOX" ]; then
    echo "[inbox_lock] エラー: 対象inboxファイルが存在しません: $INBOX" >&2
    exit 2
fi

# ★書込直前のrealpath二重確認 (H-1・design§3.4.1) の信頼済みアンカー。
# _inbox_lock_path_guardのpre-lock検証(ロック取得前に一度だけ実行)とは
# 別に、ロック取得後・実際の書込直前にPython側で再取得するinbox_pathの
# 実体親ディレクトリと突き合わせる基準値として、ここで確定させる。
INBOX_DIR_REAL="$(cd "$SCRIPT_DIR/queue/inbox" 2>/dev/null && pwd -P)"
if [ -z "$INBOX_DIR_REAL" ]; then
    echo "[inbox_lock] エラー: queue/inboxの実体解決に失敗しました" >&2
    exit 5
fi

LOCKFILE="${INBOX}.lock"
LOCK_DIR="${LOCKFILE}.d"

AUDIT_REF="$(_inbox_lock_audit_ref)"

# ★archive専用のパス確定 (cmd_734 A-3)。mark-readでは未使用のため空のまま。
ARCHIVE_FILE=""
ARCHIVE_DIR_REAL=""
if [ "$ACTION" = "archive" ]; then
    ARCHIVE_DIR="$SCRIPT_DIR/queue/inbox/archive"
    mkdir -p "$ARCHIVE_DIR"
    ARCHIVE_DIR_REAL="$(cd "$ARCHIVE_DIR" 2>/dev/null && pwd -P)"
    if [ -z "$ARCHIVE_DIR_REAL" ]; then
        echo "[inbox_lock] エラー: queue/inbox/archiveの実体解決に失敗しました" >&2
        exit 5
    fi
    case "$ARCHIVE_DIR_REAL" in
        "$INBOX_DIR_REAL"/*) ;;
        *)
            echo "[inbox_lock] エラー: queue/inbox/archiveがqueue/inbox配下から外れています" >&2
            exit 5
            ;;
    esac
    ARCHIVE_FILE="$ARCHIVE_DIR/${TARGET}.yaml"
    if ! _inbox_lock_path_guard_dir "$ARCHIVE_DIR" "$ARCHIVE_FILE"; then
        echo "[inbox_lock] エラー: path resolutionの検証に失敗しました(archive target=$TARGET)" >&2
        exit 5
    fi
fi

attempt=0
max_attempts=3
while [ $attempt -lt $max_attempts ]; do
    if _inbox_lock_acquire; then
        trap _inbox_lock_release EXIT
        if [ "$ACTION" = "archive" ]; then
            if "$PYTHON" - "$INBOX_DIR_REAL" "$ARCHIVE_DIR_REAL" "$INBOX" "$ARCHIVE_FILE" "${IDS[@]}" <<'PYEOF'
import os
import sys
import tempfile

import yaml

trusted_inbox_dir_real = sys.argv[1]
trusted_archive_dir_real = sys.argv[2]
inbox_path = sys.argv[3]
archive_path = sys.argv[4]
target_ids = sys.argv[5:]

with open(inbox_path, encoding='utf-8') as f:
    data = yaml.safe_load(f) or {}

messages = data.get('messages') or []
by_id = {m.get('id'): m for m in messages if isinstance(m, dict) and m.get('id')}

missing = [i for i in target_ids if i not in by_id]
if missing:
    print('[inbox_lock] エラー: 次のidがinbox内に存在しません: ' + ', '.join(missing), file=sys.stderr)
    sys.exit(3)

unread = [i for i in target_ids if not by_id[i].get('read', False)]
if unread:
    print('[inbox_lock] エラー: 次のidはread:falseのためarchive不可: ' + ', '.join(unread), file=sys.stderr)
    sys.exit(6)

target_id_set = set(target_ids)
to_archive = [m for m in messages if m.get('id') in target_id_set]
remaining = [m for m in messages if m.get('id') not in target_id_set]

if os.path.exists(archive_path):
    with open(archive_path, encoding='utf-8') as f:
        archive_data = yaml.safe_load(f) or {}
else:
    archive_data = {}
archive_messages = archive_data.get('messages') or []
existing_archive_ids = {m.get('id') for m in archive_messages if isinstance(m, dict)}
appended = [m for m in to_archive if m.get('id') not in existing_archive_ids]
archive_messages.extend(appended)
archive_data['messages'] = archive_messages


def _atomic_write(path, trusted_dir_real, payload):
    d = os.path.dirname(path) or '.'
    fd, tmp = tempfile.mkstemp(dir=d, suffix='.tmp')
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            yaml.safe_dump(payload, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
        # ★書込直前のrealpath二重確認 (H-1と同じ設計。mark-readはinbox
        # 側のみだが、archiveはinbox/archive両ファイルに適用する)。
        try:
            current_parent_real = os.path.dirname(os.path.realpath(path))
        except OSError:
            current_parent_real = None
        if current_parent_real != trusted_dir_real:
            print('[inbox_lock] エラー: 書込直前のrealpath検証に失敗しました(target=' + path + ')', file=sys.stderr)
            os.unlink(tmp)
            sys.exit(5)
        os.replace(tmp, path)
    except SystemExit:
        raise
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


# ★書込順序: archive→inboxの順(逆ではない)。途中でクラッシュしても
# 「両方に残る(重複・後で気付ける)」に倒し、「両方から消える(消失)」
# には倒さない。
_atomic_write(archive_path, trusted_archive_dir_real, archive_data)

data['messages'] = remaining
_atomic_write(inbox_path, trusted_inbox_dir_real, data)

skipped = len(to_archive) - len(appended)
print(
    f'[inbox_lock] {len(appended)}件をarchiveへ退避し、元inboxから{len(to_archive)}件削除しました'
    f'(archive側重複スキップ{skipped}件)'
)
PYEOF
            then
                STATUS=0
            else
                STATUS=$?
            fi
        else
            if "$PYTHON" - "$INBOX_DIR_REAL" "$INBOX" "${IDS[@]}" <<'PYEOF'
import os
import sys
import tempfile

import yaml

trusted_inbox_dir_real = sys.argv[1]
inbox_path = sys.argv[2]
target_ids = sys.argv[3:]

with open(inbox_path, encoding='utf-8') as f:
    data = yaml.safe_load(f) or {}

messages = data.get('messages') or []
by_id = {m.get('id'): m for m in messages if isinstance(m, dict) and m.get('id')}

missing = [i for i in target_ids if i not in by_id]
if missing:
    print('[inbox_lock] エラー: 次のidがinbox内に存在しません: ' + ', '.join(missing), file=sys.stderr)
    sys.exit(3)

changed = 0
for i in target_ids:
    m = by_id[i]
    if not m.get('read', False):
        m['read'] = True
        changed += 1

if changed > 0:
    d = os.path.dirname(inbox_path) or '.'
    fd, tmp = tempfile.mkstemp(dir=d, suffix='.tmp')
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            yaml.safe_dump(data, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
        # ★書込直前のrealpath二重確認 (H-1・design§3.4.1)。pre-lock guard
        # (_inbox_lock_path_guard)はロック取得前に一度だけ判定するため、
        # ロック取得からここに至るまでの間にsymlink差替え等でinbox_path
        # の実体が変わっていないかを、os.replace直前に再確認する。
        try:
            current_parent_real = os.path.dirname(os.path.realpath(inbox_path))
        except OSError:
            current_parent_real = None
        if current_parent_real != trusted_inbox_dir_real:
            print('[inbox_lock] エラー: 書込直前のrealpath検証に失敗しました(target=' + inbox_path + ')', file=sys.stderr)
            os.unlink(tmp)
            sys.exit(5)
        os.replace(tmp, inbox_path)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise

print(f'[inbox_lock] {changed}件を既読化しました')
PYEOF
            then
                STATUS=0
            else
                STATUS=$?
            fi
        fi
        _inbox_lock_release
        trap - EXIT

        if [ "$STATUS" -eq 0 ]; then
            ID_LIST="$(IFS=,; echo "${IDS[*]}")"
            echo "[inbox_lock] AUDIT: target=$TARGET ids=$ID_LIST caller_ref=$AUDIT_REF at=$(date "+%Y-%m-%dT%H:%M:%S%z")" >&2
            exit 0
        elif [ "$STATUS" -eq 3 ] || [ "$STATUS" -eq 6 ]; then
            exit "$STATUS"
        elif [ "$STATUS" -eq 5 ]; then
            # 書込直前realpath検証failure (H-1) はリトライしても結果が
            # 変わらない確定的な拒否のため、即座にexit 5で終了する。
            exit 5
        fi
        attempt=$((attempt + 1))
        [ $attempt -lt $max_attempts ] && sleep 1
    else
        attempt=$((attempt + 1))
        if [ $attempt -lt $max_attempts ]; then
            echo "[inbox_lock] ロック取得タイムアウト (試行 $attempt/$max_attempts)、再試行します..." >&2
            sleep 1
        else
            echo "[inbox_lock] $max_attempts 回試行してもロックを取得できませんでした" >&2
            exit 4
        fi
    fi
done
exit 1

fi
