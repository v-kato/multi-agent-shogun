> **★時点注記(2026-09-10追記・以下は本文への変更ではない)**: 2026-09-10、cmd_754は巻き戻された(commit 7c59260・`scripts/inbox_watcher.sh`をcmd_754適用前の状態へbyte一致復元)。本書が記述する「自動打鍵は全廃した」という設計は★当時のものであり、現在は有効でない(自動打鍵は現在稼働している)。本書は当時の設計判断・時系列の一次記録として、cmd_757②(gated `/clear`)再開時の設計資料のために保存する。これより下の本文は当時の記述のまま一切変更していない。
>
> ---

# 配送経路の実相 — 何が本当にメッセージを届けているか (cmd_754)

**最終更新**: 2026-09-09 / 実装: cmd_754 (将軍裁定 E-1〜E-5) ・ cmd_757⑥で実機ギャップ(§1.1)を追記 ・ cmd_757②で `/clear` の三重条件つき限定再許可(§7.3)を追記

本書は将軍裁定 **E-4**「CLIごとに『何が配送を担うか』を成果物に明記せよ。
Claude以外(Codex/OpenCode/Copilot/Kimi)にStop hookが無いなら、self-watch
のみが残ることを正直に書け。**「たぶん届く」と書くな**。足りないなら、それは
人経路へ倒す対象として列挙せよ」に対する回答である。

---

## 0. 結論(先に書く)

| CLI | Stop hook | agent self-watch | 自動打鍵(コード) | 自動打鍵(★稼働中プロセスの実際) | **実際に配送を担うもの** |
|-----|-----------|------------------|-------------------|--------------------------------|--------------------------|
| claude   | ○ 実在(登録・稼働確認済) | ✕ 実在せぬ | ✕ 廃止(`58ed69c`) | ★★まだ生きている(§1.1) | **Stop hook**(窓の内側)+★旧nudge併存 |
| codex    | ✕ live無し(★機構自体はcmd_757④隔離PoCで実証済・trust未設定のため2026-09-09時点で不活性・§4) | ✕ 実在せぬ | ✕ 廃止(`58ed69c`) | 未検証(claude系のみ実測・§1.1) | **無い → 人経路**(live) |
| opencode | ✕ 無い | ✕ 実在せぬ | ✕ 廃止(`58ed69c`) | 未検証 | **無い → 人経路** |
| copilot  | ✕ 無い | ✕ 実在せぬ | ✕ 廃止(`58ed69c`) | 未検証 | **無い → 人経路** |
| kimi     | ✕ 無い | ✕ 実在せぬ | ✕ 廃止(`58ed69c`) | 未検証 | **無い → 人経路** |

★**自動で確実に届く CLI は一つも無い。** Claude ですら「窓の内側なら届く」で
あって「届く」ではない。以下でその意味を正確に述べる。

★★**「自動打鍵(コード)」列は `58ed69c`時点のファイル内容についてのみ真である。
2026-09-09時点で実際に稼働しているプロセスは、この commit を未反映のまま
起動され続けており、claude 系については nudge の自動送信が実測されている
(§1.1)。「コード上は廃止済み」と「稼働中プロセスで廃止済み」を混同しないこと。**

---

## 1. なぜ自動打鍵を廃したのか

2026-09-08 に起きたことの時系列:

```
10:20:00      将軍 → 家老へ裁定送信(答えは No)
10:20:57      家老 → 足軽3号へ中継(このディレクトリは削除するな)
10:20:58      inbox_watcher が pane 3 へ [SEND-KEYS] nudge
10:20:59.16   削除が実行された
```

nudge の Enter が確認モーダルの既定選択肢 `❯ 1. Yes` を選んだ。
**「削除するな」という命令を届けたことが、削除する釦を押した。**
未読がある限り watcher は nudge を繰り返すため、あらゆるパーミッション確認が
およそ60秒で自動承認される状態にあった。

その後4世代にわたり「画面から安全を証明する」試みを重ねたが、4度とも破れた。

| 世代 | 手法 | 破れ方 |
|------|------|--------|
| 原初 | blocklist(危険の列挙) | 未収載モーダルで fail-open |
| redo1 | marker 片の認証 | 部分一致で汚染 |
| redo2 | 境界付き layout 認証 | 枠の上の未消費行で汚染 |
| finite_allowlist | cursor 版の有限 allowlist | 本裁定で棄却 |

**将軍の裁定理由**: 画面から読める状態(cursor位置・layout・marker・text)は
いずれも「描かれたもの」であって「入力がどこへ送られるか」ではない。tmux の
`cursor_y` は foreground application が最後に描いた位置に過ぎず、描画と配送は
別物である。ゆえに「安全に打鍵してよいと画面から証明できる状態」の集合は
**空**である。

**天秤**: 届かぬ代償=遅延。人が気づいて動く。可視である。誤爆の代償=D002-E1
違反の削除が実際に実行された。不可視であった。**見える失敗を選ぶ。**

---

## 1.1 ★実機ギャップ — コードは全廃したが、稼働中プロセスは未反映 (2026-09-09発覚・cmd_757)

★★本節が答える問い: 「§1の設計は commit `58ed69c` で確定した。では今この瞬間、
実際に自動打鍵は止まっているか」——**否である。稼働中の `inbox_watcher.sh`
プロセスは旧コードのまま動いており、`inboxN` 相当の nudge を今なお送っている。**

**発覚経緯**: cmd_757⑥(本書更新)作業中、家老から
`queue/inbox/ashigaru4.yaml` 経由で「cmd_754の成果はファイル上のみで実機
には未反映」との報告(殿裁定・2026-09-09)が入った。以下は足軽4号がその場で
独立に行った実測による裏付けである(伝聞のまま書かない)。

**実測1: プロセス起動時刻がcommitより前**

```
$ ps -eo pid,lstart,cmd | grep inbox_watcher
16316 Mon Sep  7 14:08:02 2026  bash .../inbox_watcher.sh ashigaru4 multiagent:agents.4 claude
（他 agent 分もすべて 2026-09-07 14:08 台に起動、以後再起動なし)
```

`58ed69c`(自動打鍵ゼロ化の確定コミット)は **2026-09-08 19:13:47**。
稼働中プロセスは全てそれより1日以上前に起動しており、bash はループ本体を
起動時に読み込んで実行し続けるため、その後ファイルを書き換えても実行中の
プロセスには反映されない。

**実測2: 今日・このタスク実行中に実際に nudge が送信された**

```
$ tail logs/inbox_watcher_ashigaru4.log
[Wed Sep  9 10:52:49 JST 2026] [SKIP] claude: suppressing Escape escalation
  for ashigaru4 (Stop hook handles delivery); sending plain nudge
[Wed Sep  9 10:52:49 JST 2026] [SEND-KEYS] Sending nudge to multiagent:agents.4 for ashigaru4
[Wed Sep  9 10:54:49 JST 2026] [SEND-KEYS] Sending nudge to multiagent:agents.4 for ashigaru4
```

本書 §0 の「自動打鍵 ✕ 廃止」は commit `58ed69c` 時点のファイル内容としては
正しいが、2026-09-09時点の**運用**としては誤りである。足軽4号は本タスク中、
このnudgeを起因とする `inbox1` という通知を複数回受信しており、これは
「もう来ない」はずの `inboxN` 打鍵の現物である。

**なぜ自動 `/clear` の暴発(D002-E1違反削除と同型の事故)が再燃していないのか**:
稼働中の旧コードは、Claude系エージェントに対する Escape エスカレーションを
既に抑止していた(上記ログの `suppressing Escape escalation ... Stop hook
handles delivery`)。これは `58ed69c` より前の別コミットで先行導入されて
いたためであり、§1が防いだ「モーダル既定選択肢の誤爆」の再燃は本ログからは
確認されていない。ただし `clear_command` 型メッセージに対する自動 `/clear`
打鍵が旧コードに残っているかは未検証であり、「安全」と断定はしない。

**解消に何が要るか**: watcher プロセスの再起動(新コード読み込み)には既存
プロセスへの signal 送信が要り、これは D006 の対象である。D006-E1 が許す
のは Branch 1/2(★同一invocationがspawnしたものへの署名に限る)、または
Branch 3(★別invocationによるライフサイクル管理のために存在する条項——
同一invocation spawn要件を課さない代わりに、(a)正本記録位置の一元化・
(b)spawn側の原子的install・(c)signal側の再読込と存在確認・(d)identity照合
という独自の完結した条件セットを課す)のいずれかを★完全に満たす場合のみ
である。この長時間稼働watcherプロセス群は、Branch 1/2の前提(このタスクを
実行しているinvocationがspawnしたものであること)を満たさないだけでなく、
Branch 3が要求する正本記録の一元化・原子的install・厳格な検証のいずれも
備えていない——★どちらのbranchにも該当しない。よってこのタスクの範囲で
再起動を実施することはできない。

★この判断は権威(将軍の裁定)では変えられない。Tier 1絶対禁止は条件充足の
有無でのみ判定され、「実施可否は将軍裁定待ち」という言い回しは、あたかも
将軍の許可がTier 1絶対禁止を解除できるかのように読めてしまうため誤りで
ある。将軍裁定の対象たりうるのは「Branch 3に適合する正本記録・原子的
install・厳格な検証を備えた再起動の仕組みを新たに設計するか否か」という
★設計上の判断であり、その設計を経て初めてD006-E1の条件が満たされ
signal送信(再起動)が可能になる。「今の未整備なプロセスを今すぐ止めて
よいか」という実施の可否そのものは、権威では開かれない。★本書はその
実施状況を追跡する場ではないため、Branch 3適合設計が完成し実際に再起動が
行われた場合は、本節と §0 の表を「解消済み」へ更新すること。

---

## 2. self-watch は実在しない(実測)

裁定 E-2 は「配送は Stop hook(Claude)と self-watch(全CLI)へ倒す」とし、
将軍は `pgrep` で self-watch の稼働を確認したと述べた。**本実装での再確認の
結果、これは成立していない。**

2026-09-08 の実測 (`pgrep -f inotifywait` の全プロセスについて親と pgid を確認):

```
pid=3720476 pgid=11226 ppid=16468
   self:   inotifywait -q -t 30 -e modify -e close_write .../queue/inbox/ashigaru6.yaml
   parent: bash scripts/inbox_watcher.sh ashigaru6 multiagent:agents.6 claude
   ... (ashigaru1,2,3,4,5,7 / karo / gunshi / shogun いずれも同型)
```

見えていた `inotifywait` は**すべて `inbox_watcher.sh` 自身の監視ループの子**
であった。agent が自ら張る self-watch は**1本も存在しない**。

これは検出側の実装とも整合する。`inbox_watcher.sh` の `agent_has_self_watch()`
は自プロセスグループの `inotifywait` を除外して数えるため、現状では全 agent に
ついて常に「self-watch 無し」を返す。

> **含意**: 「self-watch があるから nudge は要らぬ」という前提は、少なくとも
> 現時点では成り立たない。将来 agent が実際に self-watch を張るようになれば
> `agent_has_self_watch()` がそれを検出し、本書の表は変わる。

**★ただし `agent_has_self_watch()` は今日でも真を返すことがある。** Stop hook が
未読を待つ間に走らせる `inotifywait`(最大55秒)は agent 側のプロセスであり、
watcher 自身の pgid ではないため検出対象に入る。これは誤検出として扱わない
— それもまた「打鍵ゼロで配送する経路が今まさに生きている」という事実であり、
送らない判断として正しいからである。**名前が古いだけである。** 本書の表では
これを self-watch ではなく §3 の Stop hook として数える。

実測(2026-09-08、隔離tmux検証 `tests/verify_cmd_754_isolated.sh` §7):

```
inbox_watcher の監視ループ = 11本 / Stop hook の待機 = 2本 / agent 自前 = 0本
```

---

## 3. Stop hook は実在する。ただし被覆には窓がある

`scripts/stop_hook_inbox.sh` は `.claude/settings.json` の `Stop` hook として
登録されており、**Claude Code の agent に限り**動作する。

**動き**:

1. agent がターンを終えようとすると発火する
2. 未読があれば `{"decision":"block"}` を返し、未読の要約を本人へ食わせる
   → agent は inbox を読んで処理する(**打鍵ゼロで届く**)
3. 未読が無ければ `inotifywait` で**最大55秒**待つ。その間に届いた新着も
   同じく BLOCK して届ける
4. 55秒経っても新着が無ければ `exit 0`。ターンが終わり、agent は idle になる

**構造的な利点**: 発火するのは「ターンを終えるとき」であり、モーダル表示中では
ない。**危険な瞬間には構造的に発火し得ない。**

**★正直に書く被覆の限界**:

- Claude Code の hook タイムアウトは 60 秒であり、hook は1回あたり最大55秒しか
  待てない。待ち終えれば `exit 0` してターンが終わる。
- **ターン終了から55秒の窓を過ぎて完全に idle になった agent** には、次に本人が
  何かを始めるまで Stop hook は発火しない。
- したがって「10分前に作業を終えて待機している足軽」への新着は、**Stop hook でも
  届かない**。
- 作業サイクルの最中(ターンが連続している間)は継続的に被覆される。

> **含意**: 「Claude なら Stop hook が届ける」は**窓の内側でのみ真**である。
> 長く待機している agent への新規タスク割当は、自動では届かない。

---

## 4. Codex / OpenCode / Copilot / Kimi には何も無い(★Codexは時点明示が必要・cmd_757④)

- Stop hook は cmd_754 時点では Claude Code 固有の機構として本書は記述して
  いたが、★cmd_757④の実機検証(隔離CODEX_HOME)により、Codex CLI
  (v0.153.4)自体もStop/SessionStart相当のhook契約(JSON
  `additionalContext`注入・`HookPrompt`注入)と、daemon不要の起床
  (`codex queue`によるqueue由来のuser message自動応答)を持つことが実証
  された。ただし2026-09-09時点のlive環境(`/home/kato/.codex/config.toml`)
  にはtrust設定が入っておらず、live上のCodex agent(gunshi/ashigaru1/
  ashigaru2)には★不活性のままである。「Codexにその機構が存在しない」と
  「今このliveデプロイでは有効化されていない」は別の事実であり、混同しない。
- self-watch は上記のとおり実在しない。
- 自動打鍵は廃止した。

**よってlive環境でこれらのCLIで動くagentへの配送経路は、現時点で一つも
無い。**(Codexについては「機構が無い」からではなく「機構はあるが
live上で有効化されていない」ことが正確な理由である。)「たぶん届く」とは
書かない。**届かない。**

2026-09-08 時点の編成では `gunshi` / `ashigaru1` / `ashigaru2` が codex である。
この3名への配送は現時点でも人経路である。

★**cmd_757④ 差戻し中(redo1進行中・2026-09-09時点)**: 足軽6号
`subtask_757_codex_stop_hook_setup` は隔離環境でのPoCを完了し、上記の
hook契約・daemon不要起床を実機で実証した(D-1「実機確認」は合格)。
しかし軍師QCは以下を理由にREDO_REQUIREDと判定した: ①SessionStart hookが
Claude用persona復旧文面を誤流用しCodexの正本(`instructions/generated/
codex-{role}.md`)を読ませていない、②live hookはInstalled=1/Active=0の
まま(trust未設定)、③trust状態の記述が推測に基づき実測(隔離
`config.toml`に`hooks.state`・`trusted_hash`が平文で現存)と食い違う、
④`.gitignore`差分にCRLF/LF巻き込み事故、⑤新規hookを検証する回帰試験が
0件、⑥`hooks.json`が個人環境の絶対パスを直書き。`subtask_757_codex_
stop_hook_setup_redo1`(足軽6号、11:59:00割当)がこの6点の限定是正に
取り組んでおり、★live hookのtrust化(有効化)そのものは今回のredoの
scopeに含まれない(有限手順の提示に留める)。本節の結論「liveでは
Stop hookが機能していない」はredo1完了・軍師QC PASS後も当面変わらない
見込みだが、★trust化が別途実施され`codex queue`等による起床が実証されれば、
本節・§0 の表を更新すること。★未完了/実装見送りに終わった場合も、その旨を
正直にここへ追記すること。

---

## 5. 人経路 (裁定 E-3 / D-5)

配送経路を持たぬ未読が滞留したとき、`inbox_watcher.sh` は次を行う。
**nudge を強行する方向の出口は作らない。**

```
未読あり
  ├─ 0〜2分  : 配送経路(Claude=Stop hook)に委ねて待つ
  └─ 2分〜   : 未配送として数える (delivery_register_undeliverable)
                └─ 連続5回で人経路へ
                     ├─ 通常の agent : 家老 inbox へ delivery_alert
                     │                  → 家老が dashboard.md 🚨要対応【将軍手番】へ掲載
                     └─ 家老・将軍自身 : 家老 inbox は出口にならぬ
                                        (dashboard を書けるのは家老当人であり、
                                         家老→将軍の inbox 直送は禁止)
                                        → 軍師 inbox へ記録 + `scripts/ntfy.sh` で殿へ直接
```

通知は 900 秒のクールダウンを持ち、連打しない。

**★「未読が捌けた」の判定は全未読(特殊命令を含む)で行う (cmd_754 redo1)**。
`get_unread_info` の `count` は `clear_command` / `model_switch` / `cli_restart`
を**除いた**数である。初版はこの `count` だけを見て未配送カウンタを 0 へ戻して
いたため、**特殊命令だけが未読として残っている状態**では、同じ周期のうちに
「未読が捌けた」と誤認してカウンタが毎回リセットされていた。結果、その滞留は
何周しても連続5回へ到達せず、**人へ一度も上がらぬまま `read: false` で永久に
沈み得た**。`clear_command` しか届いていない redo は、家老にも殿にも見えぬまま
止まるということである。

現在は、特殊命令を処理した**後**に未読集合を読み直し、`count` と未読のまま
残った特殊命令の件数を合算した**総数**を権威とする。**総数が 0 のときだけ**
カウンタをリセットする。特殊命令のみが残る周期ではカウンタは戻らず、
`send_cli_command` が周期ごとに +1 して閾値へ到達し、人へ上がる。

回帰試験: `tests/unit/test_send_keys_preflight.bats` の T-PF-035〜T-PF-039
(`clear_command` / `model_switch` / `cli_restart` を単独で複数周期通し、閾値到達と
`read: false` の維持を確認。既読化されて総数が 0 になったときだけ戻ることも確認)。

**通知には人が取るべき手当てを添える**。例:

- `clear_command` → 「人手で ashigaru3 の pane へ /clear を入力されたし」
  (codex/opencode なら `/new`)
- `model_switch` / `cli_restart` → 「人手で
  `bash scripts/switch_cli.sh ashigaru3 --human-initiated --model <model>` を実行されたし」
- 通常の未読滞留 → 「人手で当該paneをご確認くだされ」

---

## 6. 失われた機能(正直に列挙する)

| 失われたもの | 影響 | 代替 |
|--------------|------|------|
| nudge (`inboxN` 打鍵) | 待機中 agent への起床通知が自動では届かぬ(★コード上。稼働中プロセスでは§1.1参照) | Claude は窓の内側なら Stop hook。それ以外は人 |
| Escape エスカレーション | 詰まった TUI を自動で解けぬ | 人 |
| `clear_command` の自動 `/clear` | **Redo Protocol が自動では回らぬ** | 人が当該 pane へ `/clear` を入力 |
| `model_switch` の自動 `/model` | モデル切替が自動では効かぬ | 人が `switch_cli.sh --human-initiated` |
| `cli_restart` の自動委譲 | CLI 切替が自動では効かぬ | 同上 |
| task_assigned 前の context reset | 前タスクの文脈が残ったまま次タスクへ入り得る | 人が必要と判断したときだけ `/clear` |
| startup prompt | `/clear` 後の Session Start 再実行を促せぬ | `/clear` 自体を人が打つので、その後も人 |
| 入力欄クリアの `C-u` | Codex の残留テキストが消えぬ | 実害小。放置 |
| `ratelimit_check.sh` の `/status` 注入 | Codex のクォータ残量が「?」になることがある | 人が pane で `/status` を打てば次回以降拾える |

★**cmd_757 進行中(本表は未確定・2026-09-09時点)**: 上表「nudge (`inboxN`
打鍵)」および「task_assigned 前の context reset」の2行について、殿のご指摘
(「新規cmdを投げるたびに人が `/clear` を打つのは致命的」)を受け、cmd_757が
2つの再検証を走らせている。

- **①(本丸)**: パーミッション確認モーダル表示中の Claude セッションが mesh
  (`ListAgents` 相当)へ何と申告するかを隔離環境で実測する作業
  (`subtask_757_mesh_status_under_modal_probe`)。★2026-09-09時点、観測
  結論そのものは軍師QCで実質合格である: 確認モーダル中のセッションは
  `idle` ではなく `waiting`/`waitingFor="permission prompt"` を申告する
  ——4状態(idle・busy・shell・waiting)を確認モーダル4回・選択肢型2回を
  含め複数回・複数種で観測し反例0(全824件回帰もPASS・FAIL0・SKIP0)。
  ただし軍師QCは、報告の「使える。権威あるready証明になる」という
  headlineを★実証範囲を超えた過大主張と指摘した——実際に確認できたのは
  「確認モーダル中はidle以外を申告する」ことであり、「idle申告そのものが
  安全な入力受領を保証する十分条件である」ことまでは証明していない。加えて
  F004(polling禁止)違反1件・子プロセス終了記述の不正確1件が指摘され、
  `subtask_757_mesh_status_under_modal_probe_redo1`(足軽7号、11:54:00
  割当)がこれら3点の限定是正に取り組んでいる。観測結論自体(4状態・複数回
  複数種・反例0)はredoでも維持される前提である。`idle` 以外の申告は
  「本人の申告」を安全集合の根拠にする②(打鍵の再許可)の設計材料になり
  得るが、★②の是非は将軍の別裁定事項であり本redoの範囲外である。十分条件
  の証明ができていない以上、上表の代替(Stop hook/人)は現時点では変わらない。
- **②**: ★2026-09-09 12:41、将軍は①の redo1 実測(確認モーダル中は
  `waiting`/`waitingFor="permission prompt"` を申告し `idle` を申告しない・
  4状態反例0)を根拠に、cmd_754 E-1 の安全集合を「空」から
  **「一命令・二条件」へ一点だけ開ける**裁定を下した。
  実装は `lib/clear_send_gate.sh`(**§7.3 が正本**)。
  ★★開いたのは `/clear` **ただ一つ**であり(★redo1 で **claude のみ**へ
  閉じた。他の CLI は権威的な状態源を pane 実体へ束縛できぬゆえ人経路のまま
  であり、`/new` は送らない)、
  **nudge(裸の Enter)は永久に不許可**、`model_switch`/`cli_restart` は
  引き続き人手経路のままである。
  ★★**`idle`は安全な入力受領の十分条件ではない。①が実証したのは
  『試した確認モーダルが`idle`から排除される』ことのみである。**
  その誤読への保険が条件2(画面での**危険の否認**。★**安全の証明ではない**)
  である。
  ★**gate は実装・試験済みだが `inbox_watcher.sh` へは結線していない**。
  ゆえに下表「`clear_command` の自動 `/clear`」「task_assigned 前の
  context reset」の代替は、**結線が済むまで「人」のままである**(§7.3)。
- **③**: クロスセッション通知(`SendMessage`/`ListAgents`相当の mesh 機構)
  を `inboxN` 打鍵の後継として使えるかの検証。★2026-09-09時点で未着手
  (家老への割当・実施記録を確認したが見つからず)。

★★いずれの結果になっても、本表(nudge 行・context reset 行とも代替は
「Stop hookの窓の内側 or 人」のまま)は cmd_757 が完了し軍師QCを通るまで
現状維持とする。①③の結果が出た時点でこの節と上表を更新すること。

---

## 7. 打鍵が残っている場所(3箇所)

**人手起動の打鍵**が2箇所(7.1・7.2)、**三重条件つきの限定自動打鍵**が
1箇所(7.3・cmd_757②で新設)である。

### 7.1 `scripts/switch_cli.sh` — `--human-initiated` 必須

`--human-initiated` を明示しない限り**1打鍵も送らない**。この旗は「人が今この
切替を命じ、当該 pane を見ている」ことの表明であり、自動経路(inbox_watcher の
`cli_restart` 等)は**決して付けない**(そもそも inbox_watcher は switch_cli.sh を
起動しない)。

新CLI起動の打鍵は、さらに **pane の前景プロセスが素のシェルであること** を
確かめてから送る(`pane_is_bare_shell`)。`/exit` が効かず CLI が生きていれば
送らない。

★残余リスク: 人が旗を付けたその瞬間に pane がモーダルを出していれば、`/exit` の
Enter がそれを答え得る。旗はこの危険を消さず、**責任の所在を人へ移す**だけである。

### 7.2 `shutsujin_departure.sh` — 出陣時の CLI 起動打鍵 (裁定 E-5)

裁定 E-5 は「agent がまだ動いていない pane への送信を廃止対象に含めるか」を
実装者の判断に委ねた。**判断は「残す(ただし条件付き)」である。**

**残す理由**:

1. **誤爆の形が成立しない。** 事故とは「TUI が出したモーダルの既定選択肢を
   Enter が押す」ことであった。CLI が動いていない pane に TUI は無く、
   モーダルも既定選択肢も存在しない。
2. **廃せば得られる安全が無く、失うものだけが確実である。** 人が 10 個の pane へ
   手ずから CLI 起動コマンドを打ち込むことになる。
3. 将軍の既定「agent CLI が動いている pane へは送らない」を、そのまま満たす。

**付した条件**: 出陣は既存セッションを使い回すため、**既に agent が稼働している
pane へ起動コマンドを打ち込む経路が実在した**。これは E-1 が廃した当のものである。
よって打鍵の直前に pane の**前景プロセスが素のシェルであること**を確かめる。
送らなかった pane は記録し、出陣の最後に人へ報せる。

★残余リスク: 素のシェルであっても、人がその prompt で何かを打っている最中なら
混ざる。出陣は人が自ら叩く起動手順ゆえ、その人が居合わせている前提を置く。

### 7.3 `lib/clear_send_gate.sh` — `/clear`(★claude のみ)の三重条件つき限定自動打鍵 (cmd_757②)

★**redo1 (2026-09-09)**: 軍師 QC の差戻し(未収載モーダルの偽安全・
CLI/pane 未束縛・scope gate の未到達・家老への自己通知)を受け、本節の
記述も併せて是正した。変更点は 4 つである — (1) 条件2 を**許可リスト型**へ
転換 (2) 許可する CLI を **claude ただ一つ**へ閉じ、pane 実体との束縛を課す
(3) `inbox_type` を送信口の**必須入力**とする (4) 未知状態通知の宛先を
**家老・将軍のときは軍師+ntfy へ分岐**する。

**実装**: `lib/clear_send_gate.sh`(判定と送信の本体)・
`scripts/send_clear_gated.sh`(唯一の入口)・
`tests/unit/test_clear_send_gate.bats`(単体試験)。

#### これは cmd_754 の破棄ではない

cmd_754 E-1(自動打鍵の安全集合を空にせよ)は**生きている**。
`lib/pane_preflight.sh` の `preflight_safe_state_count` は今も `0` を返し、
`pane_send_preflight` は今も常に送信禁止を返す(1文字も変えていない)。
`scripts/inbox_watcher.sh` は今も `tmux send-keys` を1つも持たない。

本節が記すのは、その**空集合の上に積まれた「一命令・二条件」の限定例外**で
ある。土台を削るのではなく、上に積む。gate を通らなかったものは cmd_754 の
世界のまま人経路(家老 inbox → dashboard 🚨要対応)へ倒れる。

#### なぜ一点だけ開いたか

cmd_754 の裁定理由は「**画面から打鍵の安全は証明できない**」であった。
cmd_757①(隔離環境での実測・2026-09-09)がその前提を**部分的に**覆した。
画面ではなく**セッション自身の申告**(`~/.claude/sessions/<pid>.json` の
`status` / `waitingFor`)を読む経路が存在し、確認モーダル表示中のセッションは
`waiting` / `waitingFor="permission prompt"` と申告し、**`idle` とは申告しない**。

- `waiting`/"permission prompt" を採れたモーダル … 計7回(パーミッション確認5・plan承認2)
- 信頼ダイアログ2回 … **申告ファイルそのものが書かれず** mesh に載らなかった。
  これは「idle と申告した」のではなく「何も申告しなかった」である。
  ゆえに実装は**mesh 不在を危険側(不許可)**として扱う。
- モーダル中に `idle` と申告した例 … **0件(反例0)**

将軍はこれを根拠に、E-1 の安全集合を「空」から「一命令・二条件」へ
**一点だけ**開ける裁定を下した(2026-09-09 12:41)。

#### ★★この実装が証明していないこと(誤読防止・最重要)

> **`idle`は安全な入力受領の十分条件ではない。①が実証したのは『試した確認モーダルが`idle`から排除される』ことのみである。**

①が示したのは「モーダル中は `idle` と申告しない」という**排除**である。
「`idle` と申告しているなら入力を安全に受け取れる」という**含意は証明されて
いない**。方向が逆であり、①はそちらを一度も示していない。

反証すら手元にある。①の実測で、Claude Code は起動 1.1〜1.4 秒後、
**TUI の初期化中に既に `idle` を申告していた**。この時点で打鍵が正しく届く
保証は無い。**`idle` は「受け取れる」を意味しない。**

**ゆえに「idle なら何でも送ってよい」と読んではならない。
その誤読に対する保険が条件2 である。**

#### 三条件

| 条件 | 内容 | 実装 |
|------|------|------|
| 条件1 | mesh(セッション自身の申告)が `idle` であること | `gate_condition1_self_reports_idle` |
| 条件2 | 画面に危険が**見えず**、かつ**唯一許可された既知の安全形**に一致すること | `gate_condition2_screen_is_known_safe_form` |
| 条件3 | 送るのは `/clear`(★claude のみ)**ただ一つ** | `gate_condition3_command_is_permitted` |

これに加えて **scope**(`inbox_type` が `clear_command` であること・
`gate_type_is_in_scope`)と **束縛(CLI)**(pane の実体が Claude CLI である
こと・`gate_cli_bound_to_pane`)、そして★redo2 で加えた
**束縛(agent_id)**(呼出側の `agent_id` が対象 pane の `@agent_id` と完全
一致すること・`gate_agent_id_bound_to_pane`)を課す。
★★さらに redo2 以降、宛先は入口で**一度だけ** canonical pane_id(`%N`)へ
解決され、以後の検査も打鍵も**その不変 ID しか使わない**(後述「宛先の固定」)。

三つ全てを満たしたときに限り、`gate_send_context_reset` が**1回だけ**打鍵する。
1つでも欠ければ送らない。

条件1 は申告を読むだけでなく、**同定・生存・束縛・滞留**も併せて検査する:
mesh 記録がその pane に**ちょうど1つ**束縛されること / `pid` が生きていること
(`kill -0` は CLAUDE.md D006 の Signal-0 exclusion により signal ではない) /
`procStart` が `/proc/<pid>/stat` と一致すること(**pid 再利用対策**) /
`idle` になってから既定 3 秒以上経っていること。
**セッション名で束縛してはならない** — ①で衝突を実測した(probe の
`shogun-23` が稼働中の足軽3号と同名であった。名は cwd 由来の短ハッシュゆえ
衝突する)。

#### ★条件2 は「危険の否認」と「既知の安全形への一致」の二段である(どちらも「安全の証明」ではない)

cmd_754 が禁じたのは「画面状態から**安全を推論**すること」である。
条件2 はそれをしない。条件2 がするのは次の二段だけである:

1. **危険の否認** — 画面に危険が見えたら、送らない
   (`_GATE_MODAL_VETO_PATTERNS`。危険パターンの列挙であり、拒否側にしか
   効かぬゆえ足すのは自由・減らすな)
2. **許可リスト** — 画面が**唯一許可された既知の安全形**に一致しなければ、
   送らない (`_GATE_SCREEN_ALLOWED_FORMS`)

- 危険が見えた → **不許可**(拒否権の行使)
- 既知の安全形に一致しない → **不許可**(★未知は危険側へ倒す)
- 既知の安全形に一致した → **何も証明しない。許可も出さない。**
  ただ「拒否権を行使しなかった」だけである
- 画面が読めなかった / 空だった → **不許可**(否認の材料が無いのだから
  fail-closed で倒す)

★**「既知の安全形への一致」は「安全の証明」ではない。** この違いが本 gate の
要である:

- 「安全の証明」…… 目の前の画面 X を見て「X は安全だ」と**結論する**。
  4世代にわたり4度とも破れた問いであり、cmd_754 が禁じたもの。実装はこれを
  **一度も行わない**
- 「既知の安全形への一致」…… **先に決めた**唯一の形 F と画面 X を突き合わせ、
  **一致しなければ拒む**。一致しても「X は安全だ」とは**結論しない**。
  許可を出すのは条件1(本人の申告)と条件3(命令の限定)であり、条件2 は
  **拒否側にしか効かない**

**拒否権は保守側(送らない方向)にしか動かない。** ゆえに cmd_754 の禁止には
**抵触しない**。実装上も、`gate_condition2_screen_is_known_safe_form` の `rc=0` は
**単独では何の許可も生まない**構造にしてある。

★**なぜ redo1 で許可リスト型へ転換したか(軍師 QC の差戻し理由1)**:
初版の条件2 は**危険パターンの有限列挙(blacklist)**であり、どのパターンにも
一致しない**非空画面を無条件に通していた**。軍師の probe が未収載のモーダル
(`Permission required / Approve access / Cancel`)を画面へ置いたところ、初版は
実際に `tmux send-keys` まで到達した。「未収載のモーダルも条件1 が `waiting`
として弾く」という初版の弁明は、①が**試した3種**について成立した事実を
**全モーダルへ不当に一般化**したものであり、①自身の限定(「3種のみ・網羅せず」
・R-6)と矛盾していた。これは画面から安全を推論する4度破れた問いの再発である。
ゆえに**未知の画面は全て拒む**形へ転換した。

**現在の許可形は1つだけである** — 「空のプロンプト行のみ」(行頭の空白を除けば
`>` ただ1文字で、他に何も表示されていない画面)。
**増やすには (1) 隔離 tmux での実測 (2) 危険な画面と構造的に区別できることの
提示 (3) 将軍・軍師の gate、の三つを要する。**
「実運用の画面が通らないから」は理由にならない(R-9)。

#### ★fail-closed 要件(将軍が「最も重要な歯止め」と明言した部分)

1. **状態語彙は我らの管理下にない。** Claude Code の更新で語は増えうる。
   `idle` 以外の一切 — `waiting` / `busy` / `shell` / **未知の語** /
   **取得失敗** — は全て**送らない**。
2. **判定は「idle である」を確認する肯定形で書く。**
   「idle でない」という否定形で書いてはならない。否定形にすると
   **未知の状態語がすり抜けて通ってしまう**。

   ```
   誤: if [ "$st" != "idle" ]; then return 1; fi      # 未知語が通る
   正: if [ "$st" = "idle" ]; then ...; fi; return 1  # 未知語は落ちる
   ```

   実装の判定は全て後者の形で書いてある。単体試験 T-CG-014(未知語7種が
   全て不許可)と T-CG-023(実コードに否定形 `!= "idle"` が無いことの静的検査)
   がこれを守る。
3. **未知の状態語を観測したら記録し、人経路へ上げる。**
   記録先は `logs/clear_send_gate_unknown_state.log`。★通知先は一律ではなく、
   **下記「未知状態通知の宛先」の分岐表が正本**である(家老・将軍が対象なら
   軍師 inbox + ntfy、それ以外は家老 inbox → dashboard 🚨要対応)。
   ★redo2 以降、この分岐に使う agent の識別は**呼出側の申告ではなく
   pane の実体(tmux の `@agent_id`)から採る**。
   **この経路を「安全集合を広げる」方向に使ってはならない。** 未知語を見た
   ときに実装がすることは (a) 送らない (b) 記録する (c) 人へ知らせる の
   三つだけである。

#### ★CLI と pane の束縛(redo1・差戻し理由2)

条件1 の権威源は `~/.claude/sessions`(**Claude 自身の申告**)であり、
Codex/OpenCode/Copilot/Kimi はこの記録を書かない(R-5)。初版の送信口は
**呼出側が渡す `cli` 文字列を実 pane の CLI と照合せず**、その値だけで
`/clear` か `/new` かを選んでいた。ゆえに Claude の記録で認証された pane へ
`cli=codex` を渡せば `/new` を送れてしまった(pane の実体とは無関係に)。
**実体と束縛されない自己申告を許可根拠にしてはならない。**

redo1 で次のとおり閉じた:

- `gate_reset_command_for_cli` は **claude → `/clear` のみ**。他の CLI は
  綴りを持たない(rc=1)。`/new` は送らない
- `gate_cli_bound_to_pane <pane> <cli> <pid>` が、条件1 が認証した pid に
  ついて **(a)** `cli` が `claude` ちょうど **(b)** その pid の `argv[0]` の
  basename が `claude` ちょうど(**カーネル /proc の事実**) **(c)** その pid が
  当該 pane の `pane_pid` そのものかその子孫(**tmux の事実**)、の三点を
  全て確かめる。1つでも読めなければ不許可
- 送信口はこの束縛を**本判定と打鍵直前の再読の二度**課す

#### ★scope の強制(redo1・差戻し理由3)

`gate_type_is_in_scope`(`clear_command` のみを許す)は、初版では**定義と
単体試験にしか現れず**、実送信関数も wrapper も `inbox_type` を引数に
取っていなかった。誤配線すれば `model_switch` 等の処理から wrapper を
呼んでも reset が送られる状態であり、既存試験は**未到達 helper だけを
検査する偽緑**であった。

redo1 で `inbox_type` を **production entry の必須入力**とした:

```
gate_send_context_reset <pane_target> <cli> <inbox_type> <agent_id>
bash scripts/send_clear_gated.sh <pane_target> <cli> <inbox_type> <agent_id>
```

★redo2 で `agent_id` も**必須引数**とした(次節)。4引数すべてが要る。

未指定は不許可(`denied_scope_inbox_type_unset`)、`clear_command` 以外も
不許可(`denied_scope`)であり、**冒頭と送信直前の二度**、完全一致を課す。

#### ★未知状態通知の宛先(redo1・差戻し理由4)

未知の状態語を観測したときの通知は、初版では `agent_id` によらず**常に家老
inbox** へ送っていた。対象が家老自身の場合、それは**停止中の本人への自己
通知**であり dashboard/殿へ到達しない。redo1 で既存 delivery contract
(`scripts/inbox_watcher.sh` の `delivery_alert_target` /
`delivery_needs_human_channel`)と同じ形へ分岐させた:

| 対象 agent | inbox 宛先 | ntfy |
|-----------|-----------|------|
| 家老 (karo) | 軍師 (`gate_unknown_state_target` → gunshi) | ★鳴らす |
| 将軍 (shogun) | 軍師 | ★鳴らす |
| その他 | 家老 | 鳴らさぬ |

#### ★宛先の固定 — canonical pane_id(redo2・差戻し理由1)

`session:window.pane_index` 形式は **tmux における不変の identity ではない**。
redo1 の実装は、条件1 の同定・CLI 束縛・画面 capture をこの index 文字列で
行い、**最終送信でも同じ文字列を tmux へ再度渡していた**。

軍師が隔離環境で検証したところ、**第一 pane が終了すると同じ index 文字列が
別の新しい pane(`pane_id` が異なる)へ再解決される**ことが実証された。
すなわち、検査した時点と `send-keys` が走る時点の間に pane が終了・再配置
されると、**検査していない別 pane へ `/clear` + Enter が着弾しうる**。

redo2 で次のとおり塞いだ:

- `_gate_canonical_pane_id <pane_target>` が入口で**一度だけ** canonical
  pane_id(`%N`)へ解決する。形の検査(`%` に続くのが数字だけ)も課し、
  読めない・形が違えば **`denied_pane_id_unresolvable` で送らない**
- 以後の**同定・`pane_pid` 検査・画面 capture・`send-keys` の全て**が
  この不変 ID だけを使う。`gate_send_context_reset` の中で
  `"$pane_target"` を渡すのは canonical 解決の**ただ一箇所**である
  (静的検査 T-CG-072 が固定する)
- tmux の `pane_id` は**再利用されない**。検査した pane が既に終了して
  いれば、以後の `display-message` は**空を返し**(下記のとおり rc は 0
  である)、`capture-pane` / `send-keys` は rc=1 で落ちる。いずれの経路も
  gate は fail-closed で倒れる。**別 pane へ着弾する経路が構造として
  無くなる**
- 確定した ID は `GATE_PANE_ID` に残り、wrapper のログにも出る

回帰試験: T-CG-070(index 再束縛を模擬 — canonical 解決の直後に index が
別 pane `%77` を指すようになる状況で、打鍵が `%9` へ**ちょうど1回**行われ
`%77` へは**1度も**行かないこと)/ T-CG-071(解決不能・形不正なら送らない)
/ T-CG-072(静的検査)。

隔離tmux での実機証跡: `tests/verify_cmd_757_pane_rebind_isolated.sh`
(専用ソケット・PASS=19/FAIL=0)。第一 pane を `exit` で自然終了させると
同じ index 文字列 `verify:w0.0` が `%0` から `%1` へ再解決され、index 経由で
読める `@agent_id` まで入れ替わることを実測した。

★★そこで判明した重要な性質(fail-closed 設計の前提):
`tmux display-message -t <消滅した %N>` は **rc=0 を返し、stdout も stderr も
空である**。別 pane へ再解決されることは無いが、**黙って 0 を返す**。ゆえに
**rc で判定してはならない** — `_gate_canonical_pane_id` が**出力の形**
(`%` + 数字)を検査しているのはこのためである。なお `capture-pane` /
`send-keys` の方は消滅した pane に対し rc=1 で落ちる。

#### ★agent_id の必須化と実体束縛(redo2・差戻し理由2)

redo1 の `agent_id` は**既定値つきの任意引数**であり、`send_clear_gated.sh`
も3引数だけを必須としていた。一方、未知状態通知の宛先分岐は pane の実体では
なく**呼出側が渡す agent_id だけ**を見ていた。

ゆえに**家老 pane を対象に3引数の正規 usage で呼ぶと** agent_id が既定値と
なり、`gate_unknown_state_target` は**家老へ分岐**した — redo1 が直したはずの
「家老自身への自己通知」が、production entry の**許された呼び方**で再現して
いた。

redo2 で次のとおり塞いだ:

- `agent_id` を**必須引数**とした。lib(`gate_send_context_reset`)・
  wrapper(`send_clear_gated.sh`)の双方で既定値を持たせない。
  未指定は `denied_agent_id_unset` / wrapper は引数不正(exit 2)
- `gate_agent_id_bound_to_pane <canonical_pane_id> <agent_id>` が、
  呼出側の申告を **tmux が pane に持たせている `@agent_id`**(CLAUDE.md の
  Session Start 手順が自己識別に使うのと同じ源)へ束縛する。
  **欠落・不一致は fail-closed で送らない**
- この束縛は**本判定と打鍵直前の再読の二度**課す
- 未知状態通知の宛先分岐も、**pane の実体から採った `@agent_id`**
  (`_gate_pane_agent_id`)で行う。呼出側の申告に委ねない

回帰試験: T-CG-073〜T-CG-078(未指定・pane 側欠落・不一致・wrapper の
引数不正・実体からの分岐・再読での再確認)。

#### ★旧 blacklist 一般化の除去(redo2・差戻し理由3)

redo1 は条件2 を許可リスト型へ転換したが、`lib/clear_send_gate.sh` の veto
表のコメントには**初版(blacklist 型)の危険な一般化がそのまま残存**し、
直後の許可リスト実装と正面衝突していた。tests 冒頭は `/new` も送り得るように
読め、本書の fail-closed 要件3 は未知語通知先を一律「家老」と記して分岐表と
矛盾していた。**将来の保守者を再び blacklist 型へ導く記述**であり、単なる
文飾の問題ではない。

redo2 で lib / tests / docs から除去し、**負の静的試験 T-CG-066** が
`tests/fixtures/cmd_757_redo2_banned_phrases.txt`(禁止文言の台帳)を
`grep -F -f` で突き合わせ、4ファイルいずれにも**0件**であることを固定する。

#### 対象外(cmd_754 のまま据え置き)

| 対象外のもの | 扱い |
|--------------|------|
| **nudge(裸の Enter・`inboxN` 打鍵)** | **永久に不許可。** 2026-09-08 に「削除する釦を押した」のは裸の Enter であった。起床は③(クロスセッション通知)が打鍵なしで代替する |
| `model_switch` / `cli_restart` | 引き続き人手経路。`scripts/switch_cli.sh <agent> --human-initiated ...` を人が実行する |
| モーダルへ自動で答える打鍵 | 禁止。`No` を送るのも禁止。答えるのは人である |
| 入力欄クリア `C-u` の自動送信 | 条件3 の許可集合に無い。ゆえに送らない(残存リスク R-2) |

#### 残存リスク(gate を入れても塞がらない穴)

| ID | 内容 |
|----|------|
| R-1 | **TOCTOU**: 申告はスナップショットである。`idle` を読んでから打鍵が着弾するまでにモーダルは上がりうる。**窓は狭まるが 0 にはならない。** 実装は (a) 打鍵直前の再読 (b) 滞留要求 (c) 条件2 の二重化 で窓を詰めるだけである |
| R-2 | **入力欄の中身を申告する field が無い。** 打ちかけの文字列が残っていても `idle` である。そこへ `/clear`+Enter を送れば残字と連結された何かが送信されうる。`C-u` で消す案は打鍵を増やす方向ゆえ採らない |
| R-3 | **ハングを見抜けない。** 申告を書くのは当のプロセス自身であり、固まれば記録は `idle` のまま古びる |
| R-4 | **受領の証明ではない。** 申告は「書いた時点の状態」であって「この打鍵を受け取った」ではない |
| R-5 | **Claude 系にしか効かない。** Codex/OpenCode/Copilot/Kimi はこの記録を書かないため条件1 で自動的に閉じる。正しい挙動だが、それらの CLI は人経路のままということでもある |
| R-6 | **モーダル網羅の未証明。** 3種・計9回で反例0だが全数ではない。★redo1 の隔離検証で4種目(起動時の「Use Fable 5.1 at high effort by default?」)を偶然観測し、これも `waiting`/"dialog open" と申告して条件1 で落ちた — **反例は今も0件だが、これは網羅の証明ではない** |
| R-7 | **非公開契約。** `~/.claude/sessions/*.json` のスキーマも `status` の値域も Claude Code の内部実装であり、版が上がれば黙って変わりうる(①の実測は v2.1.265 系)。**だからこその fail-closed 要件2・3 である** |
| R-8 | **宛先の取り違えは検出できない。** tmux の target 解決は寛容で、範囲外の pane 番号は丸められて別の既存 pane を指す(§7.1 の `pane_is_bare_shell` が実測した性質と同じ)。★**`session:window.index` 形式は不変の identity ではない** — 軍師の隔離検証(redo2)で、第一 pane が終了すると同じ index 文字列が**別の新しい pane(pane_id が異なる)へ再解決される**ことが実証された。ゆえに index 形式を検査と打鍵の双方へ渡す実装は**検査していない pane へ着弾しうる**。★redo2 でこれを塞いだ(入口で canonical pane_id へ一度だけ解決し、以後は不変 ID のみを使う。下記「宛先の固定」)。また `agent_id` を pane の `@agent_id` へ束縛したため、誤った target は同じ `@agent_id` を持たぬ限り落ちる。★**それでもなお残るのが本項である**: 呼出側が誤った target と誤った agent_id を**揃えて**渡し、その pane が偶々 idle なら、そちらの context を消してしまう。三条件はどれも「その pane が安全か」を見るのであって「宛先として正しいか」を見ていない。**呼出側は自分が管理している pane にのみ使うこと。** mesh の `cwd` 突き合わせは、足軽の pane が全て同じ project を cwd とするため同一 project 内の取り違えを1つも塞がず、採らなかった |
| R-9 | **許可形が狭い。** 条件2 第二段が許すのは「空のプロンプト行のみ」ただ一形である。実運用の Claude Code の idle 画面(枠付きプロンプト・ヒント行・status 行を伴う)はこの形に**一致しない**ため、gate は**事実上ほとんど許可しない**。これは欠陥ではなく選択である — 許可しなかったものは cmd_754 の既定(人経路)へ倒れるだけであり、「届かぬ代償は遅延であり可視である。**見える失敗を選ぶ**」という将軍裁定に沿う |
| R-10 | **束縛は Claude にしか無い。** `gate_cli_bound_to_pane` が使えるのは Claude だけであり、他の CLI は権威的状態源を pane 実体へ束縛できぬゆえ開けられない。また `argv[0]` が `claude` 以外の綴り(node 経由の起動など)であれば、本物でも**不許可へ倒れる**(fail-closed 側の取りこぼしであり、意図している) |

#### ★現時点の結線状況(正直に書く)

**gate は実装され試験されているが、`scripts/inbox_watcher.sh` へは結線して
いない。** すなわち 2026-09-09 時点で、この経路が自動で走ることはまだ無い。
使うには `bash scripts/send_clear_gated.sh <pane> <cli> <inbox_type> <agent>`
を明示的に呼ぶ必要がある(★4引数すべてが必須。例:
`bash scripts/send_clear_gated.sh multiagent:0.7 claude clear_command ashigaru7`)。

結線するか否かは cmd_757② の範囲外である。結線は
`tests/unit/test_send_keys_preflight.bats` の T-PF-020 / T-PF-024
(「inbox_watcher は打鍵を持たない」「`send_context_reset` は打鍵せず rc=1」)
という cmd_754 由来の契約に触れるため、**将軍・軍師の gate を通してから
行うこと**。本節の表(§6・§0)も、結線が済むまでは「人経路」のままである。

---

## 8. 「画面を読む」ことについて — 二つの問いを混同するな

本 cmd が棄却したのは次の問いである。

> ✗ 「動いている CLI の中で、この打鍵はどの要素へ届くか」
> → 描かれた画面からは原理的に答えられない。**ゆえに常に禁止。**

`pane_is_bare_shell` が答えるのは別の問いである。

> ○ 「この pane で、そもそも CLI が動いているか」
> → tmux の `#{pane_current_command}` は pane の tty の**前景プロセス**であり、
>   描画物ではなく OS の職制御(job control)が持つ事実である。答えが `bash` 等の
>   素のシェルなら、TUI は存在せず、したがってモーダルも既定選択肢も存在しない。

この第二の問いを使ってよいのは、**これから CLI を起動しようとしている場面**
(出陣・人手による CLI 切替)だけである。**メッセージ配送には決して用いない。**

`lib/pane_preflight.sh` は `tmux capture-pane` を**一度も呼ばない**。呼ぶ必要が
生じたと感じたら、それは安全集合を広げようとしている合図である。

---

## 9. 後続 cmd 候補(本 cmd では作らない)

軍師が挙げた第2案 — **同一 agent process が nonce/世代を発行して受領を権威的に
証明する out-of-band ready handshake** — は設計として筋が良い。しかし本 cmd では
作らない。別 cmd とし、実装前に軍師・将軍の gate を通すこと。

本書 §3 が示した「Stop hook の55秒窓」は、その handshake が解き得る当の問題で
ある。長く待機している Claude agent への配送は、現状 **人経路のみ**である。

---

## 10. 関連ファイル

| ファイル | 役割 |
|----------|------|
| `lib/pane_preflight.sh` | 安全集合が空であることの表明 + `pane_is_bare_shell` |
| `scripts/inbox_watcher.sh` | 配送経路の判定と人経路への escalation(★`tmux send-keys` を1つも持たない) |
| `scripts/stop_hook_inbox.sh` | Claude の Stop hook(打鍵ゼロの配送) |
| `scripts/switch_cli.sh` | 人手起動の CLI 切替(`--human-initiated` 必須) |
| `shutsujin_departure.sh` | 出陣時の CLI 起動打鍵(素のシェル限定) |
| `scripts/ratelimit_check.sh` | `/status` 注入を廃止(受動的な capture のみ) |
| `tests/unit/test_send_keys_preflight.bats` | 自動打鍵が存在しないことの検査 |
| `tests/unit/test_send_wakeup.bats` | 配送経路判定と人経路の検査 |
| `tests/unit/test_switch_cli_preflight.bats` | 人手起動 gate の検査 |
| `tests/unit/test_shutsujin_launch_guard.bats` | 出陣ガードの検査 |
| `tests/verify_cmd_754_isolated.sh` | 隔離tmuxでの実挙動検証(bats ではない。手で実行する) |
| `lib/clear_send_gate.sh` | ★`/clear`(claude のみ)の限定送信 gate(§7.3 が正本) |
| `scripts/send_clear_gated.sh` | 上記 gate の唯一の入口(★4引数すべて必須) |
| `tests/unit/test_clear_send_gate.bats` | gate の単体・静的試験(T-CG-001〜T-CG-078) |
| `tests/fixtures/cmd_757_redo2_banned_phrases.txt` | ★負の静的試験 T-CG-066 の禁止文言台帳 |
| `tests/verify_cmd_757_pane_rebind_isolated.sh` | ★pane index 再束縛の隔離tmux実測(bats ではない。手で実行する) |

---

> **★追記(2026-09-10・cmd_759)**: 以下は本書の主題(自動打鍵の配送経路)とは
> 別の問い——「出陣直後、claude pane は mesh(ListAgents/SendMessage の peer
> 登録)へいつ現れるか」——に対する追記である。上記本文(§0〜§10)は書き換えて
> いない。

## 11. mesh登録のタイミング(cmd_759 追記)

> **★時点注記(2026-09-29・cmd_784)**: 本節 §11.1〜§11.4 が socket の置場を
> `/tmp/cc-socks-1000/` と書くのは、2026-09-10 当時の実測に基づく記述である。
> 置場は固定パスではない。現行の規則と、2026-09-29 に起きた断絶の経緯は
> §11.6 を見よ。

### 11.1 背景

将軍が実測した以下の食い違いの真因調査を cmd_759 A-3' が求めた:

| 起動 | mesh socket(`/tmp/cc-socks-1000/`) | ListAgents |
|---|---|---|
| 10:35 一斉起動(家老・足軽3〜7) | 0個 | 載らず |
| 11:08 足軽7号 単独再起動 | 81682.sock 有 | tmux 直結 peer として載る |

### 11.2 実測(2026-09-10・足軽6号・read-onlyのみ)

- `/tmp/cc-socks-1000` の birth time は `stat` で **2026-09-10T11:07:55+09:00**
  であった。これは将軍の「11:08 足軽7号単独再起動」とほぼ同時刻であり、
  ★このディレクトリはそれ以前には存在していなかったことを示す(少なくとも
  直近の /tmp クリア以降、一度も mesh 登録が行われていなかった)。
- `uptime -s` によるこのセッションの起動時刻は **2026-09-10T10:51:21+09:00**
  であり、将軍報告の「10:35」より後である。10:35 の一斉起動と 11:08 の
  単独再起動の間で、環境が少なくとも一度リセットされた(WSL2 再起動等)
  可能性が高い。
- ★★重要な副次的発見: 調査時点で稼働していた claude 7セッション全てにおいて、
  ソケットファイルの ctime(`stat`)が、そのソケットを保有するプロセスの
  起動時刻(`ps -o lstart`)より **一律 約17分 早い**という、7件全てに共通する
  一定オフセットを確認した。個々のプロセスごとにばらつく測定誤差ではなく
  全件一致する定数ずれであることから、これは「登録が起動より17分早い」の
  ではなく、`stat` と `ps` が参照する時刻源そのものが約17分食い違っている
  (例: WSL2 のクロックが何らかの理由でステップした)ことを疑わせる。
  ★この原因そのものは本調査では確定できていない(推測に留める)。
  ★実務上の含意: 本環境では `stat` の時刻と `ps` の時刻を跨いだ絶対時刻の
  比較・時間差の算出は信頼できない。起動順の判定は本ファイルのように
  PID の直接照合(親子関係)で行い、時刻の絶対値には依存しないこと。
- `ss -xlp` で、上記7個のソケット全てが「ファイル名と同じ PID の
  プロセスが現在も LISTEN で保持している」ことを確認した(古い PID 使い回し
  による見せかけの一致ではなく、実際に生きているプロセスの登録である)。

### 11.3 verified / hypothesis / unknown / mitigation の分離(redo1で是正)

★**redo1(2026-09-10・cmd_759 redo1)**: 初版はここを「結論(真因)」として
断定していたが、軍師QCにより、提示した証拠からはそこまで導けないと
指摘された(G759-RCA-EVIDENCE-04)。以下、検証済み観測・仮説・未確定事項・
緩和策を明確に分離して記す。**「証明済みの根本原因修正」とは記さない。**

**verified observation(検証済み観測)** — 11.2 で直接確認した事実のみ:

- `/tmp/cc-socks-1000` の birth time は `stat` 実測で
  2026-09-10T11:07:55+09:00 であった。
- 本セッションの `uptime -s` は 2026-09-10T10:51:21+09:00 であり、将軍が
  報告した「10:35 の一斉起動」はこの uptime 開始より**前**の時刻である。
- 調査時点で稼働していた claude 7 セッション全てで、ソケットファイルの
  ctime(`stat`)がそのソケットを保有するプロセスの起動時刻
  (`ps -o lstart`)より**一律 約17分早い**という、7件全てに共通する定数
  オフセットを確認した。
- 上記7ソケット全てについて、ファイル名と同じ PID のプロセスが現在も
  LISTEN で保持していることを `ss -xlp` で確認した(古い PID 使い回しに
  よる見せかけの一致ではない)。

**hypothesis(仮説・直接検証はしていない)**:

- mesh 登録は claude プロセスの spawn と同時には完了せず、何らかの遅延を
  伴って後から現れる、という説明。
- 10:35 時点で 0 個だったのは、「ディレクトリ作成と claude 起動の順序が
  競合した」という将軍の当初仮説よりも、「10:35 の一斉起動と 11:08 の
  単独再起動は別 boot にまたがっており、単純比較できない」という説明で
  足りる可能性がある。

**unknown(未確定・本調査では特定できなかった)**:

- ★10:35 の 0 件観測と 11:07:55 のディレクトリ birth time を同一時系列上で
  比較してよいかどうか。10:35 は uptime 開始(10:51)より前であり、少なくとも
  一度環境がリセットされた別 boot での出来事である可能性が高く、11:08 の
  観測と直接は比較できない。
- ★`stat` と `ps` の時計が約17分食い違っている原因(WSL2 のクロックが何らか
  の理由でステップした、等はいずれも推測に留まり、本調査では確定できて
  いない)。この食い違いにより、この環境で `stat`/`ps` を跨いだ絶対時刻の
  比較・時間差の算出は信頼できない。
- mesh 登録遅延の正確な契機(固定の内部遅延か、最初のターン開始等の
  アクティビティ起点か)。
- 「claude 起動 → socket 出現」を1つのプロセスについて直接・制御下で観測
  する実験(start してから socket が現れるまでの経過時間を計測する)は、
  本調査では行っていない。上記 hypothesis は、この直接観測なしに状況証拠
  (7件共通の時計オフセット・ディレクトリ birth time)のみから導いたもので
  あり、証明ではない。

**mitigation(緩和策・保証ではない)**:

- 11.4 節の対処(チェック位置を出陣シーケンス末尾へ送る)は、上記
  hypothesis が正しいという前提に立った**保守的な緩和策**であり、
  「証明済みの根本原因修正」ではない。hypothesis が誤っていた場合でも、
  対象peerへの不可逆な変更(自動リトライ・再起動)は一切行わない。
  ただし★誤検知時にも副作用は生じる——未登録検知時はstateへの永続
  書込みに加えKaro inboxへdelivery_alert通知を送るため、可視な
  alert/nudgeが発生する(詳細は11.4末尾を参照)。11.4 末尾に記すとおり、
  この設計は可視性を保証しない。

### 11.4 緩和策(実装・★保証ではない)

★redo1: 本節の対処は11.3の**hypothesis**(登録の完了には時間がかかる)が
正しいという前提に立った緩和策であり、**証明済みの根本原因修正ではない**。
このhypothesisの下で筋の良い対処は「もっと待つ」ことだが、cmd_759 は
固定 sleep によるポーリングループ化を明示的に禁じている
(CLAUDE.md Batch/Critical Thinking 系の教訓と同じ理由——広げた分だけ別の
過検出/過信を生む)。そこで **新たな待機は一切追加せず**、`shutsujin_departure.sh`
の中で mesh 登録チェック(`lib/mesh_registration_check.sh` の
`check_mesh_registration`)を実行する位置を、既存の処理が自然に消費する
時間の**最後尾**(STEP 6.9: 将軍起動確認の最大30秒待機 + 全エージェント分の
inbox_watcher 起動が完了した直後)まで送った。これにより、追加の待機
コードを1行も書かずに、最も遅く起動する pane(軍師)にも他の処理が動く
分の実時間が与えられる。

★★**meshの可視性は起動順に依存しうる**: 上記の設計でも保証にはならない。
一斉起動の中で最後に send-keys された pane は、チェック時点までに
経過した実時間が最も短く、まだ登録が完了していない可能性が他より高い。
ゆえに `check_mesh_registration` は未登録判定が出ても対象 pane を
**再起動しない**(peer再起動等の不可逆な副作用は起きない)。
`queue/state/mesh_registration_status.yaml` へ記録した上で、未登録が
1件以上あれば `shutsujin_mesh_check` が家老inboxへ `delivery_alert`
型の通知を送る(`scripts/inbox_write.sh` 経由・`target=karo`・
`from=shutsujin_departure`)。この通知は家老のInbox Processing
Protocolで処理され、dashboard.md🚨要対応への転記につながる可視な
経路である(dashboardそのものの更新は家老が担う別工程)。自動リトライ・
自動再起動は実装しておらず、誤検知時の代償はこの可視なalert/nudgeに
留まる。

★★**殿の Remote Control 接続で peer が見える経路とは別**である。本節が
扱う `/tmp/cc-socks-1000/` の mesh 登録は、ハーネス自身の
ListAgents/SendMessage 用 peer 登録であり、殿が Remote Control で
別セッションに接続した際に見える経路(§7 以前で扱う自動打鍵・Stop hook
の配送経路)とは異なる機構である。一方が見えても他方が見えるとは限らず、
逆も同様である。

### 11.5 関連ファイル(cmd_759 追加分)

| ファイル | 役割 |
|----------|------|
| `lib/mesh_registration_check.sh` | mesh登録(socket実在)のread-only確認(送信・再起動は一切行わない) |
| `tests/unit/test_mesh_registration_check.bats` | 上記の単体試験(pure logic + tmux非依存の合成ロジック検査) |
| `queue/state/mesh_registration_status.yaml` | 出陣ごとに上書きされる、未登録pane一覧のスナップショット(家老が確認する場所) |
| `shutsujin_departure.sh` (STEP 6.9) | 出陣シーケンス末尾での一回性チェック呼出し |

### 11.6 置場の不一致と runtime dir 撤去による断絶(cmd_784 追記・2026-09-29)

★時点注記: §11.1〜§11.4 の `/tmp/cc-socks-1000/` は 2026-09-10 当時の実測である。
本節はその後(2026-09-29)に起きた断絶と、Claude Code 本体の置場規則の実測を
追記する。§11.1〜§11.5 の本文は書き換えていない。

#### 11.6.1 事象(将軍実測・2026-09-29 19:07〜19:14・全て read-only)

| 時刻 | 事実 | 根拠 |
|---|---|---|
| 19:00 頃 | WSL 起動 | uptime(19:10 時点で up 9 min) |
| 19:06:49 | systemd が `user-runtime-dir@1000` を起動(`/run/user/1000` 作成)。logind「New session 1 of user <user>」 | `journalctl -b` |
| 19:07:24〜:30 | 出陣が agent を起動。tmux server と全 claude プロセスの環境に `XDG_RUNTIME_DIR=/run/user/1000/`(末尾スラッシュ付き) | `/proc/<pid>/environ` |
| 同 | 各 claude は `/run/user/1000/cc-socks/<pid>.sock` を bind | 将軍の子 shell の `CLAUDE_CODE_MESSAGING_SOCKET` |
| 19:07:29 | STEP 6.9 が旧置場 `/tmp/cc-socks-1000` を見て 7/7 未登録(★この時点では誤検知) | `queue/state/mesh_registration_status.yaml`・`lib/mesh_registration_check.sh` |
| 19:08:40 | `session-1.scope` 起動失敗(「PID 964 vanished before we could move it to target cgroup」等)→ logind「Removed session 1」 | `journalctl -b` |
| 19:08:50 | `user@1000.service`・`user-runtime-dir@1000.service` 停止 → `/run/user/1000` 撤去 | `journalctl -b`・`/run/user` の mtime |
| 19:10〜 | `ss -xlp` は 7 本の claude socket を旧パスで LISTEN と報告するが `/run/user/1000` は不在。将軍の ListAgents は「No reachable agents」。`loginctl list-sessions` は「No sessions」。`/var/lib/systemd/linger/` は空 | `ss`・`ls`・`loginctl` |

- 家老の cmd_783 通知が将軍へ届いたのは、撤去前に送信されたためと見られる。
  撤去後は同経路が 0 件となり、`instructions/common/protocol.md` の手順どおり
  「送らず終了」に落ちる。
- 断絶の影響: 家老→将軍通知(cmd_728)と権限要求の将軍判定(cmd_775)が
  次の出陣まで機能しない。dashboard 記載と殿の口頭中継で代替する。

#### 11.6.2 真因は二段

- **真因A(check側)**: `lib/mesh_registration_check.sh` の既定 dir が
  `/tmp/cc-socks-1000` 固定で、本体の置場規則と食い違っていた。19:07:29 の
  警報は、この時点では誤検知である。
- **真因B(環境側)**: WSL2 + systemd で、出陣を行ったログインセッションが
  直後に logind から外れ、`/run/user/1000` が撤去される。agent はその下に
  socket を張っていたため、パスが消えて誰からも接続できなくなった。★こちらは
  誤検知ではなく本物の断絶である。

将軍の裁定: 家老の見立て(19:07:29 時点は誤検知)は正しい。ただしその 80 秒後に
runtime dir 自体が撤去されて本物の断絶へ転じたため、是正 cmd を発令する。

#### 11.6.3 足軽の実測(cmd_784 Phase 1・Phase 2)

**(1) 予測式の食い違い**(足軽7号・本体 2.1.284・隔離した `claude -p` の子 4 条件):

| # | 子の環境 | bind した socket |
|---|---|---|
| T1 | `XDG_RUNTIME_DIR=<実在 dir>` | `<その dir>/cc-socks/<pid>.sock` |
| T2 | `XDG_RUNTIME_DIR`・`TMPDIR`・`CLAUDE_CODE_TMPDIR` いずれも無し | `/tmp/cc-socks/<pid>.sock`(★uid 無し) |
| T3 | `XDG_RUNTIME_DIR` 無し・`TMPDIR=<dir>` | `<TMPDIR>/cc-socks/<pid>.sock` |
| T4 | `XDG_RUNTIME_DIR=/run/user/1000/`(撤去済み) | `/tmp/cc-socks-1000/<pid>.sock`(一次置場を作れず退避) |

規則は「base = `XDG_RUNTIME_DIR` → `CLAUDE_CODE_TMPDIR` → `TMPDIR`(無ければ
`/tmp`)の最初の非空、socket は `<base>/cc-socks/<pid>.sock`。パスが103byteを
超える時、または一次 dir が拒否された時のみ `/tmp/cc-socks-<uid>/<pid>.sock`
へ退避」である。★cmd_784 起草時の前提「`XDG_RUNTIME_DIR` が無ければ
`/tmp/cc-socks-<uid>`」は、`/tmp/cc-socks-<uid>` が既定ではなく**退避先**である
点で実挙動と食い違っていた。

**(2) `messagingSocketPath` 方式**(足軽7号の発見・足軽4号が採用): 各 session は
`~/.claude/sessions/<pid>.json` に本体が**実際に bind したパス**を
`messagingSocketPath` として記録する。置場を環境変数から予測するより、この
記録を正とする方が確実である(`CLAUDE_CODE_TMPDIR`・`TMPDIR`・退避・103byte
超過のいずれも自動的に反映される)。`lib/mesh_registration_check.sh` の判定順は
次のとおり(足軽4号・Phase 1):

1. `MESH_SOCK_DIR` の明示上書き(最優先・従来どおり)
2. 対象 pid のセッション記録の `messagingSocketPath`(pid 一致・`procStart` と
   `/proc/<pid>/stat` の starttime の一致・絶対パス・basename が `<pid>.sock`、を
   全て満たす記録のみ有効)。★有効な記録があればそれを権威とし、そこに socket が
   無ければ未登録とする(runtime dir 撤去後の本物の断絶を予測式で隠さない)
3. 記録が使えない時のみ予測式(上記の規則。退避先 `/tmp/cc-socks-<uid>` も候補)

**(3) `XDG_RUNTIME_DIR` を外す対処**(足軽7号・Phase 2): `shutsujin_departure.sh` が
agent の tmux session 環境と各 pane の shell から `XDG_RUNTIME_DIR` を外す
(`tmux set-environment -t <session> -r XDG_RUNTIME_DIR`、および pane 初期化の
`unset XDG_RUNTIME_DIR;`)。以後その pane で起動する CLI は、本体の規則により
login session に依らぬ `/tmp/cc-socks/<pid>.sock` へ socket を張る。`/tmp` は
root fs 上にあり、logind の session 終了で消えない。global(`-g`)環境は
触らない。隔離 tmux での実測: 撤去済みの `XDG_RUNTIME_DIR` を継いだ server の
pane へ初期化コマンドを送ると、同 pane 内で起動した `claude -p` の子は
`/tmp/cc-socks/<pid>.sock` へ bind した。

- 採用: 候補 a1(pane 環境から `XDG_RUNTIME_DIR` を外す・OSS 側の
  `shutsujin_departure.sh`)。
- 却下: a2(自前の永続 dir を `XDG_RUNTIME_DIR` として与える。XDG 仕様の意味を
  偽る変数を他プログラムへ撒く点と、本体の「既定の置場」から外れる点)。
  b(`loginctl enable-linger`。本機固有の系設定の恒久変更で agent の権限外・
  利用者一般には効かない。a1 で断絶は止まるため不要だが、併用しても害は無い)。
  置場としての `boot_shogun_local.sh`(効くのは server を出陣がその場で起こした
  場合のみ・git 非追跡で OSS 利用者に届かない)。
- 設計の全文: `context/cmd_784_phase2_design.md`。

#### 11.6.4 ★未確認・留保(足軽7号の報告の留保をそのまま残す)

- 反映は**次の出陣から**である。稼働中の agent は `/run/user/1000/cc-socks/` に
  張ったままで、この対処では救えない。「出陣後は `/tmp/cc-socks/` に張る」は
  見込みであり、出陣やり直し後の実機では未確認である(cmd_784 AC⑤)。
- 殿が tmux の外で起動した session(`/run/user/1000/cc-socks/`)と agent 群
  (`/tmp/cc-socks/`)の跨ぎ送受信は、本体の「既定の置場での相手検証」経路で
  通る見込みだが、**実機では検証していない**(道具なしの `claude -p` では
  ListAgents を呼べないため)。
- 2026-08-31・09-10 の実測が `/tmp/cc-socks-1000` だった理由は**未確定**である
  (当時の `XDG_RUNTIME_DIR` が撤去済み dir を指して退避した形で説明はつくが、
  確定していない。本 cmd で確定は不要とされた)。
- 残余リスク: agent 配下のプログラムが `XDG_RUNTIME_DIR` を失う(Wayland・
  `systemctl --user`。本環境では撤去後は元々使えず実質の後退は無い)。
  `/tmp` の 30 日掃除(`tmp.conf`)で、出陣し直さず 30 日超稼働した場合は
  socket file が消され得る。`/tmp/cc-socks` は uid を含まぬ共有名で、他利用者が
  先に作れば本体は `/tmp/cc-socks-<uid>` へ退避する。
- 脅威モデル: 本対処が止めるのは「置場の不一致と runtime dir 撤去による意図せぬ
  断絶」のみである。同一ユーザーによる意図的な socket 削除・環境改竄・check の
  迂回は対象外である。
- 上の規則は本体 2.1.284 の実測であり、本体の更新で変わり得る。

#### 11.6.5 関連ファイル(cmd_784 追加分)

| ファイル | 役割 |
|----------|------|
| `lib/mesh_registration_check.sh` | 置場判定を「セッション記録 → 予測式」へ(Phase 1) |
| `tests/unit/test_mesh_registration_check.bats` | 上記の単体試験(Phase 1) |
| `shutsujin_departure.sh` | agent pane から `XDG_RUNTIME_DIR` を外す(Phase 2) |
| `tests/unit/test_shutsujin_runtime_dir.bats` | 上記の試験(Phase 2) |
| `context/cmd_784_phase2_design.md` | Phase 2 の設計・候補比較・隔離実測の記録 |
| `instructions/common/protocol.md` | 「socketの置場規則」節(現行規則の正本) |

---

> **★追記(2026-09-17・cmd_775 scope内・subtask_775_hook_cwd_fix)**: 以下は
> 本書の主題(自動打鍵の配送経路)とは別の問い——「hookのcommandは、agentの
> cwdがプロジェクト直下でない場合でも正しく起動するか」——に対する追記
> である。上記本文(§0〜§11)は書き換えていない。

## 12. hookコマンドは絶対パスで書け — cwd起動経路の欠陥 (cmd_775)

### 12.1 背景

2026-09-17、足軽3号がプロジェクト直下でない skill ディレクトリ
`skills/<skill>/` 配下(cwdがプロジェクト直下でない状態)で作業中に
確認モーダルで長時間停止した。将軍が特定した真因
(将軍裁定 `shogun_ruling_20260917_hook_cwd`・
`queue/shogun_to_karo.yaml` cmd_775):

- Claude Code の hook は「cwd follows Claude」(公式 hooks リファレンス
  原文)——hook の `command` は、hook を起動する agent の Bash tool の
  **現在の cwd** で実行される。セッション開始時に固定されるのではない。
- `.claude/settings.json` の3 hook(SessionStart・Stop・
  PermissionRequest)の `command` はいずれも相対パス
  (`bash scripts/<script>`)で書かれていた。
- 足軽3号のcwdが `skills/<skill>/`(プロジェクト直下でない skill
  ディレクトリ)のときは
  `scripts/permission_request_hook.sh` がそのcwdから見て存在しないため、
  hook 起動そのものが `bash: scripts/permission_request_hook.sh: No
  such file or directory` でサイレントに失敗した。
- ★これは hook スクリプト自身の中身(agent_id 解決・fail-closed ロジック
  等)の欠陥ではない——hook の**プロセスが一度も起動していない**。記録
  ファイルも家老 inbox 通知も一切発生せず、Claude Code は通常の確認
  モーダルへフォールバックする。この回は hook が起動していないため
  仕組みでは答えられず、殿が手で操作した。
- 足軽6号は同時刻 cwd=`<project-root>`(プロジェクト直下)だったため、
  同じ相対パス形式でも問題は起きなかった——このズレが、hook の中身では
  なく起動経路そのものに真因があることを裏付けた。
- ★同じ相対パスは SessionStart(`bash scripts/session_start_hook.sh`)・
  Stop(`bash scripts/stop_hook_inbox.sh`)にも存在しており、cd した
  agent ではこれらの hook も同様にサイレントに起動失敗しうる潜在バグ
  だった(Stop の場合、未読 inbox の拾い上げが黙って機能しなくなる)。

### 12.2 是正

家老が `.claude/settings.json` の3 hook すべての `command` を、Claude
Code 公式ドキュメントが推奨する形へ是正した:

```
bash "${CLAUDE_PROJECT_DIR}/scripts/<script>"
```

`${CLAUDE_PROJECT_DIR}` はセッション開始時の project root に固定される
公式提供の環境変数であり、agent の cwd が後から変わってもこの値自体は
変わらない。ゆえに常に正しく解決される絶対パスになる。shell form なので
引用符で囲むこと(公式推奨どおり)。

★**規則化**: `.claude/settings.json` の hook `command` を新設・変更する
際は、必ずこの絶対パス形式を使うこと。相対パス形式
(`bash scripts/<script>`)は、hook を起動する agent の cwd が project
root と異なる場合(例: `skills/` 配下での作業)に、hook 起動そのものが
エラー通知なくサイレントに失敗するという具体的な障害を生む。

### 12.3 隔離試験による実証

`tests/unit/test_hook_cwd_launch.bats`(T-HCWD-001〜006)が、
`scripts/isolated_tmux.sh` で作る隔離 tmux pane 上で cwd を `skills/`
相当の非プロジェクト直下ディレクトリへ変えた状態で、3 hook それぞれに
ついて「絶対パス化前の相対形式は起動失敗(rc=127・`No such file or
directory`)/絶対パス化後の形式は同条件で正常起動」を対比する形で実測・
固定化している(稼働中の本番 tmux ソケットには一切触れない・D006 遵守)。
`tests/unit/test_permission_request_hook_settings.bats`(T-PRHS-003)は
静的側から、`.claude/settings.json` の3 hook すべての command が絶対
パス形式であることを恒久的 regression guard として検査する(相対形式が
紛れ込んだら即座に検知する)。

★本節が扱う defect class(hook command の cwd 依存起動失敗)そのものは
tmux の有無に一切依存しない、純粋な bash/ファイルシステムの一般的事実
である。`test_hook_cwd_launch.bats` が隔離 tmux 実機上で試験している
のは、足軽3号の実際の事故環境(agent の Bash tool が動く、tmux pane 上
でホストされたシェル)への忠実性のためであり、tmux 自体が defect の
原因や修正に関与しているわけではない。

### 12.4 関連ファイル

| ファイル | 役割 |
|----------|------|
| `.claude/settings.json` | 3 hook(SessionStart/Stop/PermissionRequest)の command 定義(絶対パス形式) |
| `tests/unit/test_hook_cwd_launch.bats` | cwd 起動経路の動的隔離試験(相対失敗/絶対成功の対比・隔離tmux実機) |
| `tests/unit/test_permission_request_hook_settings.bats` | settings.json 側の静的 regression guard(T-PRHS-003) |
| `instructions/common/tooling_pitfalls.md` ⑨ | 同欠陥の再発防止ルール(全 agent 常時参照経路) |
