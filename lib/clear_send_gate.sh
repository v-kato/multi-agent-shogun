#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# lib/clear_send_gate.sh — `/clear`(★claude のみ)の三重条件つき限定送信
#                          (cmd_757② / 将軍裁定 2026-09-09 12:41
#                           / redo1 2026-09-09 軍師QC差戻しを受けた是正)
# ═══════════════════════════════════════════════════════════════
#
# ★★本ファイルは cmd_754 E-1 を破棄しない。
#
#   cmd_754 E-1(2026-09-08)は「agent CLI 稼働 pane への自動打鍵の安全集合を
#   空にせよ」と裁定した。★その裁定は生きている。
#   `lib/pane_preflight.sh` の `preflight_safe_state_count` は今も 0 を返し、
#   `pane_send_preflight` は今も常に送信禁止を返す。★1文字も変えていない。
#
#   本ファイルが行うのは、★その空集合の上に「一命令・二条件」の限定的な
#   例外を★新設することである。土台(空集合)を削るのではなく、上に積む。
#   ゆえに:
#     ・既定は依然として「送らない」である。
#     ・本ファイルの gate を通らなかったものは、cmd_754 の世界のまま
#       人経路(家老 inbox → dashboard 🚨要対応)へ倒れる。
#     ・本ファイルを source しない限り、系の挙動は cmd_754 のままである。
#
# ═══════════════════════════════════════════════════════════════
# ★なぜ一点だけ開けたのか (経緯)
# ═══════════════════════════════════════════════════════════════
#
#   cmd_754 の裁定理由は「★画面から打鍵の安全は証明できない」であった。
#   4世代にわたり画面から安全を証明しようとし、4度とも破れた。
#
#   cmd_757① (足軽7号・隔離環境での実測・2026-09-09) が、その前提を
#   ★部分的に覆した。画面ではなく★セッション自身の申告を読む経路が
#   存在し、確認モーダル表示中のセッションは:
#
#       status = "waiting" / waitingFor = "permission prompt"
#
#   と申告する。★`idle` とは申告しない。実測の内訳は次のとおり:
#     ・`waiting`/"permission prompt" を採れたモーダル … 計7回
#       (パーミッション確認5回・plan承認2回)
#     ・信頼ダイアログ2回 …… ★申告ファイルそのものが書かれず mesh に
#       載らなかった。これは「idle と申告した」のではなく「何も申告
#       しなかった」である。ゆえに★mesh 不在は危険側として扱う
#       (下の `gate_condition1_self_reports_idle` は不在を不許可とする)。
#     ・モーダル中に `idle` と申告した例 …… ★0件(反例0)。
#
#   これは「描かれた画面」ではなく「当のプロセスが自分で書いた値」である。
#   将軍はこれを根拠に、E-1 の安全集合を「空」から「一命令・二条件」へ
#   ★一点だけ開ける裁定を下した。
#
# ═══════════════════════════════════════════════════════════════
# ★★★最重要 — この実装が証明していないこと (誤読防止)
# ═══════════════════════════════════════════════════════════════
#
#   ★★「`idle`は安全な入力受領の十分条件ではない。①が実証したのは『試した確認モーダルが`idle`から排除される』ことのみである」
#
#   この一文が本ファイルの前提である。噛み砕いて言えば:
#
#     ・①が示したのは「モーダル中は idle と申告しない」という★排除である。
#     ・「idle と申告しているなら入力を安全に受け取れる」という★含意は
#       ★証明されていない。方向が逆であり、①はそちらを一度も示していない。
#     ・反証すら手元にある: ①の実測で、Claude Code は起動 1.1〜1.4 秒後、
#       ★TUI の初期化中に既に `idle` を申告していた。この時点で打鍵が
#       正しく届く保証は無い。★`idle` は「受け取れる」を意味しない。
#     ・観測できたモーダルは3種にすぎない。全ダイアログを網羅していない。
#     ・`~/.claude/sessions/*.json` は Claude Code の★非公開の内部実装で
#       あり、版が上がれば黙って変わりうる(①の実測は v2.1.265 系)。
#
#   ★★ゆえに「idle なら何でも送ってよい」と読んではならない。
#   ★その誤読に対する保険が★条件2(画面での★危険の否認と、★唯一許可
#   された既知の安全形への一致の二段)である。
#   条件2 は安全を足すのではなく、★条件1 が取りこぼした危険を
#   ★もう一度だけ否認する機会を作るためだけに在る。
#   条件2 を外すことは、この保険を外すことである。
#
# ═══════════════════════════════════════════════════════════════
# ★条件2 について — 「危険の否認」と「既知の安全形への一致」の二段
#                    ★どちらも「安全の証明」ではない
# ═══════════════════════════════════════════════════════════════
#
#   ★cmd_754 が禁じたのは「★画面状態から★安全を★推論すること」である。
#   条件2 はそれをしない。条件2 がするのは次の二段だけである:
#
#       (i)  ★画面に危険が★見えたら、送らない        …… 危険の否認
#       (ii) ★画面が★唯一許可された既知の安全形に一致しなければ、
#            送らない                                 …… 許可リスト型
#
#   ★★(ii) は★安全の証明ではない。この違いは本 gate の要であるゆえ
#   はっきり書く:
#     ・「安全の証明」…… 目の前の画面 X を見て「X は安全だ」と★結論する。
#       ★これが4世代にわたり4度とも破れた問いであり、cmd_754 が禁じた
#       ものである。本実装はこれを★一度も行わない。
#     ・「既知の安全形への一致」…… 我らが★先に決めた唯一の形 F と画面 X を
#       突き合わせ、★一致しなければ拒む。一致しても「X は安全だ」とは
#       ★結論しない。許可を出すのは条件1(本人の申告)と条件3(命令の限定)
#       であり、条件2 は★拒否側にしか効かない。
#     ・ゆえに条件2 が変えたのは★「何を拒むか」だけである。初版は
#       「危険と★分かっているもの」だけを拒んだ。今は「唯一許可された形
#       ★以外の全て」を拒む。★許可側は1文字も広がっていない。
#
#   ★redo1 (2026-09-09) でこの形へ転換した理由 (軍師 QC の差戻し):
#     初版の条件2 は★危険パターンの有限列挙(blacklist)であり、どの
#     パターンにも一致しない★非空画面を★無条件に通していた。軍師の
#     probe が未収載のモーダル(`Permission required / Approve access /
#     Cancel`)を画面へ置いたところ、初版は実際に `tmux send-keys` まで
#     到達した。★「未収載のモーダルも条件1 が waiting として弾く」という
#     初版の弁明は、①が★試した3種について成立した事実を★全モーダルへ
#     不当に一般化したものであり、①自身の限定(「3種のみ・網羅せず」・
#     R-6)と★矛盾していた。★これは画面から安全を推論する4度破れた問いの
#     再発である。ゆえに★未知の画面は全て拒む形へ転換した。
#
#   ★rc の意味は転換後も変わらない:
#     ・危険が見えた             → ★不許可(拒否権の行使)
#     ・既知の安全形に一致しない → ★不許可(★未知は危険側へ倒す)
#     ・既知の安全形に一致した   → ★★何も証明しない。許可も出さない。
#                                   ただ「拒否権を行使しなかった」だけである。
#     ・画面が読めなかった/空    → ★不許可(否認の材料が無いのだから
#                                   fail-closed で倒す)
#
#   ★★「一致した」から「安全だ」を導いてはならない。この実装では構造として
#   それができないようにしてある:
#   `gate_condition2_screen_is_known_safe_form` の rc=0 は★単独では何の
#   許可も生まない。呼出側(`gate_send_context_reset`)は条件1と条件3を
#   ★独立に満たすことを要求し、条件2 は★その上で更に拒否できる立場にしか
#   置かない。
#
#   ★★後続の実装者へ: 許可形の列挙(`_GATE_SCREEN_ALLOWED_FORMS`)を
#   ★「実運用の画面が通るように」広げるな。広げてよいのは、隔離環境で
#   ★実測した画面について★将軍・軍師の gate を通したときだけである。
#   「配信率を上げるために安全集合を広げる」修正は cmd_754 で三世代とも
#   破れた方向である。危険パターンの列挙(`_GATE_MODAL_VETO_PATTERNS`)の
#   方は★拒否側にしか効かぬゆえ足すのは自由である(★減らすな)。
#
# ═══════════════════════════════════════════════════════════════
# ★三条件 (将軍裁定の文言に一対一で対応する)
# ═══════════════════════════════════════════════════════════════
#
#   条件1: mesh が `idle` を申告していること      → gate_condition1_self_reports_idle
#   条件2: 画面が既知の安全形に一致すること        → gate_condition2_screen_is_known_safe_form
#          (危険が見えたら拒否・未知の画面も拒否)
#   条件3: 送るのは `/clear` ただ一つ              → gate_condition3_command_is_permitted
#
#   ★三つ全てを満たし、加えて次の三点を満たしたときに限り、
#   `gate_send_context_reset` が★1回だけ打鍵する。1つでも欠ければ送らない。
#     ・scope …… inbox type が `clear_command` であること
#     ・束縛(CLI) …… pane の実体が Claude CLI であること
#     ・★束縛(agent_id・redo2) …… 呼出側の `agent_id` が、対象 pane に
#       tmux が持たせている `@agent_id` と★完全一致すること
#   ★★加えて redo2 以降、宛先は入口で★一度だけ canonical pane_id(`%N`)へ
#   解決され、以後の検査も打鍵も★その不変 ID しか使わない
#   (`session:window.index` 形式は pane の終了で★別 pane へ再解決される)。
#
# ═══════════════════════════════════════════════════════════════
# ★fail-closed 要件 (将軍が「最も重要な歯止め」と明言した部分)
# ═══════════════════════════════════════════════════════════════
#
#   1. ★状態語彙は我らの管理下にない。Claude Code の更新で語は増えうる。
#      `idle` 以外の一切 — waiting / busy / shell / ★未知の語 / ★取得失敗 —
#      は全て★送らない。
#
#   2. ★★判定は「idle である」を確認する★肯定形で書く。
#      ★「idle でない」という★否定形で書いてはならない。
#      理由: 否定形で書くと、★未知の状態語がすり抜けて★通ってしまう。
#        誤: if [ "$st" != "idle" ]; then return 1; fi   # 未知語が通る
#        正: if [ "$st" = "idle" ]; then ...; fi; return 1  # 未知語は落ちる
#      本ファイルの判定は全て後者の形で書いてある。★この形を崩すな。
#
#   3. ★未知の状態語を観測したら★記録し、人経路(家老 inbox → dashboard)
#      へ上げる。★★この経路を「安全集合を広げる」方向に使ってはならない。
#      未知語を見たときに本ファイルがすることは
#        (a) 送らない  (b) 記録する  (c) 人へ知らせる
#      の三つだけであり、★未知語を許可側へ足す実装を書いてはならない。
#
# ═══════════════════════════════════════════════════════════════
# ★対象外 (本ファイルは触れない。cmd_754 のまま据え置く)
# ═══════════════════════════════════════════════════════════════
#
#   ・★nudge (裸の Enter・`inboxN` 打鍵) …… ★永久に不許可。
#     2026-09-08 に「削除する釦を押した」のは★裸の Enter であった。
#     起床の役目は③(クロスセッション通知)が打鍵なしで代替する。
#   ・★model_switch / cli_restart …… 引き続き人手経路のまま。
#     `bash scripts/switch_cli.sh <agent> --human-initiated ...` を人が実行する。
#   ・★モーダルへ自動で答える打鍵 …… `No` を送るのも禁止。答えるのは人である。
#   ・★入力欄クリア(C-u)の自動送信 …… 条件3 の許可集合に入っていない。
#     ゆえに送らない(残存リスク R-2 として下に明記する)。
#   ・★claude 以外の CLI (codex/opencode/copilot/kimi) …… ★redo1 で
#     不許可へ閉じた。条件1 の権威源は `~/.claude/sessions`(★Claude 自身の
#     申告)であり、他の CLI はこれを書かない(R-5)。★実体と束縛されない
#     `cli` 引数を許可根拠にしてはならぬゆえ、各 CLI 固有の権威的状態源と
#     pane 実体の束縛が別途得られるまでは人経路のままとする。
#
# ═══════════════════════════════════════════════════════════════
# ★残存リスク (gate を入れても塞がらない穴。承知の上で運用すること)
# ═══════════════════════════════════════════════════════════════
#
#   R-1 ★TOCTOU: 申告はスナップショットである。`idle` を読んでから打鍵が
#       着弾するまでの間に、セッションはターンを開始しうるしモーダルを
#       上げうる。★窓は狭まるが 0 にはならない。プロセスの外から窓を
#       閉じきる方法は無い。本ファイルは (a) 打鍵直前の再読
#       (b) 滞留時間の要求 (c) 条件2 の二重化 で窓を詰めるだけである。
#   R-2 ★入力欄の中身を申告する field が無い。打ちかけの文字列が残って
#       いても `idle` である。そこへ `/clear` + Enter を送れば、残字と
#       連結された何かが送信されうる。★C-u で消す案は条件3 の許可集合に
#       入っていないため採らない(打鍵を増やす方向だからである)。
#   R-3 ★ハングを見抜けない。申告を書くのは当のプロセス自身であり、
#       固まれば記録は `idle` のまま古びる。生存検査は pid が生きている
#       ことしか言わない。
#   R-4 ★受領の証明ではない。申告は「書いた時点の状態」であって
#       「この打鍵を受け取った」ではない。
#   R-5 ★Claude 系にしか効かない。Codex/OpenCode/Copilot/Kimi はこの記録を
#       書かないため、条件1 で自動的に閉じる。★これは正しい挙動である
#       (それらの CLI は人経路のままということでもある)。
#   R-6 ★モーダル網羅の未証明。3種・計9回で反例0だが全数ではない。
#       ★redo1 の隔離検証で4種目(起動時の「Use Fable 5.1 at high effort
#       by default?」)を観測し、これも `waiting`/"dialog open" と申告して
#       条件1 で落ちた。★反例は今も0件だが、★これは網羅の証明ではない。
#   R-7 ★非公開契約。スキーマも status の値域も内部実装であり、版が
#       上がれば黙って変わりうる。★だからこその fail-closed 要件2・3 である。
#   R-8 ★宛先の取り違えは検出できない。tmux の target 解決は寛容であり、
#       範囲外の pane 番号は丸められて★別の既存 pane を指す
#       (`lib/pane_preflight.sh` が実測して記した性質と同じものである)。
#       ★★`session:window.index` 形式は★不変の identity ではない。軍師の
#       隔離検証(redo2・2026-09-09)で、第一 pane が終了すると★同じ index
#       文字列が★別の新しい pane(pane_id が異なる)へ再解決されることが
#       実証された。ゆえに index 形式を検査と打鍵の双方へ渡す実装は、
#       ★検査していない pane へ着弾しうる。
#       ★redo2 でこれを塞いだ: `gate_send_context_reset` は入口で
#       `_gate_canonical_pane_id` により pane_target を★一度だけ canonical
#       pane_id(`%N`)へ解決し、以後の同定・pane_pid 検査・画面 capture・
#       `send-keys` は★その不変 ID しか使わない。tmux の pane_id は★再利用
#       されぬゆえ、検査した pane が終了していれば、以後の display-message は
#       ★空を返し(rc は 0 である。`_gate_canonical_pane_id` の注記を見よ)、
#       capture-pane / send-keys は rc=1 で落ちる。いずれも gate は
#       fail-closed で倒れる(★別 pane へ着弾しない)。
#       ★併せて redo2 は `agent_id` を必須とし pane の `@agent_id` へ束縛
#       したため、誤った target が★同じ `@agent_id` を持たぬ限り落ちる。
#       ★それでもなお残るのが本項である: ★呼出側が誤った target と誤った
#       agent_id を★揃えて渡した場合、その誤った pane が偶々 idle であれば
#       ★そちらの context を消してしまう。三条件はいずれもこれを検出せぬ
#       — どれも「その pane が安全か」を見るのであって「その pane が
#       宛先として正しいか」を見ていないからである。
#       ★呼出側は自分が管理している pane にのみ本 gate を使うこと。
#       ※mesh の `cwd` を突き合わせる案は検討したが、足軽の pane は
#         いずれも同じ project を cwd とするため、★同一 project 内の
#         隣の pane を取り違える場合を1つも塞がない。ゆえに採らなかった。
#   R-9 ★許可形が狭い。条件2 第二段が許すのは「空のプロンプト行のみ」
#       ただ一形である。実運用の Claude Code の idle 画面(枠付きプロンプト
#       ・ヒント行・status 行を伴う)はこの形に★一致しないため、本 gate は
#       ★事実上ほとんど許可しない。★これは欠陥ではなく選択である。
#       許可しなかったものは cmd_754 の既定(人経路)へ倒れるだけであり、
#       将軍裁定「届かぬ代償は遅延であり可視である。★見える失敗を選ぶ」に
#       沿う。許可形を増やすには隔離実測+将軍・軍師の gate を要する
#       (`_GATE_SCREEN_ALLOWED_FORMS` の手順を見よ)。
#   R-10 ★束縛は Claude にしか無い。`gate_cli_bound_to_pane` は
#       (a) cli が `claude` (b) 当該 pid の argv[0] が `claude`
#       (c) その pid が当該 pane の `pane_pid` の子孫、の三点で
#       ★呼出側の申告を pane の実体へ束縛する。★逆に言えば、他の CLI に
#       ついてはこの束縛が作れないため開けられない。また argv[0] が
#       `claude` 以外の綴り(node 経由の起動など)であれば、たとえ本物でも
#       ★不許可へ倒れる(fail-closed 側の取りこぼしであり、意図している)。
#
# ═══════════════════════════════════════════════════════════════
# ─── 提供関数 ───
#
#   gate_permitted_command_count
#       → 本 gate が許す命令の種類数を stdout へ。★常に 1 である
#         (context reset ただ一つ)。試験はこの値を直接検査する。
#
#   gate_permitted_cli_count
#       → 本 gate が許す CLI の種類数を stdout へ。★常に 1 である
#         (`claude` ただ一つ。redo1 で閉じた)。
#
#   gate_reset_command_for_cli <cli>
#       → その CLI における context reset の綴りを stdout へ。
#         ★claude → `/clear` のみ。★それ以外は空を返し rc=1(fail-closed)。
#
#   gate_condition3_command_is_permitted <cli> <command>
#       → 条件3。その CLI に対して★ちょうどその綴りであるときだけ rc=0。
#
#   gate_type_is_in_scope <inbox_type>
#       → 本 gate の対象は `clear_command` ただ一つ。それ以外は rc=1。
#         nudge / model_switch / cli_restart はここで落ちる。
#         ★redo1 以降、これは `gate_send_context_reset` の★必須入力として
#         送信口で強制される(冒頭と送信直前の二度)。
#
#   _gate_canonical_pane_id <pane_target>
#       → ★redo2 で新設。pane_target を★不変の canonical pane_id(`%N`)へ
#         ★一度だけ解決する。読めない・形が違えば rc=1(fail-closed)。
#         `gate_send_context_reset` は以後この ID しか使わない。
#
#   gate_agent_id_bound_to_pane <canonical_pane_id> <agent_id>
#       → ★redo2 で新設。呼出側が渡す `agent_id` を pane の実体
#         (tmux の `@agent_id`)へ束縛する。欠落・不一致は rc=1。
#
#   gate_condition1_self_reports_idle <pane> [agent_id]
#       → 条件1。mesh(セッション自身の申告)が `idle` であるときだけ rc=0。
#         同定・生存・束縛・滞留も併せて検査する(下記)。
#         結果は GATE_MESH_* 変数へ格納する。
#         ★送信口からは canonical pane_id を渡す。
#
#   gate_cli_bound_to_pane <pane> <cli> <pid>
#       → ★呼出側が渡す `cli` を pane の実体へ束縛する。claude ちょうど・
#         argv[0] が claude・pane_pid の子孫、の三点を全て満たすときだけ rc=0。
#
#   gate_screen_allowed_form_count
#       → 条件2 が許す★既知の安全形の種類数を stdout へ。★現在 1。
#
#   gate_condition2_screen_is_known_safe_form <pane>
#       → 条件2。★危険が見えたら拒否し、★唯一許可された既知の安全形に
#         一致しなければ(未知の画面であれば)拒否する。
#         rc=0 は「拒否権を行使しなかった」だけであり★許可ではない。
#
#   gate_send_context_reset <pane_target> <cli> <inbox_type> <agent_id>
#       → 全条件を満たしたときに限り、`/clear` を1回だけ送る。
#         ★redo2 以降 `agent_id` は★必須引数であり、確定した canonical
#         pane_id を GATE_PANE_ID へ残す。
#
#   gate_unknown_state_target <agent_id> / gate_unknown_state_needs_human_channel <agent_id>
#       → 未知状態通知の宛先。★家老・将軍が対象なら軍師+ntfy へ分岐する。
#
#   gate_record_unknown_state <state> <ctx> [agent_id]
#       → 未知の状態語を記録し人経路へ上げる。★許可側へは決して足さない。
#
#   GATE_REASON に毎回の判定理由が入る(呼出側のログ用)。
# ═══════════════════════════════════════════════════════════════

# ─── 設定 (環境変数で上書き可。既定は最も保守的な値) ───

# mesh の申告ファイル置き場。Claude Code が自分で書く。
GATE_SESSIONS_DIR="${GATE_SESSIONS_DIR:-$HOME/.claude/sessions}"

# tmux 問い合わせのタイムアウト秒。
GATE_TMUX_TIMEOUT="${GATE_TMUX_TIMEOUT:-3}"

# ★滞留要求(ミリ秒)。①の実測で、起動 1.1〜1.4 秒後には既に `idle` を
#   申告していた。TUI 初期化中でも `idle` である。ゆえに「申告が
#   `idle` になってから最低これだけ経っていること」を粗い足切りに使う。
#   ★これは安全の証明ではない。R-1/R-2 は残ったままである。
#
# ★★この値は★下げられない。環境変数で★厳しくする(大きくする)ことだけを
#   許し、緩める方向の指定・非数値・未指定は全て下限へ引き上げる。
#   理由: fail-closed の歯止めが呼出側の設定一つで無効化されては歯止めに
#   ならぬ。「配信率を上げるために安全集合を広げる」修正は cmd_754 で
#   三世代とも破れた方向である。
_GATE_DWELL_FLOOR_MS=3000
case "${GATE_MIN_IDLE_DWELL_MS:-}" in
    (''|*[!0-9]*) GATE_MIN_IDLE_DWELL_MS="$_GATE_DWELL_FLOOR_MS" ;;
    (*) [ "$GATE_MIN_IDLE_DWELL_MS" -lt "$_GATE_DWELL_FLOOR_MS" ] \
            && GATE_MIN_IDLE_DWELL_MS="$_GATE_DWELL_FLOOR_MS" ;;
esac

# ★人経路(家老 inbox → dashboard)へ上げるための足場。
# ★GATE_UNKNOWN_STATE_LOG より先に定めること(下でその既定値に使う)。
GATE_PROJECT_ROOT="${GATE_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# ★未知の状態語の記録先。
GATE_UNKNOWN_STATE_LOG="${GATE_UNKNOWN_STATE_LOG:-${GATE_PROJECT_ROOT}/logs/clear_send_gate_unknown_state.log}"

# ★我らが知っている状態語の集合。★これは「許可集合」ではない。
#   許可されるのは `idle` ただ一つであり(条件1・肯定形)、この集合は
#   ★「未知語かどうか」を判定して★記録するためだけに在る。
#   ここへ語を足しても許可は1文字も広がらない。広げてはならない。
_GATE_KNOWN_STATES="idle busy waiting shell"

# ★条件2 ★第一段の照合表 — ★危険パターンの列挙である(拒否権にしか使えない)。
#   ★この表に一致した画面は★必ず拒む。ゆえに★足すのは自由であり、
#   ★減らしてはならない。
#   ★★この表は「ここに載っていなければ通してよい」という意味を★一切持たない。
#   ここに一致しなかった画面は、続く★第二段(許可リスト・下記
#   `_GATE_SCREEN_ALLOWED_FORMS`)へ回り、★唯一許可された形以外は全て拒まれる。
#   ★redo1 以前は、この表に載らぬ画面の始末を条件1 だけに委ねてよいと
#   書いていた。★それは①が試した3種で成立した事実を全モーダルへ不当に
#   一般化したものであり、軍師 probe の未収載モーダルが実際に
#   `tmux send-keys` まで到達して破れた。★同じ一般化を書き戻すな。
#   条件2 は「第一段で拒む」→「第二段で拒む」の★二段の拒否であって、
#   どちらの段も★許可を出さない。
_GATE_MODAL_VETO_PATTERNS=(
    '❯[[:space:]]*[0-9]+\.'                       # 選択中の番号付き選択肢(事故当日の `❯ 1. Yes`)
    '^[[:space:]]*[0-9]+\.[[:space:]]*(Yes|No|はい|いいえ)'  # 番号付き Yes/No
    'Do you want'                                  # パーミッション確認の定型
    'Do you trust'                                 # 信頼ダイアログ
    'Would you like'                               # 選択肢型の定型
    '\[y/N\]|\[Y/n\]|\(y/n\)'                      # 素朴な y/n 確認
    'Press Enter to'                               # Enter を要求する画面
    'esc to interrupt'                             # 作業中(ターン実行中)の表示
)

# ★条件2 第二段の照合表 — ★許可リストである (cmd_757② redo1 で転換した)。
#   ここに在るのは「★唯一許可された既知の安全形」だけであり、正規化した
#   画面★全体がこのいずれかと一致したときにのみ拒否権を行使しない。
#   ★一致は「安全の証明」ではない(上の節を見よ)。
#
#   現在の要素は1つだけである:
#     ・空のプロンプト行のみ …… 行頭の空白を除けば `>` ただ1文字で、
#       ★他に何も表示されていない画面。
#
#   ★増やすときの手順(これ以外の方法で増やすな):
#     (1) 隔離 tmux session で当該画面を★実測し、capture-pane の生出力を
#         証跡として残す
#     (2) その形が危険な画面と★構造的に区別できることを示す
#     (3) 将軍・軍師の gate を通す
#   ★「実運用の画面が通らないから」は理由にならぬ。通らなければ送らぬ
#   だけであり、それは cmd_754 の既定(人経路)へ倒れることを意味する。
_GATE_SCREEN_ALLOWED_FORMS=(
    '^[[:space:]]*>$'                              # 空のプロンプト行のみ
)


# ═══════════════════════════════════════════════════════
# 条件3 — 送ってよい命令はただ一つ
# ═══════════════════════════════════════════════════════

# gate_permitted_command_count
# ★本 gate が許す命令の種類数。常に 1。
# この値を 1 以外へ変えることは将軍裁定を覆すことに等しい。
# 変える前に将軍・軍師の gate を通せ。
gate_permitted_command_count() {
    echo 1
}

# gate_permitted_cli_count
# ★本 gate が許す CLI の種類数。常に 1(`claude` ただ一つ)。
gate_permitted_cli_count() {
    echo 1
}

# gate_reset_command_for_cli <cli>
# ★閉じた列挙である。★claude 以外は空 + rc=1(fail-closed)。
#
# ★redo1 (2026-09-09) で `claude` ただ一つへ閉じた。理由:
#   条件1 の権威源は `~/.claude/sessions`(★Claude 自身の申告)であり、
#   Codex/OpenCode/Copilot/Kimi はこの記録を書かない(R-5)。それらの CLI に
#   ついて我らが持つ権威的な状態源は★無い。にもかかわらず初版は★呼出側が
#   渡す `cli` 文字列だけで綴りを選んでいたため、★Claude の記録で認証された
#   pane へ `cli=codex` を渡せば `/new` を送れてしまった(pane の実体とは
#   無関係に)。★実体と束縛されない自己申告を許可根拠にしてはならぬ。
#   ゆえに claude → `/clear` のみを残し、他は不許可(人経路)とする。
#   開けるには、その CLI 固有の権威的状態源と pane 実体の束縛が要る。
gate_reset_command_for_cli() {
    local cli="${1:-}"
    case "$cli" in
        claude) echo "/clear" ; return 0 ;;
    esac
    # ★否定形で書いていない。上の列挙に★合致したものだけが 0 を返す。
    #   未知の CLI も、権威源を持たぬ CLI も、ここへ落ちる。
    return 1
}

# gate_condition3_command_is_permitted <cli> <command>
# ★条件3。その CLI における context reset の綴りと★完全一致するときだけ rc=0。
# nudge(裸の Enter)・model_switch・cli_restart・C-u はここを通れない。
gate_condition3_command_is_permitted() {
    local cli="${1:-}" cmd="${2:-}"
    GATE_REASON=""

    local expected
    if ! expected=$(gate_reset_command_for_cli "$cli"); then
        GATE_REASON="c3_unknown_cli:${cli}"
        return 1
    fi
    # ★肯定形。期待する綴りと完全一致したものだけが通る。
    if [ "$cmd" = "$expected" ]; then
        GATE_REASON="c3_ok:${cmd}"
        return 0
    fi
    GATE_REASON="c3_command_not_permitted:${cmd}"
    return 1
}

# gate_type_is_in_scope <inbox_type>
# ★本 gate の対象は `clear_command` ただ一つ。
# ★nudge / model_switch / cli_restart は cmd_754 のまま据え置きである。
gate_type_is_in_scope() {
    local t="${1:-}"
    GATE_REASON=""
    # ★肯定形。clear_command だけが通る。未知の type もここで落ちる。
    if [ "$t" = "clear_command" ]; then
        GATE_REASON="scope_ok:clear_command"
        return 0
    fi
    GATE_REASON="scope_out:${t}"
    return 1
}

# ═══════════════════════════════════════════════════════
# 条件1 — mesh(セッション自身の申告)が `idle` であること
# ═══════════════════════════════════════════════════════
#
# ★ここで読むのは★当のプロセスが自分で書いた値だけである。画面は読まない。
#
# 同定と束縛について(①の実測に基づく):
#   ・★セッション名で束縛してはならない。①で衝突を実測した。probe の
#     セッション (pid 1027090) に自動付与された名 `shogun-23` は、稼働中の
#     足軽3号 (pid 13687) の名と★同一であった。名は cwd 由来の短ハッシュ
#     ゆえ衝突する。★束縛は pid + procStart + tmux pane で行う。
#   ・★申告ファイルが無い場合は★不許可である。①で、信頼ダイアログ中は
#     申告ファイルそのものが書かれなかった。「何も申告しなかった」を
#     「idle」と読み替えては★ならない。mesh 不在は危険側である。

# ═══════════════════════════════════════════════════════
# ★宛先の固定 (redo2 で新設) — index ではなく canonical pane_id を使う
# ═══════════════════════════════════════════════════════
#
# ★なぜ要るのか:
#   `session:window.index` 形式は★不変の identity ではない。軍師の隔離検証
#   (redo2・2026-09-09)で、第一 pane が終了すると★同じ index 文字列が別の
#   新しい pane(pane_id が異なる)へ再解決されることが実証された。
#   検査に index を使い、送信にも index を使うと、その間に pane が終了・
#   再配置された場合★検査していない pane へ `/clear` が着弾しうる。
#   tmux の `pane_id`(`%N`)は★再利用されず、消滅した `%N` が別 pane へ
#   再解決されることも無い(隔離実測)。ゆえに入口で★一度だけ解決し、
#   以後の同定・pane_pid 検査・画面 capture・`send-keys` の★全てを
#   この不変 ID だけで行う。

# _gate_canonical_pane_id <pane_target>
# ★pane_target を canonical pane_id(`%N`)へ解決する。
# ★形の検査も課す — `%` に続くのが★数字だけであるものだけを通す(肯定形)。
# 読めない・形が違う場合は rc=1(fail-closed)。
#
# ★★rc で判定してはならぬ(redo2 の隔離実測・
#   `tests/verify_cmd_757_pane_rebind_isolated.sh`):
#   `tmux display-message -t <消滅した %N>` は★rc=0 を返し、stdout も
#   stderr も★空である。★黙って 0 を返す道具であり、rc を信じると
#   「空を掴んだまま成功した」ことになってしまう。ゆえにここでは
#   ★出力の形そのものを検査する。なお別 pane へ★再解決されることは
#   無い(空が返るだけである)ことも同じ実測で確かめてある。
#   ★capture-pane / send-keys の方は消滅した pane に対し rc=1 で落ちる。
_gate_canonical_pane_id() {
    local pane_target="${1:-}"
    [ -n "$pane_target" ] || return 1
    local id
    id=$(timeout "$GATE_TMUX_TIMEOUT" \
        tmux display-message -t "$pane_target" -p '#{pane_id}' \
        2>/dev/null | tr -d '\r' | head -n1 | tr -d '[:space:]')
    # ★肯定形・閉じた形。空も、`%` 以外で始まるものも、ここで落ちる。
    case "$id" in
        %*) : ;;
        *) return 1 ;;
    esac
    case "${id#%}" in
        (''|*[!0-9]*) return 1 ;;
    esac
    printf '%s\n' "$id"
    return 0
}

# _gate_pane_agent_id <canonical_pane_id>
# ★その pane に tmux が持たせている `@agent_id`(pane option)を返す。
#   ★これは呼出側の申告ではなく★tmux が持つ事実であり、CLAUDE.md の
#   Session Start 手順が自己識別に用いているのと同じ源である。
# 読めなければ空を返す(呼出側が fail-closed で倒す)。
_gate_pane_agent_id() {
    local pane_id="${1:-}"
    [ -n "$pane_id" ] || return 0
    timeout "$GATE_TMUX_TIMEOUT" \
        tmux display-message -t "$pane_id" -p '#{@agent_id}' \
        2>/dev/null | tr -d '\r' | head -n1 | tr -d '[:space:]' || true
}

# gate_agent_id_bound_to_pane <canonical_pane_id> <agent_id>
# ★呼出側が渡す `agent_id` を pane の実体(`@agent_id`)へ束縛する。
#
# ★なぜ要るのか (redo2・差戻し理由2):
#   redo1 の `agent_id` は既定値つきの★任意引数であった。一方、
#   未知状態通知の宛先分岐は pane の実体ではなく★呼出側が渡す agent_id
#   だけを見ていた。ゆえに家老 pane を対象に3引数の正規 usage で呼ぶと
#   `agent_id=unknown` となり、`gate_unknown_state_target unknown` は
#   ★家老へ分岐した — redo1 が直したはずの「家老自身への自己通知」が、
#   production entry の★許された呼び方で再現していた。
#   ★自己申告を実体へ束縛しない限り、その値を分岐や許可の根拠にしてはならぬ。
#
# Returns: 0 = 呼出側の agent_id が pane の `@agent_id` と完全一致
#          1 = 未指定 / pane 側が読めぬ / 不一致 (いずれも fail-closed)
gate_agent_id_bound_to_pane() {
    local pane_id="${1:-}" agent_id="${2:-}"
    GATE_REASON=""

    if [ -z "$agent_id" ]; then
        GATE_REASON="agent_id_unset:★agent_id は必須である"
        return 1
    fi

    local actual
    actual=$(_gate_pane_agent_id "$pane_id")
    if [ -z "$actual" ]; then
        # ★pane が `@agent_id` を持たぬ(出陣を経ていない pane・素の pane)。
        #   実体と突き合わせられぬのだから通さない。
        GATE_REASON="agent_id_pane_option_missing:${pane_id}"
        return 1
    fi
    # ★肯定形。完全一致したものだけが通る。
    if [ "$agent_id" = "$actual" ]; then
        GATE_REASON="agent_id_ok:${agent_id}"
        return 0
    fi
    GATE_REASON="agent_id_mismatch:caller=${agent_id}/pane=${actual}"
    return 1
}

# _gate_resolve_pane_identity <pane_target>
# pane を mesh の `tmux` field と同じ綴り(`<session>:@<win>.%<pane>`)へ解決する。
# ★これは画面(描かれたもの)ではなく tmux が持つ pane の identity である。
# 読めなければ空を返す(呼出側が fail-closed で倒す)。
_gate_resolve_pane_identity() {
    local pane_target="${1:-}"
    [ -n "$pane_target" ] || return 0
    timeout "$GATE_TMUX_TIMEOUT" \
        tmux display-message -t "$pane_target" -p '#{session_name}:#{window_id}.#{pane_id}' \
        2>/dev/null | tr -d '\r' | head -n1 | tr -d '[:space:]' || true
}

# _gate_proc_start <pid>
# /proc/<pid>/stat の第22フィールド(starttime)。mesh の `procStart` と
# 突き合わせて★pid 再利用による誤爆を防ぐ。
# ★comm(第2フィールド)は空白や括弧を含みうるので、★最後の `)` で切る。
_gate_proc_start() {
    local pid="${1:-}"
    [ -n "$pid" ] || return 1
    local stat_line
    stat_line=$(cat "/proc/${pid}/stat" 2>/dev/null) || return 1
    [ -n "$stat_line" ] || return 1
    local tail_part="${stat_line##*) }"
    # tail_part の先頭は state(第3フィールド)。starttime は全体で第22 ゆえ
    # ここでは 22-3+1 = 20 番目。
    awk '{print $20}' <<< "$tail_part"
}

# _gate_now_ms — 現在時刻をミリ秒で。
_gate_now_ms() {
    date +%s%3N
}

# gate_unknown_state_target <agent_id>
# ★未知状態通知の宛先を返す。既存の delivery contract
#   (`scripts/inbox_watcher.sh` の `delivery_alert_target`)と同じ形である。
#   ★家老・将軍が対象のとき家老 inbox は★出口にならない:
#     ・家老 …… dashboard.md を書ける唯一の agent が当人であり、その当人が
#       止まっているときの自己通知は誰にも届かぬ(★redo1 の差戻し理由4)
#     ・将軍 …… 家老→将軍の inbox 直送は禁止であり、そもそも宛先が無い
#   ゆえに軍師(→家老→dashboard)へ回す。
gate_unknown_state_target() {
    case "${1:-}" in
        karo|shogun) echo "gunshi" ;;
        *)           echo "karo" ;;
    esac
}

# gate_unknown_state_needs_human_channel <agent_id>
# ★inbox だけでは人に届かぬ配置かを返す(`delivery_needs_human_channel` と
#   同じ契約)。Returns: 0 = ntfy 併用が要る / 1 = inbox → dashboard で足りる
gate_unknown_state_needs_human_channel() {
    case "${1:-}" in
        karo|shogun) return 0 ;;
    esac
    return 1
}

# gate_record_unknown_state <state> <ctx> [agent_id]
# ★未知の状態語を記録し、人経路(inbox → dashboard 🚨要対応)へ上げる。
# ★★この経路は「安全集合を広げる」方向に使ってはならない。ここでするのは
#   (a) 送らない (b) 記録する (c) 人へ知らせる の三つだけである。
#   未知語を許可側へ足す実装をここへ書き足すな。
gate_record_unknown_state() {
    local state="${1:-}" ctx="${2:-}" agent_id="${3:-unknown}"
    local ts
    ts=$(date "+%Y-%m-%dT%H:%M:%S%z")

    mkdir -p "$(dirname "$GATE_UNKNOWN_STATE_LOG")" 2>/dev/null || true
    printf '%s\tagent=%s\tstate=%s\tctx=%s\n' \
        "$ts" "$agent_id" "$state" "$ctx" >> "$GATE_UNKNOWN_STATE_LOG" 2>/dev/null || true

    # ★人経路。★宛先は既存 delivery contract に従って分岐する。
    #   ★通知が失敗しても gate の判定は変わらない(既に不許可である)。
    local target
    target=$(gate_unknown_state_target "$agent_id")
    local msg="【未知の状態語を観測】${agent_id}(pane 判定中)の mesh 申告が \`${state}\` であった。"
    msg="${msg}★cmd_757②の gate は \`idle\` 以外を一律不許可とするため送信は行っておらぬ(fail-closed)。"
    msg="${msg}Claude Code の版が上がり状態語彙が増えた見込み。★この語を許可側へ足してはならない。"
    msg="${msg}記録: ${GATE_UNKNOWN_STATE_LOG} / ctx=${ctx}。dashboard.md 🚨要対応へ掲載されたし。"
    if [ -x "${GATE_PROJECT_ROOT}/scripts/inbox_write.sh" ]; then
        bash "${GATE_PROJECT_ROOT}/scripts/inbox_write.sh" \
            "$target" "$msg" delivery_blocked "${agent_id}" >/dev/null 2>&1 || true
    fi

    # ★家老・将軍が対象のときは inbox だけでは人に届かぬ。ntfy で殿へ直接上げる。
    if gate_unknown_state_needs_human_channel "$agent_id"; then
        local notifier="${GATE_PROJECT_ROOT}/scripts/ntfy.sh"
        if [ -f "$notifier" ]; then
            bash "$notifier" "🚨 要対応 — ${msg}" >/dev/null 2>&1 || true
        fi
    fi
    return 0
}

# gate_condition1_self_reports_idle <pane_target> [agent_id]
# ★`pane_target` は tmux が受ける任意の綴りでよいが、★送信口からは
#   ★必ず canonical pane_id(`%N`)が渡される(R-8・redo2)。
# ★`agent_id` は記録用の補助にすぎない。★未知状態通知の宛先分岐は
#   呼出側の申告ではなく★pane の実体(`@agent_id`)から採る(redo2)。
# ★条件1。次を全て満たしたときだけ rc=0:
#   (a) 在籍: その pane に束縛された申告ファイルが★ちょうど1つ在ること
#   (b) 生存: pid が生きており procStart が一致すること(pid 再利用対策)
#   (c) 束縛: 申告の `tmux` field が対象 pane と一致すること
#   (d) 申告: status が★`idle` であること(★肯定形で判定する)
#   (e) 滞留: `idle` になってから GATE_MIN_IDLE_DWELL_MS 以上経っていること
# 結果は GATE_MESH_STATUS / GATE_MESH_WAITING_FOR / GATE_MESH_PID /
# GATE_MESH_DWELL_MS へ格納する。
gate_condition1_self_reports_idle() {
    local pane_target="${1:-}" agent_id="${2:-unknown}"
    GATE_REASON=""
    GATE_MESH_STATUS=""
    GATE_MESH_WAITING_FOR=""
    GATE_MESH_PID=""
    GATE_MESH_DWELL_MS=""

    if [ -z "$pane_target" ]; then
        GATE_REASON="c1_pane_target_unset"
        return 1
    fi

    # jq が引けなければ判定材料を読めない。★読めないものは不許可である。
    if ! command -v jq >/dev/null 2>&1; then
        GATE_REASON="c1_jq_unavailable"
        return 1
    fi

    # (c) 束縛先を先に確定する。読めなければ不許可。
    local ident
    ident=$(_gate_resolve_pane_identity "$pane_target")
    if [ -z "$ident" ]; then
        GATE_REASON="c1_pane_identity_unreadable"
        return 1
    fi

    # (a) 在籍。★この pane に束縛された申告ファイルを探す。
    #     0件(信頼ダイアログ中・起動途中・Codex系など)は★不許可。
    #     2件以上(曖昧)も★不許可。
    local f matched="" match_count=0 rec
    for f in "$GATE_SESSIONS_DIR"/*.json; do
        [ -f "$f" ] || continue
        rec=$(jq -r '[(.tmux//""),(.pid//""),(.procStart//""),(.status//""),(.waitingFor//""),(.statusUpdatedAt//0)] | @tsv' \
              "$f" 2>/dev/null) || continue
        [ -n "$rec" ] || continue
        local rec_tmux
        rec_tmux=$(cut -f1 <<< "$rec")
        if [ "$rec_tmux" = "$ident" ]; then
            matched="$rec"
            match_count=$((match_count + 1))
        fi
    done

    if [ "$match_count" -eq 0 ]; then
        # ★mesh 不在は危険側である。①で信頼ダイアログ中は申告ファイルが
        #   書かれなかった。「何も申告しなかった」を「idle」と読むな。
        GATE_REASON="c1_no_mesh_record_for_pane:${ident}"
        return 1
    fi
    if [ "$match_count" -gt 1 ]; then
        GATE_REASON="c1_ambiguous_mesh_records:${match_count}"
        return 1
    fi

    local m_pid m_procstart m_status m_waiting m_updated
    m_pid=$(cut -f2 <<< "$matched")
    m_procstart=$(cut -f3 <<< "$matched")
    m_status=$(cut -f4 <<< "$matched")
    m_waiting=$(cut -f5 <<< "$matched")
    m_updated=$(cut -f6 <<< "$matched")

    GATE_MESH_STATUS="$m_status"
    GATE_MESH_WAITING_FOR="$m_waiting"
    GATE_MESH_PID="$m_pid"

    # (b) 生存。★signal 0 は CLAUDE.md D006 の Signal-0 exclusion により
    #     「signal ではない」— 存在確認にしか使えず、対象を終了・中断・
    #     変更できない。ここでは存在確認としてのみ用いる。
    if [ -z "$m_pid" ] || ! kill -0 "$m_pid" 2>/dev/null; then
        GATE_REASON="c1_mesh_pid_not_alive:${m_pid}"
        return 1
    fi
    # ★pid 再利用対策。procStart が一致しなければ別プロセスである。
    local actual_start
    actual_start=$(_gate_proc_start "$m_pid") || actual_start=""
    if [ -z "$actual_start" ] || [ "$actual_start" != "$m_procstart" ]; then
        GATE_REASON="c1_proc_start_mismatch:${m_procstart}/${actual_start}"
        return 1
    fi

    # ★未知の状態語の検出。★記録のためだけに行う。許可は1文字も広がらない。
    local known=0 k
    for k in $_GATE_KNOWN_STATES; do
        if [ "$m_status" = "$k" ]; then
            known=1
            break
        fi
    done
    if [ "$known" -eq 0 ]; then
        # ★宛先分岐は★pane の実体(tmux の `@agent_id`)から採る (redo2)。
        #   呼出側の申告に委ねると、家老 pane を対象に agent_id を省いた
        #   呼び方をしたとき★家老自身への自己通知になってしまう。
        #   実体が読めぬときだけ呼出側の値へ倒す(それも読めねば unknown)。
        local notify_id
        notify_id=$(_gate_pane_agent_id "$pane_target")
        [ -n "$notify_id" ] || notify_id="$agent_id"
        [ -n "$notify_id" ] || notify_id="unknown"
        gate_record_unknown_state "$m_status" "pane=${pane_target} ident=${ident}" "$notify_id"
        GATE_REASON="c1_unknown_state_recorded:${m_status}"
        return 1
    fi

    # (d) 申告。★★肯定形で書く。「idle である」ことを確認する。
    #     ★「idle でない」という否定形で書いてはならない。否定形にすると
    #     未知の状態語がすり抜けて★通ってしまう。
    #     ここへ到達した時点で waiting/busy/shell/未知語は全て下の
    #     return 1 へ落ちる。
    if [ "$m_status" = "idle" ]; then
        # (e) 滞留。①の実測で起動 1.1〜1.4 秒後には既に `idle` を申告して
        #     いた。TUI 初期化中でも `idle` である。★粗い足切りにすぎない。
        local now_ms dwell
        now_ms=$(_gate_now_ms)
        # ★時刻が★十進の数値であることを確かめてから使う。
        #   R-7 のとおりスキーマは非公開契約であり、版が上がれば型すら
        #   変わりうる。数値でないものを算術へ渡すと、`set -u` を敷いた
        #   呼出側で「unbound variable」となって★落ちる。落ちるのは
        #   fail-closed ではない(送らぬ保証にならぬ)。★明示的に不許可へ倒す。
        case "$m_updated" in
            (''|*[!0-9]*)
                GATE_REASON="c1_status_timestamp_not_numeric:${m_updated}"
                return 1
                ;;
            (0)
                GATE_REASON="c1_status_timestamp_missing"
                return 1
                ;;
        esac
        dwell=$(( now_ms - m_updated ))
        GATE_MESH_DWELL_MS="$dwell"
        if [ "$dwell" -ge "$GATE_MIN_IDLE_DWELL_MS" ]; then
            GATE_REASON="c1_ok:idle dwell=${dwell}ms pid=${m_pid}"
            return 0
        fi
        GATE_REASON="c1_idle_too_fresh:${dwell}ms<${GATE_MIN_IDLE_DWELL_MS}ms"
        return 1
    fi

    # ★`idle` 以外の一切がここへ落ちる: waiting / busy / shell、
    #   および将来増えうる語(上で記録済み)。★取得失敗も同様である。
    GATE_REASON="c1_not_idle:${m_status}${m_waiting:+/${m_waiting}}"
    return 1
}

# ═══════════════════════════════════════════════════════
# 束縛 — 呼出側が渡す `cli` を pane の実体へ突き合わせる
# ═══════════════════════════════════════════════════════
#
# ★redo1 (2026-09-09) で新設した (差戻し理由2)。
#   初版の送信口は★呼出側が渡す `cli` 文字列を実 pane の CLI と照合せず、
#   その値だけで綴りを選んでいた。ゆえに Claude の記録で認証された pane へ
#   `cli=codex` を渡すと `/new` を送れてしまった。★自己申告だけを許可根拠に
#   してはならぬ。ここでは★カーネル(/proc)と★tmux が持つ事実だけを見る。

# _gate_pid_argv0 <pid>
# ★その pid の argv[0] を返す(★呼出側の申告ではなくカーネル側の事実)。
_gate_pid_argv0() {
    local pid="${1:-}"
    [ -n "$pid" ] || return 1
    tr '\0' '\n' < "/proc/${pid}/cmdline" 2>/dev/null | head -n1
}

# _gate_ppid_of <pid>
# /proc/<pid>/stat の ppid(第4フィールド)。★comm は空白や括弧を含みうる
# ゆえ、`_gate_proc_start` と同じく★最後の `)` で切ってから数える。
_gate_ppid_of() {
    local pid="${1:-}" stat_line tail_part
    [ -n "$pid" ] || return 1
    stat_line=$(cat "/proc/${pid}/stat" 2>/dev/null) || return 1
    [ -n "$stat_line" ] || return 1
    tail_part="${stat_line##*) }"
    # tail_part の先頭は state(第3)。ppid は第4ゆえ、ここでは 2 番目。
    awk '{print $2}' <<< "$tail_part"
}

# _gate_pane_pid <pane_target>
# ★その pane で走っているコマンドの pid(tmux が持つ事実)。
_gate_pane_pid() {
    local pane_target="${1:-}"
    [ -n "$pane_target" ] || return 0
    timeout "$GATE_TMUX_TIMEOUT" \
        tmux display-message -t "$pane_target" -p '#{pane_pid}' \
        2>/dev/null | tr -d '\r' | head -n1 | tr -d '[:space:]' || true
}

# gate_cli_bound_to_pane <pane_target> <cli> <pid>
# ★`pane_target` は tmux が受ける任意の綴りでよいが、★送信口
#   (`gate_send_context_reset`)からは★必ず canonical pane_id(`%N`)が
#   渡される。index 形式のまま検査すると、その後 pane が終了・再配置された
#   とき★検査していない pane を見たことになるからである(R-8)。
# ★次の三点を全て満たしたときだけ rc=0(★肯定形・閉じた列挙):
#   (a) `cli` が★`claude` ちょうどであること
#       ……権威源(`~/.claude/sessions`)を持つ唯一の CLI だからである
#   (b) その pid の argv[0] の basename が★`claude` ちょうどであること
#       ……pane の実体が Claude CLI であることの★カーネル側の事実
#   (c) その pid が当該 pane の `pane_pid` そのもの、あるいはその★子孫で
#       あること ……その申告が★この pane のものであることの★tmux 側の事実
# 1つでも読めなければ rc=1(fail-closed)。
# ★祖先を辿る深さの上限。非数値・未指定は既定へ倒す(算術で落ちるのは
#   fail-closed ではない。落ちずに明示的に既定を使う)。
#   ★これを大きくしても安全は緩まない — 「pane_pid の子孫であること」
#   という包含関係そのものは深さで変わらぬからである。
case "${GATE_BIND_MAX_DEPTH:-}" in
    (''|*[!0-9]*) GATE_BIND_MAX_DEPTH=16 ;;
esac
gate_cli_bound_to_pane() {
    local pane_target="${1:-}" cli="${2:-}" pid="${3:-}"
    GATE_REASON=""

    # (a) ★肯定形。claude ちょうどのものだけが先へ進む。
    case "$cli" in
        claude) : ;;
        *) GATE_REASON="bind_cli_has_no_authoritative_source:${cli}" ; return 1 ;;
    esac

    case "$pid" in
        (''|*[!0-9]*) GATE_REASON="bind_pid_not_numeric:${pid}" ; return 1 ;;
    esac

    # (b) ★pane の実体が Claude CLI であること。
    local argv0 base
    argv0=$(_gate_pid_argv0 "$pid") || argv0=""
    base="${argv0##*/}"
    case "$base" in
        claude) : ;;
        *) GATE_REASON="bind_pane_process_not_claude:${base:-unreadable}" ; return 1 ;;
    esac

    # (c) ★その pid が当該 pane の下で走っていること。
    local pane_pid
    pane_pid=$(_gate_pane_pid "$pane_target")
    case "$pane_pid" in
        (''|*[!0-9]*) GATE_REASON="bind_pane_pid_unreadable:${pane_pid}" ; return 1 ;;
    esac

    local cur="$pid" depth=0 ppid
    while [ "$depth" -le "$GATE_BIND_MAX_DEPTH" ]; do
        if [ "$cur" = "$pane_pid" ]; then
            GATE_REASON="bind_ok:claude pid=${pid} under pane_pid=${pane_pid} depth=${depth}"
            return 0
        fi
        ppid=$(_gate_ppid_of "$cur") || ppid=""
        case "$ppid" in
            (''|*[!0-9]*) break ;;
            (0|1)         break ;;
        esac
        cur="$ppid"
        depth=$(( depth + 1 ))
    done

    GATE_REASON="bind_pid_not_under_pane:${pid}/${pane_pid}"
    return 1
}

# ═══════════════════════════════════════════════════════
# 条件2 — 画面が★唯一許可された既知の安全形であること
#          (危険の否認 + 許可リスト。★安全の証明ではない)
# ═══════════════════════════════════════════════════════
#
# ★★再掲する。これは「安全の証明」ではない。
#   rc=0 は「拒否権を行使しなかった」だけであり、★単独では何の許可も
#   生まない。許可は条件1(本人の申告)と条件3(命令の限定)が出す。
#   ★この関数の戻り値を「安全である」と読み替える実装を書くな。

# gate_screen_allowed_form_count
# ★条件2 が許す既知の安全形の種類数。増やすことは安全集合を広げることで
#   あり、隔離実測と将軍・軍師の gate を要する。試験はこの値を直接検査する。
gate_screen_allowed_form_count() {
    echo "${#_GATE_SCREEN_ALLOWED_FORMS[@]}"
}

# _gate_normalize_screen <raw>
# 照合用の正規化。★情報を足さず、★行の中身は1文字も書き換えない
# (モーダルの文言を消しては照合にならぬ)。するのは次の三つだけである:
#   ・CR を除く ・各行の行末空白を除く ・空行を落とす
_gate_normalize_screen() {
    local raw="${1-}"
    printf '%s' "$raw" | tr -d '\r' | sed 's/[[:space:]]*$//' | sed '/^$/d'
}

# gate_condition2_screen_is_known_safe_form <pane_target>
# ★`pane_target` は tmux が受ける任意の綴りでよいが、★送信口からは
#   ★必ず canonical pane_id(`%N`)が渡される(R-8・redo2)。
#   画面を見た pane と打鍵する pane が食い違ってはならぬからである。
# Returns: 0 = 拒否権を行使しなかった (★許可ではない)
#          1 = ★拒否(危険が見えた / 未知の画面であった / 画面が読めなかった)
gate_condition2_screen_is_known_safe_form() {
    local pane_target="${1:-}"
    GATE_REASON=""

    if [ -z "$pane_target" ]; then
        GATE_REASON="c2_pane_target_unset"
        return 1
    fi

    local screen rc=0
    screen=$(timeout "$GATE_TMUX_TIMEOUT" tmux capture-pane -t "$pane_target" -p 2>/dev/null) || rc=$?
    if [ "$rc" -ne 0 ]; then
        # ★危険を否認できなかったのだから倒す。読めないことは安全ではない。
        GATE_REASON="c2_capture_failed"
        return 1
    fi
    if [ -z "$screen" ]; then
        # ★空も同様。否認の材料が無い。
        GATE_REASON="c2_capture_empty"
        return 1
    fi

    # ── 第一段: ★危険の否認。1つでも見えたら★拒否権を行使する。
    #    ★この列挙は拒否側にしか効かぬゆえ、足すのは自由である(減らすな)。
    local pat
    for pat in "${_GATE_MODAL_VETO_PATTERNS[@]}"; do
        if grep -qE "$pat" <<< "$screen"; then
            GATE_REASON="c2_veto_modal_visible:${pat}"
            return 1
        fi
    done

    # ── 第二段: ★唯一許可された既知の安全形への一致 (許可リスト型)。
    #    ★これは「安全の証明」ではない。我らが先に決めた形と突き合わせ、
    #    ★一致しないもの(危険と分かっているものに限らず★未知の何であれ)を
    #    全て拒むだけである。一致しても「安全だ」とは結論しない。
    local norm
    norm=$(_gate_normalize_screen "$screen")
    if [ -z "$norm" ]; then
        GATE_REASON="c2_screen_empty_after_normalize"
        return 1
    fi

    local form
    for form in "${_GATE_SCREEN_ALLOWED_FORMS[@]}"; do
        # ★^ と $ は文字列全体の境界に当たる(行ではない)。ゆえに複数行の
        #   画面が1行の許可形に一致することはない。
        if [[ "$norm" =~ $form ]]; then
            GATE_REASON="c2_known_safe_form (★既知の形への一致であって安全の証明ではない)"
            return 0
        fi
    done

    # ★未収載のモーダルも、見慣れぬ TUI も、作業ログの残る画面も、ここへ落ちる。
    #   ★「危険と分からなかった」を「安全だ」と読み替えぬための一行である。
    GATE_REASON="c2_screen_not_a_known_safe_form"
    return 1
}

# ═══════════════════════════════════════════════════════
# 三条件を束ねた、ただ一つの送信口
# ═══════════════════════════════════════════════════════

# gate_send_context_reset <pane_target> <cli> <inbox_type> <agent_id>
# ★全ての条件を満たしたときに限り、`/clear` を★1回だけ送る。
# ★redo1 (2026-09-09) で `inbox_type` を★必須入力とした(差戻し理由3)。
# ★redo2 (2026-09-09) で更に二点を締めた:
#   ・宛先を入口で★一度だけ canonical pane_id(`%N`)へ解決し、以後の検査も
#     打鍵も★その不変 ID だけを使う(index 形式は別 pane へ再解決されうる)
#   ・`agent_id` を★必須引数とし、pane の `@agent_id` へ★束縛する
# 確定した canonical pane_id は GATE_PANE_ID に残る(呼出側のログ用)。
# Returns: 0 = 送信した / 1 = 送らなかった (理由は GATE_REASON)
gate_send_context_reset() {
    local pane_target="${1:-}" cli="${2:-}" inbox_type="${3:-}" agent_id="${4:-}"
    GATE_REASON=""
    GATE_PANE_ID=""

    # ── ★scope を最初に確かめる。本 gate が扱ってよい inbox type は
    #    `clear_command` ただ一つである。
    #    ★初版は `gate_type_is_in_scope` が定義と単体試験にしか現れず、
    #    ★送信口では強制されていなかった(誤配線すれば model_switch 等の
    #    処理からでも reset を送れた。既存試験は未到達 helper だけを見る
    #    ★偽緑であった)。ゆえに production entry の★必須入力とし、
    #    ★冒頭と★送信直前の二度、完全一致を強制する。
    if [ -z "$inbox_type" ]; then
        GATE_REASON="denied_scope_inbox_type_unset:★inbox_type は必須引数である"
        return 1
    fi
    if ! gate_type_is_in_scope "$inbox_type"; then
        GATE_REASON="denied_scope:${GATE_REASON}"
        return 1
    fi

    # ── ★agent_id も必須である (redo2・差戻し理由2)。
    #    redo1 では既定値つきの任意引数であり、省略した正規 usage で
    #    ★未知状態通知が家老自身へ戻る経路が残っていた。既定値を持たせない。
    if [ -z "$agent_id" ]; then
        GATE_REASON="denied_agent_id_unset:★agent_id は必須引数である"
        return 1
    fi

    # ── 条件3 を確かめる。★何を送りうるのかを先に確定させる。
    #    ここで確定した綴り以外は、以後どこからも送られない。
    local cmd
    if ! cmd=$(gate_reset_command_for_cli "$cli"); then
        GATE_REASON="denied_c3_unknown_cli:${cli}"
        return 1
    fi
    if ! gate_condition3_command_is_permitted "$cli" "$cmd"; then
        GATE_REASON="denied_c3:${GATE_REASON}"
        return 1
    fi

    # ── ★★宛先の固定 (redo2・差戻し理由1)。
    #    ここで★一度だけ canonical pane_id(`%N`)へ解決する。
    #    ★これ以降、`$pane_target` を後段へ渡してはならない。同定・
    #    pane_pid 検査・画面 capture・`send-keys` の★全てが `$pane_id` を使う。
    #    `session:window.index` 形式は pane の終了で★別 pane へ再解決される
    #    ため、後段で再解決させると★検査していない pane へ着弾しうる。
    local pane_id
    if ! pane_id=$(_gate_canonical_pane_id "$pane_target"); then
        GATE_REASON="denied_pane_id_unresolvable:${pane_target}"
        return 1
    fi
    GATE_PANE_ID="$pane_id"

    # ── ★agent_id の束縛 (redo2)。呼出側の申告を pane の実体へ突き合わせる。
    if ! gate_agent_id_bound_to_pane "$pane_id" "$agent_id"; then
        GATE_REASON="denied_agent_id:${GATE_REASON}"
        return 1
    fi

    # ── 条件1: 本人の申告が `idle` であること(肯定形判定)
    if ! gate_condition1_self_reports_idle "$pane_id" "$agent_id"; then
        GATE_REASON="denied_c1:${GATE_REASON}"
        return 1
    fi

    # ── 束縛: ★呼出側が渡した `cli` を pane の実体へ突き合わせる。
    #    条件1 が認証した pid が、この pane で走る Claude CLI 当人であること。
    if ! gate_cli_bound_to_pane "$pane_id" "$cli" "$GATE_MESH_PID"; then
        GATE_REASON="denied_bind:${GATE_REASON}"
        return 1
    fi

    # ── 条件2: 画面が既知の安全形であること(危険の否認 + 許可リスト)
    if ! gate_condition2_screen_is_known_safe_form "$pane_id"; then
        GATE_REASON="denied_c2:${GATE_REASON}"
        return 1
    fi

    # ── ★打鍵直前の再読 (R-1 TOCTOU の窓を詰める)。
    #    ここから送信までの間隔を可能な限り詰める。★窓は 0 にはならない。
    if ! gate_condition1_self_reports_idle "$pane_id" "$agent_id"; then
        GATE_REASON="denied_c1_recheck:${GATE_REASON}"
        return 1
    fi
    if ! gate_cli_bound_to_pane "$pane_id" "$cli" "$GATE_MESH_PID"; then
        GATE_REASON="denied_bind_recheck:${GATE_REASON}"
        return 1
    fi
    if ! gate_agent_id_bound_to_pane "$pane_id" "$agent_id"; then
        GATE_REASON="denied_agent_id_recheck:${GATE_REASON}"
        return 1
    fi

    # ── ★送信直前の最終確認。ここを通った引数だけが send-keys へ届く。
    #    (scope と綴りの★完全一致を、送信と同じ関数の中で今一度課す)
    if ! gate_type_is_in_scope "$inbox_type"; then
        GATE_REASON="denied_scope_final:${GATE_REASON}"
        return 1
    fi
    if ! gate_condition3_command_is_permitted "$cli" "$cmd"; then
        GATE_REASON="denied_c3_final:${GATE_REASON}"
        return 1
    fi

    # ── 送信。★1回だけ。★`$cmd` は上の閉じた列挙で確定した綴りである。
    #    ★宛先は入口で確定した canonical pane_id であり、ここで index 形式へ
    #    戻すことは決してしない(戻せば別 pane へ再解決されうる)。
    #    text と Enter を1回の send-keys で送る。2回に分けると、その間に
    #    セッションが状態を変えうる窓が増えるためである。
    #    ★`/clear` は tmux の key 名と衝突しないため、そのまま文字列として
    #      送られる。
    #    ★C-u(入力欄クリア)は送らない。条件3 の許可集合に無いからである
    #      (残存リスク R-2)。
    if ! timeout "$GATE_TMUX_TIMEOUT" tmux send-keys -t "$pane_id" "$cmd" Enter 2>/dev/null; then
        GATE_REASON="send_failed:${cmd}"
        return 1
    fi

    GATE_REASON="sent:${cmd} pane=${pane_id} type=${inbox_type} agent=${agent_id} pid=${GATE_MESH_PID} dwell=${GATE_MESH_DWELL_MS}ms"
    return 0
}
