#!/usr/bin/env bash
# 🏯 multi-agent-shogun 出陣スクリプト（毎日の起動用）
# Daily Deployment Script for Multi-Agent Orchestration System
#
# 使用方法:
#   ./shutsujin_departure.sh           # 全エージェント起動（前回の状態を維持）
#   ./shutsujin_departure.sh -c        # キューをリセットして起動（クリーンスタート）
#   ./shutsujin_departure.sh -s        # セットアップのみ（Claude起動なし）
#   ./shutsujin_departure.sh --auto-mode-on          # Claude permission auto-approved で起動
#   ./shutsujin_departure.sh --permission-mode plan  # Claude permission mode を明示指定
#   ./shutsujin_departure.sh -h        # ヘルプ表示

set -e

# スクリプトのディレクトリを取得
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 言語設定を読み取り（デフォルト: ja）
LANG_SETTING="ja"
if [ -f "./config/settings.yaml" ]; then
    LANG_SETTING=$(grep "^language:" ./config/settings.yaml 2>/dev/null | awk '{print $2}' || echo "ja")
fi

# シェル設定を読み取り（デフォルト: bash）
SHELL_SETTING="bash"
if [ -f "./config/settings.yaml" ]; then
    SHELL_SETTING=$(grep "^shell:" ./config/settings.yaml 2>/dev/null | awk '{print $2}' || echo "bash")
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Python venv プリフライトチェック
# ───────────────────────────────────────────────────────────────────────────────
# inbox_write.sh, inbox_watcher.sh, cli_adapter.sh が .venv/bin/python3 に依存。
# venv が存在しない場合は自動作成する（git pull 後の初回起動対策）。
# ═══════════════════════════════════════════════════════════════════════════════
VENV_DIR="$SCRIPT_DIR/.venv"
if [ ! -f "$VENV_DIR/bin/python3" ] || ! "$VENV_DIR/bin/python3" -c "import yaml" 2>/dev/null; then
    echo -e "\033[1;33m【報】\033[0m Python venv をセットアップ中..."
    if command -v python3 &>/dev/null; then
        python3 -m venv "$VENV_DIR" 2>/dev/null || {
            echo -e "\033[1;31m【ERROR】\033[0m python3 -m venv に失敗しました。python3-venv パッケージが必要かもしれません。"
            echo "  Ubuntu/Debian: sudo apt-get install python3-venv"
            exit 1
        }
        "$VENV_DIR/bin/pip" install -r "$SCRIPT_DIR/requirements.txt" -q 2>/dev/null || {
            echo -e "\033[1;31m【ERROR】\033[0m pip install に失敗しました。"
            exit 1
        }
        echo -e "\033[1;32m【成】\033[0m Python venv セットアップ完了"
    else
        echo -e "\033[1;31m【ERROR】\033[0m python3 が見つかりません。first_setup.sh を実行してください。"
        exit 1
    fi
fi

# CLI Adapter読み込み（Multi-CLI Support）
if [ -f "$SCRIPT_DIR/lib/cli_adapter.sh" ]; then
    source "$SCRIPT_DIR/lib/cli_adapter.sh"
    CLI_ADAPTER_LOADED=true
else
    CLI_ADAPTER_LOADED=false
fi

# mesh登録確認ライブラリ読み込み（cmd_759 A-3・read-only。CLI起動そのものには
# 無関係のため、読み込みに失敗しても出陣は続行しチェックのみ省く）
if [ -f "$SCRIPT_DIR/lib/mesh_registration_check.sh" ]; then
    source "$SCRIPT_DIR/lib/mesh_registration_check.sh"
    MESH_CHECK_LOADED=true
else
    MESH_CHECK_LOADED=false
fi

# Claude会話resumeライブラリ読み込み（cmd_785・opt-in。読み込めなければ
# 従来どおり全agentを新規起動する）
if [ -f "$SCRIPT_DIR/lib/claude_session_resume.sh" ]; then
    source "$SCRIPT_DIR/lib/claude_session_resume.sh"
    CLAUDE_RESUME_LOADED=true
else
    CLAUDE_RESUME_LOADED=false
fi

# shutsujin_mesh_check — STEP 6.9本体(cmd_759 redo1)
# ★依存するグローバル変数(呼出し時点で定義済みであること): AGENT_IDS[]・
#   PANE_BASE・SCRIPT_DIR。pane観測(mesh登録確認)はread-onlyであり、
#   対象peerへの入力送信・再起動は一切行わない。ただしstate永続化と、
#   未登録検知時のKaro inboxへのdelivery_alert通知(下記参照)は行う。
#
# ★G759-ERREXIT-01是正: check_mesh_registrationは未登録を正常な観測結果
#   として出力しつつstatus 1を返す。これを単純代入で受けると、set -e下では
#   最初の未登録検出でシェルが即座に終了し、一覧蓄積・state書込みへ
#   到達しない。`if ! _mesh_result=$(...); then`という明示的な条件文の中で
#   捕捉することで、未登録が起きても関数全体が継続することを保証する。
# ★G759-STATE-DIR-03是正: 書込み直前にmkdir -pし、preflight自身が
#   出力先ディレクトリの存在を保証する(STEP 2の初期化と二重になるが、
#   この関数が単独で呼ばれても自己完結して安全に書けるようにするため)。
# ★G759-DASHBOARD-PATH-02是正: state file書込み後、未登録が1件以上あれば
#   家老inboxへdelivery_alert型で通知する。これにより家老のInbox
#   Processing Protocolが確実に拾い、dashboard.md🚨要対応へ転記できる
#   有限の経路が成立する。inbox_write.sh呼出し自体もif!で捕捉し、
#   通知に失敗しても出陣シーケンス全体は継続する。
shutsujin_mesh_check() {
    local _MESH_AGENTS=("shogun")
    local _MESH_PANES=("shogun:main")
    local i
    for i in "${!AGENT_IDS[@]}"; do
        local p=$((PANE_BASE + i))
        _MESH_AGENTS+=("${AGENT_IDS[$i]}")
        _MESH_PANES+=("multiagent:agents.${p}")
    done

    local _mesh_checked=0
    local _mesh_unregistered_agent=()
    local _mesh_unregistered_pane=()
    local _mesh_unregistered_detail=()
    for i in "${!_MESH_AGENTS[@]}"; do
        local _pane="${_MESH_PANES[$i]}"
        local _pane_cli
        _pane_cli=$(tmux show-options -p -t "$_pane" -v @agent_cli 2>/dev/null || echo "")
        [ "$_pane_cli" = "claude" ] || continue
        _mesh_checked=$((_mesh_checked + 1))
        local _mesh_result
        if ! _mesh_result=$(check_mesh_registration "$_pane"); then
            _mesh_unregistered_agent+=("${_MESH_AGENTS[$i]}")
            _mesh_unregistered_pane+=("$_pane")
            _mesh_unregistered_detail+=("$_mesh_result")
        fi
    done

    mkdir -p "$SCRIPT_DIR/queue/state"

    {
        printf 'timestamp: "%s"\n' "$(date '+%Y-%m-%dT%H:%M:%S+09:00')"
        printf 'checked: %d\n' "$_mesh_checked"
        printf 'unregistered_count: %d\n' "${#_mesh_unregistered_agent[@]}"
        if [ "${#_mesh_unregistered_agent[@]}" -eq 0 ]; then
            printf 'unregistered: []\n'
        else
            printf 'unregistered:\n'
            for i in "${!_mesh_unregistered_agent[@]}"; do
                printf -- '- agent_id: "%s"\n  pane: "%s"\n  detail: "%s"\n' \
                    "${_mesh_unregistered_agent[$i]}" "${_mesh_unregistered_pane[$i]}" "${_mesh_unregistered_detail[$i]}"
            done
        fi
    } > "$SCRIPT_DIR/queue/state/mesh_registration_status.yaml"

    if [ "${#_mesh_unregistered_agent[@]}" -gt 0 ]; then
        log_info "  └─ ⚠️  mesh未登録 ${#_mesh_unregistered_agent[@]}/${_mesh_checked}件 → queue/state/mesh_registration_status.yaml（家老確認要・再起動はしていない）"
        local _mesh_notify_content="出陣直後のmesh登録確認で${#_mesh_unregistered_agent[@]}/${_mesh_checked}件が未登録でした(queue/state/mesh_registration_status.yaml参照)。再起動は行っていません。"
        if ! bash "$SCRIPT_DIR/scripts/inbox_write.sh" karo "$_mesh_notify_content" delivery_alert shutsujin_departure; then
            log_info "  └─ ⚠️  家老へのinbox通知に失敗しました(手動確認要)"
        fi
    else
        log_success "  └─ mesh登録 ${_mesh_checked}件 全て確認"
    fi
}

# 足軽IDリストと人数を動的に取得（settings.yaml から）
if [ "$CLI_ADAPTER_LOADED" = true ]; then
    _ASHIGARU_IDS_STR=$(get_ashigaru_ids)
else
    _ASHIGARU_IDS_STR="ashigaru1 ashigaru2 ashigaru3 ashigaru4 ashigaru5 ashigaru6 ashigaru7"
fi
_ASHIGARU_COUNT=$(echo "$_ASHIGARU_IDS_STR" | wc -w | tr -d ' ')

# 色付きログ関数（戦国風）
log_info() {
    echo -e "\033[1;33m【報】\033[0m $1"
}

log_success() {
    echo -e "\033[1;32m【成】\033[0m $1"
}

log_war() {
    echo -e "\033[1;31m【戦】\033[0m $1"
}

# ═══════════════════════════════════════════════════════════════════════════════
# ★出陣時の打鍵 (cmd_754 将軍裁定 E-5 — 実装者の判断)
# ═══════════════════════════════════════════════════════════════════════════════
# 裁定 E-1 が廃したのは「agent CLI が★動いている pane への自動打鍵」である。
# 出陣が打つのは、これから CLI を起動する pane、すなわち★まだ CLI が動いて
# いない pane である。E-5 はこの扱いを実装者に委ねた。判断は「残す」である。
#
#   残す理由:
#     (1) 事故の形が成立しない。誤爆とは「TUI が出したモーダルの既定選択肢を
#         Enter が押す」ことであった。CLI が動いていない pane に TUI は無く、
#         モーダルも既定選択肢も存在しない。
#     (2) 廃せば得られる安全が無く、失うものだけが確実である。人が 10 個の
#         pane へ手ずから CLI 起動コマンドを打ち込むことになる。
#     (3) 将軍の既定「agent CLI が動いている pane へは送らない」を、そのまま
#         満たしている。
#
#   ★ただし無条件では残さない。出陣は「セッションが既に在れば作り直さず
#     使い回す」ため、★既に agent が稼働している pane へ起動コマンドを
#     打ち込む経路が実在した。これは E-1 が廃した当のものである。
#     よって打鍵の直前に、pane の★前景プロセスが素のシェルであることを
#     確かめる。画面は読まない(lib/pane_preflight.sh の pane_is_bare_shell)。
#
#   ★残余リスク(正直に記す): 素のシェルであっても、人がその prompt で何かを
#     打っている最中なら混ざる。出陣は人が自ら叩く起動手順ゆえ、その人が
#     居合わせている前提を置く。
_pane_preflight_lib="$SCRIPT_DIR/lib/pane_preflight.sh"
if [ -f "$_pane_preflight_lib" ]; then
    source "$_pane_preflight_lib"
fi

# 起動打鍵を送れなかった pane の記録（末尾で人へ報せる）
SHUTSUJIN_SKIPPED_PANES=""

# shutsujin_send_launch <pane> <purpose> <send-keys引数...>
# ★CLI が動いていない pane にだけ打鍵する。動いていれば送らず記録する。
# Returns: 0 = 送った / 1 = 送らなかった
shutsujin_send_launch() {
    local pane="$1"
    local purpose="$2"
    shift 2

    if ! declare -f pane_is_bare_shell >/dev/null 2>&1; then
        log_info "  ⚠️  lib/pane_preflight.sh を読み込めておらぬ。${purpose} を送らぬ (pane=${pane})"
        SHUTSUJIN_SKIPPED_PANES="${SHUTSUJIN_SKIPPED_PANES}${pane} (preflightライブラリ不在)\n"
        return 1
    fi
    if ! pane_is_bare_shell "$pane"; then
        log_info "  ⚠️  ${pane} は素のシェルではない (${PANE_SHELL_REASON:-unknown})。${purpose} を送らぬ"
        log_info "      ★既に CLI が動いている見込みである。稼働中の pane へ打鍵せぬのが cmd_754 の裁定である。"
        SHUTSUJIN_SKIPPED_PANES="${SHUTSUJIN_SKIPPED_PANES}${pane} (${PANE_SHELL_REASON:-unknown})\n"
        return 1
    fi
    tmux send-keys -t "$pane" "$@"
}

# OpenCode は複数プロセスを短時間に連続起動すると WSL2 上で SIGILL に
# なることがあるため、OpenCode のときだけ起動間隔を少し空ける。
opencode_startup_delay() {
    local cli_type="$1"
    if [ "$cli_type" = "opencode" ]; then
        sleep 0.1
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# プロンプト生成関数（bash/zsh対応）
# ───────────────────────────────────────────────────────────────────────────────
# 使用法: generate_prompt "ラベル" "色" "シェル"
# 色: red, green, blue, magenta, cyan, yellow
# ═══════════════════════════════════════════════════════════════════════════════
generate_prompt() {
    local label="$1"
    local color="$2"
    local shell_type="$3"

    if [ "$shell_type" == "zsh" ]; then
        # zsh用: %F{color}%B...%b%f 形式
        echo "(%F{${color}}%B${label}%b%f) %F{green}%B%~%b%f%# "
    else
        # bash用: \[\033[...m\] 形式
        local color_code
        case "$color" in
            red)     color_code="1;31" ;;
            green)   color_code="1;32" ;;
            yellow)  color_code="1;33" ;;
            blue)    color_code="1;34" ;;
            magenta) color_code="1;35" ;;
            cyan)    color_code="1;36" ;;
            *)       color_code="1;37" ;;  # white (default)
        esac
        echo "(\[\033[${color_code}m\]${label}\[\033[0m\]) \[\033[1;32m\]\w\[\033[0m\]\$ "
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# agent pane を login session の runtime dir から切り離す（cmd_784）
# ───────────────────────────────────────────────────────────────────────────────
# Claude Code は mesh(ListAgents/SendMessage)の socket を
#   ${XDG_RUNTIME_DIR:-${CLAUDE_CODE_TMPDIR:-${TMPDIR:-/tmp}}}/cc-socks/<pid>.sock
# へ bind する（本体 2.1.284 の実測。一次置場を作れぬ時・パスが 103byte を
# 超える時のみ /tmp/cc-socks-<uid>/ へ退避する）。
# XDG_RUNTIME_DIR(/run/user/<uid>) は logind が login session の寿命に合わせて
# 作り・消す dir であり、tmux 上で session より長く生きる agent の置場とは
# 寿命が合わない。2026-09-29 には WSL2+systemd で出陣直後に login session が
# 外れて /run/user/1000 が撤去され、全 agent の socket が到達不能になった
# (SSH で出陣して切断した場合など、linger 無しの Linux 一般で同じことが起きる)。
# ゆえに agent pane の shell から XDG_RUNTIME_DIR を外し、本体の置場を
# login session に依らぬ一時 dir 側(既定では /tmp/cc-socks)へ倒す。
#   - pane の shell 自身から外す(shutsujin_pane_init_cmd): 出陣時の起動だけで
#     なく、同じ pane で後から CLI を起こし直す経路(switch_cli.sh 等)にも効く。
#   - session 環境に除去印を付ける(shutsujin_detach_runtime_dir): 以後その
#     session に作られる pane にも効く。
#   ★tmux server の global 環境は触らない(殿の他の tmux session を巻き込まぬ)。
# ═══════════════════════════════════════════════════════════════════════════════
shutsujin_detach_runtime_dir() {
    local session="$1"
    if ! tmux set-environment -t "$session" -r XDG_RUNTIME_DIR; then
        log_info "  ⚠️  ${session} の session 環境から XDG_RUNTIME_DIR を外せなかった(pane 側の unset で代替する)"
    fi
}

# shutsujin_pane_init_cmd <PS1文字列>
# agent pane の shell へ送る初期化コマンドを返す。
# ★unset は cd の成否に関わらず効かせるため、&& 連鎖の外に置く。
shutsujin_pane_init_cmd() {
    local prompt="$1"
    printf '%s' "unset XDG_RUNTIME_DIR; cd \"$(pwd)\" && export PS1='${prompt}' && clear"
}

# ═══════════════════════════════════════════════════════════════════════════════
# 出陣やり直し時の Claude 会話 resume (cmd_785・opt-in)
# ═══════════════════════════════════════════════════════════════════════════════
# Remote Control 常時 ON では、出陣やり直しのたびに Claude 系 agent の数だけ
# Claude アプリへ孤児セッションが残る。撤収の直前に各 agent の会話 ID を採取し、
# 起動時に `claude --resume <id>` で同じ会話を再開すると、その会話の Remote
# Control セッションへ再接続される(context/cmd_785_resume_poc.md)。
#   - 有効化: config/settings.yaml の cli.claude_session_resume: true(既定は無効)
#   - 採取は読み取りのみ。撤収前に /clear・/exit を送らない(cmd_754 裁定)。
#   - 採取・照合に失敗した agent・Codex 系・--clean 時は従来の新規起動。
#   - resume 起動が起動直後(30秒未満)に自ら非0で終わった時だけ、同じ打鍵の
#     中で1回だけ従来の新規起動へ倒す(shutsujin_launch_cmd。G785-Q01)。
#   - 有効時は Claude 系の起動コマンド(resume・新規・--clean・倒した先の新規の
#     全て)の末尾に固定の1語を付ける(get_startup_prompt_arg。cmd_785 Phase 1b)。
#     起動と同時に1件入力して転写を作り、次の出陣で resume できるようにする。
# ─── 前回スナップショットの再利用(cmd_796・別 opt-in・既定 OFF) ───
#   - 有効化: cli.claude_session_resume と cli.claude_session_resume_previous_snapshot
#     の両方が true の時だけ(context/cmd_796_design_review.md)。
#   - 今回の採取は *.current.yaml へ書き、同じ出陣の照合は current を読む。正本
#     (claude_session_snapshot.yaml)は最後の実採取記録として残す(全対象が撤収前に
#     確実に不在なら byte 単位で残し、稼働対象がいた時だけ今回の実採取で置換)。
#   - 撤収前に確実に不在(absent)だった agent に限り、正本の ID を全条件で検査して
#     候補にする。起動計画(plan)は出陣1回に固定し、ID・bridge の重複を拒否する。
#   - 前回由来の起動だけ、pane が CLI を実行する直前に lib を --check-previous で
#     呼んで再確認する(拒否なら新規起動を1回)。
#   - resume 有効時は、採取の前から全 CLI の起動送出まで出陣を flock で排他する。
#     2本目は撤収の前に止まる。lock の FD 9 は tmux server へ継承させない。
CLAUDE_RESUME_SNAPSHOT_FILE="$SCRIPT_DIR/queue/state/claude_session_snapshot.yaml"
CLAUDE_RESUME_CURRENT_FILE="$SCRIPT_DIR/queue/state/claude_session_snapshot.current.yaml"
CLAUDE_RESUME_PLAN_FILE="$SCRIPT_DIR/queue/state/claude_session_plan.yaml"
CLAUDE_RESUME_LOCK_FILE="$SCRIPT_DIR/queue/state/shutsujin.lock"
CLAUDE_RESUME_RUN_TOKEN=""
CLAUDE_RESUME_LOCK_HELD=false
declare -A CLAUDE_RESUME_PLAN_SID=()
declare -A CLAUDE_RESUME_PLAN_SOURCE=()
CLAUDE_RESUME_PREV_REMAINING=0
CLAUDE_RESUME_UNCONFIRMED=()

# shutsujin_resume_lock — STEP 1(撤収)の前に一度だけ呼ぶ(cmd_796 §5.2-1)。
# resume 有効時だけ、出陣全体を FD 9 の flock で排他する。取れなければ理由を出して
# 1 を返す(呼ぶ側は撤収の前に終了する。新規で続行して他の出陣を壊さない)。
# flock が無い環境では排他せずに続け、前回記録の再利用だけを無効にする。
shutsujin_resume_lock() {
    CLAUDE_RESUME_LOCK_HELD=false
    [ "$CLAUDE_RESUME_LOADED" = true ] || return 0
    claude_resume_enabled || return 0
    if ! command -v flock >/dev/null 2>&1; then
        log_info "  └─ ⚠️  会話resume: flock が無いため出陣の排他を取れない(前回記録の再利用は無効)"
        return 0
    fi
    if ! mkdir -p "$(dirname "$CLAUDE_RESUME_LOCK_FILE")" || ! exec 9>>"$CLAUDE_RESUME_LOCK_FILE"; then
        log_info "  └─ ⚠️  会話resume: 出陣の排他ファイルを開けない。撤収の前に中止する ($CLAUDE_RESUME_LOCK_FILE)"
        return 1
    fi
    if ! flock -n 9; then
        exec 9>&-
        log_info "  └─ ⚠️  会話resume: 別の出陣が実行中(排他を取れない)。撤収の前に中止する"
        return 1
    fi
    CLAUDE_RESUME_LOCK_HELD=true
    return 0
}

# shutsujin_resume_unlock — 排他を解く(何度呼んでもよい)
shutsujin_resume_unlock() {
    [ "$CLAUDE_RESUME_LOCK_HELD" = true ] || return 0
    exec 9>&-
    CLAUDE_RESUME_LOCK_HELD=false
    return 0
}

# shutsujin_claude_targets — この出陣で Claude として起動する役名(settings の CLI が claude)
shutsujin_claude_targets() {
    local a out=""
    for a in shogun karo ${_ASHIGARU_IDS_STR:-} gunshi; do
        [ "$(get_cli_type "$a" 2>/dev/null)" = "claude" ] && out="${out:+$out }$a"
    done
    printf '%s\n' "$out"
}

# shutsujin_claude_resume_snapshot — STEP 1 の kill-session の直前に一度だけ呼ぶ。
# 撤収前の観測と今回の採取を current へ書き、起動計画を作ってから正本の保存方針を
# 適用する(計画は正本を置換する前の内容を読む)。計画を作れた時だけ
# CLAUDE_RESUME_RUN_TOKEN を立てる(同じ出陣で採った記録・この計画しか使わない)。
shutsujin_claude_resume_snapshot() {
    CLAUDE_RESUME_RUN_TOKEN=""
    CLAUDE_RESUME_PLAN_SID=()
    CLAUDE_RESUME_PLAN_SOURCE=()
    CLAUDE_RESUME_PREV_REMAINING=0
    CLAUDE_RESUME_UNCONFIRMED=()
    [ "$CLAUDE_RESUME_LOADED" = true ] || return 0
    if [ "$CLEAN_MODE" = true ]; then
        # cmd_796 §4-6: --clean は resume のスイッチに関わらず、前回候補を次回へ持ち越さない
        if [ -e "$CLAUDE_RESUME_SNAPSHOT_FILE" ]; then
            if claude_resume_invalidate "$CLAUDE_RESUME_SNAPSHOT_FILE" clean; then
                log_info "  └─ 会話resume: --clean のため前回の記録を無効化した"
            else
                log_info "  └─ ⚠️  会話resume: --clean だが前回の記録を無効化できなかった"
            fi
        fi
        claude_resume_enabled && log_info "  └─ 会話resume: --clean のため採取しない(全agentを新規起動)"
        return 0
    fi
    claude_resume_enabled || return 0

    local token targets prev_on=0 plan_out commit kind agent source sid info
    token=$(claude_resume_new_token)
    targets=$(shutsujin_claude_targets)
    if claude_resume_previous_enabled; then
        if [ "$CLAUDE_RESUME_LOCK_HELD" = true ]; then
            prev_on=1
        else
            log_info "  └─ ⚠️  会話resume: 出陣の排他が無いため前回記録の再利用はしない"
        fi
    fi
    if ! claude_resume_snapshot "$CLAUDE_RESUME_CURRENT_FILE" "$token" "$targets"; then
        log_info "  └─ ⚠️  会話resume: 採取に失敗(全agentを新規起動で続行)"
        # 不在を証明できない: 正本を再利用不可にする(書けなければそのまま。今回は新規)
        if [ -e "$CLAUDE_RESUME_SNAPSHOT_FILE" ]; then
            claude_resume_invalidate "$CLAUDE_RESUME_SNAPSHOT_FILE" capture_failed \
                || log_info "  └─ ⚠️  会話resume: 前回の記録も無効化できなかった(次回の前回再利用は鮮度・live 条件で判定)"
        fi
        return 0
    fi
    log_info "  └─ 会話resume: Claude系agentの会話IDを採取 → queue/state/claude_session_snapshot.current.yaml"

    if plan_out=$(claude_resume_plan "$CLAUDE_RESUME_SNAPSHOT_FILE" "$CLAUDE_RESUME_CURRENT_FILE" \
        "$CLAUDE_RESUME_PLAN_FILE" "$token" "$targets" "$(pwd)" "$prev_on"); then
        while IFS=$'\t' read -r kind agent source sid info; do
            [ "$kind" = "PLAN" ] || continue
            [[ "$agent" =~ ^(shogun|karo|gunshi|ashigaru[0-9]+)$ ]] || continue
            case "$source" in
                current|previous_snapshot)
                    claude_resume_valid_session_id "$sid" || continue
                    CLAUDE_RESUME_PLAN_SOURCE["$agent"]="$source"
                    CLAUDE_RESUME_PLAN_SID["$agent"]="$sid"
                    if [ "$source" = "previous_snapshot" ]; then
                        CLAUDE_RESUME_PREV_REMAINING=$((CLAUDE_RESUME_PREV_REMAINING + 1))
                        log_info "  └─ 会話resume: ${agent} は前回記録の候補(${info})"
                    fi
                    ;;
                *)
                    [ "$prev_on" = 1 ] && log_info "  └─ 会話resume: ${agent} は前回記録を使わない(${info})"
                    ;;
            esac
        done <<< "$plan_out"
        CLAUDE_RESUME_RUN_TOKEN="$token"
    else
        log_info "  └─ ⚠️  会話resume: 起動計画を作れない(全agentを新規起動で続行)"
    fi

    # 正本の保存方針(計画が正本を読んだ後で適用する)
    if commit=$(claude_resume_commit_canonical "$CLAUDE_RESUME_SNAPSHOT_FILE" "$CLAUDE_RESUME_CURRENT_FILE" "$targets"); then
        case "$commit" in
            preserved) log_info "  └─ 会話resume: 撤収前に対象が全て不在のため、前回の記録(正本)を残す" ;;
            *) log_info "  └─ 会話resume: 今回の採取で記録(正本)を更新 → queue/state/claude_session_snapshot.yaml" ;;
        esac
    else
        # cmd_796 §4-5: 正本の書込み自体に失敗した出陣は、全員新規へ倒す(計画を捨てる)
        CLAUDE_RESUME_RUN_TOKEN=""
        CLAUDE_RESUME_PLAN_SID=()
        CLAUDE_RESUME_PLAN_SOURCE=()
        CLAUDE_RESUME_PREV_REMAINING=0
        log_info "  └─ ⚠️  会話resume: 記録(正本)を更新できないため、この出陣は全agentを新規起動で続行"
    fi
    return 0
}

# shutsujin_resume_id <agent_id> <cli_type>
# この出陣の起動計画で、その agent に発行した会話 ID(current・前回由来)を返す。
# 空なら従来の新規起動。計画は一度だけ作り、ここでは読むだけ(予約し直さない)。
shutsujin_resume_id() {
    [ -n "${CLAUDE_RESUME_RUN_TOKEN:-}" ] || return 0
    [ "${2:-}" = "claude" ] || return 0
    [ -n "${1:-}" ] || return 0
    printf '%s\n' "${CLAUDE_RESUME_PLAN_SID[$1]:-}"
}

# shutsujin_wrap_resume_cmd <agent_id> <resume_id> <resume_cmd> <fresh_cmd>
# resume する起動コマンドを包む。計画で前回由来の agent だけ、直前確認つきの1行
# (claude_resume_previous_launch_cmd)にし、それ以外は従来の起動直後失敗の復旧経路
# (claude_resume_launch_cmd)。
shutsujin_wrap_resume_cmd() {
    if [ -n "${CLAUDE_RESUME_RUN_TOKEN:-}" ] && [ -n "${1:-}" ] \
        && [ "${CLAUDE_RESUME_PLAN_SOURCE[$1]:-}" = "previous_snapshot" ] \
        && [ "${CLAUDE_RESUME_PLAN_SID[$1]:-}" = "${2:-}" ]; then
        claude_resume_previous_launch_cmd "$CLAUDE_RESUME_PLAN_FILE" "$CLAUDE_RESUME_RUN_TOKEN" "$1" "$2" "$3" "$4"
        return 0
    fi
    claude_resume_launch_cmd "$2" "$3" "$4"
}

# shutsujin_launch_cmd <agent_id> <resume_id>
# build_cli_command の起動コマンドを返す。resume_id がある時は
# shutsujin_wrap_resume_cmd で包み、`--resume` 起動が起動直後に失敗した時に限り
# 同じ打鍵の中で1回だけ従来の新規起動へ倒す(cmd_785 G785-Q01)。
# resume_id が空・ライブラリ未読込なら従来の build_cli_command そのもの。
# 固定の1語(opt-in 時)は build_cli_command が resume・新規の両方の末尾へ同じ形で
# 付けるので、ここでは足さない(cmd_785 Phase 1b)。
shutsujin_launch_cmd() {
    local fresh
    fresh=$(build_cli_command "$1")
    if [ -z "${2:-}" ] || ! declare -F claude_resume_launch_cmd >/dev/null 2>&1; then
        printf '%s\n' "$fresh"
        return 0
    fi
    shutsujin_wrap_resume_cmd "$1" "$2" "$(build_cli_command "$1" "$2")" "$fresh"
}

# shutsujin_log_resume <表示名> <resume_id> [agent_id]
shutsujin_log_resume() {
    if [ -n "${2:-}" ]; then
        if [ -n "${3:-}" ] && [ "${CLAUDE_RESUME_PLAN_SOURCE[$3]:-}" = "previous_snapshot" ]; then
            log_info "  └─ ${1}: 前回の記録から会話を再開(--resume ${2}。起動の直前に稼働状況を再確認し、拒否なら新規起動)"
        else
            log_info "  └─ ${1}: 前回の会話を再開(--resume ${2}。起動直後に失敗すれば1回だけ新規起動へ切替)"
        fi
    fi
    return 0
}

# shutsujin_resume_settle <pane> <agent_id> <cli_type> <送出の rc>
# 起動を送った直後に呼ぶ(cmd_796 §5.2-5)。前回由来の起動がまだ後に残っている間
# (またはこの起動自身が前回由来の時)、送った claude の記録が出るまで有限時間だけ
# 待つ。後続の直前確認が、起動直後で記録の無い claude を「判定不能」として拒否しない
# ようにするため。前回由来の起動で記録を確かめられなければ「未確定」として残す。
shutsujin_resume_settle() {
    local pane="${1:-}" agent="${2:-}" cli="${3:-}" sent="${4:-1}" is_prev=false pane_pid
    [ "${CLAUDE_RESUME_PREV_REMAINING:-0}" -gt 0 ] || return 0
    [ "$cli" = "claude" ] || return 0
    if [ -n "$agent" ] && [ "${CLAUDE_RESUME_PLAN_SOURCE[$agent]:-}" = "previous_snapshot" ]; then
        is_prev=true
        CLAUDE_RESUME_PREV_REMAINING=$((CLAUDE_RESUME_PREV_REMAINING - 1))
    fi
    # 送れなかった pane では何も起動していない(待たない・未確定にもしない)
    [ "$sent" = 0 ] || return 0
    if [ "$is_prev" = false ] && [ "$CLAUDE_RESUME_PREV_REMAINING" -le 0 ]; then
        return 0
    fi
    pane_pid=$(tmux display-message -p -t "$pane" '#{pane_pid}' 2>/dev/null) || pane_pid=""
    if claude_resume_wait_live_record "$pane_pid" "$agent" "$CLAUDE_RESUME_SETTLE_SEC" >/dev/null; then
        return 0
    fi
    log_info "  └─ ⚠️  会話resume: ${agent} の起動後の記録を ${CLAUDE_RESUME_SETTLE_SEC} 秒以内に確かめられない"
    [ "$is_prev" = true ] && CLAUDE_RESUME_UNCONFIRMED+=("$agent")
    return 0
}

# shutsujin_resume_finalize — 全 CLI の起動送出の後に呼ぶ(何度呼んでもよい)。
# 記録を確かめられなかった前回由来の起動を正本から外し(次の出陣が起動前の窓を
# 不在として使わない)、出陣の排他を解く。
shutsujin_resume_finalize() {
    if [ "${#CLAUDE_RESUME_UNCONFIRMED[@]}" -gt 0 ]; then
        if claude_resume_withdraw_previous "$CLAUDE_RESUME_SNAPSHOT_FILE" "${CLAUDE_RESUME_RUN_TOKEN:-none}" "${CLAUDE_RESUME_UNCONFIRMED[@]}"; then
            log_info "  └─ 会話resume: 起動を確かめられなかった前回候補を記録から外した(${CLAUDE_RESUME_UNCONFIRMED[*]})"
        else
            log_info "  └─ ⚠️  会話resume: 起動を確かめられなかった前回候補を記録から外せなかった(${CLAUDE_RESUME_UNCONFIRMED[*]})"
        fi
        CLAUDE_RESUME_UNCONFIRMED=()
    fi
    shutsujin_resume_unlock
}

# ═══════════════════════════════════════════════════════════════════════════════
# オプション解析
# ═══════════════════════════════════════════════════════════════════════════════
SETUP_ONLY=false
OPEN_TERMINAL=false
CLEAN_MODE=false
KESSEN_MODE=false
SHOGUN_NO_THINKING=false
SILENT_MODE=false
SHELL_OVERRIDE=""
# Permission flag (default: dangerously-skip-permissions for backward compat)
PERMISSION_FLAG="--dangerously-skip-permissions"

while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--setup-only)
            SETUP_ONLY=true
            shift
            ;;
        -c|--clean)
            CLEAN_MODE=true
            shift
            ;;
        -k|--kessen)
            KESSEN_MODE=true
            shift
            ;;
        -t|--terminal)
            OPEN_TERMINAL=true
            shift
            ;;
        --shogun-no-thinking)
            SHOGUN_NO_THINKING=true
            shift
            ;;
        --auto-mode-on)
            PERMISSION_FLAG="--permission-mode auto-approved"
            shift
            ;;
        --permission-mode)
            if [[ -n "$2" && "$2" != -* ]]; then
                PERMISSION_FLAG="--permission-mode $2"
                shift 2
            else
                echo "エラー: --permission-mode オプションにはモード名を指定してください"
                exit 1
            fi
            ;;
        -S|--silent)
            SILENT_MODE=true
            shift
            ;;
        -shell|--shell)
            if [[ -n "$2" && "$2" != -* ]]; then
                SHELL_OVERRIDE="$2"
                shift 2
            else
                echo "エラー: -shell オプションには bash または zsh を指定してください"
                exit 1
            fi
            ;;
        -h|--help)
            echo ""
            echo "🏯 multi-agent-shogun 出陣スクリプト"
            echo ""
            echo "使用方法: ./shutsujin_departure.sh [オプション]"
            echo ""
            echo "オプション:"
            echo "  -c, --clean         キューとダッシュボードをリセットして起動（クリーンスタート）"
            echo "                      未指定時は前回の状態を維持して起動"
            echo "  -k, --kessen        決戦の陣（全足軽をOpusで起動）"
            echo "                      未指定時は平時の陣（足軽1-7=Sonnet, 軍師=Opus）"
            echo "  -s, --setup-only    tmuxセッションのセットアップのみ（Claude起動なし）"
            echo "  -t, --terminal      Windows Terminal で新しいタブを開く"
            echo "  -shell, --shell SH  シェルを指定（bash または zsh）"
            echo "                      未指定時は config/settings.yaml の設定を使用"
            echo "  --auto-mode-on      Claude を --permission-mode auto-approved で起動"
            echo "  --permission-mode M Claude の permission mode を明示指定"
            echo "  -S, --silent        サイレントモード（足軽の戦国echo表示を無効化・API節約）"
            echo "                      未指定時はshoutモード（タスク完了時に戦国風echo表示）"
            echo "  -h, --help          このヘルプを表示"
            echo ""
            echo "例:"
            echo "  ./shutsujin_departure.sh              # 前回の状態を維持して出陣"
            echo "  ./shutsujin_departure.sh -c           # クリーンスタート（キューリセット）"
            echo "  ./shutsujin_departure.sh -s           # セットアップのみ（手動でClaude起動）"
            echo "  ./shutsujin_departure.sh -t           # 全エージェント起動 + ターミナルタブ展開"
            echo "  ./shutsujin_departure.sh -shell bash  # bash用プロンプトで起動"
            echo "  ./shutsujin_departure.sh -k           # 決戦の陣（全足軽Opus）"
            echo "  ./shutsujin_departure.sh -c -k         # クリーンスタート＋決戦の陣"
            echo "  ./shutsujin_departure.sh -shell zsh   # zsh用プロンプトで起動"
            echo "  ./shutsujin_departure.sh --shogun-no-thinking  # 将軍のthinkingを無効化（中継特化）"
            echo "  ./shutsujin_departure.sh --auto-mode-on        # permission auto-approved で起動"
            echo "  ./shutsujin_departure.sh --permission-mode plan  # permission mode を明示指定"
            echo "  ./shutsujin_departure.sh -S           # サイレントモード（echo表示なし）"
            echo ""
            echo "モデル構成:"
            echo "  将軍:      Opus（デフォルト。--shogun-no-thinkingで無効化）"
            echo "  家老:      Sonnet（高速タスク管理）"
            echo "  軍師:      Opus（戦略立案・設計判断）"
            echo "  足軽1-7:   Sonnet（実働部隊）"
            echo ""
            echo "陣形:"
            echo "  平時の陣（デフォルト）: 足軽1-7=Sonnet, 軍師=Opus"
            echo "  決戦の陣（--kessen）:   全足軽=Opus, 軍師=Opus"
            echo ""
            echo "表示モード:"
            echo "  shout（デフォルト）:  タスク完了時に戦国風echo表示"
            echo "  silent（--silent）:   echo表示なし（API節約）"
            echo ""
            echo "エイリアス:"
            echo "  csst  → cd $HOME/multi-agent-shogun && ./shutsujin_departure.sh"
            echo "  css   → tmux attach-session -t shogun"
            echo "  csm   → tmux attach-session -t multiagent"
            echo ""
            exit 0
            ;;
        *)
            echo "不明なオプション: $1"
            echo "./shutsujin_departure.sh -h でヘルプを表示"
            exit 1
            ;;
    esac
done

# シェル設定のオーバーライド（コマンドラインオプション優先）
if [ -n "$SHELL_OVERRIDE" ]; then
    if [[ "$SHELL_OVERRIDE" == "bash" || "$SHELL_OVERRIDE" == "zsh" ]]; then
        SHELL_SETTING="$SHELL_OVERRIDE"
    else
        echo "エラー: -shell オプションには bash または zsh を指定してください（指定値: $SHELL_OVERRIDE）"
        exit 1
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# 出陣バナー表示（CC0ライセンスASCIIアート使用）
# ───────────────────────────────────────────────────────────────────────────────
# 【著作権・ライセンス表示】
# 忍者ASCIIアート: syntax-samurai/ryu - CC0 1.0 Universal (Public Domain)
# 出典: https://github.com/syntax-samurai/ryu
# "all files and scripts in this repo are released CC0 / kopimi!"
# ═══════════════════════════════════════════════════════════════════════════════
show_battle_cry() {
    clear

    # タイトルバナー（色付き）
    echo ""
    echo -e "\033[1;31m╔══════════════════════════════════════════════════════════════════════════════════╗\033[0m"
    echo -e "\033[1;31m║\033[0m \033[1;33m███████╗██╗  ██╗██╗   ██╗████████╗███████╗██╗   ██╗     ██╗██╗███╗   ██╗\033[0m \033[1;31m║\033[0m"
    echo -e "\033[1;31m║\033[0m \033[1;33m██╔════╝██║  ██║██║   ██║╚══██╔══╝██╔════╝██║   ██║     ██║██║████╗  ██║\033[0m \033[1;31m║\033[0m"
    echo -e "\033[1;31m║\033[0m \033[1;33m███████╗███████║██║   ██║   ██║   ███████╗██║   ██║     ██║██║██╔██╗ ██║\033[0m \033[1;31m║\033[0m"
    echo -e "\033[1;31m║\033[0m \033[1;33m╚════██║██╔══██║██║   ██║   ██║   ╚════██║██║   ██║██   ██║██║██║╚██╗██║\033[0m \033[1;31m║\033[0m"
    echo -e "\033[1;31m║\033[0m \033[1;33m███████║██║  ██║╚██████╔╝   ██║   ███████║╚██████╔╝╚█████╔╝██║██║ ╚████║\033[0m \033[1;31m║\033[0m"
    echo -e "\033[1;31m║\033[0m \033[1;33m╚══════╝╚═╝  ╚═╝ ╚═════╝    ╚═╝   ╚══════╝ ╚═════╝  ╚════╝ ╚═╝╚═╝  ╚═══╝\033[0m \033[1;31m║\033[0m"
    echo -e "\033[1;31m╠══════════════════════════════════════════════════════════════════════════════════╣\033[0m"
    echo -e "\033[1;31m║\033[0m       \033[1;37m出陣じゃーーー！！！\033[0m    \033[1;36m⚔\033[0m    \033[1;35m天下布武！\033[0m                          \033[1;31m║\033[0m"
    echo -e "\033[1;31m╚══════════════════════════════════════════════════════════════════════════════════╝\033[0m"
    echo ""

    # ═══════════════════════════════════════════════════════════════════════════
    # 足軽隊列（オリジナル）
    # ═══════════════════════════════════════════════════════════════════════════
    echo -e "\033[1;34m  ╔═════════════════════════════════════════════════════════════════════════════╗\033[0m"
    echo -e "\033[1;34m  ║\033[0m                \033[1;37m【 足 軽 隊 列 ・ 七 名 + 軍 師 配 備 】\033[0m                  \033[1;34m║\033[0m"
    echo -e "\033[1;34m  ╚═════════════════════════════════════════════════════════════════════════════╝\033[0m"

    cat << 'ASHIGARU_EOF'

       /\      /\      /\      /\      /\      /\      /\      /\
      /||\    /||\    /||\    /||\    /||\    /||\    /||\    /||\
     /_||\   /_||\   /_||\   /_||\   /_||\   /_||\   /_||\   /_||\
       ||      ||      ||      ||      ||      ||      ||      ||
      /||\    /||\    /||\    /||\    /||\    /||\    /||\    /||\
      /  \    /  \    /  \    /  \    /  \    /  \    /  \    /  \
     [足1]   [足2]   [足3]   [足4]   [足5]   [足6]   [足7]   [軍師]

ASHIGARU_EOF

    echo -e "                    \033[1;36m「「「 はっ！！ 出陣いたす！！ 」」」\033[0m"
    echo ""

    # ═══════════════════════════════════════════════════════════════════════════
    # システム情報
    # ═══════════════════════════════════════════════════════════════════════════
    echo -e "\033[1;33m  ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\033[0m"
    echo -e "\033[1;33m  ┃\033[0m  \033[1;37m🏯 multi-agent-shogun\033[0m  〜 \033[1;36m戦国マルチエージェント統率システム\033[0m 〜           \033[1;33m┃\033[0m"
    echo -e "\033[1;33m  ┃\033[0m                                                                           \033[1;33m┃\033[0m"
    echo -e "\033[1;33m  ┃\033[0m  \033[1;35m将軍\033[0m: 統括  \033[1;31m家老\033[0m: 管理  \033[1;33m軍師\033[0m: 戦略(Opus)  \033[1;34m足軽\033[0m: 実働×7  \033[1;33m┃\033[0m"
    echo -e "\033[1;33m  ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\033[0m"
    echo ""
}

# バナー表示実行
show_battle_cry

echo -e "  \033[1;33m天下布武！陣立てを開始いたす\033[0m (Setting up the battlefield)"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 1: 既存セッションクリーンアップ
# ═══════════════════════════════════════════════════════════════════════════════
log_info "🧹 既存の陣を撤収中..."
# cmd_796: resume 有効時は出陣を排他する。取れなければ撤収の前に止まる(他の出陣を壊さない)。
if ! shutsujin_resume_lock; then
    exit 1
fi
# cmd_785: 撤収(kill-session)の直前に Claude 系 agent の会話 ID を採取する(opt-in)。
shutsujin_claude_resume_snapshot || true
tmux kill-session -t multiagent 2>/dev/null && log_info "  └─ multiagent陣、撤収完了" || log_info "  └─ multiagent陣は存在せず"
tmux kill-session -t shogun 2>/dev/null && log_info "  └─ shogun本陣、撤収完了" || log_info "  └─ shogun本陣は存在せず"

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 1.5: 前回記録のバックアップ（--clean時のみ、内容がある場合）
# ═══════════════════════════════════════════════════════════════════════════════
if [ "$CLEAN_MODE" = true ]; then
    BACKUP_DIR="./logs/backup_$(date '+%Y%m%d_%H%M%S')"
    NEED_BACKUP=false

    if [ -f "./dashboard.md" ]; then
        if grep -q "cmd_" "./dashboard.md" 2>/dev/null; then
            NEED_BACKUP=true
        fi
    fi

    # 既存の dashboard.md 判定の後に追加
    if [ -f "./queue/shogun_to_karo.yaml" ]; then
        if grep -q "id: cmd_" "./queue/shogun_to_karo.yaml" 2>/dev/null; then
            NEED_BACKUP=true
        fi
    fi

    if [ "$NEED_BACKUP" = true ]; then
        mkdir -p "$BACKUP_DIR" || true
        cp "./dashboard.md" "$BACKUP_DIR/" 2>/dev/null || true
        cp -r "./queue/reports" "$BACKUP_DIR/" 2>/dev/null || true
        cp -r "./queue/tasks" "$BACKUP_DIR/" 2>/dev/null || true
        cp "./queue/shogun_to_karo.yaml" "$BACKUP_DIR/" 2>/dev/null || true
        log_info "📦 前回の記録をバックアップ: $BACKUP_DIR"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 2: キューディレクトリ確保 + リセット（--clean時のみリセット）
# ═══════════════════════════════════════════════════════════════════════════════

# queue ディレクトリが存在しない場合は作成（初回起動時に必要）
[ -d ./queue/reports ] || mkdir -p ./queue/reports
[ -d ./queue/tasks ] || mkdir -p ./queue/tasks
# queue/state はmesh登録確認(STEP 6.9)の書込み先。新規/clean環境では
# 偶然にも存在しないことがあるため、他の2つと同じくここで保証する
# (cmd_759 redo1 G759-STATE-DIR-03)。
[ -d ./queue/state ] || mkdir -p ./queue/state
# inbox はLinux FSにシンボリックリンク（WSL2の/mnt/c/ではinotifywaitが動かないため）
# macOSではfswatch使用のためシンボリックリンク不要
if [ "$(uname -s)" != "Darwin" ]; then
    INBOX_LINUX_DIR="$HOME/.local/share/multi-agent-shogun/inbox"
    if [ ! -L ./queue/inbox ]; then
        mkdir -p "$INBOX_LINUX_DIR"
        # ★D002-E1個別記録(cmd_753完了処理redo2・汎用tagには混ぜない):
        # 次行の`rm -rf ./queue/inbox`は、静的検査器
        # (scripts/rm_rf_d002e1_checker.py)が汎用の'./'相対パスとして
        # 「未証明・要人手確認」(FORMAT_ONLY)止まりに倒す対象であり、
        # この分類器上の扱いは変更しない。
        # ★以下は実装が無条件に保証する事実ではない。本ファイル16-17
        # 行目は`BASH_SOURCE[0]`自身のsymlinkをreadlink/realpath等で
        # 解決しておらず、repo外の起動用symlink経由で起動された場合は
        # `SCRIPT_DIR`がリポジトリルートに固定される保証はない。また
        # 本行直前のcheckは`./queue/inbox`自身がsymlinkでないことしか
        # 検証しておらず、親component`./queue`自体が外部を指すsymlink
        # でないことは検証していない。★「本行実行時点のCWDがリポジトリ
        # ルートに固定されており、中間symlinkも経由していない」という
        # のは、直接の標準起動であること・各中間componentが非symlink
        # であることを、この行を書いた時点でレビュー時に別途確認して
        # 初めて成立する条件付きの事実であり、実装自体がそれを恒常的に
        # 保証しているわけではない(無条件に安全と言うには、本スクリプト
        # 自身のsymlink解決と全中間componentのruntime保証、または
        # 再帰削除を避ける設計が別途必要——本redoのscope外)。
        [ -d ./queue/inbox ] && cp ./queue/inbox/*.yaml "$INBOX_LINUX_DIR/" 2>/dev/null && rm -rf ./queue/inbox
        ln -sf "$INBOX_LINUX_DIR" ./queue/inbox
        log_info "  └─ inbox → Linux FS ($INBOX_LINUX_DIR) にシンボリックリンク作成"
    fi
else
    [ -d ./queue/inbox ] || mkdir -p ./queue/inbox
fi

if [ "$CLEAN_MODE" = true ]; then
    log_info "📜 前回の軍議記録を破棄中..."

    # 足軽タスクファイルリセット
    for i in $(seq 1 "$_ASHIGARU_COUNT"); do
        cat > ./queue/tasks/ashigaru${i}.yaml << EOF
# 足軽${i}専用タスクファイル
task:
  task_id: null
  parent_cmd: null
  description: null
  target_path: null
  status: idle
  timestamp: ""
EOF
    done

    # 軍師タスクファイルリセット
    cat > ./queue/tasks/gunshi.yaml << EOF
# 軍師専用タスクファイル
task:
  task_id: null
  parent_cmd: null
  description: null
  target_path: null
  status: idle
  timestamp: ""
EOF

    # 足軽レポートファイルリセット
    for i in $(seq 1 "$_ASHIGARU_COUNT"); do
        cat > ./queue/reports/ashigaru${i}_report.yaml << EOF
worker_id: ashigaru${i}
task_id: null
timestamp: ""
status: idle
result: null
EOF
    done

    # 軍師レポートファイルリセット
    cat > ./queue/reports/gunshi_report.yaml << EOF
worker_id: gunshi
task_id: null
timestamp: ""
status: idle
result: null
EOF

    # ntfy inbox リセット
    echo "inbox:" > ./queue/ntfy_inbox.yaml

    # agent inbox リセット
    for agent in shogun karo $_ASHIGARU_IDS_STR gunshi; do
        echo "messages:" > "./queue/inbox/${agent}.yaml"
    done

    log_success "✅ 陣払い完了"
else
    log_info "📜 前回の陣容を維持して出陣..."
    log_success "✅ キュー・報告ファイルはそのまま継続"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 3: ダッシュボード初期化（--clean時のみ）
# ═══════════════════════════════════════════════════════════════════════════════
if [ "$CLEAN_MODE" = true ]; then
    log_info "📊 戦況報告板を初期化中..."
    TIMESTAMP=$(date "+%Y-%m-%d %H:%M")

    if [ "$LANG_SETTING" = "ja" ]; then
        # 日本語のみ
        cat > ./dashboard.md << EOF
# 📊 戦況報告
最終更新: ${TIMESTAMP}

## 🚨 要対応 - 殿のご判断をお待ちしております
なし

## 🔄 進行中 - 只今、戦闘中でござる
なし

## ✅ 本日の戦果
| 時刻 | 戦場 | 任務 | 結果 |
|------|------|------|------|

## 🎯 スキル化候補 - 承認待ち
なし

## 🛠️ 生成されたスキル
なし

## ⏸️ 待機中
なし

## ❓ 伺い事項
なし
EOF
    else
        # 日本語 + 翻訳併記
        cat > ./dashboard.md << EOF
# 📊 戦況報告 (Battle Status Report)
最終更新 (Last Updated): ${TIMESTAMP}

## 🚨 要対応 - 殿のご判断をお待ちしております (Action Required - Awaiting Lord's Decision)
なし (None)

## 🔄 進行中 - 只今、戦闘中でござる (In Progress - Currently in Battle)
なし (None)

## ✅ 本日の戦果 (Today's Achievements)
| 時刻 (Time) | 戦場 (Battlefield) | 任務 (Mission) | 結果 (Result) |
|------|------|------|------|

## 🎯 スキル化候補 - 承認待ち (Skill Candidates - Pending Approval)
なし (None)

## 🛠️ 生成されたスキル (Generated Skills)
なし (None)

## ⏸️ 待機中 (On Standby)
なし (None)

## ❓ 伺い事項 (Questions for Lord)
なし (None)
EOF
    fi

    log_success "  └─ ダッシュボード初期化完了 (言語: $LANG_SETTING, シェル: $SHELL_SETTING)"
else
    log_info "📊 前回のダッシュボードを維持"
fi
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 4: tmux の存在確認
# ═══════════════════════════════════════════════════════════════════════════════
if ! command -v tmux &> /dev/null; then
    echo ""
    echo "  ╔════════════════════════════════════════════════════════╗"
    echo "  ║  [ERROR] tmux not found!                              ║"
    echo "  ║  tmux が見つかりません                                 ║"
    echo "  ╠════════════════════════════════════════════════════════╣"
    echo "  ║  Run first_setup.sh first:                            ║"
    echo "  ║  まず first_setup.sh を実行してください:               ║"
    echo "  ║     ./first_setup.sh                                  ║"
    echo "  ╚════════════════════════════════════════════════════════╝"
    echo ""
    exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 5: shogun セッション作成（1ペイン・window 0 を必ず確保）
# ═══════════════════════════════════════════════════════════════════════════════
log_war "👑 将軍の本陣を構築中..."

# shogun セッションがなければ作る（-s 時もここで必ず shogun が存在するようにする）
# window 0 のみ作成し -n main で名前付け（第二 window にするとアタッチ時に空ペインが開くため 1 window に限定）
if ! tmux has-session -t shogun 2>/dev/null; then
    # 9>&-: 出陣の排他(FD 9・cmd_796)を、ここで起動し得る tmux server へ継承させない
    tmux new-session -d -s shogun -n main 9>&-
fi
shutsujin_detach_runtime_dir shogun

# スマホ等の小画面クライアント対策: aggressive-resize + latest
# css関数がスマホ用に専用ウィンドウを作るので、PCのウィンドウに干渉しない
tmux set-option -g window-size latest
tmux set-option -g aggressive-resize on

# 将軍ペインはウィンドウ名 "main" で指定（base-index 1 環境でも動く）
SHOGUN_PROMPT=$(generate_prompt "将軍" "magenta" "$SHELL_SETTING")
shutsujin_send_launch shogun:main "将軍paneのPS1設定" "$(shutsujin_pane_init_cmd "$SHOGUN_PROMPT")" Enter || true
tmux select-pane -t shogun:main -P 'bg=#002b36'  # 将軍の Solarized Dark
tmux set-option -p -t shogun:main @agent_id "shogun"

log_success "  └─ 将軍の本陣、構築完了"
echo ""

# pane-base-index を取得（1 の環境ではペインは 1,2,... になる）
PANE_BASE=$(tmux show-options -gv pane-base-index 2>/dev/null || echo 0)

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 5.1: multiagent セッション作成（9ペイン：karo + ashigaru1-8）
# ═══════════════════════════════════════════════════════════════════════════════
log_war "⚔️ 家老・足軽・軍師の陣を構築中（9名配備）..."

# 最初のペイン作成(9>&-: 出陣の排他の FD を tmux server へ継承させない。cmd_796)
if ! tmux new-session -d -s multiagent -n "agents" 2>/dev/null 9>&-; then
    echo ""
    echo "  ╔════════════════════════════════════════════════════════════╗"
    echo "  ║  [ERROR] Failed to create tmux session 'multiagent'      ║"
    echo "  ║  tmux セッション 'multiagent' の作成に失敗しました       ║"
    echo "  ╠════════════════════════════════════════════════════════════╣"
    echo "  ║  An existing session may be running.                     ║"
    echo "  ║  既存セッションが残っている可能性があります              ║"
    echo "  ║                                                          ║"
    echo "  ║  Check: tmux ls                                          ║"
    echo "  ║  Kill:  tmux kill-session -t multiagent                  ║"
    echo "  ╚════════════════════════════════════════════════════════════╝"
    echo ""
    exit 1
fi
# ★下の split-window より前に置く(分割で生まれる pane が除去印を継ぐため)
shutsujin_detach_runtime_dir multiagent

# DISPLAY_MODE: shout (default) or silent (--silent flag)
if [ "$SILENT_MODE" = true ]; then
    tmux set-environment -t multiagent DISPLAY_MODE "silent"
    echo "  📢 表示モード: サイレント（echo表示なし）"
else
    tmux set-environment -t multiagent DISPLAY_MODE "shout"
fi

# 3x3グリッド作成（合計9ペイン）
# ペイン番号は pane-base-index に依存（0 または 1）
# 最初に3列に分割
tmux split-window -h -t "multiagent:agents"
tmux split-window -h -t "multiagent:agents"

# 各列を3行に分割
tmux select-pane -t "multiagent:agents.${PANE_BASE}"
tmux split-window -v
tmux split-window -v

tmux select-pane -t "multiagent:agents.$((PANE_BASE+3))"
tmux split-window -v
tmux split-window -v

tmux select-pane -t "multiagent:agents.$((PANE_BASE+6))"
tmux split-window -v
tmux split-window -v

# ペインラベル・エージェントID・色設定 — settings.yaml から動的に構築
PANE_LABELS=("karo")
AGENT_IDS=("karo")
PANE_COLORS=("red")
for _ai in $_ASHIGARU_IDS_STR; do
    PANE_LABELS+=("$_ai")
    AGENT_IDS+=("$_ai")
    PANE_COLORS+=("blue")
done
PANE_LABELS+=("gunshi")
AGENT_IDS+=("gunshi")
PANE_COLORS+=("yellow")

# モデル名設定（pane-border-format で常時表示するため）- 動的構築
MODEL_NAMES=()
for _ai in "${AGENT_IDS[@]}"; do
    if [[ "$_ai" == "gunshi" ]]; then
        MODEL_NAMES+=("Opus")
    elif [ "$KESSEN_MODE" = true ]; then
        MODEL_NAMES+=("Opus")
    else
        MODEL_NAMES+=("Sonnet")
    fi
done

# CLI Adapter経由でモデル表示名を統一形式で設定
# get_model_display_name(): Sonnet, Opus+T, Haiku, Codex, Spark 等の短縮名を返す
if [ "$CLI_ADAPTER_LOADED" = true ]; then
    for i in "${!AGENT_IDS[@]}"; do
        _agent="${AGENT_IDS[$i]}"
        MODEL_NAMES[$i]=$(get_model_display_name "$_agent")
    done
fi

for i in "${!AGENT_IDS[@]}"; do
    p=$((PANE_BASE + i))
    tmux select-pane -t "multiagent:agents.${p}" -T "${MODEL_NAMES[$i]}"
    tmux set-option -p -t "multiagent:agents.${p}" @agent_id "${AGENT_IDS[$i]}"
    tmux set-option -p -t "multiagent:agents.${p}" @model_name "${MODEL_NAMES[$i]}"
    tmux set-option -p -t "multiagent:agents.${p}" @current_task ""
    PROMPT_STR=$(generate_prompt "${PANE_LABELS[$i]}" "${PANE_COLORS[$i]}" "$SHELL_SETTING")
    shutsujin_send_launch "multiagent:agents.${p}" "${AGENT_IDS[$i]}paneのPS1設定" "$(shutsujin_pane_init_cmd "$PROMPT_STR")" Enter || true
done

# 家老・軍師ペインの背景色（足軽との視覚的区別）
# 注: グループセッションで背景色が引き継がれない問題があるため、コメントアウト（2026-02-14）
# tmux select-pane -t "multiagent:agents.${PANE_BASE}" -P 'bg=#501515'          # 家老: 赤
# tmux select-pane -t "multiagent:agents.$((PANE_BASE+8))" -P 'bg=#454510'      # 軍師: 金

# pane-border-format でモデル名を常時表示
tmux set-option -t multiagent -w pane-border-status top
tmux set-option -t multiagent -w pane-border-format '#{?pane_active,#[reverse],}#[bold]#{@agent_id}#[default] (#{@model_name}) #{@current_task}'

log_success "  └─ 家老・足軽・軍師の陣、構築完了"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 6: Claude Code 起動（-s / --setup-only のときはスキップ）
# ═══════════════════════════════════════════════════════════════════════════════
if [ "$SETUP_ONLY" = false ]; then
    # CLI の存在チェック（Multi-CLI対応）
    if [ "$CLI_ADAPTER_LOADED" = true ]; then
        _default_cli=$(get_cli_type "")
        if ! validate_cli_availability "$_default_cli"; then
            exit 1
        fi
    else
        if ! command -v claude &> /dev/null; then
            log_info "⚠️  claude コマンドが見つかりません"
            echo "  first_setup.sh を再実行してください:"
            echo "    ./first_setup.sh"
            exit 1
        fi
    fi

    # 前セッションのstaleフラグをクリア
    rm -f /tmp/shogun_idle_*
    echo "idle flags cleared"

    log_war "👑 全軍に Claude Code を召喚中..."

    # 将軍: CLI Adapter経由でコマンド構築
    _shogun_cli_type="claude"
    _shogun_cmd="claude --model opus --name shogun --effort max $PERMISSION_FLAG"
    _shogun_resume=""
    if [ "$CLI_ADAPTER_LOADED" = true ]; then
        _shogun_cli_type=$(get_cli_type "shogun")
        _shogun_resume=$(shutsujin_resume_id "shogun" "$_shogun_cli_type")
        _shogun_cmd=$(shutsujin_launch_cmd "shogun" "$_shogun_resume")
    fi
    # --shogun-no-thinking → settings.yaml の thinking を一時的に false にして build_cli_command に任せる
    if [ "$SHOGUN_NO_THINKING" = true ] && [ "$CLI_ADAPTER_LOADED" = true ]; then
        "$CLI_ADAPTER_PROJECT_ROOT/.venv/bin/python3" -c "
import yaml
f = '${CLI_ADAPTER_SETTINGS}'
with open(f) as fh: d = yaml.safe_load(fh) or {}
d.setdefault('cli',{}).setdefault('agents',{}).setdefault('shogun',{})['thinking'] = False
with open(f,'w') as fh: yaml.safe_dump(d, fh, default_flow_style=False, allow_unicode=True, sort_keys=False)
" 2>/dev/null
        _shogun_cmd=$(shutsujin_launch_cmd "shogun" "$_shogun_resume")
        log_info "  └─ 将軍 settings.yaml thinking=false に設定"
    fi
    shutsujin_log_resume "将軍" "$_shogun_resume" shogun
    tmux set-option -p -t "shogun:main" @agent_cli "$_shogun_cli_type"
    _launch_rc=0
    shutsujin_send_launch shogun:main "将軍のCLI起動" "$_shogun_cmd" \
        && shutsujin_send_launch shogun:main "将軍のCLI起動Enter" Enter || _launch_rc=1
    shutsujin_resume_settle shogun:main shogun "$_shogun_cli_type" "$_launch_rc"
    opencode_startup_delay "$_shogun_cli_type"
    _shogun_display=$(get_model_display_name "shogun" 2>/dev/null || echo "Opus")
    tmux set-option -p -t "shogun:main" @model_name "$_shogun_display" 2>/dev/null || true
    log_info "  └─ 将軍（${_shogun_cli_type} / ${_shogun_display}）、召喚完了"

    # 少し待機（安定のため）
    sleep 1

    # 家老（pane 0）: CLI Adapter経由でコマンド構築（デフォルト: Sonnet）
    p=$((PANE_BASE + 0))
    _karo_cli_type="claude"
    _karo_cmd="claude --model sonnet --name karo --effort max $PERMISSION_FLAG"
    if [ "$CLI_ADAPTER_LOADED" = true ]; then
        _karo_cli_type=$(get_cli_type "karo")
        _karo_resume=$(shutsujin_resume_id "karo" "$_karo_cli_type")
        _karo_cmd=$(shutsujin_launch_cmd "karo" "$_karo_resume")
        shutsujin_log_resume "家老" "$_karo_resume" karo
    fi
    tmux set-option -p -t "multiagent:agents.${p}" @agent_cli "$_karo_cli_type"
    _launch_rc=0
    shutsujin_send_launch "multiagent:agents.${p}" "家老のCLI起動" "$_karo_cmd" \
        && shutsujin_send_launch "multiagent:agents.${p}" "家老のCLI起動Enter" Enter || _launch_rc=1
    shutsujin_resume_settle "multiagent:agents.${p}" karo "$_karo_cli_type" "$_launch_rc"
    opencode_startup_delay "$_karo_cli_type"
    _karo_display=$(get_model_display_name "karo" 2>/dev/null || echo "Sonnet")
    tmux set-option -p -t "multiagent:agents.${p}" @model_name "$_karo_display" 2>/dev/null || true
    log_info "  └─ 家老（${_karo_display}）、召喚完了"

    if [ "$KESSEN_MODE" = true ]; then
        # 決戦の陣: CLI Adapter経由（claudeはOpus強制）
        for i in $(seq 1 "$_ASHIGARU_COUNT"); do
            p=$((PANE_BASE + i))
            _ashi_cli_type="claude"
            _ashi_cmd="claude --model opus --name ashigaru${i} --effort max $PERMISSION_FLAG"
            if [ "$CLI_ADAPTER_LOADED" = true ]; then
                _ashi_cli_type=$(get_cli_type "ashigaru${i}")
                if [ "$_ashi_cli_type" = "claude" ]; then
                    # cmd_785: 採取した会話IDは claude_resume_lookup が UUID 形式を検査済み。
                    # resume する時は起動直後の失敗に限り1回だけ新規起動へ倒す形に包む。
                    # resume 側は従来コマンドの claude の直後へ --resume を足して組む
                    # (引数を書き写さない=同じ従来引数であることを構造で保つ)。
                    _ashi_resume=$(shutsujin_resume_id "ashigaru${i}" "$_ashi_cli_type")
                    _ashi_cmd="claude --model opus --name ashigaru${i} --effort max $PERMISSION_FLAG"
                    _ashi_prompt=$(get_startup_prompt_arg "ashigaru${i}")  # cmd_785 Phase 1b: opt-in 時の固定の1語(build_cli_command と同じ)
                    _ashi_cmd="${_ashi_cmd}${_ashi_prompt:+ $_ashi_prompt}"  # resume 側はこの _ashi_cmd から組む=resume・新規に1回ずつ
                    if [ -n "$_ashi_resume" ]; then
                        _ashi_cmd=$(shutsujin_wrap_resume_cmd "ashigaru${i}" "$_ashi_resume" \
                            "claude --resume ${_ashi_resume}${_ashi_cmd#claude}" "$_ashi_cmd")
                    fi
                    shutsujin_log_resume "足軽${i}" "$_ashi_resume" "ashigaru${i}"
                else
                    _ashi_cmd=$(build_cli_command "ashigaru${i}")
                fi
            fi
            tmux set-option -p -t "multiagent:agents.${p}" @agent_cli "$_ashi_cli_type"
            _launch_rc=0
            shutsujin_send_launch "multiagent:agents.${p}" "足軽${i}のCLI起動" "$_ashi_cmd" \
                && shutsujin_send_launch "multiagent:agents.${p}" "足軽${i}のCLI起動Enter" Enter || _launch_rc=1
            shutsujin_resume_settle "multiagent:agents.${p}" "ashigaru${i}" "$_ashi_cli_type" "$_launch_rc"
            opencode_startup_delay "$_ashi_cli_type"
        done
        log_info "  └─ 足軽1-${_ASHIGARU_COUNT}（決戦の陣）、召喚完了"
    else
        # 平時の陣: CLI Adapter経由（デフォルト: 全足軽=Sonnet）
        for i in $(seq 1 "$_ASHIGARU_COUNT"); do
            p=$((PANE_BASE + i))
            _ashi_cli_type="claude"
            _ashi_cmd="claude --model sonnet --name ashigaru${i} --effort max $PERMISSION_FLAG"
            if [ "$CLI_ADAPTER_LOADED" = true ]; then
                _ashi_cli_type=$(get_cli_type "ashigaru${i}")
                _ashi_resume=$(shutsujin_resume_id "ashigaru${i}" "$_ashi_cli_type")
                _ashi_cmd=$(shutsujin_launch_cmd "ashigaru${i}" "$_ashi_resume")
                shutsujin_log_resume "足軽${i}" "$_ashi_resume" "ashigaru${i}"
            fi
            tmux set-option -p -t "multiagent:agents.${p}" @agent_cli "$_ashi_cli_type"
            _launch_rc=0
            shutsujin_send_launch "multiagent:agents.${p}" "足軽${i}のCLI起動" "$_ashi_cmd" \
                && shutsujin_send_launch "multiagent:agents.${p}" "足軽${i}のCLI起動Enter" Enter || _launch_rc=1
            shutsujin_resume_settle "multiagent:agents.${p}" "ashigaru${i}" "$_ashi_cli_type" "$_launch_rc"
            opencode_startup_delay "$_ashi_cli_type"
        done
        log_info "  └─ 足軽1-${_ASHIGARU_COUNT}（平時の陣）、召喚完了"
    fi

    # 軍師（pane _ASHIGARU_COUNT+1）: Opus Thinking — 戦略立案・設計判断専任
    p=$((PANE_BASE + _ASHIGARU_COUNT + 1))
    _gunshi_cli_type="claude"
    _gunshi_cmd="claude --model opus --name gunshi --effort max $PERMISSION_FLAG"
    if [ "$CLI_ADAPTER_LOADED" = true ]; then
        _gunshi_cli_type=$(get_cli_type "gunshi")
        _gunshi_resume=$(shutsujin_resume_id "gunshi" "$_gunshi_cli_type")
        _gunshi_cmd=$(shutsujin_launch_cmd "gunshi" "$_gunshi_resume")
        shutsujin_log_resume "軍師" "$_gunshi_resume" gunshi
    fi
    tmux set-option -p -t "multiagent:agents.${p}" @agent_cli "$_gunshi_cli_type"
    _launch_rc=0
    shutsujin_send_launch "multiagent:agents.${p}" "軍師のCLI起動" "$_gunshi_cmd" \
        && shutsujin_send_launch "multiagent:agents.${p}" "軍師のCLI起動Enter" Enter || _launch_rc=1
    shutsujin_resume_settle "multiagent:agents.${p}" gunshi "$_gunshi_cli_type" "$_launch_rc"
    opencode_startup_delay "$_gunshi_cli_type"
    _gunshi_display=$(get_model_display_name "gunshi" 2>/dev/null || echo "Opus+T")
    tmux set-option -p -t "multiagent:agents.${p}" @model_name "$_gunshi_display" 2>/dev/null || true
    log_info "  └─ 軍師（${_gunshi_display}）、召喚完了"

    if [ "$KESSEN_MODE" = true ]; then
        log_success "✅ 決戦の陣で出陣！全軍Opus！"
    else
        log_success "✅ 平時の陣で出陣（家老=Sonnet, 足軽=Sonnet, 軍師=Opus）"
    fi
    echo ""

    # cmd_796: 全 CLI の起動送出が済んだ。記録を確かめられなかった前回候補を正本から外し、
    # 出陣の排他を解く(この後に起動する inbox_watcher 等へ FD 9 を継承させない)。
    shutsujin_resume_finalize

    # ═══════════════════════════════════════════════════════════════════════════
    # STEP 6.5: 各エージェントに指示書を読み込ませる
    # ═══════════════════════════════════════════════════════════════════════════
    log_war "📜 各エージェントに指示書を読み込ませ中..."
    echo ""

    # ═══════════════════════════════════════════════════════════════════════════
    # 忍者戦士（syntax-samurai/ryu - CC0 1.0 Public Domain）
    # ═══════════════════════════════════════════════════════════════════════════
    echo -e "\033[1;35m  ┌────────────────────────────────────────────────────────────────────────────────────────────────────────────┐\033[0m"
    echo -e "\033[1;35m  │\033[0m                              \033[1;37m【 忍 者 戦 士 】\033[0m  Ryu Hayabusa (CC0 Public Domain)                        \033[1;35m│\033[0m"
    echo -e "\033[1;35m  └────────────────────────────────────────────────────────────────────────────────────────────────────────────┘\033[0m"

    cat << 'NINJA_EOF'
...................................░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒                        ...................................
..................................░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒                        ...................................
..................................░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒                        ...................................
..................................░░░░░░░░░░░░░░░░░░░░░░░░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒                        ...................................
..................................░░░░░░░░░░░░░░░░░░░░░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒                        ...................................
..................................░░░░░░░░░░░░░░░░░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒░░░░░░░░▒▒▒▒▒▒                         ...................................
..................................░░░░░░░░░░░░░░░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒  ▒▒▒▒▒▒░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒░░░░░░░░▒▒▒▒▒▒▒                         ...................................
..................................░░░░░░░░░░░░░░░░▒▒▒▒          ▒▒▒▒▒▒▒▒░░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒░░░░▒▒▒▒▒▒▒▒▒                             ...................................
..................................░░░░░░░░░░░░░░▒▒▒▒               ▒▒▒▒▒░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒                                ...................................
..................................░░░░░░░░░░░░░▒▒▒                    ▒▒▒▒░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒                                    ...................................
..................................░░░░░░░░░░░░▒                            ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒                                        ...................................
..................................░░░░░░░░░░░      ░░░░░░░░░░░░░                                      ░░░░░░░░░░░░       ▒          ...................................
..................................░░░░░░░░░░ ▒    ░░░▓▓▓▓▓▓▓▓▓▓▓▓░░                                 ░░░░░░░░░░░░░░░ ░               ...................................
..................................░░░░░░░░░░     ░░░▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░                          ░░░░░░░░░░░░░░░░░░░                ...................................
..................................░░░░░░░░░ ▒  ░░░░▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░             ░░▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░  ░   ▒         ...................................
..................................░░░░░░░░ ░  ░░░░░░▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░ ░  ▒         ...................................
..................................░░░░░░░░ ░  ░░░░░░░▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░  ░    ▒        ...................................
..................................░░░░░░░░░▒  ░ ░               ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░▓▓▓▓▓▓▓▓▓▓▓░                 ░            ...................................
.................................░░░░░░░░░░   ░░░  ░                 ▓▓▓▓▓▓▓▓░▓▓▓▓░░░▓░░░░░░▓▓▓▓▓                    ░ ░   ▒         ..................................
.................................░░░░░░░░▒▒   ░░░░░ ░                  ▓▓▓▓▓▓░▓▓▓▓░░▓▓▓░░░░░░▓▓                    ░  ░ ░  ▒         ..................................
.................................░░░░░░░░▒    ░░░░░░░░░ ░                 ░▓░░▓▓▓▓▓░▓▓▓░░░░░                   ░ ░░ ░░ ░   ▒         ..................................
.................................░░░░░░░▒▒    ░░░░░░░   ░░                    ▓▓▓▓▓▓▓▓▓░░                   ░░    ░ ░░ ░    ▒        ..................................
.................................░░░░░░░▒▒    ░░░░░░░░░░                      ░▓▓▓▓▓▓▓░░░                     ░░░  ░  ░ ░   ▒        ..................................
.................................░░░░░░░ ▒    ░░░░░░                         ░░░▓▓▓░▓░░░░      ░                  ░ ░░ ░    ▒        ..................................
.................................░░░░░░░ ▒    ░░░░░░░     ▓▓        ▓  ░░ ░░░░░░░░░░░░░  ░   ░░  ▓        █▓       ░  ░ ░   ▒▒       ..................................
..................................░░░░░▒ ▒    ░░░░░░░░  ▓▓██  ▓  ██ ██▓  ▓ ░░░▓░  ░ ░ ░░░░  ▓   ██ ▓█  ▓  ██▓▓  ░░░░  ░ ░    ▒      ...................................
..................................░░░░░▒ ▒▒   ░░░░░░░░░  ▓██  ▓▓  ▓ ██▓  ▓░░░░▓▓░  ░░░░░░░░ ▓  ▓██ ▓   ▓  ██▓▓ ░░░░░░░ ░     ▒      ...................................
..................................░░░░░  ▒░   ░░░░░░░▓░░ ▓███  ▓▓▓▓ ███░  ░░░░▓▓░░░░░░░░░░    ░▓██  ▓▓▓  ███▓ ░░▓▓░░  ░    ▒ ▒      ...................................
...................................░░░░  ▒░    ░░░░▓▓▓▓▓▓░  ███    ██      ░░░░░▓▓▓▓▓░░░░░░░     ███   ████ ░░▓▓▓▓░░  ░    ▒ ▒      ...................................
...................................░░░░ ▒ ░▒    ░░▓▓▓▓▓▓▓▓▓▓ ██████  ▓▓▓░░ ░░░░▓▓▓▓▓▓░░░░░░░░░▓▓▓   █████  ▓▓▓▓▓▓▓░░░░    ▒▒ ▒      ...................................
...................................░░░░ ░ ░░     ░▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓█░░░░░░░▓▓▓▓▓▓▓░░░░ ░░   ░░▓░▓▓░░░░░░░▓▓▓▓▓▓░░      ▒▒ ▒      ...................................
...................................░░░░ ░ ░░      ░▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓██  ░░░░░░░▓▓▓▓▓▓▓░░░░  ░░░░░   ░░░░░░░░░▓▓▓▓▓░░ ░    ▒▒  ▒      ...................................
...................................░░░░▒░░▒░░      ░▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░▓▓▓▓▓▓▓▓░░░  ░░░░░░░░░░░░░░░░░░▓▓░░░░      ▒▒  ▒     ....................................
...................................░░░░▒░░ ░░       ░▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░▓▓▓▓▓▓▓▓▓░░░░  ░░░░░░░░░░░░░░░░░░░░░        ▒▒  ▒     ....................................
...................................░░░░░░░ ▒░▒       ░▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░▓▓▓░░   ░░░░░  ░░░░░░░░░░░░░░░░░░░░         ▒   ▒     ....................................
...................................░░░░░░░░░░░           ░▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓              ░    ░░░░░░░░░░░░░░░            ▒   ▒     ....................................
....................................░░░░░░░░░░░▒  ▒▒        ▓▓▓▓▓▓▓▓▓▓▓▓▓  ░░░░░░░░░░▒▒                         ▒▒▒▒▒   ▒    ▒    .....................................
....................................░░░░░░░░░░ ░▒ ▒▒▒░░░        ▓▓▓▓▓▓   ░░░░░░░░░░░░░▒▒▒      ▒▒▒▒▒░░░░▒▒    ▒▒▒▒▒▒▒  ▒▒    ▒    .....................................
....................................░░░░░░░░░░ ░░░ ▒▒▒░░░░░░          ░░░░░ ░░░░░░░░░░▒░▒     ▒▒▒▒▒▒░░░░░░▒▒▒▒▒░▒▒▒▒   ▒▒         .....................................
.....................................░░░░░░░░░░ ░░░░░  ▒▒░░░░░░░░░░░░░    ░░░░░░░░░  ▒░▒▒    ▒▒▒▒▒░░░░▒▒▒▒▒▒░░▒▒▒   ▒▒▒         ......................................
.....................................░░░░░░░░░░░░░░░░░░  ▒░░░░░░░░░░░   ░░░░░░░░░░░░░░   ▒   ▒▒▒▒▒▒▒░▒▒▒▒▒▒░░░░▒▒▒   ▒▒          ......................................
.....................................░░░░░░░░░░░ ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░      ▒▒▒▒▒▒▒    ▒  ░░░▒▒▒▒  ▒▒▒          ......................................
......................................░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ ▒░▒▒▒ ▒▒▒    ▒░░░░░░░░░░▒   ▒▒▒▒      ▒   .......................................
......................................░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▒  ░░▒▒▒▒▒▒░░░░░░░░░░░░░▒  ░▒▒▒▒       ▒   .......................................
......................................░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▒ ▒▒░▒▒▒▒▒▒▒░░░░░░░░░░  ░░▒▒▒▒▒       ▒   .......................................
......................................░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▒▒ ░▒▒▒▒▒▒▒▒▒░░▒░░░░░░ ░░▒▒▒▒▒▒      ▒    .......................................
.......................................░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▒▒░░▒░▒▒▒ ▒▒▒▒▒░░░░░░░░░▒▒▒▒▒        ▒    .......................................
.......................................░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▒▒▒▒░▒▒▒▒▒     ░░░░░░░░▒▒▒▒▒▒        ▒    .......................................
.......................................░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▒▒▒░░▒░▒▒▒▒▒▒  ▒░░░░░░░▒▒▒▒▒▒        ▒     .......................................
NINJA_EOF

    echo ""
    echo -e "                                    \033[1;35m「 天下布武！勝利を掴め！ 」\033[0m"
    echo ""
    echo -e "                               \033[0;36m[ASCII Art: syntax-samurai/ryu - CC0 1.0 Public Domain]\033[0m"
    echo ""

    echo "  Claude Code の起動を待機中（最大30秒）..."

    # 将軍の起動を確認（最大30秒待機）
    for i in {1..30}; do
        if tmux capture-pane -t shogun:main -p | grep -q "bypass permissions"; then
            echo "  └─ 将軍の Claude Code 起動確認完了（${i}秒）"
            break
        fi
        sleep 1
    done

    # ═══════════════════════════════════════════════════════════════════
    # STEP 6.6: inbox_watcher起動（全エージェント）
    # ═══════════════════════════════════════════════════════════════════
    log_info "📬 メールボックス監視を起動中..."

    # inbox ディレクトリ初期化（シンボリックリンク先のLinux FSに作成）
    mkdir -p "$SCRIPT_DIR/logs"
    for agent in shogun karo $_ASHIGARU_IDS_STR gunshi; do
        [ -f "$SCRIPT_DIR/queue/inbox/${agent}.yaml" ] || echo "messages:" > "$SCRIPT_DIR/queue/inbox/${agent}.yaml"
    done

    # 既存のwatcherと孤児inotifywait/fswatchをkill
    pkill -f "inbox_watcher.sh" 2>/dev/null || true
    pkill -f "inotifywait.*queue/inbox" 2>/dev/null || true
    pkill -f "fswatch.*queue/inbox" 2>/dev/null || true
    sleep 1

    # 将軍のwatcher（ntfy受信の自動起床に必要）
    # 安全モード: phase2/phase3エスカレーションは無効、timeout周期処理も無効（event-drivenのみ）
    _shogun_watcher_cli=$(tmux show-options -p -t "shogun:main" -v @agent_cli 2>/dev/null || echo "claude")
    nohup env ASW_DISABLE_ESCALATION=1 ASW_PROCESS_TIMEOUT=0 ASW_DISABLE_NORMAL_NUDGE=0 \
        bash "$SCRIPT_DIR/scripts/inbox_watcher.sh" shogun "shogun:main" "$_shogun_watcher_cli" \
        >> "$SCRIPT_DIR/logs/inbox_watcher_shogun.log" 2>&1 &
    disown

    # 家老のwatcher
    _karo_watcher_cli=$(tmux show-options -p -t "multiagent:agents.${PANE_BASE}" -v @agent_cli 2>/dev/null || echo "claude")
    nohup bash "$SCRIPT_DIR/scripts/inbox_watcher.sh" karo "multiagent:agents.${PANE_BASE}" "$_karo_watcher_cli" \
        >> "$SCRIPT_DIR/logs/inbox_watcher_karo.log" 2>&1 &
    disown

    # 足軽のwatcher
    for i in $(seq 1 "$_ASHIGARU_COUNT"); do
        p=$((PANE_BASE + i))
        _ashi_watcher_cli=$(tmux show-options -p -t "multiagent:agents.${p}" -v @agent_cli 2>/dev/null || echo "claude")
        nohup bash "$SCRIPT_DIR/scripts/inbox_watcher.sh" "ashigaru${i}" "multiagent:agents.${p}" "$_ashi_watcher_cli" \
            >> "$SCRIPT_DIR/logs/inbox_watcher_ashigaru${i}.log" 2>&1 &
        disown
    done

    # 軍師のwatcher
    p=$((PANE_BASE + _ASHIGARU_COUNT + 1))
    _gunshi_watcher_cli=$(tmux show-options -p -t "multiagent:agents.${p}" -v @agent_cli 2>/dev/null || echo "claude")
    nohup bash "$SCRIPT_DIR/scripts/inbox_watcher.sh" "gunshi" "multiagent:agents.${p}" "$_gunshi_watcher_cli" \
        >> "$SCRIPT_DIR/logs/inbox_watcher_gunshi.log" 2>&1 &
    disown

    log_success "  └─ $((_ASHIGARU_COUNT + 3))エージェント分のinbox_watcher起動完了（将軍+家老+足軽${_ASHIGARU_COUNT}+軍師）"

    # STEP 6.7 は廃止 — CLAUDE.md Session Start (step 1: tmux agent_id) で各自が自律的に
    # 自分のinstructions/*.mdを読み込む。検証済み (2026-02-08)。
    log_info "📜 指示書読み込みは各エージェントが自律実行（CLAUDE.md Session Start）"
    echo ""

    # ═══════════════════════════════════════════════════════════════════
    # STEP 6.9: mesh登録preflight（cmd_759 A-3・read-only）
    # ═══════════════════════════════════════════════════════════════════
    # ★ここまでで将軍起動待ち（最大30秒・上記）とinbox_watcher起動が既に
    #   実時間を消費している。mesh登録（本体の置場規則による cc-socks 配下の
    #   socket。上記 shutsujin_pane_init_cmd により既定では /tmp/cc-socks/）は
    #   起動直後は未完了のことがある実測があるため（docs/delivery_channels.md
    #   参照）、新たなsleep/pollingループは追加せず、ここまでの自然な経過
    #   時間の後に一度だけ確認する（CLAUDE.md/cmd_759 A-3「固定sleepでの
    #   ポーリングループ化は避け一回性の確認に留める」に従う）。
    # ★未登録paneがあっても、対象peerへの入力送信・再起動は行わない
    #   (pane観測はread-only)。ただしstate永続化とKaro inboxへの
    #   delivery_alert通知(shutsujin_mesh_check内・下記参照)は行う。
    if [ "$MESH_CHECK_LOADED" = true ]; then
        log_info "🔌 mesh登録を確認中（read-only）..."
        shutsujin_mesh_check
        echo ""
    fi
fi
# cmd_796: -s(起動なし)でも、常駐プロセス(ntfy リスナー等)を起こす前に出陣の排他を解く
shutsujin_resume_finalize

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 6.7.5: ntfy_inbox 古メッセージ退避（7日より前のprocessed分をアーカイブ）
# ═══════════════════════════════════════════════════════════════════════════════
if [ -f ./queue/ntfy_inbox.yaml ]; then
    _archive_result=$(python3 -c "
import yaml, sys
from datetime import datetime, timedelta, timezone

INBOX = './queue/ntfy_inbox.yaml'
ARCHIVE = './queue/ntfy_inbox_archive.yaml'
DAYS = 7

with open(INBOX) as f:
    data = yaml.safe_load(f) or {}

entries = data.get('inbox', []) or []
if not entries:
    sys.exit(0)

cutoff = datetime.now(timezone(timedelta(hours=9))) - timedelta(days=DAYS)
recent, old = [], []

for e in entries:
    ts = e.get('timestamp', '')
    try:
        dt = datetime.fromisoformat(str(ts))
        if dt < cutoff and e.get('status') == 'processed':
            old.append(e)
        else:
            recent.append(e)
    except Exception:
        recent.append(e)

if not old:
    sys.exit(0)

# Append to archive
try:
    with open(ARCHIVE) as f:
        archive = yaml.safe_load(f) or {}
except FileNotFoundError:
    archive = {}
archive_entries = archive.get('inbox', []) or []
archive_entries.extend(old)
with open(ARCHIVE, 'w') as f:
    yaml.dump({'inbox': archive_entries}, f, allow_unicode=True, default_flow_style=False)

# Write back recent only
with open(INBOX, 'w') as f:
    yaml.dump({'inbox': recent}, f, allow_unicode=True, default_flow_style=False)

print(f'{len(old)}件退避 {len(recent)}件保持')
" 2>/dev/null) || true
    if [ -n "$_archive_result" ]; then
        log_info "📱 ntfy_inbox整理: $_archive_result → ntfy_inbox_archive.yaml"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 6.8: ntfy入力リスナー起動
# ═══════════════════════════════════════════════════════════════════════════════
NTFY_TOPIC=$(grep 'ntfy_topic:' ./config/settings.yaml 2>/dev/null | awk '{print $2}' | tr -d '"')
if [ -n "$NTFY_TOPIC" ]; then
    pkill -f "ntfy_listener.sh" 2>/dev/null || true
    [ ! -f ./queue/ntfy_inbox.yaml ] && echo "inbox:" > ./queue/ntfy_inbox.yaml
    nohup bash "$SCRIPT_DIR/scripts/ntfy_listener.sh" &>/dev/null &
    disown
    log_info "📱 ntfy入力リスナー起動 (topic: $NTFY_TOPIC)"
else
    log_info "📱 ntfy未設定のためリスナーはスキップ"
fi
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 7: 環境確認・完了メッセージ
# ═══════════════════════════════════════════════════════════════════════════════
log_info "🔍 陣容を確認中..."
echo ""
echo "  ┌──────────────────────────────────────────────────────────┐"
echo "  │  📺 Tmux陣容 (Sessions)                                  │"
echo "  └──────────────────────────────────────────────────────────┘"
tmux list-sessions | sed 's/^/     /'
echo ""
echo "  ┌──────────────────────────────────────────────────────────┐"
echo "  │  📋 布陣図 (Formation)                                   │"
echo "  └──────────────────────────────────────────────────────────┘"
echo ""
echo "     【shogunセッション】将軍の本陣"
echo "     ┌─────────────────────────────┐"
echo "     │  Pane 0: 将軍 (SHOGUN)      │  ← 総大将・プロジェクト統括"
echo "     └─────────────────────────────┘"
echo ""
echo "     【multiagentセッション】家老・足軽・軍師の陣（3x3 = 9ペイン）"
echo "     ┌─────────┬─────────┬─────────┐"
echo "     │  karo   │ashigaru3│ashigaru6│"
echo "     │  (家老) │ (足軽3) │ (足軽6) │"
echo "     ├─────────┼─────────┼─────────┤"
echo "     │ashigaru1│ashigaru4│ashigaru7│"
echo "     │ (足軽1) │ (足軽4) │ (足軽7) │"
echo "     ├─────────┼─────────┼─────────┤"
echo "     │ashigaru2│ashigaru5│ gunshi  │"
echo "     │ (足軽2) │ (足軽5) │ (軍師)  │"
echo "     └─────────┴─────────┴─────────┘"
echo ""

echo ""
echo "  ╔══════════════════════════════════════════════════════════╗"
echo "  ║  🏯 出陣準備完了！天下布武！                              ║"
echo "  ╚══════════════════════════════════════════════════════════╝"
echo ""

if [ "$SETUP_ONLY" = true ]; then
    echo "  ⚠️  セットアップのみモード: Claude Codeは未起動です"
    echo ""
    echo "  手動でClaude Codeを起動するには:"
    echo "  ┌──────────────────────────────────────────────────────────┐"
    echo "  │  # 将軍を召喚                                            │"
    echo "  │  tmux send-keys -t shogun:main \\                         │"
    echo "  │    'claude ${PERMISSION_FLAG}' Enter         │"
    echo "  │                                                          │"
    echo "  │  # 家老・足軽を一斉召喚                                  │"
    echo "  │  for p in \$(seq $PANE_BASE $((PANE_BASE+8))); do                                 │"
    echo "  │      tmux send-keys -t multiagent:agents.\$p \\            │"
    echo "  │      'claude ${PERMISSION_FLAG}' Enter       │"
    echo "  │  done                                                    │"
    echo "  └──────────────────────────────────────────────────────────┘"
    echo ""
fi

echo "  次のステップ:"
echo "  ┌──────────────────────────────────────────────────────────┐"
echo "  │  将軍の本陣にアタッチして命令を開始:                      │"
echo "  │     tmux attach-session -t shogun   (または: css)        │"
echo "  │                                                          │"
echo "  │  家老・足軽の陣を確認する:                                │"
echo "  │     tmux attach-session -t multiagent   (または: csm)    │"
echo "  │                                                          │"
echo "  │  ※ 各エージェントは指示書を読み込み済み。                 │"
echo "  │    すぐに命令を開始できます。                             │"
echo "  └──────────────────────────────────────────────────────────┘"
echo ""

# ★起動打鍵を送らなかった pane を人へ報せる (cmd_754 E-3/E-5)。
#   黙って落とさない。人が見て手を打つための出口である。
if [ -n "$SHUTSUJIN_SKIPPED_PANES" ]; then
    echo "  ╔══════════════════════════════════════════════════════════╗"
    echo "  ║  🚨 起動打鍵を送らなかった pane がござる                  ║"
    echo "  ╚══════════════════════════════════════════════════════════╝"
    echo -e "$SHUTSUJIN_SKIPPED_PANES" | sed '/^$/d' | sed 's/^/     - /'
    echo ""
    echo "  ★これらの pane は素のシェルではなかった(既に CLI が動いている等)。"
    echo "    cmd_754 の裁定により、稼働中の pane へは打鍵せぬ。"
    echo "    既に望みの CLI が動いておるならそのままでよい。差し替えるなら"
    echo "    当該 pane を人が確認し、手ずから /exit してから再度出陣せよ。"
    echo ""
fi

echo "  ════════════════════════════════════════════════════════════"
echo "   天下布武！勝利を掴め！ (Tenka Fubu! Seize victory!)"
echo "  ════════════════════════════════════════════════════════════"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 8: Windows Terminal でタブを開く（-t オプション時のみ）
# ═══════════════════════════════════════════════════════════════════════════════
if [ "$OPEN_TERMINAL" = true ]; then
    log_info "📺 Windows Terminal でタブを展開中..."

    # Windows Terminal が利用可能か確認
    if command -v wt.exe &> /dev/null; then
        wt.exe -w 0 new-tab wsl.exe -e bash -c "tmux attach-session -t shogun" \; new-tab wsl.exe -e bash -c "tmux attach-session -t multiagent"
        log_success "  └─ ターミナルタブ展開完了"
    else
        log_info "  └─ wt.exe が見つかりません。手動でアタッチしてください。"
    fi
    echo ""
fi
