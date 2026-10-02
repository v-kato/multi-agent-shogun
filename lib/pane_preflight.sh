#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# lib/pane_preflight.sh — 自動打鍵の安全集合 (cmd_754 最終版)
# ═══════════════════════════════════════════════════════════════
#
# ★結論: agent CLI が動いている pane へ自動で打鍵してよい状態の集合は
#   ★空である。本ファイルはその一点を実装する。
#
# ═══════════════════════════════════════════════════════════════
# ★なぜ空なのか (将軍裁定 E-1 / 2026-09-08)
# ═══════════════════════════════════════════════════════════════
#
#   2026-09-08 の事故:
#     10:20:00      将軍 → 家老へ裁定送信(答えは No)
#     10:20:57      家老 → 足軽3号へ中継(このディレクトリは削除するな)
#     10:20:58      inbox_watcher が pane 3 へ [SEND-KEYS] nudge
#     10:20:59.16   削除が実行された
#   nudge の Enter が既定の選択肢 `❯ 1. Yes` を選び、D002-E1 違反の削除が
#   実際に実行された。「削除するな」という命令を届けたことが、削除する
#   ボタンを押した。
#
#   この事故のあと、我らは4世代にわたり「画面から安全を証明する」ことを
#   試みた。★4度やって4度破れている。
#     原初            : blocklist 型(危険の列挙) → 未収載モーダルで fail-open
#     redo1           : marker 片の認証        → 部分一致で汚染
#     redo2           : 境界付き layout 認証   → 枠の上の未消費行で汚染
#     finite_allowlist: cursor 版の有限 allowlist → 本裁定で棄却
#
#   ★将軍の裁定理由(そのまま):
#     画面から読める状態(cursor位置・layout・marker・text)は、いずれも
#     「描かれたもの」であって「入力がどこへ送られるか」ではない。tmux の
#     cursor_y は foreground application が最後に描いた位置に過ぎず、描画と
#     配送は別物である。ゆえに「安全に打鍵してよいと画面から証明できる
#     状態」の集合は★空である。これは失敗ではなく、将軍が命じた列挙の
#     正直な答えである。
#
#   ★天秤(将軍の言葉のまま):
#     届かぬ代償=遅延。人が気づいて動く。可視である。誤爆の代償=本日、
#     D002-E1 違反の削除が実行された。不可視であった。止まっている agent は
#     見える。誤って押された釦は見えない。見える失敗を選ぶ。
#
# ═══════════════════════════════════════════════════════════════
# ★禁止 (最重要・後続の実装者へ)
# ═══════════════════════════════════════════════════════════════
#
#   1. 画面状態(cursor / text / layout / marker)から active focus を推論する
#      コードを本ファイルへ書き戻すな。4度破れている。5度目をやるな。
#      ★本ファイルは `tmux capture-pane` を一度も呼ばない。呼ぶ必要が
#      生じたと感じたら、それは安全集合を広げようとしている合図である。
#   2. 「配信率を上げるために安全集合を広げる」修正をするな。三世代とも
#      その方向で破れている。★通らないことが仕様である。
#   3. モーダルへ自動で答える機能を作るな。`No` を送るのも禁止である。
#      答えるのは人である。
#   4. 同一 agent process が nonce/世代を発行して受領を権威的に証明する
#      out-of-band ready handshake(軍師第2案)は設計として筋が良いが、
#      ★本ファイルへ書くな。別 cmd とし、実装前に軍師・将軍の gate を通す。
#
# ═══════════════════════════════════════════════════════════════
# ★本ファイルが扱う「もう一つの、別の問い」 (混同するな)
# ═══════════════════════════════════════════════════════════════
#
#   上で棄却したのは次の問いである:
#       × 「動いている CLI の中で、この打鍵はどの要素へ届くか」
#         → 描かれた画面からは原理的に答えられない。ゆえに常に禁止。
#
#   本ファイルはもう一つ、まったく別の問いに答える:
#       ○ 「この pane で、そもそも CLI が動いているか」
#         → tmux の `#{pane_current_command}` は pane の tty の★前景プロセスで
#            あり、描画物ではなく OS の職制御(job control)が持つ事実である。
#            答えが `bash` 等の素のシェルなら、TUI は存在せず、したがって
#            モーダルも既定選択肢も存在しない。
#
#   この第二の問いを使ってよいのは、★これから CLI を起動しようとしている
#   場面(出陣・人手による CLI 切替)だけである。メッセージ配送には★決して
#   用いない。用途を広げるな。
#
#   ★残余リスク(正直に記す):
#     (a) 素のシェルであっても、人がその場で何か入力している最中かもしれぬ。
#         起動打鍵はその入力へ混ざる。ゆえにこの経路は「人が今この pane を
#         起動しようとしている」場面に限る。
#     (b) 検査と送信の間に CLI が起動し得る(TOCTOU)。出陣ではその pane を
#         直前に自ら作っており、窓は自分の制御下にある。
#     (c) `#{pane_current_command}` が読めぬ場合は「CLI が動いている」側へ
#         倒す(fail-safe)。
#
# ═══════════════════════════════════════════════════════════════
# ─── 提供関数 ───
#
#   preflight_safe_state_count
#       → 安全集合の要素数を stdout へ出す。★常に 0 である。
#         試験はこの値を直接検査する(「空である」ことの機械可読な表明)。
#
#   pane_send_preflight <pane_target> [ctx]
#       → ★常に 1 (送信禁止) を返す。PREFLIGHT_REASON に理由を格納する。
#         引数は呼出側の互換のために受け取るが、判定には一切用いない。
#         判定材料を持たぬのではない。★判定してよい材料が存在しないので
#         ある。
#
#   pane_foreground_command <pane_target>
#       → pane の前景プロセス名を stdout へ。読めなければ空文字。
#
#   pane_is_bare_shell <pane_target>
#       → 0 = 前景が素のシェル(CLI は動いていない)
#         1 = それ以外・判定不能(CLI が動いている扱い)
#         ★理由は PANE_SHELL_REASON に格納する。
#
#   ★tmux の target 解決は寛容である(実測 2026-09-08・隔離tmux):
#     `display-message -t <sess>:<win>.99` は範囲外の pane 番号を丸めて
#     既存 pane を返し、rc も 0 である。存在せぬ session を指した時だけ
#     出力が空になる。ゆえに「rc が 0 だから pane が在る」とは言えぬ。
#     本ライブラリは pane_id が★非空であることを存在の根拠とし、さらに
#     pane_id と前景プロセスを★一度の問い合わせで同時に取る(二度に分けると
#     その間に pane が入れ替わり得る)。
#     ★残余リスク: 同一 window 内の範囲外番号は丸められるため、宛先を
#     取り違えた場合に「別の pane の前景」を見ることがある。その pane が
#     CLI を走らせていれば送らぬ側へ倒れるが、素のシェルなら送り得る。
#     呼出側は自分が作った/自分が指した pane にのみ本関数を使うこと。
# ═══════════════════════════════════════════════════════════════

# tmux 問い合わせのタイムアウト秒
PREFLIGHT_CAPTURE_TIMEOUT="${PREFLIGHT_CAPTURE_TIMEOUT:-3}"

# ★安全集合の要素数。空であることの機械可読な表明である。
# この関数が 0 以外を返すよう変更することは、本 cmd の裁定を覆すことに
# 等しい。変更する前に将軍・軍師の gate を通せ。
preflight_safe_state_count() {
    echo 0
}

# pane_send_preflight <pane_target> [ctx]
# ★agent CLI が動いている pane への自動打鍵は一律禁止である。
# 本関数は pane を一切覗かない。覗いても答えは変わらぬからである。
# Returns: 常に 1 (送信禁止)
pane_send_preflight() {
    PREFLIGHT_REASON="automatic_send_forbidden"
    return 1
}

# pane_foreground_command <pane_target>
# pane の tty の前景プロセス名を返す。読めなければ空文字を返す。
# ★画面ではなく職制御(job control)の事実を読む。
pane_foreground_command() {
    local pane_target="${1:-}"
    [ -n "$pane_target" ] || return 0
    timeout "$PREFLIGHT_CAPTURE_TIMEOUT" \
        tmux display-message -t "$pane_target" -p '#{pane_current_command}' 2>/dev/null \
        | tr -d '\r' | head -n1 | tr -d '[:space:]' || true
}

# pane_is_bare_shell <pane_target>
# 「この pane では CLI が動いていない(前景が素のシェルである)」ことだけを
# 判定する。★メッセージ配送の可否判断へ用いてはならぬ。
# Returns: 0 = 素のシェル / 1 = それ以外(判定不能を含む)
pane_is_bare_shell() {
    local pane_target="${1:-}"
    PANE_SHELL_REASON=""

    if [ -z "$pane_target" ]; then
        PANE_SHELL_REASON="pane_target_unset"
        return 1
    fi

    # ★pane_id と前景プロセスを一度に取る。二度に分けると、その間に pane が
    #   入れ替わっても気づけぬ。
    local raw pane_id fg
    raw=$(timeout "$PREFLIGHT_CAPTURE_TIMEOUT" \
        tmux display-message -t "$pane_target" -p '#{pane_id}|#{pane_current_command}' 2>/dev/null \
        | tr -d '\r' | head -n1) || true
    if [ -z "$raw" ] || [ "${raw%%|*}" = "$raw" ]; then
        # 問い合わせ自体が失敗した / 区切りが無い = 判定不能
        PANE_SHELL_REASON="pane_query_failed"
        return 1
    fi
    pane_id="${raw%%|*}"
    fg="${raw#*|}"
    fg="${fg//[[:space:]]/}"

    if [ -z "${pane_id//[[:space:]]/}" ]; then
        # ★存在せぬ session を指すと tmux は rc=0 のまま空を返す。
        #   pane_id が空であることを存在せぬ証拠として扱う。
        PANE_SHELL_REASON="pane_absent"
        return 1
    fi
    if [ -z "$fg" ]; then
        # 読めぬなら「CLI が動いている」側へ倒す(fail-safe)。
        PANE_SHELL_REASON="foreground_unreadable"
        return 1
    fi

    case "$fg" in
        bash|-bash|zsh|-zsh|sh|-sh|dash|-dash|ksh|-ksh|fish|-fish|tcsh|-tcsh|csh|-csh)
            PANE_SHELL_REASON="bare_shell:${fg}"
            return 0
            ;;
        *)
            # CLI 本体でも、シェルが前景で走らせている別コマンドでも同じ扱いに
            # する。いずれにせよ「素のシェルではない」からである。
            PANE_SHELL_REASON="foreground_not_shell:${fg}"
            return 1
            ;;
    esac
}
