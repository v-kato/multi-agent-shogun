#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# cmd_757② redo2 の隔離tmux検証 — pane index 再束縛と canonical pane_id
#   実行: bash tests/verify_cmd_757_pane_rebind_isolated.sh
#   ★bats テストではない(tmux server を立てるため)。`bats tests/*.bats` は
#     .bats だけを見るゆえ、本ファイルは回帰スイートの対象外である。
#     決定的な回帰試験は tests/unit/test_clear_send_gate.bats の
#     T-CG-070〜T-CG-072 が担う。本ファイルはその★前提となる tmux の
#     実挙動(index が再束縛されること)を実機で示す証跡である。
#   ★稼働中の agent pane には一切触れない。専用ソケット (-L) の tmux
#     server 上にだけ pane を作り、そこで実挙動を確かめる。
#   ★D006 により tmux kill-server / kill-session は使わない。
#     後始末は「自分で作った素のシェル pane へ exit を入力する」で行う。
#   ★本スクリプトは gate の判定関数しか呼ばない。`/clear` の打鍵は
#     隔離 pane に mesh 申告が無いため条件1 で必ず落ちる(それも確かめる)。
#   ★cmd_758初版(2026-09-09)では「対象paneへexitを入力し自然終了を
#     イベント駆動で待つ」核心部分を `scripts/isolated_tmux.sh` の
#     `itmux_wait_for_pane_exit` へ一本化しよう試みた(A-8)。しかし
#     軍師QC(G758-DEFAULT-AND-RAW-TARGET-BYPASS-01)により、この
#     source公開APIが検査を経ずに任意のsocket/pane_idを直接送信へ
#     渡せてしまう第二の送信口であると判明し、redo1でraw APIごと
#     廃止した。ゆえに本スクリプトは★局所実装へ戻す(A-8は完全移行
#     不可)。`scripts/isolated_tmux.sh` の `create`/`teardown` は
#     どのみち使わない——本試験は index 再束縛を確かめるため同一
#     window内に2つのpaneを意図的に作り、片方だけを先に終了させて
#     もう片方を残すという、`create`(pane1つのみ)/`teardown`(全paneを
#     一括で終わらせる)のどちらの型にも合わない検証固有の手順が要る
#     ためである。
# ═══════════════════════════════════════════════════════════════
set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMUX_BIN="$(command -v tmux)"
SOCK="cmd757_rebind_$$"

# ★cmd_758 redo1: 「exit入力+イベント駆動待ち」の核心パターンを
#   ローカルに保持する(scripts/isolated_tmux.sh はsourceしない)。
#   hookを先に仕込んでから exit キーを送ることで、「exitが先に処理
#   されhookが間に合わない」窓を作らない(順序が要である)。
wait_for_pane_exit() {
    local socket="$1" pane_id="$2"
    local chan="verify757_exit_$$_${RANDOM}"
    "$TMUX_BIN" -L "$socket" set-hook -t "$pane_id" pane-exited \
        "run-shell -b '${TMUX_BIN} -L ${socket} wait-for -S ${chan}'" 2>/dev/null
    "$TMUX_BIN" -L "$socket" send-keys -t "$pane_id" "exit" Enter 2>/dev/null
    "$TMUX_BIN" -L "$socket" wait-for "$chan" 2>/dev/null
}
PASS=0
FAIL=0

log()  { echo -e "$*"; }
check() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        PASS=$((PASS+1)); log "  ✅ ${name}"
    else
        FAIL=$((FAIL+1)); log "  ❌ ${name}\n      期待: ${want}\n      実際: ${got}"
    fi
}
check_ne() {
    local name="$1" not_want="$2" got="$3"
    if [ "$not_want" != "$got" ]; then
        PASS=$((PASS+1)); log "  ✅ ${name} (${got} ≠ ${not_want})"
    else
        FAIL=$((FAIL+1)); log "  ❌ ${name}\n      同一であってはならぬ: ${got}"
    fi
}

# ★隔離の担保: 専用ソケットにしか触らせない
itmux() { command tmux -L "$SOCK" "$@"; }

# ★F004是正(cmd_757②redo3・G757-CLEAR-F004-POLLING-REDO2-02): pane終了の
#   event-driven検知。固定sleep・busy pollingのいずれも使わない。
#   tmux の `pane-exited` hook(対象pane限定・-t)を先に仕込んでから
#   exitキーを送り、`tmux wait-for`のblocking waitで終了通知だけを待つ。
#   ★D006明記: killは一切使わない。exitキーで自然終了させ、hookからの
#   通知を待つだけである(kill-server/kill-sessionは隔離socketでも禁止)。
#   ★手順の順序が要である: hookを先に仕込んでから exit を送ることで、
#   「exitが先に処理されhookが間に合わない」窓を作らない。
# ★cmd_758 redo1(A-8は完全移行不可): `scripts/isolated_tmux.sh` は
#   raw source APIを提供しない設計になったため、本スクリプトは
#   ローカルの `wait_for_pane_exit`(上で定義済み)をそのまま使う。

log "═══ cmd_757② redo2 隔離tmux検証 (socket=${SOCK}) ═══"
log ""

# ── 0. 隔離の確認 ─────────────────────────────────────────────
log "▼ 0. 隔離の確認"
itmux new-session -d -s verify -n w0 bash 2>/dev/null
# ★F004是正: `new-session -d` はtmux client/server間の同期呼出しであり、
#   コマンドが戻った時点でsession/window/paneは既にserver側に存在する
#   (server未起動ならclientが起動を待ってから応答するため、以降の
#   list-sessions等は即座に正しい値を返す)。固定sleepは実際には何の
#   依存関係も持たぬ飾りだったため、待ち自体を無くす(置換ではなく除去)。
sessions="$(itmux list-sessions -F '#{session_name}' 2>/dev/null | tr '\n' ',')"
check "隔離serverに verify セッションのみ存在する" "verify," "$sessions"
live_seen="$(itmux list-sessions -F '#{session_name}' 2>/dev/null | grep -cE '^(multiagent|shogun)$' || true)"
check "隔離serverから稼働中セッションは見えない" "0" "$live_seen"
log ""

# ── 1. 2つの pane を作り、index と canonical pane_id を記録する ──
log "▼ 1. index 文字列と canonical pane_id を記録する"
itmux split-window -t verify:w0.0 -d bash 2>/dev/null
# ★F004是正: split-window -d も同期呼出しであり、戻った時点で新paneは
#   既にserver側に存在する。待ちが要らない理由は上のnew-sessionと同じ。
INDEX_TARGET="verify:w0.0"
A_ID="$(itmux display-message -t "$INDEX_TARGET" -p '#{pane_id}' 2>/dev/null)"
B_ID="$(itmux display-message -t verify:w0.1 -p '#{pane_id}' 2>/dev/null)"
log "  index=${INDEX_TARGET} → pane_id=${A_ID}"
log "  index=verify:w0.1 → pane_id=${B_ID}"
check_ne "2つの pane は別の pane_id を持つ" "$A_ID" "$B_ID"
log ""

# ── 2. pane の @agent_id (redo2 が束縛に使う tmux 側の事実) ──
log "▼ 2. pane option @agent_id が tmux 側の事実として読めること"
itmux set-option -p -t "$A_ID" @agent_id "verify_a" 2>/dev/null
itmux set-option -p -t "$B_ID" @agent_id "verify_b" 2>/dev/null
check "A pane の @agent_id" "verify_a" "$(itmux display-message -t "$A_ID" -p '#{@agent_id}' 2>/dev/null)"
check "B pane の @agent_id" "verify_b" "$(itmux display-message -t "$B_ID" -p '#{@agent_id}' 2>/dev/null)"
log ""

# ── 3. ★第一 pane を自然終了させ、index が再束縛されるかを見る ──
log "▼ 3. ★index 再束縛の実測 (第一 pane を exit で自然終了させる)"
log "  ★kill は使わぬ。自分で作った素のシェルへ exit を入力する。"
# ★F004是正: 最大100回のbusy pollingを、pane-exited hook + `tmux wait-for`
#   のblocking waitへ置換する。exitキー送信自体も wait_for_pane_exit
#   の中で行う(hookを先に仕込んでから送るため、取りこぼしの窓が無い)。
#   ★cmd_758 redo1(A-8完全移行不可): ローカル定義の核心関数を使う。
wait_for_pane_exit "$SOCK" "$A_ID"
gone=0
if ! itmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qx -- "$A_ID"; then
    gone=1
fi
check "第一 pane (${A_ID}) は消滅した" "1" "$gone"

NOW_ID="$(itmux display-message -t "$INDEX_TARGET" -p '#{pane_id}' 2>/dev/null)"
log "  ★同じ index 文字列 ${INDEX_TARGET} を今もう一度解決すると → ${NOW_ID}"
check_ne "★index 文字列は★別の pane へ再束縛された" "$A_ID" "$NOW_ID"
check "★再束縛先は第二 pane である" "$B_ID" "$NOW_ID"
NOW_AGENT="$(itmux display-message -t "$INDEX_TARGET" -p '#{@agent_id}' 2>/dev/null)"
check "★index 経由で読める @agent_id も入れ替わっている" "verify_b" "$NOW_AGENT"

# ★canonical pane_id は再利用されない。消滅した %N は★別 pane へ再解決されず、
#   ただ空を返す。★★ここは実測で分かった重要な性質である:
#   `tmux display-message -t <消滅した %N>` は★rc=0 を返し stdout も stderr も
#   ★空である(黙って 0 を返す道具。CLAUDE.md「Tooling Pitfalls」の grep 盲点と
#   同じ病)。ゆえに★rc で判定してはならぬ。`_gate_canonical_pane_id` が
#   ★出力の形(`%` + 数字)を検査しているのはこのためである。
dead_rc=0
dead_out="$(itmux display-message -t "$A_ID" -p '#{pane_id}' 2>/dev/null)" || dead_rc=$?
log "  ★消滅した ${A_ID} への display-message: rc=${dead_rc} stdout=[${dead_out}]"
check "★消滅した canonical pane_id は★別 pane を返さない (出力は空)" "" "$dead_out"
check_ne "★消滅した canonical pane_id は生きた pane の ID を返さない" "$B_ID" "${dead_out:-none}"
# ★打鍵系・画面取得系は rc で落ちる(こちらは黙らない)。
itmux capture-pane -t "$A_ID" -p >/dev/null 2>&1; cap_rc=$?
check_ne "★消滅した pane への capture-pane は失敗する" "0" "$cap_rc"
log ""

# ── 4. gate 側の挙動 (判定関数のみ・打鍵はしない) ───────────────
log "▼ 4. gate の宛先固定と agent_id 束縛 (★判定のみ・打鍵はせぬ)"
# lib は `timeout tmux ...` と呼ぶため、シェル関数では隔離できない。
# ★実行可能な shim を PATH の先頭へ置き、隔離ソケットへ固定する。
SHIM_DIR="$(mktemp -d /tmp/cmd757_shim.XXXXXX)"
# ★F004是正で追加: shim経由の全呼出しを記録する。後段(d)で「送っていない
#   ことの証明」に固定sleep+画面差分ではなく、この呼出しログを使う。
CALL_LOG="$SHIM_DIR/calls.log"
cat > "$SHIM_DIR/tmux" <<SHIM
#!/usr/bin/env bash
echo "\$@" >> "$CALL_LOG"
exec $(command -v tmux) -L "$SOCK" "\$@"
SHIM
chmod +x "$SHIM_DIR/tmux"
export PATH="$SHIM_DIR:$PATH"

source "$PROJECT_ROOT/lib/clear_send_gate.sh"

# (a) 生きている pane は canonical pane_id へ解決できる
got="$(_gate_canonical_pane_id "$INDEX_TARGET" 2>/dev/null || echo "RC1")"
check "生きた index は canonical pane_id へ解決される" "$B_ID" "$got"

# (b) ★消滅した pane_id は解決に失敗する = fail-closed で送らない
got="$(_gate_canonical_pane_id "$A_ID" 2>/dev/null || echo "RC1")"
check "★消滅した canonical pane_id は解決できず fail-closed" "RC1" "$got"

# (c) @agent_id 束縛 — 実体と一致するときだけ通る
gate_agent_id_bound_to_pane "$B_ID" "verify_b" >/dev/null 2>&1; rc=$?
check "実体と一致する agent_id は通る" "0" "$rc"
log "      reason: ${GATE_REASON}"
gate_agent_id_bound_to_pane "$B_ID" "verify_a" >/dev/null 2>&1; rc=$?
check "★不一致の agent_id は通らない" "1" "$rc"
log "      reason: ${GATE_REASON}"
gate_agent_id_bound_to_pane "$B_ID" "" >/dev/null 2>&1; rc=$?
check "★agent_id 未指定は通らない" "1" "$rc"
log "      reason: ${GATE_REASON}"

# (d) ★production entry を通しても打鍵は起きない
#     隔離 pane には mesh 申告が無いゆえ条件1 で必ず落ちる。
before="$(itmux capture-pane -t "$B_ID" -p 2>/dev/null | md5sum)"
gate_send_context_reset "$INDEX_TARGET" claude clear_command verify_b >/dev/null 2>&1; rc=$?
check "★production entry は隔離 pane へ送らない (rc=1)" "1" "$rc"
log "      reason: ${GATE_REASON}"
# ★F004是正: gate_send_context_reset は同期呼出しの関数であり、戻った時点で
#   その内部が発行しうる `tmux send-keys` は(呼ばれていれば)既に完了して
#   いる(バックグラウンドの子プロセスではない)。「万一送っていたら反映
#   されるまで待つ」ための固定sleepは不要である。代わりに shim の呼出し
#   ログを直接検査し、send-keys がそもそも一度も呼ばれていないことを
#   断定する(画面差分より精密・即時であり、待ちを要さない)。
send_keys_calls="$(/usr/bin/grep -c '^send-keys ' "$CALL_LOG" 2>/dev/null || true)"
[ -n "$send_keys_calls" ] || send_keys_calls=0
check "★production entry から send-keys は一度も呼ばれていない" "0" "$send_keys_calls"
after="$(itmux capture-pane -t "$B_ID" -p 2>/dev/null | md5sum)"
check "★隔離 pane の画面は1文字も変わっていない" "$before" "$after"
log ""

# ── 5. 後始末 (kill は使わぬ) ──────────────────────────────────
log "▼ 5. 後始末 (kill は使わぬ)"
rm -rf "$SHIM_DIR"
# ★F004是正: 固定sleep 2を pane-exited hook + `tmux wait-for` へ置換する。
#   pane B は本セッション唯一の残paneゆえ(A は step 3 で既に消滅済み)、
#   Bの終了でwindow→sessionも連鎖して閉じる(既定 exit-empty によりserver
#   ごと終了しうる)。exitキー送信もhelperの中で行う(hookを先に仕込んで
#   から送るため取りこぼしの窓が無い)。★server自体が終了した場合、以後の
#   `itmux` 呼出しは「no server running」で即座に失敗する(新規serverを
#   自動起動しない)ため、待ちが永久にハングすることは無い。
#   ★cmd_758 redo1(A-8完全移行不可): ローカル定義の核心関数を使う。
wait_for_pane_exit "$SOCK" "$B_ID"
if itmux has-session -t verify 2>/dev/null; then
    log "  ⚠️  隔離セッションが残っている。socket=${SOCK} を人が確認されたし"
else
    log "  ✅ 隔離セッションは自然終了した (socket=${SOCK})"
fi
log ""

log "═══ 結果: PASS=${PASS} FAIL=${FAIL} ═══"
[ "$FAIL" -eq 0 ]
