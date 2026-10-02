#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# scripts/permission_orphans.sh — 権限要求の孤児記録の計数と退避 (cmd_799 ⑤)
# ═══════════════════════════════════════════════════════════════
#
# queue/state/permission_requests/ の記録ファイルを3種に分類する。分類の
# 定義は inbox_watcher.sh の has_pending_permission_request() と同一
# (_permission_request_resolved / _permission_request_failsafe_expired):
#
#   resolved : `hook_result:` を持つ(hookが退出を記帳済み)
#   pending  : `hook_result:` が無く、received_at+timeout+マージン(既定
#              1800+10秒)を超過していない(hookが待機中でありうる)。
#              received_atが読めない記録も、watcher同様「超過していない」
#              側=pendingへ倒す。
#   orphan   : `hook_result:` が無く、received_atからtimeout+マージンを
#              超過している。hook自身のdeadline(timeout−マージン)を過ぎて
#              いるため、hookは生きていない(SIGKILL・クラッシュ・再起動、
#              またはhook_result導入前の旧版の記録)。★watcherのguardは
#              超過した記録を既に無視する(送信は抑止されない)ので、孤児は
#              打鍵を止めない。「結果の無い記録」が残って未決に見える
#              だけの整理対象である。
#
# 使い方:
#   permission_orphans.sh [list]            計数と孤児の一覧(読み取りのみ)
#   permission_orphans.sh archive           退避の予行(何も動かさない)
#   permission_orphans.sh archive --apply   孤児だけを退避先へ mv する
#
# ★退避先: queue/state/permission_requests_orphaned/(同名で移す)。
#   ★削除はしない(rm系は一切呼ばない)。mv -n(上書きしない)で、退避先に
#   同名があれば移さず非0で終わる。決定ファイル(queue/state/
#   permission_decisions/)は監査ログなので触れない。pending・resolvedは
#   移さない。
#
# テスト用環境変数 (production では未設定。__ 始まりはtest専用):
#   __PERMISSION_ORPHANS_ROOT — プロジェクトroot上書き
# timeout/マージンはhook・watcherと同じ環境変数名で揃える:
#   PERMISSION_HOOK_TIMEOUT_SECONDS(既定1800) / __PERMISSION_HOOK_MARGIN_SECONDS(既定10)
#
set -uo pipefail

ROOT="${__PERMISSION_ORPHANS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REQUESTS_DIR="$ROOT/queue/state/permission_requests"
ORPHAN_DIR="$ROOT/queue/state/permission_requests_orphaned"
TIMEOUT_SECONDS="${PERMISSION_HOOK_TIMEOUT_SECONDS:-1800}"
MARGIN_SECONDS="${__PERMISSION_HOOK_MARGIN_SECONDS:-10}"

usage() {
    echo "usage: $(basename "$0") [list | archive [--apply]]" >&2
}

# 記録1件の分類を標準出力へ1語で返す(resolved|pending|orphan)。
# 判定はwatcherの_permission_request_resolved / _permission_request_failsafe_expired
# と同じ(grepで`hook_result:`・`received_at:`を読む)。
classify() {
    local req_file="$1" raw val epoch now

    if /usr/bin/grep -qE '^hook_result:' "$req_file" 2>/dev/null; then
        echo resolved
        return 0
    fi

    raw="$(/usr/bin/grep -m1 '^received_at:' "$req_file" 2>/dev/null)"
    if [ -z "$raw" ]; then
        echo pending
        return 0
    fi
    val="${raw#received_at:}"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%\'}"; val="${val#\'}"
    val="${val%\"}"; val="${val#\"}"
    val="${val%$'\r'}"

    if ! epoch="$(date -u -d "$val" +%s 2>/dev/null)" || [ -z "$epoch" ]; then
        echo pending
        return 0
    fi

    now="$(date -u +%s)"
    if [ $(( now - epoch )) -gt $(( TIMEOUT_SECONDS + MARGIN_SECONDS )) ]; then
        echo orphan
    else
        echo pending
    fi
}

# 孤児を ORPHAN_LIST(配列)へ、各分類の本数を COUNT_* へ集計する。
collect() {
    COUNT_TOTAL=0
    COUNT_RESOLVED=0
    COUNT_PENDING=0
    ORPHAN_LIST=()

    [ -d "$REQUESTS_DIR" ] || return 0

    local req_file kind
    while IFS= read -r -d '' req_file; do
        COUNT_TOTAL=$(( COUNT_TOTAL + 1 ))
        kind="$(classify "$req_file")"
        case "$kind" in
            resolved) COUNT_RESOLVED=$(( COUNT_RESOLVED + 1 )) ;;
            pending)  COUNT_PENDING=$(( COUNT_PENDING + 1 )) ;;
            orphan)   ORPHAN_LIST+=("$req_file") ;;
        esac
    done < <(find "$REQUESTS_DIR" -maxdepth 1 -type f -name '*.yaml' -print0 2>/dev/null | sort -z)
}

print_summary() {
    if [ ! -d "$REQUESTS_DIR" ]; then
        echo "記録ディレクトリが無い: $REQUESTS_DIR (権限要求がまだ一度も無い通常状態)"
    fi
    echo "total=${COUNT_TOTAL} resolved=${COUNT_RESOLVED} pending=${COUNT_PENDING} orphan=${#ORPHAN_LIST[@]}"
}

cmd_list() {
    collect
    print_summary
    local f
    for f in "${ORPHAN_LIST[@]+"${ORPHAN_LIST[@]}"}"; do
        echo "orphan: $(basename "$f") received_at=$(/usr/bin/grep -m1 '^received_at:' "$f" 2>/dev/null | sed "s/^received_at:[[:space:]]*//; s/['\"]//g")"
    done
    return 0
}

cmd_archive() {
    local apply="$1"
    collect
    print_summary

    if [ "${#ORPHAN_LIST[@]}" -eq 0 ]; then
        echo "退避対象の孤児は無い"
        return 0
    fi

    if [ "$apply" -ne 1 ]; then
        local f
        for f in "${ORPHAN_LIST[@]}"; do
            echo "[dry-run] would move: $(basename "$f") -> $ORPHAN_DIR/"
        done
        echo "予行のみ(何も動かしていない)。実行するには: $(basename "$0") archive --apply"
        return 0
    fi

    mkdir -p "$ORPHAN_DIR" || { echo "退避先を作れない: $ORPHAN_DIR" >&2; return 1; }

    local rc=0 f name
    for f in "${ORPHAN_LIST[@]}"; do
        name="$(basename "$f")"
        if [ -e "$ORPHAN_DIR/$name" ]; then
            echo "skip(退避先に同名あり・上書きしない): $name" >&2
            rc=1
            continue
        fi
        if mv -n -- "$f" "$ORPHAN_DIR/$name" && [ ! -e "$f" ] && [ -e "$ORPHAN_DIR/$name" ]; then
            echo "moved: $name -> $ORPHAN_DIR/"
        else
            echo "移動に失敗: $name" >&2
            rc=1
        fi
    done
    return "$rc"
}

main() {
    local sub="${1:-list}"
    case "$sub" in
        list)
            [ "$#" -le 1 ] || { usage; return 2; }
            cmd_list
            ;;
        archive)
            local apply=0
            if [ "$#" -ge 2 ]; then
                [ "$2" = "--apply" ] && [ "$#" -eq 2 ] || { usage; return 2; }
                apply=1
            fi
            cmd_archive "$apply"
            ;;
        *)
            usage
            return 2
            ;;
    esac
}

main "$@"
