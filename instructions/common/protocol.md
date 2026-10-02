# Communication Protocol

## Mailbox System (inbox_write.sh)

Agent-to-agent communication uses file-based mailbox:

```bash
bash scripts/inbox_write.sh <target_agent> "<message>" <type> <from>
```

Examples:
```bash
# Shogun → Karo
bash scripts/inbox_write.sh karo "cmd_048を書いた。実行せよ。" cmd_new shogun

# Ashigaru → Karo
bash scripts/inbox_write.sh karo "足軽5号、任務完了。報告YAML確認されたし。" report_received ashigaru5

# Karo → Ashigaru
bash scripts/inbox_write.sh ashigaru3 "タスクYAMLを読んで作業開始せよ。" task_assigned karo
```

Delivery is handled by `inbox_watcher.sh` (infrastructure layer).
**Agents NEVER call tmux send-keys directly.**

## Delivery Mechanism (自動打鍵は有効)

Two layers:
1. **Message persistence**: `inbox_write.sh` writes to `queue/inbox/{agent}.yaml` with flock. Guaranteed.
2. **Wake-up signal**: `tmux send-keys` による自動打鍵(`inboxN` nudge等のCLI keystroke)は★実際に送信されている。inbox_watcher.shが各エージェントのpaneへ直接打鍵する経路であり、Claude系エージェントではこのnudgeとStop hook(ターン終了時に未読を拾う経路)が併存する。下表『実際の配送経路』列がclaude行を「Stop hookのみ」と記すのは、エスカレーション(後述)上カウントする確定経路がStop hookである、という意味であり、nudgeが存在しないという意味ではない——nudgeは即時性を狙うベストエフォート経路、Stop hookはターン終了時に必ず未読を拾う確定経路として、両方が有効である。
★対象paneに確認モーダル(破壊的操作の確認ダイアログ等)が表示されている間は、そのagent宛てに`inbox_write`しないこと。nudgeは対象paneの表示内容を見ずに`Enter`等を送るため、モーダルの既定選択肢(多くは`❯ 1. Yes`)を誤って押してしまう危険がある。2026-09-08、この経路でD002-E1違反の削除が実際に実行された(詳細は次項)。確認モーダルの有無に確信が持てないときは、解消を確認してから送ること。

★2026-09-08、`inbox_watcher` の nudge が送った Enter が確認モーダルの既定
選択肢 `❯ 1. Yes` を選び、D002-E1 違反の削除が実際に実行された。
「削除するな」という命令を届けたことが、削除する釦を押した。
以後4世代にわたり「画面から安全を証明する」試み(blocklist型 → marker片
認証 → 境界付きlayout認証 → cursor版有限allowlist)を重ねたが4度とも破れ、
将軍は一時★自動打鍵の安全集合を空とする裁定を下した。しかし2026-09-10、
cmd_760により復元され、nudgeは現在も有効である(詳細は
`docs/delivery_channels.md`)。

**CLI 別・実際に配送を担うもの** (「たぶん届く」と書かぬ):

| CLI      | Stop hook | agent self-watch | 実際の配送経路 |
|----------|-----------|------------------|----------------|
| claude   | ○ 実在    | ✕ 実在せぬ       | Stop hook のみ |
| codex    | ✕ 無い    | ✕ 実在せぬ       | ★無い → 人経路 |
| opencode | ✕ 無い    | ✕ 実在せぬ       | ★無い → 人経路 |
| copilot  | ✕ 無い    | ✕ 実在せぬ       | ★無い → 人経路 |
| kimi     | ✕ 無い    | ✕ 実在せぬ       | ★無い → 人経路 |

- **self-watch**: 2026-09-08 の実測では、`pgrep -f inotifywait` で見えていた
  プロセスは全て `inbox_watcher` 自身の監視ループの子であった。agent が自ら
  張る self-watch は★1本も存在しない。よって配送経路として数えない。
- **Stop hook** (`scripts/stop_hook_inbox.sh`): agent が★ターンを終える時に
  発火し、未読があれば stop を BLOCK して本人へ食わせる。未読が無ければ
  `inotifywait` で★最大55秒だけ待ち、その間の新着も同じく届ける。
  ★55秒の窓を過ぎて完全に idle になった後は、次のターン終了まで発火せぬ。
  すなわち★長く待機している Claude agent への新着は Stop hook でも届かぬ。
  これも人経路の対象である。
- 詳細は `docs/delivery_channels.md` を見よ。

**Agent reads the inbox file itself.** メッセージ本体が tmux を通ることは無い。

Special cases (`tmux send-keys` で送る CLI コマンド):
- `type: clear_command` / `type: model_switch` は★自動で送信される
  (`/clear`・`/model ...`としてpaneへ直接打鍵される)。
- `type: clear_command` を★軍師宛に送るときは時点が限られる。作業中の軍師へは
  送らない(下記「Redo Protocol」内「軍師宛 clear_command の規則」を見よ)。
- `type: cli_restart` のみ★自動では送らない。未読のまま保持し、人が
  何をすべきかを添えて人経路へ上げる。理由: `switch_cli.sh` 自身が課す
  `--human-initiated` 必須の制約(cmd_754将軍裁定E-1)は★cmd_754巻き戻し後も
  存続しており、自動経路からの委譲はcmd_760 A-4で撤去したため。
- CLI/モデルの切替(cli_restart)は人手で `bash scripts/switch_cli.sh <agent> --human-initiated ...`
  を実行する(`--human-initiated` 無しでは1打鍵も送らぬ)。

## Agent Self-Watch Phase Policy (cmd_107)

Phase 2 は「通常 nudge を busy 中のみ止める」、Phase 3 は「send-keys を
最終手段に限る」という、打鍵の量を加減する旗である。既定値は
`ASW_PHASE=2`であり、agentがbusyな間は通常nudgeを抑制してStop hook等の
確定経路に委ねるが、agentがidleなら通常nudgeは★実際に送信される。
`ASW_PHASE=3`まで上げれば`FINAL_ESCALATION_ONLY=1`となり通常nudge自体を
escalation経路のみに絞れるが、これは既定値ではない。

Read-cost controls:

- `summary-first` routing: unread_count fast-path before full inbox parsing.
- `no_idle_full_read`: timeout cycle with unread=0 must skip heavy read path.
- Metrics hooks are recorded: `unread_latency_sec`, `read_count`, `estimated_tokens`.

**Escalation** (段階はwatcherが実際に送る打鍵の強さを表す。家老inbox/ntfyへの自動アラート機構は無い):

| Elapsed | Action |
|---------|--------|
| 0〜2 min | 通常nudge(`inboxN`打鍵)。agentがbusy中はスキップし確定経路(Claude=Stop hook)に委ねる |
| 2〜4 min | Copilot・KimiはEscape×2+Ctrl-C+nudgeへ昇格。Claude・Codex・OpenCodeは(Escapeが処理中のturn・操作を妨げるため)通常nudgeへフォールバック |
| 4 min〜  | ★足軽(ashigaru)のみ`/clear`を送信。5分に1回まで。家老・軍師・将軍はここでも`/clear`を送らずEscape+nudgeへフォールバックする |

★「未配送が閾値超過で家老inbox(`delivery_alert`)/ntfyへ自動で上がる」経路はwatcherに無い(cmd_754で一時導入・cmd_760巻き戻しで消滅。時点注記は`docs/delivery_channels.md`)。上表はいずれもtmux send-keysによるベストエフォートの打鍵であり、届いた保証にはならない。家老・将軍自身が対象で人手を要する場合のntfyは、家老が判断して`scripts/ntfy.sh`を手動実行する人経路である(watcherの自動処理ではない)。

★足軽にとっての実務: 4分間未読のまま応答が無いと`/clear`が飛びcontextを失う(禁止ではなく事実)。対処として、長い作業中は未読を溜めず、作業に入る前にinboxを既読化しておくこと。

## Inbox Processing Protocol (karo/ashigaru/gunshi)

Inbox通知に気づいたとき(★`inboxN`打鍵は★実際に送信される。詳細は「Delivery Mechanism」節。それ以外の引き金として Claude=Stop hookの未読要約ブロック〈ターンが連続している窓の内側のみ〉、または全CLI共通で人経路〈dashboard 🚨要対応・家老inbox等〉経由の呼びかけもある):
1. `Read queue/inbox/{your_id}.yaml`
2. Find all entries with `read: false` (note their `id` values)
3. Process each message according to its `type`
4. `bash scripts/inbox_lock.sh mark-read {your_id} --id <all noted ids>`
5. Resume normal workflow

### MANDATORY Post-Task Inbox Check

**After completing ANY task, BEFORE going idle:**
1. Read `queue/inbox/{your_id}.yaml`
2. If any entries have `read: false` → process them
3. Only then go idle

This is NOT optional. If you skip this and a redo message is waiting,
you will be stuck idle until the next escalation or task reassignment.

## Redo Protocol

When an ashigaru's output is unsatisfactory and needs to be redone.

**改訂 (cmd_693・2026-08-18)**: cmd_692でPhase Aのredoが12回に達し、将軍裁定で
打ち切りとなった事案を受けて、旧STEP 3「escalate to dashboard 🚨」を実効gate化した。
旧文言は「上申しつつredoを出し続ける」ことを妨げず、上申内容も未定義だったため
機能しなかった。詳細は `memory/feedback_redo_protocol_escalation_gate.md` 参照。

### When to Redo

| Condition | Action |
|-----------|--------|
| Output wrong format/content | Redo with corrected description |
| Partial completion | Redo with specific remaining items |
| Output acceptable but imperfect | Do NOT redo — note in dashboard, move on |

### Task ID Naming (Redo回数を機械判定可能にする)

Redoのtask_idは必ず `_redoN` サフィックスを付与し、Nに累積redo回数を入れる。

```
オリジナル:   subtask_097d
1回目のredo:  subtask_097d_redo1   (redo_of: subtask_097d)
2回目のredo:  subtask_097d_redo2   (redo_of: subtask_097d_redo1)
3回目のredo:  作成禁止。task_idに "_redo3" が現れる時点で
              下記 Escalation Gate に抵触する
```

この命名規則により「2 redo完了」はtask_idを見るだけで機械的に判定でき、
見過ごしようがない。

### Procedure

```
STEP 1: Write new task YAML
  - New task_id with `_redoN` suffix (see naming rule above)
  - Add `redo_of: <original_task_id>` field
  - Updated description with SPECIFIC correction instructions
  - Do NOT just say "redo" — explain WHAT was wrong and HOW to fix it
  - status: assigned

STEP 2: Send clear_command via inbox (NOT task_assigned)
  bash scripts/inbox_write.sh ashigaru{N} "タスクYAMLを読んで作業開始せよ。" clear_command karo
  # clear_command は★自動で送信される
  #   (Claude/Copilot/Kimi: /clear、Codex/OpenCode: /new)。送信後、
  #   inbox_watcherが[auto-recovery] task_assignedを自動投入する。投入
  #   内容は永続化されるが、起床はベストエフォート(nudge)または確定的
  #   だがターン終了時点の遅延を伴う経路(Stop hook)によるものであり、
  #   確実ではない。★送信前に対象paneへ確認モーダルが出ていないか確認
  #   すること(「Delivery Mechanism」節と同趣旨)。

STEP 3: 2 redo完了、または早期trigger(下記)に該当 → 3回目のredo YAML作成は
  禁止。Escalation Gateへ進む。
```

### Escalation Gate（★停止gate — 2 redo後 / 早期trigger時）

次のredoのtask_idが `_redo3` になる場合(=2 redoが既に完了している場合)、
家老は3回目のredo task YAMLを**作成してはならない**。以下いずれかの早期
trigger条件に該当する場合は、redo回数が2に達していなくても本gateの対象
とする(回数基準より兆候基準を優先する)。

**早期trigger（回数より早く出る2つの兆候）**:
- **同じ箇所を2回続けて削っている** — whack-a-moleの兆候。直近2回のredo
  指摘が同一箇所を指している場合
- **成果物が当初taskに無い種類の物になっている** — scope driftの兆候。
  例: 文言修正を頼んだはずがvalidator/fixture/state machine等の形式
  検証artifactが生成されている場合

**上申手順**: 家老はdashboard.md 🚨要対応へ、状況説明ではなく判断材料
として以下4項目を**必須**で記載し、将軍の裁定が dashboard.md または
inbox に記録されるまで、**当該subtaskのredo作成のみ**停止する(他cmd・
他subtaskの処理は通常どおり継続してよい)。

1. **各redoの指摘を1行ずつ列挙** — 同じ箇所を繰り返し指摘しているか、
   毎回別の箇所かが一目で分かる形にする
2. **今作っている成果物 vs 当初taskが求めた成果物の対比**
3. **完了条件が有限か** — 「〜が存在しないことを示せ」型など、際限なく
   証拠を積み増せる要求が混じっていないか
4. **軍師の見立て** — 収束見込みありか、scopeの問題か

**将軍の裁定肢**（いずれか明記されるまで再開してはならない）:
(a) 続行（★理由を明記させる） / (b) scope縮小 / (c) 将軍が直接書く / (d) 分割

★「もう一度やれ」という無言の再開指示は裁定として扱わない。それでは
redo回数が増えるだけで何も是正されない。

### 本gateは軍師の判定基準に一切影響しない

★redoが多い = 軍師が厳しすぎる、ではない。本gate導入前後を問わず、軍師は
従来どおり厳格にPASS/REDO_REQUIREDを判定せよ。scopeを見直すのは将軍の
役目であり、本gateを理由に軍師がREDO_REQUIREDを出し渋る方向へ判定基準を
緩めれば、得るものより失うものが大きい。

### Why context reset for Redo

Previous context may contain the wrong approach. A context reset forces YAML re-read.
Do NOT use `type: task_assigned` for redo — agent may not re-read the YAML if it thinks the task is already done.

### Race Condition Prevention

A context reset eliminates the race:
- Old task status (done/assigned) is irrelevant — session is wiped
- Agent recovers from YAML, sees new task_id with `status: assigned`
- No conflict with previous attempt's state

### 軍師宛 clear_command の規則 (cmd_792)

上記 Procedure の STEP 2 は★足軽向けであり、軍師へは準用しない。軍師(Codex、宛先は `/new`)への
`clear_command` は次に限る。

- **送ってよい時点**: 新しいQCタスクを割り当てる直前、かつ軍師の**前task**が
  `queue/tasks/gunshi.yaml` で `done` または `idle` であり、paneがbusyでないことを確認した後。
  確認は新task YAMLを書く前に行う(書くと `assigned` になり、前taskの完了を示す根拠が上書きされる)。
  順序は「前task done/idle・pane非busyを確認 → 新QC task YAMLを書く(この `assigned` は未着手の次task)
  → `clear_command` を送る」。
- **送ってはならない時点**: 前taskが `assigned`/`in_progress` のまま、またはpaneがbusy(処理中)の間。
  Codexは作業中の入力を次のtool call後に投入するため、進行中のQCを途中で失う。
- **作業中の補足**: `task_assigned` + task YAMLへの追記で伝える(文脈を切らない)。
- **根拠(将軍実測・2026-09-30・Codex会話記録)**: 文脈窓258,400トークンに対しQC1件で入力が
  24k→190〜200kに達し、複数QCの会話では自動圧縮で198k→143k→47kと要約化していた。文脈保持の実体は
  要約であり、独立したQCの利得を上回らない。
- **誤送信の実例(2026-09-30 16:15:38)**: 家老が軍師の状態を確認せずに送り、watcherは
  `gunshi still busy after 15s — proceeding with startup prompt anyway` と記録して打鍵を続行した(旧実装の挙動。cmd_792②でCodex宛てのこの経路は、busyなら強行せず未読のまま保持して次巡回で再判定する形に是正済み。★本番watcherへの反映は出陣やり直し後=殿手番であり、「画面がidleに見えたこと」は安全な受領の証明ではない)。
- 家老側の手順は `instructions/roles/karo_role.md`「軍師(Codex)への文脈リセット規則」を正本とする。

### Redo Task YAML Example

```yaml
task:
  task_id: subtask_097d_redo1
  parent_cmd: cmd_097
  redo_of: subtask_097d
  bloom_level: L1
  description: |
    【やり直し】前回の問題: echoが緑色太字でなかった。
    修正: echo -e "\033[1;32m..." で緑色太字出力。echoを最終tool callに。
  status: assigned
  timestamp: "2026-02-09T07:46:00"
```

## Task Working Directory Exclusivity (cmd_695)

**新設 (cmd_695・2026-08-18)**: 2026-08-18 10:30、家老がcmd_690(足軽3号・
10:25発令)とcmd_691(足軽5号・10:27発令)を同一working directory
(`<外部プロジェクトの作業木>`)へ並行割当し、10:30:53のcmd_690側checkoutが
cmd_691の実機検証対象branchを差し替える事故が起きた。軍師がreflog・
commit差分・稼働PGIDから独立検証し、cmd_691 Phase CのFAILEDは実装欠陥
ではなく環境破壊が原因と特定した(足軽3・5いずれにも実装上の落ち度
なし)。「注意する」という心構えでは同種の事故が再発するため、家老の
割当判断を機械的に判定できる規則に変える。

### working_dir フィールド (task YAML)

足軽task YAML (`queue/tasks/ashigaruN.yaml`) は任意で `working_dir`
フィールドを `task:` ブロック直下に持つ。

- **値がある場合**: そのタスクが占有する作業ツリーの絶対パス
  (例: `/path/to/<外部プロジェクトの作業木>`。git checkout・ローカルサーバ起動・
  実機検証を伴うタスクが該当)。★記載する値は必ず`realpath`相当の
  正規化済み絶対パスとすること — 末尾スラッシュなし・symlink解決
  済み・`.`/`..`等の相対成分を含まない形。記載前に`realpath <path>`
  を実行しその出力をそのまま用いる。同一性判定(Step 2)は正規化後
  の文字列の単純一致で行うため、末尾スラッシュの有無やsymlink違い
  で表記が揺れると衝突を見逃す。専用validatorは設けない(規則文言
  での担保とする)。
- **省略した場合**: ★**省略 = そのタスクは作業ツリーを占有しない、
  という意味である。** 「working_dirが無いタスク」は本チェックの
  対象外として扱う。既存タスクYAML(本フィールド導入前に書かれた
  もの)は全てこの意味の「占有なし」として解釈し、遡及的な付与は
  行わない。

### 家老の割当時チェック(機械的判定)

家老は、新たにタスクを `queue/tasks/ashigaruN.yaml` へ `status:
assigned` として書き込む前に、以下を実行する:

0. **割当先自身の現在のentryをまず検査する(★上書き前に必須)**。
   割当先の `queue/tasks/ashigaruN.yaml` を上書きする行為そのものが
   「唯一の占有記録を消す」操作になり得るため、新タスクに
   `working_dir` があるか否か・新旧の `working_dir` が同一か否かに
   関わらず、上書き前に必ず現entryを読む。現entryが次項(3)の統一
   predicate(status が `assigned` なら `working_dir_released` の
   記載有無に関係なく常に占有中。`done`/`failed` なら
   `working_dir_released: true` 未記載の場合のみ占有中)により「占有
   中」と判定され、かつ現entryに `working_dir` の記載があるならば、
   そのworking_dirは依然占有中とみなし、**このtask fileを上書きして
   はならない**。この場合は新タスクを `queue/tasks/pending.yaml` へ
   `status: pending_blocked` として保留し、当該working_dirの解放
   (`status` が `done`/`failed` へ遷移すると同時の
   `working_dir_released: true` の追記)を待つ。解放を確認できるまで、
   同じ割当先であっても新規タスクをそのtask fileへ書き込んでは
   ならない。
   (実例: cmd_695完了直後、家老がashigaru5へ`working_dir`未記載の
   新task `subtask_691_phase_c_v2` を割り当てた際、一次YAMLでは
   12:02:21時点で既に `status: assigned` として書き込まれていた。
   軍師が12:04頃のQC中にこの割当後の状態を検出し、直接の衝突は
   まだ発生していなかったため、家老へ追加割当禁止を通知した。本
   ステップ導入前は割当前に機械的検査する手段が無かったことが根本
   原因である)
1. 割り当てようとするタスクに `working_dir` が無く、かつ上記0で
   割当先自身が「占有中」でなければ、本チェックは対象外。そのまま
   割当可。
2. `working_dir` があれば、全ての `queue/tasks/ashigaru*.yaml`
   (割当先自身を含む。上記0と重複してよい)を走査し、同一
   `working_dir` 値を持つ `task:` エントリを探す。
3. 該当エントリが見つかった場合、以下の統一predicateで「占有中」を
   判定する:
   - `status` が `assigned` である場合: `working_dir_released`
     フィールドの記載有無に関わらず常に「占有中」(このフィールドは
     `done`/`failed` への遷移と同時に付与されて初めて意味を持つため、
     `assigned` 中の誤記載・古い値の持ち越しがあっても無視する。
     fail-safe側に倒す)。
   - `status` が `done` / `failed` のいずれかである場合:
     `working_dir_released: true` が明記されていなければ「占有中」
     (`failed` を含めるのはfail-safeのため。失敗タスクほどbranch
     変更・devプロセスを残したまま中断している可能性が高い)。
   いずれかに該当すれば「占有中」と判定し、**割当てない**。
4. 「占有中」と判定した場合、新規タスクは `queue/tasks/pending.yaml`
   へ `status: pending_blocked` として保留し、占有中タスクの解放
   (`status` が `done` または `failed` へ遷移するのと同時に
   `working_dir_released: true` が明記されること。`assigned` のまま
   ではこのフィールドの記載がどうあっても解放とはみなさない)を待っ
   て改めて割り当てる(通常のpending_tasks運用に従う。`instructions/
   common/task_flow.md` の Pending Tasks 参照)。
5. 上記いずれにも該当しなければ、通常どおり `assigned` として割り
   当てる。

★「注意する」「配慮する」は判定基準にならない。上記0〜5のみで判定
する。

### 例外は認めない(読み取り専用の並行実行)

同一 `working_dir` でも読み取り専用のつもりなら並行してよいか、という
問いへの答えは★**認めない**。「読むだけのつもり」のタスクが
`git checkout` を呼んだことが今回の事故の原因であり、タスクの実行内容
が真に読み取り専用かどうかを機械的に判定する手段がない以上、判定
コストが排他制御のコストを上回る。`working_dir` が設定されたタスクは、
用途を問わず本チェックの対象とする。

### 解放: working_dir_released フィールド

タスクが `done` または `failed` になった時点でも `working_dir` は
自動的には解放されない。足軽は完了報告(`status: done` への更新)
または失敗報告(`status: failed` への更新)と同時に、そのworking_dir
を使うプロセス(dev server・electron等)を残さず終了した場合に
**限り**、自分のtask YAMLへ `working_dir_released: true` を明記する。
稼働プロセスを残す場合はこのフィールドを書かない(=占有継続として
扱われる。fail-safe側に倒す)。`failed` でも解放条件は同じであり、
「失敗したから自動的に空く」ことはない。

★`status` が `assigned` である間は、`working_dir_released`
フィールドがどのような値であれ一切参照しない。Step 3の統一
predicateどおり、占有中/解放の判定にこのフィールドが影響するのは
`status` が `done`/`failed` である場合のみであり、`assigned` は常に
「占有中」として扱う。

例(cmd_691): PGID `1034951` (vite:5173/electron:9222) が生存したまま
`done` 報告されていた実例がある(2026-08-18 11:37に別件の安全事故で
当該PGIDは既に停止済みだが、「タスクはdoneだが作業ツリーはまだ使用
中」という状態が現に起こりうることの実証にはなる)。このような場合
`working_dir_released` を明記しないことで、家老の割当チェックは当該
working_dirを引き続き「占有中」と判定し続ける。プロセスが停止し作業
ツリーが実際に空いたことを確認した時点で、足軽が `working_dir_
released: true` を追記する。

## Report Write Lock (cmd_699)

`queue/reports/gunshi_report.yaml` への書き込みには、軍師の追記(QC
report作成)と家老の移管(cmd完了時に`gunshi_report_archive.yaml`へ退避)
の2種類が存在する。flockはadvisory(協調的)であり、★全ての書き手が
同じロックを取らなければ意味を持たない。生のRead/Edit/Writeで両者が
並行実行されると、片方の変更が他方の上書きで消える lost update が
起きる(2026-08-18時点で3度観測・毎回軍師が自力復元・実害はまだ無い)。

★`gunshi_report.yaml`への追記・削除(移管によるエントリ削除を含む)は、
必ず以下のスクリプト経由で行うこと。生のRead/Edit/Writeで直接書き換え
てはならない。読み取りのみ(件数確認等)にはロック不要 — read-modify-
writeの一連だけをこのスクリプトで囲めば足りる。

```bash
# 軍師: 新しいQC report(単一YAMLマッピング文書・'---'区切りを含まないこと)を追記
bash scripts/gunshi_report_lock.sh append <content_file>

# 家老: 指定parent_cmdに一致する文書をgunshi_report_archive.yamlへ移管
bash scripts/gunshi_report_lock.sh archive <parent_cmd_id>
```

両コマンドとも `queue/reports/.gunshi_report.lock` を `inbox_write.sh`
と同形の mkdir+flock 二重ロックで取得してから read-modify-write を行い、
完了後に解放する。該当 parent_cmd の文書が無い archive 呼び出しは0件
移動として正常終了する(エラーにしない)。

## Ashigaru Report Write Lock (cmd_734)

`queue/reports/ashigaru{N}_report.yaml` への書き込みにも、上記gunshi_
report.yamlと同型のlost updateリスクがある: 足軽本人の完了報告追記と、
家老の移管(cmd完了時に`ashigaru{N}_report_archive.yaml`へ退避)が生の
Read/Edit/Writeで並行実行されると、片方の変更が他方の上書きで消える。
flockはadvisoryであり、★全ての書き手が同じロックを取らなければ意味を
持たない。

★`ashigaru{N}_report.yaml`への追記・移管は、必ず以下のスクリプト経由で
行うこと。**report.yamlのEOFへの直接Edit/Write追記は禁止**。読み取りの
み(件数確認等)にはロック不要 — read-modify-writeの一連だけをこの
スクリプトで囲めば足りる。

```bash
# 足軽: 完了報告(単一YAMLマッピング文書・'---'区切りを含まないこと)を追記
bash scripts/ashigaru_report_lock.sh append <agent_id> <content_file>

# 家老: 指定parent_cmdに一致する文書を ashigaru{N}_report_archive.yaml へ移管
bash scripts/ashigaru_report_lock.sh archive <agent_id> <cmd_id_list_file>
```

`<agent_id>` は `ashigaru1`/`ashigaru2`/`ashigaru3`/`ashigaru4`/`ashigaru5`/
`ashigaru6`/`ashigaru7` のいずれか(allowlist完全一致・他の値は使い方エラーで
拒否)。両コマンド
とも `queue/reports/.{agent_id}_report.lock` を `inbox_write.sh`・
`gunshi_report_lock.sh` と同形の mkdir+flock 二重ロックで取得してから
read-modify-write を行い、完了後に解放する。該当 parent_cmd の文書が
無い archive 呼び出しは0件移動として正常終了する(エラーにしない)。
list形式(1チャンクに複数エントリがまとめられた過去分)のchunkは
parent_cmdが混在しうるため判定不能として常にkeep側に残す(fail-safe)。

## Dashboardセクション判定基準 (cmd_700)

殿のご下問(2026-08-18・「記録にあたるものが🚨要対応/🔄進行中に滞留し、
真のpendingが埋もれている」)への対応。4セクションの判定基準を明文化し、
「解決済み」の記録が居座る事故を機械的に検出できる形にする。

### 定義(A-1)

| セクション | 定義 |
|-----------|------|
| 🚨 要対応 | ★殿または将軍が判断・対応するまで前に進めないもの**のみ**。報告目的で置くことを禁ずる。見出し(`- **{見出し}**:` の `**...**` 部分)の先頭に【殿手番】【将軍手番】タグを必須付与する(cmd_715改訂・無印は【殿手番】扱い)。「解決済み」の冠が付いた時点で✅戦果へ移す |
| 🔄 進行中 | ★agentが現に稼働しているもの**のみ**。完了・PASS・保留(pending_blocked)は✅戦果へ移す。★将軍上申待ち・殿裁可待ちはここに置かず🚨要対応へ置くこと(cmd_715改訂)。例外として、status: pendingのcmd(発令済み・未着手)は『【pending】』印付きの1行のみ🔄進行中への掲載を認める(cmd_id・title・着手待ちの理由を明記)。これは既存の⏸️待機中(保留・候補)とは区別する——pendingは『発令済みで着手待ち』、⏸️は『保留・候補』である |
| ⏸️ 待機中 | 殿の判断待ちだが急がないもの(既存の役割を維持) |
| ✅ 戦果 | 完了したもの・記録 |

### 機械的歯止め(A-2)

🚨要対応・🔄進行中の**見出し**(`- **{見出し}**:` の `**...**` 部分)に、
以下4語を含めてはならない:

`解決済み` / `完了` / `PASS` / `是正済み`

- これらの語を見出しで使ってよいのは✅戦果へ移した後のみ。🚨/🔄に置いた
  ままでは使わない。
- 否定形(「未完了」「未是正」等)も文字列としてこれらの語を含むため同様に
  誤検出される。開いている項目の見出しでは「残作業」「保留」「未実施」
  「検証待ち」等、別表現を使うこと。
- 検出語は意図的に4語のみに絞る(増やすほど誤検出が増える)。この4語で
  拾えない滞留(例: 恒久ルールの「確定」等)は、A-1の定義——特に「agentが
  現に稼働しているか」——に照らした目視判断で拾う。A-2はA-1を代替する
  ものではなく、A-1の典型的な違反パターンを安価に検出する補助である。

**検証コマンド**(家老が完了処理時に実行。0件が正常):

```bash
sed -n '/^## 🚨 要対応/,/^## 🔄 進行中/p' dashboard.md \
  | grep -E '^- \*\*.*(解決済み|完了|PASS|是正済み).*\*\*:'
sed -n '/^## 🔄 進行中/,/^## ✅/p' dashboard.md \
  | grep -E '^- \*\*.*(解決済み|完了|PASS|是正済み).*\*\*:'
```

### 恒久記録の置き場所(A-3)

恒久運用ルール(例: CoDD SKIP包括裁可のような、将来にわたり適用される
取り決め)の正本はdashboard.mdではなくmemory(Memory MCP +
`memory/MEMORY.md` + `memory/feedback_*.md`)である。dashboardは「今」を
映すものと割り切り、恒久記録は🔄進行中/🚨要対応に居座らせず✅戦果へ
流してよい。

**移す前の確認手順(必須・省略禁止)**:
1. `memory/MEMORY.md`(またはMemory MCP `read_graph`)に当該ルールを指す
   行が存在することを確認する。
2. その行がリンクする詳細ファイル(`memory/feedback_*.md`等)が実在し、
   適用条件・例外・失効条件を過不足なく記載していることを確認する。
3. 1・2いずれかが欠落していれば★流してはならない。先にmemory側へ記録
   してから改めて本手順に戻る。
4. 確認できたら✅戦果へ要約して移し、「詳細は memory/{file} 参照」の
   一文を残す(dashboard側で全文を保持する必要はない——memoryが正本の
   ため)。

### 機械的トリガー(cmd_715改訂)

殿のご下問と同根の事故が将軍手番でも起きた(2026-08-20、cmd_711/712/713
の3件がPhase A軍師QC合格・将軍上申待ちのまま🔄進行中に置かれ、🚨要対応
に出ず将軍の目に留まらなかった)。任意フィールドを引き金にすると空振り
する実例——現役gunshi_report 202件中`gate.shogun_submission`保持は5件
のみ、当日埋もれた3件中cmd_712のみREADY保持・cmd_711はBLOCKEDのみ・
cmd_713はgateフィールド自体なし——を踏まえ、以下3点を機械的トリガーの
土台とする。

**① gate.shogun_submission 必須出力(軍師)**

軍師は`queue/reports/gunshi_report.yaml`へ追記する全てのQC reportに、
`gate.shogun_submission`を**必須**出力する(任意フィールドにしては
ならない。ホワイトリスト・任意フィールドが新しい仲間を黙って落とす
事故が本日だけで3例目——slim_yamlのCANONICAL_REPORTSに
gunshi_report_archiveが無かった件、.gitignoreのホワイトリストに
inbox_lock.shが無かった件、そして本件——であるため)。値の定義:

| 値 | 意味 |
|----|------|
| `READY` | 全Phase完了・将軍上申準備完了 |
| `BLOCKED` | redo中等、現時点では将軍へ上申できない |
| `N_A` | この report は将軍上申を要さない(中間QC等) |

出力形式・記載箇所は`instructions/roles/gunshi_role.md`のReport Format
節に従う。

**② 家老の即時移送ルール**

家老は、gunshi reportのinbox通知(type: `report_received`、
from: gunshi)を「Inbox Processing Protocol」Step 3(メッセージを
typeに応じて処理する)の一環として処理する際、当該reportの
`gate.shogun_submission: READY`を確認した時点で、当該cmdのdashboard.md
上の項目を🔄進行中から🚨要対応【将軍手番】へ**即座に**移す。「PASS
報告は受けたが上申はまだ」という中間状態を🔄進行中に放置してはなら
ない。

★移送した時点で、当該項目は🚨要対応へ新たに現れる。よって家老は
「家老→将軍 クロスセッション通知 (cmd_728)」に従い、台帳で既送を
照合した上で将軍へ一通送る。

**③ 将軍コミットメント追跡(新設)**

軍師QCのgateを引き金にする限り、QCを経由しない将軍手番は永久に拾え
ない。cmd_696がcmd_701を待ち、cmd_701が将軍を待った事案(将軍が「新
cmdを起草する」と述べたまま2日間書かれなかった)が実例であり、QCゲート
を一切経ていなかった。

- 将軍が「起草する」「裁定する」「判断する」等、今後の行動を明言した
  場合、家老は`queue/shogun_commitments.yaml`へ当該言明を記録する
  (スキーマ・記録手順は同ファイルのコメントを参照)。
- 家老はinbox処理の都度、同ファイルの全エントリについて`committed_at`
  からの経過時間をチェックする。
- ★`committed_at`から24時間経過してもコミットメントが果たされていな
  ければ、家老は当該項目をdashboard.md 🚨要対応【将軍手番】へ自動的に
  掲載する(cmd_701→cmd_713の2日間放置という教訓を踏まえ余裕を持ち
  短めに設定した値であり、閾値の妥当性自体は将軍裁可を仰ぐ)。
  - ★例外(2026-08-20T18:59将軍裁可): 将軍が言明時に期限を明示した
    場合(「今日中」「来週」等)は、その期限を`due`へ記載し、既定
    24時間ではなく`due`を基準に追跡する。24時間で一律に上げてはなら
    ない。期限の明示が無い言明のみが既定24時間の対象である。
  - ★掲載した時点で「家老→将軍 クロスセッション通知 (cmd_728)」の
    送信条件を満たす。★ただし通知は判断点ごとに一度きりである——
    本項の判定は家老のinbox処理の都度走るため、台帳
    (`queue/shogun_notify_sent.yaml`)で既送を照合せねば同じ項目で
    何度でも通知が飛ぶ。
  - ★理由: 24時間は短すぎると見る向きもあろうが、cmd_701→cmd_713が
    2日間膠着した実害がある。誤報(空振り)の代償は🚨要対応への1行
    追加にとどまる一方、見落としの代償は2日間の膠着である。短めに
    倒すのが正しい。ただし将軍が期限を明示すればそれに従うため
    ノイズは自然に減る——期限を添える責は将軍にある。
- 将軍がコミットメントを実行(新cmd発令等)した時点で、家老は
  `queue/shogun_commitments.yaml`から該当エントリを削除する。
  - ★🚨要対応掲載後、将軍が「まだやらぬ」等、未実行のまま応答した
    場合は、黙ってエントリを削除してはならない。将軍から改めて期限
    を取り、`due`を更新して記録し直し、追跡を継続する。一度上げて
    流されたら終わり、では意味がない。

## 家老→将軍 クロスセッション通知 (cmd_728)

殿の下命(2026-08-31)による。家老がdashboard.md 🚨要対応へ【将軍手番】
項目を**新規に**掲げたとき、家老は将軍のセッションへクロスセッション
通知(`SendMessage`)を**一通だけ**送る。2026-08-31の実運用では将軍手番が
30〜60分おきに計5回発生し、そのすべてを殿が口頭で将軍へ中継しておられた。
その手間を無くすための経路である。

### ★通知は「鈴」であって「指図」ではない(最重要)

- 通知が伝えるのは「dashboardを見に来い」だけである。
- ★将軍は通知の本文で判断しない。必ずdashboard.mdとqueue/配下の一次
  データを自ら読んでから動く。
- ★ゆえに本文へ判断材料を盛ってはならない。盛った瞬間にこの経路の
  安全性——送信元の名を詐称されても、本文が誤っていても、将軍の判断は
  汚れない——が崩れる。
- 本文は後述の定型文に限る。詳細を書きたくなったらdashboardへ書け。

### 送信条件(これ以外では送るな)

**送る**:

- 家老がdashboard.md 🚨要対応へ、見出しが【将軍手番】で始まる項目を
  ★新規に書いたとき。以下を含む:
  - 「機械的トリガー(cmd_715改訂)②」により🔄進行中から🚨要対応
    【将軍手番】へ移した場合(要対応へ新たに現れるため)
  - 「同③」の24時間経過による自動掲載
  - 既存項目のタグを【殿手番】から【将軍手番】へ改めた場合

**送るな**:

- ★【殿手番】項目。殿への通知はntfy(`bash scripts/ntfy.sh`)が担う。
  ★この経路で殿へ直接届けてはならない。
- dashboardを更新しただけのとき(進捗の追記・体裁の修正・✅戦果への
  移動等)。★更新のたびに送るな。
- 既に送った判断点(台帳で照合する。後述)。
- 1回のdashboard更新で複数の【将軍手番】項目を書いたとき。★1通に
  まとめよ。項目ごとに送るな。
- ★連投するな。1回のdashboard更新につき最大1通である。

### 送信手順(家老)

1. ★先にdashboard.mdを更新し、【将軍手番】項目を書き終える。通知は
   その後である。順序を逆にすると、将軍が見に来た時に項目が無い。
2. `queue/shogun_notify_sent.yaml` を読み、同一の `cmd_id` +
   `topic` を持つエントリが無いことを確かめる。あれば★送らず終了。
3. `ListAgents` で将軍のセッションを解決する。★名を決め打ちするな
   (`from-name`・peer名は自動生成であり、再起動で変わる)。
   - 各行は `name [ref] · … · tmux <session>:@<window_id>.%<pane_id>`
     の形で出る。
   - ★tmux列のセッション名が `shogun:` の行が将軍である(この経路に
     現れる他のpeer——家老・足軽3〜7——はいずれも `multiagent:` である)。
   - 実測例(2026-08-31): 将軍の行は
     `将軍 [3a6efc] · interactive · idle · tmux shogun:@0.%0` と出た。
     ★この名に依存するな。tmux列で判ぜよ。
   - 該当行が1つであることを確かめ、その pane id で裏を取る:
     `tmux display-message -t '%0' -p '#{@agent_id}'`(`%0` は当該行の
     pane id)が `shogun` を返すこと。
   - 該当行が0件または2件以上、あるいは裏取りが一致しないときは
     ★送らず終了する。dashboardは既に更新済みであり記録は失われない。
     ★別名で当て推量して送るな。
4. `SendMessage` を送る。`to` は3で確定した行の名前をそのまま用いる。
   本文は次の定型文とする(★これ以外を書くな):

   ```
   家老より。dashboard.md 🚨要対応へ【将軍手番】項目を新規に掲げ申した。ご確認くだされ。返信は無用。(cmd_XXX)
   ```

   - ★冒頭の「家老より」は必須。`from-name` は `shogun-1a` 等の自動
     生成名で役職を示さぬため、名乗りで補う(将軍側はsocketパスのPID→
     親PID→tmux pane_pid→`@agent_id` でも辿れるが、名乗りと二重にせよ)。
   - 複数項目を1通にまとめるときは末尾へcmd_idを併記する:
     `(cmd_XXX, cmd_YYY)`。
   - ★`notify_when_idle` を使うな。将軍が busy でもメッセージは滞留し
     次のtool roundで届くため、購読は不要である。
5. 送信の成否にかかわらず、`queue/shogun_notify_sent.yaml` へ★項目ごと
   に1エントリ追記する(失敗時は `result: failed` と理由を記す)。
   ★失敗しても再送するな。dashboardが一次記録である。

### 送信済み台帳 `queue/shogun_notify_sent.yaml`

- ★書き手は家老のみである。単一書き手ゆえロック機構は設けない
  (`inbox_write.sh`・`gunshi_report_lock.sh` と異なる点)。
- 重複判定の鍵は `cmd_id` + `topic`。`topic` は判断点を表す短い識別子で、
  家老が掲載時に付し、★見出しの言い回しを変えても変えない。
  - ★見出し全文を鍵にするな。体裁を直しただけで二通目が飛ぶ。
  - ★cmd_idだけを鍵にするな。同一cmdで別個の判断点が後日生じたとき、
    二度と通知できなくなる。
  - 同一cmdで新しい判断点が生じた場合に限り、新しい `topic` で送って
    よい。★迷ったら送らぬ方に倒せ。通知の欠落は将軍が次にdashboardを
    見るまでの遅延にとどまるが、連投は殿の作業環境を乱し、将軍のturnを
    無駄に消費する(受信は将軍のturnを1つ消費する——後述の実測)。
- ★この台帳が無いと「機械的トリガー③」(24時間経過項目の自動掲載)は
  家老のinbox処理の都度——すなわち何度でも——通知を飛ばす。台帳は連投
  防止の要である。
- 項目が片付き✅戦果へ移した後も★エントリを消すな。消せば同じ判断点で
  再送しうる。肥大したときは家老が `queue/archive/` へ移す。

### ★歯止め(permission laundering 禁止)

★この経路は既存の禁止を解くものではない。

1. ★家老はこの経路で殿へ直接届けない。殿への通知はntfyのみである。
2. ★家老は自らに禁じられた行為を将軍に代行させない。将軍へ依頼する形
   をとっても、家老の権限外の行為が家老の意思で行われるならば同じこと
   である。
3. ★指揮系統(将軍→家老→足軽/軍師)を迂回しない。
4. ★inbox経由の家老→将軍は引き続き禁止である(「Report Flow」参照)。
   本節は★別経路の限定的な追加であって、inbox禁止の解除ではない。
   inbox禁止の理由は「殿の入力に割り込むから」であり、本経路は専用
   ブロックに包まれて届くためその理由に当たらぬ、というだけである。
5. ★足軽・軍師はこの経路を使わない。足軽3〜7は技術的には参加できるが、
   報告は従来どおり(足軽→軍師→家老)である。★足軽から将軍への直送は
   禁止。
6. 受信側では、ハーネス自身が同趣旨の注意書きを添えて将軍へ渡すことを
   実測で確認している(2026-08-31)。本節の記述はその重複ではなく★補強
   である。★「ハーネスが守るから不要」と考えるな——ハーネスは将軍を
   守るが、家老の側の振る舞いは縛らぬ。

### 参加できる者・できぬ者(★非対称)

| Agent | CLI | この経路 |
|---|---|---|
| 将軍 | Claude | 受信可 |
| 家老 | Claude | ★送信可(本節の用途に限る) |
| 足軽3〜7 | Claude | 技術的には可だが★使わない |
| 軍師 | Codex | ★不可(peer一覧に一切現れぬ) |
| 足軽1・2 | Codex | ★不可(同上) |

★軍師→将軍の通知はこの機構では作れない。軍師のQC結果は従来どおり
家老経由(`queue/reports/gunshi_report.yaml` + inbox → 家老 → dashboard)
である。「あとで軍師にも」と考えるな——CLIが違えば経路自体が存在せぬ。
この非対称は当面解消できぬ前提として扱う。

### 実測で確かめた事実(2026-08-31・将軍)

| 事項 | 実測結果 |
|---|---|
| 経路の可否 | ★使える(家老からの試験一通が将軍へ到達) |
| 受信形 | `<cross-session-message from="uds:<送信側claudeがbindしたsocketのパス>" from-name="...">` の専用ブロック(`<パス>` は `<dir>/{PID}.sock`。置場の決まり方は下記「socketの置場規則」) |
| 殿の入力との混同 | ★しない(専用ブロックで包まれる) |
| socket実体 | `cc-socks` 系ディレクトリ配下の `{PID}.sock`(★`~/.claude` ではない)。★置場は固定パスではなく本体の規則で決まる(下記「socketの置場規則」) |
| 送信元の名 | `shogun-1a` 等の自動生成名。役職を示さず、再起動で変わる |
| turn消費 | ★受信は将軍のturnを1つ消費する |
| 参加者 | Claude系のみ(家老・足軽3〜7)。Codex系(軍師・足軽1・2)は不参加 |

### socketの置場規則(cmd_784・Claude Code 2.1.284 の実測)

★置場は固定パスではない。旧記述の `/tmp/cc-socks-<uid>` 固定は、本体の規則の
うち「退避先」を既定と取り違えたものであった。以下は足軽7号の隔離実測
(`claude -p` の子を4条件で起動し、bindしたsocketを観測)とバイナリ読取による。

| 事項 | 内容 |
|---|---|
| 一次置場 | base = `XDG_RUNTIME_DIR` → `CLAUDE_CODE_TMPDIR` → `TMPDIR`(無ければ `/tmp`)の最初の非空。socket は `<base>/cc-socks/<pid>.sock` |
| 退避先 | パスが103byteを超える時、または一次dirを作れない・所有者が不正などで拒否された時のみ `/tmp/cc-socks-<uid>/<pid>.sock`。撤去済みの `XDG_RUNTIME_DIR` を指したまま起動した場合もここへ退避する |
| 環境変数が全て無い時 | `/tmp/cc-socks/<pid>.sock`(uid無し) |
| 実際にbindしたパス | `~/.claude/sessions/<pid>.json` の `messagingSocketPath` に記録される。★置場の判定はこれを正とする(`lib/mesh_registration_check.sh` も第一手段とする) |
| 本リポジトリの出陣後 | `shutsujin_departure.sh` が agent pane から `XDG_RUNTIME_DIR` を外すため、次回出陣以降は `/tmp/cc-socks/<pid>.sock` の見込み |

- `XDG_RUNTIME_DIR` は login session の寿命で消える。2026-09-29 の出陣は、
  約80秒後に logind が session を外して `/run/user/1000` が撤去され、その下に
  張った socket へ誰も到達できなくなった(cmd_784・経緯は
  `docs/delivery_channels.md` §11.6)。
- ★断定できないこと(足軽7号の留保をそのまま残す):
  - 「出陣後は `/tmp/cc-socks/` に張る」は見込みであり、出陣やり直し後の
    実機では未確認である(確認は cmd_784 AC⑤)。
  - 殿がtmux外で起動したsession(`/run/user/1000/cc-socks/`)とagent群
    (`/tmp/cc-socks/`)の跨ぎ送受信は、本体の「既定の置場での相手検証」
    経路で通る見込みだが、実機では検証していない。
  - 2026-08-31・09-10 の実測が `/tmp/cc-socks-<uid>` だった理由は未確定である
    (当時の `XDG_RUNTIME_DIR` が撤去済みdirを指して退避した形で説明はつくが、
    確定していない)。
  - 上の規則は本体 2.1.284 の実測であり、本体の更新で変わり得る。

### ★まだ測れていないこと(断定するな)

- ★殿が入力しておられる最中に通知が届いた場合の挙動は**未実測**である。
  公式文書は「割り込まぬ」と書くが、公式文書を鵜呑みにして判断を誤った
  前歴がある(2026-08-20)。★正本としても断定しない。
- 通知量を絞ってある(【将軍手番】の新規掲載時のみ・1回の更新につき
  最大1通・同一判断点は一度きり)のは、★この不確かさに対する備えでも
  ある。実運用の頻度は1日5回程度(2026-08-31実測)であり、この絞りで
  過大にはならぬ見込みである。
- 挙動が実測されるまでは、この絞りを緩めてはならない。緩めるときは
  cmdを立て、実測を添えて殿の裁可を仰ぐこと。

## 権限要求ルーティング (cmd_775)

足軽・家老・軍師の確認モーダル停止を、PermissionRequest hookで指揮系統
へデータとしてルーティングする(打鍵は一切発生しない)。将軍自身のpane
は対象外(hookが自pane判定で`shogun`と分かった時点で即deferToUserとし、
記録ファイルすら作らない)。対象はClaude系のみ——Codex系(足軽1・2・軍師)
はhook自体が無く対象外(従来どおりモーダル/人経路のまま)。

### 記録ファイル

```
queue/state/permission_requests/<agent>_<UTC時刻>_<sha256(session_id+tool_input)先頭8文字>.yaml
```

事実のみ(agent_id・session_id・task_id/parent_cmd・tool_name・
tool_input全文・cwd・受領時刻)が書かれる。判断材料は含まれない。
★record IDは`tool_use_id`に依存しない(将軍裁定(a): Phase 0隔離PoC・
redo1を通じ実測7回全てで当該フィールドが欠落した)。`permission_
suggestions`キーも出現が不安定と実測されたため一切依存せず、存在すれば
記録に転記するのみとする。

作成後、この記録ファイルへは`hook_result`(下記「inbox_watcherの打鍵
抑制guard」節参照。hookの`finish()`が退出経路で記帳する`outcome`/
`returned_at`)と`inquiry`(将軍裁定(iii)。将軍が`inquire`実行時に
記帳する`sent_at`/`channel`/`by`)が、それぞれ発生時点で原子的に追記
されうる。いずれも作成時点の初期内容には含まれない。

`hook_result.outcome`は`allow`・`deny`・`defer_timeout`・`failed`・
`aborted`のいずれか。`aborted`(cmd_799 ④)は、手動のNo/Escでモーダルが
閉じられhookが終了させられた(SIGTERM系)場合に、hookのEXIT trapが
記帳する。この退出は`finish()`を通らないため、従来は`hook_result`が
書かれずguardがfail-safe timeout(約30分)まで解けなかった。記帳は
check-and-setで、記録に`hook_result`が既にあれば何も書かない(通常の
退出経路と二重に書かない)。SIGKILLはtrapできず、この場合は従来どおり
fail-safe timeoutが解除する。判定(allow/deny)の中身とtimeout値は変えて
いない。

### inbox通知

type: `permission_request`。本文はrequest_idと1行要約のみ(判断材料は
含めない)。

### 家老の手順(判断しない)

1. dashboard.md 🚨要対応へ【将軍手番】で新規項目を掲げる(記録ファイルの
   pathとrequest_idを転記するのみ。tool_inputの内容評価や「allowすべき
   では」といった所感は書かない)。
2. 「家老→将軍 クロスセッション通知 (cmd_728)」節の定型文・送信条件・
   台帳照合手順をそのまま使って将軍へ通知する
   (permission_request専用の別ルートは設けない)。

### 将軍の判定規則

記録ファイルの命令全文とtask YAMLを読み、`scripts/permission_decide.sh`
で決定ファイルへ書く。

- **deny**: 将軍の権限。`message`(禁止だけでなく★通ってよい代替手段を
  含む理由文)+`interrupt=false`を固定で使う(Phase 0 redo1実測: turnは
  中断されずmessageがそのままClaudeへ渡り、turnは継続した)。
- **allow**: 既定は殿の権限。将軍は決定ファイルを書かず
  `permission_decide.sh inquire <request_id> --by shogun --channel ntfy`
  を実行してntfyで殿へ問う(下記「問い合わせ (inquire)」参照)。殿の
  返答が来たら`permission_decide.sh <request_id> allow --by lord
  --reason <文>`または`deny --by lord --reason <文>`で決定を書く。
  timeout(1800秒−margin)内に殿の返答が無ければ通常モーダルへ落ち、
  殿の手元で直接答えていただく(従来どおり)。機械検証できる場合(例:
  `rm -rf`をcmd_753のclosed-grammar検査器がSAFEと判定)に限り、
  `--machine-check`証跡付きで将軍がallow可。「画面を見て安全そう」は
  不可(cmd_754の教訓)。allowは`decision.behavior=allow`★単体で足りる
  (将軍裁定(b): Phase 0 redo1実測で`updatedPermissions`の併記なしに
  確認モーダルが完全に消え命令が実行された)ため、`updatedPermissions`
  (許可規則の追加)は★使わない(scope外・より狭く保つ)。

### 決定ファイル

`queue/state/permission_decisions/<request_id>.yaml`。1 request 1決定
(上書き不可)。監査ログを兼ねる(privategit保全対象)。決定は`deny`か
`allow`のみ(★将軍裁定(iii)〈cmd_775 Phase D redo2〉により`defer`は
決定の語彙から除外された)。殿への問い合わせは決定ではない——下記
「問い合わせ (inquire)」を使う。

### 問い合わせ (inquire・将軍裁定(iii))

allowが殿権限の場合、将軍は決定を書かずに`scripts/permission_decide.sh
inquire <request_id> --by shogun --channel <ntfy|terminal>`を実行して
殿へ問う。これは★決定ではない: 決定ファイル(`queue/state/
permission_decisions/`)は書かれず、1 request 1決定のslotも消費しない。
記録ファイル(`queue/state/permission_requests/<request_id>.yaml`)へ
`inquiry: {sent_at: <UTC>, channel: <ntfy|terminal>, by: shogun}`が
原子的に追記される(既存フィールドは変更されない)。

hookは殿の返答(将軍が`allow --by lord`/`deny --by lord`として転記した
決定)が来るまでポーリングを継続する。timeout(1800秒−margin)内に決定が
書かれなければ、hookは通常どおりdeferToUser(確認モーダル継続)へ落ちる。
`defer`という決定値は廃止されたが、1 request 1決定は`deny`/`allow`の
みで構成される——殿への問い合わせ中は決定を一切書かないことで、この
制約と矛盾なく両立する。

### inbox_watcherの打鍵抑制guard(★新設・将軍裁定(c))

hookが決定待ちの間、確認モーダルが画面に出たままになる(Phase 0隔離PoC
③の実測: hookのtimeoutに遠く及ばない時点〈送信後約8秒〉で既に画面へ
モーダルが表示され、決定が届くまでそのまま変化なく表示され続けた)。
この間に鍵が届くと2026-09-08型の誤爆(確認モーダルの既定選択肢を打鍵で
押してしまう事故)になり得るため、`inbox_watcher.sh`は「当該agentの
未決`permission_request`記録が`queue/state/permission_requests/`に
存在する間、そのpaneへ一切の打鍵(nudge・`/clear`・`model_switch`)を
送らない」という、画面のbusy判定に加えるデータ根拠のguardを持つこと
(defense in depth・送らない側へ倒すのみ)。解除条件は、hookが記録
ファイルへ`hook_result`(上記「記録ファイル」節参照)を記帳した事象、
または`received_at`+timeout+マージン(約1810秒)経過によるfail-safeの
いずれかである(★決定ファイルの存在そのものは解除条件ではない——hookが
異常終了し決定を読めないまま終わる場合があるため)。実装は
`scripts/inbox_watcher.sh`へ行った(cmd_775 Phase D redo2で
`hook_result`記帳判定へ改修)。

### 孤児記録(結果の無い記録)の扱い (cmd_799 ⑤)

孤児記録とは、`hook_result`が無く、`received_at`からtimeout+マージン
(約1810秒)を超過した記録である(上記guardの「解決済み」「fail-safe超過」
の定義と同一)。hookは自身のdeadline(timeout−マージン)で退出するため、
この時点でhookは生きていない(SIGKILL・クラッシュ・再起動、または
`hook_result`導入前の旧版の記録)。★guardは超過した記録を既に無視する
ので、孤児は打鍵を止めない——「結果の無い記録」が残って未決に見える
だけの整理対象である。決定ファイル(`queue/state/permission_decisions/`)
は監査ログなので整理の対象外。整理は**削除せず退避**とし、手順と道具
(`scripts/permission_orphans.sh`)は`instructions/roles/karo_role.md`
「権限要求の孤児記録の整理 (cmd_799 ⑤)」節を正本とする。

### 試験要件(将軍裁定(d)・Phase C実装で満たすこと)

隔離試験(isolated_tmux使用・稼働pane非干渉)で以下3件を確認すること:

1. hook待機中に人がモーダルへ手で答えた場合、後から届くhookの決定が
   二重実行・矛盾を起こさないこと。
2. hookの`timeout`に設定できる上限の実測と、超過時のdeferToUser
   (通常モーダル)継続。
3. hook自身の異常(記録書込不能・決定ファイルschema不正)でdecisionを
   返さない(=defer)こと・allowを返す経路が存在しないことの負の試験。

### Tooling Pitfalls再掲

hookからdenyを受け取ったagentは、同じ命令を再試行せず作り直すこと
(Tooling Pitfalls⑤「使い捨て検証に後始末を書くな」と同種の教訓——
理由を理解せず同じ形を繰り返すな)。

hookコマンドのcwd依存起動失敗とその是正(絶対パス化)の詳細は
`docs/delivery_channels.md`§12・`instructions/common/
tooling_pitfalls.md`⑨を参照。

## Report Flow (interrupt prevention)

| Direction | Method | Reason |
|-----------|--------|--------|
| Ashigaru/Gunshi → Karo | Report YAML + inbox_write | File-based notification |
| Karo → Shogun/Lord | dashboard.md update only(+【将軍手番】項目の**新規掲載時のみ**クロスセッション通知1通 → 「家老→将軍 クロスセッション通知 (cmd_728)」) | **inbox to shogun FORBIDDEN**(継続) — prevents interrupting Lord's input。cmd_728の経路はinbox禁止の解除ではなく別経路の限定的追加である |
| Karo → Gunshi | YAML + inbox_write | Strategic task delegation |
| Top → Down | YAML + inbox_write | Standard wake-up |

## File Operation Rule

**Always Read before Write/Edit.** Claude Code rejects Write/Edit on unread files.

## Inbox Communication Rules

### Sending Messages

```bash
bash scripts/inbox_write.sh <target> "<message>" <type> <from>
```

**No sleep interval needed.** Multiple sends can be done in rapid succession — flock handles concurrency.

★ただし「送った=届いた」ではない。`inbox_write.sh` が保証するのは
`queue/inbox/{agent}.yaml` への★永続化だけである。agent CLI が動いている pane
への自動打鍵(nudge)は★実際に送信されるが、エスカレーション上カウントする
確定配送経路は CLI ごとに異なる(詳細は「Delivery Mechanism」節):

| CLI | 実際に配送を担うもの |
|-----|----------------------|
| claude | **Stop hook のみ**(ターン終了時に発火。未読が無ければ最大55秒待つ。★その窓を過ぎて完全に idle になった後は届かぬ) |
| codex / opencode / copilot / kimi | ★**無い → 人経路** |

★agent 自前の self-watch は実在しない。配送経路として数えるな。
配送確認は inbox YAML の `read` 状態を正とせよ。確定配送経路の無いCLIで
届かぬ間、watcherは0〜2分nudge・2〜4分(Copilot/Kimiのみ)Escape×2+Ctrl-C
+nudge・4分〜(足軽のみ)`/clear`(5分に1回)と打鍵を強め続けるが、
「閾値超過で家老inboxへdelivery_alertとして自動で上がる」機構は無い。
それでも届かなければ、家老自身がdashboard.md 🚨要対応【将軍手番】へ
載せ、人の手を仰げ。
詳細: `docs/delivery_channels.md`

### Report Notification Protocol

After writing report YAML, notify Karo:

```bash
bash scripts/inbox_write.sh karo "足軽{N}号、任務完了でござる。報告書を確認されよ。" report_received ashigaru{N}
```

That's it. No state checking, no retry from the sender's side.
★`inbox_write` が保証するのは**永続化**だけである。inbox_watcher は★実際に
nudgeを送信するが、それは「送ったから届いた」を意味しない。確定配送を
担うものは上表のとおりであり、届かぬ間はwatcherがnudge→(一部CLIは)
Escape+nudge→(足軽のみ)`/clear`と時間経過に応じて打鍵を強めるだけで、
自動で人経路へ切り替わる機構は無い。
