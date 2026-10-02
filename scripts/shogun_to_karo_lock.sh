#!/usr/bin/env bash
# shogun_to_karo_lock.sh — queue/shogun_to_karo.yaml への新規cmd追記(append)・
# 既存cmdのフィールド更新(update)・既存cmdの削除(remove)を、共通の排他ロック
# (queue/.shogun_to_karo.lock)経由で行う (cmd_741 / cmd_741 redo1 / redo2)。
#
# 背景: flock は advisory であり、全ての書き手が同じロックを取らない限り
# 意味を持たない。本ファイル(cmd正本)には inbox_lock.sh / gunshi_report_lock.sh /
# ashigaru_report_lock.sh と異なりロック機構が無く、将軍・家老の双方が生の
# Read/Edit/Writeで並行書込みしうる状態だった。2026-09-01T17:2x頃、将軍が
# `cat >> queue/shogun_to_karo.yaml <<EOF ... EOF` で追記した際、直前エントリ
# (cmd_734)と新エントリ(cmd_735)の境界(`- ` で始まる区切り行)が消失し、
# cmd_735のtitle/timestamp/north_star/purpose/contentがcmd_734の同名フィールド
# へサイレント上書きされ、cmd_735がcmd_id別エントリとして参照不能になった
# (cmd_731/cmd_732でも同型)。データ本体は区切り行1行の挿入で復元済だが、
# 「1行消えるだけでcmdが消える」構造は残っていた。
#
# ★redo1での追加背景(G741-WRITER-COVERAGE-01): append専用lockだけでは
# 防げない事故がある。事故のraceはShogun appendとKaro read-modify-write
# (status更新・karo_note追記・archive移管時の削除)の組合せでも起きる。
# Karoが生Edit/Writeで既存ファイルをread-modify-writeすれば、lock下で
# 追加済みのcmdをKaroの古いsnapshotが丸ごと上書きし消し得る。そのため
# update/removeもappendと同じlock配下のread-modify-writeとして提供する。
#
# ★redo2での追加背景(軍師QC 2026-09-02T20:49:04、verdict:
# FAIL_REDO2_SCOPE_AMENDMENT_REQUIRED): redo1のlock本体(共有lock・
# LOCK_HELD・strict loader・cmd_id一意性検査)は独立Bats15/15 PASSで
# 成立と確認された一方、次の3点が是正対象として指摘された。
# (1) G741-R1-HEREDOC-01(blocker): 公式利用例の非引用`<<EOF`がcmd本文を
#     シェル展開し、内容改変・意図しないcommand実行を招き得た(隔離実測
#     で確認済み)。全公式例を`<<'EOF'`(quoted heredoc)へ統一する。
# (2) G741-R1-MODE-02(blocker_integrity): atomic_writeがtempfile.mkstemp
#     既定0600のままos.replaceし、既存canonicalの実際のmode(0755)を
#     書込みの度に静かに0600へ変えていた。既存targetがあればそのmodeを
#     tmpへ継承してから置換する。
# (3) G741-R1-TEST-HOOK-05(hardening_recommended): test専用チューニング
#     env varが呼び出し元シェルに残留していると、canonical実行でも
#     retry回数・timeout・成功後sleepが変わり得た。
#     SHOGUN_TO_KARO_LOCK_TEST_MODE=1 の明示設定が無い限り一切参照しない
#     test fixture専用modeへ限定する。
# 中核lock機構・YAML厳密性検査は redo2 でも再変更しない(据え置き)。
#
# ★設計条件: advisory lock は全ての書き手が同じlockを取らねば無意味である
# (cmd_695で学んだこと)。将軍は上記ヒアドキュメント形式でcmdを追記して
# いるため、将軍がその手の動きのまま使えるstdin(ヒアドキュメント)経路を
# 必須とする(gunshi_report_lock.sh / ashigaru_report_lock.sh の
# content_fileパス引数方式とは異なる。本ファイルは将軍の既存操作パターンを
# 壊さないことを優先する)。update も同じ理由でstdin(ヒアドキュメント)を
# 使う。removeは対象cmd_idの列挙のみであり、複数行入力の必要が無いため
# 引数方式とする。
#
# ★G741-R1-HEREDOC-01: 下記ヒアドキュメントは必ず `<<'EOF'`(quoted)を
# 使うこと。`<<EOF`(unquoted)ではシェルがヒアドキュメント本文中の
# `$VAR`・`${...}`・バッククォート・`$()`を、本スクリプトのstdinに渡る
# 前に展開してしまう。cmd content(command/purposeフィールド等)は自由
# 記述のMarkdown/コード/pathを含み得るため、内容破損だけでなく意図しない
# コマンド実行にもつながり得る(隔離実測で確認済み)。
#
# 使い方:
#   bash scripts/shogun_to_karo_lock.sh append <<'EOF'
#   - cmd_id: cmd_XXX
#     timestamp: '2026-09-02T18:00:00+09:00'
#     north_star: ...
#     ...
#   EOF
#
#   bash scripts/shogun_to_karo_lock.sh update <<'EOF'
#   - cmd_id: cmd_XXX
#     status: in_progress
#     karo_note: |
#       ...
#   EOF
#
#   bash scripts/shogun_to_karo_lock.sh remove cmd_XXX [cmd_YYY ...]
#
# append: 標準入力には、cmd_idを持つマッピングを1件以上含むYAML list
# (トップレベル `- cmd_id: ...` から始まる形)を渡すこと。複数cmdをまとめて
# 渡してもよい。既存ファイルおよび標準入力のいずれにもcmd_id重複が無い
# ことを検証し、標準入力のcmd_idが既存ファイルのcmd_idと重複する場合も
# 拒否する(cmd_id参照が曖昧になるため)。
#
# update: 標準入力には、cmd_idと更新したいフィールドのみを持つマッピングを
# 1件以上含むYAML listを渡す。各要素のcmd_idで既存エントリを1件特定し、
# cmd_id以外のフィールドを既存エントリへ上書き・追加マージする(cmd_id
# 自体は不変のlookup keyであり、update経由では変更できない)。対象cmd_idが
# 存在しない場合は何も書き換えず中断する。更新対象以外の既存エントリは
# 生テキストのまま一切変更しない(yaml.compose のノード開始位置から
# エントリ境界を特定し、対象エントリの生テキスト片だけを差し替える方式。
# ファイル全体を再ダンプしない=他エントリの整形・改行・コメントを壊さない)。
#
# remove: 引数に削除したいcmd_idを1件以上渡す。全て既存ファイルに存在する
# ことを確認したうえで、該当エントリの生テキスト片だけを取り除く(update同様、
# 削除対象外のエントリは一切変更しない)。archive側ファイル
# (shogun_to_karo_archive.yaml)への追記自体は対象外(呼び出し側が別途行う)。
# active queueからの削除だけを本lockと協調させる。
#
# 書込み後検証: 一時ファイルへ書いた結果を再度YAMLとしてパースし、
# (i) 妥当なYAMLか (ii) トップレベルがlistか (iii) cmd_idの重複が無いか
# (iv) 件数が期待通りか (v) update/removeでは対象cmd_idの変化が意図通りか
# を確認する。異常なら一時ファイルを破棄し、本番ファイルには一切触れず
# 非0 exitする(区切り行消失のような事故を、発生前に検知して食い止める)。
#
# 読み取りのみ(件数確認等)にはロックは不要。read-modify-write の一連
# (append/update/remove)だけをロックで囲む。
#
# ★mode/owner継承(G741-R1-MODE-02): 一時ファイルはtempfile.mkstempで
# 既定0600で作られるため、os.replaceでそのまま置換すると、既存targetの
# 実際のmode(例: 0755)が書込みの度に0600へ静かに劣化する。本スクリプトは
# 既存targetがあれば、そのmodeをos.replace前にtmpへ明示的に継承する。
# owner/groupも実行userと異なる場合はchownを試み、権限不足で失敗すれば
# 警告をstderrへ出す(黙殺しない。書込み自体は継続する)。
#
# ★YAML厳密性(G741-YAML-STRICTNESS-04): PyYAMLのsafe_loadは同一mapping内の
# 重複keyを後勝ちで黙って受理する。本スクリプトは重複keyを拒否する
# strict loaderを既存ファイル・標準入力の両方に使い、かつ結合/更新/削除後の
# cmd_id一意性を別途検査する(mapping内重複keyの検出だけでは、異なる要素間で
# 同じcmd_idを使う曖昧参照は検出できないため)。
#
# exit code:
#   0  成功
#   1  使い方エラー — 未知のaction、append/updateで標準入力が空・不正YAML・
#      非list・cmd_id欠落要素を含む・標準入力内でcmd_idが重複、appendで
#      標準入力のcmd_idが既存ファイルと重複、updateでcmd_id以外の更新
#      フィールドが1件も無い要素がある、removeで引数が0件・引数内でcmd_id
#      重複
#   2  書込み前の検証失敗 — 既存ファイルの解析失敗、既存ファイルのトップ
#      レベルがlistでない、既存ファイル内でcmd_idが重複、update/removeで
#      対象cmd_idが既存ファイルに見つからない
#   3  書込み後の検証失敗 — 結合/更新/削除後の再パース失敗、cmd_id件数が
#      期待と不一致、重複cmd_idが発生、updateで更新内容が反映されていない、
#      removeで削除対象が残存 or 削除対象外が消失
#   4  ロック取得失敗(既定: 5秒タイムアウト×3回試行後も失敗)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="$SCRIPT_DIR/.venv/bin/python3"

TARGET="$SCRIPT_DIR/queue/shogun_to_karo.yaml"
LOCKFILE="$SCRIPT_DIR/queue/.shogun_to_karo.lock"
LOCK_DIR="${LOCKFILE}.d"

# ★テスト専用チューニング変数(G741-LOCK-OWNERSHIP-03の回帰テストを高速・
# 決定的に行うためのフック)。既定値は変更前と完全に同じ本番挙動を維持する。
# 通常運用(将軍・家老の実操作)ではこれらを一切設定しないこと。
#
# ★G741-R1-TEST-HOOK-05: 個別チューニング変数(SHOGUN_TO_KARO_LOCK_MKDIR_ITERS
# 等)は、呼び出し元シェルに以前のtest実行等で残留していても、
# SHOGUN_TO_KARO_LOCK_TEST_MODE=1 を明示的に設定しない限り一切参照しない
# (test fixture専用modeへの限定)。これにより、canonical実行(将軍・家老の
# 実操作)は残留env varの値に関わらず常に下記既定値のみで動作する。
if [ "${SHOGUN_TO_KARO_LOCK_TEST_MODE:-0}" = "1" ]; then
    LOCK_MKDIR_ITERS="${SHOGUN_TO_KARO_LOCK_MKDIR_ITERS:-50}"           # 既定: 50*0.1s=5s
    LOCK_MAX_ATTEMPTS="${SHOGUN_TO_KARO_LOCK_MAX_ATTEMPTS:-3}"
    LOCK_RETRY_SLEEP="${SHOGUN_TO_KARO_LOCK_RETRY_SLEEP:-1}"
    LOCK_FLOCK_TIMEOUT="${SHOGUN_TO_KARO_LOCK_FLOCK_TIMEOUT:-5}"
    # ★手動解放後・exit前に意図的にsleepを挟む(既定0=無効)。先行process手動
    # 解放後の遅延trap発火が後続所有dirを消さないことを試験するための専用フック。
    LOCK_TEST_DELAY_BEFORE_EXIT="${SHOGUN_TO_KARO_LOCK_TEST_DELAY_BEFORE_EXIT:-0}"
else
    LOCK_MKDIR_ITERS=50
    LOCK_MAX_ATTEMPTS=3
    LOCK_RETRY_SLEEP=1
    LOCK_FLOCK_TIMEOUT=5
    LOCK_TEST_DELAY_BEFORE_EXIT=0
fi

usage() {
    echo "使い方:" >&2
    echo "  shogun_to_karo_lock.sh append              (標準入力からYAML断片を読む)" >&2
    echo "  shogun_to_karo_lock.sh update              (標準入力からYAML断片を読む)" >&2
    echo "  shogun_to_karo_lock.sh remove <cmd_id> [<cmd_id> ...]" >&2
}

ACTION="${1:-}"
shift || true

REMOVE_IDS=()
case "$ACTION" in
    append|update)
        if [ $# -gt 0 ]; then
            usage
            exit 1
        fi
        ;;
    remove)
        if [ $# -lt 1 ]; then
            usage
            exit 1
        fi
        REMOVE_IDS=("$@")
        ;;
    *)
        usage
        exit 1
        ;;
esac

mkdir -p "$(dirname "$TARGET")"

# プロセス間ロック: mkdir で相互排他を確立し、flock があれば追加で使う。
# inbox_write.sh / gunshi_report_lock.sh / ashigaru_report_lock.sh と同じ
# 二重ロック方式。
#
# ★G741-LOCK-OWNERSHIP-03: LOCK_HELD で「自processがmkdirに成功したか」を
# 追跡する。_release_lock は LOCK_HELD=1 の時だけ rmdir し、直後に 0 へ戻す。
# これにより (a) ロック取得に一度も成功しなかったprocessのEXIT trapが他
# processの LOCK_DIR を消すことがなく、(b) 手動解放済みの場合はEXIT trapの
# 二度目の呼び出しが no-op になり、後から別processが取得したLOCK_DIRを
# 誤って消すこともない。
LOCK_HELD=0

_acquire_lock() {
    local i=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        sleep 0.1
        i=$((i + 1))
        [ "$i" -ge "$LOCK_MKDIR_ITERS" ] && return 1
    done
    LOCK_HELD=1

    if command -v flock &>/dev/null; then
        exec 200>"$LOCKFILE"
        if ! flock -w "$LOCK_FLOCK_TIMEOUT" 200; then
            rmdir "$LOCK_DIR" 2>/dev/null || true
            LOCK_HELD=0
            return 1
        fi
    fi
    return 0
}

_release_lock() {
    # ★注意: `exec FD>&-` はリダイレクトのみのexec呼び出しであり、現在の
    # シェルへ永続的に作用する。ここで `2>/dev/null` を付けると、fd 200 の
    # close失敗を隠すつもりが「シェル全体のstderrを恒久的に/dev/nullへ
    # リダイレクトする」副作用を生み、以後のset -xトレースやエラー出力が
    # 全て消える(実測で確認した既知の落とし穴)。fd 200 が未openでも
    # `exec 200>&-` 自体は元々エラーにならないため、リダイレクトは付けない。
    if command -v flock &>/dev/null; then
        exec 200>&- || true
    fi
    if [ "$LOCK_HELD" = "1" ]; then
        rmdir "$LOCK_DIR" 2>/dev/null || true
        LOCK_HELD=0
    fi
}

# 標準入力(将軍・家老のヒアドキュメント)を一時ファイルへ保存する。Pythonを
# `python3 - <<'PYEOF' ... PYEOF` で起動するとヒアドキュメント全体が
# Pythonスクリプトのソースとしてstdinに渡るため、ユーザー入力は別途
# ファイル経由でPythonへ渡す必要がある。単一ファイルの mktemp/rm であり
# D002-E1(ディレクトリ削除限定)の対象外。removeは標準入力を使わないため
# STDIN_TMP は空のまま(作成しない)。
STDIN_TMP=""
_cleanup() {
    # ★注意: `[ -n "$STDIN_TMP" ] && rm -f ...` を最終文にすると、STDIN_TMP
    # が空(removeアクション)の時に左辺の失敗(exit 1)がこの関数の戻り値と
    # なり、EXIT trap経由で `exit "$STATUS"`(0のはず)を上書きしてしまう
    # (実測で確認した既知の落とし穴)。if で明示的に分岐し、この関数の
    # 終了statusが呼び出し側のexit codeへ漏れないようにする。
    _release_lock
    if [ -n "$STDIN_TMP" ]; then
        rm -f "$STDIN_TMP" 2>/dev/null || true
    fi
}
trap _cleanup EXIT

case "$ACTION" in
    append|update)
        STDIN_TMP="$(mktemp)"
        cat > "$STDIN_TMP"
        ;;
esac

attempt=0
STATUS=4
while [ "$attempt" -lt "$LOCK_MAX_ATTEMPTS" ]; do
    if _acquire_lock; then
        if "$PYTHON" - "$ACTION" "$TARGET" "$STDIN_TMP" "${REMOVE_IDS[@]}" <<'PYEOF'
import os
import stat
import sys
import tempfile
from collections import Counter

import yaml


class _StrictLoader(yaml.SafeLoader):
    """同一mapping内の重複keyを拒否するLoader (G741-YAML-STRICTNESS-04)。
    PyYAML標準のsafe_loadは重複keyを後勝ちで黙って受理するため、
    正本の書込みガードとしては不十分。"""


def _no_duplicate_keys_constructor(loader, node, deep=False):
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in mapping:
            raise yaml.constructor.ConstructorError(
                'while constructing a mapping', node.start_mark,
                f'重複キーを検出しました: {key!r}', key_node.start_mark,
            )
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


_StrictLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG,
    _no_duplicate_keys_constructor,
)


def _str_representer(dumper, data):
    style = '|' if '\n' in data else None
    return dumper.represent_scalar('tag:yaml.org,2002:str', data, style=style)


yaml.SafeDumper.add_representer(str, _str_representer)


def strict_load(text):
    return yaml.load(text, Loader=_StrictLoader)


def get_ids(parsed_list):
    return [e.get('cmd_id') for e in parsed_list if isinstance(e, dict) and e.get('cmd_id')]


def dup_of(ids):
    counts = Counter(ids)
    return sorted(k for k, n in counts.items() if n > 1)


def _line_start(text, idx):
    nl = text.rfind('\n', 0, idx)
    return nl + 1


def split_entries(text):
    """既にstrict_loadで妥当性確認済みのtextを前提に、トップレベルlistの
    各要素を `- ` prefixを含む生テキスト片へ分割する(yaml.composeは構築
    フェーズを実行しないためLoaderの重複key検出は効かない — 事前の
    strict_load成功が前提条件)。戻り値: [(cmd_id_or_None, raw_text), ...]。"""
    node = yaml.compose(text, Loader=yaml.SafeLoader)
    if node is None or not isinstance(node, yaml.SequenceNode):
        return []
    starts = [_line_start(text, c.start_mark.index) for c in node.value]
    bounds = starts + [len(text)]
    parsed = strict_load(text) or []
    entries = []
    for i in range(len(node.value)):
        raw = text[bounds[i]:bounds[i + 1]]
        cid = parsed[i].get('cmd_id') if isinstance(parsed[i], dict) else None
        entries.append((cid, raw))
    return entries


def read_existing(target_path):
    """戻り値: (existing_text, existing_parsed, before_count)。
    ファイル無し/空なら ('', [], 0)。壊れていれば標準エラーへ出力しexit 2。"""
    if not (os.path.exists(target_path) and os.path.getsize(target_path) > 0):
        return '', [], 0
    with open(target_path, encoding='utf-8', newline='') as f:
        existing_text = f.read()
    try:
        existing_parsed = strict_load(existing_text)
    except yaml.YAMLError as e:
        print(
            f'[shogun_to_karo_lock] エラー: 既存ファイルの解析に失敗したため、'
            f'変更を行わず中断します: {e}',
            file=sys.stderr,
        )
        sys.exit(2)
    if existing_parsed is None:
        existing_parsed = []
    if not isinstance(existing_parsed, list):
        print(
            '[shogun_to_karo_lock] エラー: 既存ファイルのトップレベルがlistでは'
            'ないため、変更を行わず中断します',
            file=sys.stderr,
        )
        sys.exit(2)
    existing_ids = get_ids(existing_parsed)
    dup = dup_of(existing_ids)
    if dup:
        print(
            f'[shogun_to_karo_lock] エラー: 既存ファイルに重複cmd_idがあるため、'
            f'変更を行わず中断します: {dup}',
            file=sys.stderr,
        )
        sys.exit(2)
    return existing_text, existing_parsed, len(existing_ids)


def atomic_write(target_path, combined_text, verify):
    """一時ファイルへ書き、verify(text)->(ok, message) で検証してから
    os.replaceする。NGならtmpを破棄しexit 3(本番ファイルは無傷)。

    G741-R1-MODE-02: 既存targetがあれば、そのmode(パーミッションbit)を
    os.replace前にtmpへ継承する。tempfile.mkstempのtmpは既定0600で作られる
    ため、継承しなければ既存targetの実際のmode(現canonical/privategitは
    0755)が書込みの度に0600へ静かに変わってしまう。owner/groupも
    「実行userと同じはず」という前提だけに頼らず、既存targetと異なる場合は
    chownを試み、権限不足で失敗した場合はその旨を警告として出す(黙殺しない。
    書込み自体は継続する)。
    """
    d = os.path.dirname(target_path) or '.'
    fd, tmp = tempfile.mkstemp(dir=d, suffix='.tmp')
    try:
        if os.path.exists(target_path):
            st = os.stat(target_path)
            os.chmod(tmp, stat.S_IMODE(st.st_mode))
            if (st.st_uid, st.st_gid) != (os.geteuid(), os.getegid()):
                try:
                    os.chown(tmp, st.st_uid, st.st_gid)
                except PermissionError:
                    print(
                        f'[shogun_to_karo_lock] 警告: 既存ファイルのowner/group'
                        f'(uid={st.st_uid}, gid={st.st_gid})を実行ユーザーの'
                        f'権限では引き継げませんでした。書込み自体は継続します'
                        f'(modeは継承済み)。',
                        file=sys.stderr,
                    )
        with os.fdopen(fd, 'w', encoding='utf-8', newline='') as f:
            f.write(combined_text)
        with open(tmp, encoding='utf-8', newline='') as f:
            verify_text = f.read()
        ok, message = verify(verify_text)
        if not ok:
            print(
                f'[shogun_to_karo_lock] エラー: 書込み後検証に失敗したため、'
                f'書込みを取り消しました: {message}',
                file=sys.stderr,
            )
            os.unlink(tmp)
            sys.exit(3)
        os.replace(tmp, target_path)
    except SystemExit:
        raise
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


action = sys.argv[1]
target_path = sys.argv[2]
stdin_path = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else None
remove_ids = sys.argv[4:] if action == 'remove' else []

if action == 'append':
    with open(stdin_path, encoding='utf-8') as f:
        new_text = f.read()

    if not new_text.strip():
        print('[shogun_to_karo_lock] エラー: 標準入力が空です', file=sys.stderr)
        sys.exit(1)

    try:
        new_parsed = strict_load(new_text)
    except yaml.YAMLError as e:
        print(f'[shogun_to_karo_lock] エラー: 標準入力が正しいYAMLではありません: {e}', file=sys.stderr)
        sys.exit(1)

    if not isinstance(new_parsed, list) or len(new_parsed) == 0:
        print(
            '[shogun_to_karo_lock] エラー: 標準入力はcmd_idを持つ要素を1件以上含む'
            'YAML list(`- cmd_id: cmd_XXX ...` から始まる形)でなければなりません',
            file=sys.stderr,
        )
        sys.exit(1)

    if not all(isinstance(e, dict) and e.get('cmd_id') for e in new_parsed):
        print(
            '[shogun_to_karo_lock] エラー: 標準入力の全要素がcmd_idを持つマッピングで'
            'なければなりません',
            file=sys.stderr,
        )
        sys.exit(1)

    new_ids = get_ids(new_parsed)
    dup_new = dup_of(new_ids)
    if dup_new:
        print(f'[shogun_to_karo_lock] エラー: 標準入力内でcmd_idが重複しています: {dup_new}', file=sys.stderr)
        sys.exit(1)

    new_count = len(new_parsed)

    existing_text, existing_parsed, before_count = read_existing(target_path)
    existing_ids = get_ids(existing_parsed)

    overlap = sorted(set(existing_ids) & set(new_ids))
    if overlap:
        print(
            f'[shogun_to_karo_lock] エラー: 標準入力のcmd_idが既存ファイルと重複して'
            f'います(既存参照が曖昧になるため中断): {overlap}',
            file=sys.stderr,
        )
        sys.exit(1)

    existing_norm = '' if not existing_text else (
        existing_text if existing_text.endswith('\n') else existing_text + '\n'
    )
    new_text_norm = new_text if new_text.endswith('\n') else new_text + '\n'
    combined = existing_norm + new_text_norm
    expected_count = before_count + new_count

    def _verify(verify_text):
        try:
            verify_parsed = strict_load(verify_text)
        except yaml.YAMLError as e:
            return False, f'YAML解析に失敗: {e}'
        if not isinstance(verify_parsed, list):
            return False, 'トップレベルがlistでなくなった'
        v_ids = get_ids(verify_parsed)
        dup = dup_of(v_ids)
        if dup:
            return False, f'重複cmd_idが発生した: {dup}'
        after_count = len(v_ids)
        if after_count != expected_count:
            return False, (
                f'cmd_id要素数が一致しない(書込み前{before_count}件+新規{new_count}件='
                f'期待{expected_count}件 に対し実際{after_count}件)'
            )
        return True, ''

    atomic_write(target_path, combined, _verify)
    print(
        f'[shogun_to_karo_lock] {new_count}件追記しました'
        f'(cmd_id要素数: {before_count} → {expected_count})'
    )

elif action == 'update':
    with open(stdin_path, encoding='utf-8') as f:
        upd_text = f.read()

    if not upd_text.strip():
        print('[shogun_to_karo_lock] エラー: 標準入力が空です', file=sys.stderr)
        sys.exit(1)

    try:
        upd_parsed = strict_load(upd_text)
    except yaml.YAMLError as e:
        print(f'[shogun_to_karo_lock] エラー: 標準入力が正しいYAMLではありません: {e}', file=sys.stderr)
        sys.exit(1)

    if not isinstance(upd_parsed, list) or len(upd_parsed) == 0:
        print(
            '[shogun_to_karo_lock] エラー: 標準入力はcmd_idを持つ要素を1件以上含む'
            'YAML listでなければなりません',
            file=sys.stderr,
        )
        sys.exit(1)

    if not all(isinstance(e, dict) and e.get('cmd_id') for e in upd_parsed):
        print(
            '[shogun_to_karo_lock] エラー: 標準入力の全要素がcmd_idを持つマッピングで'
            'なければなりません',
            file=sys.stderr,
        )
        sys.exit(1)

    for e in upd_parsed:
        if len(e) < 2:
            print(
                f"[shogun_to_karo_lock] エラー: cmd_id {e.get('cmd_id')!r} に更新対象"
                f"フィールドがありません(cmd_id以外に最低1件必要です)",
                file=sys.stderr,
            )
            sys.exit(1)

    upd_ids = [e['cmd_id'] for e in upd_parsed]
    dup_upd = dup_of(upd_ids)
    if dup_upd:
        print(
            f'[shogun_to_karo_lock] エラー: 標準入力内でcmd_idが重複しています'
            f'(どちらが有効か曖昧なため中断): {dup_upd}',
            file=sys.stderr,
        )
        sys.exit(1)

    existing_text, existing_parsed, before_count = read_existing(target_path)
    if before_count == 0:
        print('[shogun_to_karo_lock] エラー: 既存ファイルが空または存在しないため、更新対象がありません', file=sys.stderr)
        sys.exit(2)

    entries = split_entries(existing_text)
    id_to_index = {cid: i for i, (cid, _raw) in enumerate(entries) if cid}

    missing = sorted(cid for cid in upd_ids if cid not in id_to_index)
    if missing:
        print(f'[shogun_to_karo_lock] エラー: 更新対象のcmd_idが既存ファイルに見つかりません: {missing}', file=sys.stderr)
        sys.exit(2)

    updated_blocks = {}
    for upd in upd_parsed:
        cid = upd['cmd_id']
        idx = id_to_index[cid]
        original_entry = existing_parsed[idx]
        merged = dict(original_entry)
        for k, v in upd.items():
            if k == 'cmd_id':
                continue
            merged[k] = v
        dumped = yaml.safe_dump(
            [merged], allow_unicode=True, sort_keys=False, default_flow_style=False,
        )
        updated_blocks[idx] = dumped if dumped.endswith('\n') else dumped + '\n'

    pieces = [updated_blocks.get(i, raw) for i, (_cid, raw) in enumerate(entries)]
    combined = ''.join(pieces)

    def _verify(verify_text):
        try:
            verify_parsed = strict_load(verify_text)
        except yaml.YAMLError as e:
            return False, f'YAML解析に失敗: {e}'
        if not isinstance(verify_parsed, list):
            return False, 'トップレベルがlistでなくなった'
        v_ids = get_ids(verify_parsed)
        dup = dup_of(v_ids)
        if dup:
            return False, f'重複cmd_idが発生した: {dup}'
        if len(v_ids) != before_count:
            return False, f'cmd_id要素数が更新前後で変化した(更新前{before_count}件、更新後{len(v_ids)}件)'
        if set(v_ids) != set(get_ids(existing_parsed)):
            return False, 'cmd_idの集合が更新前後で変化した'
        by_id = {e.get('cmd_id'): e for e in verify_parsed if isinstance(e, dict)}
        for upd in upd_parsed:
            cid = upd['cmd_id']
            entry = by_id.get(cid)
            if entry is None:
                return False, f'{cid} の更新後エントリが見つからない'
            for k, v in upd.items():
                if k == 'cmd_id':
                    continue
                if entry.get(k) != v:
                    return False, f'{cid}.{k} の更新が反映されていない'
        return True, ''

    atomic_write(target_path, combined, _verify)
    print(f'[shogun_to_karo_lock] {len(upd_parsed)}件更新しました(対象cmd_id: {sorted(upd_ids)})')

elif action == 'remove':
    if not remove_ids:
        print('[shogun_to_karo_lock] エラー: 削除対象のcmd_idを1件以上指定してください', file=sys.stderr)
        sys.exit(1)

    dup_arg = dup_of(remove_ids)
    if dup_arg:
        print(f'[shogun_to_karo_lock] エラー: 削除対象引数内でcmd_idが重複しています: {dup_arg}', file=sys.stderr)
        sys.exit(1)

    existing_text, existing_parsed, before_count = read_existing(target_path)
    if before_count == 0:
        print('[shogun_to_karo_lock] エラー: 既存ファイルが空または存在しないため、削除対象がありません', file=sys.stderr)
        sys.exit(2)

    entries = split_entries(existing_text)
    existing_id_set = {cid for cid, _raw in entries if cid}

    missing = sorted(cid for cid in remove_ids if cid not in existing_id_set)
    if missing:
        print(f'[shogun_to_karo_lock] エラー: 削除対象のcmd_idが既存ファイルに見つかりません: {missing}', file=sys.stderr)
        sys.exit(2)

    remove_set = set(remove_ids)
    combined = ''.join(raw for cid, raw in entries if cid not in remove_set)
    expected_count = before_count - len(remove_set)

    def _verify(verify_text):
        try:
            verify_parsed = strict_load(verify_text) or []
        except yaml.YAMLError as e:
            return False, f'YAML解析に失敗: {e}'
        if not isinstance(verify_parsed, list):
            return False, 'トップレベルがlistでなくなった'
        v_ids = get_ids(verify_parsed)
        dup = dup_of(v_ids)
        if dup:
            return False, f'重複cmd_idが発生した: {dup}'
        if len(v_ids) != expected_count:
            return False, (
                f'cmd_id要素数が一致しない(削除前{before_count}件-削除{len(remove_set)}件='
                f'期待{expected_count}件 に対し実際{len(v_ids)}件)'
            )
        remaining_overlap = remove_set & set(v_ids)
        if remaining_overlap:
            return False, f'削除対象のはずのcmd_idが残存している: {sorted(remaining_overlap)}'
        if not (existing_id_set - remove_set) <= set(v_ids):
            return False, '削除対象外のcmd_idが失われた'
        return True, ''

    atomic_write(target_path, combined, _verify)
    print(
        f'[shogun_to_karo_lock] {len(remove_set)}件削除しました'
        f'(cmd_id要素数: {before_count} → {expected_count})'
    )

else:
    print(f'[shogun_to_karo_lock] 内部エラー: 未知のaction: {action}', file=sys.stderr)
    sys.exit(1)
PYEOF
        then
            STATUS=0
        else
            STATUS=$?
        fi
        _release_lock
        if [ "$LOCK_TEST_DELAY_BEFORE_EXIT" != "0" ]; then
            sleep "$LOCK_TEST_DELAY_BEFORE_EXIT"
        fi
        # Python側のエラーは全て標準入力/既存ファイルの内容に起因する
        # 確定的なものであり、リトライしても結果は変わらないため、
        # ロック取得の成否に関わらずここで即exitする。
        break
    else
        attempt=$((attempt + 1))
        if [ "$attempt" -lt "$LOCK_MAX_ATTEMPTS" ]; then
            echo "[shogun_to_karo_lock] ロック取得タイムアウト (試行 $attempt/$LOCK_MAX_ATTEMPTS)、再試行します..." >&2
            sleep "$LOCK_RETRY_SLEEP"
        else
            echo "[shogun_to_karo_lock] $LOCK_MAX_ATTEMPTS 回試行してもロックを取得できませんでした" >&2
            STATUS=4
        fi
    fi
done

exit "$STATUS"
