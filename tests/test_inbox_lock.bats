#!/usr/bin/env bats
# test_inbox_lock.bats — inbox_lock.sh ユニット・統合テスト (cmd_706 Phase D)
#
# 対象: queue/inbox/*.yaml の既読更新(mark-read)を、inbox_write.sh /
# inbox_watcher.sh と同じロック(${INBOX}.lock / ${INBOX}.lock.d)経由で
# 行うラッパー (context/cmd_706_design.md Phase A確定版・redo2)。
#
# ★認可層の撤去について (cmd_706 Phase B redo1):
# 初版はcaller(呼び出し元)をtmux @agent_idで識別し、他者inbox操作
# (--repair)をkaro限定で許可する認可層(_inbox_lock_get_caller /
# _inbox_lock_authorize)を持っていた。軍師QCがTMUX_PANE環境変数の
# 差し替えのみでcaller詐称が可能なことを実inbox無変更で独立再現し、
# 将軍裁定によりこの認可層そのものを撤去した(詳細:
# context/cmd_706_design.md §3.4.2)。旧T-CL-23(_inbox_lock_authorize
# 単体test)は対象関数が撤去されたため削除し、旧T-CL-11〜16は
# 「認可なしで成功する・TMUX_PANEは詐称可能な監査参考値としてのみ
# 記録される」ことを検証する形に書き換えた。
#
# ★H-1/H-3対応について (cmd_706 Phase B redo2):
# 軍師QC(C706B-R1-QC-01・03)が2点を指摘した。
#   H-1: _inbox_lock_path_guard(pre-lock・第一防御)はロック取得前に
#        一度だけ判定するため、そこからPython書込(os.replace)までの
#        間にsymlink差替え等が起きても再確認しない設計になっていた。
#        os.replace直前にinbox_pathの実realpathを再取得し、trusted
#        anchor(呼び出し時に固定したqueue/inboxの実体パス)と厳密一致
#        するかを確認する第二防御(書込直前realpath二重確認)を追加した
#        (exit 5相当・原本不変)。T-CL-24はpre-guard(第一防御)が正規に
#        捕捉する静的symlinkケース、T-CL-25はpre-guard通過後・ロック
#        取得後の差替え(TOCTOU)を再現し第二防御を直接検証する。
#   H-3: `--id`値の走査ループが、次の literal `--id` としか比較して
#        いなかったため、`--id msg_a --repair` のように値走査中に
#        option様token(`--`始まり)が現れても未知の引数として拒否
#        されずmessage IDとして吸収してしまう不具合があった。走査中に
#        `--`始まりのtokenを検知したら即座に走査を打ち切り外側の
#        dispatchへ委ねる形に修正した(T-CL-11b)。既存の「1つの--idに
#        複数ID列挙」形式に加え、独立した複数--idフラグ形式(--id A
#        --id B)が壊れていないことをT-CL-05bで回帰確認する。
#
# 検証方式 (design §6):
#   方式(a): tmuxから分離した内部関数(_inbox_lock_allowlist_check)を
#            __INBOX_LOCK_TESTING__=1 でsourceし直接呼び出す単体test。
#   方式(b): 隔離tmux server(tmux -L <専用label>)上に@agent_idを設定した
#            専用paneを用意し、コード変更なしのproduction inbox_lock.shを
#            そのまま実行するintegration test。paneコマンドはsleepとし、
#            時間経過で自然終了させる(tmux kill-server/kill-sessionは
#            CLAUDE.md D006により無条件禁止のため、明示終了は一切行わない)。
#
# 対象inboxは全テストを通じて隔離tmp fixture root(mktemp -d配下)のみ。
# 実 queue/inbox/*.yaml は一切対象にしない(cmd_696と同じ規律)。
#
# チェックリスト対応 (design §6 Phase D (a)〜(g)):
#   (a) T-CL-20   snapshot後の並行appendを保持し未処理read:falseのまま
#   (b) T-CL-21a  writer/watcher/mark-read三者同時実行でYAML parse成功・全ID保存
#   (b) T-CL-21b  inbox_lock.sh同士の並行実行でlost updateが起きない
#   (c) T-CL-07   複数ID all-or-nothing
#   (d) T-CL-06   既読ID再指定冪等
#   (e) T-CL-09/10/22 不正agent/path traversal拒否
#   (e) T-CL-24/25    書込直前realpath二重確認(H-1・静的symlink/TOCTOU)
#   (f) T-CL-12/13/14  cross-agent操作(認可層撤去後は成功・監査ログのみ記録)
#   (g) T-CL-17   lock timeout/失敗時に原本不変
#
# ★T-CL-15/16 は認可層撤去後も、TMUX_PANEが空/不正/未知paneであっても
#   処理そのものは成功し(fail-closedしない)、監査ログのcaller_refのみ
#   "unknown"になることを確認する回帰テスト(旧: fail-closed exit 5の
#   固定化テストだったが、認可撤去に伴い期待値を反転させた)。

# --- セットアップ ---

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export VENV_PYTHON="$PROJECT_ROOT/.venv/bin/python3"

    [ -f "$PROJECT_ROOT/scripts/inbox_lock.sh" ] || return 1
    [ -f "$PROJECT_ROOT/scripts/inbox_write.sh" ] || return 1
    [ -f "$PROJECT_ROOT/scripts/inbox_watcher.sh" ] || return 1
    "$VENV_PYTHON" -c "import yaml" 2>/dev/null || return 1
    command -v tmux >/dev/null 2>&1 || return 1

    # 隔離tmux server (方式(b))。実session・実paneとは無関係な専用label。
    # 各paneは sleep 300 を実行するのみ — 5分後に自然終了し、本ファイルの
    # test実行時間(lock timeoutテスト等を含めても数分程度)を確実に上回る。
    export IL_TMUX_LABEL="ilbats_$$_${RANDOM}"
    tmux -L "$IL_TMUX_LABEL" new-session -d -s il_ashigaru3 'sleep 300'
    tmux -L "$IL_TMUX_LABEL" new-session -d -s il_karo 'sleep 300'
    tmux -L "$IL_TMUX_LABEL" new-session -d -s il_gunshi 'sleep 300'
    sleep 0.3

    export IL_PANE_ASHIGARU3 IL_PANE_KARO IL_PANE_GUNSHI IL_SOCKPATH
    IL_PANE_ASHIGARU3="$(tmux -L "$IL_TMUX_LABEL" list-panes -t il_ashigaru3 -F '#{pane_id}')"
    IL_PANE_KARO="$(tmux -L "$IL_TMUX_LABEL" list-panes -t il_karo -F '#{pane_id}')"
    IL_PANE_GUNSHI="$(tmux -L "$IL_TMUX_LABEL" list-panes -t il_gunshi -F '#{pane_id}')"
    IL_SOCKPATH="$(tmux -L "$IL_TMUX_LABEL" display-message -p '#{socket_path}')"

    tmux -L "$IL_TMUX_LABEL" set-option -p -t "$IL_PANE_ASHIGARU3" @agent_id "ashigaru3"
    tmux -L "$IL_TMUX_LABEL" set-option -p -t "$IL_PANE_KARO" @agent_id "karo"
    tmux -L "$IL_TMUX_LABEL" set-option -p -t "$IL_PANE_GUNSHI" @agent_id "gunshi"

    [ -n "$IL_PANE_ASHIGARU3" ] || return 1
    [ -n "$IL_PANE_KARO" ] || return 1
    [ -n "$IL_PANE_GUNSHI" ] || return 1
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/inbox_lock_test.XXXXXX")"
    export TEST_SCRIPT_DIR="$TEST_TMPDIR/scripts"
    export TEST_INBOX_DIR="$TEST_TMPDIR/queue/inbox"
    mkdir -p "$TEST_SCRIPT_DIR" "$TEST_INBOX_DIR"

    cp "$PROJECT_ROOT/scripts/inbox_lock.sh" "$TEST_SCRIPT_DIR/inbox_lock.sh"
    chmod +x "$TEST_SCRIPT_DIR/inbox_lock.sh"
    cp "$PROJECT_ROOT/scripts/inbox_write.sh" "$TEST_SCRIPT_DIR/inbox_write.sh"
    chmod +x "$TEST_SCRIPT_DIR/inbox_write.sh"
    ln -sf "$PROJECT_ROOT/.venv" "$TEST_TMPDIR/.venv"

    export TEST_SCRIPT="$TEST_SCRIPT_DIR/inbox_lock.sh"
    export TEST_WRITE_SCRIPT="$TEST_SCRIPT_DIR/inbox_write.sh"

    # 既定のcaller: 隔離ashigaru3 pane(自inbox操作の既定値)。
    export TMUX="$IL_SOCKPATH,$$,0"
    export TMUX_PANE="$IL_PANE_ASHIGARU3"
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ] && rm -rf -- "${TEST_TMPDIR:?}"
}

# --- ヘルパー ---

make_inbox() {
    # make_inbox <path> <id> <read:true|false> [<id> <read>]...
    local path="$1"; shift
    {
        echo "messages:"
        while [ $# -ge 2 ]; do
            cat <<MSGEOF
- id: $1
  from: karo
  read: $2
  timestamp: '2026-08-19T00:00:00'
  type: task_assigned
  content: てすとメッセージ $1
MSGEOF
            shift 2
        done
    } > "$path"
}

read_flag() {
    # read_flag <path> <id> — "true"/"false"/"MISSING" を出力
    "$VENV_PYTHON" - "$1" "$2" <<'PY'
import sys, yaml
path, mid = sys.argv[1], sys.argv[2]
with open(path, encoding='utf-8') as f:
    data = yaml.safe_load(f) or {}
for m in (data.get('messages') or []):
    if m.get('id') == mid:
        print('true' if m.get('read') else 'false')
        raise SystemExit
print('MISSING')
PY
}

count_messages() {
    "$VENV_PYTHON" - "$1" <<'PY'
import sys, yaml
with open(sys.argv[1], encoding='utf-8') as f:
    data = yaml.safe_load(f) or {}
print(len(data.get('messages') or []))
PY
}

assert_yaml_valid() {
    "$VENV_PYTHON" - "$1" <<'PY'
import sys, yaml
with open(sys.argv[1], encoding='utf-8') as f:
    yaml.safe_load(f)
PY
}

# =============================================================================
# 使い方エラー (exit 1)
# =============================================================================

@test "T-CL-01: 引数無し → exit 1" {
    run bash "$TEST_SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "使い方" ]]
}

@test "T-CL-02: mark-read のみ(target未指定) → exit 1" {
    run bash "$TEST_SCRIPT" mark-read
    [ "$status" -eq 1 ]
}

@test "T-CL-03: --id未指定 → exit 1" {
    make_inbox "$TEST_INBOX_DIR/ashigaru3.yaml" msg_a false
    run bash "$TEST_SCRIPT" mark-read ashigaru3
    [ "$status" -eq 1 ]
}

@test "T-CL-04: --id 0件指定 → exit 1" {
    make_inbox "$TEST_INBOX_DIR/ashigaru3.yaml" msg_a false
    run bash "$TEST_SCRIPT" mark-read ashigaru3 --id
    [ "$status" -eq 1 ]
}

@test "T-CL-11 (認可層撤去の回帰): 撤去済み--repairフラグは未知の引数として exit 1" {
    make_inbox "$TEST_INBOX_DIR/ashigaru3.yaml" msg_a false
    run bash "$TEST_SCRIPT" mark-read ashigaru3 --repair --id msg_a
    [ "$status" -eq 1 ]
    [[ "$output" =~ "使い方" ]]
}

@test "T-CL-11b (H-3): --id値の走査中に現れた--repairもoption様tokenとして即exit 1・原本不変" {
    # T-CL-11は--repairが最初のtoken(--idの前)の場合。本testは--idの
    # 値走査ループの"内側"に--repairが現れるケース(旧実装のバグ箇所)。
    make_inbox "$TEST_INBOX_DIR/ashigaru3.yaml" msg_a false
    cp "$TEST_INBOX_DIR/ashigaru3.yaml" "$TEST_TMPDIR/before.yaml"

    run bash "$TEST_SCRIPT" mark-read ashigaru3 --id msg_a --repair
    [ "$status" -eq 1 ]
    [[ "$output" =~ "使い方" ]]

    diff "$TEST_TMPDIR/before.yaml" "$TEST_INBOX_DIR/ashigaru3.yaml"
}

# =============================================================================
# 基本のmark-read動作
# =============================================================================

@test "T-CL-05: 自inbox・単一id既読化 → exit 0、対象のみ変化" {
    make_inbox "$TEST_INBOX_DIR/ashigaru3.yaml" msg_a false msg_b false
    run bash "$TEST_SCRIPT" mark-read ashigaru3 --id msg_a
    [ "$status" -eq 0 ]
    [[ "$output" =~ "1件を既読化しました" ]]
    [ "$(read_flag "$TEST_INBOX_DIR/ashigaru3.yaml" msg_a)" = "true" ]
    [ "$(read_flag "$TEST_INBOX_DIR/ashigaru3.yaml" msg_b)" = "false" ]
    [ "$(count_messages "$TEST_INBOX_DIR/ashigaru3.yaml")" -eq 2 ]
}

@test "T-CL-05b (H-3・形式保持): 独立した複数--idフラグ(--id A --id B)も1回のmark-readで両方既読化される" {
    # --idへの複数ID列挙(T-CL-20等で既出)とは別形式。H-3のfix箇所
    # (--id値走査ループ)が、この「複数--idフラグ」形式を壊していない
    # ことを回帰確認する。
    make_inbox "$TEST_INBOX_DIR/ashigaru3.yaml" msg_a false msg_b false msg_c false
    run bash "$TEST_SCRIPT" mark-read ashigaru3 --id msg_a --id msg_b
    [ "$status" -eq 0 ]
    [[ "$output" =~ "2件を既読化しました" ]]
    [ "$(read_flag "$TEST_INBOX_DIR/ashigaru3.yaml" msg_a)" = "true" ]
    [ "$(read_flag "$TEST_INBOX_DIR/ashigaru3.yaml" msg_b)" = "true" ]
    [ "$(read_flag "$TEST_INBOX_DIR/ashigaru3.yaml" msg_c)" = "false" ]
}

@test "T-CL-06 (A-4): 既読済みidの再指定 → exit 0・0件・冪等" {
    make_inbox "$TEST_INBOX_DIR/ashigaru3.yaml" msg_a true msg_b false
    run bash "$TEST_SCRIPT" mark-read ashigaru3 --id msg_a
    [ "$status" -eq 0 ]
    [[ "$output" =~ "0件を既読化しました" ]]
    [ "$(read_flag "$TEST_INBOX_DIR/ashigaru3.yaml" msg_a)" = "true" ]
    [ "$(read_flag "$TEST_INBOX_DIR/ashigaru3.yaml" msg_b)" = "false" ]
}

@test "T-CL-07 (A-5): 存在しないidが1件でも混在 → exit 3・all-or-nothing" {
    make_inbox "$TEST_INBOX_DIR/ashigaru3.yaml" msg_a false msg_b false
    run bash "$TEST_SCRIPT" mark-read ashigaru3 --id msg_a msg_nonexistent
    [ "$status" -eq 3 ]
    # 存在するmsg_aも既読化されていないこと(部分適用しない)
    [ "$(read_flag "$TEST_INBOX_DIR/ashigaru3.yaml" msg_a)" = "false" ]
    [ "$(read_flag "$TEST_INBOX_DIR/ashigaru3.yaml" msg_b)" = "false" ]
}

@test "T-CL-08: 対象inboxファイルが存在しない(自inbox) → exit 2" {
    # ashigaru3.yaml を意図的に作らない
    run bash "$TEST_SCRIPT" mark-read ashigaru3 --id msg_x
    [ "$status" -eq 2 ]
}

# =============================================================================
# allowlist / path (e)
# =============================================================================

@test "T-CL-09 (e): allowlist不一致のagent_id → exit 5" {
    run bash "$TEST_SCRIPT" mark-read ashigaru8 --id msg_x
    [ "$status" -eq 5 ]
}

@test "T-CL-10 (e): path traversal風のagent_id → exit 5" {
    run bash "$TEST_SCRIPT" mark-read "../../etc/passwd" --id msg_x
    [ "$status" -eq 5 ]
}

@test "T-CL-22 (e・方式a): _inbox_lock_allowlist_check 単体test" {
    export __INBOX_LOCK_TESTING__=1
    source "$TEST_SCRIPT"
    run _inbox_lock_allowlist_check gunshi
    [ "$status" -eq 0 ]
    run _inbox_lock_allowlist_check ashigaru7
    [ "$status" -eq 0 ]
    run _inbox_lock_allowlist_check ashigaru8
    [ "$status" -eq 1 ]
    run _inbox_lock_allowlist_check "../etc"
    [ "$status" -eq 1 ]
    run _inbox_lock_allowlist_check ""
    [ "$status" -eq 1 ]
}

@test "T-CL-24 (H-1): 呼出時点で既に外部を指すsymlinkであるinboxは拒否され、symlink本体・リンク先とも不変" {
    # _inbox_lock_path_guard(pre-lock・第一防御)が正規に捕捉するケース。
    # symlinkが最初から存在するため、ロック取得後のPython書込直前
    # realpath二重確認(H-1・T-CL-25)に到達する前に拒否される。
    mkdir -p "$TEST_TMPDIR/external"
    make_inbox "$TEST_TMPDIR/external/evil.yaml" msg_a false
    cp "$TEST_TMPDIR/external/evil.yaml" "$TEST_TMPDIR/evil_before.yaml"

    ln -s "$TEST_TMPDIR/external/evil.yaml" "$TEST_INBOX_DIR/ashigaru3.yaml"

    run bash "$TEST_SCRIPT" mark-read ashigaru3 --id msg_a
    [ "$status" -eq 5 ]

    # symlink本体(queue/inbox側)がos.replaceで実ファイルへ置き換わって
    # いないこと(=原本のsymlinkとしての形が保たれていること)
    [ -L "$TEST_INBOX_DIR/ashigaru3.yaml" ]
    [ "$(readlink "$TEST_INBOX_DIR/ashigaru3.yaml")" = "$TEST_TMPDIR/external/evil.yaml" ]

    # リンク先の内容が一切変更されていないこと
    diff "$TEST_TMPDIR/evil_before.yaml" "$TEST_TMPDIR/external/evil.yaml"

    ! ls "$TEST_INBOX_DIR"/*.tmp >/dev/null 2>&1
}

@test "T-CL-25 (H-1・TOCTOU): pre-guard通過後・ロック取得後のsymlink差替えも書込直前realpath二重確認が拒否し、原本・リンク先とも不変" {
    # T-CL-24とは異なり、_inbox_lock_path_guard(pre-lock)の時点では
    # 通常ファイルとして存在させ、pre-guardを正規に通過させる。ロック
    # 取得後・Python書込直前の間隙(TOCTOU)でsymlinkへ差し替えても、
    # H-1で追加した書込直前realpath二重確認が独立して拒否することを
    # 検証する。
    make_inbox "$TEST_INBOX_DIR/ashigaru3.yaml" msg_a false
    cp "$TEST_INBOX_DIR/ashigaru3.yaml" "$TEST_TMPDIR/before_inbox.yaml"

    mkdir -p "$TEST_TMPDIR/external"
    make_inbox "$TEST_TMPDIR/external/evil.yaml" msg_a false
    cp "$TEST_TMPDIR/external/evil.yaml" "$TEST_TMPDIR/before_evil.yaml"

    # ロックディレクトリを事前取得し、production scriptをロック取得待ち
    # のリトライループへ足止めする。この時点でpre-guardは既に通過済み
    # (対象は通常ファイル)だが、Python書込にはまだ到達していない。
    mkdir -p "$TEST_INBOX_DIR/ashigaru3.yaml.lock.d"

    bash "$TEST_SCRIPT" mark-read ashigaru3 --id msg_a > "$TEST_TMPDIR/run.log" 2>&1 &
    pid=$!

    sleep 0.3

    # pre-guard通過後・ロック取得前の間隙を模し、通常ファイルを外部
    # symlinkへ差し替える。
    rm -f "$TEST_INBOX_DIR/ashigaru3.yaml"
    ln -s "$TEST_TMPDIR/external/evil.yaml" "$TEST_INBOX_DIR/ashigaru3.yaml"

    # 足止めしていたロックを解放し、スクリプトを進行させる。
    rmdir "$TEST_INBOX_DIR/ashigaru3.yaml.lock.d"

    status=0
    wait "$pid" || status=$?

    [ "$status" -eq 5 ]
    [[ "$(cat "$TEST_TMPDIR/run.log")" =~ "書込直前のrealpath検証に失敗しました" ]]

    [ -L "$TEST_INBOX_DIR/ashigaru3.yaml" ]
    [ "$(readlink "$TEST_INBOX_DIR/ashigaru3.yaml")" = "$TEST_TMPDIR/external/evil.yaml" ]
    diff "$TEST_TMPDIR/before_evil.yaml" "$TEST_TMPDIR/external/evil.yaml"

    ! ls "$TEST_INBOX_DIR"/*.tmp >/dev/null 2>&1
    [ ! -d "$TEST_INBOX_DIR/ashigaru3.yaml.lock.d" ]
}

# =============================================================================
# cross-agent操作 (f・認可層撤去後は成功し、監査ログのみ記録される)
# =============================================================================

@test "T-CL-12 (f・認可層撤去): cross-agent対象への操作は--repair無しで成功する" {
    make_inbox "$TEST_INBOX_DIR/gunshi.yaml" msg_g1 false
    run bash "$TEST_SCRIPT" mark-read gunshi --id msg_g1
    [ "$status" -eq 0 ]
    [[ "$output" =~ "1件を既読化しました" ]]
    [ "$(read_flag "$TEST_INBOX_DIR/gunshi.yaml" msg_g1)" = "true" ]
}

@test "T-CL-13 (f・認可層撤去): 旧・補修専用だった逆方向(gunshi→karo)のcross-agent操作も成功する" {
    make_inbox "$TEST_INBOX_DIR/karo.yaml" msg_k1 false
    # callerをgunshi paneにし、旧設計ならkaro専用だったtarget=karoを
    # gunshi自身が操作する。認可層撤去後はcaller種別を問わずtargetの
    # allowlist一致のみで成功する(T-CL-12とはcaller/target逆方向)。
    export TMUX_PANE="$IL_PANE_GUNSHI"
    run bash "$TEST_SCRIPT" mark-read karo --id msg_k1
    [ "$status" -eq 0 ]
    [ "$(read_flag "$TEST_INBOX_DIR/karo.yaml" msg_k1)" = "true" ]
}

@test "T-CL-14 (f): cross-agent操作成功時、AUDIT行にtarget/caller_refが記録される" {
    make_inbox "$TEST_INBOX_DIR/gunshi.yaml" msg_g1 false msg_g2 false

    export TMUX_PANE="$IL_PANE_KARO"
    run bash "$TEST_SCRIPT" mark-read gunshi --id msg_g1
    [ "$status" -eq 0 ]
    [[ "$output" =~ "1件を既読化しました" ]]
    [[ "$output" =~ "AUDIT: target=gunshi ids=msg_g1 caller_ref=karo" ]]
    [ "$(read_flag "$TEST_INBOX_DIR/gunshi.yaml" msg_g1)" = "true" ]
    [ "$(read_flag "$TEST_INBOX_DIR/gunshi.yaml" msg_g2)" = "false" ]
}

@test "T-CL-14b: 自inbox操作(caller==target)でもAUDIT行は常に出力される" {
    make_inbox "$TEST_INBOX_DIR/ashigaru3.yaml" msg_a false
    run bash "$TEST_SCRIPT" mark-read ashigaru3 --id msg_a
    [ "$status" -eq 0 ]
    [[ "$output" =~ "AUDIT: target=ashigaru3 ids=msg_a caller_ref=ashigaru3" ]]
}

# =============================================================================
# ★回帰test: 認可層撤去後、TMUX_PANEの異常値はfail-closedせず
# 監査参考値(caller_ref)がunknownになるだけであることの固定化 (方式b)
# =============================================================================

@test "T-CL-15 (回帰・方式b): TMUX_PANE空でも処理は成功しcaller_ref=unknown" {
    make_inbox "$TEST_INBOX_DIR/gunshi.yaml" msg_g1 false
    export TMUX_PANE=""
    # このTMUXは隔離serverを指しており、karoやgunshiのpaneも実在するが、
    # TMUX_PANEが空のため tmux display-message -t "" は「暗黙のcurrent
    # pane」へ解決されうる(実機検証で判明した危険な挙動)。認可判断には
    # そもそもTMUX_PANEを使わないため、inbox_lock.sh自身のformatガード
    # により、tmuxを呼ぶ前にcaller_ref=unknownと確定し処理は成功する
    # (fail-closedしない)。
    run bash "$TEST_SCRIPT" mark-read gunshi --id msg_g1
    [ "$status" -eq 0 ]
    [[ "$output" =~ "caller_ref=unknown" ]]
    [ "$(read_flag "$TEST_INBOX_DIR/gunshi.yaml" msg_g1)" = "true" ]
}

@test "T-CL-15b (回帰・方式b): TMUX_PANE未設定(unset)でも処理は成功しcaller_ref=unknown" {
    make_inbox "$TEST_INBOX_DIR/gunshi.yaml" msg_g1 false
    unset TMUX_PANE
    run bash "$TEST_SCRIPT" mark-read gunshi --id msg_g1
    [ "$status" -eq 0 ]
    [[ "$output" =~ "caller_ref=unknown" ]]
    [ "$(read_flag "$TEST_INBOX_DIR/gunshi.yaml" msg_g1)" = "true" ]
}

@test "T-CL-16 (方式b): 整形式だが存在しないpane-id → 処理は成功しcaller_ref=unknown" {
    make_inbox "$TEST_INBOX_DIR/ashigaru3.yaml" msg_a false
    export TMUX_PANE="%99999"
    run bash "$TEST_SCRIPT" mark-read ashigaru3 --id msg_a
    [ "$status" -eq 0 ]
    [[ "$output" =~ "caller_ref=unknown" ]]
    [ "$(read_flag "$TEST_INBOX_DIR/ashigaru3.yaml" msg_a)" = "true" ]
}

@test "T-CL-16b (方式b・正常系確認): 隔離tmuxの実paneからcaller_refが正しく解決される(参考値のみ)" {
    make_inbox "$TEST_INBOX_DIR/karo.yaml" msg_k1 false
    export TMUX_PANE="$IL_PANE_KARO"
    run bash "$TEST_SCRIPT" mark-read karo --id msg_k1
    [ "$status" -eq 0 ]
    [[ "$output" =~ "caller_ref=karo" ]]
    [ "$(read_flag "$TEST_INBOX_DIR/karo.yaml" msg_k1)" = "true" ]
}

# =============================================================================
# ロック (g) と解放確認
# =============================================================================

@test "T-CL-17 (g): ロック取得失敗 → exit 4・原本不変" {
    make_inbox "$TEST_INBOX_DIR/ashigaru3.yaml" msg_a false
    mkdir -p "$TEST_INBOX_DIR/ashigaru3.yaml.lock.d"
    cp "$TEST_INBOX_DIR/ashigaru3.yaml" "$TEST_TMPDIR/before.yaml"

    run bash "$TEST_SCRIPT" mark-read ashigaru3 --id msg_a
    [ "$status" -eq 4 ]

    diff "$TEST_TMPDIR/before.yaml" "$TEST_INBOX_DIR/ashigaru3.yaml"
    rmdir "$TEST_INBOX_DIR/ashigaru3.yaml.lock.d"
}

@test "T-CL-18: 成功後にlock directoryが解放されている" {
    make_inbox "$TEST_INBOX_DIR/ashigaru3.yaml" msg_a false
    run bash "$TEST_SCRIPT" mark-read ashigaru3 --id msg_a
    [ "$status" -eq 0 ]
    [ ! -d "$TEST_INBOX_DIR/ashigaru3.yaml.lock.d" ]
}

@test "T-CL-19: all-or-nothing失敗(exit 3)後もlock directoryが解放されている" {
    make_inbox "$TEST_INBOX_DIR/ashigaru3.yaml" msg_a false
    run bash "$TEST_SCRIPT" mark-read ashigaru3 --id msg_nonexistent
    [ "$status" -eq 3 ]
    [ ! -d "$TEST_INBOX_DIR/ashigaru3.yaml.lock.d" ]
}

# =============================================================================
# 並行性 (a)(b)
# =============================================================================

@test "T-CL-20 (a・TOCTOU非再発): snapshot後の並行appendはread:falseのまま残る" {
    make_inbox "$TEST_INBOX_DIR/ashigaru3.yaml" msg_a false msg_b false

    # 呼び出し元は事前Readでmsg_a/msg_bのみをsnapshotした、という想定。
    # mark-read実行の直前に第三者(inbox_write.sh)が新着を追加する。
    bash "$TEST_WRITE_SCRIPT" ashigaru3 "並行新着" concurrent_new karo >/dev/null

    run bash "$TEST_SCRIPT" mark-read ashigaru3 --id msg_a msg_b
    [ "$status" -eq 0 ]

    [ "$(read_flag "$TEST_INBOX_DIR/ashigaru3.yaml" msg_a)" = "true" ]
    [ "$(read_flag "$TEST_INBOX_DIR/ashigaru3.yaml" msg_b)" = "true" ]
    [ "$(count_messages "$TEST_INBOX_DIR/ashigaru3.yaml")" -eq 3 ]

    "$VENV_PYTHON" - "$TEST_INBOX_DIR/ashigaru3.yaml" <<'PY'
import sys, yaml
with open(sys.argv[1], encoding='utf-8') as f:
    data = yaml.safe_load(f)
new = [m for m in data['messages'] if m['id'] not in ('msg_a', 'msg_b')]
assert len(new) == 1, new
assert new[0]['read'] is False, new[0]
assert new[0]['content'] == '並行新着', new[0]
PY
}


@test "T-CL-21b (b): inbox_lock.sh同士の並行実行(排他id)でlost updateが起きない" {
    make_inbox "$TEST_INBOX_DIR/ashigaru3.yaml" msg_a false msg_b false msg_c false msg_d false

    bash "$TEST_SCRIPT" mark-read ashigaru3 --id msg_a msg_b > "$TEST_TMPDIR/l1.log" 2>&1 &
    pid1=$!
    bash "$TEST_SCRIPT" mark-read ashigaru3 --id msg_c msg_d > "$TEST_TMPDIR/l2.log" 2>&1 &
    pid2=$!

    wait "$pid1"; rc1=$?
    wait "$pid2"; rc2=$?
    [ "$rc1" -eq 0 ]
    [ "$rc2" -eq 0 ]

    assert_yaml_valid "$TEST_INBOX_DIR/ashigaru3.yaml"
    [ "$(count_messages "$TEST_INBOX_DIR/ashigaru3.yaml")" -eq 4 ]
    for id in msg_a msg_b msg_c msg_d; do
        [ "$(read_flag "$TEST_INBOX_DIR/ashigaru3.yaml" "$id")" = "true" ]
    done
}

# =============================================================================
# archive サブコマンド (cmd_734 A-3)
# =============================================================================

archive_path() {
    echo "$TEST_INBOX_DIR/archive/$1.yaml"
}

@test "T-CL-26: 不明なsubcommand → exit 1" {
    make_inbox "$TEST_INBOX_DIR/ashigaru3.yaml" msg_a true
    run bash "$TEST_SCRIPT" bogus-action ashigaru3 --id msg_a
    [ "$status" -eq 1 ]
    [[ "$output" =~ "使い方" ]]
}

@test "T-CL-27: 基本動作・read:true単一idをarchiveへ退避" {
    make_inbox "$TEST_INBOX_DIR/ashigaru3.yaml" msg_a true msg_b false
    run bash "$TEST_SCRIPT" archive ashigaru3 --id msg_a
    [ "$status" -eq 0 ]
    [[ "$output" =~ "1件をarchiveへ退避し、元inboxから1件削除しました" ]]

    # 元inboxからmsg_aが消え、msg_bのみ残る
    [ "$(count_messages "$TEST_INBOX_DIR/ashigaru3.yaml")" -eq 1 ]
    [ "$(read_flag "$TEST_INBOX_DIR/ashigaru3.yaml" msg_b)" = "false" ]
    [ "$(read_flag "$TEST_INBOX_DIR/ashigaru3.yaml" msg_a)" = "MISSING" ]

    # archive側にmsg_aが1件、read:trueのまま保持されている
    [ -f "$(archive_path ashigaru3)" ]
    [ "$(count_messages "$(archive_path ashigaru3)")" -eq 1 ]
    [ "$(read_flag "$(archive_path ashigaru3)" msg_a)" = "true" ]
}

@test "T-CL-28 (A-2安全策): read:falseが1件でも混在 → exit 6・原本/archiveとも不変" {
    make_inbox "$TEST_INBOX_DIR/ashigaru3.yaml" msg_a true msg_b false
    run bash "$TEST_SCRIPT" archive ashigaru3 --id msg_a msg_b
    [ "$status" -eq 6 ]
    [[ "$output" =~ "read:falseのためarchive不可" ]]

    # 全体が拒否され、どちらも元inboxに残ったまま
    [ "$(count_messages "$TEST_INBOX_DIR/ashigaru3.yaml")" -eq 2 ]
    [ "$(read_flag "$TEST_INBOX_DIR/ashigaru3.yaml" msg_a)" = "true" ]
    [ "$(read_flag "$TEST_INBOX_DIR/ashigaru3.yaml" msg_b)" = "false" ]
    [ ! -f "$(archive_path ashigaru3)" ]
}

@test "T-CL-29: 複数read:trueidの一括archive" {
    make_inbox "$TEST_INBOX_DIR/ashigaru3.yaml" msg_a true msg_b true msg_c false
    run bash "$TEST_SCRIPT" archive ashigaru3 --id msg_a msg_b
    [ "$status" -eq 0 ]
    [[ "$output" =~ "2件をarchiveへ退避し、元inboxから2件削除しました" ]]

    [ "$(count_messages "$TEST_INBOX_DIR/ashigaru3.yaml")" -eq 1 ]
    [ "$(read_flag "$TEST_INBOX_DIR/ashigaru3.yaml" msg_c)" = "false" ]
    [ "$(count_messages "$(archive_path ashigaru3)")" -eq 2 ]
    [ "$(read_flag "$(archive_path ashigaru3)" msg_a)" = "true" ]
    [ "$(read_flag "$(archive_path ashigaru3)" msg_b)" = "true" ]
}

@test "T-CL-30: 存在しないidが混在 → exit 3・all-or-nothing・原本/archiveとも不変" {
    make_inbox "$TEST_INBOX_DIR/ashigaru3.yaml" msg_a true
    run bash "$TEST_SCRIPT" archive ashigaru3 --id msg_a msg_nonexistent
    [ "$status" -eq 3 ]
    [ "$(count_messages "$TEST_INBOX_DIR/ashigaru3.yaml")" -eq 1 ]
    [ "$(read_flag "$TEST_INBOX_DIR/ashigaru3.yaml" msg_a)" = "true" ]
    [ ! -f "$(archive_path ashigaru3)" ]
}

@test "T-CL-31: archiveディレクトリが存在しなくても自動作成される" {
    [ ! -d "$TEST_INBOX_DIR/archive" ]
    make_inbox "$TEST_INBOX_DIR/ashigaru3.yaml" msg_a true
    run bash "$TEST_SCRIPT" archive ashigaru3 --id msg_a
    [ "$status" -eq 0 ]
    [ -d "$TEST_INBOX_DIR/archive" ]
    [ -f "$(archive_path ashigaru3)" ]
}

@test "T-CL-32 (クラッシュ再実行想定): archive側に既に同idが存在する場合は重複追記せず、元inboxからは削除する" {
    make_inbox "$TEST_INBOX_DIR/ashigaru3.yaml" msg_a true
    # クラッシュ後の状態を模擬: archive側には既にmsg_aがある(前回実行の
    # 「archive書込は成功したがinbox書込前に落ちた」状態を手作業で再現)。
    mkdir -p "$TEST_INBOX_DIR/archive"
    make_inbox "$(archive_path ashigaru3)" msg_a true

    run bash "$TEST_SCRIPT" archive ashigaru3 --id msg_a
    [ "$status" -eq 0 ]
    [[ "$output" =~ "0件をarchiveへ退避し、元inboxから1件削除しました" ]]
    [[ "$output" =~ "archive側重複スキップ1件" ]]

    [ "$(count_messages "$TEST_INBOX_DIR/ashigaru3.yaml")" -eq 0 ]
    [ "$(count_messages "$(archive_path ashigaru3)")" -eq 1 ]
}

@test "T-CL-33: archive成功後にlock directoryが解放されている" {
    make_inbox "$TEST_INBOX_DIR/ashigaru3.yaml" msg_a true
    run bash "$TEST_SCRIPT" archive ashigaru3 --id msg_a
    [ "$status" -eq 0 ]
    [ ! -d "$TEST_INBOX_DIR/ashigaru3.yaml.lock.d" ]
}

@test "T-CL-34 (e): allowlist不一致のagent_idはarchiveでも exit 5" {
    run bash "$TEST_SCRIPT" archive ashigaru8 --id msg_x
    [ "$status" -eq 5 ]
    [ ! -f "$(archive_path ashigaru8)" ]
}

@test "T-CL-35 (H-1相当): 呼出時点で既にsymlinkであるinboxはarchiveでも拒否され不変" {
    mkdir -p "$TEST_TMPDIR/external"
    make_inbox "$TEST_TMPDIR/external/evil.yaml" msg_a true
    cp "$TEST_TMPDIR/external/evil.yaml" "$TEST_TMPDIR/evil_before.yaml"
    ln -s "$TEST_TMPDIR/external/evil.yaml" "$TEST_INBOX_DIR/ashigaru3.yaml"

    run bash "$TEST_SCRIPT" archive ashigaru3 --id msg_a
    [ "$status" -eq 5 ]

    [ -L "$TEST_INBOX_DIR/ashigaru3.yaml" ]
    diff "$TEST_TMPDIR/evil_before.yaml" "$TEST_TMPDIR/external/evil.yaml"
    [ ! -f "$(archive_path ashigaru3)" ]
}

@test "T-CL-36: archive成功時もAUDIT行はmark-readと同一フォーマットで記録される(target/ids/caller_ref)" {
    make_inbox "$TEST_INBOX_DIR/ashigaru3.yaml" msg_a true
    run bash "$TEST_SCRIPT" archive ashigaru3 --id msg_a
    [ "$status" -eq 0 ]
    [[ "$output" =~ "AUDIT: target=ashigaru3 ids=msg_a caller_ref=" ]]
}

@test "T-CL-38: archive後も元inboxの他フィールド(from/timestamp/type/content)が保持される" {
    make_inbox "$TEST_INBOX_DIR/ashigaru3.yaml" msg_a true
    run bash "$TEST_SCRIPT" archive ashigaru3 --id msg_a
    [ "$status" -eq 0 ]

    "$VENV_PYTHON" - "$(archive_path ashigaru3)" <<'PY'
import sys, yaml
with open(sys.argv[1], encoding='utf-8') as f:
    data = yaml.safe_load(f)
m = data['messages'][0]
assert m['id'] == 'msg_a', m
assert m['from'] == 'karo', m
assert m['type'] == 'task_assigned', m
assert m['content'] == 'てすとメッセージ msg_a', m
assert m['read'] is True, m
PY
}

@test "T-CL-39 (cmd_734 G734-A-TEST-01・並行実行): archiveとinbox_writeの同時実行でYAML破損なく新着read:falseはactiveに残る" {
    # 事前状態: archive対象のread:true 2件(msg_a, msg_b) + 既存read:false 1件(msg_c)
    make_inbox "$TEST_INBOX_DIR/ashigaru3.yaml" msg_a true msg_b true msg_c false

    # archive(msg_a, msg_b)とinbox_write(新着3件・read:false)を同時実行する。
    bash "$TEST_SCRIPT" archive ashigaru3 --id msg_a msg_b > "$TEST_TMPDIR/arc.log" 2>&1 &
    pid_arc=$!
    bash "$TEST_WRITE_SCRIPT" ashigaru3 "並行新着1" concurrent_archive karo > "$TEST_TMPDIR/wn1.log" 2>&1 &
    pid_n1=$!
    bash "$TEST_WRITE_SCRIPT" ashigaru3 "並行新着2" concurrent_archive karo > "$TEST_TMPDIR/wn2.log" 2>&1 &
    pid_n2=$!
    bash "$TEST_WRITE_SCRIPT" ashigaru3 "並行新着3" concurrent_archive karo > "$TEST_TMPDIR/wn3.log" 2>&1 &
    pid_n3=$!

    rc_arc=0
    wait "$pid_arc" || rc_arc=$?
    rc_n1=0
    wait "$pid_n1" || rc_n1=$?
    rc_n2=0
    wait "$pid_n2" || rc_n2=$?
    rc_n3=0
    wait "$pid_n3" || rc_n3=$?

    [ "$rc_arc" -eq 0 ]
    [ "$rc_n1" -eq 0 ]
    [ "$rc_n2" -eq 0 ]
    [ "$rc_n3" -eq 0 ]

    # 両ファイルともYAML parse可能であること
    assert_yaml_valid "$TEST_INBOX_DIR/ashigaru3.yaml"
    assert_yaml_valid "$(archive_path ashigaru3)"

    "$VENV_PYTHON" - "$TEST_INBOX_DIR/ashigaru3.yaml" "$(archive_path ashigaru3)" <<'PY'
import sys, yaml
inbox_path, archive_path = sys.argv[1], sys.argv[2]
with open(inbox_path, encoding='utf-8') as f:
    inbox_msgs = (yaml.safe_load(f) or {}).get('messages') or []
with open(archive_path, encoding='utf-8') as f:
    archive_msgs = (yaml.safe_load(f) or {}).get('messages') or []

inbox_ids = [m['id'] for m in inbox_msgs]
archive_ids = [m['id'] for m in archive_msgs]

# 重複0: inbox/archive間でIDが重複しない
assert set(inbox_ids).isdisjoint(archive_ids), (inbox_ids, archive_ids)

# archive対象(msg_a, msg_b)のみがarchiveへ移動している
assert sorted(archive_ids) == ['msg_a', 'msg_b'], archive_ids

# 全ID保存: 元3件(msg_a/b/c)+並行新着3件=6件がinbox+archive合計で失われていない
assert len(inbox_ids) + len(archive_ids) == 6, (inbox_ids, archive_ids)

# 新着3件(read:false)はarchiveへ巻き込まれずactive(inbox)に残っている
new_msgs = [m for m in inbox_msgs if m['id'] != 'msg_c']
assert len(new_msgs) == 3, new_msgs
contents = sorted(m['content'] for m in new_msgs)
assert contents == ['並行新着1', '並行新着2', '並行新着3'], contents
for m in new_msgs:
    assert m['read'] is False, m

# 既存read:false(msg_c)もarchiveへ巻き込まれずactiveに残っている
assert any(m['id'] == 'msg_c' and m['read'] is False for m in inbox_msgs), inbox_msgs
PY

    [ ! -d "$TEST_INBOX_DIR/ashigaru3.yaml.lock.d" ]
}
