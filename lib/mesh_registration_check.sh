#!/usr/bin/env bash
# lib/mesh_registration_check.sh — cmd_759 A-3 / cmd_784 Phase 1
# 出陣直後、claude paneのmesh登録(socket実在)をread-onlyで確認する。
#
# ★lib/pane_preflight.sh (cmd_754「自動打鍵の安全集合」) とは別物。
#   あちらは「動いているCLI paneへ自動打鍵してよいか」を判定し常に
#   禁止(0)を返す送信可否ゲートである。本ファイルは「起動直後の
#   claude paneがmeshへ登録されたか」をread-onlyで確認するだけであり、
#   送信可否判定・自動送信には一切関与しない。未登録であっても
#   本ファイルはpaneへ何も送らない(再起動もしない)。呼出側
#   (shutsujin_departure.sh)も同じ原則を守ること。
#
# ★socketの置場は「確認対象のclaudeプロセスが実際にbindした場所」と一致
#   させる(cmd_784・Claude Code 2.1.284)。呼出側shellの環境と対象
#   プロセスの環境は一致するとは限らないため、対象pid基準で決める。優先順:
#     1) MESH_SOCK_DIR の明示上書き(最優先)
#     2) 対象pidのセッション記録
#          <CLAUDE_CONFIG_DIR または ~/.claude>/sessions/<pid>.json
#        の messagingSocketPath(本体が実際にbindしたパスを記録している)。
#        pid が一致し、procStart が /proc/<pid>/stat のstarttimeと一致し、
#        絶対パスで basename が <pid>.sock のときだけ採用する(pid再利用に
#        よる古い記録を弾く)。記録が示す場所にsocketが無ければ、それが
#        そのまま「未登録」である(予測式へ逃がさない)。
#     3) 記録が使えないときの予測式(足軽7号の隔離実測に基づく):
#          base = XDG_RUNTIME_DIR || CLAUDE_CODE_TMPDIR || TMPDIR || /tmp
#                 (最初の非空・末尾スラッシュは正規化。本環境の
#                  XDG_RUNTIME_DIR実値は /run/user/1000/)
#          → <base>/cc-socks/<pid>.sock
#        一次dirが使えない場合(パスが長すぎる・一次dirを拒否された場合)
#        のみ本体は /tmp/cc-socks-<uid> へ退避するため、これも候補に含める
#        (uid は id -u。1000の決め打ちはしない)。
#        各環境変数は対象pidの /proc/<pid>/environ から読み、読めない時
#        (pid不在・権限なし)のみ呼出側環境へ退避する。対象のenvironが
#        読めて未設定なら、呼出側の値へは退避しない(本体が実際に使う
#        置場とずれるため)。
#   ★environ・セッション記録の値は文字列としてのみ扱い、評価・実行しない。
#   ★予測式は「記録が無い/使えない時の退避」であり、本体の挙動が変われば
#     外れ得る。確実なのは 2) の記録である。
#
# ★mesh登録(<socket dir>/<pid>.sock)は起動直後は未完了のことが
#   ある(cmd_759調査時点の実測: /tmp/cc-socks-1000 のbirth timeが単発起動の
#   タイミングと重なった一方、同時多重起動直後の確認では0件だった。
#   ※置場が環境依存(XDG_RUNTIME_DIRの有無・一次dirの可否)であることは
#   cmd_784で判明した。詳細・時系列は docs/delivery_channels.md 参照)。
#   ゆえに本ファイルは「待つ」機構を持たない——固定sleepや再試行ループは
#   実装しない。呼出側が既存の処理で自然に消費した時間の後に一度だけ
#   呼ぶこと。
#
# ─── 提供関数 ───
#
#   mesh_pid_env_value <pid> <NAME>
#       → 対象pidの/proc/<pid>/environ から環境変数NAMEの値を出力する
#         (未設定なら空文字を出力)。Returns: 0=environが読めた
#         1=読めない(pid空・不在・権限なし)。read-only。
#
#   mesh_env_of <pid> <NAME>
#       → 対象pidのenviron優先でNAMEの値を出力。読めない時のみ
#         呼出側環境の値。read-only。
#
#   mesh_recorded_sock_dir <pid>
#       → 対象pidのセッション記録(上記2)が有効ならsocket dirを出力する。
#         Returns: 0=有効な記録あり 1=記録なし・不正・古い。read-only。
#
#   mesh_sock_dirs [pid]
#       → socketが在るはずのdir候補を優先順に1行1件で出力する
#         (MESH_SOCK_DIR明示 → 有効な記録 → 予測式の一次dir・退避dir)。
#
#   mesh_sock_dir [pid]
#       → mesh_sock_dirs の先頭(期待する置場)。
#
#   mesh_pane_pid <pane_target>
#       → pane前景シェルのPID(tmuxの#{pane_pid})を返す。読めなければ
#         空文字。read-only(tmux display-messageのみ)。
#
#   mesh_child_claude_pid <parent_pid>
#       → parent_pidの直接の子のうちcomm名が"claude"であるPIDを返す。
#         0件・複数件は空文字(判定不能。誤って1つを選ばない)。
#         read-only(psのみ)。
#
#   mesh_is_registered <pid>
#       → mesh_sock_dirs <pid> のいずれかに <dir>/<pid>.sock がUNIXソケット
#         として実在するか。Returns: 0=登録済み 1=未登録・pid空。
#         read-only(-Sテストのみ)。
#
#   check_mesh_registration <pane_target>
#       → 出力: "registered:<pid>" | "unregistered:<reason>[:<pid>]"
#         Returns: 0=registered 1=unregistered
#         reason ∈ {pane_pid_not_found, claude_pid_not_found, no_socket}
# ═══════════════════════════════════════════════════════════════

# ★MESH_SOCK_DIR は明示上書き専用(未設定・空なら上記の規則で決める)。
#   source時に既定値を代入して固定化しない——対象pidごとに置場が変わり得る。

mesh_pid_env_value() {
    local pid="${1:-}" name="${2:-}"
    [ -n "$pid" ] && [ -n "$name" ] || return 1
    case "$pid" in *[!0-9]*) return 1 ;; esac
    local environ_file="/proc/${pid}/environ"
    [ -r "$environ_file" ] || return 1

    # environはNUL区切り。値は文字列としてのみ扱い、evalや展開はしない。
    local entry
    while IFS= read -r -d '' entry || [ -n "$entry" ]; do
        case "$entry" in
            "${name}="*)
                printf '%s' "${entry#"${name}="}"
                return 0
                ;;
        esac
    done 2>/dev/null < "$environ_file"
    return 0
}

mesh_env_of() {
    local pid="${1:-}" name="${2:-}" value=""
    [ -n "$name" ] || return 0
    # 対象pidのenvironが読めたなら、その値だけを信じる(対象が持たない
    # 変数を呼出側の値で補うと、本体が実際に使う置場とずれる)。
    if [ -n "$pid" ] && value=$(mesh_pid_env_value "$pid" "$name"); then
        printf '%s' "$value"
    else
        printf '%s' "${!name:-}"
    fi
}

# mesh_proc_starttime <pid> — /proc/<pid>/stat の22番目(starttime)
mesh_proc_starttime() {
    local pid="${1:-}" stat rest
    [ -r "/proc/${pid}/stat" ] || return 1
    stat=$(cat "/proc/${pid}/stat" 2>/dev/null) || return 1
    # 2番目のフィールド comm は括弧で囲まれ空白を含み得るため、最後の ") " 以降を切る
    rest="${stat##*) }"
    local -a fields
    read -ra fields <<< "$rest"
    [ -n "${fields[19]:-}" ] || return 1
    printf '%s' "${fields[19]}"
}

# mesh_json_scalar <content> <key> — 単純なJSONから最初の "key": "文字列" か
# "key": 数値 を取り出す。エスケープ(バックスラッシュ)を含む文字列値は
# 対象外(空を返す)。値は評価しない。
mesh_json_scalar() {
    local content="${1:-}" key="${2:-}"
    [ -n "$key" ] || return 0
    local pat
    pat="\"${key}\"[[:space:]]*:[[:space:]]*\\(\"[^\"\\\\]*\"\\|[0-9][0-9]*\\)"
    printf '%s' "$content" \
        | command grep -o "$pat" | head -n1 \
        | sed -e 's/^"[^"]*"[[:space:]]*:[[:space:]]*//' -e 's/^"\(.*\)"$/\1/'
}

mesh_recorded_sock_dir() {
    local pid="${1:-}"
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac

    local config_dir
    config_dir=$(mesh_env_of "$pid" CLAUDE_CONFIG_DIR)
    [ -n "$config_dir" ] || config_dir="${HOME:-}/.claude"
    local record="${config_dir}/sessions/${pid}.json"
    [ -f "$record" ] && [ -r "$record" ] || return 1

    local content
    content=$(tr -d '\r\n' 2>/dev/null < "$record") || return 1

    local rec_pid rec_start rec_path proc_start
    rec_pid=$(mesh_json_scalar "$content" pid)
    rec_start=$(mesh_json_scalar "$content" procStart)
    rec_path=$(mesh_json_scalar "$content" messagingSocketPath)

    # pid再利用対策: 記録のpid・procStartが今の対象プロセスと一致すること
    [ "$rec_pid" = "$pid" ] || return 1
    proc_start=$(mesh_proc_starttime "$pid") || return 1
    [ -n "$rec_start" ] && [ "$rec_start" = "$proc_start" ] || return 1

    case "$rec_path" in /*) ;; *) return 1 ;; esac
    [ "${rec_path##*/}" = "${pid}.sock" ] || return 1

    local dir="${rec_path%/*}"
    [ -n "$dir" ] || dir="/"
    printf '%s' "$dir"
}

# mesh_predicted_sock_dirs [pid] — 予測式(上記3)。一次dirと退避dirを出力。
mesh_predicted_sock_dirs() {
    local pid="${1:-}" base="" name value
    for name in XDG_RUNTIME_DIR CLAUDE_CODE_TMPDIR TMPDIR; do
        value=$(mesh_env_of "$pid" "$name")
        if [ -n "$value" ]; then
            base="$value"
            break
        fi
    done
    [ -n "$base" ] || base="/tmp"

    # 末尾スラッシュを全て落とす(本環境のXDG_RUNTIME_DIR実値は /run/user/1000/)
    while [ "${base%/}" != "$base" ]; do
        base="${base%/}"
    done

    local primary="${base}/cc-socks"
    local fallback
    fallback="/tmp/cc-socks-$(id -u)"
    printf '%s\n' "$primary"
    if [ "$fallback" != "$primary" ]; then
        printf '%s\n' "$fallback"
    fi
}

mesh_sock_dirs() {
    local pid="${1:-}"

    if [ -n "${MESH_SOCK_DIR:-}" ]; then
        printf '%s\n' "$MESH_SOCK_DIR"
        return 0
    fi

    local recorded
    if recorded=$(mesh_recorded_sock_dir "$pid"); then
        printf '%s\n' "$recorded"
        return 0
    fi

    mesh_predicted_sock_dirs "$pid"
}

mesh_sock_dir() {
    local first=""
    IFS= read -r first < <(mesh_sock_dirs "$@")
    printf '%s\n' "$first"
}

mesh_pane_pid() {
    local pane_target="${1:-}"
    [ -n "$pane_target" ] || return 0
    tmux display-message -t "$pane_target" -p '#{pane_pid}' 2>/dev/null \
        | tr -d '[:space:]'
}

mesh_child_claude_pid() {
    local parent_pid="${1:-}"
    [ -n "$parent_pid" ] || return 0

    local pid comm found=""
    while read -r pid comm; do
        [ -n "$pid" ] || continue
        if [ "$comm" = "claude" ]; then
            if [ -n "$found" ]; then
                # 複数該当は判定不能として空を返す(誤ってどれか1つを
                # 選ぶと、別paneのclaudeを指す事故になり得る)。
                echo ""
                return 0
            fi
            found="$pid"
        fi
    done < <(ps --ppid "$parent_pid" -o pid=,comm= 2>/dev/null)

    echo "$found"
}

mesh_is_registered() {
    local pid="${1:-}"
    [ -n "$pid" ] || return 1
    local dir
    while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        if [ -S "${dir}/${pid}.sock" ]; then
            return 0
        fi
    done < <(mesh_sock_dirs "$pid")
    return 1
}

check_mesh_registration() {
    local pane_target="${1:-}"

    local ppid
    ppid=$(mesh_pane_pid "$pane_target")
    if [ -z "$ppid" ]; then
        echo "unregistered:pane_pid_not_found"
        return 1
    fi

    local pid
    pid=$(mesh_child_claude_pid "$ppid")
    if [ -z "$pid" ]; then
        echo "unregistered:claude_pid_not_found"
        return 1
    fi

    if mesh_is_registered "$pid"; then
        echo "registered:${pid}"
        return 0
    fi
    echo "unregistered:no_socket:${pid}"
    return 1
}
