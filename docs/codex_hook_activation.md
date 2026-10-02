# Codex CLI hook 有効化手順・実機gate (cmd_757④redo1)

本書は cmd_757④(足軽6号・2026-09-09)の軍師QC(REDO_REQUIRED)で指摘された
問題2(G757-HOOK-INACTIVE-02)・問題3(G757-TRUST-SOT-03)への是正として作成した。
**本書に書かれた「有効化」自体は本redoでは実施していない**。実施可否は
家老・将軍の裁定を仰ぐ(下記「実施しないこと」参照)。

## 現状 (2026-09-09時点)

- 対象ファイル: `.codex/hooks.json.template`(track対象)→
  `scripts/generate_codex_hooks.sh` が実行時の絶対パスで展開した
  `.codex/hooks.json`(生成物・.gitignore対象)
- live `/home/kato/.codex/config.toml` には本 hooks.json に対応する
  `hooks.state` エントリが無い → **Installed=1 / Active=0**(未trust・完全に無効)
- 現時点で ashigaru1・ashigaru2・gunshi の Codex 版 Stop 配送・SessionStart
  persona 復旧は**動いていない**

## 問題3是正: trust 保存先の訂正事実 (G757-TRUST-SOT-03)

cmd_757④の初回報告は「trust状態は平文ファイルでは見当たらずsqlite内と推定」
としていたが、これは誤りである。★実測(隔離CODEX_HOME
`/tmp/tmp.aWzATSxSAy/config.toml` を本redoで直接再読して確認。軍師の独立検証
とも一致):

```toml
[hooks.state."/tmp/tmp.OvINhbNF2Q/.codex/hooks.json:session_start:0:0"]
trusted_hash = "sha256:f733e1de3815b863a644aa412db9209f6a2a652c3c6122ac090b0b1d87ded848"
```

- trust 状態は **CODEX_HOME の `config.toml` に平文の TOML テーブルとして
  永続化される**(sqlite ではない)。
- キーの形式は `"<hooks.jsonへの絶対パス>:<event_name(snake_case)>:0:0"` であり、
  **セッションIDを一切含まない**。従って trust は個々のセッションにではなく
  「(CODEX_HOME, hooks.json絶対パス, event, hook索引)の組」に紐づく。
- この鍵構造そのものが「同一 CODEX_HOME を共有するセッションはすべて同じ
  trust 状態を参照する」ことの直接的根拠であり、「各セッションごとに
  個別の trust 操作が必要」という結論は支持されない。実際、cmd_757④初回報告も
  「以後のセッション起動では再操作不要だった」と実機確認済みであり、本redoの
  鍵構造の再確認はこれと整合する(★訂正が要るのは保存先〈sqlite→config.toml
  平文〉のみであり、「session単位か否か」の結論自体は初回報告のとおりで正しい)。
- `trusted_hash` は hooks.json の該当 hook 定義の内容から算出されるハッシュと
  推測される(具体的なハッシュ対象の正確なシリアライズ形式・アルゴリズムは
  本redoでは特定できなかった — 単純な「ファイル全体のsha256」「hook定義
  オブジェクトのJSON(sorted/unsorted)」「commandフィールド単体」のいずれとも
  一致しなかった)。したがって **hooks.json の内容を変更すれば trusted_hash
  は再計算され、旧hashは失効する**(内容変更後は再trustが必要)という前提で
  運用すべきである。★非対話的にこのハッシュを事前計算して config.toml へ
  直接書き込む方法は本redoでは未解明であり、followup候補として残す
  (実施は下記「対話的手順」による)。

## 有効化手順 (対話的・危険な自動打鍵を使わない)

前提: 稼働中の ashigaru1・ashigaru2・gunshi の pane へは打鍵しない
(スコープ外)。以下は**家老または将軍が人手で**、いずれか1つの Codex pane
(または新規に起動する Codex セッション)で行う想定の手順である。

1. 対象 pane で Codex CLI のスラッシュコマンド `/hooks` を実行し、
   hook 管理パネルを開く。
2. パネルに `SessionStart` (command: `<PROJECT_ROOT>/scripts/codex_session_start_hook.sh`)
   と `Stop` (command: `<PROJECT_ROOT>/scripts/stop_hook_inbox.sh`) が
   `Installed` として一覧表示されることを確認する。
3. `t` (trust all) を入力し、明示的信頼を付与する。
4. 上記「問題3是正」の鍵構造により、**同一 CODEX_HOME を使う他の Codex pane
   も同じ config.toml を参照するため、原則として pane ごとに繰り返す必要は
   ない**。ただし既に起動済みで config.toml を起動時にしか読まない可能性の
   あるセッション(=ashigaru1・ashigaru2・gunshi が現在稼働中のセッションその
   もの)については、trust 付与後に「実機gate」で個別に有効化を確認し、
   反映されていなければそのセッションの再起動(新規 `codex` 起動。
   `kill` 系コマンドでの強制終了はD006により行わない。人手で `/exit` させた
   上での再起動、または次のセッション境界を待つ)が必要となる可能性がある。

## 有効化後の実機gate (何を確認すれば「有効化成功」と判定できるか)

以下をすべて満たして初めて「有効化成功」と判定する。いずれか1つでも
欠けば Active=0 のまま(=未trust扱い)として扱うこと。

1. **config.toml 実測**: 対象 CODEX_HOME の `config.toml` に
   `[hooks.state."<PROJECT_ROOT>/.codex/hooks.json:session_start:0:0"]` と
   `[hooks.state."<PROJECT_ROOT>/.codex/hooks.json:stop:0:0"]` の両エントリが
   存在し、`trusted_hash` が現在の `.codex/hooks.json` の内容に対応する値で
   ある(hooks.json を変更した後に古い hash のまま残っていないか要確認)。
2. **`/hooks` パネル実測**: 対象セッションで `/hooks` を開き、
   `SessionStart`・`Stop` の両方が `Active` 表示になっている。
3. **SessionStart 実発火確認(一次証跡必須・偽陽性排除)**
   (cmd_757④redo2, G757-CODEX-ACTIVATION-GATE-FALSE-POSITIVE-REDO1-02是正):
   ★Codex は hook が未trustのままでも `AGENTS.md` を自動ロードするため、
   「persona質問に正答した」だけでは hook が実発火したかを識別できない
   (偽陽性)。cmd_757④初回報告はこの正答のみを根拠としていた。
   - **一次証跡(必須。これが無い限り「発火」と判定しない)**: 対象セッションの
     `/new` 実行直前に `logs/session_start_hook.log` の行数(または最終行)を
     記録し、実行直後に同ログへ `<agent_id> session_start_hook fired
     (cli=codex)` という新規行が追記されていることを確認する。または
     rollout ログに hook 由来の `additionalContext` 挿入(`hookEventName:
     SessionStart` を伴う封筒)が記録されていることを確認する。
   - **補強情報(単独では証拠にならない)**: 「自己識別・役割・タスクYAMLパス」
     に関する質問をし、モデルが `instructions/generated/codex-{role}.md` に
     基づく正しい persona(Codex 正本の内容)で応答すること。誤って
     CLAUDE.md 由来の内容(`instructions/{role}.md`・`/clear` 前提)を
     引用した場合は失敗と判定する。★ただしこの応答確認は一次証跡と
     必ず併用すること。応答確認のみを根拠に「発火した」と判定してはならない。
4. **Stop 配送確認(旧watcherのinboxN打鍵との混同回避)**:
   対象 agent の inbox へ `read: false` のメッセージを1件仕込む。★投入は必ず
   `bash scripts/inbox_write.sh {agent_id} "<本文>" <type> <from>` 経由で行う
   (YAML を直接編集するな。全ての書き手が同じ flock を取らねば advisory lock は
   意味を持たない——cmd_695/cmd_741 の教訓)。その状態でターンを終了させ、`stop_hook_inbox.sh` と同型の
   block→再開ループが実機で発生することを確認する(cmd_757④初回報告 D-2 で
   確認済みの契約と同じ動作)。★ただし2026-09-09時点、`inbox_watcher.sh` の
   稼働中プロセスは cmd_754 の自動打鍵全廃を未反映のまま `inboxN` 打鍵を
   なお送り得る実機ギャップがある(`docs/delivery_channels.md` §1.1)ため、
   block→再開が「起きた」ことだけでは stop_hook_inbox.sh 由来か旧watcherの
   打鍵による偶然の再開かを区別できない。

   ★★一次証跡は次の(ア)★ただ一つである。(イ)は補強情報であり、★単独では
   hook 由来の根拠にならない。「(ア)または(イ)」としてはならない——★「他の
   原因が無い」は「これが起きた」の証明ではないからである。

   - **(ア) 一次証跡(必須)**: rollout ログに Stop イベント由来の `HookPrompt`
     挿入が記録されていること(`docs/delivery_channels.md` §4 の
     「JSON `additionalContext`注入・`HookPrompt`注入」契約)。★hook が発火した
     ことを**正の形で**示す唯一の証跡である。
   - **(イ) 補強情報(単独では不可)**: 同時刻帯の
     `logs/inbox_watcher_{agent_id}.log` に該当する `[SEND-KEYS] Sending nudge`
     行が**存在しない**こと。★これは代替原因(旧watcherの打鍵)を排除するだけで
     あり、★hook の発火を示さない。★存在した場合は(ア)の有無にかかわらず
     「旧watcher由来の可能性あり」と併記すること。
   ★stop_hook_inbox.sh 自体は現時点で自身の発火を記録する専用ログを
   持たない。★一次証跡(ア)が得られない場合は、★(イ)が満たされていても
   「Stop配送確認は未達」として報告し、有効化成功に含めないこと。
5. 上記1〜4のいずれかが未達の場合、または一部の pane でのみ達成した場合は
   「部分的有効化」として明示的に報告し、「有効化成功」と総称しないこと。

## 実施しないこと (本redoのスコープ外)

- 本redoでは上記手順を**実行していない**(live hookの実trustは行っていない)。
- 稼働中の ashigaru1・ashigaru2・gunshi の pane への打鍵による検証は行わない
  (cmd_757④redo1の禁止事項)。
- 実施可否・実施タイミングの決定は家老・将軍の裁定に委ねる。
