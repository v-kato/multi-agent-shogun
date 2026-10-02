#!/usr/bin/env bats
# test_shutsujin_runtime_dir.bats — agent pane を login session の runtime dir
# から切り離す (cmd_784 Phase 2・AC②)
#
# 真因B: WSL2+systemd で出陣直後に login session が logind から外れ、
#   /run/user/<uid>(XDG_RUNTIME_DIR)が撤去された。Claude Code は mesh の
#   socket を ${XDG_RUNTIME_DIR}/cc-socks/<pid>.sock へ張っていたため、
#   パスごと消えて誰からも到達できなくなった。
# 対処: shutsujin_departure.sh が agent pane の shell と session 環境から
#   XDG_RUNTIME_DIR を外し、本体の置場を login session に依らぬ一時 dir 側
#   (既定 /tmp/cc-socks)へ倒す。
#
# ★稼働中の multiagent/shogun 本番 tmux には一切触れない。実 tmux を使う
#   試験は scripts/isolated_tmux.sh(cmd_758 QC済helper)の隔離ソケットのみ
#   を相手にし、後始末も同 helper の teardown(素のシェルへ exit)に任せる。
#   出陣スクリプト本体は実行せず、関数定義だけを awk で取り出して評価する。
#
# テスト構成:
#   T-RD-001: pane 初期化コマンドは unset を && 連鎖の外に前置し、従来の連鎖を保つ
#   T-RD-002: PS1 設定の送信箇所(将軍・multiagent)は全て初期化関数を通る
#   T-RD-003: 除去印は各 session 作成の後・pane 分割/PS1 送信/CLI 起動の前に付く
#   T-RD-004: 除去印は session 単位(-t <session> -r)で付け、global(-g)は触らない
#   T-RD-005: 除去印の付与に失敗しても出陣を止めず、警告を出す(set -e 下)
#   T-RD-006: 隔離tmux実機: 除去印の後に分割された pane は XDG_RUNTIME_DIR を
#             持たず、server の global 環境は変わらない
#   T-RD-007: 隔離tmux実機: 除去印より前から在る pane も、初期化コマンドで
#             XDG_RUNTIME_DIR を失う

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export SHUTSUJIN="$PROJECT_ROOT/shutsujin_departure.sh"
    export ISOLATED_TMUX="$PROJECT_ROOT/scripts/isolated_tmux.sh"
    [ -f "$SHUTSUJIN" ] || return 1
    [ -f "$ISOLATED_TMUX" ] || return 1
}

setup() {
    HANDLE_FILE=""
    # 隔離 server が継ぐ「撤去済みの runtime dir」の見立て(実在させない)
    export FAKE_XDG="/nonexistent/cmd784/run/user/$(id -u)/"
}

teardown() {
    if [ -n "${HANDLE_FILE:-}" ] && [ -f "$HANDLE_FILE" ]; then
        bash "$ISOLATED_TMUX" teardown "$HANDLE_FILE" || true
    fi
}

# 出陣スクリプトから関数定義だけを取り出す
extract_fn() {
    awk "/^$1\\(\\) \\{/,/^}/" "$SHUTSUJIN"
}

# XDG_RUNTIME_DIR を持つ隔離 tmux server を作る。
# 呼出後、ISO_SOCKET_PATH / ISO_SESSION / ISO_PANE_ID を export する。
iso_create() {
    HANDLE_FILE="$(XDG_RUNTIME_DIR="$FAKE_XDG" bash "$ISOLATED_TMUX" create -L "$1")"
    [ -n "$HANDLE_FILE" ]
    export ISO_SOCKET_PATH="$(grep '^SOCKET_PATH=' "$HANDLE_FILE" | cut -d= -f2-)"
    export ISO_SESSION="$(grep '^SESSION=' "$HANDLE_FILE" | cut -d= -f2-)"
    export ISO_PANE_ID="$(grep '^PANE_ID=' "$HANDLE_FILE" | cut -d= -f2-)"
    [ -n "$ISO_SOCKET_PATH" ]
    [ -n "$ISO_SESSION" ]
    [ -n "$ISO_PANE_ID" ]
}

iso_tmux() {
    tmux -S "$ISO_SOCKET_PATH" "$@"
}

# 隔離 pane の中で XDG_RUNTIME_DIR を読み、global option へ書かせて待つ。
# 読んだ値(未設定なら UNSET)を stdout へ返す。
iso_probe_split() {
    local key="$1"
    iso_tmux split-window -d -t "$ISO_SESSION" \
        "tmux set-option -g @${key} \"\${XDG_RUNTIME_DIR-UNSET}\"; tmux wait-for -S ${key}"
    timeout 10 tmux -S "$ISO_SOCKET_PATH" wait-for "$key"
    iso_tmux show-option -gv "@${key}"
}

iso_probe_pane() {
    local key="$1"
    iso_tmux send-keys -t "$ISO_PANE_ID" -l \
        "tmux set-option -g @${key} \"\${XDG_RUNTIME_DIR-UNSET}\"; tmux wait-for -S ${key}"
    iso_tmux send-keys -t "$ISO_PANE_ID" Enter
    timeout 10 tmux -S "$ISO_SOCKET_PATH" wait-for "$key"
    iso_tmux show-option -gv "@${key}"
}

@test "T-RD-001: pane 初期化コマンドは unset を && 連鎖の外に前置し、従来の連鎖を保つ" {
    run bash -c "
        eval \"\$(awk '/^shutsujin_pane_init_cmd\\(\\) \\{/,/^}/' '$SHUTSUJIN')\"
        cd '$PROJECT_ROOT' && shutsujin_pane_init_cmd 'P> '
    "
    [ "$status" -eq 0 ]
    [ "$output" = "unset XDG_RUNTIME_DIR; cd \"$PROJECT_ROOT\" && export PS1='P> ' && clear" ]
}

@test "T-RD-002: PS1 設定の送信箇所(将軍・multiagent)は全て初期化関数を通る" {
    local sites code_only
    sites="$(grep 'PS1設定' "$SHUTSUJIN" | grep -vE '^[[:space:]]*#')"
    [ "$(echo "$sites" | grep -c 'shutsujin_send_launch')" -eq 2 ]
    [ "$(echo "$sites" | grep -c 'shutsujin_pane_init_cmd')" -eq 2 ]
    # export PS1 を組み立てるのは初期化関数の本体1箇所だけ
    code_only="$(grep -vE '^[[:space:]]*#' "$SHUTSUJIN")"
    [ "$(echo "$code_only" | grep -c 'export PS1=')" -eq 1 ]
    extract_fn shutsujin_pane_init_cmd | grep -q 'export PS1='
}

@test "T-RD-003: 除去印は各 session 作成の後・pane 分割/PS1 送信/CLI 起動の前に付く" {
    local l_sg_new l_sg_detach l_sg_ps1 l_ma_new l_ma_detach l_split l_ma_ps1 l_cli
    l_sg_new="$(grep -n 'tmux new-session -d -s shogun' "$SHUTSUJIN" | head -1 | cut -d: -f1)"
    l_sg_detach="$(grep -nx 'shutsujin_detach_runtime_dir shogun' "$SHUTSUJIN" | head -1 | cut -d: -f1)"
    l_sg_ps1="$(grep -n '将軍paneのPS1設定' "$SHUTSUJIN" | head -1 | cut -d: -f1)"
    l_ma_new="$(grep -n 'tmux new-session -d -s multiagent' "$SHUTSUJIN" | head -1 | cut -d: -f1)"
    l_ma_detach="$(grep -nx 'shutsujin_detach_runtime_dir multiagent' "$SHUTSUJIN" | head -1 | cut -d: -f1)"
    l_split="$(grep -nE '^[[:space:]]*tmux split-window' "$SHUTSUJIN" | head -1 | cut -d: -f1)"
    l_ma_ps1="$(grep -n 'paneのPS1設定" "$(shutsujin_pane_init_cmd "$PROMPT_STR")"' "$SHUTSUJIN" | head -1 | cut -d: -f1)"
    l_cli="$(grep -n 'のCLI起動"' "$SHUTSUJIN" | head -1 | cut -d: -f1)"
    for v in "$l_sg_new" "$l_sg_detach" "$l_sg_ps1" "$l_ma_new" "$l_ma_detach" "$l_split" "$l_ma_ps1" "$l_cli"; do
        [ -n "$v" ]
    done
    [ "$l_sg_new" -lt "$l_sg_detach" ]
    [ "$l_sg_detach" -lt "$l_sg_ps1" ]
    [ "$l_ma_new" -lt "$l_ma_detach" ]
    [ "$l_ma_detach" -lt "$l_split" ]
    [ "$l_sg_ps1" -lt "$l_cli" ]
    [ "$l_ma_ps1" -lt "$l_cli" ]
}

@test "T-RD-004: 除去印は session 単位(-t <session> -r)で付け、global(-g)は触らない" {
    run bash -c "
        tmux() { echo \"tmux \$*\"; }
        log_info() { echo \"[log_info] \$*\"; }
        eval \"\$(awk '/^shutsujin_detach_runtime_dir\\(\\) \\{/,/^}/' '$SHUTSUJIN')\"
        shutsujin_detach_runtime_dir multiagent
    "
    [ "$status" -eq 0 ]
    [ "$output" = "tmux set-environment -t multiagent -r XDG_RUNTIME_DIR" ]
    # 出陣スクリプト全体で XDG_RUNTIME_DIR を global 環境に対して操作しない
    ! grep -vE '^[[:space:]]*#' "$SHUTSUJIN" | grep -E 'set-environment' | grep -E '(^|[[:space:]])-g' | grep -q 'XDG_RUNTIME_DIR'
}

@test "T-RD-005: 除去印の付与に失敗しても出陣を止めず、警告を出す(set -e 下)" {
    run bash -c "
        set -e
        tmux() { return 1; }
        log_info() { echo \"[log_info] \$*\"; }
        eval \"\$(awk '/^shutsujin_detach_runtime_dir\\(\\) \\{/,/^}/' '$SHUTSUJIN')\"
        shutsujin_detach_runtime_dir shogun
        echo AFTER
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'XDG_RUNTIME_DIR を外せなかった'
    echo "$output" | grep -q '^AFTER$'
}

@test "T-RD-006: 隔離tmux実機: 除去印の後に分割された pane は XDG_RUNTIME_DIR を持たず、global 環境は変わらない" {
    iso_create c784rd6

    # 対照: 除去印より前の分割 pane は server の global 環境から継ぐ
    run iso_probe_split c784rd6_before
    [ "$status" -eq 0 ]
    [ "$output" = "$FAKE_XDG" ]
    run iso_tmux show-environment -g XDG_RUNTIME_DIR
    [ "$output" = "XDG_RUNTIME_DIR=$FAKE_XDG" ]

    run bash -c "
        tmux() { command tmux -S \"\$ISO_SOCKET_PATH\" \"\$@\"; }
        log_info() { echo \"[log_info] \$*\"; }
        eval \"\$(awk '/^shutsujin_detach_runtime_dir\\(\\) \\{/,/^}/' '$SHUTSUJIN')\"
        shutsujin_detach_runtime_dir \"\$ISO_SESSION\"
    "
    [ "$status" -eq 0 ]
    run iso_tmux show-environment -t "$ISO_SESSION" XDG_RUNTIME_DIR
    [ "$output" = "-XDG_RUNTIME_DIR" ]

    run iso_probe_split c784rd6_after
    [ "$status" -eq 0 ]
    [ "$output" = "UNSET" ]

    # global 環境は触らない(同じ server の他 session を巻き込まぬ)
    run iso_tmux show-environment -g XDG_RUNTIME_DIR
    [ "$output" = "XDG_RUNTIME_DIR=$FAKE_XDG" ]
}

@test "T-RD-007: 隔離tmux実機: 除去印より前から在る pane も、初期化コマンドで XDG_RUNTIME_DIR を失う" {
    local init_cmd
    iso_create c784rd7

    # 対照: 初期化前の pane の shell は XDG_RUNTIME_DIR を持っている
    run iso_probe_pane c784rd7_before
    [ "$status" -eq 0 ]
    [ "$output" = "$FAKE_XDG" ]

    init_cmd="$(bash -c "
        eval \"\$(awk '/^shutsujin_pane_init_cmd\\(\\) \\{/,/^}/' '$SHUTSUJIN')\"
        cd '$PROJECT_ROOT' && shutsujin_pane_init_cmd 'iso> '
    ")"
    [ -n "$init_cmd" ]
    iso_tmux send-keys -t "$ISO_PANE_ID" -l "$init_cmd"
    iso_tmux send-keys -t "$ISO_PANE_ID" Enter

    run iso_probe_pane c784rd7_after
    [ "$status" -eq 0 ]
    [ "$output" = "UNSET" ]
}
