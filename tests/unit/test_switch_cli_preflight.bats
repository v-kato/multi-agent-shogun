#!/usr/bin/env bats
# test_switch_cli_preflight.bats — switch_cli.sh の打鍵ゲート (cmd_754 最終版)
#
# 背景:
#   switch_cli.sh は agent CLI が動いている pane へ /exit を打ち込み、
#   その後シェルへ新CLIの起動コマンドを打ち込む。計14箇所の打鍵である。
#   ★2026-09-08 の事故を受けた将軍裁定 E-1 により、agent CLI が動いている
#   pane への★自動打鍵は廃された。
#
# ★本ファイルの契約:
#   1. 既定(自動起動)では★1打鍵も送らない
#   2. 打鍵するのは `--human-initiated` が明示されたときだけである
#      (人が今この切替を命じ、当該 pane を見ていることの表明)
#   3. 新CLI起動は、pane の★前景プロセスが素のシェルであるときのみ
#      (画面文字列からは何も推論しない)
#
# テスト構成:
#   T-SC-001: 生の tmux send-keys は sc_send_keys の1箇所のみで、gate を通る
#   T-SC-002: 人手起動でなければ send_exit は1打鍵も送らず rc=1
#   T-SC-003: 人手起動でなければ launch_new_cli も送らず rc=3
#   T-SC-004: 人手起動なら send_exit(claude) は /exit と Enter を送る
#   T-SC-005: 人手起動なら send_exit(codex) は Escape/C-c/文字列/Enter を送る
#   T-SC-006: launch_new_cli — 前景が素のシェルでなければ起動しない (rc=3)
#   T-SC-007: launch_new_cli 正常系 — 素のシェルなら起動打鍵と Enter を送る
#   T-SC-008: 打鍵の配送失敗は rc=2 で伝播し、以降の打鍵を送らない
#   T-SC-009: pane_is_bare_shell 未ロード時は起動しない (fail-safe)
#   T-SC-010: 送らなかったことは黙って落とさずログへ残る
#   T-SC-011: ★実コードに capture-pane が無い(画面からの推論をやめた)
#   T-SC-012: モーダルへ答える打鍵を持たない (スコープ外・厳禁)
#   T-SC-013: --human-initiated は引数解析で明示的に立てられる
#   T-SC-014: 自動経路(inbox_watcher)は switch_cli.sh を実行しない
#             (stub/sentinel実行検証。人手案内テキストが安全であることも含む)
#   T-SC-015: 自己検証 — stub/sentinel機構は実行されれば確実にsentinelを立てる
#   T-SC-016: cli_restart処理後もinboxエントリは read:false のまま残る(未読保持)
#   T-SC-017: send_cli_command は cli_restart マーカーに人手案内(--human-initiated)を残す
#   T-SC-018: normalize_special_command は clear_command/model_switch/cli_restart を正しく変換する
#   T-SC-019: get_unread_info は clear_command/model_switch のみ既読化し cli_restart は未読のまま残す
#   T-SC-020〜022: ★cmd_760 A-4 stub/sentinel配線証明redo1で削除(欠番)。
#             旧・文字列引数として渡す入力無害化試験(実行行としての注入
#             ではなかった)。関心はT-SC-024〜026(実行行としてのコード
#             注入)へ統合済み。詳細は末尾の redo1 節を見よ。
#   T-SC-023: 配線証明(V-1) — 違反コピー(現在のworktree sourceへ、唯一の
#             アンカー[CLI-RESTART-HUMAN-PATH]を基準に旧自動委譲行相当を
#             実行行として注入した隔離コピー)は同一配線でsentinelを
#             赤くし、直後に同一配線で無変更の本番コピーは緑になる
#             (証明順序厳守: 赤→緑)
#   T-SC-024: 配線証明(V-2 変異1/3) — echo後段でのbash実行を★実行行として隔離コピーへ
#             注入すると同一配線でsentinelが赤くなる
#   T-SC-025: 配線証明(V-2 変異2/3) — printf後段でのexec実行を★実行行として注入すると赤くなる
#   T-SC-026: 配線証明(V-2 変異3/3) — command substitution経由の実行を★実行行として注入すると赤くなる
#
# ★cmd_760 A-4 redo1 (G760-A4-VACUOUS-REGRESSION-TEST-01是正):
#   旧T-SC-014は `! cmdA; cmdB` の2行構成で、1行目の `!` 否定は
#   bashのset -eトラップ対象外(POSIX仕様)のため、禁止patternが実在しても
#   関数は2行目へ進み、2行目が常に真になるため空振りでPASSしていた
#   (軍師が人工codeで実証済み)。T-SC-014は明示的status判定へ改め、
#   T-SC-015(当時)で同ロジックが違反fixtureに対し確実に赤くなることを
#   自己検証した。
#   ★redo1作業中の副次発見: 明示的判定に直した直後、T-SC-014は
#   production側(scripts/inbox_watcher.sh)に対し実際に赤くなった。原因は
#   自動実行の実在ではなく、511行目の人手案内echo文内にある引用文字列
#   `bash scripts/switch_cli.sh ...` への誤検知(false positive)だった。
#   production側は無変更のまま、判定ロジック側にecho/printf行の除外を
#   追加して是正し、T-SC-020(当時)でその除外が正しく機能することを固定した。
#
# ★cmd_760 A-4 redo2 (将軍裁定・静的パターン照合の全廃 2026-09-10):
#   redo1の是正(echo/printf行除外)自体が新たな盲点だった——「echoで
#   始まる行は丸ごと除外する」という設計は、`echo ok; bash
#   scripts/switch_cli.sh ...` のように★同一行の後半で実行するパターンを
#   除外ごと見逃す(軍師が独立実証)。原初QC(空振り)・redo1QC(新盲点)の
#   2回とも「禁止パターンが存在しないことを正規表現で示す」という★消極的
#   証拠の構造そのものが無理筋だった(パターンが無い ≠ 呼ばれない)。
#   redo2は正規表現による行除外・パターン照合という技法そのものを
#   `assert_no_switch_cli_auto_exec` ごと全廃し、★stub/sentinel方式による
#   実行検証へ置換した: 本番の scripts/switch_cli.sh は書き換えず、隔離した
#   実行環境($STUB_EXEC_ROOT/scripts/switch_cli.sh)へ「呼ばれたら
#   sentinelファイルを作るだけ」のstubを配置し、cli_restart処理の実関数
#   (normalize_special_command・send_cli_command、共に無変更)を★実際に
#   実行した上で、sentinelファイルが存在しないことを確認する「呼ばれれば
#   必ず分かる」積極的実験に改めた。T-SC-015は自己検証として、stubが実際に
#   呼ばれれば確実にsentinelが立つこと(機構自体が空振りでないこと)を
#   確認する。旧T-SC-020(echo/printf除外の自己検証)は、除外という技法
#   自体の廃止に伴い意味を失ったため、その関心(人手案内テキストは実行を
#   伴わない)をT-SC-014へ統合した。T-SC-020〜022には、軍師が独立実証した
#   3種の迂回パターン(同一行後半でのbash実行・printf+exec・command
#   substitution)を、cli_restartメッセージの内容(content)として実際に
#   流し込み、実関数が一切実行しないことを確認する試験を新設した(閉じた
#   リスト・将軍指定)。
#
# ★cmd_760 A-4 新task(redo3ではない・scope固定後の新task・将軍裁定 2026-09-10):
#   redo2で判明した欠陥: T-SC-014等が使う WATCHER_HARNESS は
#   `SCRIPT_DIR="$PROJECT_ROOT"` を固定していた。本番の呼出し経路
#   `${SCRIPT_DIR}/scripts/switch_cli.sh` が STUB_EXEC_ROOT のstubへ
#   一度も解決されておらず、「配線されていないstubは何も証明しない」
#   (将軍指摘)。加えてT-SC-020〜022は軍師提示の3行を
#   `normalize_special_command` への★文字列引数として渡しただけで、
#   ★実行行として注入・実行していなかった(入力無害化の試験であり、
#   実行検証にはなっていなかった)。
#   本taskはこの2点を是正する:
#   - WATCHER_HARNESS の SCRIPT_DIR / source対象を TEST_SCRIPT_DIR /
#     TEST_WATCHER_SCRIPT で外部注入可能にした(既定値は従来どおりで
#     T-SC-014・016〜022は無変更のまま動作する)。
#   - T-SC-023(V-1): SCRIPT_DIR=STUB_EXEC_ROOT の配線下で、まず
#     cli_restart自動実行を復活させた隔離コピー(git HEAD時点の実コード
#     ——58ed69cで自動委譲を廃する★前の実在コミット内容そのもの。
#     regex変異ではない)を実行して★sentinelが赤くなることを示し、
#     直後に同一配線で無変更の本番コピー(working tree)を実行して
#     ★sentinelが立たない(緑)ことを示す。赤を先に示す順序を1 testの中で
#     強制し、bats実行順序への依存を避けた。
#   - T-SC-024〜026(V-2): 軍師提示の3変異を、隔離コピーの
#     `[CLI-RESTART-HUMAN-PATH]` 人手案内行そのものへ★実行行として
#     置換注入し(文字列引数としてではない)、同じ配線(SCRIPT_DIR=
#     STUB_EXEC_ROOT・cli_restartの実処理関数は無変更)で実行して
#     各々sentinelが赤くなることを示す。
#
# ★cmd_760 A-4 stub/sentinel配線証明redo1
#   (G760-A4-V1-HEAD-EPHEMERAL-01・G760-A4-V2-INERT-TESTS-REMAIN-02是正):
#   問題1(HEAD依存の是正): T-SC-023の違反コピーを
#   `git -C "$PROJECT_ROOT" show HEAD:scripts/inbox_watcher.sh` から
#   生成する旧方式は、gitの可変HEADに依存する危うい設計だった——本cmdの
#   成果がcommitされた瞬間、HEADもworktreeと同じ安全版になり、負の対照
#   (赤)が消える。是正として、V-2で確立済みの`make_v2_mutant`(現在の
#   worktree source `$WATCHER_SCRIPT` へ、唯一のアンカー文字列
#   `[CLI-RESTART-HUMAN-PATH]` を基準に実行行を置換注入する手法)を
#   V-1の違反コピー生成にも転用した。置換注入する実行行は旧自動委譲行
#   相当(`bash "${SCRIPT_DIR}/scripts/switch_cli.sh" "$AGENT_ID"
#   $restart_args`)一本のみとし、旧コード(58ed69c^時点)にあった
#   `| while … done` やCLI_TYPE再取得、`return 0` は再現していない
#   ——V-1が証明すべきは「switch_cli.shが実際に呼ばれること」
#   (sentinelの有無)であり、戻り値の数値自体は本質ではないため、V-2群
#   (T-SC-024〜026)と同様に赤・緑ともRC=1・sentinelの有無で判定する
#   形へ揃えた。これにより、commit後・clean checkout後を問わず常に
#   同じ手順で違反コピーを再構成でき、負の対照が恒久的に機能する。
#   問題2(inert試験の削除): 前task(V-2)で「文字列引数として渡す形
#   (旧T-SC-020〜022)は廃止せよ」と指定したにも関わらず、旧T-SC-020〜022
#   が試験本文そのまま残存し、3文字列を`normalize_special_command`への
#   第3引数として渡すだけの入力無害化試験(実行行としての注入ではない)
#   として、正しいV-2試験(T-SC-024〜026)と併存していた。これは事実
#   誤認による差戻し対象だったため、旧T-SC-020〜022を実際に削除し、
#   T-SC-024〜026(実行行としてのコード注入)だけを正本として残した。
#   番号はT-SC-024〜026のまま維持し、020〜022は欠番とした(振り直しは
#   していない)。

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export SWITCH_CLI="$PROJECT_ROOT/scripts/switch_cli.sh"
    export PREFLIGHT_LIB="$PROJECT_ROOT/lib/pane_preflight.sh"
    export WATCHER_SCRIPT="$PROJECT_ROOT/scripts/inbox_watcher.sh"
    export VENV_PYTHON="$PROJECT_ROOT/.venv/bin/python3"
    [ -f "$SWITCH_CLI" ] || return 1
    [ -f "$PREFLIGHT_LIB" ] || return 1
    [ -f "$WATCHER_SCRIPT" ] || return 1
    "$VENV_PYTHON" -c "import yaml" 2>/dev/null || return 1
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/switch_cli_preflight.XXXXXX")"
    export MOCK_LOG="$TEST_TMPDIR/tmux_calls.log"
    > "$MOCK_LOG"

    export MOCK_FOREGROUND="bash"
    export MOCK_PANE_ID_RC=0
    export MOCK_SENDKEYS_RC=0

    export TEST_HARNESS="$TEST_TMPDIR/harness.sh"
    cat > "$TEST_HARNESS" << HARNESS
#!/bin/bash
# 実 tmux には決して触らせない。全て記録付きモックで置き換える。
tmux() {
    echo "tmux \$*" >> "$MOCK_LOG"
    if echo "\$*" | grep -q "send-keys"; then
        return \${MOCK_SENDKEYS_RC:-0}
    fi
    if echo "\$*" | grep -q "pane_current_command"; then
        # ★実装は pane_id と前景プロセスを一度に問い合わせる
        printf '%s|%s\n' "\${MOCK_PANE_ID-%0}" "\${MOCK_FOREGROUND:-}"
        return 0
    fi
    if echo "\$*" | grep -q "pane_id"; then
        return "\${MOCK_PANE_ID_RC:-0}"
    fi
    echo "%1"
    return 0
}
timeout() { shift; "\$@"; }
sleep() { :; }
log() { echo "[switch_cli] \$*" >&2; }
export -f tmux timeout sleep log

source "$PREFLIGHT_LIB"

# switch_cli.sh の gate 対象打鍵領域だけを取り出して評価する。
# ★main 処理は実行しない(実 pane へ打鍵させぬため)。
SC_HUMAN_INITIATED=\${SC_HUMAN_INITIATED:-0}
_gate_region="\$(awk '/打鍵の入口 \(cmd_754/,/preflight gate 対象打鍵ここまで/' "$SWITCH_CLI")"
eval "\$_gate_region"
HARNESS
    chmod +x "$TEST_HARNESS"

    # ── cli_restart 行動試験用: inbox_watcher.sh 本体を関数定義のみ
    #    ロードするハーネス($TEST_INBOX で対象inboxファイルを差替可能)。
    #    実 pane には一切触れない(tmux は全モック)。
    export TEST_INBOX_DIR="$TEST_TMPDIR/queue/inbox"
    mkdir -p "$TEST_INBOX_DIR"
    cat > "$TEST_INBOX_DIR/test_agent.yaml" << 'YAML'
messages: []
YAML

    # ★cmd_760 A-4 新task(V-1配線証明): SCRIPT_DIR と source 対象を
    #   TEST_SCRIPT_DIR / TEST_WATCHER_SCRIPT で外部注入可能にした。
    #   両者とも既定値は従来どおり(実project root / 本番working tree)
    #   なので、T-SC-014・016〜022はこの変更による挙動差分を受けない。
    #   T-SC-023〜026だけが SCRIPT_DIR=STUB_EXEC_ROOT かつ隔離/変異コピー
    #   をsourceすることで、「配線されたstub」を実際に検証する。
    export WATCHER_HARNESS="$TEST_TMPDIR/watcher_harness.sh"
    cat > "$WATCHER_HARNESS" << HARNESS
#!/bin/bash
AGENT_ID="\${TEST_AGENT_ID:-test_agent}"
PANE_TARGET="test:0.0"
CLI_TYPE="\${TEST_CLI_TYPE:-claude}"
INBOX="\${TEST_INBOX:-$TEST_INBOX_DIR/test_agent.yaml}"
LOCKFILE="\${INBOX}.lock"
SCRIPT_DIR="\${TEST_SCRIPT_DIR:-$PROJECT_ROOT}"

tmux() {
    echo "tmux \$*" >> "$MOCK_LOG"
    if echo "\$*" | grep -q "show-options"; then
        echo ""
        return 0
    fi
    if echo "\$*" | grep -q "send-keys"; then
        return \${MOCK_SENDKEYS_RC:-0}
    fi
    if echo "\$*" | grep -q "capture-pane"; then
        printf '%s\n' ""
        return 0
    fi
    return 0
}
timeout() { shift; "\$@"; }
sleep() { :; }
export -f tmux timeout sleep

export __INBOX_WATCHER_TESTING__=1
source "\${TEST_WATCHER_SCRIPT:-$WATCHER_SCRIPT}"
HARNESS
    chmod +x "$WATCHER_HARNESS"

    # ── stub/sentinel実行検証用(cmd_760 A-4 redo2) ──
    #    本番の scripts/switch_cli.sh 自体は書き換えない。隔離した実行
    #    環境(STUB_EXEC_ROOT)へ「呼ばれたらsentinelファイルを作るだけ」
    #    のstubを配置する。sentinelは mktemp -d で試験ごとに新規作成し、
    #    $TEST_TMPDIR 配下ゆえ既存の teardown() で自動的に後始末される
    #    (D002-E1準拠・新たな rm -rf は書かない)。
    local sentinel_dir
    sentinel_dir="$(mktemp -d "$TEST_TMPDIR/sentinel.XXXXXX")"
    export SENTINEL_FILE="$sentinel_dir/called"

    export STUB_EXEC_ROOT="$TEST_TMPDIR/stub_exec_root"
    mkdir -p "$STUB_EXEC_ROOT/scripts"
    cat > "$STUB_EXEC_ROOT/scripts/switch_cli.sh" << STUB
#!/bin/bash
# T-SC-014系(cmd_760 A-4 redo2)専用の試験stub。呼ばれた痕跡として
# sentinelファイルを作るだけであり、本番の switch_cli.sh の代わりに
# この隔離実行環境(STUB_EXEC_ROOT)へのみ配置する。本番ファイルは
# 一切書き換えない。
touch "$SENTINEL_FILE"
exit 0
STUB
    chmod +x "$STUB_EXEC_ROOT/scripts/switch_cli.sh"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

# ── V-2ヘルパー(cmd_760 A-4 新task) ──
# 本番 scripts/inbox_watcher.sh の cli_restart 人手案内行(唯一のアンカー
# 文字列 [CLI-RESTART-HUMAN-PATH] を含む1行)を、引数で渡された実行行へ
# そのまま置換した隔離コピーを $TEST_TMPDIR 配下(mktemp -d由来・
# D002-E1準拠)へ書き出す。本番ファイルは Read するだけで一切書き換えない。
# これは「禁止パターンの有無を正規表現で判定する」旧方式(redo1で廃止済み)
# とは別物で、隔離コピーという★試験fixtureを組み立てるための単純な
# アンカー文字列置換である(検出ロジックではない)。
make_v2_mutant() {
    local out="$1"
    local replacement_line="$2"
    local matches
    matches="$(grep -c 'CLI-RESTART-HUMAN-PATH' "$WATCHER_SCRIPT")"
    if [ "$matches" -ne 1 ]; then
        echo "[make_v2_mutant] anchor 'CLI-RESTART-HUMAN-PATH' は本番ファイル中に $matches 件(期待値1)" >&2
        return 1
    fi
    awk -v repl="$replacement_line" '
        /\[CLI-RESTART-HUMAN-PATH\]/ { print repl; next }
        { print }
    ' "$WATCHER_SCRIPT" > "$out"
    bash -n "$out"
}

@test "T-SC-001: 生の tmux send-keys は sc_send_keys の1箇所のみで gate を通る" {
    local code_only n body
    code_only="$(grep -vE '^[[:space:]]*#' "$SWITCH_CLI")"
    n="$(echo "$code_only" | grep -cE 'tmux send-keys' || true)"
    [ "$n" -eq 1 ]
    body="$(awk '/^sc_send_keys\(\)/,/^}/' "$SWITCH_CLI")"
    echo "$body" | grep -qE 'tmux send-keys'
    # ★必ず人手起動の gate を通してから撃つこと
    echo "$body" | grep -q 'sc_human_gate'
}

@test "T-SC-002: 人手起動でなければ send_exit は1打鍵も送らず rc=1" {
    run bash -c "SC_HUMAN_INITIATED=0; source '$TEST_HARNESS'; send_exit test:0.0 claude; echo RC=\$?"
    echo "$output" | grep -q "RC=1"
    ! grep -q "send-keys" "$MOCK_LOG"
    echo "$output" | grep -q "NO-AUTO-SEND"
}

@test "T-SC-003: 人手起動でなければ launch_new_cli も送らず rc=3" {
    run bash -c "SC_HUMAN_INITIATED=0; MOCK_FOREGROUND=bash; source '$TEST_HARNESS'; launch_new_cli test:0.0 'claude --model opus'; echo RC=\$?"
    echo "$output" | grep -q "RC=3"
    ! grep -q "send-keys" "$MOCK_LOG"
}

@test "T-SC-004: 人手起動なら send_exit(claude) は /exit と Enter を送る" {
    run bash -c "SC_HUMAN_INITIATED=1; source '$TEST_HARNESS'; send_exit test:0.0 claude; echo RC=\$?"
    echo "$output" | grep -q "RC=0"
    grep -q "send-keys -t test:0.0 /exit" "$MOCK_LOG"
    grep -qE "send-keys -t test:0\.0 Enter" "$MOCK_LOG"
}

@test "T-SC-005: 人手起動なら send_exit(codex) は Escape/C-c/文字列/Enter を送る" {
    run bash -c "SC_HUMAN_INITIATED=1; source '$TEST_HARNESS'; send_exit test:0.0 codex; echo RC=\$?"
    echo "$output" | grep -q "RC=0"
    grep -q "send-keys -t test:0.0 Escape" "$MOCK_LOG"
    grep -q "send-keys -t test:0.0 C-c" "$MOCK_LOG"
    grep -q "send-keys -t test:0.0 /exit" "$MOCK_LOG"
}

@test "T-SC-006: launch_new_cli は前景が素のシェルでなければ起動しない (rc=3)" {
    run bash -c "SC_HUMAN_INITIATED=1; MOCK_FOREGROUND=claude; source '$TEST_HARNESS'; launch_new_cli test:0.0 'claude --model opus'; echo RC=\$?"
    echo "$output" | grep -q "RC=3"
    ! grep -q "send-keys" "$MOCK_LOG"
    echo "$output" | grep -q "素のシェルではない"
}

@test "T-SC-007: launch_new_cli 正常系 — 素のシェルなら起動打鍵と Enter を送る" {
    run bash -c "SC_HUMAN_INITIATED=1; MOCK_FOREGROUND=bash; source '$TEST_HARNESS'; launch_new_cli test:0.0 'claude --model opus'; echo RC=\$?"
    echo "$output" | grep -q "RC=0"
    grep -q "send-keys -t test:0.0 claude --model opus" "$MOCK_LOG"
    grep -qE "send-keys -t test:0\.0 Enter" "$MOCK_LOG"
}

@test "T-SC-008: 打鍵の配送失敗は rc=2 で伝播し、以降の打鍵を送らない" {
    run bash -c "SC_HUMAN_INITIATED=1; MOCK_SENDKEYS_RC=7; source '$TEST_HARNESS'; sc_send_keys test:0.0 claude '試験打鍵' X; echo RC=\$?"
    echo "$output" | grep -q "RC=2"
    echo "$output" | grep -q "SEND-FAILURE"
    # send_exit も配送失敗で中断すること
    > "$MOCK_LOG"
    run bash -c "SC_HUMAN_INITIATED=1; MOCK_SENDKEYS_RC=7; source '$TEST_HARNESS'; send_exit test:0.0 claude; echo RC=\$?"
    ! echo "$output" | grep -q "RC=0"
}

@test "T-SC-009: pane_is_bare_shell 未ロード時は起動しない (fail-safe)" {
    run bash -c "SC_HUMAN_INITIATED=1; source '$TEST_HARNESS'; unset -f pane_is_bare_shell; launch_new_cli test:0.0 'claude'; echo RC=\$?"
    echo "$output" | grep -q "RC=3"
    ! grep -q "send-keys" "$MOCK_LOG"
}

@test "T-SC-010: 送らなかったことは黙って落とさずログへ残る" {
    run bash -c "SC_HUMAN_INITIATED=0; source '$TEST_HARNESS'; send_exit test:0.0 claude"
    echo "$output" | grep -q "NO-AUTO-SEND"
    echo "$output" | grep -q "human-initiated"
}

@test "T-SC-011: ★実コードに capture-pane が無い (画面からの推論をやめた)" {
    local code_only n
    code_only="$(grep -vE '^[[:space:]]*#' "$SWITCH_CLI")"
    n="$(echo "$code_only" | grep -cE 'capture-pane' || true)"
    [ "$n" -eq 0 ]
}

@test "T-SC-012: モーダルへ答える打鍵を持たない (スコープ外・厳禁)" {
    local code_only
    code_only="$(grep -vE '^[[:space:]]*#' "$SWITCH_CLI")"
    ! echo "$code_only" | grep -qE 'send-keys[^|]*"(1|2|3|y|Y|n|N|Yes|No|yes|no)"'
    ! echo "$code_only" | grep -qE 'send-keys[^|]*(Down|Up)([[:space:]]|$)'
}

@test "T-SC-013: --human-initiated は引数解析で明示的に立てられる" {
    grep -q -- '--human-initiated)' "$SWITCH_CLI"
    grep -q 'SC_HUMAN_INITIATED=1' "$SWITCH_CLI"
    # 既定は 0 (打鍵しない側)
    grep -q '^SC_HUMAN_INITIATED=0' "$SWITCH_CLI"
}

@test "T-SC-014: 自動経路(inbox_watcher)は switch_cli.sh を実行しない(stub/sentinel実行検証)" {
    # ★cmd_760 A-4 redo2: 静的パターン照合(assert_no_switch_cli_auto_exec)
    #   を全廃し、実行検証(stub/sentinel方式)へ置換した。「禁止パターンが
    #   無い」という消極的証拠ではなく、「実際に実行しても呼ばれない」と
    #   いう積極的実験で確認する(将軍裁定 2026-09-10)。
    # 本番の scripts/inbox_watcher.sh・scripts/switch_cli.sh は無変更。
    # $STUB_EXEC_ROOT へ cd してから実関数を呼ぶことで、「もし
    # send_cli_command が相対パスで switch_cli.sh を実行するように将来
    # 変わったら、本試験は確実にそれを検知する」配線にした上で、現行実装
    # (人手案内のechoのみ)がその配線の下でも無実行であることを示す。
    run bash -c '
        cd "$1" || exit 99
        source "$2"
        marker=$(normalize_special_command cli_restart "--model opus")
        send_cli_command "$marker"
        echo RC=$?
    ' _ "$STUB_EXEC_ROOT" "$WATCHER_HARNESS"
    echo "$output" | grep -q "RC=1"
    [ ! -f "$SENTINEL_FILE" ]
    # 人へ「こう打て」と案内する文字列は残ってよい(E-3 の人経路)。
    # ★このテキストが実際の実行を伴わないことは上のsentinel不在で
    #   証明済み(旧T-SC-020の関心をここへ統合)。
    echo "$output" | grep -q 'switch_cli.sh'
    echo "$output" | grep -q -- "--human-initiated"
}

@test "T-SC-015: 自己検証 — stub/sentinel機構は実行されれば確実にsentinelを立てる" {
    # ★T-SC-014が「呼ばれない」ことを示す土台として、まず「呼ばれれば
    #   sentinelが立つ」ことを自己検証する。この裏付けが無いと、配線の
    #   誤りにより常にsentinelが立たない(=見せかけの合格)可能性を排除
    #   できない(redo1でT-SC-014が空振りでPASSしていた事故と同型のリスク
    #   を、置換後の新方式についても潰しておく)。
    [ ! -f "$SENTINEL_FILE" ]
    run bash -c '
        cd "$1" || exit 99
        bash scripts/switch_cli.sh agent --human-initiated
        echo RC=$?
    ' _ "$STUB_EXEC_ROOT"
    echo "$output" | grep -q "RC=0"
    [ -f "$SENTINEL_FILE" ]
}

@test "T-SC-016: cli_restart処理後もinboxエントリは read:false のまま残る(未読保持)" {
    export TEST_INBOX="$TEST_INBOX_DIR/test_agent.yaml"
    cat > "$TEST_INBOX" << 'YAML'
messages:
  - id: msg_restart
    from: karo
    timestamp: "2026-09-10T10:00:00+09:00"
    type: cli_restart
    content: "--model opus"
    read: false
YAML
    run bash -c "export TEST_INBOX='$TEST_INBOX'; source '$WATCHER_HARNESS'; get_unread_info"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"type": "cli_restart"'

    run "$VENV_PYTHON" -c "
import yaml
d = yaml.safe_load(open('$TEST_INBOX'))
m = [x for x in d['messages'] if x['id'] == 'msg_restart'][0]
print('READ=%s' % m['read'])
"
    echo "$output" | grep -q "READ=False"
}

@test "T-SC-017: send_cli_command は cli_restart マーカーを実行委譲せず人手案内をログへ残す" {
    run bash -c "source '$WATCHER_HARNESS'; send_cli_command '__CLI_RESTART__:--model opus'; echo RC=\$?"
    echo "$output" | grep -q "RC=1"
    echo "$output" | grep -q -- "--human-initiated"
    echo "$output" | grep -q "switch_cli.sh"
    ! grep -q "send-keys" "$MOCK_LOG"
}

@test "T-SC-018: normalize_special_command は clear_command/model_switch/cli_restart を正しく変換する" {
    run bash -c "source '$WATCHER_HARNESS'; normalize_special_command clear_command ''"
    [ "$status" -eq 0 ]
    [ "$output" = "/clear" ]

    run bash -c "source '$WATCHER_HARNESS'; normalize_special_command model_switch '/model opus'"
    [ "$status" -eq 0 ]
    [ "$output" = "/model opus" ]

    run bash -c "source '$WATCHER_HARNESS'; normalize_special_command cli_restart '--model opus'"
    [ "$status" -eq 0 ]
    [ "$output" = "__CLI_RESTART__:--model opus" ]
}

@test "T-SC-019: get_unread_info は clear_command/model_switch のみ既読化し cli_restart は未読のまま残す" {
    export TEST_INBOX="$TEST_INBOX_DIR/test_agent.yaml"
    cat > "$TEST_INBOX" << 'YAML'
messages:
  - id: msg_clear
    from: karo
    timestamp: "2026-09-10T10:00:00+09:00"
    type: clear_command
    content: redo
    read: false
  - id: msg_model
    from: karo
    timestamp: "2026-09-10T10:00:01+09:00"
    type: model_switch
    content: "/model opus"
    read: false
  - id: msg_restart
    from: karo
    timestamp: "2026-09-10T10:00:02+09:00"
    type: cli_restart
    content: "--model opus"
    read: false
YAML
    run bash -c "export TEST_INBOX='$TEST_INBOX'; source '$WATCHER_HARNESS'; get_unread_info"
    [ "$status" -eq 0 ]

    run "$VENV_PYTHON" -c "
import yaml
d = yaml.safe_load(open('$TEST_INBOX'))
byid = {x['id']: x['read'] for x in d['messages']}
print('CLEAR=%s MODEL=%s RESTART=%s' % (byid['msg_clear'], byid['msg_model'], byid['msg_restart']))
"
    echo "$output" | grep -q "CLEAR=True MODEL=True RESTART=False"
}

@test "T-SC-023: 配線証明(V-1) — 違反コピーは赤、直後に同一配線で本番コピーは緑(証明順序厳守)" {
    # ★cmd_760 A-4 新task(redo3ではない・将軍裁定 2026-09-10)。
    #   redo2の欠陥: T-SC-014が使うWATCHER_HARNESSはSCRIPT_DIRを実project
    #   rootへ固定していた。本番の呼出し経路
    #   ${SCRIPT_DIR}/scripts/switch_cli.sh がSTUB_EXEC_ROOTのstubへ
    #   一度も解決されておらず、「配線されていないstubは何も証明しない」
    #   (将軍指摘)。本testはSCRIPT_DIRをSTUB_EXEC_ROOTへ実際に注入した
    #   上で、(a) cli_restart自動実行を復活させた隔離コピーでsentinelが
    #   ★赤くなることを先に示し、(b) 同じ配線・同じSTUB_EXEC_ROOTで、
    #   無変更の本番コピー(working tree)がsentinelを立てない(★緑)こと
    #   を後で示す。赤くできる配線でだけ緑に意味がある、という将軍指定の
    #   順序を1 test内で強制し、bats実行順序への依存を避けた。
    #
    # ★cmd_760 A-4 stub/sentinel配線証明redo1(G760-A4-V1-HEAD-EPHEMERAL-01
    #   是正): 違反コピーはgitの可変HEADからではなく、現在のworktree
    #   source($WATCHER_SCRIPT)へ、唯一のアンカー[CLI-RESTART-HUMAN-PATH]
    #   を基準に旧自動委譲行相当を実行行として注入して作る(make_v2_mutant
    #   を転用・詳細はファイル末尾の redo1 節)。commit後・clean checkout後
    #   を問わず常に同じ手順で再構成できる。

    # 本番ファイル(working treeのscripts/inbox_watcher.sh)は Read するだけ
    # で一切書き換えない。書き出し先は$TEST_TMPDIR配下(setup()でmktemp -d
    # 捕捉済み・D002-E1準拠)。make_v2_mutant内でbash -n済み。
    local violating_copy="$TEST_TMPDIR/inbox_watcher_violating.sh"
    make_v2_mutant "$violating_copy" '        bash "${SCRIPT_DIR}/scripts/switch_cli.sh" "$AGENT_ID" $restart_args'
    # 前提健全性: この隔離コピーが実際にswitch_cli.shへ自動委譲することを自己確認。
    grep -qF '${SCRIPT_DIR}/scripts/switch_cli.sh' "$violating_copy"

    # (a) ★赤: 違反コピー・SCRIPT_DIR=STUB_EXEC_ROOT
    run bash -c "
        export TEST_SCRIPT_DIR='$STUB_EXEC_ROOT'
        export TEST_WATCHER_SCRIPT='$violating_copy'
        source '$WATCHER_HARNESS'
        marker=\$(normalize_special_command cli_restart '--model opus')
        send_cli_command \"\$marker\"
        echo RC=\$?
    "
    echo "$output" | grep -q "RC=1"
    [ -f "$SENTINEL_FILE" ]

    rm -f "$SENTINEL_FILE"

    # (b) ★緑: 同じSTUB_EXEC_ROOT・無変更の本番コピー(working tree)
    run bash -c "
        export TEST_SCRIPT_DIR='$STUB_EXEC_ROOT'
        export TEST_WATCHER_SCRIPT='$WATCHER_SCRIPT'
        source '$WATCHER_HARNESS'
        marker=\$(normalize_special_command cli_restart '--model opus')
        send_cli_command \"\$marker\"
        echo RC=\$?
    "
    echo "$output" | grep -q "RC=1"
    [ ! -f "$SENTINEL_FILE" ]
}

@test "T-SC-024: 配線証明(V-2 変異1/3) — echo後段でのbash実行を実行行として注入すると赤くなる" {
    # ★S-3 変異例1/3(閉じたリスト・将軍指定)。redo2(T-SC-020)は同じ文字列
    #   をnormalize_special_commandへの★文字列引数として渡しただけで、
    #   実行行として注入していなかった(将軍指摘)。本testは隔離コピーの
    #   [CLI-RESTART-HUMAN-PATH]行そのものをこの文字列へ★置換し、コード
    #   として実行する。V-1と同じ配線(SCRIPT_DIR=STUB_EXEC_ROOT)を使う。
    local mutant="$TEST_TMPDIR/inbox_watcher_v2_1.sh"
    make_v2_mutant "$mutant" '        echo ok; bash scripts/switch_cli.sh agent --human-initiated'

    # 変異行は $SCRIPT_DIR を介さない相対パスのため、STUB_EXEC_ROOTへcdする。
    run bash -c "
        cd '$STUB_EXEC_ROOT' || exit 99
        export TEST_SCRIPT_DIR='$STUB_EXEC_ROOT'
        export TEST_WATCHER_SCRIPT='$mutant'
        source '$WATCHER_HARNESS'
        marker=\$(normalize_special_command cli_restart '--model opus')
        send_cli_command \"\$marker\"
        echo RC=\$?
    "
    echo "$output" | grep -q "RC=1"
    [ -f "$SENTINEL_FILE" ]
}

@test "T-SC-025: 配線証明(V-2 変異2/3) — printf後段でのexec実行を実行行として注入すると赤くなる" {
    # ★S-3 変異例2/3(閉じたリスト・将軍指定)。
    local mutant="$TEST_TMPDIR/inbox_watcher_v2_2.sh"
    make_v2_mutant "$mutant" '        printf ok; exec scripts/switch_cli.sh agent --human-initiated'

    run bash -c "
        cd '$STUB_EXEC_ROOT' || exit 99
        export TEST_SCRIPT_DIR='$STUB_EXEC_ROOT'
        export TEST_WATCHER_SCRIPT='$mutant'
        source '$WATCHER_HARNESS'
        marker=\$(normalize_special_command cli_restart '--model opus')
        send_cli_command \"\$marker\"
        echo RC=\$?
    "
    # ★execは現プロセス像をswitch_cli.sh(stub)へ置換するため、制御は
    #   send_cli_command・このbash -cへ戻らず、以降の echo RC=\$? は
    #   実行されない。RC出力の有無ではなくsentinelの存在のみで判定する。
    [ -f "$SENTINEL_FILE" ]
}

@test "T-SC-026: 配線証明(V-2 変異3/3) — command substitution経由の実行を実行行として注入すると赤くなる" {
    # ★S-3 変異例3/3(閉じたリスト・将軍指定)。
    local mutant="$TEST_TMPDIR/inbox_watcher_v2_3.sh"
    make_v2_mutant "$mutant" '        echo "$(bash scripts/switch_cli.sh agent --human-initiated)"'

    run bash -c "
        cd '$STUB_EXEC_ROOT' || exit 99
        export TEST_SCRIPT_DIR='$STUB_EXEC_ROOT'
        export TEST_WATCHER_SCRIPT='$mutant'
        source '$WATCHER_HARNESS'
        marker=\$(normalize_special_command cli_restart '--model opus')
        send_cli_command \"\$marker\"
        echo RC=\$?
    "
    echo "$output" | grep -q "RC=1"
    [ -f "$SENTINEL_FILE" ]
}
