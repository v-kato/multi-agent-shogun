#!/usr/bin/env bats
# test_clear_send_gate.bats — 三重条件つき `/clear` 送信の単体テスト (cmd_757②)
#
# 背景:
#   cmd_754 E-1 は「agent CLI 稼働 pane への自動打鍵の安全集合を空にせよ」と
#   裁定した。★その裁定は生きている。本ファイルが検査するのは、その空集合の
#   ★上に積まれた「一命令・二条件」の限定例外である。
#
#   cmd_757① の実測(隔離環境・複数種のモーダル・反例0)により、確認モーダル
#   表示中のセッションは mesh へ `waiting`/"permission prompt" と申告し
#   `idle` とは申告しないことが分かった。将軍はこれを根拠に一点だけ開けた。
#
# ★★本ファイルが最も強く検査すること (fail-closed):
#   1. 判定が★肯定形(「idle である」)で書かれていること。否定形
#      (「idle でない」)で書くと★未知の状態語がすり抜けて通ってしまう。
#   2. `idle` 以外の一切 — waiting/busy/shell/未知語/取得失敗 — が
#      ★送らない側へ落ちること。
#   3. 条件2 が★「危険の否認」と★「唯一許可された既知の安全形への一致」に
#      留まり、★単独では許可を生まないこと。★未知の画面は一律不許可。
#   4. 送りうる命令が `/clear` ただ一つであること(★claude 以外の CLI は
#      redo1 で閉じた。`/new` は送らない)。
#      ★nudge(裸の Enter)・model_switch・cli_restart は対象外のままであること。
#   5. ★redo2: 宛先が入口で★一度だけ canonical pane_id(`%N`)へ解決され、
#      以後の検査も打鍵も★その不変 ID しか使わないこと。
#   6. ★redo2: `agent_id` が必須であり、pane の `@agent_id` へ束縛されること。
#
# テスト構成:
#   ── 条件3: 送ってよい命令はただ一つ ──
#   T-CG-001: gate_permitted_command_count は 1 を返す
#   T-CG-002: CLI 別の context reset の綴りが正しい
#   T-CG-003: 未知の CLI は空 + rc=1 (fail-closed)
#   T-CG-004: 条件3 は綴りの完全一致のみ許す
#   T-CG-005: 裸の Enter・C-u・任意文字列は許さない
#   T-CG-008: gate_permitted_cli_count は 1 (claude のみ)
#   T-CG-009: ★claude 以外の CLI は綴りを返さない (redo1 で閉じた)
#   T-CG-006: gate_type_is_in_scope は clear_command のみ通す
#   T-CG-007: nudge / model_switch / cli_restart は対象外である
#   ── 条件1: 本人の申告が idle であること (肯定形・fail-closed) ──
#   T-CG-010: idle かつ滞留十分なら許可される
#   T-CG-011: waiting (permission prompt) は不許可
#   T-CG-012: busy は不許可
#   T-CG-013: shell は不許可
#   T-CG-014: ★未知の状態語は不許可 (否定形で書いていれば通ってしまう)
#   T-CG-015: ★未知の状態語は記録され人経路へ上がる
#   T-CG-016: mesh 記録が無ければ不許可 (信頼ダイアログ相当・①の実測)
#   T-CG-017: pane identity が読めなければ不許可
#   T-CG-018: procStart 不一致 (pid 再利用) は不許可
#   T-CG-019: pid が生きていなければ不許可
#   T-CG-020: 滞留不足 (idle になった直後) は不許可
#   T-CG-021: 同一 pane に複数記録が一致すれば曖昧ゆえ不許可
#   T-CG-022: 別 pane の記録には引きずられない (束縛の検査)
#   T-CG-023: ★実装が否定形 `!= "idle"` を使っていない (静的検査)
#   ── 束縛: 呼出側の cli を pane の実体へ突き合わせる (redo1) ──
#   T-CG-024: claude 実体が pane 配下にあるとき許可
#   T-CG-025: ★cli が claude 以外なら不許可 (権威源が無い)
#   T-CG-026: pane の実体が claude でなければ不許可
#   T-CG-027: pid が pane の子孫でなければ不許可
#   T-CG-028: pane_pid が読めなければ不許可
#   T-CG-029: pid が数値でなければ不許可
#   ── 条件2: 危険の否認のみ (安全の証明ではない) ──
#   T-CG-030: モーダルが見えたら拒否する (事故当日の `❯ 1. Yes`)
#   T-CG-031: 各種モーダル定型でも拒否する
#   T-CG-032: capture 失敗は拒否 (読めないことは安全ではない)
#   T-CG-033: capture が空なら拒否
#   T-CG-034: 素の画面では拒否権を行使しない (rc=0)
#   T-CG-035: ★条件2 の rc=0 は単独では送信を生まない
#   T-CG-036: ★軍師 probe の未収載モーダルは不許可 (redo1 の核)
#   T-CG-037: ★未知の画面は危険パターンに無くとも一律不許可
#   T-CG-038: 許可されるのは「空のプロンプト行のみ」の形だけ
#   T-CG-039: 許可形の種類数は 1
#   ── 三条件の合成 ──
#   T-CG-040: 三条件充足で /clear がちょうど1回送られる
#   T-CG-041: 条件1 非充足なら送らない
#   T-CG-042: 条件2 非充足なら送らない
#   T-CG-043: 条件3 非充足 (未知 CLI) なら送らない
#   T-CG-044: 送信は text+Enter を1回の send-keys で行う
#   T-CG-045: C-u (入力欄クリア) を送らない
#   T-CG-046: 打鍵直前に条件1 を再読する (TOCTOU の窓を詰める)
#   T-CG-047: 再読で waiting へ変わっていたら送らない
#   T-CG-048: ★codex/opencode/copilot/kimi は送らない (redo1)
#   T-CG-049: ★inbox_type が clear_command でなければ送信口で落ちる
#   T-CG-049b: ★inbox_type 未指定なら送らない (必須引数)
#   T-CG-049c: ★scope は送信直前にも再度強制される (静的検査)
#   T-CG-049d: ★束縛を欠く pane へは送らない
#   ── cmd_754 の土台が無傷であること ──
#   T-CG-050: pane_preflight の安全集合は今も空 (0)
#   T-CG-051: pane_send_preflight は今も常に送信禁止
#   T-CG-052: inbox_watcher に tmux send-keys は今も1つも無い
#   T-CG-053: 本ライブラリの send-keys は1箇所だけである
#   T-CG-054: 本ライブラリは nudge/model_switch/cli_restart を送らない
#   ── 明記事項 (軍師の限定・将軍裁定より) ──
#   T-CG-060: 「idle は十分条件でない」旨が実装コメントに在る
#   T-CG-061: 条件2 が「危険の否認」である旨が実装コメントに在る
#   T-CG-062: docs にも同じ2点が在る
#   T-CG-063: cmd_754 を「破棄」ではなく「上に積む」と書いてある
#   T-CG-064: ★許可リスト型が「安全の証明」ではない旨が実装コメントに在る
#   T-CG-065: docs にも redo1 の4点が書かれている
#   ── ★redo2: 宛先の固定 (canonical pane_id) ──
#   T-CG-070: ★index 再束縛を模擬しても検査した pane 以外へは送らない
#   T-CG-071: canonical pane_id が読めない/形不正なら送らない
#   T-CG-072: ★送信口は pane_target を canonical 解決にのみ使う (静的検査)
#   ── ★redo2: agent_id の必須化と実体束縛 ──
#   T-CG-073: agent_id 未指定なら送らない (必須引数)
#   T-CG-074: pane が @agent_id を持たねば送らない
#   T-CG-075: agent_id が pane の実体と不一致なら送らない
#   T-CG-076: wrapper は4引数未満を引数不正で拒む
#   T-CG-077: ★未知状態通知は pane の実体 @agent_id で分岐する
#   T-CG-078: agent_id 束縛は打鍵直前にも再確認される
#   ── ★redo2: 旧文言の除去 (負の静的試験) ──
#   T-CG-066: ★旧 blacklist 一般化・実装と矛盾する記述が0件であること
#   T-CG-067: docs に redo2 の2点が書かれている
#   ── 未知状態通知の宛先 (redo1) ──
#   T-CG-055: 分岐の契約 (家老・将軍は軍師へ)
#   T-CG-056: ★家老が対象なら軍師 inbox + ntfy
#   T-CG-057: ★将軍が対象でも軍師 inbox + ntfy
#   T-CG-058: 足軽が対象なら家老 inbox のみ

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export GATE_LIB="$PROJECT_ROOT/lib/clear_send_gate.sh"
    export PREFLIGHT_LIB="$PROJECT_ROOT/lib/pane_preflight.sh"
    export WATCHER_SCRIPT="$PROJECT_ROOT/scripts/inbox_watcher.sh"
    export DELIVERY_DOC="$PROJECT_ROOT/docs/delivery_channels.md"
    [ -f "$GATE_LIB" ] || return 1
    [ -f "$PREFLIGHT_LIB" ] || return 1
    command -v jq >/dev/null 2>&1 || return 1
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/gate_test.XXXXXX")"
    export MOCK_LOG="$TEST_TMPDIR/tmux_calls.log"
    export SENDKEYS_LOG="$TEST_TMPDIR/sendkeys.log"
    export FAKE_SESSIONS="$TEST_TMPDIR/sessions"
    export FAKE_ROOT="$TEST_TMPDIR/fake_root"
    export UNKNOWN_LOG="$TEST_TMPDIR/unknown_state.log"
    export INBOX_WRITE_LOG="$TEST_TMPDIR/inbox_write.log"
    export NTFY_LOG="$TEST_TMPDIR/ntfy.log"
    mkdir -p "$FAKE_SESSIONS" "$FAKE_ROOT/scripts"
    > "$MOCK_LOG"
    > "$SENDKEYS_LOG"

    # ── 人経路のモック (家老 inbox への通知を記録する) ──
    cat > "$FAKE_ROOT/scripts/inbox_write.sh" << 'FAKE'
#!/bin/bash
echo "target=$1 type=$3 from=$4" >> "$INBOX_WRITE_LOG"
echo "content=$2" >> "$INBOX_WRITE_LOG"
exit 0
FAKE
    chmod +x "$FAKE_ROOT/scripts/inbox_write.sh"

    # ── 殿への経路 (ntfy) のモック ──
    cat > "$FAKE_ROOT/scripts/ntfy.sh" << 'FAKENTFY'
#!/bin/bash
echo "ntfy=$1" >> "$NTFY_LOG"
exit 0
FAKENTFY
    chmod +x "$FAKE_ROOT/scripts/ntfy.sh"

    # ── ★pane の実体として振る舞う「claude という名の子プロセス」 ──
    #   `gate_cli_bound_to_pane` は argv[0] の basename が `claude` である
    #   ことと、その pid が pane_pid の子孫であることを★カーネル(/proc)が
    #   持つ事実として検査する。ゆえに試験でも★本物の子プロセスを立てる
    #   (内部関数を差し替えて偽の緑を作らない)。
    #   ★D006-E1 Branch 1 準拠: 同一 invocation が直接 spawn した子であり、
    #     PID は spawn 直後に `$!` から専用変数へ捕捉し以後再代入しない。
    #     teardown が送る signal はこの★単一の正の PID のみを対象とする。
    #   ★F004是正(cmd_757②redo3・G757-CLEAR-F004-POLLING-REDO2-02):
    #     旧実装は `bash -c 'exec -a claude sleep 900'` で子を立て、
    #     「bash起動→exec -aでargv[0]をclaudeへ書き換える」という二段階が
    #     終わるのを最大500回のbusy pollingで待っていた(F004違反)。
    #     `claude`という名のsymlink経由でsleepを直接execすれば、spawn
    #     直後からargv[0]が`claude`であり、★待ち合わせという行為自体が
    #     要らなくなる(race自体を無くす。実測: symlink実行直後の
    #     /proc/PID/cmdline 第一要素のbasenameは即座に`claude`である)。
    ln -sf "$(command -v sleep)" "$TEST_TMPDIR/claude"
    "$TEST_TMPDIR/claude" 900 &
    export FAKE_CLAUDE_PID=$!
    export FAKE_CLAUDE_START="$(awk '{print $22}' "/proc/$FAKE_CLAUDE_PID/stat")"

    # ── 生きている pid とその procStart (pid 再利用検査の突き合わせ用) ──
    #   ★申告主は上の「claude という名の」子プロセスとする。
    export LIVE_PID="$FAKE_CLAUDE_PID"
    export LIVE_PROCSTART="$FAKE_CLAUDE_START"
    # ★その親 pid。tmux モックが `#{pane_pid}` として返す値であり、
    #   束縛検査(子孫であること)はこれを頂点として歩く。
    export LIVE_PANE_PID="$(awk '{print $2}' <<< "$(sed 's/^.*) //' "/proc/$FAKE_CLAUDE_PID/stat")")"
    # 存在しない pid (kill -0 が失敗する値)
    export DEAD_PID="999999999"

    export PANE_IDENT="multiagent:@1.%9"
    export PANE_TARGET="multiagent:0.9"
    # ★redo2: 送信口は入口で pane_target を canonical pane_id へ解決し、
    #   以後の検査も打鍵も★この不変 ID だけを使う。
    export PANE_ID="%9"

    # ── tmux モック制御 ──
    export MOCK_PANE_IDENT="$PANE_IDENT"
    export MOCK_IDENT_RC=0
    export MOCK_PANE_ID="$PANE_ID"
    # ★pane が tmux に持たせている `@agent_id`(呼出側の申告ではない事実)。
    export MOCK_PANE_AGENT_ID="ashigaru7"
    export MOCK_PANE_PID="$LIVE_PANE_PID"
    # ★既定の画面は「唯一許可された既知の安全形」= 空のプロンプト行のみ。
    #   redo1 で条件2 を許可リスト型へ転換したため、これ以外の画面は
    #   (危険パターンに一致せずとも)全て不許可となる。
    export MOCK_CAPTURE="> "
    export MOCK_CAPTURE_RC=0
    export MOCK_SENDKEYS_RC=0

    export GATE_HARNESS="$TEST_TMPDIR/gate_harness.sh"
    cat > "$GATE_HARNESS" << HARNESS
#!/bin/bash
tmux() {
    echo "tmux \$*" >> "$MOCK_LOG"
    case "\$*" in
        *pane_pid*)
            printf '%s\n' "\${MOCK_PANE_PID-}"
            return 0
            ;;
        *session_name*)
            [ "\${MOCK_IDENT_RC:-0}" -ne 0 ] && return "\${MOCK_IDENT_RC}"
            printf '%s\n' "\${MOCK_PANE_IDENT-}"
            return 0
            ;;
        *@agent_id*)
            printf '%s\n' "\${MOCK_PANE_AGENT_ID-}"
            return 0
            ;;
        *pane_id*)
            printf '%s\n' "\${MOCK_PANE_ID-}"
            return 0
            ;;
        *capture-pane*)
            [ "\${MOCK_CAPTURE_RC:-0}" -ne 0 ] && return "\${MOCK_CAPTURE_RC}"
            printf '%s\n' "\${MOCK_CAPTURE-}"
            return 0
            ;;
        *send-keys*)
            echo "\$*" >> "$SENDKEYS_LOG"
            return "\${MOCK_SENDKEYS_RC:-0}"
            ;;
    esac
    return 0
}
timeout() { shift; "\$@"; }
export -f tmux timeout
export GATE_SESSIONS_DIR="$FAKE_SESSIONS"
export GATE_PROJECT_ROOT="$FAKE_ROOT"
export GATE_UNKNOWN_STATE_LOG="$UNKNOWN_LOG"
source "$GATE_LIB"
HARNESS
    chmod +x "$GATE_HARNESS"
}

teardown() {
    # ★D006-E1 Branch 1: setup が直接 spawn した子へ、spawn 直後に `$!` から
    #   捕捉した★単一の正の PID だけへ signal を送る。送る前に、その PID が
    #   ★今も同じ未回収の子であることを starttime の一致で確かめる
    #   (pid 再利用による誤爆を防ぐ)。broadcast は用いない。
    if [ -n "${FAKE_CLAUDE_PID:-}" ] && kill -0 "$FAKE_CLAUDE_PID" 2>/dev/null; then
        local now_start
        now_start="$(awk '{print $22}' "/proc/$FAKE_CLAUDE_PID/stat" 2>/dev/null || echo "")"
        if [ -n "$now_start" ] && [ "$now_start" = "${FAKE_CLAUDE_START:-}" ]; then
            kill "$FAKE_CLAUDE_PID" 2>/dev/null || true
            wait "$FAKE_CLAUDE_PID" 2>/dev/null || true
        fi
    fi
    rm -rf "$TEST_TMPDIR"
}

# mk_session <name> <status> <waitingFor> <age_ms> [pid] [procStart] [tmux_ident]
# mesh の申告ファイルを1つ作る。age_ms は「その状態になってからの経過」。
mk_session() {
    local name="$1" status="$2" waiting="$3" age_ms="$4"
    local pid="${5:-$LIVE_PID}" procstart="${6:-$LIVE_PROCSTART}" ident="${7:-$PANE_IDENT}"
    local now_ms updated
    now_ms="$(date +%s%3N)"
    updated=$(( now_ms - age_ms ))
    cat > "$FAKE_SESSIONS/${name}.json" << JSON
{"pid":${pid},"sessionId":"test-${name}","cwd":"/home/kato/shogun","procStart":"${procstart}","kind":"interactive","tmux":"${ident}","name":"test","status":"${status}","waitingFor":${waiting},"updatedAt":${updated},"statusUpdatedAt":${updated}}
JSON
}

# ═══════════════════════════════════════════════════════
# 条件3 — 送ってよい命令はただ一つ
# ═══════════════════════════════════════════════════════

@test "T-CG-001: gate_permitted_command_count は 1 を返す (一命令)" {
    run bash -c "source '$GATE_LIB' && gate_permitted_command_count"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

@test "T-CG-002: context reset の綴りは claude → /clear ただ一つ" {
    run bash -c "source '$GATE_LIB' && gate_reset_command_for_cli claude"
    [ "$status" -eq 0 ]
    [ "$output" = "/clear" ]
}

@test "T-CG-008: gate_permitted_cli_count は 1 を返す (claude のみ)" {
    run bash -c "source '$GATE_LIB' && gate_permitted_cli_count"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

@test "T-CG-009: ★claude 以外の CLI は綴りを返さない (redo1 で閉じた)" {
    # 条件1 の権威源は `~/.claude/sessions`(★Claude 自身の申告)であり、
    # 他の CLI はこれを書かない (R-5)。★実体と束縛されない cli 引数を
    # 許可根拠にしてはならぬゆえ、claude 以外は綴りを持たない。
    for cli in codex opencode copilot kimi; do
        run bash -c "source '$GATE_LIB' && gate_reset_command_for_cli '$cli'"
        [ "$status" -eq 1 ]
        [ -z "$output" ]
    done
}

@test "T-CG-003: 未知の CLI は空 + rc=1 (fail-closed)" {
    for cli in "" "bogus" "gemini" "IDLE" "claude " "aider"; do
        run bash -c "source '$GATE_LIB' && gate_reset_command_for_cli '$cli'"
        [ "$status" -eq 1 ]
        [ -z "$output" ]
    done
}

@test "T-CG-004: 条件3 は綴りの完全一致のみ許す" {
    run bash -c "source '$GATE_LIB' && gate_condition3_command_is_permitted claude '/clear'"
    [ "$status" -eq 0 ]
    # ★claude 以外は綴りを持たぬゆえ、何を渡しても通らない。
    run bash -c "source '$GATE_LIB' && gate_condition3_command_is_permitted codex '/new'"
    [ "$status" -eq 1 ]
    run bash -c "source '$GATE_LIB' && gate_condition3_command_is_permitted claude '/new'"
    [ "$status" -eq 1 ]
    run bash -c "source '$GATE_LIB' && gate_condition3_command_is_permitted codex '/clear'"
    [ "$status" -eq 1 ]
}

@test "T-CG-005: 裸の Enter・C-u・任意文字列は許さない" {
    for cmd in "Enter" "C-u" "C-c" "" "/clear " " /clear" "/clearall" "clear" "inbox7" "/clear; rm -rf /"; do
        run bash -c "source '$GATE_LIB' && gate_condition3_command_is_permitted claude '$cmd'"
        [ "$status" -eq 1 ]
    done
}

@test "T-CG-006: gate_type_is_in_scope は clear_command のみ通す" {
    run bash -c "source '$GATE_LIB' && gate_type_is_in_scope clear_command"
    [ "$status" -eq 0 ]
}

@test "T-CG-007: nudge / model_switch / cli_restart は対象外である" {
    for t in nudge model_switch cli_restart task_assigned report_received "" unknown_future_type; do
        run bash -c "source '$GATE_LIB' && gate_type_is_in_scope '$t'"
        [ "$status" -eq 1 ]
    done
}

# ═══════════════════════════════════════════════════════
# 条件1 — 本人の申告が idle であること
# ═══════════════════════════════════════════════════════

@test "T-CG-010: idle かつ滞留十分なら許可される" {
    mk_session s1 idle null 9000
    run bash -c "source '$GATE_HARNESS'; gate_condition1_self_reports_idle '$PANE_TARGET'; echo \"rc=\$? reason=\$GATE_REASON\""
    echo "$output"
    echo "$output" | grep -q "rc=0"
    echo "$output" | grep -q "c1_ok:idle"
}

@test "T-CG-011: waiting (permission prompt) は不許可" {
    mk_session s1 waiting '"permission prompt"' 9000
    run bash -c "source '$GATE_HARNESS'; gate_condition1_self_reports_idle '$PANE_TARGET'; echo \"rc=\$? reason=\$GATE_REASON\""
    echo "$output"
    echo "$output" | grep -q "rc=1"
    echo "$output" | grep -q "c1_not_idle:waiting"
}

@test "T-CG-012: busy は不許可" {
    mk_session s1 busy null 9000
    run bash -c "source '$GATE_HARNESS'; gate_condition1_self_reports_idle '$PANE_TARGET'; echo \"rc=\$?\""
    echo "$output" | grep -q "rc=1"
}

@test "T-CG-013: shell は不許可" {
    mk_session s1 shell null 9000
    run bash -c "source '$GATE_HARNESS'; gate_condition1_self_reports_idle '$PANE_TARGET'; echo \"rc=\$?\""
    echo "$output" | grep -q "rc=1"
}

@test "T-CG-014: ★未知の状態語は不許可 (否定形で書いていれば通ってしまう)" {
    # ★これが fail-closed の要である。Claude Code の版が上がって状態語が
    #   増えたとき、否定形 (`!= idle`) の実装ならここで★通ってしまう。
    for st in "resuming" "compacting" "awaiting_input" "IDLE" "idle2" "" "ready"; do
        mk_session s1 "$st" null 9000
        run bash -c "source '$GATE_HARNESS'; gate_condition1_self_reports_idle '$PANE_TARGET'; echo \"rc=\$? reason=\$GATE_REASON\""
        echo "state=$st => $output"
        echo "$output" | grep -q "rc=1"
    done
}

@test "T-CG-015: ★未知の状態語は記録され人経路へ上がる" {
    mk_session s1 "compacting" null 9000
    run bash -c "source '$GATE_HARNESS'; gate_condition1_self_reports_idle '$PANE_TARGET' ashigaru7; echo \"rc=\$? reason=\$GATE_REASON\""
    echo "$output"
    echo "$output" | grep -q "rc=1"
    echo "$output" | grep -q "c1_unknown_state_recorded:compacting"
    # 記録が残っていること
    [ -f "$UNKNOWN_LOG" ]
    grep -q "state=compacting" "$UNKNOWN_LOG"
    grep -q "agent=ashigaru7" "$UNKNOWN_LOG"
    # 人経路 (家老 inbox) へ上がっていること
    [ -f "$INBOX_WRITE_LOG" ]
    grep -q "target=karo" "$INBOX_WRITE_LOG"
    grep -q "dashboard" "$INBOX_WRITE_LOG"
}

@test "T-CG-016: mesh 記録が無ければ不許可 (信頼ダイアログ相当・①の実測)" {
    # ①で、信頼ダイアログ表示中は申告ファイルそのものが書かれなかった。
    # 「何も申告しなかった」を「idle」と読み替えてはならない。
    run bash -c "source '$GATE_HARNESS'; gate_condition1_self_reports_idle '$PANE_TARGET'; echo \"rc=\$? reason=\$GATE_REASON\""
    echo "$output"
    echo "$output" | grep -q "rc=1"
    echo "$output" | grep -q "c1_no_mesh_record_for_pane"
}

@test "T-CG-017: pane identity が読めなければ不許可" {
    mk_session s1 idle null 9000
    MOCK_PANE_IDENT="" run bash -c "source '$GATE_HARNESS'; gate_condition1_self_reports_idle '$PANE_TARGET'; echo \"rc=\$? reason=\$GATE_REASON\""
    echo "$output"
    echo "$output" | grep -q "rc=1"
    echo "$output" | grep -q "c1_pane_identity_unreadable"
}

@test "T-CG-018: procStart 不一致 (pid 再利用) は不許可" {
    mk_session s1 idle null 9000 "$LIVE_PID" "1"
    run bash -c "source '$GATE_HARNESS'; gate_condition1_self_reports_idle '$PANE_TARGET'; echo \"rc=\$? reason=\$GATE_REASON\""
    echo "$output"
    echo "$output" | grep -q "rc=1"
    echo "$output" | grep -q "c1_proc_start_mismatch"
}

@test "T-CG-019: pid が生きていなければ不許可" {
    mk_session s1 idle null 9000 "$DEAD_PID" "12345"
    run bash -c "source '$GATE_HARNESS'; gate_condition1_self_reports_idle '$PANE_TARGET'; echo \"rc=\$? reason=\$GATE_REASON\""
    echo "$output"
    echo "$output" | grep -q "rc=1"
    echo "$output" | grep -q "c1_mesh_pid_not_alive"
}

@test "T-CG-020: 滞留不足 (idle になった直後) は不許可" {
    # ①の実測: 起動 1.1〜1.4 秒後には既に `idle` を申告していた。
    # TUI 初期化中でも `idle` である。滞留で粗く弾く。
    mk_session s1 idle null 200
    run bash -c "source '$GATE_HARNESS'; gate_condition1_self_reports_idle '$PANE_TARGET'; echo \"rc=\$? reason=\$GATE_REASON\""
    echo "$output"
    echo "$output" | grep -q "rc=1"
    echo "$output" | grep -q "c1_idle_too_fresh"
}

@test "T-CG-020b: statusUpdatedAt が数値でなければ不許可 (落ちずに倒す)" {
    # ★R-7: スキーマは非公開契約であり型すら変わりうる。数値でないものを
    #   算術へ渡すと `set -u` を敷いた呼出側で落ちる。落ちることは
    #   fail-closed ではないので、明示的に不許可へ倒す。
    mk_session s1 idle null 9000
    for bad in '"later"' 'null' '"2026-09-09T00:00:00"'; do
        python3 - "$FAKE_SESSIONS/s1.json" "$bad" << 'PY'
import json, sys
p, bad = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d["statusUpdatedAt"] = json.loads(bad)
json.dump(d, open(p, "w"))
PY
        run bash -c "set -uo pipefail; source '$GATE_HARNESS'; gate_condition1_self_reports_idle '$PANE_TARGET'; echo \"rc=\$? reason=\$GATE_REASON\""
        echo "bad=$bad => $output"
        echo "$output" | grep -q "rc=1"
        echo "$output" | grep -qE "c1_status_timestamp_(not_numeric|missing)"
    done
}

@test "T-CG-020c: 滞留要求は環境変数で緩められない (厳しくするのは可)" {
    # ★fail-closed の歯止めが呼出側の設定一つで無効化されては歯止めにならぬ。
    for bad in 0 1 100 "" "abc" "-5000"; do
        run bash -c "GATE_MIN_IDLE_DWELL_MS='$bad' bash -c 'source \"$GATE_LIB\"; echo \$GATE_MIN_IDLE_DWELL_MS'"
        echo "指定=$bad => $output"
        [ "$output" = "3000" ]
    done
    # 厳しくする方向は通る
    run bash -c "GATE_MIN_IDLE_DWELL_MS=9000 bash -c 'source \"$GATE_LIB\"; echo \$GATE_MIN_IDLE_DWELL_MS'"
    [ "$output" = "9000" ]
}

@test "T-CG-020d: 滞留要求を 0 にしても idle 直後は送られない" {
    # ★T-CG-020c の帰結を、実際の判定でも確かめる。
    mk_session s1 idle null 200
    run bash -c "GATE_MIN_IDLE_DWELL_MS=0; source '$GATE_HARNESS'; gate_send_context_reset '$PANE_TARGET' claude clear_command ashigaru7; echo \"rc=\$? reason=\$GATE_REASON\""
    echo "$output"
    echo "$output" | grep -q "rc=1"
    echo "$output" | grep -q "c1_idle_too_fresh"
    [ ! -s "$SENDKEYS_LOG" ]
}

@test "T-CG-021: 同一 pane に複数記録が一致すれば曖昧ゆえ不許可" {
    mk_session s1 idle null 9000
    mk_session s2 idle null 9000
    run bash -c "source '$GATE_HARNESS'; gate_condition1_self_reports_idle '$PANE_TARGET'; echo \"rc=\$? reason=\$GATE_REASON\""
    echo "$output"
    echo "$output" | grep -q "rc=1"
    echo "$output" | grep -q "c1_ambiguous_mesh_records:2"
}

@test "T-CG-022: 別 pane の記録には引きずられない (束縛の検査)" {
    # ①でセッション名の衝突を実測した (probe の `shogun-23` が稼働中の
    # 足軽3号と同名であった)。束縛は pid + procStart + tmux pane で行う。
    mk_session other idle null 9000 "$LIVE_PID" "$LIVE_PROCSTART" "multiagent:@1.%3"
    run bash -c "source '$GATE_HARNESS'; gate_condition1_self_reports_idle '$PANE_TARGET'; echo \"rc=\$? reason=\$GATE_REASON\""
    echo "$output"
    echo "$output" | grep -q "rc=1"
    echo "$output" | grep -q "c1_no_mesh_record_for_pane"
}

@test "T-CG-024: 束縛 — claude 実体が pane 配下にあるとき rc=0" {
    run bash -c "source '$GATE_HARNESS'; gate_cli_bound_to_pane '$PANE_TARGET' claude '$LIVE_PID'; echo \"rc=\$? reason=\$GATE_REASON\""
    echo "$output"
    echo "$output" | grep -q "rc=0"
    echo "$output" | grep -q "bind_ok:claude"
}

@test "T-CG-025: ★束縛 — cli 引数が claude 以外なら不許可 (権威源が無い)" {
    # ★差戻し理由2: 初版は呼出側の cli 文字列を実 pane と照合せず、
    #   Claude の記録で認証された pane へ `cli=codex` を渡せば `/new` を
    #   送れてしまった。実体と束縛されない自己申告は許可根拠にならぬ。
    for cli in codex opencode copilot kimi "" bogus; do
        run bash -c "source '$GATE_HARNESS'; gate_cli_bound_to_pane '$PANE_TARGET' '$cli' '$LIVE_PID'; echo \"rc=\$? reason=\$GATE_REASON\""
        echo "cli=$cli => $output"
        echo "$output" | grep -q "rc=1"
        echo "$output" | grep -q "bind_cli_has_no_authoritative_source"
    done
}

@test "T-CG-026: 束縛 — pane の実体が claude でなければ不許可" {
    # 本試験プロセス自身 (argv[0] は claude ではない) を指させる。
    run bash -c "source '$GATE_HARNESS'; gate_cli_bound_to_pane '$PANE_TARGET' claude '$$'; echo \"rc=\$? reason=\$GATE_REASON\""
    echo "$output"
    echo "$output" | grep -q "rc=1"
    echo "$output" | grep -q "bind_pane_process_not_claude"
}

@test "T-CG-027: 束縛 — pid が pane の子孫でなければ不許可" {
    MOCK_PANE_PID=1 run bash -c "source '$GATE_HARNESS'; gate_cli_bound_to_pane '$PANE_TARGET' claude '$LIVE_PID'; echo \"rc=\$? reason=\$GATE_REASON\""
    echo "$output"
    echo "$output" | grep -q "rc=1"
    echo "$output" | grep -q "bind_pid_not_under_pane"
}

@test "T-CG-028: 束縛 — pane_pid が読めなければ不許可 (fail-closed)" {
    MOCK_PANE_PID="" run bash -c "source '$GATE_HARNESS'; gate_cli_bound_to_pane '$PANE_TARGET' claude '$LIVE_PID'; echo \"rc=\$? reason=\$GATE_REASON\""
    echo "$output"
    echo "$output" | grep -q "rc=1"
    echo "$output" | grep -q "bind_pane_pid_unreadable"
}

@test "T-CG-029: 束縛 — pid が数値でなければ不許可" {
    for bad in "" "abc" "-1" "12x"; do
        run bash -c "source '$GATE_HARNESS'; gate_cli_bound_to_pane '$PANE_TARGET' claude '$bad'; echo \"rc=\$? reason=\$GATE_REASON\""
        echo "pid=$bad => $output"
        echo "$output" | grep -q "rc=1"
        echo "$output" | grep -q "bind_pid_not_numeric"
    done
}

@test "T-CG-023: ★実装が否定形 != \"idle\" を使っていない (静的検査)" {
    # ★否定形で書くと未知の状態語がすり抜けて通ってしまう。
    #   実コード (コメント除く) に否定形の idle 比較が無いことを検査する。
    run bash -c "grep -v '^[[:space:]]*#' '$GATE_LIB' | grep -cE '!=[[:space:]]*\"?idle\"?' || true"
    [ "$output" = "0" ]
}

# ═══════════════════════════════════════════════════════
# 条件2 — 危険の否認のみ (安全の証明ではない)
# ═══════════════════════════════════════════════════════

@test "T-CG-030: モーダルが見えたら拒否する (事故当日の ❯ 1. Yes)" {
    MOCK_CAPTURE="Do you want to proceed?
❯ 1. Yes
  2. No" \
    run bash -c "source '$GATE_HARNESS'; gate_condition2_screen_is_known_safe_form '$PANE_TARGET'; echo \"rc=\$? reason=\$GATE_REASON\""
    echo "$output"
    echo "$output" | grep -q "rc=1"
    echo "$output" | grep -q "c2_veto_modal_visible"
}

@test "T-CG-031: 各種モーダル定型でも拒否する" {
    local screens=(
        "Do you trust the files in this folder?"
        "Would you like to continue? (y/n)"
        "  1. Yes
  2. No"
        "Press Enter to continue"
        "Running tool… (esc to interrupt)"
        "削除してよろしいか [y/N]"
    )
    for s in "${screens[@]}"; do
        MOCK_CAPTURE="$s" run bash -c "source '$GATE_HARNESS'; gate_condition2_screen_is_known_safe_form '$PANE_TARGET'; echo \"rc=\$?\""
        echo "screen=[$s] => $output"
        echo "$output" | grep -q "rc=1"
    done
}

@test "T-CG-032: capture 失敗は拒否 (読めないことは安全ではない)" {
    MOCK_CAPTURE_RC=1 run bash -c "source '$GATE_HARNESS'; gate_condition2_screen_is_known_safe_form '$PANE_TARGET'; echo \"rc=\$? reason=\$GATE_REASON\""
    echo "$output"
    echo "$output" | grep -q "rc=1"
    echo "$output" | grep -q "c2_capture_failed"
}

@test "T-CG-033: capture が空なら拒否" {
    MOCK_CAPTURE="" run bash -c "source '$GATE_HARNESS'; gate_condition2_screen_is_known_safe_form '$PANE_TARGET'; echo \"rc=\$? reason=\$GATE_REASON\""
    echo "$output"
    echo "$output" | grep -q "rc=1"
    echo "$output" | grep -q "c2_capture_empty"
}

@test "T-CG-034: ★唯一許可された既知の安全形なら拒否権を行使しない (rc=0)" {
    run bash -c "source '$GATE_HARNESS'; gate_condition2_screen_is_known_safe_form '$PANE_TARGET'; echo \"rc=\$? reason=\$GATE_REASON\""
    echo "$output"
    echo "$output" | grep -q "rc=0"
    echo "$output" | grep -q "c2_known_safe_form"
}

@test "T-CG-036: ★軍師 probe の未収載モーダルは不許可 (redo1 の核)" {
    # ★差戻し理由1: 初版 (blacklist) は危険パターンに一致しない★非空画面を
    #   無条件に通し、この画面で実際に send-keys まで到達した。
    MOCK_CAPTURE="Permission required
Approve access to the repository?
  Approve access
  Cancel" \
    run bash -c "source '$GATE_HARNESS'; gate_condition2_screen_is_known_safe_form '$PANE_TARGET'; echo \"rc=\$? reason=\$GATE_REASON\""
    echo "$output"
    echo "$output" | grep -q "rc=1"
    echo "$output" | grep -q "c2_screen_not_a_known_safe_form"
}

@test "T-CG-037: ★未知の画面は危険パターンに無くとも一律不許可" {
    local screens=(
        "Permission required
  Approve access
  Cancel"
        "commit 58ed69c
Author: Ashigaru
    cmd_754完了"
        "╭──────────────╮
│ >            │
╰──────────────╯
  ? for shortcuts"
        "  ようこそ。作業を続けよ。
> "
        "Select an option:
  Alpha
  Beta"
        "> /clear"
        "❯ "
        "\$ "
    )
    for s in "${screens[@]}"; do
        MOCK_CAPTURE="$s" run bash -c "source '$GATE_HARNESS'; gate_condition2_screen_is_known_safe_form '$PANE_TARGET'; echo \"rc=\$?\""
        echo "screen=[$s] => $output"
        echo "$output" | grep -q "rc=1"
    done
}

@test "T-CG-038: 許可されるのは「空のプロンプト行のみ」の形だけである" {
    for s in ">" "> " "  >  " "
>   
"; do
        MOCK_CAPTURE="$s" run bash -c "source '$GATE_HARNESS'; gate_condition2_screen_is_known_safe_form '$PANE_TARGET'; echo \"rc=\$? reason=\$GATE_REASON\""
        echo "screen=[$s] => $output"
        echo "$output" | grep -q "rc=0"
    done
}

@test "T-CG-039: gate_screen_allowed_form_count は 1 (許可形は唯一である)" {
    # ★増やすことは安全集合を広げることであり、隔離実測と将軍・軍師の
    #   gate を要する。試験はこの値を直接検査して番人となる。
    run bash -c "source '$GATE_LIB' && gate_screen_allowed_form_count"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

@test "T-CG-035: ★条件2 の rc=0 は単独では送信を生まない" {
    # 条件2 は通る素の画面。しかし mesh 記録が無い (条件1 不成立) ので
    # 送信は起きない。★「見えなかった」は許可ではないことの検査である。
    run bash -c "source '$GATE_HARNESS'; gate_condition2_screen_is_known_safe_form '$PANE_TARGET'; echo c2rc=\$?; gate_send_context_reset '$PANE_TARGET' claude clear_command ashigaru7; echo \"sendrc=\$? reason=\$GATE_REASON\""
    echo "$output"
    echo "$output" | grep -q "c2rc=0"
    echo "$output" | grep -q "sendrc=1"
    [ ! -s "$SENDKEYS_LOG" ]
}

# ═══════════════════════════════════════════════════════
# 三条件の合成
# ═══════════════════════════════════════════════════════

@test "T-CG-040: 三条件充足で /clear がちょうど1回送られる" {
    mk_session s1 idle null 9000
    run bash -c "source '$GATE_HARNESS'; gate_send_context_reset '$PANE_TARGET' claude clear_command ashigaru7; echo \"rc=\$? reason=\$GATE_REASON\""
    echo "$output"
    echo "$output" | grep -q "rc=0"
    echo "$output" | grep -q "sent:/clear"
    [ "$(wc -l < "$SENDKEYS_LOG")" -eq 1 ]
    grep -q '/clear' "$SENDKEYS_LOG"
}

@test "T-CG-041: 条件1 非充足なら送らない" {
    mk_session s1 waiting '"permission prompt"' 9000
    run bash -c "source '$GATE_HARNESS'; gate_send_context_reset '$PANE_TARGET' claude clear_command ashigaru7; echo \"rc=\$? reason=\$GATE_REASON\""
    echo "$output"
    echo "$output" | grep -q "rc=1"
    echo "$output" | grep -q "denied_c1"
    [ ! -s "$SENDKEYS_LOG" ]
}

@test "T-CG-042: 条件2 非充足なら送らない" {
    mk_session s1 idle null 9000
    # ★条件1 は満たしているのに、画面にモーダルが見えるので拒否される。
    #   これが「保険」としての条件2 の役目そのものである。
    MOCK_CAPTURE="Do you want to proceed?
❯ 1. Yes" \
    run bash -c "source '$GATE_HARNESS'; gate_send_context_reset '$PANE_TARGET' claude clear_command ashigaru7; echo \"rc=\$? reason=\$GATE_REASON\""
    echo "$output"
    echo "$output" | grep -q "rc=1"
    echo "$output" | grep -q "denied_c2"
    [ ! -s "$SENDKEYS_LOG" ]
}

@test "T-CG-043: 条件3 非充足 (未知 CLI) なら送らない" {
    mk_session s1 idle null 9000
    for cli in "" "bogus" "gemini"; do
        > "$SENDKEYS_LOG"
        run bash -c "source '$GATE_HARNESS'; gate_send_context_reset '$PANE_TARGET' '$cli' clear_command ashigaru7; echo \"rc=\$? reason=\$GATE_REASON\""
        echo "cli=$cli => $output"
        echo "$output" | grep -q "rc=1"
        echo "$output" | grep -q "denied_c3_unknown_cli"
        [ ! -s "$SENDKEYS_LOG" ]
    done
}

@test "T-CG-044: 送信は text+Enter を1回の send-keys で行う" {
    mk_session s1 idle null 9000
    run bash -c "source '$GATE_HARNESS'; gate_send_context_reset '$PANE_TARGET' claude clear_command ashigaru7"
    [ "$(wc -l < "$SENDKEYS_LOG")" -eq 1 ]
    grep -q 'Enter' "$SENDKEYS_LOG"
    grep -q '/clear' "$SENDKEYS_LOG"
}

@test "T-CG-045: C-u (入力欄クリア) を送らない" {
    mk_session s1 idle null 9000
    run bash -c "source '$GATE_HARNESS'; gate_send_context_reset '$PANE_TARGET' claude clear_command ashigaru7"
    run grep -c 'C-u' "$SENDKEYS_LOG"
    [ "$output" = "0" ]
}

@test "T-CG-046: 打鍵直前に条件1 を再読する (TOCTOU の窓を詰める)" {
    mk_session s1 idle null 9000
    run bash -c "source '$GATE_HARNESS'; gate_send_context_reset '$PANE_TARGET' claude clear_command ashigaru7"
    # 条件1 は2回読まれる (本判定 + 打鍵直前の再読)。ゆえに identity 問い合わせも2回。
    run grep -c 'session_name' "$MOCK_LOG"
    [ "$output" = "2" ]
    # 束縛も同じく2回確かめられる (本判定 + 再読)。
    run grep -c 'pane_pid' "$MOCK_LOG"
    [ "$output" = "2" ]
}

@test "T-CG-047: 再読で waiting へ変わっていたら送らない" {
    mk_session s1 idle null 9000
    # capture-pane が呼ばれた時点で申告を waiting へ差し替える。
    # ★条件2 の直後・打鍵の直前に状態が変わる状況を作る。
    cat > "$TEST_TMPDIR/flip_harness.sh" << FLIP
#!/bin/bash
tmux() {
    echo "tmux \$*" >> "$MOCK_LOG"
    case "\$*" in
        *pane_pid*) printf '%s\n' "$LIVE_PANE_PID"; return 0 ;;
        *session_name*) printf '%s\n' "$PANE_IDENT"; return 0 ;;
        *@agent_id*) printf '%s\n' "ashigaru7"; return 0 ;;
        *pane_id*) printf '%s\n' "$PANE_ID"; return 0 ;;
        *capture-pane*)
            # ★ここで本人の申告が waiting へ遷移する (モーダルが上がった)
            sed -i 's/"status":"idle"/"status":"waiting"/' "$FAKE_SESSIONS/s1.json"
            printf '%s\n' "> "
            return 0
            ;;
        *send-keys*) echo "\$*" >> "$SENDKEYS_LOG"; return 0 ;;
    esac
    return 0
}
timeout() { shift; "\$@"; }
export -f tmux timeout
export GATE_SESSIONS_DIR="$FAKE_SESSIONS"
export GATE_PROJECT_ROOT="$FAKE_ROOT"
export GATE_UNKNOWN_STATE_LOG="$UNKNOWN_LOG"
source "$GATE_LIB"
FLIP
    run bash -c "source '$TEST_TMPDIR/flip_harness.sh'; gate_send_context_reset '$PANE_TARGET' claude clear_command ashigaru7; echo \"rc=\$? reason=\$GATE_REASON\""
    echo "$output"
    echo "$output" | grep -q "rc=1"
    echo "$output" | grep -q "denied_c1_recheck"
    [ ! -s "$SENDKEYS_LOG" ]
}

@test "T-CG-048: ★codex/opencode/copilot/kimi は送らない (redo1 で閉じた)" {
    mk_session s1 idle null 9000
    for cli in codex opencode copilot kimi; do
        > "$SENDKEYS_LOG"
        run bash -c "source '$GATE_HARNESS'; gate_send_context_reset '$PANE_TARGET' '$cli' clear_command ashigaru7; echo \"rc=\$? reason=\$GATE_REASON\""
        echo "cli=$cli => $output"
        echo "$output" | grep -q "rc=1"
        echo "$output" | grep -q "denied_c3_unknown_cli"
        [ ! -s "$SENDKEYS_LOG" ]
    done
}

@test "T-CG-049: ★inbox_type が clear_command でなければ送信口で落ちる" {
    # ★差戻し理由3: 初版は `gate_type_is_in_scope` が定義と単体試験にしか
    #   現れず、送信口では強制されていなかった (未到達 helper だけを見る
    #   ★偽緑)。今は production entry の必須入力である。
    mk_session s1 idle null 9000
    for t in model_switch cli_restart nudge task_assigned report_received unknown_future_type; do
        > "$SENDKEYS_LOG"
        run bash -c "source '$GATE_HARNESS'; gate_send_context_reset '$PANE_TARGET' claude '$t' ashigaru7; echo \"rc=\$? reason=\$GATE_REASON\""
        echo "type=$t => $output"
        echo "$output" | grep -q "rc=1"
        echo "$output" | grep -q "denied_scope"
        [ ! -s "$SENDKEYS_LOG" ]
    done
}

@test "T-CG-049b: ★inbox_type 未指定なら送らない (必須引数である)" {
    mk_session s1 idle null 9000
    run bash -c "source '$GATE_HARNESS'; gate_send_context_reset '$PANE_TARGET' claude; echo \"rc=\$? reason=\$GATE_REASON\""
    echo "$output"
    echo "$output" | grep -q "rc=1"
    echo "$output" | grep -q "denied_scope_inbox_type_unset"
    [ ! -s "$SENDKEYS_LOG" ]
}

@test "T-CG-049c: ★scope は送信直前にも再度強制される (静的検査)" {
    # 冒頭と送信直前の二度、同じ引数で完全一致を課していること。
    run bash -c "grep -v '^[[:space:]]*#' '$GATE_LIB' | grep -c 'gate_type_is_in_scope \"\$inbox_type\"'"
    [ "$output" = "2" ]
}

@test "T-CG-049d: ★束縛を欠く pane へは送らない" {
    # 申告主が claude でない (この試験プロセス自身) 場合。
    mk_session s1 idle null 9000 "$$" "$(awk '{print $22}' /proc/$$/stat)"
    run bash -c "source '$GATE_HARNESS'; gate_send_context_reset '$PANE_TARGET' claude clear_command ashigaru7; echo \"rc=\$? reason=\$GATE_REASON\""
    echo "$output"
    echo "$output" | grep -q "rc=1"
    echo "$output" | grep -q "denied_bind"
    [ ! -s "$SENDKEYS_LOG" ]
}

# ═══════════════════════════════════════════════════════
# cmd_754 の土台が無傷であること
# ═══════════════════════════════════════════════════════

@test "T-CG-050: pane_preflight の安全集合は今も空 (0)" {
    # ★本 cmd は cmd_754 を破棄しない。空集合の上に例外を積むだけである。
    run bash -c "source '$PREFLIGHT_LIB' && preflight_safe_state_count"
    [ "$output" = "0" ]
}

@test "T-CG-051: pane_send_preflight は今も常に送信禁止" {
    for args in "test:0.0 claude" "test:0.0 codex" "" "test:0.0"; do
        run bash -c "source '$PREFLIGHT_LIB'; pane_send_preflight $args"
        [ "$status" -eq 1 ]
    done
}


@test "T-CG-053: 本ライブラリの send-keys は1箇所だけである" {
    run bash -c "grep -v '^[[:space:]]*#' '$GATE_LIB' | grep -c 'send-keys' || true"
    [ "$output" = "1" ]
}

@test "T-CG-054: 本ライブラリは nudge/model_switch/cli_restart を送らない" {
    # 実コードに、対象外の命令を打鍵する経路が無いこと。
    run bash -c "grep -v '^[[:space:]]*#' '$GATE_LIB' | grep -cE 'send-keys.*(C-u|C-c|Escape|inbox[0-9])' || true"
    [ "$output" = "0" ]
    # switch_cli 相当の呼び出しも持たない。
    run bash -c "grep -v '^[[:space:]]*#' '$GATE_LIB' | grep -c 'switch_cli' || true"
    [ "$output" = "0" ]
}

# ═══════════════════════════════════════════════════════
# 未知状態通知の宛先 (★家老・将軍への自己通知を避ける)
# ═══════════════════════════════════════════════════════

@test "T-CG-055: 分岐の契約 — 家老・将軍は軍師へ、他は家老へ" {
    run bash -c "source '$GATE_LIB' && gate_unknown_state_target karo"
    [ "$output" = "gunshi" ]
    run bash -c "source '$GATE_LIB' && gate_unknown_state_target shogun"
    [ "$output" = "gunshi" ]
    for a in ashigaru1 ashigaru7 gunshi unknown ""; do
        run bash -c "source '$GATE_LIB' && gate_unknown_state_target '$a'"
        [ "$output" = "karo" ]
    done
    # ntfy 併用が要るのは家老・将軍のときだけである。
    for a in karo shogun; do
        run bash -c "source '$GATE_LIB' && gate_unknown_state_needs_human_channel '$a'"
        [ "$status" -eq 0 ]
    done
    for a in ashigaru7 gunshi ""; do
        run bash -c "source '$GATE_LIB' && gate_unknown_state_needs_human_channel '$a'"
        [ "$status" -eq 1 ]
    done
}

@test "T-CG-056: ★家老が対象なら軍師 inbox + ntfy へ分岐する" {
    # ★差戻し理由4: 初版は agent_id によらず常に家老 inbox へ送っていた。
    #   対象が家老自身のとき、それは★停止中の本人への自己通知であり
    #   dashboard/殿へ到達しない。
    run bash -c "source '$GATE_HARNESS'; gate_record_unknown_state compacting 'pane=x' karo"
    [ "$status" -eq 0 ]
    grep -q "target=gunshi" "$INBOX_WRITE_LOG"
    run grep -c "target=karo" "$INBOX_WRITE_LOG"
    [ "$output" = "0" ]
    [ -f "$NTFY_LOG" ]
    grep -q "要対応" "$NTFY_LOG"
}

@test "T-CG-057: ★将軍が対象でも軍師 inbox + ntfy へ分岐する" {
    run bash -c "source '$GATE_HARNESS'; gate_record_unknown_state compacting 'pane=x' shogun"
    [ "$status" -eq 0 ]
    grep -q "target=gunshi" "$INBOX_WRITE_LOG"
    [ -f "$NTFY_LOG" ]
}

@test "T-CG-058: 足軽が対象なら家老 inbox のみ (ntfy は鳴らさぬ)" {
    run bash -c "source '$GATE_HARNESS'; gate_record_unknown_state compacting 'pane=x' ashigaru7"
    [ "$status" -eq 0 ]
    grep -q "target=karo" "$INBOX_WRITE_LOG"
    [ ! -f "$NTFY_LOG" ]
}

# ═══════════════════════════════════════════════════════
# 明記事項 (軍師の限定・将軍裁定より)
# ═══════════════════════════════════════════════════════

@test "T-CG-060: 「idle は十分条件でない」旨が実装コメントに在る" {
    grep -q 'idle.*は安全な入力受領の十分条件ではない' "$GATE_LIB"
    grep -q '試した確認モーダルが.*idle.*から排除される' "$GATE_LIB"
}

@test "T-CG-061: 条件2 が「危険の否認」である旨が実装コメントに在る" {
    grep -q '危険の否認' "$GATE_LIB"
    grep -q '安全の証明ではない' "$GATE_LIB"
    # ★誤読への保険であることも併記されていること
    grep -q '保険' "$GATE_LIB"
}

@test "T-CG-062: docs にも同じ2点が在る" {
    [ -f "$DELIVERY_DOC" ]
    grep -q 'idle.*は安全な入力受領の十分条件ではない' "$DELIVERY_DOC"
    grep -q '試した確認モーダルが.*idle.*から排除される' "$DELIVERY_DOC"
    grep -q '危険の否認' "$DELIVERY_DOC"
    grep -q '安全の証明ではない' "$DELIVERY_DOC"
}

@test "T-CG-063: cmd_754 を「破棄」ではなく「上に積む」と書いてある" {
    grep -q 'cmd_754 E-1 を破棄しない' "$GATE_LIB"
    grep -qE '一命令・二条件' "$GATE_LIB"
    grep -qE '一命令・二条件' "$DELIVERY_DOC"
}

@test "T-CG-064: ★許可リスト型が「安全の証明」ではない旨が実装コメントに在る" {
    # ★redo1 の要。「既知の安全形への一致」と「安全の証明」の違いが
    #   実装コメントに明記されていること (タスク指定の必須事項)。
    grep -q '許可リスト' "$GATE_LIB"
    grep -q '既知の安全形' "$GATE_LIB"
    grep -q '安全の証明ではない' "$GATE_LIB"
    grep -q '一致しても' "$GATE_LIB"
}

@test "T-CG-065: docs にも redo1 の4点が書かれている" {
    grep -q '許可リスト' "$DELIVERY_DOC"
    grep -q 'gate_cli_bound_to_pane' "$DELIVERY_DOC"
    grep -q 'inbox_type' "$DELIVERY_DOC"
    grep -q 'gate_unknown_state_target' "$DELIVERY_DOC"
}

# ═══════════════════════════════════════════════════════
# ★redo2: 宛先の固定 — canonical pane_id (差戻し理由1)
# ═══════════════════════════════════════════════════════
#
# ★`session:window.pane_index` は★不変の identity ではない。軍師が隔離検証で
#   「第一 pane が終了すると同じ index 文字列が別の新しい pane へ再解決される」
#   ことを実証した。検査に index を使い送信にも index を使うと、その間に pane が
#   終了・再配置された場合★検査していない pane へ `/clear` が着弾しうる。

@test "T-CG-070: ★index 再束縛を模擬しても検査した pane 以外へは送らない" {
    mk_session s1 idle null 9000
    export WRONG_SENDKEYS_LOG="$TEST_TMPDIR/wrong_sendkeys.log"
    export RESOLVE_COUNT="$TEST_TMPDIR/resolve_count"
    : > "$RESOLVE_COUNT"

    # ★index 文字列 `multiagent:0.9` は、canonical 解決が済んだ★直後に
    #   別 pane (`%77`) へ再束縛されたものとして振る舞う。ゆえに index を
    #   後段へ渡す実装なら `%77` の値(別 ident・別 pane_pid・危険な画面)を
    #   掴み、`%77` へ打鍵してしまう。
    cat > "$TEST_TMPDIR/rebind_harness.sh" << REBIND
#!/bin/bash
tmux() {
    echo "tmux \$*" >> "$MOCK_LOG"
    local tgt="rebound"
    case "\$*" in
        *"-t %9"*) tgt="checked" ;;
    esac
    case "\$*" in
        *pane_pid*)
            if [ "\$tgt" = "checked" ]; then printf '%s\n' "$LIVE_PANE_PID"
            else printf '%s\n' "1"; fi
            return 0 ;;
        *session_name*)
            if [ "\$tgt" = "checked" ]; then printf '%s\n' "$PANE_IDENT"
            else printf '%s\n' "multiagent:@1.%77"; fi
            return 0 ;;
        *@agent_id*)
            if [ "\$tgt" = "checked" ]; then printf '%s\n' "ashigaru7"
            else printf '%s\n' "ashigaru1"; fi
            return 0 ;;
        *pane_id*)
            # ★index への最初の解決だけが %9 を返す。以後 index は %77 を指す。
            echo x >> "$RESOLVE_COUNT"
            if [ "\$(wc -l < "$RESOLVE_COUNT")" -eq 1 ]; then printf '%s\n' "%9"
            else printf '%s\n' "%77"; fi
            return 0 ;;
        *capture-pane*)
            if [ "\$tgt" = "checked" ]; then printf '%s\n' "> "
            else printf '%s\n' "Do you want to proceed?
❯ 1. Yes"; fi
            return 0 ;;
        *send-keys*)
            if [ "\$tgt" = "checked" ]; then echo "\$*" >> "$SENDKEYS_LOG"
            else echo "\$*" >> "$WRONG_SENDKEYS_LOG"; fi
            return 0 ;;
    esac
    return 0
}
timeout() { shift; "\$@"; }
export -f tmux timeout
export GATE_SESSIONS_DIR="$FAKE_SESSIONS"
export GATE_PROJECT_ROOT="$FAKE_ROOT"
export GATE_UNKNOWN_STATE_LOG="$UNKNOWN_LOG"
source "$GATE_LIB"
REBIND
    run bash -c "source '$TEST_TMPDIR/rebind_harness.sh'; gate_send_context_reset '$PANE_TARGET' claude clear_command ashigaru7; echo \"rc=\$? reason=\$GATE_REASON\""
    echo "$output"
    echo "$output" | grep -q "rc=0"
    # ★確定した宛先は canonical pane_id である。
    echo "$output" | grep -q "pane=%9"
    # ★検査した pane (%9) へちょうど1回だけ。
    [ "$(wc -l < "$SENDKEYS_LOG")" -eq 1 ]
    grep -q -- '-t %9' "$SENDKEYS_LOG"
    # ★再束縛された別 pane (%77) へは1度も送っていない。
    [ ! -s "$WRONG_SENDKEYS_LOG" ]
    # ★canonical 解決の1回を除き、index 文字列で tmux を叩いていないこと。
    run grep -c -- '-t multiagent:0.9' "$MOCK_LOG"
    [ "$output" = "1" ]
}

@test "T-CG-071: canonical pane_id が読めない/形不正なら送らない (fail-closed)" {
    mk_session s1 idle null 9000
    for bad in "" "0" "9" "multiagent:0.9" "%" "%9a" "%-1" "@9" "%%9"; do
        > "$SENDKEYS_LOG"
        MOCK_PANE_ID="$bad" run bash -c "source '$GATE_HARNESS'; gate_send_context_reset '$PANE_TARGET' claude clear_command ashigaru7; echo \"rc=\$? reason=\$GATE_REASON\""
        echo "pane_id=[$bad] => $output"
        echo "$output" | grep -q "rc=1"
        echo "$output" | grep -q "denied_pane_id_unresolvable"
        [ ! -s "$SENDKEYS_LOG" ]
    done
}

@test "T-CG-072: ★送信口は pane_target を canonical 解決にのみ使う (静的検査)" {
    awk '/^gate_send_context_reset\(\) \{/,/^\}/' "$GATE_LIB" \
        | grep -v '^[[:space:]]*#' > "$TEST_TMPDIR/send_body.txt"
    [ -s "$TEST_TMPDIR/send_body.txt" ]

    # ★`"$pane_target"` を渡すのは `_gate_canonical_pane_id` ただ一箇所である。
    run grep -c '_gate_canonical_pane_id "\$pane_target"' "$TEST_TMPDIR/send_body.txt"
    [ "$output" = "1" ]
    run grep -c '"\$pane_target"' "$TEST_TMPDIR/send_body.txt"
    [ "$output" = "1" ]

    # ★以後の検査は全て canonical pane_id を受け取る。
    for f in gate_agent_id_bound_to_pane gate_condition1_self_reports_idle \
             gate_cli_bound_to_pane gate_condition2_screen_is_known_safe_form; do
        run grep -c "$f \"\$pane_id\"" "$TEST_TMPDIR/send_body.txt"
        [ "$output" -ge 1 ]
    done

    # ★打鍵の宛先も canonical pane_id ただ一つ。
    run grep -c 'send-keys -t "\$pane_id"' "$TEST_TMPDIR/send_body.txt"
    [ "$output" = "1" ]
}

# ═══════════════════════════════════════════════════════
# ★redo2: agent_id の必須化と実体束縛 (差戻し理由2)
# ═══════════════════════════════════════════════════════

@test "T-CG-073: agent_id 未指定なら送らない (★必須引数である)" {
    mk_session s1 idle null 9000
    # 引数を省いた場合
    run bash -c "source '$GATE_HARNESS'; gate_send_context_reset '$PANE_TARGET' claude clear_command; echo \"rc=\$? reason=\$GATE_REASON\""
    echo "$output"
    echo "$output" | grep -q "rc=1"
    echo "$output" | grep -q "denied_agent_id_unset"
    [ ! -s "$SENDKEYS_LOG" ]
    # 空文字を明示的に渡した場合
    run bash -c "source '$GATE_HARNESS'; gate_send_context_reset '$PANE_TARGET' claude clear_command ''; echo \"rc=\$? reason=\$GATE_REASON\""
    echo "$output" | grep -q "rc=1"
    echo "$output" | grep -q "denied_agent_id_unset"
    [ ! -s "$SENDKEYS_LOG" ]
}

@test "T-CG-073b: ★家老 pane を3引数で呼んでも既定値へ倒れない (差戻し理由2の再現防止)" {
    # ★redo1 は `agent_id` を任意引数とし既定値を持たせていたため、家老 pane を
    #   3引数の正規 usage で呼ぶと既定値のまま先へ進み、未知状態通知が
    #   ★家老自身へ戻る経路が残っていた。今は引数不足でその場で落ちる。
    mk_session s1 idle null 9000
    MOCK_PANE_AGENT_ID=karo run bash -c "source '$GATE_HARNESS'; gate_send_context_reset '$PANE_TARGET' claude clear_command; echo \"rc=\$? reason=\$GATE_REASON\""
    echo "$output"
    echo "$output" | grep -q "rc=1"
    echo "$output" | grep -q "denied_agent_id_unset"
    [ ! -s "$SENDKEYS_LOG" ]
    # ★家老 inbox への自己通知も起きていないこと。
    [ ! -f "$INBOX_WRITE_LOG" ]
}

@test "T-CG-074: pane が @agent_id を持たねば送らない (fail-closed)" {
    mk_session s1 idle null 9000
    MOCK_PANE_AGENT_ID="" run bash -c "source '$GATE_HARNESS'; gate_send_context_reset '$PANE_TARGET' claude clear_command ashigaru7; echo \"rc=\$? reason=\$GATE_REASON\""
    echo "$output"
    echo "$output" | grep -q "rc=1"
    echo "$output" | grep -q "denied_agent_id:agent_id_pane_option_missing"
    [ ! -s "$SENDKEYS_LOG" ]
}

@test "T-CG-075: agent_id が pane の実体と不一致なら送らない" {
    mk_session s1 idle null 9000
    for pair in "karo:ashigaru7" "ashigaru1:ashigaru7" "ashigaru7:ashigaru70" "gunshi:shogun"; do
        local pane_side="${pair%%:*}" caller_side="${pair##*:}"
        > "$SENDKEYS_LOG"
        MOCK_PANE_AGENT_ID="$pane_side" run bash -c "source '$GATE_HARNESS'; gate_send_context_reset '$PANE_TARGET' claude clear_command '$caller_side'; echo \"rc=\$? reason=\$GATE_REASON\""
        echo "pane=$pane_side caller=$caller_side => $output"
        echo "$output" | grep -q "rc=1"
        echo "$output" | grep -q "denied_agent_id:agent_id_mismatch"
        [ ! -s "$SENDKEYS_LOG" ]
    done
    # ★一致したときだけ通る (肯定形の確認)。
    run bash -c "source '$GATE_HARNESS'; gate_agent_id_bound_to_pane '$PANE_ID' ashigaru7; echo \"rc=\$? reason=\$GATE_REASON\""
    echo "$output" | grep -q "rc=0"
    echo "$output" | grep -q "agent_id_ok:ashigaru7"
}

@test "T-CG-076: wrapper は4引数未満を引数不正 (exit 2) で拒む" {
    # ★4引数を揃えた実呼出は稼働中 pane へ届きうるゆえ★行わない。
    #   実挙動は GATE_HARNESS 経由の試験群 (T-CG-070〜075) が検査している。
    local w="$PROJECT_ROOT/scripts/send_clear_gated.sh"
    run bash "$w"
    [ "$status" -eq 2 ]
    run bash "$w" "$PANE_TARGET"
    [ "$status" -eq 2 ]
    run bash "$w" "$PANE_TARGET" claude
    [ "$status" -eq 2 ]
    run bash "$w" "$PANE_TARGET" claude clear_command
    [ "$status" -eq 2 ]
    echo "$output" | grep -q "agent_id"
    # ★wrapper 側に既定値が残っていないこと (静的検査)。
    run grep -c 'AGENT_ID="\$4"' "$w"
    [ "$output" = "1" ]
    run bash -c "grep -c 'if \[ \"\$#\" -lt 4 \]' '$w'"
    [ "$output" = "1" ]
}

@test "T-CG-077: ★未知状態通知は pane の実体 @agent_id で分岐する" {
    # ★差戻し理由2 の核心。呼出側が何を申告しようと、宛先は pane の実体から
    #   採る。家老 pane なら軍師 + ntfy へ回り、★家老自身への自己通知に
    #   ならない。
    mk_session s1 "compacting" null 9000
    MOCK_PANE_AGENT_ID=karo run bash -c "source '$GATE_HARNESS'; gate_condition1_self_reports_idle '$PANE_TARGET' unknown; echo \"rc=\$? reason=\$GATE_REASON\""
    echo "$output"
    echo "$output" | grep -q "rc=1"
    echo "$output" | grep -q "c1_unknown_state_recorded:compacting"
    grep -q "target=gunshi" "$INBOX_WRITE_LOG"
    run grep -c "target=karo" "$INBOX_WRITE_LOG"
    [ "$output" = "0" ]
    [ -f "$NTFY_LOG" ]
    grep -q "要対応" "$NTFY_LOG"
    # ★記録される agent も実体側の綴りであること。
    grep -q "agent=karo" "$UNKNOWN_LOG"
}

@test "T-CG-077b: ★将軍 pane でも実体から軍師 + ntfy へ分岐する" {
    mk_session s1 "compacting" null 9000
    MOCK_PANE_AGENT_ID=shogun run bash -c "source '$GATE_HARNESS'; gate_condition1_self_reports_idle '$PANE_TARGET' ashigaru7; echo \"rc=\$?\""
    echo "$output" | grep -q "rc=1"
    grep -q "target=gunshi" "$INBOX_WRITE_LOG"
    [ -f "$NTFY_LOG" ]
}

@test "T-CG-078: ★agent_id 束縛は打鍵直前にも再確認される" {
    mk_session s1 idle null 9000
    # (a) 静的検査 — 本判定と再読の二度、同じ引数で束縛を課していること。
    awk '/^gate_send_context_reset\(\) \{/,/^\}/' "$GATE_LIB" \
        | grep -v '^[[:space:]]*#' > "$TEST_TMPDIR/send_body2.txt"
    run grep -c 'gate_agent_id_bound_to_pane "\$pane_id" "\$agent_id"' "$TEST_TMPDIR/send_body2.txt"
    [ "$output" = "2" ]

    # (b) 実挙動 — capture-pane の時点で pane の @agent_id が入れ替わったら送らない。
    echo "ashigaru7" > "$TEST_TMPDIR/pane_agent_id"
    cat > "$TEST_TMPDIR/agentflip_harness.sh" << AFLIP
#!/bin/bash
tmux() {
    echo "tmux \$*" >> "$MOCK_LOG"
    case "\$*" in
        *pane_pid*) printf '%s\n' "$LIVE_PANE_PID"; return 0 ;;
        *session_name*) printf '%s\n' "$PANE_IDENT"; return 0 ;;
        *@agent_id*) cat "$TEST_TMPDIR/pane_agent_id"; return 0 ;;
        *pane_id*) printf '%s\n' "$PANE_ID"; return 0 ;;
        *capture-pane*)
            # ★ここで pane の帰属が入れ替わる (別 agent の pane になった)
            echo "ashigaru1" > "$TEST_TMPDIR/pane_agent_id"
            printf '%s\n' "> "
            return 0
            ;;
        *send-keys*) echo "\$*" >> "$SENDKEYS_LOG"; return 0 ;;
    esac
    return 0
}
timeout() { shift; "\$@"; }
export -f tmux timeout
export GATE_SESSIONS_DIR="$FAKE_SESSIONS"
export GATE_PROJECT_ROOT="$FAKE_ROOT"
export GATE_UNKNOWN_STATE_LOG="$UNKNOWN_LOG"
source "$GATE_LIB"
AFLIP
    run bash -c "source '$TEST_TMPDIR/agentflip_harness.sh'; gate_send_context_reset '$PANE_TARGET' claude clear_command ashigaru7; echo \"rc=\$? reason=\$GATE_REASON\""
    echo "$output"
    echo "$output" | grep -q "rc=1"
    echo "$output" | grep -q "denied_agent_id_recheck"
    [ ! -s "$SENDKEYS_LOG" ]
}

# ═══════════════════════════════════════════════════════
# ★redo2: 旧 blacklist 一般化の除去 (負の静的試験・差戻し理由3)
# ═══════════════════════════════════════════════════════

@test "T-CG-066: ★旧 blacklist 一般化・実装と矛盾する記述が0件であること (lib/・tests/・docs/ 全域走査)" {
    # ★cmd_757②redo3(G757-CLEAR-NEGATIVE-SCAN-PARTIAL-REDO2-01の是正):
    #   redo2 時点の本試験は clear_send_gate.sh・send_clear_gated.sh・
    #   本ファイル自身・delivery_channels.md の★4ファイルだけを走査して
    #   おり、`tests/verify_cmd_757_pane_rebind_isolated.sh` すら対象外
    #   であった。他の tests/docs へ旧 blacklist 型の禁止文言(台帳10行)を
    #   置いても試験は緑になってしまっていた。
    #
    # ★走査root(開始点): lib/・tests/・docs/ の★全域(サブディレクトリを
    #   含む)。「4ファイル」という限定を「全域」へ改めた。
    #
    # ★fixture自身の除外: 台帳ファイル自身は禁止文言をそのまま列挙する
    #   ものであり、走査対象に含めると必ず自己マッチ(誤検出)する。ゆえに
    #   走査対象から★この1件だけを明示的に除く。それ以外のファイルは
    #   一切除外しない(バイナリ判定で読み飛ばされないよう `-a` を付す。
    #   実測: __pycache__ 配下の .pyc を含む lib/・tests/・docs/ 全206
    #   ファイルのうち、fixture自身以外で台帳文言がヒットする箇所は無い)。
    #
    # ★CLAUDE.md Tooling Pitfalls (cmd_735): シェル関数版 grep (ugrep経由)
    #   は gitignore 対象を素通りする(実測: 同一検索で関数版26/実体413)。
    #   網羅性が問われる本試験は find・grep とも /usr/bin 配下をフルパスで
    #   呼ぶ。
    local ledger="$PROJECT_ROOT/tests/fixtures/cmd_757_redo2_banned_phrases.txt"
    [ -f "$ledger" ]
    # ★台帳が空なら常に緑になり番人にならぬ。中身があることを先に確かめる。
    local n
    n="$(/usr/bin/grep -c . "$ledger")"
    [ "$n" -ge 8 ]

    local roots=("$PROJECT_ROOT/lib" "$PROJECT_ROOT/tests" "$PROJECT_ROOT/docs")
    local f hits total=0 offenders=""
    while IFS= read -r f; do
        [ "$f" = "$ledger" ] && continue
        hits="$(/usr/bin/grep -ac -F -f "$ledger" "$f" 2>/dev/null || true)"
        [ -n "$hits" ] || hits=0
        if [ "$hits" != "0" ]; then
            offenders="${offenders}${f}:${hits}
"
            total=$((total + hits))
        fi
    done < <(/usr/bin/find "${roots[@]}" -type f)
    echo "offenders:"
    echo "$offenders"
    [ "$total" -eq 0 ]
}

@test "T-CG-066b: ★veto 表のコメントが二段の拒否として書かれている" {
    # ★除去したあとに「何が正しいのか」が書かれていること (空白のまま
    #   残すと、次の保守者がまた一般化を書き足す)。
    grep -q '第一段' "$GATE_LIB"
    grep -q '第二段' "$GATE_LIB"
    grep -q '二段の拒否' "$GATE_LIB"
    grep -q '許可を出さない' "$GATE_LIB"
}

@test "T-CG-067: docs に redo2 の是正内容が書かれている" {
    [ -f "$DELIVERY_DOC" ]
    grep -q 'canonical pane_id' "$DELIVERY_DOC"
    grep -q '_gate_canonical_pane_id' "$DELIVERY_DOC"
    grep -q '不変の identity ではない' "$DELIVERY_DOC"
    grep -q 'gate_agent_id_bound_to_pane' "$DELIVERY_DOC"
    grep -q '@agent_id' "$DELIVERY_DOC"
    grep -q 'cmd_757_redo2_banned_phrases.txt' "$DELIVERY_DOC"
}
