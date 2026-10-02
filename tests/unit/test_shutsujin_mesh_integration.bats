#!/usr/bin/env bats
# test_shutsujin_mesh_integration.bats — shutsujin_departure.sh の
# mesh登録preflight(STEP 6.9・shutsujin_mesh_check関数)統合試験
# cmd_759 redo1 (subtask_759_peer_name_agent_id_alignment_v2_redo1)
#
# 前回(cmd_759初回)は lib/mesh_registration_check.sh のpure logicのみを
# 検査しており、shutsujin_departure.sh本体の以下4点は一切未到達だった:
#   G759-ERREXIT-01: set -e下での単純代入によるshell即時終了
#   G759-DASHBOARD-PATH-02: state file書込みのみでconsumerが無い
#   G759-STATE-DIR-03: queue/state未作成のclean環境での失敗
#   G759-TEST-COVERAGE-05: 6リテラル・実効経路を通す統合試験の不在
# 本ファイルはこの4点を統合的に検証する。
#
# テスト構成:
#   T-MI-001: 未登録検知時、set -e下でも継続し一覧蓄積・state書込みへ到達する
#   T-MI-002: 未登録が1件以上あれば家老inboxへdelivery_alert型で通知される
#   T-MI-003: 全員登録済みなら家老inboxへは通知しない
#   T-MI-004: clean環境(queue/state不在)でも書込み時にディレクトリが作成される
#   T-MI-005: shutsujin_departure.sh本体の--name literal 6箇所(静的検査)
#   T-MI-006: STEP 2のqueue/state作成保証コード(静的検査)
#   T-MI-007: 単純代入(if外)が存在しないことの静的検査(将来の回帰防止)
#   T-MI-008: 家老へのinbox通知自体が失敗してもscript全体は継続する
#
# cmd_759 redo2 (G759-REDO1-DOC-SIDE-EFFECT-01): redo1はinbox_write.sh
# 呼出しによりKaro inboxへ★永続書込みを行うが、これを「read-only記録の
# み」と読める記述がshutsujin_departure.sh/docs/delivery_channels.md側に
# 残っていた。T-MI-009〜011はこれを是正した記述を固定する。いずれも
# 「Karo inbox handoffまで」を検査範囲とし、dashboard.md自体の更新
# (家老のInbox Processing Protocolが担う別工程)までは検査対象としない。
#   T-MI-009: delivery_alert通知contentの要点(count・state path・
#             再起動なしの旨)を固定する
#   T-MI-010: shutsujin_departure.shのコメントがdelivery_alert副作用を
#             明記し、誤解を招く表現が残っていないことの静的検査
#   T-MI-011: docs/delivery_channels.mdがstate→Karo inbox→dashboardの
#             handoff経路を明記し、誤解を招く表現を含まないことの
#             静的検査

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export SHUTSUJIN="$PROJECT_ROOT/shutsujin_departure.sh"
    [ -f "$SHUTSUJIN" ] || return 1
}

setup() {
    TEST_TMP="$(mktemp -d)"
    FN_FILE="$TEST_TMP/mesh_check_fn.sh"
    awk '/^shutsujin_mesh_check\(\) \{/,/^}/' "$SHUTSUJIN" > "$FN_FILE"
    # 関数抽出そのものが壊れていないかの前提チェック(空なら以降の全testが無意味に緑化するため)
    [ -s "$FN_FILE" ]
    grep -q '^shutsujin_mesh_check() {' "$FN_FILE"
}

teardown() {
    rm -rf "$TEST_TMP"
}

# ─────────────────────────────────────────────────────────────
# T-MI-001〜T-MI-004, T-MI-008: 実効経路(関数を実際に実行)
# ─────────────────────────────────────────────────────────────

@test "T-MI-001: 未登録pane検知時もset -e下でscriptが継続し一覧蓄積・state書込みへ到達する(G759-ERREXIT-01)" {
    cat > "$TEST_TMP/harness.sh" << HARNESS
#!/bin/bash
set -e
SCRIPT_DIR="$TEST_TMP"
AGENT_IDS=(ashigaru1 ashigaru2)
PANE_BASE=0
log_info() { :; }
log_success() { :; }
tmux() {
    if [[ "\$*" == *"show-options"* ]]; then echo "claude"; return 0; fi
    return 0
}
check_mesh_registration() {
    echo "unregistered:no_socket:99999"
    return 1
}
source "$FN_FILE"
shutsujin_mesh_check
echo "REACHED_END rc=\$?"
HARNESS
    run bash "$TEST_TMP/harness.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "REACHED_END rc=0"
    [ -f "$TEST_TMP/queue/state/mesh_registration_status.yaml" ]
    # shogun + ashigaru1 + ashigaru2 = 3件全て未登録として蓄積されていること
    # (単純代入バグが再発すれば、1件目で shell が落ちて到達しない)
    grep -q "checked: 3" "$TEST_TMP/queue/state/mesh_registration_status.yaml"
    grep -q "unregistered_count: 3" "$TEST_TMP/queue/state/mesh_registration_status.yaml"
    grep -q 'agent_id: "shogun"' "$TEST_TMP/queue/state/mesh_registration_status.yaml"
    grep -q 'agent_id: "ashigaru1"' "$TEST_TMP/queue/state/mesh_registration_status.yaml"
    grep -q 'agent_id: "ashigaru2"' "$TEST_TMP/queue/state/mesh_registration_status.yaml"
}

@test "T-MI-002: 未登録が1件以上あれば家老inboxへdelivery_alert型で通知が送られる(G759-DASHBOARD-PATH-02)" {
    mkdir -p "$TEST_TMP/scripts"
    cat > "$TEST_TMP/scripts/inbox_write.sh" << 'MOCK'
#!/bin/bash
echo "CALLED:$1:$3:$4" >> "$MOCK_LOG"
exit 0
MOCK
    chmod +x "$TEST_TMP/scripts/inbox_write.sh"
    : > "$TEST_TMP/inbox_calls.log"

    cat > "$TEST_TMP/harness.sh" << HARNESS
#!/bin/bash
set -e
export MOCK_LOG="$TEST_TMP/inbox_calls.log"
SCRIPT_DIR="$TEST_TMP"
AGENT_IDS=(ashigaru1)
PANE_BASE=0
log_info() { :; }
log_success() { :; }
tmux() {
    if [[ "\$*" == *"show-options"* ]]; then echo "claude"; return 0; fi
    return 0
}
check_mesh_registration() {
    echo "unregistered:no_socket:12345"
    return 1
}
source "$FN_FILE"
shutsujin_mesh_check
HARNESS
    run bash "$TEST_TMP/harness.sh"
    [ "$status" -eq 0 ]
    # target=karo, type=delivery_alert, from=shutsujin_departure であること
    # (contentは可変のため$2は検査しない)
    grep -qF -- "CALLED:karo:delivery_alert:shutsujin_departure" "$TEST_TMP/inbox_calls.log"
}

@test "T-MI-003: 全員mesh登録済みなら家老inboxへは通知しない" {
    mkdir -p "$TEST_TMP/scripts"
    cat > "$TEST_TMP/scripts/inbox_write.sh" << 'MOCK'
#!/bin/bash
echo "CALLED" >> "$MOCK_LOG"
exit 0
MOCK
    chmod +x "$TEST_TMP/scripts/inbox_write.sh"
    : > "$TEST_TMP/inbox_calls.log"

    cat > "$TEST_TMP/harness.sh" << HARNESS
#!/bin/bash
set -e
export MOCK_LOG="$TEST_TMP/inbox_calls.log"
SCRIPT_DIR="$TEST_TMP"
AGENT_IDS=(ashigaru1)
PANE_BASE=0
log_info() { :; }
log_success() { :; }
tmux() {
    if [[ "\$*" == *"show-options"* ]]; then echo "claude"; return 0; fi
    return 0
}
check_mesh_registration() {
    echo "registered:54321"
    return 0
}
source "$FN_FILE"
shutsujin_mesh_check
HARNESS
    run bash "$TEST_TMP/harness.sh"
    [ "$status" -eq 0 ]
    [ ! -s "$TEST_TMP/inbox_calls.log" ]
    grep -q "unregistered_count: 0" "$TEST_TMP/queue/state/mesh_registration_status.yaml"
    grep -q "unregistered: \[\]" "$TEST_TMP/queue/state/mesh_registration_status.yaml"
}

@test "T-MI-004: clean環境(queue/state不在)でも書込み時にディレクトリが作成される(G759-STATE-DIR-03)" {
    [ ! -d "$TEST_TMP/queue" ]

    cat > "$TEST_TMP/harness.sh" << HARNESS
#!/bin/bash
set -e
SCRIPT_DIR="$TEST_TMP"
AGENT_IDS=()
PANE_BASE=0
log_info() { :; }
log_success() { :; }
tmux() { echo "claude"; return 0; }
check_mesh_registration() { echo "registered:1"; return 0; }
source "$FN_FILE"
shutsujin_mesh_check
HARNESS
    run bash "$TEST_TMP/harness.sh"
    [ "$status" -eq 0 ]
    [ -d "$TEST_TMP/queue/state" ]
    [ -f "$TEST_TMP/queue/state/mesh_registration_status.yaml" ]
}

@test "T-MI-008: 家老へのinbox通知自体が失敗してもset -e下でscript全体は継続する" {
    mkdir -p "$TEST_TMP/scripts"
    cat > "$TEST_TMP/scripts/inbox_write.sh" << 'MOCK'
#!/bin/bash
exit 1
MOCK
    chmod +x "$TEST_TMP/scripts/inbox_write.sh"

    cat > "$TEST_TMP/harness.sh" << HARNESS
#!/bin/bash
set -e
SCRIPT_DIR="$TEST_TMP"
AGENT_IDS=(ashigaru1)
PANE_BASE=0
LOG_FILE="$TEST_TMP/log.txt"
log_info() { echo "[log_info] \$*" >> "\$LOG_FILE"; }
log_success() { :; }
tmux() {
    if [[ "\$*" == *"show-options"* ]]; then echo "claude"; return 0; fi
    return 0
}
check_mesh_registration() {
    echo "unregistered:no_socket:1"
    return 1
}
source "$FN_FILE"
shutsujin_mesh_check
echo "REACHED_END rc=\$?"
HARNESS
    run bash "$TEST_TMP/harness.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "REACHED_END rc=0"
    grep -q "家老へのinbox通知に失敗" "$TEST_TMP/log.txt"
}

# ─────────────────────────────────────────────────────────────
# T-MI-005〜T-MI-007: 静的検査(shutsujin_departure.sh本体・抽出関数)
# ─────────────────────────────────────────────────────────────

@test "T-MI-005: shutsujin_departure.sh本体の--name literalは正確に6箇所(shogun1・karo1・ashigaru\${i}×3・gunshi1)" {
    local shogun_n karo_n ashi_n gunshi_n total
    shogun_n=$(grep -cF -- '--name shogun ' "$SHUTSUJIN")
    karo_n=$(grep -cF -- '--name karo ' "$SHUTSUJIN")
    ashi_n=$(grep -cF -- '--name ashigaru${i} ' "$SHUTSUJIN")
    gunshi_n=$(grep -cF -- '--name gunshi ' "$SHUTSUJIN")
    [ "$shogun_n" -eq 1 ]
    [ "$karo_n" -eq 1 ]
    [ "$ashi_n" -eq 3 ]
    [ "$gunshi_n" -eq 1 ]
    total=$((shogun_n + karo_n + ashi_n + gunshi_n))
    [ "$total" -eq 6 ]
}

@test "T-MI-006: STEP 2でqueue/stateディレクトリ作成保証コードが存在する(G759-STATE-DIR-03静的検査)" {
    grep -qF -- '[ -d ./queue/state ] || mkdir -p ./queue/state' "$SHUTSUJIN"
}

@test "T-MI-007: shutsujin_mesh_check内にcheck_mesh_registrationの単純代入(if外)が存在しない(G759-ERREXIT-01回帰防止)" {
    # 危険な形(単純代入。set -e下で最初の未登録がshellを即終了させる)が
    # 存在しないことを確認する。
    run grep -nE '^[[:space:]]*_mesh_result=\$\(check_mesh_registration' "$FN_FILE"
    [ "$status" -ne 0 ]
    # 正しい形(明示的な条件文の中での捕捉)が存在することを確認する。
    grep -qE 'if ! _mesh_result=\$\(check_mesh_registration' "$FN_FILE"
}

# ─────────────────────────────────────────────────────────────
# T-MI-009〜T-MI-011: cmd_759 redo2 (G759-REDO1-DOC-SIDE-EFFECT-01)
# ─────────────────────────────────────────────────────────────

@test "T-MI-009: delivery_alert通知のcontentがcount・state path・再起動なしの旨を含む(G759-REDO1-DOC-SIDE-EFFECT-01・Karo inbox handoffまでを検査範囲とする)" {
    mkdir -p "$TEST_TMP/scripts"
    cat > "$TEST_TMP/scripts/inbox_write.sh" << 'MOCK'
#!/bin/bash
echo "$2" > "$MOCK_CONTENT_FILE"
exit 0
MOCK
    chmod +x "$TEST_TMP/scripts/inbox_write.sh"

    cat > "$TEST_TMP/harness.sh" << HARNESS
#!/bin/bash
set -e
export MOCK_CONTENT_FILE="$TEST_TMP/inbox_content.txt"
SCRIPT_DIR="$TEST_TMP"
AGENT_IDS=(ashigaru1 ashigaru2)
PANE_BASE=0
log_info() { :; }
log_success() { :; }
tmux() {
    if [[ "\$*" == *"show-options"* ]]; then echo "claude"; return 0; fi
    return 0
}
check_mesh_registration() {
    echo "unregistered:no_socket:12345"
    return 1
}
source "$FN_FILE"
shutsujin_mesh_check
HARNESS
    run bash "$TEST_TMP/harness.sh"
    [ "$status" -eq 0 ]
    [ -f "$TEST_TMP/inbox_content.txt" ]
    # shogun + ashigaru1 + ashigaru2 = 3件中3件が未登録 → "3/3" を含む
    grep -qF "3/3" "$TEST_TMP/inbox_content.txt"
    # state path の明記
    grep -qF "queue/state/mesh_registration_status.yaml" "$TEST_TMP/inbox_content.txt"
    # 再起動していない旨の明記
    grep -qF "再起動" "$TEST_TMP/inbox_content.txt"
}

@test "T-MI-010: shutsujin_departure.shのコメントがdelivery_alert副作用を明記し誤解を招く表現が残っていない(G759-REDO1-DOC-SIDE-EFFECT-01静的検査・Karo inbox handoffまでを検査範囲とする)" {
    # redo1で誤解を招いた表現(「read-onlyで記録するのみ」等)が残っていないこと
    run /usr/bin/grep -nE '記録するのみ|記録に留め' "$SHUTSUJIN"
    [ "$status" -ne 0 ]
    # ★将軍直接(Escalation Gate裁定c・2026-09-10): 誤検知時にもstate永続書込み・
    # Karo inbox通知(alert/nudge)が生じるため「実害は生じない/実害なし」という
    # 過大な安全主張が残っていないこと
    run /usr/bin/grep -nE '実害は生じない|実害なし|実害は無い|実害が無い|害は生じない' "$SHUTSUJIN"
    [ "$status" -ne 0 ]
    # delivery_alert通知(Karoへの送信)を行う旨が明記されていること
    /usr/bin/grep -qF "delivery_alert通知" "$SHUTSUJIN"
    # pane観測(observation)がread-onlyであることの記述は維持されていること
    /usr/bin/grep -qF "対象peerへの入力送信・再起動は一切行わない" "$SHUTSUJIN"
}

@test "T-MI-011: docs/delivery_channels.mdがstate→Karo inbox→dashboardのhandoff経路を明記し誤解を招く表現を含まない(G759-REDO1-DOC-SIDE-EFFECT-01静的検査・Karo inbox handoffまでを検査範囲とする)" {
    local docfile="$PROJECT_ROOT/docs/delivery_channels.md"
    [ -f "$docfile" ]
    # redo1で誤解を招いた表現(「read-only に記録するのみ」等)が残っていないこと
    run /usr/bin/grep -nE '記録するのみ|記録に留め' "$docfile"
    [ "$status" -ne 0 ]
    # ★将軍直接(Escalation Gate裁定c・2026-09-10・G759-REDO2-DOC-OVERCLAIM):
    # 誤検知時にもstate永続書込み・Karo inbox通知(alert/nudge)が生じるため、
    # 「実害は生じない」等の過大な安全主張が残っていないこと(否定)
    run /usr/bin/grep -nE '実害は生じない|実害なし|実害は無い|実害が無い|害は生じない' "$docfile"
    [ "$status" -ne 0 ]
    # 誤検知時に副作用(可視なalert/nudge)が生じる旨が明記されていること(肯定)
    /usr/bin/grep -qF "誤検知時にも副作用は生じる" "$docfile"
    # delivery_alert通知の存在と、Karo inboxのInbox Processing Protocolへの
    # handoffが明記されていること(dashboard.md自体の更新は別工程であり、
    # ここではKaro inbox handoffまでを検査範囲とする)
    /usr/bin/grep -qF "delivery_alert" "$docfile"
    /usr/bin/grep -qF "Inbox Processing" "$docfile"
}
