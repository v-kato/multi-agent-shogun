#!/usr/bin/env bats
# test_claude_session_resume.bats — 出陣やり直し時の Claude 会話 resume (cmd_785 Phase 1・AC②③④)
#
# 撤収の直前に Claude 系 agent の会話 ID を採取し(lib/claude_session_resume.sh)、
# 起動時に `claude --resume <id>` を付ける(lib/cli_adapter.sh build_cli_command・
# shutsujin_departure.sh)。PoC: context/cmd_785_resume_poc.md
#
# ★稼働中の ~/.claude/sessions・projects は読まない・書かない(CLAUDE_CONFIG_DIR を
#   試験ごとの一時 dir へ向ける)。本番 tmux にも触れない(tmux はモック関数)。
#   出陣スクリプト本体は実行せず、関数定義だけを awk で取り出して評価する。
# ★一時 dir は bats が自動で片付ける BATS_TEST_TMPDIR のみを使い、rm -rf を書かない。
# ★「生きている pid」には試験プロセス自身($$)・その親($PPID)・pid 1 を使い、
#   実物の /proc/<pid>/stat の starttime と照合させる。子プロセス探索の試験だけは
#   自ら終わる短い sleep(comm 名を claude にした symlink)を起こし、wait で回収する
#   (signal は送らない)。復旧経路の試験の偽 claude も自ら指定の rc で終わる。
# ★経過秒の判定は現実時計に頼らない(cmd_791・cmd_794)。WSL2 では systemd-timesyncd が
#   現実時計を約32秒ごとに約3秒巻き戻す実測があり、`date +%s` の差で経過を測ると揺れた。
#   lib 自身が単調時計(/proc/uptime)で測る。値の注入は、生成した1行の `< /proc/uptime` を
#   試験側で試験用ファイルへ置き換えて行う(inject_uptime。lib に差し替えの口は無い)。
#
# 変異試験用: CSR_LIB_UNDER_TEST / CLI_ADAPTER_UNDER_TEST / SHUTSUJIN_UNDER_TEST /
#   HOOK_UNDER_TEST で検査対象の複製へ差し替えられる。
#
# テスト構成:
#   T-CSR-001〜005: 有効化(opt-in)の判定
#   T-CSR-010〜012: sessionId 形式・project dir 名・starttime
#   T-CSR-020〜028: 記録の検証(read_record)
#   T-CSR-030〜031: 子 claude pid の探索(実プロセス)
#   T-CSR-040〜046: 採取(snapshot)
#   T-CSR-050〜057: 照合(lookup)
#   T-CSR-060〜065: build_cli_command の resume 受け口
#   T-CSR-070〜071: 採取→照合→起動コマンドの通し
#   T-CSR-080〜088: shutsujin_departure.sh への組込み
#   T-CSR-090: 隔離 tmux 実機での採取(scripts/isolated_tmux.sh の create/teardown のみ)
#   T-CSR-091: 隔離 tmux 実機での起動直後失敗→新規起動1回(偽 claude)
#   T-CSR-100〜113: 起動直後失敗の復旧経路(G785-Q01。偽の claude・単調時計の注入で bash と sh。
#                   113 は現実時計の巻き戻しに左右されないこと〔cmd_794〕)
#   T-CSR-120〜129: 起動時の固定プロンプト(cmd_785 Phase 1b。opt-in の Claude 系だけ・
#                   resume/新規に1回ずつ・許可リスト・出陣の全7経路)
#   T-CSR-140〜141: SessionStart hook の毎回変わる1行(cmd_785 Phase 1b)
#   P796-01〜15: 前回スナップショットの安全な再利用(cmd_796。設計確認
#                context/cmd_796_design_review.md §8 の有限集合。英字の枝番は同じ項目の別観点)
#
# ★cmd_796: 現生存 Claude の観測(claude_resume_live_observe)・時計(_claude_resume_clock)・
#   子プロセス探索(claude_resume_child_claude_scan)は、試験の中でだけ関数を定義し直して
#   固定する(use_mock_live・use_mock_clock・use_mock_child)。lib に差し替えの口
#   (環境変数・引数)は無く、本番の出陣や pane の直前確認(`bash lib --check-previous`)
#   からは到達できない。本物の /proc 観測を使う試験(P796-05a・P796-12e)は、同じ実行
#   ユーザーの生存 Claude 全ての記録を読み取りだけで読む(稼働中の agent が居ればその
#   ~/.claude/sessions も読む。書かない)。判定は試験自身の偽 claude についてだけ行う。

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export CSR_LIB="${CSR_LIB_UNDER_TEST:-$PROJECT_ROOT/lib/claude_session_resume.sh}"
    export CLI_ADAPTER_LIB="${CLI_ADAPTER_UNDER_TEST:-$PROJECT_ROOT/lib/cli_adapter.sh}"
    export SHUTSUJIN="${SHUTSUJIN_UNDER_TEST:-$PROJECT_ROOT/shutsujin_departure.sh}"
    export HOOK="${HOOK_UNDER_TEST:-$PROJECT_ROOT/scripts/session_start_hook.sh}"
    export PY="$PROJECT_ROOT/.venv/bin/python3"
    [ -f "$CSR_LIB" ] && [ -f "$CLI_ADAPTER_LIB" ] && [ -f "$SHUTSUJIN" ] && [ -f "$HOOK" ] && [ -x "$PY" ]
}

setup() {
    unset PERMISSION_FLAG CLAUDE_RESUME_PYTHON
    W="$BATS_TEST_TMPDIR"
    export CLAUDE_CONFIG_DIR="$W/claude_config"
    mkdir -p "$CLAUDE_CONFIG_DIR/sessions" "$CLAUDE_CONFIG_DIR/projects"
    HANDLE_FILE=""
    FAKE_HOLD_DIR=""
    HELD_FIFO=""
    SNAP="$W/state/claude_session_snapshot.yaml"
    LAUNCH_CWD="$W/proj.dir_x"
    SLUG="$(printf '%s' "$LAUNCH_CWD" | sed 's/[^A-Za-z0-9]/-/g')"
    SID1="11111111-1111-4111-8111-111111111111"
    SID2="22222222-2222-4222-8222-222222222222"
    SID3="33333333-3333-4333-8333-333333333333"
    SID_DECOY="dddddddd-dddd-4ddd-8ddd-dddddddddddd"
    # opt-in 時に Claude 系の起動コマンド末尾へ付く固定の1語(cmd_785 Phase 1b)。
    # lib の定数を読まず試験側のリテラルで持つ(定数の書換えを検出するため)。
    TOK="run-session-start-procedure"

    cat > "$W/settings_on.yaml" <<'YAML'
cli:
  default: claude
  claude_session_resume: true
  agents:
    shogun: {type: claude, model: opus}
    karo: {type: claude, model: sonnet}
    gunshi: {type: codex, model: gpt-6-sol}
    ashigaru1: {type: codex, model: gpt-6-luna}
    ashigaru3: {type: claude, model: sonnet --effort xhigh}
    ashigaru4: {type: claude, model: sonnet}
YAML
    sed '/claude_session_resume/d' "$W/settings_on.yaml" > "$W/settings_absent.yaml"
    sed 's/claude_session_resume: true/claude_session_resume: false/' "$W/settings_on.yaml" > "$W/settings_off.yaml"
    # cmd_796: 前回スナップショットの再利用(別 opt-in)も真
    sed 's/  claude_session_resume: true/  claude_session_resume: true\n  claude_session_resume_previous_snapshot: true/' \
        "$W/settings_on.yaml" > "$W/settings_prev.yaml"
    load_libs "$W/settings_on.yaml"

    # 本番 tmux の代わり(出陣セッション2つと pane を返すだけ)
    MOCK_SESSIONS=""
    MOCK_ROWS=""
    MOCK_TMUX_MODE=""
    declare -gA MOCK_CHILD=()
}

teardown() {
    # 途中で落ちた時も、止めてある偽 claude を先に放して素のシェルへ戻す(exit を届けるため)
    if [ -n "${FAKE_HOLD_DIR:-}" ] && [ -d "$FAKE_HOLD_DIR" ]; then
        : > "$FAKE_HOLD_DIR/release.all"
    fi
    # 途中で落ちた時も、子を持たない親(start_held_parent)を放す
    if [ -n "${HELD_FIFO:-}" ] && [ -p "$HELD_FIFO" ]; then
        printf '\n' 1<> "$HELD_FIFO"
    fi
    if [ -n "${HANDLE_FILE:-}" ] && [ -f "$HANDLE_FILE" ]; then
        bash "$PROJECT_ROOT/scripts/isolated_tmux.sh" teardown "$HANDLE_FILE" || true
    fi
}

load_libs() {
    export CLI_ADAPTER_SETTINGS="$1"
    # shellcheck disable=SC1090
    source "$CLI_ADAPTER_LIB"
    # 複製(変異試験)を読んでも本物の venv を使う
    CLI_ADAPTER_PROJECT_ROOT="$PROJECT_ROOT"
    # shellcheck disable=SC1090
    source "$CSR_LIB"
    CLAUDE_RESUME_PROJECT_ROOT="$PROJECT_ROOT"
}

# 無いセッションへの has-session は、本物の tmux と同じ文面を stderr へ出して rc=1。
#   MOCK_TMUX_MODE: noserver=server 無し(WSL 再起動後)・broken=それ以外の失敗・
#   listfail=list-panes の失敗・空=server はあるがセッションが無い
tmux() {
    case "$1" in
        has-session)
            local t="${3#=}"
            if [[ " $MOCK_SESSIONS " == *" $t "* ]] && [ "${MOCK_TMUX_MODE:-}" != broken ]; then
                return 0
            fi
            case "${MOCK_TMUX_MODE:-}" in
                noserver) echo "error connecting to /tmp/tmux-1000/default (No such file or directory)" >&2 ;;
                broken) echo "server exited unexpectedly" >&2 ;;
                *) echo "can't find session: $t" >&2 ;;
            esac
            return 1
            ;;
        list-panes)
            [ "${MOCK_TMUX_MODE:-}" != listfail ] || return 1
            local t="${4#=}"
            printf '%b' "$MOCK_ROWS" | awk -F'\t' -v s="$t" 'index($1, s ":") == 1'
            ;;
        display-message)
            printf '%s\n' "${MOCK_PANE_PID:-}"
            ;;
        *) return 1 ;;
    esac
}

# use_real_child — use_mock_child で差し替えた子探索を、検査対象の lib の本物へ戻す
#   (G796-Q01: 探索関数は本物のまま、ps だけを試験側の関数で固定するため)
use_real_child() {
    eval "$(awk '/^claude_resume_child_claude_scan\(\) \{/,/^}/' "$CSR_LIB")"
    declare -F claude_resume_child_claude_scan >/dev/null
}

# start_held_parent <fifo> — 子を持たない本物の親を起こし、pid を HELD_PARENT へ置く。
#   read 組込みで待つので子を作らない(/proc の子一覧は空)。<fifo> へ1行書くと終わり、
#   書かれなければ 30 秒で自ら終わる(signal は送らない)。出陣の排他(FD 9)は引き継がない。
start_held_parent() {
    HELD_FIFO="$1"
    mkfifo "$HELD_FIFO"
    bash -c 'read -r -t 30 _ <> "$1"' _ "$HELD_FIFO" 9>&- &
    HELD_PARENT=$!
}

# release_held_parent — start_held_parent の親を終わらせて回収する(読み手が居なくても塞がらない)
release_held_parent() {
    printf '\n' 1<> "$HELD_FIFO"
    wait "$HELD_PARENT"
}

# 子 claude の探索の代わり。MOCK_CHILD[pane_pid]: 数字=その1つ・空=0件・MULTI・ERR
use_mock_child() {
    claude_resume_child_claude_scan() {
        local v="${MOCK_CHILD[$1]:-}"
        case "$v" in
            "") echo "NONE" ;;
            MULTI|ERR) echo "$v" ;;
            *) echo "ONE $v" ;;
        esac
    }
}

# write_record <pid> <name> <sessionId> [procStart] [bridge]
write_record() {
    local pid="$1" name="$2" sid="$3"
    local st="${4:-$(claude_resume_proc_starttime "$1")}"
    local bridge="${5:-session_01TestBridge$1}"
    printf '{"pid":%s,"sessionId":"%s","cwd":"%s","procStart":"%s","name":"%s","bridgeSessionId":"%s","status":"idle"}\n' \
        "$pid" "$sid" "$LAUNCH_CWD" "$st" "$name" "$bridge" > "$CLAUDE_CONFIG_DIR/sessions/${pid}.json"
}

write_transcript() {
    mkdir -p "$CLAUDE_CONFIG_DIR/projects/$SLUG"
    printf '{"type":"custom-title","customTitle":"x","sessionId":"%s"}\n' "$1" \
        > "$CLAUDE_CONFIG_DIR/projects/$SLUG/$1.jsonl"
}

# snap_py <python式>  (d = 読み込んだ snapshot)
snap_py() {
    "$PY" -c "import yaml,sys; d=yaml.safe_load(open(sys.argv[1])); print($1)" "$SNAP"
}

extract_fn() {
    awk "/^$1\\(\\) \\{/,/^}/" "$SHUTSUJIN"
}

# =============================================================================
# 有効化(opt-in)
# =============================================================================

@test "T-CSR-001: settings に cli.claude_session_resume が無ければ無効(OSS 既定)" {
    load_libs "$W/settings_absent.yaml"
    run claude_resume_enabled
    [ "$status" -eq 1 ]
}

@test "T-CSR-002: cli.claude_session_resume: true で有効" {
    run claude_resume_enabled
    [ "$status" -eq 0 ]
}

@test "T-CSR-003: cli.claude_session_resume: false で無効" {
    load_libs "$W/settings_off.yaml"
    run claude_resume_enabled
    [ "$status" -eq 1 ]
}

@test "T-CSR-004: cli_adapter が読めていない(設定読取関数が無い)なら無効" {
    unset -f _cli_adapter_read_yaml
    run claude_resume_enabled
    [ "$status" -eq 1 ]
}

@test "T-CSR-005: settings.yaml 自体が無くても無効で止まらない" {
    load_libs "$W/no_such_settings.yaml"
    run claude_resume_enabled
    [ "$status" -eq 1 ]
}

# =============================================================================
# 形式・名前・starttime
# =============================================================================

@test "T-CSR-010: sessionId は小文字16進の UUID 形式だけを通す" {
    # ★bats(set -e)下では `! cmd` は失敗しても試験を落とさないため、否定は関数で判定する
    assert_invalid() {
        if claude_resume_valid_session_id "$1"; then
            echo "通してはならない値が通った: [$1]"
            return 1
        fi
    }
    claude_resume_valid_session_id "$SID1"
    claude_resume_valid_session_id "$SID_DECOY"
    assert_invalid ""
    assert_invalid "poc785-a"
    assert_invalid "${SID_DECOY^^}"
    assert_invalid "${SID1} --dangerously-skip-permissions"
    assert_invalid '$(touch /tmp/x)'
    assert_invalid "../../${SID1}"
    assert_invalid "${SID1}"$'\n'"x"
    assert_invalid "${SID1:0:35}"
}

@test "T-CSR-011: project dir 名は英数字以外を '-' にする(本体の規則・PoC 実測と一致)" {
    [ "$(claude_resume_project_slug /home/kato/shogun)" = "-home-kato-shogun" ]
    [ "$(claude_resume_project_slug /tmp/poc785-cwd.r7vfwx)" = "-tmp-poc785-cwd-r7vfwx" ]
    [ "$(claude_resume_project_slug /a/b_c.d)" = "-a-b-c-d" ]
}

@test "T-CSR-012: starttime は /proc/<pid>/stat 第22欄。数字以外・不在 pid は失敗" {
    local expect
    expect=$(awk '{s=$0; sub(/.*\) /,"",s); split(s,a," "); print a[20]}' /proc/$$/stat)
    [ "$(claude_resume_proc_starttime $$)" = "$expect" ]
    run claude_resume_proc_starttime "1; echo x"
    [ "$status" -ne 0 ]
    run claude_resume_proc_starttime ""
    [ "$status" -ne 0 ]
}

# =============================================================================
# 記録の検証
# =============================================================================

@test "T-CSR-020: pid・procStart・name・sessionId が揃えば OK と sessionId・bridge を返す" {
    write_record $$ karo "$SID1"
    run claude_resume_read_record $$ karo
    [ "$status" -eq 0 ]
    [ "$output" = "OK"$'\t'"$SID1"$'\t'"session_01TestBridge$$" ]
}

@test "T-CSR-021: procStart が現プロセスと違う(pid 再利用・死んだ記録)は NG" {
    write_record $$ karo "$SID1" "999999999999"
    run claude_resume_read_record $$ karo
    [ "$status" -ne 0 ]
    [ "$output" = "NG"$'\t'"proc_start_mismatch" ]
}

@test "T-CSR-022: name が agent_id と違えば NG" {
    write_record $$ ashigaru9 "$SID1"
    run claude_resume_read_record $$ karo
    [ "$status" -ne 0 ]
    [ "$output" = "NG"$'\t'"name_mismatch" ]
}

@test "T-CSR-023: 記録ファイルが無ければ NG(no_record)" {
    run claude_resume_read_record $$ karo
    [ "$status" -ne 0 ]
    [ "$output" = "NG"$'\t'"no_record" ]
}

@test "T-CSR-024: 壊れた JSON・配列の JSON は NG(broken_record)" {
    printf '{"pid": %s, "sessionId": ' $$ > "$CLAUDE_CONFIG_DIR/sessions/$$.json"
    run claude_resume_read_record $$ karo
    [ "$output" = "NG"$'\t'"broken_record" ]
    printf '[1,2]\n' > "$CLAUDE_CONFIG_DIR/sessions/$$.json"
    run claude_resume_read_record $$ karo
    [ "$output" = "NG"$'\t'"broken_record" ]
}

@test "T-CSR-025: 記録内の pid 欄がファイル名の pid と違えば NG" {
    write_record $$ karo "$SID1"
    sed -i "s/\"pid\":$$,/\"pid\":$(( $$ + 1 )),/" "$CLAUDE_CONFIG_DIR/sessions/$$.json"
    run claude_resume_read_record $$ karo
    [ "$output" = "NG"$'\t'"pid_mismatch" ]
}

@test "T-CSR-026: sessionId が UUID 形式でなければ NG(シェルへ渡さない)" {
    write_record $$ karo '$(touch /tmp/cmd785_pwn)'
    run claude_resume_read_record $$ karo
    [ "$output" = "NG"$'\t'"invalid_session_id" ]
}

@test "T-CSR-027: bridgeSessionId が不正・無しでも会話 ID は採れる(bridge は空)" {
    write_record $$ karo "$SID1" "" "not a bridge"
    run claude_resume_read_record $$ karo
    [ "$status" -eq 0 ]
    [ "$output" = "OK"$'\t'"$SID1"$'\t' ]
}

@test "T-CSR-028: 生きていない pid は NG(no_process)" {
    local dead="" p
    for p in $(seq 4194303 -1 4193000); do
        [ -e "/proc/$p" ] || { dead=$p; break; }
    done
    [ -n "$dead" ]
    write_record "$dead" karo "$SID1" "12345"
    run claude_resume_read_record "$dead" karo
    [ "$output" = "NG"$'\t'"no_process" ]
}

# =============================================================================
# 子 claude pid の探索(実プロセス。自ら終わる sleep を wait で回収する)
# =============================================================================

@test "T-CSR-030: 直接の子で comm=claude が1つならその pid" {
    mkdir -p "$W/bin"
    ln -s "$(command -v sleep)" "$W/bin/claude"
    local me=$BASHPID
    "$W/bin/claude" 1 &
    local child=$!
    local got
    got=$(claude_resume_child_claude_pid "$me")
    wait "$child"
    [ "$got" = "$child" ]
}

@test "T-CSR-031: comm=claude の子が2つなら空(どちらも選ばない)" {
    mkdir -p "$W/bin"
    ln -s "$(command -v sleep)" "$W/bin/claude"
    local me=$BASHPID
    "$W/bin/claude" 1 &
    local c1=$!
    "$W/bin/claude" 1 &
    local c2=$!
    local got
    got=$(claude_resume_child_claude_pid "$me")
    wait "$c1" "$c2"
    [ -z "$got" ]
}

# =============================================================================
# 採取(snapshot)
# =============================================================================

setup_panes() {
    use_mock_child
    MOCK_SESSIONS="shogun multiagent"
    MOCK_ROWS="shogun:0.0\t9100\tshogun\tclaude\n"
    MOCK_ROWS+="multiagent:0.0\t9200\tkaro\tclaude\n"
    MOCK_ROWS+="multiagent:0.1\t9201\tashigaru1\tcodex\n"
    MOCK_ROWS+="multiagent:0.3\t9203\tashigaru3\tclaude\n"
    MOCK_ROWS+="multiagent:0.4\t9204\tashigaru4\tclaude\n"
    MOCK_ROWS+="multiagent:0.8\t9208\tgunshi\tcodex\n"
    MOCK_CHILD[9100]=$$        # 生存・記録正
    MOCK_CHILD[9200]=$PPID     # 生存・記録正
    MOCK_CHILD[9201]=$PPID     # codex pane(子が居ても対象外)
    MOCK_CHILD[9203]=1         # 生存・記録は死んだプロセスのもの(procStart 不一致)
    # 9204: claude 子プロセス無し
    write_record $$ shogun "$SID1"
    write_record $PPID karo "$SID2"
    write_record 1 ashigaru3 "$SID3" "999999999999"
}

@test "T-CSR-040: 検証を通った Claude 系 agent だけを記録し、理由付きで他を skipped に残す" {
    setup_panes
    run claude_resume_snapshot "$SNAP" tok-1
    [ "$status" -eq 0 ]
    [ "$(snap_py "d['run_token']")" = "tok-1" ]
    [ "$(snap_py "d['sessions_found']")" = "True" ]
    [ "$(snap_py "sorted(d['agents'])")" = "['karo', 'shogun']" ]
    [ "$(snap_py "d['agents']['shogun']['session_id']")" = "$SID1" ]
    [ "$(snap_py "d['agents']['karo']['session_id']")" = "$SID2" ]
    [ "$(snap_py "d['agents']['karo']['bridge_session_id']")" = "session_01TestBridge$PPID" ]
    [ "$(snap_py "d['agents']['karo']['pane']")" = "multiagent:0.0" ]
    [ "$(snap_py "sorted((s['agent_id'], s['reason']) for s in d['skipped'])")" = "[('ashigaru3', 'proc_start_mismatch'), ('ashigaru4', 'claude_pid_not_found')]" ]
}

@test "T-CSR-041: Codex 系 pane は記録にも skipped にも載らない" {
    setup_panes
    write_record $PPID ashigaru1 "$SID3"   # 記録が在っても pane が codex なら見ない
    claude_resume_snapshot "$SNAP" tok-1
    run snap_py "'ashigaru1' in d['agents'] or 'gunshi' in d['agents'] or any(s['agent_id'] in ('ashigaru1','gunshi') for s in d['skipped'])"
    [ "$output" = "False" ]
}

@test "T-CSR-042: 偽の sessions/*.json(同名・別 pid)は pid で引かないので使われない" {
    setup_panes
    write_record 424242 karo "$SID_DECOY" "999"   # 名前は karo だが pane の子ではない
    mv "$CLAUDE_CONFIG_DIR/sessions/$PPID.json" "$W/karo_record_moved.json"   # karo の本当の子には記録が無い
    claude_resume_snapshot "$SNAP" tok-1
    run grep -c "$SID_DECOY" "$SNAP"
    [ "$output" = "0" ]
    [ "$(snap_py "'karo' in d['agents']")" = "False" ]
    [ "$(snap_py "[s['reason'] for s in d['skipped'] if s['agent_id']=='karo']")" = "['no_record']" ]
}

# cmd_796 で区別: claude_resume_snapshot は「渡された記録ファイル」(出陣では今回の採取=
#   *.current.yaml)へ書く関数で、ここで試すのはその書き手の仕様。前回分を current へ持ち
#   越さない。正本(前回の実採取記録)を残すか置き換えるかは claude_resume_commit_canonical の
#   保存方針で決まり、全対象が不在なら正本は消えない(P796-01)。旧仕様の「正本を空で上書き」
#   はもう無い。
@test "T-CSR-043: 出陣セッションが無ければ、渡された記録ファイル(今回の current)へ空の記録を書く(前回分を current へ持ち越さない)" {
    setup_panes
    claude_resume_snapshot "$SNAP" tok-old
    MOCK_SESSIONS=""
    run claude_resume_snapshot "$SNAP" tok-new
    [ "$status" -eq 0 ]
    [ "$(snap_py "(d['run_token'], d['sessions_found'], d['agents'], d['skipped'])")" = "('tok-new', False, {}, [])" ]
    # 「セッションが無い」は tmux が明言した時だけ(observation の材料。前回分の扱いは P796-01)
    [ "$(snap_py "d['schema_version']")" = "2" ]
}

@test "T-CSR-044: 一時ファイル+rename で書き、一時ファイルを残さない・保存先 dir は作る" {
    setup_panes
    [ ! -d "$W/state" ]
    claude_resume_snapshot "$SNAP" tok-1
    [ -f "$SNAP" ]
    run bash -c "ls -A '$W/state' | grep -c '^\.claude_session_snapshot\.'"
    [ "$output" = "0" ]
    head -1 "$SNAP" | grep -q '機械生成(cmd_785)'
}

@test "T-CSR-045: 書けない時は1を返し、既存の記録を壊さない" {
    setup_panes
    claude_resume_snapshot "$SNAP" tok-keep
    chmod 555 "$W/state"
    run claude_resume_snapshot "$SNAP" tok-new
    chmod 755 "$W/state"
    [ "$status" -eq 1 ]
    [ "$(snap_py "d['run_token']")" = "tok-keep" ]
}

@test "T-CSR-046: 不正な @agent_id の claude pane は invalid_agent_id で skip" {
    use_mock_child
    MOCK_SESSIONS="multiagent"
    MOCK_ROWS="multiagent:0.5\t9300\tevil;id\tclaude\n"
    MOCK_CHILD[9300]=$$
    claude_resume_snapshot "$SNAP" tok-1
    [ "$(snap_py "(d['agents'], [s['reason'] for s in d['skipped']])")" = "({}, ['invalid_agent_id'])" ]
}

# =============================================================================
# 照合(lookup)
# =============================================================================

write_snapshot() {
    mkdir -p "$W/state"
    cat > "$SNAP" <<EOF
captured_at: "2026-09-29T22:00:00+09:00"
run_token: "$1"
sessions_found: true
agents:
  karo:
    session_id: "$2"
    bridge_session_id: session_01X
    pid: 1
    pane: multiagent:0.0
skipped: []
EOF
}

@test "T-CSR-050: 同じ出陣の記録で転写が実在すれば sessionId を返す" {
    write_snapshot tok-1 "$SID1"
    write_transcript "$SID1"
    run claude_resume_lookup "$SNAP" tok-1 karo "$LAUNCH_CWD"
    [ "$status" -eq 0 ]
    [ "$output" = "$SID1" ]
}

@test "T-CSR-051: 転写が無ければ返さない(存在しない ID は claude を即終了させる)" {
    write_snapshot tok-1 "$SID1"
    run claude_resume_lookup "$SNAP" tok-1 karo "$LAUNCH_CWD"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "T-CSR-052: run_token が違う(前回以前の出陣の記録)なら返さない" {
    write_snapshot tok-old "$SID1"
    write_transcript "$SID1"
    run claude_resume_lookup "$SNAP" tok-new karo "$LAUNCH_CWD"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "T-CSR-053: 記録に無い agent は返さない" {
    write_snapshot tok-1 "$SID1"
    write_transcript "$SID1"
    run claude_resume_lookup "$SNAP" tok-1 ashigaru3 "$LAUNCH_CWD"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "T-CSR-054: 記録の session_id が UUID 形式でなければ返さず、評価もしない" {
    local marker="$W/pwned"
    write_snapshot tok-1 "\$(touch $marker)"
    mkdir -p "$CLAUDE_CONFIG_DIR/projects/$SLUG"
    run claude_resume_lookup "$SNAP" tok-1 karo "$LAUNCH_CWD"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [ ! -e "$marker" ]
    # 名前(--resume <name> は picker を開く)は、同名の転写ファイルが在っても返さない
    write_snapshot tok-1 "poc785-a"
    printf '{}\n' > "$CLAUDE_CONFIG_DIR/projects/$SLUG/poc785-a.jsonl"
    run claude_resume_lookup "$SNAP" tok-1 karo "$LAUNCH_CWD"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "T-CSR-055: 転写が別 cwd の project dir にしか無ければ返さない" {
    write_snapshot tok-1 "$SID1"
    mkdir -p "$CLAUDE_CONFIG_DIR/projects/-other-dir"
    printf '{}\n' > "$CLAUDE_CONFIG_DIR/projects/-other-dir/$SID1.jsonl"
    run claude_resume_lookup "$SNAP" tok-1 karo "$LAUNCH_CWD"
    [ "$status" -eq 1 ]
}

@test "T-CSR-056: 記録が壊れている・無いなら返さない" {
    mkdir -p "$W/state"
    printf 'agents: [unclosed\n' > "$SNAP"
    run claude_resume_lookup "$SNAP" tok-1 karo "$LAUNCH_CWD"
    [ "$status" -eq 1 ]
    run claude_resume_lookup "$W/state/none.yaml" tok-1 karo "$LAUNCH_CWD"
    [ "$status" -eq 1 ]
}

@test "T-CSR-057: 引数が欠けたら返さない(run_token 空=採取していない出陣)" {
    write_snapshot tok-1 "$SID1"
    write_transcript "$SID1"
    run claude_resume_lookup "$SNAP" "" karo "$LAUNCH_CWD"
    [ "$status" -eq 1 ]
}

# =============================================================================
# build_cli_command の resume 受け口
# =============================================================================

@test "T-CSR-060: claude agent に正しい ID を渡すと claude の直後に --resume <id> が付く" {
    run build_cli_command ashigaru3 "$SID1"
    [ "$status" -eq 0 ]
    [ "$output" = "claude --resume $SID1 --model sonnet --effort xhigh --name ashigaru3 --dangerously-skip-permissions $TOK" ]
}

@test "T-CSR-061: ID 空は従来と完全に同じ(opt-in 無効時の不変)" {
    local plain
    plain=$(build_cli_command karo)
    [ "$(build_cli_command karo "")" = "$plain" ]
    [ "$plain" = "claude --model sonnet --name karo --dangerously-skip-permissions $TOK" ]
    # opt-in 無効(未記載・false)なら固定の1語も付かず、従来と完全に同じ
    local s
    for s in absent off; do
        load_libs "$W/settings_${s}.yaml"
        [ "$(build_cli_command karo "")" = "claude --model sonnet --name karo --dangerously-skip-permissions" ]
    done
}

@test "T-CSR-062: 不正な ID は付けずに従来の新規起動(警告は stderr)" {
    local plain out err
    plain=$(build_cli_command karo)
    for bad in 'x; touch /tmp/cmd785_pwn' "${SID_DECOY^^}" "poc785-a" "${SID1} --continue"; do
        out=$(build_cli_command karo "$bad" 2>/dev/null)
        [ "$out" = "$plain" ]
        err=$(build_cli_command karo "$bad" 2>&1 >/dev/null)
        [[ "$err" == *"形式が不正"* ]]
    done
}

@test "T-CSR-063: Codex 系 agent には ID を渡しても何も変わらない" {
    [ "$(build_cli_command gunshi "$SID1")" = "$(build_cli_command gunshi)" ]
    [ "$(build_cli_command ashigaru1 "$SID1")" = "$(build_cli_command ashigaru1)" ]
    [[ "$(build_cli_command gunshi "$SID1")" != *"--resume"* ]]
}

@test "T-CSR-064: permission flag の上書き(--permission-mode 等)と共存する" {
    PERMISSION_FLAG="--permission-mode plan" run build_cli_command shogun "$SID2"
    [ "$output" = "claude --resume $SID2 --model opus --name shogun --permission-mode plan $TOK" ]
}

@test "T-CSR-065: thinking: false の前置きと共存する" {
    printf '%s\n' "cli:" "  agents:" "    karo: {type: claude, model: sonnet, thinking: false}" > "$W/settings_think.yaml"
    load_libs "$W/settings_think.yaml"
    [ "$(build_cli_command karo "$SID1")" = "MAX_THINKING_TOKENS=0 claude --resume $SID1 --model sonnet --name karo --dangerously-skip-permissions" ]
}

# =============================================================================
# 通し: 採取 → 照合 → 起動コマンド
# =============================================================================

@test "T-CSR-070: 採取できて転写がある agent だけ --resume、他は従来コマンド" {
    setup_panes
    write_transcript "$SID1"          # shogun の転写は在る
    # karo の転写は無い(SID2)→ 従来起動
    claude_resume_snapshot "$SNAP" tok-1
    local id
    id=$(claude_resume_lookup "$SNAP" tok-1 shogun "$LAUNCH_CWD") || id=""
    [ "$(build_cli_command shogun "$id")" = "claude --resume $SID1 --model opus --name shogun --dangerously-skip-permissions $TOK" ]
    id=$(claude_resume_lookup "$SNAP" tok-1 karo "$LAUNCH_CWD") || id=""
    [ "$(build_cli_command karo "$id")" = "claude --model sonnet --name karo --dangerously-skip-permissions $TOK" ]
    id=$(claude_resume_lookup "$SNAP" tok-1 ashigaru3 "$LAUNCH_CWD") || id=""
    [ "$(build_cli_command ashigaru3 "$id")" = "claude --model sonnet --effort xhigh --name ashigaru3 --dangerously-skip-permissions $TOK" ]
}

@test "T-CSR-071: 照合の失敗は set -e 下の代入でも出陣を止めない" {
    run bash -c "set -e; source '$CLI_ADAPTER_LIB'; CLI_ADAPTER_PROJECT_ROOT='$PROJECT_ROOT'; source '$CSR_LIB'; CLAUDE_RESUME_PROJECT_ROOT='$PROJECT_ROOT'; \
        id=\$(claude_resume_lookup '$W/none.yaml' tok karo /x) || id=''; echo \"reached:[\$id]\""
    [ "$status" -eq 0 ]
    [ "$output" = "reached:[]" ]
}

# =============================================================================
# shutsujin_departure.sh への組込み
# =============================================================================

# 出陣スクリプトの補助関数だけを読み込む(log_info は記録用の代替)
load_shutsujin_fns() {
    LOGS=()
    log_info() { LOGS+=("$*"); }
    local fn
    for fn in shutsujin_claude_resume_snapshot shutsujin_resume_id shutsujin_log_resume shutsujin_launch_cmd \
        shutsujin_wrap_resume_cmd shutsujin_claude_targets shutsujin_resume_lock shutsujin_resume_unlock \
        shutsujin_resume_settle shutsujin_resume_finalize; do
        eval "$(extract_fn "$fn")"
        declare -F "$fn" >/dev/null || { echo "出陣スクリプトに $fn が無い" >&2; return 1; }
    done
    CLAUDE_RESUME_SNAPSHOT_FILE="$SNAP"
    CLAUDE_RESUME_CURRENT_FILE="$W/state/claude_session_snapshot.current.yaml"
    CLAUDE_RESUME_PLAN_FILE="$W/state/claude_session_plan.yaml"
    CLAUDE_RESUME_LOCK_FILE="$W/state/shutsujin.lock"
    CLAUDE_RESUME_LOADED=true
    CLEAN_MODE=false
    CLAUDE_RESUME_RUN_TOKEN=""
    CLAUDE_RESUME_LOCK_HELD=false
    declare -gA CLAUDE_RESUME_PLAN_SID=()
    declare -gA CLAUDE_RESUME_PLAN_SOURCE=()
    CLAUDE_RESUME_PREV_REMAINING=0
    CLAUDE_RESUME_UNCONFIRMED=()
}

@test "T-CSR-080: 採取は STEP 1 の最初の kill-session より前に一度だけ呼ばれる" {
    local call kill
    call=$(grep -n '^shutsujin_claude_resume_snapshot || true$' "$SHUTSUJIN" | cut -d: -f1)
    kill=$(grep -n '^tmux kill-session' "$SHUTSUJIN" | head -1 | cut -d: -f1)
    [ "$(printf '%s\n' "$call" | wc -l)" -eq 1 ]
    [ -n "$call" ] && [ -n "$kill" ]
    [ "$call" -lt "$kill" ]
}

@test "T-CSR-081: 起動部は決戦の陣の非 claude 分岐を除き全て shutsujin_launch_cmd へ resume ID を渡す" {
    local with_resume total_launch bare single ln
    with_resume=$(grep -cE '\$\(shutsujin_launch_cmd "[^"]+" "\$_[a-z]+_resume"\)' "$SHUTSUJIN")
    total_launch=$(grep -cE '\$\(shutsujin_launch_cmd ' "$SHUTSUJIN")
    # 将軍2(thinking 上書きの組み直しを含む)・家老・平時の足軽・軍師
    [ "$with_resume" -eq 5 ]
    [ "$total_launch" -eq 5 ]
    # build_cli_command を直接呼ぶのは shutsujin_launch_cmd の中の2つと、決戦の陣の非 claude 分岐の1つだけ
    bare=$(grep -nE '\$\(build_cli_command "' "$SHUTSUJIN")
    [ "$(printf '%s\n' "$bare" | wc -l)" -eq 3 ]
    [ "$(printf '%s\n' "$bare" | grep -cF 'build_cli_command "$1"')" -eq 2 ]
    single=$(grep -nF '_ashi_cmd=$(build_cli_command "ashigaru${i}")' "$SHUTSUJIN" | cut -d: -f1)
    [ "$(printf '%s\n' "$single" | wc -l)" -eq 1 ]
    ln=$(( single - 1 ))
    sed -n "${ln}p" "$SHUTSUJIN" | grep -qE '^[[:space:]]*else[[:space:]]*$'
    sed -n "$(( single - 15 )),$(( single - 1 ))p" "$SHUTSUJIN" | grep -qF 'if [ "$_ashi_cli_type" = "claude" ]; then'
    # 復旧経路の無い resume(build_cli_command へ resume ID を直に渡す起動)は残っていない
    ! grep -qE '\$\(build_cli_command "[^"]+" "\$_[a-z]+_resume"\)' "$SHUTSUJIN"
}

@test "T-CSR-082: 決戦の陣の手組み claude コマンドも、resume 時は復旧経路付き・無い時は従来どおり" {
    load_shutsujin_fns
    local fresh_line='_ashi_cmd="claude --model opus --name ashigaru${i} --effort max $PERMISSION_FLAG"'
    # resume ID を包む if 節の直前が、従来の手組みコマンドの代入と、それへ固定の1語を
    # 付ける2行(cmd_785 Phase 1b。中身は T-CSR-125 で評価する)であること
    grep -B3 -F 'if [ -n "$_ashi_resume" ]; then' "$SHUTSUJIN" | head -1 | grep -qF "$fresh_line"
    grep -B2 -F 'if [ -n "$_ashi_resume" ]; then' "$SHUTSUJIN" | head -1 | grep -qF '_ashi_prompt=$(get_startup_prompt_arg "ashigaru${i}")'
    grep -B1 -F 'if [ -n "$_ashi_resume" ]; then' "$SHUTSUJIN" | head -1 | grep -qF '_ashi_cmd="${_ashi_cmd}${_ashi_prompt:+ $_ashi_prompt}"'
    local block
    block=$(awk 'index($0, "if [ -n \"$_ashi_resume\" ]; then"){f=1} f{print} f && $0 ~ /^[[:space:]]*fi[[:space:]]*$/{exit}' "$SHUTSUJIN")
    [ -n "$block" ]
    local i=2 PERMISSION_FLAG="--dangerously-skip-permissions" _ashi_cmd _ashi_resume
    local plain="claude --model opus --name ashigaru2 --effort max --dangerously-skip-permissions"
    _ashi_cmd="$plain"; _ashi_resume="$SID1"
    eval "$block"
    [ "$_ashi_cmd" = "$(claude_resume_launch_cmd "$SID1" "claude --resume $SID1 --model opus --name ashigaru2 --effort max --dangerously-skip-permissions" "$plain")" ]
    [[ "$_ashi_cmd" == *"_csr_rc"* ]]
    _ashi_cmd="$plain"; _ashi_resume=""
    eval "$block"
    [ "$_ashi_cmd" = "$plain" ]
}

@test "T-CSR-083: 有効かつ --clean でなければ採取し run_token を立てる" {
    load_shutsujin_fns
    setup_panes
    shutsujin_claude_resume_snapshot
    [ -n "$CLAUDE_RESUME_RUN_TOKEN" ]
    [ "$(snap_py "d['run_token']")" = "$CLAUDE_RESUME_RUN_TOKEN" ]
}

@test "T-CSR-084: --clean 時は採取せず run_token も立てない" {
    load_shutsujin_fns
    setup_panes
    CLEAN_MODE=true
    shutsujin_claude_resume_snapshot
    [ -z "$CLAUDE_RESUME_RUN_TOKEN" ]
    [ ! -e "$SNAP" ]
    [[ "${LOGS[*]}" == *"--clean"* ]]
}

@test "T-CSR-085: 無効(opt-in なし)・ライブラリ未読込では何もしない" {
    load_shutsujin_fns
    setup_panes
    load_libs "$W/settings_absent.yaml"
    use_mock_child
    shutsujin_claude_resume_snapshot
    [ -z "$CLAUDE_RESUME_RUN_TOKEN" ]
    [ ! -e "$SNAP" ]
    load_libs "$W/settings_on.yaml"
    CLAUDE_RESUME_LOADED=false
    shutsujin_claude_resume_snapshot
    [ -z "$CLAUDE_RESUME_RUN_TOKEN" ]
    [ ! -e "$SNAP" ]
}

@test "T-CSR-086: 採取に失敗しても 0 を返し(set -e で出陣を止めない)、run_token は立てない" {
    load_shutsujin_fns
    setup_panes
    mkdir -p "$W/state"
    chmod 555 "$W/state"
    run shutsujin_claude_resume_snapshot
    local rc=$status
    shutsujin_claude_resume_snapshot
    chmod 755 "$W/state"
    [ "$rc" -eq 0 ]
    [ -z "$CLAUDE_RESUME_RUN_TOKEN" ]
    [[ "${LOGS[*]}" == *"採取に失敗"* ]]
    [ ! -e "$SNAP" ]
}

# cmd_796: shutsujin_resume_id は、採取の後に一度だけ作る起動計画(同一 run の照合結果を
#   含む)から読む。照合そのもの(run_token 完全一致・転写の実在)は T-CSR-050〜057。
@test "T-CSR-087: shutsujin_resume_id は run_token 無し・claude 以外なら空、他はこの出陣の照合結果(起動計画)" {
    load_shutsujin_fns
    setup_panes
    write_transcript "$SID2"        # karo だけ転写がある(shogun は無い)
    mkdir -p "$LAUNCH_CWD"
    cd "$LAUNCH_CWD"
    [ -z "$(shutsujin_resume_id karo claude)" ]
    shutsujin_claude_resume_snapshot
    [ -n "$CLAUDE_RESUME_RUN_TOKEN" ]
    [ -z "$(shutsujin_resume_id karo codex)" ]
    [ "$(shutsujin_resume_id karo claude)" = "$SID2" ]
    [ -z "$(shutsujin_resume_id shogun claude)" ]
    [ -z "$(shutsujin_resume_id ashigaru3 claude)" ]
    [ -z "$(shutsujin_resume_id "" claude)" ]
    # 計画上の由来は同一 run の照合(current)
    [ "${CLAUDE_RESUME_PLAN_SOURCE[karo]}" = "current" ]
}

@test "T-CSR-088: resume する agent だけ記録を残し、空なら何も出さず 0 を返す" {
    load_shutsujin_fns
    shutsujin_log_resume "家老" ""
    [ "${#LOGS[@]}" -eq 0 ]
    shutsujin_log_resume "家老" "$SID1"
    [ "${LOGS[0]}" = "  └─ 家老: 前回の会話を再開(--resume $SID1。起動直後に失敗すれば1回だけ新規起動へ切替)" ]
}

# =============================================================================
# 起動直後失敗の復旧経路(G785-Q01)
#   偽の claude・date を PATH の先頭に置いて、生成した1行コマンドを bash と
#   sh(dash)で実行する。signal は送らない(偽 claude は自ら指定 rc で終わる)。
#   経過秒は単調時計 /proc/uptime の整数部の差で測る(cmd_794)。値を注入する試験は、
#   生成した文字列の `< /proc/uptime` 2か所を試験側で順に試験用ファイルへ置き換える
#   (inject_uptime)。lib には読取先を変える口(環境変数・変数・関数)を一切作らない
#   ので、本番の起動経路からは到達できない(cmd_784 の教訓)。
# =============================================================================

# make_fakes — 偽の claude と date を $FAKEBIN に作る
#   claude: 呼ばれるたび "MAX_THINKING_TOKENS<TAB>argv" を $FAKE_LOG へ1行足し、
#     --resume 付きなら FAKE_RESUME_SLEEP 秒眠って FAKE_RESUME_RC で、無しなら
#     FAKE_FRESH_SLEEP 秒眠って FAKE_FRESH_RC で終わる。6回目以降は即 rc=0
#     (変異でループしても試験が終わるように。回数は $FAKE_LOG の行数で数える)。
#     FAKE_HOLD_DIR があれば、眠る前に $FAKE_HOLD_DIR/release.<n>(n=何回目か)か
#     release.all が置かれるまで生きている(上限60秒。隔離 tmux 実機の条件同期用)。
#   date: 現実時計の代わり。`+%s` の呼出しを $FAKE_DATE_LOG へ1行ずつ記録し、
#     FAKE_DATE_SEQ(ファイル)があればその先頭行を返して消費する(巻き戻しの注入)。
#     それ以外は本物の date。生成コマンドは date を呼ばないので、記録は常に空のはず。
make_fakes() {
    FAKEBIN="$W/fakebin"
    mkdir -p "$FAKEBIN"
    export FAKE_LOG="$W/fake_claude.log"
    : > "$FAKE_LOG"
    export FAKE_DATE_LOG="$W/fake_date.log"
    : > "$FAKE_DATE_LOG"
    export FAKE_RESUME_SLEEP=0 FAKE_RESUME_RC=0 FAKE_FRESH_SLEEP=0 FAKE_FRESH_RC=0
    unset FAKE_DATE_SEQ
    cat > "$FAKEBIN/claude" <<'SH'
#!/bin/bash
n=$(( $(wc -l < "$FAKE_LOG") + 1 ))
printf '%s\t%s\n' "${MAX_THINKING_TOKENS:-}" "$*" >> "$FAKE_LOG"
[ "$n" -le 5 ] || exit 0
if [ -n "${FAKE_HOLD_DIR:-}" ]; then
    for _ in $(seq 1 1200); do
        [ -e "$FAKE_HOLD_DIR/release.$n" ] || [ -e "$FAKE_HOLD_DIR/release.all" ] && break
        sleep 0.05
    done
fi
case " $* " in
    *" --resume "*) sleep "${FAKE_RESUME_SLEEP:-0}"; exit "${FAKE_RESUME_RC:-0}" ;;
    *) sleep "${FAKE_FRESH_SLEEP:-0}"; exit "${FAKE_FRESH_RC:-0}" ;;
esac
SH
    cat > "$FAKEBIN/date" <<SH
#!/bin/bash
if [ "\$#" -eq 1 ] && [ "\$1" = "+%s" ]; then
    echo "+%s" >> "\$FAKE_DATE_LOG"
    if [ -n "\${FAKE_DATE_SEQ:-}" ] && [ -s "\$FAKE_DATE_SEQ" ]; then
        v=\$(head -n1 "\$FAKE_DATE_SEQ")
        sed -i 1d "\$FAKE_DATE_SEQ"
        printf '%s\n' "\$v"
        exit 0
    fi
fi
exec $(command -v date) "\$@"
SH
    chmod +x "$FAKEBIN/claude" "$FAKEBIN/date"
    FRESH_KARO="$(build_cli_command karo)"
    RESUME_KARO="$(build_cli_command karo "$SID1")"
}

# set_dates <秒...> — 偽 date(現実時計)が順に返す値
set_dates() {
    export FAKE_DATE_SEQ="$W/date_seq"
    printf '%s\n' "$@" > "$FAKE_DATE_SEQ"
}

# set_uptimes <起動前の内容> <終了後の内容> — inject_uptime が読ませる2つのファイル。
#   内容は /proc/uptime と同じ "秒.百分の一 アイドル秒" の1行。NONE はファイルを作らない
#   (=読めない)。EMPTY は空のファイル。それ以外の文字列はそのまま1行で書く。
set_uptimes() {
    local i=0 v
    # 呼ぶたび別の置場(run の subshell からも一意。NONE の回に前回のファイルが残らない)
    UPTIME_DIR=$(mktemp -d "$W/uptime.XXXXXX")
    for v in "$1" "$2"; do
        case "$v" in
            NONE) ;;
            EMPTY) : > "$UPTIME_DIR/$i" ;;
            *) printf '%s\n' "$v" > "$UPTIME_DIR/$i" ;;
        esac
        i=$((i + 1))
    done
}

# inject_uptime <1行コマンド> — 生成コマンドの `< /proc/uptime` が正確に2か所
#   (resume 起動の前と後)であることを確かめ、先頭から順に set_uptimes の 0・1 へ
#   置き換えた文字列を出す。形が違えば(date へ戻す変異など)失敗する。
inject_uptime() {
    local cmd="$1" before after
    [ "$(printf '%s' "$cmd" | grep -o -F '< /proc/uptime' | wc -l)" -eq 2 ] || { echo "uptime の読取りが2か所でない" >&2; return 1; }
    before="${cmd%%_csr_rc=\$?*}"
    after="${cmd#*_csr_rc=\$?}"
    [ "$(printf '%s' "$before" | grep -o -F '< /proc/uptime' | wc -l)" -eq 1 ] || { echo "resume 起動の前の読取りが1か所でない" >&2; return 1; }
    [ "$(printf '%s' "$after" | grep -o -F '< /proc/uptime' | wc -l)" -eq 1 ] || { echo "resume 起動の後の読取りが1か所でない" >&2; return 1; }
    cmd="${cmd/"< /proc/uptime"/"< $UPTIME_DIR/0"}"
    cmd="${cmd/"< /proc/uptime"/"< $UPTIME_DIR/1"}"
    printf '%s\n' "$cmd"
}

# run_launch <shell> <1行コマンド> — 偽の claude/date を先に引く PATH で、最大20秒
run_launch() {
    PATH="$FAKEBIN:$PATH" timeout 20 "$1" -c "$2"
}

# run_launch_up <shell> <1行コマンド> <起動前の uptime> <終了後の uptime> — 単調時計を注入して実行
run_launch_up() {
    set_uptimes "$3" "$4"
    local injected
    injected=$(inject_uptime "$2") || return 99
    run_launch "$1" "$injected"
}

fake_date_calls() { wc -l < "$FAKE_DATE_LOG"; }
fake_calls() { wc -l < "$FAKE_LOG"; }
fake_argv() { sed -n "${1}p" "$FAKE_LOG" | cut -f2-; }

@test "T-CSR-100: 生成は1行・上限は定数30秒・経過は単調時計(/proc/uptime)で測り date を使わない・then 節に同じ従来引数の新規起動が1つだけ・履歴展開の ! を含まない" {
    make_fakes
    [ "$CLAUDE_RESUME_FALLBACK_WINDOW_SEC" = "30" ]
    local cmd
    cmd=$(claude_resume_launch_cmd "$SID1" "$RESUME_KARO" "$FRESH_KARO")
    [ "$(printf '%s\n' "$cmd" | wc -l)" -eq 1 ]
    [[ "$cmd" != *'!'* ]]
    # resume 起動の直前に単調時計を読む(読む前に空にする=読めなければ前回の値が残らない)
    [[ "$cmd" == "_csr_u=; read -r _csr_u _csr_x 2>/dev/null < /proc/uptime; _csr_t0=\${_csr_u%%.*}; ${RESUME_KARO}; _csr_rc=\$?; "* ]]
    # 終了直後にもう一度読み、両方が整数で t1 >= t0 の時だけ経過が入る(それ以外は空=測れない)
    [[ "$cmd" == *'; _csr_rc=$?; _csr_u=; read -r _csr_u _csr_x 2>/dev/null < /proc/uptime; _csr_t1=${_csr_u%%.*}; _csr_dt=; [ "$_csr_t0" -ge 0 ] 2>/dev/null && [ "$_csr_t1" -ge "$_csr_t0" ] 2>/dev/null && _csr_dt=$(( _csr_t1 - _csr_t0 )); if '* ]]
    inject_uptime "$cmd" > /dev/null
    # 現実時計(date)は使わない
    [ "$(printf '%s\n' "$cmd" | grep -c -w date)" -eq 0 ]
    [[ "$cmd" == *'[ "$_csr_rc" -ge 1 ] && [ "$_csr_rc" -le 127 ] && [ -n "$_csr_dt" ] && [ "$_csr_dt" -lt 30 ]; then '* ]]
    # 測れなかった時の elif 節は警告(stderr)を出すだけで何も起動しない
    [[ "$cmd" == *"; ${FRESH_KARO}; elif "'[ "$_csr_rc" -ge 1 ] && [ "$_csr_rc" -le 127 ] && [ -z "$_csr_dt" ]; then echo "[shutsujin] claude --resume が rc=$_csr_rc で終了したが、経過秒を単調時計 (/proc/uptime) で測れないため新規起動へ切り替えない" >&2; fi' ]]
    # 新規起動(--resume 無し)の出現は then 節の1つだけ
    [ "$(printf '%s' "$cmd" | grep -o -F "$FRESH_KARO" | wc -l)" -eq 1 ]
    [ "$(printf '%s' "$cmd" | grep -o -F -- "--resume $SID1" | wc -l)" -eq 1 ]
    # 環境変数では上限を変えられない
    CLAUDE_RESUME_FALLBACK_WINDOW_SEC=999 bash -c "source '$CSR_LIB'; [ \"\$CLAUDE_RESUME_FALLBACK_WINDOW_SEC\" = 30 ]"
}

@test "T-CSR-101: (a) resume 起動が起動直後に rc=1 → 同じ従来引数の新規起動が1回だけ走る(bash・sh。本物の /proc/uptime)" {
    make_fakes
    local cmd sh
    cmd=$(claude_resume_launch_cmd "$SID1" "$RESUME_KARO" "$FRESH_KARO")
    for sh in bash sh; do
        : > "$FAKE_LOG"
        FAKE_RESUME_RC=1 FAKE_FRESH_RC=0 run run_launch "$sh" "$cmd"
        [ "$status" -eq 0 ]
        [ "$(fake_calls)" -eq 2 ]
        [ "$(fake_argv 1)" = "${RESUME_KARO#claude }" ]
        [ "$(fake_argv 2)" = "${FRESH_KARO#claude }" ]
        [[ "$output" == *"claude --resume が起動直後に終了 (rc=1, "*"従来の新規起動へ切り替える (1回のみ)"* ]]
        [[ "$output" != *"測れない"* ]]
    done
    [ "$(fake_date_calls)" -eq 0 ]
}

@test "T-CSR-102: (b) 上限秒数に達した後の非0終了は新規起動しない(境界: 0・29秒は倒す・30秒/31秒は倒さない。単調時計の整数部の差・bash・sh)" {
    make_fakes
    local cmd sh
    cmd=$(claude_resume_launch_cmd "$SID1" "$RESUME_KARO" "$FRESH_KARO")
    export FAKE_RESUME_RC=1
    for sh in bash sh; do
        : > "$FAKE_LOG"; run run_launch_up "$sh" "$cmd" "1000.00 50.00" "1000.50 50.10"
        [ "$(fake_calls)" -eq 2 ] || { echo "$sh 0秒"; return 1; }
        [[ "$output" == *"(rc=1, 0秒)"* ]]
        : > "$FAKE_LOG"; run run_launch_up "$sh" "$cmd" "1000.00 50.00" "1029.99 51.00"
        [ "$(fake_calls)" -eq 2 ] || { echo "$sh 29秒"; return 1; }
        [[ "$output" == *"(rc=1, 29秒)"* ]]
        : > "$FAKE_LOG"; run run_launch_up "$sh" "$cmd" "1000.99 50.00" "1030.00 51.00"
        [ "$(fake_calls)" -eq 1 ] || { echo "$sh 30秒"; return 1; }
        [[ "$output" != *"新規起動へ切り替える"* ]]
        [[ "$output" != *"測れない"* ]]
        : > "$FAKE_LOG"; run run_launch_up "$sh" "$cmd" "1000.00 50.00" "1031.00 51.00"
        [ "$(fake_calls)" -eq 1 ] || { echo "$sh 31秒"; return 1; }
        : > "$FAKE_LOG"; run run_launch_up "$sh" "$cmd" "1000.00 50.00" "5000.00 51.00"
        [ "$(fake_calls)" -eq 1 ] || { echo "$sh 4000秒"; return 1; }
    done
    [ "$(fake_date_calls)" -eq 0 ]
}

@test "T-CSR-103: (b) 実際に流れた時間でも、上限を越えて動いた後の非0終了は倒さない(上限を2秒に下げ、実 sleep と本物の /proc/uptime で確認)" {
    # 値を注入せず、生成コマンドが本物の /proc/uptime を読む。実 sleep 3 秒なら整数部の差は
    # 必ず3以上(単調時計は戻らず、floor(a+d)-floor(a) >= floor(d))で、上限2秒を越える。
    make_fakes
    local cmd
    CLAUDE_RESUME_FALLBACK_WINDOW_SEC=2
    cmd=$(claude_resume_launch_cmd "$SID1" "$RESUME_KARO" "$FRESH_KARO")
    [[ "$cmd" == *'-lt 2 ]'* ]]
    FAKE_RESUME_RC=1 FAKE_RESUME_SLEEP=3 run run_launch bash "$cmd"
    [ "$(fake_calls)" -eq 1 ]
    [[ "$output" != *"測れない"* ]]
    : > "$FAKE_LOG"
    FAKE_RESUME_RC=1 FAKE_RESUME_SLEEP=0 run run_launch bash "$cmd"
    [ "$(fake_calls)" -eq 2 ]
    [ "$(fake_date_calls)" -eq 0 ]
}

@test "T-CSR-104: (c) resume 起動が rc=0 で終われば(起動直後の /exit 等)新規起動しない" {
    make_fakes
    local cmd sh
    cmd=$(claude_resume_launch_cmd "$SID1" "$RESUME_KARO" "$FRESH_KARO")
    for sh in bash sh; do
        : > "$FAKE_LOG"
        FAKE_RESUME_RC=0 run run_launch "$sh" "$cmd"
        [ "$status" -eq 0 ]
        [ "$(fake_calls)" -eq 1 ]
    done
}

@test "T-CSR-105: signal による終了・停止(rc>=128)は倒さず、rc 1〜127 は倒す" {
    make_fakes
    local cmd rc
    cmd=$(claude_resume_launch_cmd "$SID1" "$RESUME_KARO" "$FRESH_KARO")
    for rc in 128 129 130 137 143 148 255; do
        : > "$FAKE_LOG"
        FAKE_RESUME_RC=$rc run run_launch bash "$cmd"
        [ "$(fake_calls)" -eq 1 ] || { echo "rc=$rc で倒れた"; false; }
    done
    for rc in 1 2 126 127; do
        : > "$FAKE_LOG"
        FAKE_RESUME_RC=$rc run run_launch bash "$cmd"
        [ "$(fake_calls)" -eq 2 ] || { echo "rc=$rc で倒れなかった"; false; }
    done
}

@test "T-CSR-106: (d) resume でない起動は包まず従来のコマンドそのもの(失敗しても新規起動を足さない)" {
    make_fakes
    [ "$(claude_resume_launch_cmd "" "$RESUME_KARO" "$FRESH_KARO")" = "$FRESH_KARO" ]
    load_shutsujin_fns
    [ "$(shutsujin_launch_cmd karo "")" = "$FRESH_KARO" ]
    [ "$(shutsujin_launch_cmd gunshi "")" = "$(build_cli_command gunshi)" ]
    FAKE_FRESH_RC=1 run run_launch bash "$(shutsujin_launch_cmd karo "")"
    [ "$status" -eq 1 ]
    [ "$(fake_calls)" -eq 1 ]
    [ "$(fake_argv 1)" = "${FRESH_KARO#claude }" ]
}

@test "T-CSR-107: (e) 新規起動も起動直後に失敗する時、claude は計2回だけでループしない" {
    make_fakes
    local cmd sh
    cmd=$(claude_resume_launch_cmd "$SID1" "$RESUME_KARO" "$FRESH_KARO")
    for sh in bash sh; do
        : > "$FAKE_LOG"
        FAKE_RESUME_RC=1 FAKE_FRESH_RC=1 run run_launch "$sh" "$cmd"
        [ "$status" -eq 1 ]
        [ "$(fake_calls)" -eq 2 ]
        [[ "$(fake_argv 2)" != *--resume* ]]
    done
}

@test "T-CSR-108: 単調時計を読めない・空・非数値・逆行(t1<t0)なら経過を測れないとして倒さず(fail-closed)、date へも倒さず、理由を stderr に残す(bash・sh)" {
    make_fakes
    local cmd sh pair
    local warn="[shutsujin] claude --resume が rc=1 で終了したが、経過秒を単調時計 (/proc/uptime) で測れないため新規起動へ切り替えない"
    cmd=$(claude_resume_launch_cmd "$SID1" "$RESUME_KARO" "$FRESH_KARO")
    export FAKE_RESUME_RC=1
    for sh in bash sh; do
        for pair in "NONE|NONE" "NONE|1001.00 5.00" "1000.00 5.00|NONE" "EMPTY|1001.00 5.00" "1000.00 5.00|EMPTY" \
                    "abc def|1001.00 5.00" "1000.00 5.00|x1001.00 5.00" "1000.00 5.00|990.00 5.00"; do
            # 現実時計は「1秒」を示す(date へ倒す作りなら、ここで倒れてしまう)
            set_dates 1000 1001
            : > "$FAKE_LOG"
            run_launch_up "$sh" "$cmd" "${pair%%|*}" "${pair#*|}" > "$W/out" 2> "$W/err" || true
            [ "$(fake_calls)" -eq 1 ] || { echo "$sh [$pair]: 呼出し $(fake_calls) 回"; return 1; }
            # stderr は警告1行だけ(読取り失敗・整数比較のシェルのエラーを漏らさない)
            [ "$(cat "$W/err")" = "$warn" ] || { echo "$sh [$pair]: err=[$(cat "$W/err")]"; return 1; }
            [ ! -s "$W/out" ] || { echo "$sh [$pair]: out=[$(cat "$W/out")]"; return 1; }
        done
        # 対話シェルに前回の値が残っていても、読む前に空にするので使われない
        : > "$FAKE_LOG"
        set_uptimes NONE NONE
        run_launch "$sh" "_csr_u='1000.00 5.00'; _csr_t0=1000; _csr_t1=1001; _csr_dt=1; $(inject_uptime "$cmd")" > "$W/out" 2> "$W/err" || true
        [ "$(fake_calls)" -eq 1 ] || { echo "$sh 残り値: 呼出し $(fake_calls) 回"; return 1; }
        [ "$(cat "$W/err")" = "$warn" ]
        # rc 0・rc>=128 は測れなくても倒さず、警告も出さない(判定に経過を使わないため)
        local rc
        for rc in 0 130; do
            : > "$FAKE_LOG"
            FAKE_RESUME_RC=$rc run_launch_up "$sh" "$cmd" NONE NONE > "$W/out" 2> "$W/err" || true
            [ "$(fake_calls)" -eq 1 ] || { echo "$sh rc=$rc"; return 1; }
            [ ! -s "$W/err" ] || { echo "$sh rc=$rc: err=[$(cat "$W/err")]"; return 1; }
        done
    done
    [ "$(fake_date_calls)" -eq 0 ]
}

@test "T-CSR-109: thinking: false の前置き(MAX_THINKING_TOKENS=0)は resume 起動・新規起動の両方に効く" {
    printf '%s\n' "cli:" "  agents:" "    karo: {type: claude, model: sonnet, thinking: false}" > "$W/settings_think.yaml"
    load_libs "$W/settings_think.yaml"
    make_fakes
    [[ "$FRESH_KARO" == "MAX_THINKING_TOKENS=0 claude "* ]]
    FAKE_RESUME_RC=1 run run_launch bash "$(claude_resume_launch_cmd "$SID1" "$RESUME_KARO" "$FRESH_KARO")"
    [ "$(fake_calls)" -eq 2 ]
    [ "$(cut -f1 "$FAKE_LOG" | tr '\n' ' ')" = "0 0 " ]
}

@test "T-CSR-110: 包める形でない入力は復旧経路を付けず従来の新規起動だけを返す(理由は stderr)" {
    make_fakes
    local out err bad
    # [理由] resume_cmd fresh_cmd sid
    check_plain() {
        out=$(claude_resume_launch_cmd "$3" "$1" "$2" 2>/dev/null)
        err=$(claude_resume_launch_cmd "$3" "$1" "$2" 2>&1 >/dev/null)
        [ "$out" = "$2" ] || { echo "out=[$out]"; return 1; }
        [[ "$err" == *"理由: $4"* ]] || { echo "err=[$err]"; return 1; }
    }
    check_plain "${RESUME_KARO/$SID1/${SID_DECOY^^}}" "$FRESH_KARO" "${SID_DECOY^^}" invalid_session_id
    check_plain "$RESUME_KARO" "$FRESH_KARO" 'x; touch /tmp/cmd785_pwn' invalid_session_id
    check_plain "$RESUME_KARO" "" "$SID1" fresh_cmd_empty
    check_plain "$RESUME_KARO" "$RESUME_KARO" "$SID1" fresh_cmd_has_resume
    # 引数が食い違う・resume が無い・別 ID・2つある
    check_plain "claude --resume $SID1 --model opus --name karo --dangerously-skip-permissions" "$FRESH_KARO" "$SID1" resume_cmd_mismatch
    check_plain "$FRESH_KARO" "$FRESH_KARO" "$SID1" resume_cmd_mismatch
    check_plain "$(build_cli_command karo "$SID2")" "$FRESH_KARO" "$SID1" resume_cmd_mismatch
    check_plain "claude --resume $SID1 --resume $SID1 --model sonnet --name karo --dangerously-skip-permissions" "$FRESH_KARO" "$SID1" resume_cmd_mismatch
    # 構造を変え得る文字
    for bad in ' # c' ' ; touch x' ' && x' ' | x' ' > x' ' < x' ' $(x)' ' `x`' " 'x'" ' "x"' ' x!' ' \x' $'\nx'; do
        check_plain "claude --resume $SID1 --model sonnet${bad}" "claude --model sonnet${bad}" "$SID1" unsafe_char
    done
    # 上限が正の整数でなければ組まない
    CLAUDE_RESUME_FALLBACK_WINDOW_SEC="30; x"
    check_plain "$RESUME_KARO" "$FRESH_KARO" "$SID1" invalid_window
    CLAUDE_RESUME_FALLBACK_WINDOW_SEC=0
    check_plain "$RESUME_KARO" "$FRESH_KARO" "$SID1" invalid_window
}

@test "T-CSR-111: shutsujin_launch_cmd は resume 時だけ包み、ライブラリ未読込・claude 以外では従来コマンド" {
    make_fakes
    load_shutsujin_fns
    [ "$(shutsujin_launch_cmd karo "$SID1")" = "$(claude_resume_launch_cmd "$SID1" "$RESUME_KARO" "$FRESH_KARO")" ]
    [[ "$(shutsujin_launch_cmd karo "$SID1")" == *"_csr_rc"* ]]
    # Codex 系: build_cli_command が --resume を付けないので包まない(実際は shutsujin_resume_id が空を返す)
    [ "$(shutsujin_launch_cmd gunshi "$SID1" 2>/dev/null)" = "$(build_cli_command gunshi)" ]
    # ライブラリ未読込(関数が無い)なら ID があっても従来コマンド
    unset -f claude_resume_launch_cmd
    [ "$(shutsujin_launch_cmd karo "$SID1")" = "$FRESH_KARO" ]
}

@test "T-CSR-112: 出陣と同じ set -e 下でも、包む処理・包めない入力で止まらない" {
    run bash -c "set -e; source '$CLI_ADAPTER_LIB'; CLI_ADAPTER_PROJECT_ROOT='$PROJECT_ROOT'; source '$CSR_LIB'; \
        a=\$(claude_resume_launch_cmd '$SID1' 'claude --resume $SID1 --model x' 'claude --model x'); \
        b=\$(claude_resume_launch_cmd 'bad' 'claude --resume bad --model x' 'claude --model x' 2>/dev/null); \
        echo \"reached:\${#a}:[\$b]\""
    [ "$status" -eq 0 ]
    [[ "$output" == "reached:"*":[claude --model x]" ]]
}

@test "T-CSR-113: 現実時計を3秒巻き戻しても判定は変わらない(判定は単調時計だけで決まり date を呼ばない。bash・sh)" {
    make_fakes
    local cmd sh
    cmd=$(claude_resume_launch_cmd "$SID1" "$RESUME_KARO" "$FRESH_KARO")
    export FAKE_RESUME_RC=1
    for sh in bash sh; do
        # 起動失敗(実際は1秒)の最中に現実時計が3秒戻った。date の差なら経過 -2 で倒さず
        # pane が空のまま残った(cmd_791 の実測)。単調時計は1秒進むので倒す
        set_dates 1000 998
        : > "$FAKE_LOG"; run run_launch_up "$sh" "$cmd" "500.10 9.00" "501.20 9.00"
        [ "$(fake_calls)" -eq 2 ] || { echo "$sh 巻き戻し中の起動失敗: 呼出し $(fake_calls) 回"; return 1; }
        [[ "$output" == *"(rc=1, 1秒)。従来の新規起動へ切り替える (1回のみ)"* ]]
        # 31秒動いてから失敗し、その間に現実時計が3秒戻った。date の差なら28秒と測られ
        # 余計な新規起動が足された。単調時計では31秒なので倒さない
        set_dates 1000 1028
        : > "$FAKE_LOG"; run run_launch_up "$sh" "$cmd" "500.10 9.00" "531.10 9.00"
        [ "$(fake_calls)" -eq 1 ] || { echo "$sh 巻き戻しを挟む31秒: 呼出し $(fake_calls) 回"; return 1; }
        [[ "$output" != *"切り替え"* ]]
    done
    # 現実時計は一度も読まれていない
    [ "$(fake_date_calls)" -eq 0 ]
}

# =============================================================================
# 起動時の固定プロンプト(cmd_785 Phase 1b)
#   opt-in(cli.claude_session_resume: true)の Claude 系の起動コマンド末尾へ固定の
#   1語を付け、起動と同時に転写を作る。resume・新規の両方に同じ形で1回ずつ入り、
#   claude_resume_launch_cmd の照合と危険文字検査を変えずに通ること。
# =============================================================================

# claude 2.1.285 の `claude --help` の Commands 欄にある名前(別名を含む)
CLAUDE_SUBCOMMANDS="agents attach auth auto-mode doctor gateway import install logs mcp plugin plugins project respawn rm setup-token stop kill ultrareview update upgrade"
# claude 2.1.285 で可変長の値(<...>)を取るオプション。プロンプトの直前に来ると
# プロンプトまで値として飲み込む(context/cmd_785_phase1b_experiment.md §6-4)
CLAUDE_VARIADIC_OPTS="--add-dir --allowedTools --allowed-tools --betas --disallowedTools --disallowed-tools --file --mcp-config --tools"

@test "T-CSR-120: 固定の1語は定数(環境変数で変わらない)・許可リストを通る・claude のサブコマンド名と一致しない" {
    [ "$CLAUDE_STARTUP_TOKEN" = "$TOK" ]
    [[ "$CLAUDE_STARTUP_TOKEN" =~ $_CLAUDE_STARTUP_TOKEN_RE ]]
    local c
    for c in $CLAUDE_SUBCOMMANDS; do
        [ "$TOK" != "$c" ]
        # 許可リストはサブコマンドと同じ形(1〜2語)を通さない
        ! [[ "$c" =~ $_CLAUDE_STARTUP_TOKEN_RE ]] || { echo "許可リストが $c を通した"; false; }
    done
    # 環境変数で差し替えても、読み込んだ時点の定数に戻る
    CLAUDE_STARTUP_TOKEN='x; touch /tmp/cmd785_pwn' _CLAUDE_STARTUP_TOKEN_RE='.*' \
        bash -c "source '$CLI_ADAPTER_LIB'; [ \"\$CLAUDE_STARTUP_TOKEN\" = '$TOK' ] && [ \"\$_CLAUDE_STARTUP_TOKEN_RE\" = '^[a-z0-9]+(-[a-z0-9]+){2,}\$' ]"
}

@test "T-CSR-121: 許可リストに合わない定数は付けず従来の起動(resume・新規とも)・理由は stderr" {
    local plain="claude --model sonnet --name karo --dangerously-skip-permissions"
    local resume="claude --resume $SID1 --model sonnet --name karo --dangerously-skip-permissions"
    local bad out err
    for bad in '' 'run session start' "'run-session-start'" '"run-session-start"' \
        'a-b-c;x' 'a-b-$(x)' 'a-b-`x`' 'a-b-${x}' 'a-b-*' 'a-b-?' 'a-[b]-c' '~a-b-c' 'a-b-c!' \
        'a-b-c#x' 'a-b-c&x' 'a-b-c|x' 'a-b-c>x' 'a-b-c<x' 'a-b-c\x' $'a-b-c\nx' $'a-b-c\tx' \
        'Run-Session-Start' 'a--b-c' '-a-b-c' 'a-b-c-' 'a_b_c' 'a.b.c' 'é-b-c' 'ａ-b-c' \
        'rm' 'update' 'auto-mode' 'setup-token' 'run-session'; do
        CLAUDE_STARTUP_TOKEN="$bad"
        out=$(build_cli_command karo 2>/dev/null)
        [ "$out" = "$plain" ] || { echo "bad=[$bad] out=[$out]"; return 1; }
        out=$(build_cli_command karo "$SID1" 2>/dev/null)
        [ "$out" = "$resume" ] || { echo "bad=[$bad] resume=[$out]"; return 1; }
        err=$(build_cli_command karo 2>&1 >/dev/null)
        [[ "$err" == *"起動時の固定プロンプトが許可リストに合わないため付けない"* ]] || { echo "bad=[$bad] err=[$err]"; return 1; }
    done
    # 許可リストを通る別の語なら、その語がそのまま付く(検査が定数の比較ではないこと)
    CLAUDE_STARTUP_TOKEN="start-the-procedure-2"
    [ "$(build_cli_command karo)" = "$plain start-the-procedure-2" ]
}

@test "T-CSR-122: 付くのは opt-in 真の Claude 系だけ(Codex・他 CLI・opt-in 無効には付かない)。/clear 後の文面は不変" {
    [ "$(get_claude_startup_token karo)" = "$TOK" ]
    [ "$(get_startup_prompt_arg karo)" = "$TOK" ]
    [ "$(get_startup_prompt_arg ashigaru3)" = "$TOK" ]
    # Codex 系: 固定の1語は付かず、従来の Codex 初期プロンプトのまま
    [ -z "$(get_claude_startup_token gunshi)" ]
    [ -z "$(get_claude_startup_token ashigaru1)" ]
    [[ "$(build_cli_command gunshi)" != *"$TOK"* ]]
    [[ "$(build_cli_command ashigaru1 "$SID1")" != *"$TOK"* ]]
    [[ "$(build_cli_command gunshi)" == "codex "*"'Session Start — "* ]]
    # inbox_watcher.sh が /clear 後に打鍵する文面の出所(get_startup_prompt)は Claude で空のまま
    [ -z "$(get_startup_prompt karo)" ]
    # Claude 以外の CLI
    cat > "$W/settings_other.yaml" <<'YAML'
cli:
  default: claude
  claude_session_resume: true
  agents:
    ashigaru5: {type: copilot}
    ashigaru6: {type: kimi, model: k2.5}
    ashigaru7: {type: opencode, model: sonnet}
YAML
    load_libs "$W/settings_other.yaml"
    local a
    for a in ashigaru5 ashigaru6 ashigaru7; do
        [ -z "$(get_claude_startup_token "$a")" ]
        [[ "$(build_cli_command "$a")" != *"$TOK"* ]] || { echo "$a に付いた"; false; }
    done
    # opt-in 無効(未記載・false)
    local s
    for s in absent off; do
        load_libs "$W/settings_${s}.yaml"
        [ -z "$(get_claude_startup_token karo)" ]
        [ -z "$(get_startup_prompt_arg karo)" ]
        [[ "$(build_cli_command karo)" != *"$TOK"* ]]
        [[ "$(build_cli_command ashigaru3 "$SID1")" != *"$TOK"* ]]
    done
}

@test "T-CSR-123: cli_adapter 側の opt-in 判定は claude_resume_enabled と全ての値で一致する" {
    local v a b
    for v in true True TRUE yes on 1 '"true"' false False no off 0 '"no"' tru 2 null '""' '[]'; do
        printf '%s\n' "cli:" "  default: claude" "  claude_session_resume: $v" "  agents:" "    karo: {type: claude, model: sonnet}" \
            > "$W/settings_v.yaml"
        load_libs "$W/settings_v.yaml"
        a=0; claude_resume_enabled || a=1
        b=0; _cli_adapter_claude_session_resume_enabled || b=1
        [ "$a" = "$b" ] || { echo "v=[$v] resume=$a adapter=$b"; return 1; }
        if [ "$a" = 0 ]; then
            [ "$(get_claude_startup_token karo)" = "$TOK" ] || { echo "v=[$v]"; return 1; }
        else
            [ -z "$(get_claude_startup_token karo)" ] || { echo "v=[$v]"; return 1; }
        fi
    done
    # 真と偽の両方を実際に通っていること(判定が片方に張り付いていない)
    load_libs "$W/settings_on.yaml"
    _cli_adapter_claude_session_resume_enabled
    load_libs "$W/settings_off.yaml"
    ! _cli_adapter_claude_session_resume_enabled
}

# 出陣の STEP 6(将軍〜軍師の起動コマンド組立てと打鍵)だけを取り出す
extract_launch_block() {
    awk 'index($0, "# 将軍: CLI Adapter経由でコマンド構築"){f=1} f{print} f && index($0, "軍師（${_gunshi_display}）、召喚完了"){exit}' "$SHUTSUJIN"
}

# run_launch_block — 取り出した STEP 6 を評価し、pane ごとに打鍵される起動コマンドを
#   LAUNCH[pane] に集める。tmux・打鍵・待機は代替(本番 tmux に触れない)。
#   resume ID は MOCK_RESUME[agent](claude の時だけ返す)。
#   使う変数: KESSEN_MODE・SHOGUN_NO_THINKING・PERMISSION_FLAG
run_launch_block() {
    declare -gA LAUNCH=()
    local block
    block=$(extract_launch_block)
    [ -n "$block" ] || return 1
    tmux() { return 0; }
    sleep() { :; }
    opencode_startup_delay() { :; }
    log_success() { :; }
    log_war() { :; }
    shutsujin_send_launch() { [ "$3" = Enter ] || LAUNCH["$1"]="$3"; return 0; }
    shutsujin_resume_id() { [ "${2:-}" = claude ] && printf '%s\n' "${MOCK_RESUME[$1]:-}"; return 0; }
    CLI_ADAPTER_LOADED=true
    PANE_BASE=0
    _ASHIGARU_COUNT=2
    eval "$block" 2> "$W/launch_err"
}

# check_claude_launch <経路名> <1行コマンド> <resume ID(空=新規)> <thinking 前置き 0/"">
#   偽 claude で実行し(resume は rc=1 で倒させる)、argv を確かめる。
check_claude_launch() {
    local route="$1" line="$2" sid="$3" think="$4" a1 a2
    : > "$FAKE_LOG"
    FAKE_RESUME_RC=1 FAKE_FRESH_RC=0 run_launch bash "$line" >/dev/null 2>&1 || true
    if [ -n "$sid" ]; then
        [[ "$line" == *"_csr_rc"* ]] || { echo "$route: 照合を通らず包まれていない [$line]"; return 1; }
        [ "$(fake_calls)" -eq 2 ] || { echo "$route: 呼出し $(fake_calls) 回"; return 1; }
        a1=$(fake_argv 1); a2=$(fake_argv 2)
        [ "$a1" = "--resume $sid $a2" ] || { echo "$route: resume=[$a1] fresh=[$a2]"; return 1; }
    else
        [[ "$line" != *"_csr_"* ]] || { echo "$route: resume でないのに包まれた"; return 1; }
        [ "$(fake_calls)" -eq 1 ] || { echo "$route: 呼出し $(fake_calls) 回"; return 1; }
        a2=$(fake_argv 1)
        [[ "$a2" != *--resume* ]] || { echo "$route: [$a2]"; return 1; }
    fi
    # 新規側(倒した先を含む)の argv の末尾が固定の1語で、1回だけ。直前は真偽値フラグ
    [[ "$a2" == *" --dangerously-skip-permissions $TOK" ]] || { echo "$route: fresh=[$a2]"; return 1; }
    [ "$(printf '%s\n' "$a2" | grep -o -- "$TOK" | wc -l)" -eq 1 ] || { echo "$route: 語が複数"; return 1; }
    [ "$(cut -f1 "$FAKE_LOG" | sort -u | tr -d '\n')" = "$think" ] || { echo "$route: thinking=[$(cut -f1 "$FAKE_LOG" | tr '\n' ' ')]"; return 1; }
}

@test "T-CSR-124: 出陣の全7経路(将軍・将軍thinking上書き・家老・平時足軽・決戦足軽claude・決戦足軽非claude・軍師)の argv が照合を通り、固定の1語は Claude 系の resume・新規に1回ずつ" {
    cat > "$W/settings_launch.yaml" <<'YAML'
cli:
  default: claude
  claude_session_resume: true
  agents:
    shogun: {type: claude, model: opus}
    karo: {type: claude, model: sonnet}
    gunshi: {type: claude, model: opus}
    ashigaru1: {type: codex, model: gpt-6-luna}
    ashigaru2: {type: claude, model: sonnet --effort xhigh}
YAML
    load_shutsujin_fns
    make_fakes
    PERMISSION_FLAG="--dangerously-skip-permissions"
    declare -gA MOCK_RESUME=()
    local kessen nothink mode think n=0
    for kessen in false true; do
        for nothink in false true; do
            for mode in resume fresh; do
                cp "$W/settings_launch.yaml" "$W/settings_run.yaml"
                load_libs "$W/settings_run.yaml"
                KESSEN_MODE=$kessen SHOGUN_NO_THINKING=$nothink
                MOCK_RESUME=()
                if [ "$mode" = resume ]; then
                    MOCK_RESUME=([shogun]="$SID1" [karo]="$SID2" [ashigaru2]="$SID3" [gunshi]="$SID_DECOY" [ashigaru1]="$SID1")
                fi
                run_launch_block
                ! grep -q '理由:\|許可リスト' "$W/launch_err" || { cat "$W/launch_err"; return 1; }
                [ "${#LAUNCH[@]}" -eq 5 ]
                think=""; [ "$nothink" = true ] && think=0
                check_claude_launch "将軍(kessen=$kessen,nothink=$nothink,$mode)" "${LAUNCH[shogun:main]}" "${MOCK_RESUME[shogun]:-}" "$think"
                check_claude_launch "家老($mode)" "${LAUNCH[multiagent:agents.0]}" "${MOCK_RESUME[karo]:-}" ""
                check_claude_launch "足軽2(kessen=$kessen,$mode)" "${LAUNCH[multiagent:agents.2]}" "${MOCK_RESUME[ashigaru2]:-}" ""
                check_claude_launch "軍師($mode)" "${LAUNCH[multiagent:agents.3]}" "${MOCK_RESUME[gunshi]:-}" ""
                if [ "$kessen" = true ]; then
                    : > "$FAKE_LOG"
                    FAKE_RESUME_RC=1 run_launch bash "${LAUNCH[multiagent:agents.2]}" >/dev/null 2>&1 || true
                    [[ "$(fake_argv 1)" == *"--model opus --name ashigaru2 --effort max --dangerously-skip-permissions $TOK" ]]
                fi
                # 非 Claude(Codex): 固定の1語も resume も付かず、build_cli_command そのもの
                [ "${LAUNCH[multiagent:agents.1]}" = "$(build_cli_command ashigaru1)" ]
                [[ "${LAUNCH[multiagent:agents.1]}" != *"$TOK"* ]]
                n=$((n + 1))
            done
        done
    done
    [ "$n" -eq 8 ]
    # opt-in 無効なら、どの経路にも付かない(resume ID も返らない前提)
    sed '/claude_session_resume/d' "$W/settings_launch.yaml" > "$W/settings_run.yaml"
    load_libs "$W/settings_run.yaml"
    MOCK_RESUME=()
    for kessen in false true; do
        KESSEN_MODE=$kessen SHOGUN_NO_THINKING=false
        run_launch_block
        local pane
        for pane in "${!LAUNCH[@]}"; do
            [[ "${LAUNCH[$pane]}" != *"$TOK"* ]] || { echo "$pane: ${LAUNCH[$pane]}"; return 1; }
        done
    done
}

@test "T-CSR-125: 決戦の陣の手組み起動は、opt-in 時だけ従来コマンドの末尾に1語を足してから resume 側を組む" {
    load_shutsujin_fns
    local block
    block=$(awk 'index($0, "_ashi_resume=$(shutsujin_resume_id \"ashigaru${i}\""){f=1} f{print} f && $0 ~ /^[[:space:]]*fi[[:space:]]*$/{exit}' "$SHUTSUJIN")
    # 最初に現れるのは決戦の陣(opus・effort max の手組み)の分
    [[ "$block" == *'_ashi_cmd="claude --model opus --name ashigaru${i} --effort max $PERMISSION_FLAG"'* ]]
    local i=2 PERMISSION_FLAG="--dangerously-skip-permissions" _ashi_cli_type=claude _ashi_cmd _ashi_resume _ashi_prompt
    local plain="claude --model opus --name ashigaru2 --effort max --dangerously-skip-permissions"
    declare -gA MOCK_RESUME=([ashigaru2]="$SID1")
    shutsujin_resume_id() { printf '%s\n' "${MOCK_RESUME[$1]:-}"; }
    eval "$block"
    [ "$_ashi_cmd" = "$(claude_resume_launch_cmd "$SID1" "claude --resume $SID1 --model opus --name ashigaru2 --effort max --dangerously-skip-permissions $TOK" "$plain $TOK")" ]
    [[ "$_ashi_cmd" == *"_csr_rc"* ]]
    [ "$(printf '%s' "$_ashi_cmd" | grep -o -- "$TOK" | wc -l)" -eq 2 ]
    MOCK_RESUME=()
    eval "$block"
    [ "$_ashi_cmd" = "$plain $TOK" ]
    # opt-in 無効: 従来の手組みコマンドのまま
    load_libs "$W/settings_off.yaml"
    MOCK_RESUME=([ashigaru2]="$SID1")
    eval "$block"
    [[ "$_ashi_cmd" != *"$TOK"* ]]
    MOCK_RESUME=()
    eval "$block"
    [ "$_ashi_cmd" = "$plain" ]
}

@test "T-CSR-126: 固定の1語は role・task・環境変数に左右されず、シェル経由でも1つの引数としてそのまま届く(bash・sh)" {
    make_fakes
    local a
    for a in shogun karo ashigaru3 ashigaru4; do
        [ "$(TOK=x HOME=/nonexistent TMUX_PANE=%99 get_claude_startup_token "$a")" = "$TOK" ]
    done
    # 引数を1つずつ記録する偽 claude
    cat > "$FAKEBIN/claude" <<'SH'
#!/bin/bash
printf '%s\n' "$#" "${@: -1}" > "$FAKE_LOG"
SH
    chmod +x "$FAKEBIN/claude"
    mkdir -p "$W/globdir" && cd "$W/globdir"
    : > "run-session-start-procedure-x" ; : > "a.txt"
    local sh line
    for sh in bash sh; do
        for line in "$(build_cli_command karo)" "$(build_cli_command karo "$SID1")"; do
            : > "$FAKE_LOG"
            run_launch "$sh" "$line"
            [ "$(sed -n 2p "$FAKE_LOG")" = "$TOK" ]
        done
        [ "$(sed -n 1p "$FAKE_LOG")" -eq 8 ]
    done
}

@test "T-CSR-127: 固定の1語の直前は真偽値フラグで、起動コマンドに可変長オプションが無い(既定・permission 上書き・決戦)" {
    local a words prev o
    for a in shogun karo ashigaru3 ashigaru4; do
        for PERMISSION_FLAG in "" "--dangerously-skip-permissions" "--permission-mode plan"; do
            read -ra words <<< "$(build_cli_command "$a" "$SID1")"
            [ "${words[-1]}" = "$TOK" ]
            prev="${words[-2]}"
            if [ "$PERMISSION_FLAG" = "--permission-mode plan" ]; then
                # 値を1つだけ取るオプションの値(可変長ではない)
                [ "${words[-3]}" = "--permission-mode" ] && [ "$prev" = plan ]
            else
                [ "$prev" = "--dangerously-skip-permissions" ]
            fi
            for o in $CLAUDE_VARIADIC_OPTS; do
                [[ " ${words[*]} " != *" $o "* ]] || { echo "$a: $o"; return 1; }
            done
        done
    done
    unset PERMISSION_FLAG
    # 決戦の陣の手組み起動(T-CSR-124 の評価結果と同じ形)も直前は真偽値フラグ
    grep -qF '_ashi_cmd="claude --model opus --name ashigaru${i} --effort max $PERMISSION_FLAG"' "$SHUTSUJIN"
}

@test "T-CSR-128: 固定の1語付きでも起動直後の復旧は従来どおり(29/30秒・rc 0/1/127/128/255・新規側失敗で計2回)" {
    make_fakes
    [[ "$FRESH_KARO" == *" $TOK" ]]
    [[ "$RESUME_KARO" == "claude --resume $SID1 "*" $TOK" ]]
    local cmd rc
    cmd=$(claude_resume_launch_cmd "$SID1" "$RESUME_KARO" "$FRESH_KARO" 2>"$W/err")
    [ ! -s "$W/err" ]
    [[ "$cmd" == *"_csr_rc"* ]]
    export FAKE_RESUME_RC=1
    : > "$FAKE_LOG"; run run_launch_up bash "$cmd" "1000.00 5.00" "1029.00 5.00"
    [ "$(fake_calls)" -eq 2 ]
    [ "$(fake_argv 1)" = "--resume $SID1 $(fake_argv 2)" ]
    [[ "$(fake_argv 2)" == *" $TOK" ]]
    : > "$FAKE_LOG"; run run_launch_up bash "$cmd" "1000.00 5.00" "1030.00 5.00"
    [ "$(fake_calls)" -eq 1 ]
    for rc in 0 1 127 128 255; do
        : > "$FAKE_LOG"
        FAKE_RESUME_RC=$rc run run_launch sh "$cmd"
        case "$rc" in
            1|127) [ "$(fake_calls)" -eq 2 ] || { echo "rc=$rc"; return 1; } ;;
            *)     [ "$(fake_calls)" -eq 1 ] || { echo "rc=$rc"; return 1; } ;;
        esac
    done
    # 新規側も起動直後に失敗しても、計2回で止まる
    : > "$FAKE_LOG"
    FAKE_RESUME_RC=1 FAKE_FRESH_RC=1 run run_launch bash "$cmd"
    [ "$status" -eq 1 ]
    [ "$(fake_calls)" -eq 2 ]
}

@test "T-CSR-129: --clean・記録なし・転写なしの新規起動にも固定の1語が付く" {
    load_shutsujin_fns
    setup_panes
    # --clean: 採取せず run_token も立たない → resume ID 空 → 新規起動
    CLEAN_MODE=true
    shutsujin_claude_resume_snapshot
    [ -z "$(shutsujin_resume_id karo claude)" ]
    [ "$(shutsujin_launch_cmd karo "")" = "claude --model sonnet --name karo --dangerously-skip-permissions $TOK" ]
    # 記録はあるが転写が無い → 照合が空 → 新規起動
    CLEAN_MODE=false
    shutsujin_claude_resume_snapshot
    [ -n "$CLAUDE_RESUME_RUN_TOKEN" ]
    mkdir -p "$LAUNCH_CWD" && cd "$LAUNCH_CWD"
    [ -z "$(shutsujin_resume_id karo claude)" ]
    [ "$(shutsujin_launch_cmd karo "$(shutsujin_resume_id karo claude)")" = "claude --model sonnet --name karo --dangerously-skip-permissions $TOK" ]
    # 記録に無い agent・Codex 系
    [ "$(shutsujin_launch_cmd ashigaru4 "$(shutsujin_resume_id ashigaru4 claude)")" = "claude --model sonnet --name ashigaru4 --dangerously-skip-permissions $TOK" ]
    [[ "$(shutsujin_launch_cmd gunshi "$(shutsujin_resume_id gunshi codex)")" != *"$TOK"* ]]
}

# =============================================================================
# SessionStart hook の毎回変わる1行(cmd_785 Phase 1b)
#   resume の時、注入がその会話に既にある注入と同一だと会話へ加わらない(隔離実測)。
#   Claude 版の出力の末尾に、呼ばれるたびに変わる起動時刻の行を1行だけ足す。
# =============================================================================

# run_hook <agent_id> [cli] — 起動時刻を FAKE_NOW に固定した date で hook を走らせる
run_hook() {
    mkdir -p "$W/datebin" "$W/hooklogs"
    cat > "$W/datebin/date" <<SH
#!/bin/bash
case "\${1:-}" in
    +%Y-%m-%dT%H:%M:%S%:z) printf '%s\n' "\$FAKE_NOW" ;;
    *) exec $(command -v date) "\$@" ;;
esac
SH
    chmod +x "$W/datebin/date"
    PATH="$W/datebin:$PATH" __SESSION_START_HOOK_AGENT_ID="$1" __SESSION_START_HOOK_LOG_DIR="$W/hooklogs" \
        bash "$HOOK" ${2:+"$2"}
}

@test "T-CSR-140: hook の Claude 版は末尾に毎回変わる起動時刻の行を1行だけ足し、既存の文面を保つ" {
    local a out1 out2
    for a in shogun karo gunshi ashigaru7 other; do
        out1=$(FAKE_NOW="2026-09-30T12:00:00+09:00" run_hook "$a")
        out2=$(FAKE_NOW="2026-09-30T12:00:01+09:00" run_hook "$a")
        [ "$out1" != "$out2" ] || { echo "$a: 出力が同一"; return 1; }
        # 違いは最後の1行だけ
        [ "$(printf '%s\n' "$out1" | sed '$d')" = "$(printf '%s\n' "$out2" | sed '$d')" ]
        [ "$(printf '%s\n' "$out1" | tail -n1)" = "起動時刻: 2026-09-30T12:00:00+09:00(毎回変わる行。resume 時も、記憶に頼らず上記の手順を今あらためて実行せよ)" ]
        [ "$(printf '%s\n' "$out1" | grep -c '^起動時刻: ')" -eq 1 ]
    done
    # 既存の文面(手順・status の扱い)は残る
    out1=$(FAKE_NOW=x run_hook ashigaru7)
    [[ "$out1" == *"**CRITICAL: Session Start 手順を最優先で実行せよ**"* ]]
    [[ "$out1" == *'`queue/tasks/ashigaru7.yaml` を Read'* ]]
    [[ "$out1" == *"status=assigned かつ work → タスク実行"* ]]
    [[ "$out1" == *"idle → 待機"* ]]
    [[ "$out1" == *"done → 待機 (再報告禁止)"* ]]
    out1=$(FAKE_NOW=x run_hook karo)
    [[ "$out1" == *'`instructions/generated/karo.md` を最後まで必読'* ]]
    # 本物の date でも時刻の形で出る
    out1=$(__SESSION_START_HOOK_AGENT_ID=karo __SESSION_START_HOOK_LOG_DIR="$W/hooklogs" bash "$HOOK" | tail -n1)
    [[ "$out1" =~ ^起動時刻:\ [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}\( ]]
}

@test "T-CSR-141: hook の Codex 版・agent 不明(個人利用)は従来どおり(起動時刻の行なし・無出力)" {
    local a out
    for a in karo ashigaru7 other; do
        out=$(FAKE_NOW="2026-09-30T12:00:00+09:00" run_hook "$a" codex)
        [ -n "$out" ]
        [[ "$out" != *"起動時刻"* ]] || { echo "$a: codex 版に付いた"; return 1; }
    done
    out=$(FAKE_NOW=x run_hook "")
    [ -z "$out" ]
}

# =============================================================================
# 隔離 tmux 実機(scripts/isolated_tmux.sh のみ。本番 tmux には触れない)
# =============================================================================

@test "T-CSR-090: 隔離tmux実機: pane option(@agent_id/@agent_cli)と pane の子 claude から採取できる" {
    local helper="$PROJECT_ROOT/scripts/isolated_tmux.sh"
    HANDLE_FILE="$(bash "$helper" create -L csr090)"
    [ -n "$HANDLE_FILE" ]
    local sock session pane pane_pid child="" i
    sock="$(grep '^SOCKET_PATH=' "$HANDLE_FILE" | cut -d= -f2-)"
    session="$(grep '^SESSION=' "$HANDLE_FILE" | cut -d= -f2-)"
    pane="$(grep '^PANE_ID=' "$HANDLE_FILE" | cut -d= -f2-)"
    pane_pid="$(grep '^PANE_PID=' "$HANDLE_FILE" | cut -d= -f2-)"
    command tmux -S "$sock" set-option -p -t "$pane" @agent_id karo
    command tmux -S "$sock" set-option -p -t "$pane" @agent_cli claude

    # pane のシェルの子として、comm 名が claude の短命プロセスを起こす(自ら終わる)
    mkdir -p "$W/bin"
    ln -s "$(command -v sleep)" "$W/bin/claude"
    command tmux -S "$sock" send-keys -t "$pane" "$W/bin/claude 4" Enter
    for i in $(seq 1 30); do
        child=$(claude_resume_child_claude_pid "$pane_pid")
        [ -n "$child" ] && break
        sleep 0.1
    done
    [ -n "$child" ]
    write_record "$child" karo "$SID1"

    # モックの tmux を外し、本物の tmux を隔離 server へ向ける
    unset -f tmux
    TMUX="${sock},0,0" CLAUDE_RESUME_SESSIONS="nosuch $session" claude_resume_snapshot "$SNAP" tok-iso
    [ "$(snap_py "sorted(d['agents'])")" = "['karo']" ]
    [ "$(snap_py "d['agents']['karo']['session_id']")" = "$SID1" ]
    [ "$(snap_py "d['agents']['karo']['pane']")" = "${session}:0.0" ]
    [ "$(snap_py "d['agents']['karo']['pid']")" = "$child" ]

    # 子が自ら終わるのを待つ(teardown は素のシェルへ exit を送るため)
    for i in $(seq 1 60); do
        [ -z "$(claude_resume_child_claude_pid "$pane_pid")" ] && break
        sleep 0.2
    done
    [ -z "$(claude_resume_child_claude_pid "$pane_pid")" ]
}

@test "T-CSR-091: 隔離tmux実機: 対話 bash の pane で resume 起動が直後に失敗 → 新規起動が1回、どちらも pane の直接の子" {
    make_fakes
    local helper="$PROJECT_ROOT/scripts/isolated_tmux.sh"
    HANDLE_FILE="$(bash "$helper" create -L csr091)"
    [ -n "$HANDLE_FILE" ]
    local sock pane pane_pid child="" args="" i cmd
    sock="$(grep '^SOCKET_PATH=' "$HANDLE_FILE" | cut -d= -f2-)"
    pane="$(grep '^PANE_ID=' "$HANDLE_FILE" | cut -d= -f2-)"
    pane_pid="$(grep '^PANE_PID=' "$HANDLE_FILE" | cut -d= -f2-)"

    # 実時間に頼らず条件で同期する(cmd_791): 経過秒は単調時計の読取先を差し替えて注入し
    # (1000→1001=起動直後。cmd_794)、偽 claude は試験が release.<n> を置くまで生かしておく
    # (寿命と観測の速さを競わせない)
    FAKE_HOLD_DIR="$W/hold"
    mkdir -p "$FAKE_HOLD_DIR"
    set_uptimes "1000.00 5.00" "1001.00 5.00"

    # 出陣と同じく、pane の対話シェルへ1行を1回だけ打鍵する(偽 claude を PATH の先頭へ)
    command tmux -S "$sock" send-keys -t "$pane" \
        "export PATH=${FAKEBIN}:\$PATH FAKE_LOG=${FAKE_LOG} FAKE_DATE_LOG=${FAKE_DATE_LOG} FAKE_HOLD_DIR=${FAKE_HOLD_DIR} FAKE_RESUME_SLEEP=0 FAKE_RESUME_RC=1 FAKE_FRESH_SLEEP=0 FAKE_FRESH_RC=0" Enter
    cmd=$(inject_uptime "$(claude_resume_launch_cmd "$SID1" "$RESUME_KARO" "$FRESH_KARO")")
    command tmux -S "$sock" send-keys -t "$pane" "$cmd" Enter

    # resume 起動中: pane の直接の子(comm=claude)が --resume 付き
    for i in $(seq 1 50); do
        child=$(claude_resume_child_claude_pid "$pane_pid")
        [ -n "$child" ] && args=$(ps -o args= -p "$child" 2>/dev/null || true)
        [[ "$args" == *"--resume $SID1"* ]] && break
        sleep 0.1
    done
    [[ "$args" == *"--resume $SID1 --model sonnet --name karo"* ]]
    : > "$FAKE_HOLD_DIR/release.1"

    # 失敗後の新規起動: やはり pane の直接の子で、--resume 無しの従来引数
    # (期待する引数そのものを待つ。終わった直後の resume を読んだ瞬間に抜けない)
    args=""
    for i in $(seq 1 50); do
        child=$(claude_resume_child_claude_pid "$pane_pid")
        [ -n "$child" ] && args=$(ps -o args= -p "$child" 2>/dev/null || true)
        [[ "$args" == *"claude --model sonnet --name karo --dangerously-skip-permissions $TOK" ]] && break
        sleep 0.1
    done
    [[ "$args" == *"claude --model sonnet --name karo --dangerously-skip-permissions $TOK" ]]
    # 切替の表示は、打鍵した行(同じ文面を $_csr_rc 等のまま含む)ではなく出力行を、値の入った
    # 1行として照合する。80桁の pane では出力行が折り返すため -J で結合し、行全体で比べる。
    # pane の表示は tmux が非同期に取り込むため、現れるまで待ってから確かめる
    local shown="[shutsujin] claude --resume が起動直後に終了 (rc=1, 1秒)。従来の新規起動へ切り替える (1回のみ)"
    for i in $(seq 1 50); do
        command tmux -S "$sock" capture-pane -pJ -S - -t "$pane" | grep -qxF "$shown" && break
        sleep 0.1
    done
    command tmux -S "$sock" capture-pane -pJ -S - -t "$pane" | grep -qxF "$shown"
    : > "$FAKE_HOLD_DIR/release.2"

    # 新規起動が自ら終わるのを待つ(teardown は素のシェルへ exit を送るため)
    for i in $(seq 1 60); do
        [ -z "$(claude_resume_child_claude_pid "$pane_pid")" ] && break
        sleep 0.2
    done
    [ -z "$(claude_resume_child_claude_pid "$pane_pid")" ]
    [ "$(fake_calls)" -eq 2 ]
    [ "$(fake_date_calls)" -eq 0 ]
}

# =============================================================================
# 前回スナップショットの安全な再利用(cmd_796)
#   設計確認 context/cmd_796_design_review.md §8 の P796-01〜15。WSL 再起動・クラッシュの
#   後の出陣(撤収前に採る相手がいない)を、tmux server 無し・現生存 Claude の観測・時計を
#   試験の中でだけ固定して再現する。出陣スクリプト本体は実行しない(関数の抽出のみ)。
# =============================================================================

# use_mock_live <true|false> [name=sessionId=bridge ...] — 現生存 Claude の観測を固定する
use_mock_live() {
    MOCK_LIVE=$("$PY" - "$@" <<'PY'
import json, sys
ok = sys.argv[1] == 'true'
procs = []
for i, spec in enumerate(sys.argv[2:]):
    name, sid, bridge = (spec.split('=') + ['', ''])[:3]
    procs.append({'sessionId': sid, 'name': name, 'bridge': bridge, 'pid': 900000 + i,
                  'starttime': '1', 'config_dir': '/nonexistent'})
print(json.dumps({'ok': ok, 'reasons': [] if ok else ['900099:no_record'], 'procs': procs}))
PY
)
    claude_resume_live_observe() { printf '%s\n' "$MOCK_LIVE"; }
}

# use_mock_clock <現実時計> <uptime> <boot_id> — 時計の観測を固定する('-' は読めない)
use_mock_clock() {
    MOCK_CLOCK="$1"$'\t'"$2"$'\t'"$3"
    _claude_resume_clock() { printf '%s\n' "$MOCK_CLOCK"; }
}

iso_of() { date -d "@$1" '+%Y-%m-%dT%H:%M:%S%:z'; }

# write_prev <v2|legacy> [agent=sessionId=bridge ...] — 前回の正本($SNAP)を書く。
#   省略時は shogun・karo・ashigaru3 の3役。値は PREV_AT(採取時刻の文字列)・PREV_TOKEN・
#   PREV_BOOT・PREV_UPTIME・PREV_EXTRA(v2 に足す任意キー。"k=v")から取る。
#   bridge が "none" なら bridge_session_id を null にする。
write_prev() {
    local fmt="$1"
    shift
    local -a specs=("$@")
    [ "${#specs[@]}" -gt 0 ] || specs=("shogun=$SID1=$BR_S" "karo=$SID2=$BR_K" "ashigaru3=$SID3=$BR_A")
    mkdir -p "$W/state"
    "$PY" - "$SNAP" "$fmt" "$PREV_AT" "$PREV_TOKEN" "$PREV_BOOT" "$PREV_UPTIME" "$LAUNCH_CWD" \
        "$CLAUDE_CONFIG_DIR" "${PREV_EXTRA:-}" "${specs[@]}" <<'PY'
import sys, yaml
path, fmt, at, token, boot, uptime, cwd, cfg, extra = sys.argv[1:10]
agents = {}
for spec in sys.argv[10:]:
    a, sid, br = spec.split('=')
    agents[a] = {'session_id': sid, 'bridge_session_id': None if br == 'none' else br,
                 'pid': 4194000, 'pane': 'multiagent:0.1'}
doc = {'captured_at': at, 'run_token': token, 'sessions_found': True, 'agents': agents, 'skipped': []}
if fmt == 'v2':
    doc = {'schema_version': 2, **doc,
           'observations': {a: {'state': 'present'} for a in agents},
           'observation_complete': True, 'boot_id': boot, 'captured_uptime': float(uptime),
           'cwd': cwd, 'config_dir': cfg}
    if extra:
        k, v = extra.split('=', 1)
        doc[k] = v
with open(path, 'w', encoding='utf-8') as fh:
    fh.write('# 前回の正本(試験用)\n')
    yaml.safe_dump(doc, fh, sort_keys=False, allow_unicode=True)
PY
}

# write_transcript_br <sessionId> <bridge(session_…)> [mtime] — bridge 記録つきの転写
write_transcript_br() {
    local sid="$1" br="$2" mt="${3:-$((NOW - 1800))}"
    local f="$CLAUDE_CONFIG_DIR/projects/$SLUG/$sid.jsonl"
    mkdir -p "$CLAUDE_CONFIG_DIR/projects/$SLUG"
    {
        printf '{"type":"custom-title","customTitle":"x","sessionId":"%s"}\n' "$sid"
        printf '{"type":"bridge-session","sessionId":"%s","bridgeSessionId":"cse_%s"}\n' "$sid" "${br#session_}"
    } > "$f"
    touch -d "@$mt" "$f"
}

plan_py() { "$PY" -c "import yaml,sys; d=yaml.safe_load(open(sys.argv[1])); print($1)" "$W/state/claude_session_plan.yaml"; }
cur_py() { "$PY" -c "import yaml,sys; d=yaml.safe_load(open(sys.argv[1])); print($1)" "$W/state/claude_session_snapshot.current.yaml"; }
# plan_of <agent> — 計画の "由来:理由" (前回由来なら "previous_snapshot:<ID>")
plan_of() {
    plan_py "(lambda e: e['source'] + ':' + (e.get('reason') or e.get('session_id') or ''))(d['agents'].get('$1', {'source': 'none'}))"
}

# setup_prev_world — WSL 再起動後の出陣の世界: tmux server 無し・生存 Claude 無し・
#   別の boot。前回の正本(新形式・1時間前)に3役、各々の転写と bridge 記録がある。
setup_prev_world() {
    load_libs "$W/settings_prev.yaml"
    use_mock_child
    load_shutsujin_fns
    NOW=$(date +%s)
    BOOT_NOW="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    BOOT_OLD="bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    use_mock_clock "$NOW" "500.00" "$BOOT_NOW"
    use_mock_live true
    MOCK_SESSIONS=""
    MOCK_TMUX_MODE=noserver
    _ASHIGARU_IDS_STR="ashigaru1 ashigaru3"   # ashigaru1 は codex(対象外)
    mkdir -p "$LAUNCH_CWD"
    cd "$LAUNCH_CWD"
    PREV_TOKEN="1790000000-4242-cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    PREV_AT=$(iso_of $((NOW - 3600)))
    PREV_BOOT="$BOOT_OLD"
    PREV_UPTIME="100000.0"
    PREV_EXTRA=""
    BR_S="session_01ShogunBridge"
    BR_K="session_01KaroBridge"
    BR_A="session_01AshiBridge"
    write_prev v2
    write_transcript_br "$SID1" "$BR_S"
    write_transcript_br "$SID2" "$BR_K"
    write_transcript_br "$SID3" "$BR_A"
}

# run_prev — 出陣の STEP 1 と同じ順(排他 → 採取・計画・正本の保存方針)
run_prev() {
    shutsujin_resume_unlock
    shutsujin_resume_lock
    shutsujin_claude_resume_snapshot
}

# inject_check <1行> <true|false> — 生成した1行の直前確認
#   (`bash <lib> --check-previous …`)が正確に1か所であることを確かめ、試験側で true/false
#   へ置き換える(lib に差し替えの口は無い。inject_uptime と同じ流儀)
inject_check() {
    local cmd="$1" to="$2" pre rest
    pre="if bash ${CLAUDE_RESUME_LIB_DIR}/claude_session_resume.sh --check-previous "
    [ "$(printf '%s' "$cmd" | grep -o -F -- "--check-previous" | wc -l)" -eq 1 ] || { echo "直前確認が1か所でない" >&2; return 1; }
    [[ "$cmd" == "$pre"* ]] || { echo "直前確認が先頭でない" >&2; return 1; }
    rest="${cmd#"$pre"}"
    rest="${rest#*; then }"
    printf 'if %s; then %s\n' "$to" "$rest"
}

@test "P796-01: 確実な稼働なし+前回の正本・転写・bridge・鮮度・未使用が全て有効 → その UUID で resume。元の token・時刻を計画に残し、空の採取で正本を消さない" {
    setup_prev_world
    cp "$SNAP" "$W/snap_before"
    run_prev
    [ "$CLAUDE_RESUME_LOCK_HELD" = true ]
    [ -n "$CLAUDE_RESUME_RUN_TOKEN" ]
    [ "$CLAUDE_RESUME_RUN_TOKEN" != "$PREV_TOKEN" ]
    [ "$(shutsujin_resume_id shogun claude)" = "$SID1" ]
    [ "$(shutsujin_resume_id karo claude)" = "$SID2" ]
    [ "$(shutsujin_resume_id ashigaru3 claude)" = "$SID3" ]
    [ "${CLAUDE_RESUME_PLAN_SOURCE[karo]}" = "previous_snapshot" ]
    [ "$CLAUDE_RESUME_PREV_REMAINING" -eq 3 ]
    # 正本は byte 単位で残る(空の採取で上書きしない)
    cmp "$SNAP" "$W/snap_before"
    [[ "${LOGS[*]}" == *"前回の記録(正本)を残す"* ]]
    # current は今回の token と「不在」の観測を持つ
    [ "$(cur_py "(d['run_token'] == '$CLAUDE_RESUME_RUN_TOKEN', d['agents'], sorted((k, v['state']) for k, v in d['observations'].items()), d['observation_complete'])")" \
        = "(True, {}, [('ashigaru3', 'absent'), ('karo', 'absent'), ('shogun', 'absent')], True)" ]
    # 計画は今回の token。元の token・採取時刻を由来として持つ(今回の値へ貼り替えない)
    [ "$(plan_py "d['run_token'] == '$CLAUDE_RESUME_RUN_TOKEN'")" = "True" ]
    [ "$(plan_py "(d['agents']['karo']['original_run_token'], d['agents']['karo']['original_captured_at'], d['agents']['karo']['age_basis'], d['agents']['karo']['bridge_session_id'])")" \
        = "('$PREV_TOKEN', '$PREV_AT', 'wallclock_other_boot', '$BR_K')" ]
    [[ "${LOGS[*]}" == *"karo は前回記録の候補(basis=wallclock_other_boot age=3600s token=$PREV_TOKEN at=$PREV_AT)"* ]]
    # 起動は直前確認つきの1行
    [[ "$(shutsujin_launch_cmd karo "$SID2")" == "if bash ${CLAUDE_RESUME_LIB_DIR}/claude_session_resume.sh --check-previous $CLAUDE_RESUME_PLAN_FILE $CLAUDE_RESUME_RUN_TOKEN karo $SID2; then "* ]]
    shutsujin_log_resume "家老" "$SID2" karo
    [[ "${LOGS[-1]}" == *"前回の記録から会話を再開(--resume $SID2。起動の直前に稼働状況を再確認し、拒否なら新規起動)"* ]]
    # 再起動後の出陣を繰り返しても候補は消えない(正本が残るため)
    run_prev
    [ "$(shutsujin_resume_id karo claude)" = "$SID2" ]
    cmp "$SNAP" "$W/snap_before"
    # 旧形式(今日の正本と同じ形)でも同じ条件で通り、制限(現実時計)を由来に残す
    write_prev legacy
    run_prev
    [ "$(plan_of karo)" = "previous_snapshot:$SID2" ]
    [ "$(plan_py "(d['canonical_format'], d['agents']['karo']['age_basis'])")" = "('legacy', 'wallclock_legacy')" ]
}

@test "P796-02: 指定転写が無い・別cwd・不可読・空・破損・最後のbridgeが空/不一致/無し・symlink → その agent だけ新規。他の転写へ探索しない" {
    setup_prev_world
    local f="$CLAUDE_CONFIG_DIR/projects/$SLUG/$SID2.jsonl"
    # 同じ bridge を持つ別 ID の転写(探索すれば見つかってしまう囮)
    write_transcript_br "$SID_DECOY" "$BR_K"
    expect_karo() {
        run_prev
        [ "$(plan_of karo)" = "fresh:$1" ] || { echo "期待 fresh:$1 実際 $(plan_of karo)"; return 1; }
        [ "$(plan_of shogun)" = "previous_snapshot:$SID1" ]
        [ -z "$(shutsujin_resume_id karo claude)" ]
        # 次の観点のために正しい転写へ戻す(不可読・symlink も戻す)
        chmod 644 "$f" 2>/dev/null || true
        if [ -L "$f" ]; then mv "$f" "$W/link.$RANDOM"; fi
        write_transcript_br "$SID2" "$BR_K"
    }
    mv "$f" "$W/moved.jsonl";                                   expect_karo no_transcript
    mkdir -p "$CLAUDE_CONFIG_DIR/projects/-other-dir"
    mv "$f" "$CLAUDE_CONFIG_DIR/projects/-other-dir/$SID2.jsonl"; expect_karo no_transcript
    chmod 000 "$f";                                             expect_karo transcript_unreadable
    : > "$f"; touch -d "@$((NOW - 60))" "$f";                   expect_karo transcript_empty
    printf 'not json\n' >> "$f"; touch -d "@$((NOW - 60))" "$f"; expect_karo transcript_broken
    printf '{"type":"bridge-session","sessionId":"%s","bridgeSessionId":""}\n' "$SID2" >> "$f"; touch -d "@$((NOW - 60))" "$f"
    expect_karo bridge_disconnected
    printf '{"type":"bridge-session","sessionId":"%s","bridgeSessionId":"cse_01OtherBridge"}\n' "$SID2" >> "$f"; touch -d "@$((NOW - 60))" "$f"
    expect_karo bridge_mismatch
    printf '{"type":"bridge-session","sessionId":"%s","bridgeSessionId":"cse_01KaroBridge"}\n' "$SID_DECOY" >> "$f"; touch -d "@$((NOW - 60))" "$f"
    expect_karo transcript_session_mismatch
    printf '{"type":"custom-title","customTitle":"x","sessionId":"%s"}\n' "$SID2" > "$f"; touch -d "@$((NOW - 60))" "$f"
    expect_karo transcript_no_bridge
    mv "$f" "$W/real.jsonl"; ln -s "$W/real.jsonl" "$f";        expect_karo transcript_not_regular
    # 正本の bridge が無い(null)・不正
    write_prev v2 "shogun=$SID1=$BR_S" "karo=$SID2=none" "ashigaru3=$SID3=$BR_A"
    expect_karo no_bridge
    write_prev v2 "shogun=$SID1=$BR_S" "karo=$SID2=cse_01KaroBridge" "ashigaru3=$SID3=$BR_A"
    expect_karo no_bridge
    # 戻せば通る(各回の拒否は上の欠陥だけによる)
    write_prev v2
    run_prev
    [ "$(plan_of karo)" = "previous_snapshot:$SID2" ]
}

@test "P796-03: 正本の年齢 0・ちょうど7日は通過、7日+1秒・小数で7日超・未来・不正日時と転写 mtime の未来・7日超は新規。最近の mtime で古い正本を延命しない" {
    setup_prev_world
    [ "$CLAUDE_RESUME_PREVIOUS_MAX_AGE_SEC" = "604800" ]
    expect_age() {   # <採取時刻の文字列> <期待>
        PREV_AT="$1"
        write_prev v2
        run_prev
        [ "$(plan_of karo)" = "$2" ] || { echo "at=$1 期待 $2 実際 $(plan_of karo)"; return 1; }
    }
    expect_age "$(iso_of "$NOW")"                    "previous_snapshot:$SID2"
    expect_age "$(iso_of $((NOW - 604800)))"         "previous_snapshot:$SID2"
    expect_age "$(iso_of $((NOW - 604801)))"         "fresh:snapshot_stale"
    expect_age "$(iso_of $((NOW + 1)))"              "fresh:snapshot_future"
    expect_age "2026-13-45T00:00:00+09:00"           "fresh:canonical_captured_at"
    expect_age "2026-10-01T00:00:00"                 "fresh:canonical_captured_at"
    # 現実時計に小数がある時、ちょうど7日+0.5秒は超過(丸めで延命しない)
    use_mock_clock "${NOW}.5" "500.00" "$BOOT_NOW"
    expect_age "$(iso_of $((NOW - 604800)))"         "fresh:snapshot_stale"
    use_mock_clock "$NOW" "500.00" "$BOOT_NOW"
    # 転写 mtime: 未来・7日超は拒否
    PREV_AT=$(iso_of $((NOW - 60)))
    write_prev v2
    touch -d "@$((NOW + 5))" "$CLAUDE_CONFIG_DIR/projects/$SLUG/$SID2.jsonl"
    run_prev
    [ "$(plan_of karo)" = "fresh:transcript_future" ]
    touch -d "@$((NOW - 604801))" "$CLAUDE_CONFIG_DIR/projects/$SLUG/$SID2.jsonl"
    run_prev
    [ "$(plan_of karo)" = "fresh:transcript_stale" ]
    # 転写が最近更新されていても、7日を超えた正本は延命しない
    touch -d "@$((NOW - 10))" "$CLAUDE_CONFIG_DIR/projects/$SLUG/$SID2.jsonl"
    expect_age "$(iso_of $((NOW - 604801)))"         "fresh:snapshot_stale"
    # mtime が採取時刻より後なのは、同じ会話を続けた結果なので拒否しない
    touch -d "@$((NOW - 10))" "$CLAUDE_CONFIG_DIR/projects/$SLUG/$SID2.jsonl"
    expect_age "$(iso_of $((NOW - 3600)))"           "previous_snapshot:$SID2"
}

@test "P796-04: 候補 ID を別 PID・別 name・別 cwd が使用中なら新規。bridge を別 ID が使用中(/clear 後)も新規。正本の旧 PID の不在では通さない" {
    setup_prev_world
    # 正本の pid(4194000)はどれも生きていないが、ID は別のプロセスが使っている
    use_mock_live true "ashigaru5=$SID2=session_01Unrelated"
    run_prev
    [ "$(plan_of karo)" = "fresh:session_in_use" ]
    [ "$(plan_of shogun)" = "previous_snapshot:$SID1" ]
    # 同じ bridge を別の ID(/clear で ID だけ替わった生存プロセス)が使っている
    use_mock_live true "ashigaru9=$SID_DECOY=$BR_K"
    run_prev
    [ "$(plan_of karo)" = "fresh:bridge_in_use" ]
    # 同じ役名の Claude が別の所で生きている(撤収前の観測で判定不能)
    use_mock_live true "karo=$SID_DECOY=session_01Other"
    run_prev
    [ "$(plan_of karo)" = "fresh:not_absent:unknown" ]
    [ "$(cur_py "d['observations']['karo']")" = "{'state': 'unknown', 'reason': 'same_role_live'}" ]
    # 判定不能の観測があった出陣は正本を今回の実採取で置き換える(旧記録を再利用可能なままにしない)
    run_prev
    [ "$(plan_of karo)" = "fresh:not_absent:unknown" ]
    use_mock_live true
    run_prev
    [ "$(plan_of karo)" = "fresh:no_previous_entry" ]
    # 正本が有効で使用者がいなければ通る
    write_prev v2
    use_mock_live true "ashigaru5=$SID_DECOY=session_01Unrelated"
    run_prev
    [ "$(plan_of karo)" = "previous_snapshot:$SID2" ]
}

@test "P796-05: 生存 Claude の記録が無い・壊れた・照合不一致なら観測は unknown で前回を拒否する(撤収前の観測と計画の両方)" {
    setup_prev_world
    use_mock_live false
    run_prev
    [ "$(cur_py "sorted((k, v['state'], v.get('reason')) for k, v in d['observations'].items())")" \
        = "[('ashigaru3', 'unknown', 'live_unknown'), ('karo', 'unknown', 'live_unknown'), ('shogun', 'unknown', 'live_unknown')]" ]
    [ "$(cur_py "d['observation_complete']")" = "False" ]
    [ "$(plan_of karo)" = "fresh:not_absent:unknown" ]
    # 判定不能の観測で正本を消さない・使わない(全対象が absent ではないので、今回の実採取=空で置換)
    [ "$(snap_py "(d['agents'], d['observations']['karo']['state'])")" = "({}, 'unknown')" ]
    # 次の出陣で観測が戻っても、置き換えた正本には前回の ID が無い(旧記録を再利用可能なままにしない)
    use_mock_live true
    run_prev
    [ "$(plan_of karo)" = "fresh:no_previous_entry" ]
}

@test "P796-05a: 本物の /proc 観測: 記録の無い・壊れた・starttime 不一致の生存 claude は理由付きで判定不能、照合の通る記録は使用者、死んだ残存記録は使用者にしない" {
    mkdir -p "$W/bin"
    ln -s "$(command -v sleep)" "$W/bin/claude"
    "$W/bin/claude" 8 &
    local c=$!
    live_of() { claude_resume_live_observe | "$PY" -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
    # 1) 記録が無い
    [ "$(live_of "('$c:no_record' in d['reasons'], d['ok'], any(p['pid'] == $c for p in d['procs']))")" = "(True, False, False)" ]
    # 2) 壊れた記録
    printf '{"pid": %s, ' "$c" > "$CLAUDE_CONFIG_DIR/sessions/$c.json"
    [ "$(live_of "'$c:broken_record' in d['reasons']")" = "True" ]
    # 3) starttime が違う(PID 再利用・死んだ記録)
    write_record "$c" karo "$SID1" "999999999999"
    [ "$(live_of "'$c:proc_start_mismatch' in d['reasons']")" = "True" ]
    # 4) 照合が通れば使用者として列挙される(設定 dir はそのプロセスの環境から引く)
    write_record "$c" karo "$SID1"
    [ "$(live_of "[(p['sessionId'], p['name'], p['config_dir']) for p in d['procs'] if p['pid'] == $c]")" = "[('$SID1', 'karo', '$CLAUDE_CONFIG_DIR')]" ]
    [ "$(live_of "any(r.startswith('$c:') for r in d['reasons'])")" = "False" ]
    # 5) 死んだ PID の残存記録(同じ ID でも)は使用者にしない
    local dead="" p
    for p in $(seq 4194303 -1 4193000); do
        [ -e "/proc/$p" ] || { dead=$p; break; }
    done
    write_record "$dead" karo "$SID2" "12345"
    [ "$(live_of "any(p['sessionId'] == '$SID2' for p in d['procs']) or any(r.startswith('$dead:') for r in d['reasons'])")" = "False" ]
    wait "$c"
}

@test "P796-06: pane に Claude はいるが採取 NG・子が複数・子の探索失敗(出力の無い非0終了を含む)・tmux の失敗は unknown(撤収後に消えても前回へ倒さない)。素のシェル・server 無しは absent" {
    setup_prev_world
    MOCK_TMUX_MODE=""
    MOCK_SESSIONS="shogun multiagent"
    MOCK_ROWS="shogun:0.0\t9100\tshogun\tclaude\n"
    MOCK_ROWS+="multiagent:0.0\t9200\tkaro\tclaude\n"
    MOCK_ROWS+="multiagent:0.3\t9203\tashigaru3\tclaude\n"
    MOCK_CHILD[9100]=""          # 素のシェル(claude が落ちた)
    MOCK_CHILD[9200]=$$          # claude はいるが記録の照合が合わない
    write_record $$ karo "$SID_DECOY" "999999999999"
    MOCK_CHILD[9203]=MULTI
    run_prev
    [ "$(cur_py "sorted((k, v['state'], v.get('reason')) for k, v in d['observations'].items())")" \
        = "[('ashigaru3', 'unknown', 'multiple_claude_pids'), ('karo', 'unknown', 'proc_start_mismatch'), ('shogun', 'absent', None)]" ]
    # 計画時の live 観測では誰もいない(撤収後に消えた)が、撤収前の unknown を absent へ格上げしない
    [ "$(plan_of karo)" = "fresh:not_absent:unknown" ]
    [ "$(plan_of ashigaru3)" = "fresh:not_absent:unknown" ]
    [ "$(plan_of shogun)" = "previous_snapshot:$SID1" ]
    # 子の探索に失敗
    write_prev v2
    MOCK_CHILD[9200]=ERR
    run_prev
    [ "$(cur_py "d['observations']['karo']")" = "{'state': 'unknown', 'reason': 'child_scan_failed'}" ]
    # tmux が「無い」と明言しない失敗・list-panes の失敗は全員 unknown(空の出力を absence にしない)
    local mode
    for mode in broken listfail; do
        write_prev v2
        MOCK_TMUX_MODE=$mode
        run_prev
        [ "$(cur_py "sorted(v.get('reason') for v in d['observations'].values())")" = "['tmux_unreadable', 'tmux_unreadable', 'tmux_unreadable']" ] || { echo "mode=$mode"; return 1; }
        [ "$(plan_of shogun)" = "fresh:not_absent:unknown" ]
    done
    # server はあるがセッションが無い・server が無い は absent
    for mode in "" noserver; do
        write_prev v2
        MOCK_TMUX_MODE=$mode
        MOCK_SESSIONS=""
        run_prev
        [ "$(cur_py "sorted(v['state'] for v in d['observations'].values())")" = "['absent', 'absent', 'absent']" ] || { echo "mode=[$mode]"; return 1; }
        MOCK_SESSIONS="shogun multiagent"
    done
    # 子の探索が出力なしで失敗(G796-Q01): 本物の探索関数へ戻し、ps だけを試験側で固定する。
    #   親の確認(ps -p)は成功・子一覧(ps --ppid)は stdout/stderr とも空で非0。計画時の
    #   live 観測は空(撤収後に消えた)だが、撤収前の探索失敗を不在へ格上げしない。
    #   親は子を持たない本物のプロセス(/proc の子一覧は空)と、確認の直後に居なくなった pid。
    use_real_child
    ps() {
        case "$1" in
            -p) return 0 ;;
            --ppid) return "$MOCK_PS_RC" ;;
            *) command ps "$@" ;;
        esac
    }
    local dead="" p spec rc pane
    for p in $(seq 4194303 -1 4193000); do
        [ -e "/proc/$p" ] || { dead=$p; break; }
    done
    [ -n "$dead" ]
    start_held_parent "$W/held.fifo"
    MOCK_TMUX_MODE=""
    MOCK_SESSIONS="multiagent"
    for spec in "2 $HELD_PARENT" "130 $HELD_PARENT" "137 $HELD_PARENT" "255 $HELD_PARENT" "1 $dead"; do
        read -r rc pane <<< "$spec"
        write_prev v2
        MOCK_PS_RC=$rc
        MOCK_ROWS="multiagent:0.0\t${pane}\tkaro\tclaude\n"
        run_prev
        [ "$(cur_py "d['observations']['karo']")" = "{'state': 'unknown', 'reason': 'child_scan_failed'}" ] || { echo "rc=$rc pane=$pane"; return 1; }
        [ "$(plan_of karo)" = "fresh:not_absent:unknown" ] || { echo "rc=$rc pane=$pane"; return 1; }
    done
    # 対照: rc=1(ps の 0件と同じ rc)で出力なし・/proc の子一覧で 0件を裏取りできた → 不在
    write_prev v2
    MOCK_PS_RC=1
    MOCK_ROWS="multiagent:0.0\t${HELD_PARENT}\tkaro\tclaude\n"
    run_prev
    [ "$(cur_py "d['observations']['karo']['state']")" = "absent" ]
    [ "$(plan_of karo)" = "previous_snapshot:$SID2" ]
    release_held_parent
    unset -f ps
}

@test "P796-06a: 子 claude の探索は 0件・1件・複数・探索失敗(親の不在・ps の誤り・出力の無い非0終了・0件の裏取り不能・不正形式)を区別する(本物のプロセス)" {
    mkdir -p "$W/bin"
    ln -s "$(command -v sleep)" "$W/bin/claude"
    local me=$BASHPID c1 c2 lone
    # 0件: 子の無い親(自ら終わる sleep)
    sleep 3 &
    lone=$!
    [ "$(claude_resume_child_claude_scan "$lone")" = "NONE" ]
    # 1件・複数
    "$W/bin/claude" 2 &
    c1=$!
    [ "$(claude_resume_child_claude_scan "$me")" = "ONE $c1" ]
    "$W/bin/claude" 2 &
    c2=$!
    [ "$(claude_resume_child_claude_scan "$me")" = "MULTI" ]
    [ -z "$(claude_resume_child_claude_pid "$me")" ]
    # 親の不在・不正な pid は探索失敗(0件と読まない)
    local dead="" p
    for p in $(seq 4194303 -1 4193000); do
        [ -e "/proc/$p" ] || { dead=$p; break; }
    done
    [ "$(claude_resume_child_claude_scan "$dead")" = "ERR" ]
    [ "$(claude_resume_child_claude_scan "1; x")" = "ERR" ]
    # ps が失敗を stderr に出して rc=1(0件と同じ rc)でも、0件ではなく探索失敗
    cat > "$W/bin/ps" <<SH
#!/bin/bash
case " \$* " in
    *" --ppid "*) echo "error: unsupported option" >&2; exit 1 ;;
    *) exec $(command -v ps) "\$@" ;;
esac
SH
    chmod +x "$W/bin/ps"
    [ "$(PATH="$W/bin:$PATH" claude_resume_child_claude_scan "$me")" = "ERR" ]
    # G796-Q01: 子一覧の ps が出力なしで失敗しても 0件と読まない(ps だけを試験側の関数で固定)。
    #   親は子を持たない本物のプロセス(/proc の子一覧は空)。rc が 0・1 以外は探索失敗
    ps() {
        case "$1" in
            -p) [ "${MOCK_PS_PARENT:-}" = seen ] && return 0; command ps "$@" ;;
            --ppid) printf '%b' "${MOCK_PS_OUT:-}"; return "$MOCK_PS_RC" ;;
            *) command ps "$@" ;;
        esac
    }
    start_held_parent "$W/held.fifo"
    local held=$HELD_PARENT rc
    MOCK_PS_OUT=""
    for rc in 2 3 127 128 130 137 143 255; do
        MOCK_PS_RC=$rc
        [ "$(claude_resume_child_claude_scan "$held")" = "ERR" ] || { echo "rc=$rc"; return 1; }
    done
    # rc=1(ps の 0件と同じ rc)で出力なし: /proc の子一覧で 0件を裏取りできた時だけ 0件
    MOCK_PS_RC=1
    [ "$(claude_resume_child_claude_scan "$held")" = "NONE" ]
    #   /proc では子が見える(ps の答えと食い違う)→ 探索失敗
    [ "$(claude_resume_child_claude_scan "$me")" = "ERR" ]
    #   親が確認の直後に居なくなり /proc を読めない → 探索失敗
    MOCK_PS_PARENT=seen
    [ "$(claude_resume_child_claude_scan "$dead")" = "ERR" ]
    #   呼び手が nullglob を立てていても(子一覧のファイルが1つも無い)0件と読まない
    shopt -s nullglob
    [ "$(claude_resume_child_claude_scan "$dead")" = "ERR" ]
    shopt -u nullglob
    MOCK_PS_PARENT=""
    # rc=0 なのに行が無い・pid だけの行は不正形式 → 探索失敗。正しい形は従来どおり
    MOCK_PS_RC=0
    MOCK_PS_OUT=""
    [ "$(claude_resume_child_claude_scan "$held")" = "ERR" ]
    MOCK_PS_OUT="  4242\n"
    [ "$(claude_resume_child_claude_scan "$held")" = "ERR" ]
    MOCK_PS_OUT="  4242 bash\n"
    [ "$(claude_resume_child_claude_scan "$held")" = "NONE" ]
    MOCK_PS_OUT="  4242 bash\n  4243 claude\n"
    [ "$(claude_resume_child_claude_scan "$held")" = "ONE 4243" ]
    unset -f ps
    release_held_parent
    wait "$c1" "$c2" "$lone"
}

@test "P796-07: 役名の違い・廃止・重複・CLI の変更は前回を使わず、pane 番号だけの変更は使う" {
    setup_prev_world
    # pane 番号・pane の並びだけが変わった(役名で照合し、pane は診断情報)
    MOCK_TMUX_MODE=""
    MOCK_SESSIONS="multiagent"
    MOCK_ROWS="multiagent:0.7\t9207\tashigaru3\tclaude\n"
    run_prev
    [ "$(plan_of ashigaru3)" = "previous_snapshot:$SID3" ]
    MOCK_SESSIONS=""
    MOCK_TMUX_MODE=noserver
    # 役名の変更: 正本は ashigaru30、今回の対象は ashigaru3
    write_prev v2 "shogun=$SID1=$BR_S" "karo=$SID2=$BR_K" "ashigaru30=$SID3=$BR_A"
    run_prev
    [ "$(plan_of ashigaru3)" = "fresh:no_previous_entry" ]
    # 廃止(今回の対象に無い役)は計画に載らない
    _ASHIGARU_IDS_STR="ashigaru1"
    write_prev v2
    run_prev
    [ "$(plan_of ashigaru3)" = "none:" ]
    [ -z "$(shutsujin_resume_id ashigaru3 claude)" ]
    # 対象一覧に重複
    _ASHIGARU_IDS_STR="ashigaru3 ashigaru3"
    run_prev
    [ "$(plan_of ashigaru3)" = "fresh:duplicate_target" ]
    [ -z "$(shutsujin_resume_id ashigaru3 claude)" ]
    # CLI の変更(今回は codex): 対象外で計画に載らず、起動コマンドは従来の codex のまま
    _ASHIGARU_IDS_STR="ashigaru1 ashigaru3"
    sed 's/ashigaru3: {type: claude, model: sonnet --effort xhigh}/ashigaru3: {type: codex, model: gpt-6-luna}/' "$W/settings_prev.yaml" > "$W/settings_prev_codex.yaml"
    load_libs "$W/settings_prev_codex.yaml"
    use_mock_child; use_mock_live true; use_mock_clock "$NOW" "500.00" "$BOOT_NOW"
    run_prev
    [ "$(plan_of ashigaru3)" = "none:" ]
    [ -z "$(shutsujin_resume_id ashigaru3 codex)" ]
    [ "$(shutsujin_launch_cmd ashigaru3 "")" = "$(build_cli_command ashigaru3)" ]
    [[ "$(build_cli_command ashigaru3)" == "codex "* ]]
}

@test "P796-08: 正本の破損・重複キー・不正 UUID・空 token・無効化記録・未知のキー・保存失敗(current・正本)は新規(候補を評価しない)。current の token 不一致は同一 run の照合で拒否" {
    setup_prev_world
    expect_all() {   # <期待の理由>
        run_prev
        [ "$(plan_of karo)" = "fresh:$1" ] && [ "$(plan_of shogun)" = "fresh:$1" ] || { echo "期待 $1 実際 $(plan_of karo)/$(plan_of shogun)"; return 1; }
    }
    printf 'agents: [unclosed\n' > "$SNAP";                         expect_all canonical_broken
    write_prev v2
    printf 'agents:\n  karo: {session_id: x}\n' >> "$SNAP";        expect_all canonical_broken   # agents が2回(重複キー)
    write_prev v2 "shogun=$SID1=$BR_S" "karo=${SID_DECOY^^}=$BR_K"
    run_prev
    [ "$(plan_of karo)" = "fresh:invalid_session_id" ]
    [ "$(plan_of shogun)" = "previous_snapshot:$SID1" ]
    PREV_TOKEN=""; write_prev v2;                                    expect_all canonical_token
    PREV_TOKEN="1790000000-4242-cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    PREV_EXTRA="unknown_key=1"; write_prev v2;                       expect_all canonical_schema
    PREV_EXTRA=""
    claude_resume_invalidate "$SNAP" clean;                          expect_all canonical_invalidated
    [ "$(snap_py "(d['invalidated'], d['reason'], d['agents'])")" = "(True, 'clean', {})" ]
    # current の保存に失敗: そのrunは前回経路を使わず、全員新規(run_token も立てない)
    write_prev v2
    chmod 555 "$W/state"
    run_prev
    chmod 755 "$W/state"
    [ -z "$CLAUDE_RESUME_RUN_TOKEN" ]
    [ -z "$(shutsujin_resume_id karo claude)" ]
    [[ "${LOGS[*]}" == *"採取に失敗"* ]]
    # 正本の書込み(今回の実採取での置換)自体に失敗した出陣は、全員新規(current も使わない)
    SID_CUR="44444444-4444-4444-8444-444444444444"
    MOCK_TMUX_MODE=""
    MOCK_SESSIONS="shogun"
    MOCK_ROWS="shogun:0.0\t9100\tshogun\tclaude\n"
    MOCK_CHILD[9100]=$$
    write_record $$ shogun "$SID_CUR" "" "session_01CurBridge"
    write_transcript "$SID_CUR"
    mv "$SNAP" "$W/snap_file_moved"
    mkdir "$SNAP"                     # 正本の場所が dir で置換できない
    run_prev
    [ -z "$CLAUDE_RESUME_RUN_TOKEN" ]
    [ -z "$(shutsujin_resume_id shogun claude)" ]
    [ "$CLAUDE_RESUME_PREV_REMAINING" -eq 0 ]
    [[ "${LOGS[*]}" == *"記録(正本)を更新できないため、この出陣は全agentを新規起動で続行"* ]]
    rmdir "$SNAP"
    mv "$W/snap_file_moved" "$SNAP"
    MOCK_SESSIONS=""
    MOCK_TMUX_MODE=noserver
    # current の token が今回と違う(別 run のファイル): 計画は current を使わず、前回も評価しない
    run_prev
    run claude_resume_plan "$SNAP" "$CLAUDE_RESUME_CURRENT_FILE" "$W/state/plan2.yaml" "tok-other" "shogun karo" "$LAUNCH_CWD" 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"PLAN"$'\t'"karo"$'\t'"fresh"$'\t'$'\t'"current_mismatch"* ]]
}

@test "P796-09: 別 switch の OFF・未記載・読めない設定、基本 switch の OFF、--clean は前回経路を無効にし、clean 後に旧会話を復活させない。Codex の argv は不変" {
    setup_prev_world
    cp "$SNAP" "$W/snap_before"
    # 別 switch の値(真と読む形は基本 switch と同じ)
    local v
    for v in true True yes on 1; do
        sed "s/claude_session_resume_previous_snapshot: true/claude_session_resume_previous_snapshot: $v/" "$W/settings_prev.yaml" > "$W/settings_v.yaml"
        load_libs "$W/settings_v.yaml"
        claude_resume_previous_enabled || { echo "v=$v"; return 1; }
    done
    for v in false no off 0 tru '""'; do
        sed "s/claude_session_resume_previous_snapshot: true/claude_session_resume_previous_snapshot: $v/" "$W/settings_prev.yaml" > "$W/settings_v.yaml"
        load_libs "$W/settings_v.yaml"
        ! claude_resume_previous_enabled || { echo "v=$v"; return 1; }
    done
    # 未記載(=cmd_785 だけ有効): 正本の保存方針は働くが、前回は使わない
    load_libs "$W/settings_on.yaml"
    use_mock_child; use_mock_live true; use_mock_clock "$NOW" "500.00" "$BOOT_NOW"
    run_prev
    [ -n "$CLAUDE_RESUME_RUN_TOKEN" ]
    [ "$(plan_of karo)" = "fresh:previous_disabled" ]
    [ -z "$(shutsujin_resume_id karo claude)" ]
    cmp "$SNAP" "$W/snap_before"
    # 基本 switch が OFF なら別 switch が真でも無効(何も採らない・書かない)
    sed 's/  claude_session_resume: true/  claude_session_resume: false/' "$W/settings_prev.yaml" > "$W/settings_v.yaml"
    load_libs "$W/settings_v.yaml"
    run claude_resume_previous_enabled
    [ "$status" -eq 1 ]
    # 設定を読めなければ OFF
    load_libs "$W/no_such_settings.yaml"
    run claude_resume_previous_enabled
    [ "$status" -eq 1 ]
    # --clean: resume の switch が OFF でも正本を無効化する
    load_libs "$W/settings_v.yaml"
    use_mock_child; use_mock_live true; use_mock_clock "$NOW" "500.00" "$BOOT_NOW"
    CLEAN_MODE=true
    run_prev
    [ -z "$CLAUDE_RESUME_RUN_TOKEN" ]
    [ "$(snap_py "(d['invalidated'], d['reason'])")" = "(True, 'clean')" ]
    # clean の後の出陣(再起動後・両 switch ON)でも clean 前の会話を復活させない
    load_libs "$W/settings_prev.yaml"
    use_mock_child; use_mock_live true; use_mock_clock "$NOW" "500.00" "$BOOT_NOW"
    CLEAN_MODE=false
    run_prev
    [ "$(plan_of karo)" = "fresh:canonical_invalidated" ]
    [ -z "$(shutsujin_resume_id karo claude)" ]
    # Codex 系: 計画に載らず、起動コマンドは従来どおり
    [ "$(plan_of gunshi)" = "none:" ]
    [ "$(shutsujin_launch_cmd gunshi "$(shutsujin_resume_id gunshi codex)")" = "$(build_cli_command gunshi)" ]
    [[ "$(build_cli_command gunshi)" != *"--resume"* ]]
}

@test "P796-10: current の成功・不在・unknown が混在すれば役別に選ぶ(current 優先・unknown を救わない)。正本は置換前の内容を読み、別 run の計画は直前確認で拒否" {
    setup_prev_world
    SID_CUR="44444444-4444-4444-8444-444444444444"
    MOCK_TMUX_MODE=""
    MOCK_SESSIONS="shogun multiagent"
    MOCK_ROWS="shogun:0.0\t9100\tshogun\tclaude\n"
    MOCK_ROWS+="multiagent:0.0\t9200\tkaro\tclaude\n"
    MOCK_ROWS+="multiagent:0.3\t9203\tashigaru3\tclaude\n"
    MOCK_CHILD[9100]=$$          # shogun は稼働中(今回の採取が通る)
    write_record $$ shogun "$SID_CUR" "" "$BR_S"
    write_transcript "$SID_CUR"
    MOCK_CHILD[9200]=""          # karo は落ちていた(素のシェル)
    MOCK_CHILD[9203]=$PPID       # ashigaru3 は claude がいるが照合 NG
    write_record $PPID ashigaru3 "$SID_DECOY" "999999999999"
    use_mock_live true "shogun=$SID_CUR=$BR_S"
    run_prev
    [ "$(plan_of shogun)" = "current:$SID_CUR" ]
    [ "$(plan_of karo)" = "previous_snapshot:$SID2" ]
    [ "$(plan_of ashigaru3)" = "fresh:not_absent:unknown" ]
    # karo の由来は置換前の正本(元の token・時刻)
    [ "$(plan_py "(d['agents']['karo']['original_run_token'], d['agents']['karo']['original_captured_at'])")" = "('$PREV_TOKEN', '$PREV_AT')" ]
    # 稼働対象がいたので、正本は今回の実採取で置き換わる(失敗した役の穴へ前回 ID を混ぜない)
    [ "$(snap_py "(d['run_token'] == '$CLAUDE_RESUME_RUN_TOKEN', sorted(d['agents']))")" = "(True, ['shogun'])" ]
    [[ "${LOGS[*]}" == *"今回の採取で記録(正本)を更新"* ]]
    # 起動: shogun は従来の復旧経路、karo は直前確認つき
    [[ "$(shutsujin_launch_cmd shogun "$SID_CUR")" == "_csr_u=;"* ]]
    [[ "$(shutsujin_launch_cmd karo "$SID2")" == "if bash "*"--check-previous"* ]]
    # 直前確認: 今の計画なら通り、別 run の token・別の ID・previous でない agent は拒否
    use_mock_live true
    claude_resume_previous_check "$CLAUDE_RESUME_PLAN_FILE" "$CLAUDE_RESUME_RUN_TOKEN" karo "$SID2"
    run claude_resume_previous_check "$CLAUDE_RESUME_PLAN_FILE" "1790000001-1-x" karo "$SID2"
    [ "$status" -eq 1 ]
    [[ "$output" == *"plan_token_mismatch"* ]]
    run claude_resume_previous_check "$CLAUDE_RESUME_PLAN_FILE" "$CLAUDE_RESUME_RUN_TOKEN" karo "$SID3"
    [ "$status" -eq 1 ]
    [[ "$output" == *"plan_session_mismatch"* ]]
    run claude_resume_previous_check "$CLAUDE_RESUME_PLAN_FILE" "$CLAUDE_RESUME_RUN_TOKEN" shogun "$SID_CUR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"plan_entry_mismatch"* ]]
    # 一時ファイルを残さない(atomic な置換)
    [ "$(ls -A "$W/state" | grep -c '\.tmp$')" -eq 0 ]
}

@test "P796-11: 前回2役が同じ UUID・同じ bridge なら双方拒否、current と衝突した前回は拒否、current 同士の重複も双方拒否。先着で採らない" {
    setup_prev_world
    # 同じ UUID
    write_prev v2 "shogun=$SID1=$BR_S" "karo=$SID2=$BR_K" "ashigaru3=$SID2=$BR_K"
    run_prev
    [ "$(plan_of karo)" = "fresh:duplicate_previous" ]
    [ "$(plan_of ashigaru3)" = "fresh:duplicate_previous" ]
    [ "$(plan_of shogun)" = "previous_snapshot:$SID1" ]
    # 別 UUID・同じ bridge
    write_transcript_br "$SID3" "$BR_K"
    write_prev v2 "shogun=$SID1=$BR_S" "karo=$SID2=$BR_K" "ashigaru3=$SID3=$BR_K"
    run_prev
    [ "$(plan_of karo)" = "fresh:duplicate_previous" ]
    [ "$(plan_of ashigaru3)" = "fresh:duplicate_previous" ]
    write_transcript_br "$SID3" "$BR_A"
    write_prev v2
    # current と衝突: 稼働中の shogun の今回の採取が karo の前回 bridge を持つ
    # (計画時には既にいない=live 観測では見えない場合も、計画の重複排除で拒否する)
    SID_CUR="44444444-4444-4444-8444-444444444444"
    MOCK_TMUX_MODE=""
    MOCK_SESSIONS="shogun"
    MOCK_ROWS="shogun:0.0\t9100\tshogun\tclaude\n"
    MOCK_CHILD[9100]=$$
    write_record $$ shogun "$SID_CUR" "" "$BR_K"
    write_transcript "$SID_CUR"
    run_prev
    [ "$(plan_of shogun)" = "current:$SID_CUR" ]
    [ "$(plan_of karo)" = "fresh:conflict_current" ]
    [ "$(plan_of ashigaru3)" = "previous_snapshot:$SID3" ]
    # current 同士の重複(2役が同じ ID を採取された)は双方とも新規
    MOCK_SESSIONS="shogun multiagent"
    MOCK_ROWS="shogun:0.0\t9100\tshogun\tclaude\n"
    MOCK_ROWS+="multiagent:0.3\t9203\tashigaru3\tclaude\n"
    MOCK_CHILD[9203]=$PPID
    write_record $$ shogun "$SID_CUR" "" "session_01X1"
    write_record $PPID ashigaru3 "$SID_CUR" "" "session_01X2"
    run_prev
    [ "$(plan_of shogun)" = "fresh:duplicate_current" ]
    [ "$(plan_of ashigaru3)" = "fresh:duplicate_current" ]
}

@test "P796-12: 出陣が重なれば2本目は撤収の前に止まり、1本目の後は次の出陣が排他を取れる" {
    load_shutsujin_fns
    mkdir -p "$W/state"
    local hold="$W/hold_release" ready="$W/hold_ready"
    (
        shutsujin_resume_lock || exit 9
        : > "$ready"
        for _ in $(seq 1 200); do [ -e "$hold" ] && break; sleep 0.05; done
        shutsujin_resume_unlock
    ) &
    local first=$!
    for _ in $(seq 1 200); do [ -e "$ready" ] && break; sleep 0.05; done
    [ -e "$ready" ]
    run shutsujin_resume_lock
    [ "$status" -eq 1 ]
    LOGS=()
    shutsujin_resume_lock || true
    [ "$CLAUDE_RESUME_LOCK_HELD" = false ]
    [[ "${LOGS[*]}" == *"別の出陣が実行中(排他を取れない)。撤収の前に中止する"* ]]
    : > "$hold"
    wait "$first"
    shutsujin_resume_lock
    [ "$CLAUDE_RESUME_LOCK_HELD" = true ]
    shutsujin_resume_unlock
    [ "$CLAUDE_RESUME_LOCK_HELD" = false ]
    # resume 無効なら排他しない(従来どおり)
    load_libs "$W/settings_absent.yaml"
    shutsujin_resume_lock
    [ "$CLAUDE_RESUME_LOCK_HELD" = false ]
}

@test "P796-12a: 出陣スクリプトの順序: 排他 → 失敗なら exit → 採取 → 撤収。tmux server を起こし得る行は FD 9 を閉じ、常駐プロセスの前に排他を解く" {
    local lock snap kill
    lock=$(grep -n '^if ! shutsujin_resume_lock; then$' "$SHUTSUJIN" | cut -d: -f1)
    snap=$(grep -n '^shutsujin_claude_resume_snapshot || true$' "$SHUTSUJIN" | cut -d: -f1)
    kill=$(grep -n '^tmux kill-session' "$SHUTSUJIN" | head -1 | cut -d: -f1)
    [ "$(printf '%s\n' "$lock" | wc -l)" -eq 1 ]
    [ -n "$lock" ]
    sed -n "$((lock + 1))p" "$SHUTSUJIN" | grep -qE '^[[:space:]]+exit 1$'
    [ "$lock" -lt "$snap" ]
    [ "$snap" -lt "$kill" ]
    # tmux new-session は全て 9>&- 付き
    [ "$(grep -c 'tmux new-session' "$SHUTSUJIN")" -eq "$(grep 'tmux new-session' "$SHUTSUJIN" | grep -c '9>&-')" ]
    [ "$(grep -c 'tmux new-session' "$SHUTSUJIN")" -ge 2 ]
    # 排他を解く呼出し(finalize)は、最初の nohup(常駐プロセス)より前と、起動なし(-s)経路の後
    local fin_lines first_nohup gunshi_launch ntfy
    fin_lines=$(grep -n '^[[:space:]]*shutsujin_resume_finalize$' "$SHUTSUJIN" | cut -d: -f1)
    first_nohup=$(grep -n 'nohup ' "$SHUTSUJIN" | head -1 | cut -d: -f1)
    gunshi_launch=$(grep -nF 'shutsujin_resume_settle "multiagent:agents.${p}" gunshi' "$SHUTSUJIN" | cut -d: -f1)
    ntfy=$(grep -n 'nohup bash "$SCRIPT_DIR/scripts/ntfy_listener.sh"' "$SHUTSUJIN" | cut -d: -f1)
    [ "$(printf '%s\n' "$fin_lines" | wc -l)" -eq 2 ]
    [ "$(printf '%s\n' "$fin_lines" | head -1)" -gt "$gunshi_launch" ]
    [ "$(printf '%s\n' "$fin_lines" | head -1)" -lt "$first_nohup" ]
    [ "$(printf '%s\n' "$fin_lines" | tail -1)" -lt "$ntfy" ]
    # 全ての起動分岐(将軍・家老・決戦足軽・平時足軽・軍師)の送出の直後に settle がある
    [ "$(grep -c '^[[:space:]]*shutsujin_resume_settle ' "$SHUTSUJIN")" -eq 5 ]
    [ "$(grep -B1 '^[[:space:]]*shutsujin_resume_settle ' "$SHUTSUJIN" | grep -c 'CLI起動Enter" Enter || _launch_rc=1$')" -eq 5 ]
}

@test "P796-12b: 隔離tmux実機: 排他を持ったまま起こした tmux server へ FD 9(9>&-)を継承させず、解いた後は次の出陣が排他を取れる" {
    load_shutsujin_fns
    mkdir -p "$W/state"
    shutsujin_resume_lock
    [ "$CLAUDE_RESUME_LOCK_HELD" = true ]
    local helper="$PROJECT_ROOT/scripts/isolated_tmux.sh"
    HANDLE_FILE="$(bash "$helper" create -L csr796 9>&-)"
    [ -n "$HANDLE_FILE" ]
    local pane_pid server fd
    pane_pid="$(grep '^PANE_PID=' "$HANDLE_FILE" | cut -d= -f2-)"
    server=$(awk '{s=$0; sub(/.*\) /,"",s); split(s,a," "); print a[2]}' "/proc/$pane_pid/stat")
    [ -d "/proc/$server/fd" ]
    for fd in /proc/"$server"/fd/* /proc/"$pane_pid"/fd/*; do
        [ "$(readlink "$fd" 2>/dev/null)" != "$CLAUDE_RESUME_LOCK_FILE" ] || { echo "FD 漏れ: $fd"; return 1; }
    done
    shutsujin_resume_unlock
    # server が生きたままでも、次の出陣(別プロセス)は排他を取れる
    flock -n "$CLAUDE_RESUME_LOCK_FILE" true
}

@test "P796-12c: 送った前回由来の起動の記録を有限時間で確かめられなければ未確定として正本から外し、次の出陣はそれを使わない" {
    setup_prev_world
    run_prev
    [ "$CLAUDE_RESUME_PREV_REMAINING" -eq 3 ]
    CLAUDE_RESUME_SETTLE_SEC=1
    MOCK_PANE_PID=9300
    MOCK_CHILD[9300]=""            # 起動したはずの claude が見えない(遅延・失敗)
    SECONDS=0
    shutsujin_resume_settle shogun:main shogun claude 0
    [ "$SECONDS" -le 3 ]
    [ "${CLAUDE_RESUME_UNCONFIRMED[*]}" = "shogun" ]
    # 送れなかった pane は待たず、未確定にもしない
    shutsujin_resume_settle multiagent:agents.0 karo claude 1
    [ "${CLAUDE_RESUME_UNCONFIRMED[*]}" = "shogun" ]
    # 記録が出れば確定(未確定にしない)
    MOCK_CHILD[9300]=$$
    write_record $$ ashigaru3 "$SID3"
    shutsujin_resume_settle multiagent:agents.3 ashigaru3 claude 0
    [ "${CLAUDE_RESUME_UNCONFIRMED[*]}" = "shogun" ]
    [ "$CLAUDE_RESUME_PREV_REMAINING" -eq 0 ]
    shutsujin_resume_finalize
    [ "$CLAUDE_RESUME_LOCK_HELD" = false ]
    [ "$(snap_py "(sorted(d['agents']), [(w['agent_id'], w['reason']) for w in d['withdrawn']], d['run_token'], d['captured_at'])")" \
        = "(['ashigaru3', 'karo'], [('shogun', 'previous_launch_unconfirmed')], '$PREV_TOKEN', '$PREV_AT')" ]
    run_prev
    [ "$(plan_of shogun)" = "fresh:withdrawn" ]
    [ "$(plan_of karo)" = "previous_snapshot:$SID2" ]
}

@test "P796-12d: 選択の後に使用者が現れたら直前確認が拒否し、新規起動は1回だけ(bash・sh)" {
    setup_prev_world
    run_prev
    make_fakes
    # 選択の後に、同じ ID の使用者が現れた
    use_mock_live true "ashigaru9=$SID2=session_01Unrelated"
    run claude_resume_previous_check "$CLAUDE_RESUME_PLAN_FILE" "$CLAUDE_RESUME_RUN_TOKEN" karo "$SID2"
    [ "$status" -eq 1 ]
    [[ "$output" == *"前回記録の直前確認で拒否: session_in_use (agent=karo)"* ]]
    # 判定不能の生存 Claude が現れた時も拒否
    use_mock_live false
    run claude_resume_previous_check "$CLAUDE_RESUME_PLAN_FILE" "$CLAUDE_RESUME_RUN_TOKEN" karo "$SID2"
    [ "$status" -eq 1 ]
    [[ "$output" == *"live_unknown"* ]]
    # 拒否された1行は新規起動を1回だけ(resume は起動しない)
    local cmd sh
    cmd=$(shutsujin_launch_cmd karo "$SID2")
    for sh in bash sh; do
        : > "$FAKE_LOG"
        FAKE_FRESH_RC=1 run run_launch "$sh" "$(inject_check "$cmd" false)"
        [ "$(fake_calls)" -eq 1 ]
        [[ "$(fake_argv 1)" != *"--resume"* ]]
        [[ "$output" == *"前回記録の直前確認で拒否されたため、従来の新規起動にする (1回のみ)"* ]]
    done
}

@test "P796-12e: pane の直前確認の入口(bash lib --check-previous)は本物の /proc を読み、差し替えの口を持たない" {
    setup_prev_world
    run_prev
    local lib="$CSR_LIB"
    # 引数の形が違えば拒否・使い方の誤りは rc=2
    run bash "$lib" --check-previous "$CLAUDE_RESUME_PLAN_FILE" "bad token" karo "$SID2"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid_argument"* ]]
    run bash "$lib"
    [ "$status" -eq 2 ]
    # 別 run の token
    run bash "$lib" --check-previous "$CLAUDE_RESUME_PLAN_FILE" "1790000001-1-x" karo "$SID2"
    [ "$status" -eq 1 ]
    [[ "$output" == *"plan_token_mismatch"* ]]
    # 候補 ID を、照合の通る記録を持つ生存 claude が使っている → 拒否(本物の観測)
    mkdir -p "$W/bin"
    ln -s "$(command -v sleep)" "$W/bin/claude"
    "$W/bin/claude" 8 &
    local c=$!
    write_record "$c" ashigaru9 "$SID2" "" "session_01Unrelated"
    # Python の差し替え(CLAUDE_RESUME_PYTHON)も、関数の export も効かない
    printf '#!/bin/sh\nexit 0\n' > "$W/bin/fakepy"
    chmod +x "$W/bin/fakepy"
    claude_resume_live_observe() { echo '{"ok": true, "reasons": [], "procs": []}'; }
    export -f claude_resume_live_observe
    CLAUDE_RESUME_PYTHON="$W/bin/fakepy" run bash "$lib" --check-previous "$CLAUDE_RESUME_PLAN_FILE" "$CLAUDE_RESUME_RUN_TOKEN" karo "$SID2"
    export -n -f claude_resume_live_observe
    [ "$status" -eq 1 ]
    [[ "$output" == *"session_in_use (agent=karo)"* ]]
    wait "$c"
}

@test "P796-13: 同じ boot は単調時計で年齢を測り(現実時計の3秒逆行に左右されない)、boot が違えば uptime を引かない。uptime の逆行・読めない・boot_id 読めないは拒否、旧形式は制限を残す" {
    setup_prev_world
    PREV_BOOT="$BOOT_NOW"
    PREV_UPTIME="100.0"
    # 同じ boot: 年齢は 500-100=400 秒。採取時刻(現実時計)は「3秒先」に見えるが使わない
    PREV_AT=$(iso_of $((NOW + 3)))
    write_prev v2
    run_prev
    [ "$(plan_of karo)" = "previous_snapshot:$SID2" ]
    [ "$(plan_py "(d['agents']['karo']['age_basis'], d['agents']['karo']['age_seconds'])")" = "('uptime_same_boot', 400)" ]
    # 同じ boot で単調時計の年齢が7日ちょうど/7日+1秒(現実時計では1時間前)
    PREV_AT=$(iso_of $((NOW - 3600)))
    PREV_UPTIME="100.0"
    write_prev v2
    use_mock_clock "$NOW" "604900.00" "$BOOT_NOW"
    run_prev
    [ "$(plan_of karo)" = "previous_snapshot:$SID2" ]
    use_mock_clock "$NOW" "604901.00" "$BOOT_NOW"
    run_prev
    [ "$(plan_of karo)" = "fresh:snapshot_stale" ]
    # 同じ boot で uptime が逆行・読めない・boot_id が読めない
    use_mock_clock "$NOW" "99.00" "$BOOT_NOW"
    run_prev
    [ "$(plan_of karo)" = "fresh:uptime_regressed" ]
    use_mock_clock "$NOW" "-" "$BOOT_NOW"
    run_prev
    [ "$(plan_of karo)" = "fresh:uptime_unreadable" ]
    use_mock_clock "$NOW" "500.00" "-"
    run_prev
    [ "$(plan_of karo)" = "fresh:boot_id_unreadable" ]
    # 別の boot: 前 boot の uptime(今より大きい)を引かず、現実時計で測る
    PREV_BOOT="$BOOT_OLD"
    PREV_UPTIME="999999.0"
    write_prev v2
    use_mock_clock "$NOW" "500.00" "$BOOT_NOW"
    run_prev
    [ "$(plan_py "(d['agents']['karo']['source'], d['agents']['karo']['age_basis'], d['agents']['karo']['age_seconds'])")" = "('previous_snapshot', 'wallclock_other_boot', 3600)" ]
    # 別の boot で現実時計が採取時刻より前(未来の採取時刻)なら拒否
    PREV_AT=$(iso_of $((NOW + 3)))
    write_prev v2
    run_prev
    [ "$(plan_of karo)" = "fresh:snapshot_future" ]
    # 旧形式(boot_id・uptime なし)は現実時計で測り、由来に制限を残す
    PREV_AT=$(iso_of $((NOW - 3600)))
    write_prev legacy
    run_prev
    [ "$(plan_py "d['agents']['karo']['age_basis']")" = "wallclock_legacy" ]
    [[ "${LOGS[*]}" == *"basis=wallclock_legacy"* ]]
}

@test "P796-14: 出陣の全経路で、前回由来の起動だけが直前確認つき。固定の1語・resume/新規の照合は不変、送出ごとに settle、Codex は不変" {
    cat > "$W/settings_launch.yaml" <<'YAML'
cli:
  default: claude
  claude_session_resume: true
  claude_session_resume_previous_snapshot: true
  agents:
    shogun: {type: claude, model: opus}
    karo: {type: claude, model: sonnet}
    gunshi: {type: claude, model: opus}
    ashigaru1: {type: codex, model: gpt-6-luna}
    ashigaru2: {type: claude, model: sonnet --effort xhigh}
YAML
    load_shutsujin_fns
    make_fakes
    PERMISSION_FLAG="--dangerously-skip-permissions"
    declare -gA MOCK_RESUME=()
    local kessen nothink pane want
    for kessen in false true; do
        for nothink in false true; do
            cp "$W/settings_launch.yaml" "$W/settings_run.yaml"
            load_libs "$W/settings_run.yaml"
            KESSEN_MODE=$kessen SHOGUN_NO_THINKING=$nothink
            # 計画: 将軍・足軽2 は前回由来、家老は current、軍師は新規
            CLAUDE_RESUME_RUN_TOKEN="1790000002-7-dddddddd-dddd-4ddd-8ddd-dddddddddddd"
            CLAUDE_RESUME_PLAN_SOURCE=([shogun]=previous_snapshot [ashigaru2]=previous_snapshot [karo]=current)
            CLAUDE_RESUME_PLAN_SID=([shogun]="$SID1" [ashigaru2]="$SID3" [karo]="$SID2")
            MOCK_RESUME=([shogun]="$SID1" [karo]="$SID2" [ashigaru2]="$SID3" [ashigaru1]="$SID1")
            SETTLE=()
            shutsujin_resume_settle() { SETTLE+=("$1|$2|$3|$4"); }
            run_launch_block
            ! grep -q '理由:\|許可リスト' "$W/launch_err" || { cat "$W/launch_err"; return 1; }
            [ "${#LAUNCH[@]}" -eq 5 ]
            # 送出の直後に毎回 settle(pane・役・CLI・送出の rc)
            [ "${SETTLE[*]}" = "shogun:main|shogun|claude|0 multiagent:agents.0|karo|claude|0 multiagent:agents.1|ashigaru1|codex|0 multiagent:agents.2|ashigaru2|claude|0 multiagent:agents.3|gunshi|claude|0" ] || { echo "${SETTLE[*]}"; return 1; }
            eval "$(extract_fn shutsujin_resume_settle)"
            for pane in shogun:main multiagent:agents.2; do
                [ "$(printf '%s' "${LAUNCH[$pane]}" | grep -o -F -- '--check-previous' | wc -l)" -eq 1 ] || { echo "$pane: ${LAUNCH[$pane]}"; return 1; }
            done
            for pane in multiagent:agents.0 multiagent:agents.1 multiagent:agents.3; do
                [[ "${LAUNCH[$pane]}" != *"--check-previous"* ]] || { echo "$pane"; return 1; }
            done
            # 直前確認が通れば従来の resume(起動直後失敗なら同じ従来引数の新規へ1回)
            check_claude_launch "将軍(prev,kessen=$kessen,nothink=$nothink)" "$(inject_check "${LAUNCH[shogun:main]}" true)" "$SID1" "$([ "$nothink" = true ] && echo 0)"
            check_claude_launch "足軽2(prev,kessen=$kessen)" "$(inject_check "${LAUNCH[multiagent:agents.2]}" true)" "$SID3" ""
            # 拒否なら新規起動を1回だけ(固定の1語つき・同じ従来引数)
            : > "$FAKE_LOG"
            run_launch bash "$(inject_check "${LAUNCH[multiagent:agents.2]}" false)" >/dev/null 2>&1 || true
            [ "$(fake_calls)" -eq 1 ]
            [[ "$(fake_argv 1)" == *"--name ashigaru2 "*"--dangerously-skip-permissions $TOK" ]]
            [[ "$(fake_argv 1)" != *"--resume"* ]]
            check_claude_launch "家老(current)" "${LAUNCH[multiagent:agents.0]}" "$SID2" ""
            check_claude_launch "軍師(fresh)" "${LAUNCH[multiagent:agents.3]}" "" ""
            [ "${LAUNCH[multiagent:agents.1]}" = "$(build_cli_command ashigaru1)" ]
        done
    done
}

@test "P796-14a: 隔離tmux実機: 直前確認の後の claude も、拒否の後の新規起動も pane のシェルの直接の子" {
    setup_prev_world
    run_prev
    # 子プロセス探索などの代替を外す(計画は作成済み。ここからは本物の pane を観測する)
    load_libs "$W/settings_prev.yaml"
    make_fakes
    local helper="$PROJECT_ROOT/scripts/isolated_tmux.sh"
    HANDLE_FILE="$(bash "$helper" create -L csr796b)"
    [ -n "$HANDLE_FILE" ]
    local sock pane pane_pid child="" args="" i cmd want
    sock="$(grep '^SOCKET_PATH=' "$HANDLE_FILE" | cut -d= -f2-)"
    pane="$(grep '^PANE_ID=' "$HANDLE_FILE" | cut -d= -f2-)"
    pane_pid="$(grep '^PANE_PID=' "$HANDLE_FILE" | cut -d= -f2-)"
    FAKE_HOLD_DIR="$W/hold"
    mkdir -p "$FAKE_HOLD_DIR"
    command tmux -S "$sock" send-keys -t "$pane" \
        "export PATH=${FAKEBIN}:\$PATH FAKE_LOG=${FAKE_LOG} FAKE_DATE_LOG=${FAKE_DATE_LOG} FAKE_HOLD_DIR=${FAKE_HOLD_DIR} FAKE_RESUME_SLEEP=0 FAKE_RESUME_RC=0 FAKE_FRESH_SLEEP=0 FAKE_FRESH_RC=0" Enter
    cmd=$(shutsujin_launch_cmd karo "$SID2")
    # 1) 直前確認が通る → resume の claude が pane の直接の子
    command tmux -S "$sock" send-keys -t "$pane" "$(inject_check "$cmd" true)" Enter
    for i in $(seq 1 50); do
        child=$(claude_resume_child_claude_pid "$pane_pid")
        [ -n "$child" ] && args=$(ps -o args= -p "$child" 2>/dev/null || true)
        [[ "$args" == *"--resume $SID2"* ]] && break
        sleep 0.1
    done
    [[ "$args" == *"--resume $SID2 --model sonnet --name karo"* ]]
    : > "$FAKE_HOLD_DIR/release.1"
    for i in $(seq 1 60); do
        [ -z "$(claude_resume_child_claude_pid "$pane_pid")" ] && break
        sleep 0.1
    done
    # 2) 直前確認が拒否 → 新規起動が pane の直接の子(resume は起動しない)
    args=""
    command tmux -S "$sock" send-keys -t "$pane" "$(inject_check "$cmd" false)" Enter
    want="claude --model sonnet --name karo --dangerously-skip-permissions $TOK"
    for i in $(seq 1 50); do
        child=$(claude_resume_child_claude_pid "$pane_pid")
        [ -n "$child" ] && args=$(ps -o args= -p "$child" 2>/dev/null || true)
        [[ "$args" == *"$want" ]] && break
        sleep 0.1
    done
    [[ "$args" == *"$want" ]]
    : > "$FAKE_HOLD_DIR/release.2"
    for i in $(seq 1 60); do
        [ -z "$(claude_resume_child_claude_pid "$pane_pid")" ] && break
        sleep 0.2
    done
    [ -z "$(claude_resume_child_claude_pid "$pane_pid")" ]
    [ "$(fake_calls)" -eq 2 ]
}

@test "P796-15: 前回由来の resume が 29/30 秒・rc 0/1/127/128/255 で終わる時と新規側も失敗する時の復旧は従来と同じ有限(2回目の新規・ループなし)" {
    setup_prev_world
    run_prev
    make_fakes
    local cmd ok rc
    cmd=$(shutsujin_launch_cmd karo "$SID2")
    ok=$(inject_check "$cmd" true)
    export FAKE_RESUME_RC=1
    : > "$FAKE_LOG"; run run_launch_up bash "$ok" "1000.00 5.00" "1029.00 5.00"
    [ "$(fake_calls)" -eq 2 ]
    [ "$(fake_argv 1)" = "--resume $SID2 $(fake_argv 2)" ]
    : > "$FAKE_LOG"; run run_launch_up bash "$ok" "1000.00 5.00" "1030.00 5.00"
    [ "$(fake_calls)" -eq 1 ]
    for rc in 0 1 127 128 255; do
        : > "$FAKE_LOG"
        FAKE_RESUME_RC=$rc run run_launch sh "$ok"
        case "$rc" in
            1|127) [ "$(fake_calls)" -eq 2 ] || { echo "rc=$rc"; return 1; } ;;
            *)     [ "$(fake_calls)" -eq 1 ] || { echo "rc=$rc"; return 1; } ;;
        esac
    done
    # 新規側も起動直後に失敗しても計2回
    : > "$FAKE_LOG"
    FAKE_RESUME_RC=1 FAKE_FRESH_RC=1 run run_launch bash "$ok"
    [ "$status" -eq 1 ]
    [ "$(fake_calls)" -eq 2 ]
    # 拒否側の新規起動が失敗しても、もう1回は起動しない
    : > "$FAKE_LOG"
    FAKE_FRESH_RC=1 run run_launch bash "$(inject_check "$cmd" false)"
    [ "$(fake_calls)" -eq 1 ]
    # 生成は1行・履歴展開の ! を含まない・新規起動の出現は then 節の復旧と else 節の各1つ
    [ "$(printf '%s\n' "$cmd" | wc -l)" -eq 1 ]
    [[ "$cmd" != *'!'* ]]
    [ "$(printf '%s' "$cmd" | grep -o -F "$(build_cli_command karo)" | wc -l)" -eq 2 ]
    [ "$(printf '%s' "$cmd" | grep -o -F -- "--resume $SID2" | wc -l)" -eq 1 ]
}

@test "P796-15a: 前回由来の起動を組めない入力(パス・token・役名・ID の形式、包めない起動コマンド)は直前確認を付けず新規起動だけ" {
    make_fakes
    local plan="$W/state/claude_session_plan.yaml" tok="1790000002-7-x" out err
    check_plain_prev() {   # <plan> <token> <agent> <sid> <resume> <fresh> <理由>
        out=$(claude_resume_previous_launch_cmd "$1" "$2" "$3" "$4" "$5" "$6" 2>/dev/null)
        err=$(claude_resume_previous_launch_cmd "$1" "$2" "$3" "$4" "$5" "$6" 2>&1 >/dev/null)
        [ "$out" = "$6" ] || { echo "out=[$out]"; return 1; }
        [[ "$err" == *"理由: $7"* ]] || { echo "err=[$err]"; return 1; }
    }
    check_plain_prev "$W/st ate/plan.yaml" "$tok" karo "$SID1" "$RESUME_KARO" "$FRESH_KARO" unsafe_path
    check_plain_prev "relative/plan.yaml" "$tok" karo "$SID1" "$RESUME_KARO" "$FRESH_KARO" unsafe_path
    check_plain_prev "$plan" 'tok;x' karo "$SID1" "$RESUME_KARO" "$FRESH_KARO" invalid_token
    check_plain_prev "$plan" "$tok" 'karo;x' "$SID1" "$RESUME_KARO" "$FRESH_KARO" invalid_agent_id
    check_plain_prev "$plan" "$tok" karo "${SID_DECOY^^}" "$RESUME_KARO" "$FRESH_KARO" invalid_session_id
    check_plain_prev "$plan" "$tok" karo "$SID1" "$FRESH_KARO" "$FRESH_KARO" launch_cmd_unwrapped
    # 正しい入力なら、直前確認 → 従来の1行(claude_resume_launch_cmd)/新規1回
    out=$(claude_resume_previous_launch_cmd "$plan" "$tok" karo "$SID1" "$RESUME_KARO" "$FRESH_KARO")
    [ "$out" = "if bash ${CLAUDE_RESUME_LIB_DIR}/claude_session_resume.sh --check-previous $plan $tok karo $SID1; then $(claude_resume_launch_cmd "$SID1" "$RESUME_KARO" "$FRESH_KARO"); else echo \"[shutsujin] 前回記録の直前確認で拒否されたため、従来の新規起動にする (1回のみ)\"; $FRESH_KARO; fi" ]
}
