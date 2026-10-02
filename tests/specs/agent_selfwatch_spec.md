# Agent Self-Watch テスト仕様書

| 項目 | 内容 |
|---|---|
| 文書ID | ASW-SPEC-001 |
| parent_cmd | cmd_107 |
| task_id | subtask_107b |
| 作成日 | 2026-02-09 |
| 参照要件 | reports/requirements_agent_selfwatch.md |
| 対象 | Agent self-watch Phase 1-3（TDD Step 2） |

---

## 0. ★現契約の注記 (cmd_754 / 2026-09-08 改訂)

本仕様書は cmd_107 当時、**「平常時は nudge を減らし、異常時は send-keys で
復旧する」** という前提で書かれていた。その前提は★失効した。

2026-09-08、確認モーダル表示中の pane へ inbox_watcher が nudge を送り、その
Enter が既定選択肢 `❯ 1. Yes` を選んで D002-E1 違反の削除が実際に実行された。
以後4世代にわたり「画面から安全を証明する」試みを重ねたが4度とも破れ、将軍は
★**自動打鍵の安全集合を空とする**裁定を下した (E-1)。

現契約:

| CLI | Stop hook | agent self-watch | 自動打鍵 | 実際に配送を担うもの |
|-----|-----------|------------------|----------|----------------------|
| claude | ○ 実在 | ✕ 実在せぬ | ✕ 廃止 | **Stop hook のみ**(最大55秒の窓の内側だけ) |
| codex | ✕ 無い | ✕ 実在せぬ | ✕ 廃止 | ★**無い → 人経路** |
| opencode | ✕ 無い | ✕ 実在せぬ | ✕ 廃止 | ★**無い → 人経路** |
| copilot | ✕ 無い | ✕ 実在せぬ | ✕ 廃止 | ★**無い → 人経路** |
| kimi | ✕ 無い | ✕ 実在せぬ | ✕ 廃止 | ★**無い → 人経路** |

- ★`tmux send-keys` は**平常時も異常時も0**である。「最終手段としての打鍵」は
  存在しない。エスカレーションの段階は**「人へ上げるまでの猶予」だけ**を表す。
- ★agent 自前の self-watch は**実在しない**(2026-09-08 実測)。配送経路として
  数えてはならぬ。
- ★`clear_command` / `model_switch` / `cli_restart` は**自動では送られない**。
  `read: false` のまま保持され、人が当該 pane へ入力するまで実行されない。
- 正本: `docs/delivery_channels.md`

以下の FR/NFR・TC の期待値は、この現契約に同期済みである。TC ID は
トレーサビリティ維持のため変更していない。

---

## 1. 目的

本仕様書は、`reports/requirements_agent_selfwatch.md` で定義された FR/NFR を、
実装前に検証可能なテストケースへ分解する。

ゴール:
- FR/NFRごとにテストケースID・期待値を定義する
- ユニットテスト範囲（inbox処理・監視・競合制御・エスカレーション）を明確化する
- E2E範囲を「殿担当」として分離する

---

## 2. テストレベルと担当

| レベル | 名称 | 主担当 | 実行環境 | 用途 |
|---|---|---|---|---|
| L1 | Unit | 足軽（本件） | bats + bash + python3 | 関数/ロジック単体検証 |
| L2 | Integration | 家老 | L1 + tmux + inotify-tools | watcher/CLI境界の統合検証 |
| L3 | E2E | **殿担当** | 実運用tmux全体 | 指揮系統を含む完走確認 |

注記:
- `SKIP=0` は必須。SKIPが1以上なら「未完了」扱い。
- 本仕様書は Step 2 対象。実装・実行は後続 Step 3以降。

---

## 3. FRテストケース一覧

### 3.1 Phase 1

| TC ID | 要件 | レベル | 観点 | 期待値 |
|---|---|---|---|---|
| TC-FR-001 | FR-001 起動時未読回収 | L1 | 起動直後処理 | 未読ありで `process_unread_once` が1回動作し取りこぼし0 |
| TC-FR-002 | FR-002 self-watch監視 | L1/L2 | inotify+timeout | inotify欠落時でもtimeout経由で未読検知できる |
| TC-FR-003 | FR-003 type別処理 | L1 | message type分岐 | `task_assigned`/`clear_command`/`model_switch` が正しい処理レーンへ分岐 |
| TC-FR-004 | FR-004 排他整合 | L1/L2 | flock+atomic | 競合時でもYAML破損せず read更新が巻き戻らない |
| TC-FR-005 | FR-005 post-task inbox check | L1/L3 | 完了直後動作 | 完了直後に未読確認し、未読あり時はidle移行しない |
| TC-FR-006 | FR-006 可観測性メトリクス | L1 | metrics記録 | `unread_latency_sec`/`read_count`/`estimated_tokens` が算出可能 |
| TC-FR-007 | FR-007 Feature Flag移行 | L1/L2 | フラグ切替 | phase切替が有効、OFF時は現行互換モードへ戻る |

### 3.2 Phase 2

| TC ID | 要件 | レベル | 観点 | 期待値 |
|---|---|---|---|---|
| TC-FR-008 | FR-008 nudge全廃 | L1/L2 | send-keys不在 | ★あらゆるメッセージで `send-keys` が実行されない(実コードに1つも存在しない) |
| TC-FR-009 | FR-009 特殊コマンドの保持契約 | L1/L2 | 未送信時の扱い | `clear_command`/`model_switch`/`cli_restart` は★自動送信されず `read: false` のまま保持され、滞留として数えられる(既読化は送信確定・恒久skip・終端skipのときだけ) |
| TC-FR-010 | FR-010 summary-first | L1 | fast-path | unread_count=0時にfull read回避、必要時のみfull read |

### 3.3 Phase 3

| TC ID | 要件 | レベル | 観点 | 期待値 |
|---|---|---|---|---|
| TC-FR-011 | FR-011 send-keys全廃 | L1/L2 | 打鍵の不在 | ★平常時も異常時も send-keys 利用0。復旧経路は人経路(家老inbox → dashboard 🚨要対応、家老/将軍が対象なら ntfy)のみ |
| TC-FR-012 | FR-012 閾値再定義 | L1/L2 | エスカレーション | 閾値/cooldownは「人へ上げるまでの猶予」を表し、打鍵の強度を表さない。★特殊命令のみの未読でも閾値へ到達し、人へ一度は上がる |
| TC-FR-013 | FR-013 代替IPC評価フック | L1 | 拡張性 | YAML正本を崩さずPoC導入/撤回が可能 |

### 3.4 共通

| TC ID | 要件 | レベル | 観点 | 期待値 |
|---|---|---|---|---|
| TC-FR-014 | FR-014 後方互換IF | L1/L2 | インターフェース | inbox YAML schema / inbox_write IF / message type互換を維持 |
| TC-FR-015 | FR-015 実装/CI連携 | L1/L2 | 連携 | spec→bats→CI が同一IDでトレース可能 |

---

## 4. NFRテストケース一覧

| TC ID | 要件 | レベル | 観点 | 期待値 |
|---|---|---|---|---|
| TC-NFR-001 | NFR-001 信頼性 | L2/L3 | 未読喪失防止 | 未読メッセージ喪失0、再処理は冪等 |
| TC-NFR-002 | NFR-002 後方互換性 | L1/L2 | 回帰 | 既存inbox_write/既存YAMLで回帰なし |
| TC-NFR-003 | NFR-003 トークン効率 | L1/L2 | No Idle Read | idle時full readゼロ、推定tokens/dayが閾値内 |
| TC-NFR-004 | NFR-004 運用性 | L2 | 障害復旧 | 手順書のみで復旧可能、再現率100% |
| TC-NFR-005 | NFR-005 可搬性 | L2/L3 | 環境差分 | WSL2/Linux/Docker/SSH方針に矛盾がない |
| TC-NFR-006 | NFR-006 観測可能性 | L1 | ログ/指標 | 主要メトリクスが継続収集できる |
| TC-NFR-007 | NFR-007 保守性 | L1 | 責務分離 | watcher責務が肥大せず、標準経路/復旧経路が分離 |
| TC-NFR-008 | NFR-008 テスト容易性 | L1 | トレース | FR/NFR→TC→batsの対応表が欠落なし |

---

## 5. ユニットテスト範囲（Step 3対象）

## 5.1 inbox処理

- UT-INBOX-001: unread_count算出（空/既読のみ/混在）
- UT-INBOX-002: type別分岐（task_assigned/clear/model/unknown）
- UT-INBOX-003: read更新の冪等性（同一メッセージ再処理でも破壊なし）
- UT-INBOX-004: 起動時 `process_unread_once` の必須実行

期待値:
- unread算出誤差0
- unknown typeでも異常終了しない
- read更新後のYAML構造が有効

## 5.2 監視（self-watch）

- UT-WATCH-001: inotifyイベントで処理起動
- UT-WATCH-002: timeout fallbackで補足
- UT-WATCH-003: No Idle Readルール（idle時full read禁止）

期待値:
- event欠落があってもtimeoutで未読回収
- idle時に無駄なfull readを実行しない

## 5.3 競合制御

- UT-LOCK-001: flock競合時の安全リトライ
- UT-LOCK-002: atomic replace後もYAML破損なし
- UT-LOCK-003: 同時更新時の整合性（巻き戻りなし）

期待値:
- lock競合でも整合性を維持
- 破損YAMLを生成しない

## 5.4 エスカレーション

- UT-ESC-001: unread age に応じた段階遷移(★遷移するのは「人へ上げるまでの猶予」であって打鍵の強度ではない)
- UT-ESC-002: cooldown で★人への通知が連打されない(旧「/clear 連打の抑制」は /clear を送らぬため消滅)
- UT-ESC-003: busy 時は滞留時計を進めない(Claude は Stop hook が拾うため)
- UT-ESC-004: ★self-watch は実在しないため、配送経路として数えない。Claude のみ Stop hook へ委ねる
- UT-ESC-005: ★特殊命令のみが未読のとき、未配送カウンタがリセットされず複数周期で閾値へ到達する (cmd_754 redo1)
- UT-ESC-006: 全未読(特殊命令を含む)が0になったときだけ未配送カウンタがリセットされる

期待値:
- 時間条件に応じて★人経路へ上がる。打鍵は一切発火しない
- 特殊命令のみの滞留が「未読が捌けた」と誤認されない
- 未配送の連続回数が閾値へ到達し、人が必ず一度は知る

---

## 6. 統合テスト範囲（家老担当）

- IT-001: watcher + agent + inbox_write の連携
- IT-002: CLI別分岐（claude/codex/copilot）
- IT-003: ★全経路で send-keys 不在(通常・異常を問わず)
- IT-004: 障害注入時の復旧が★人経路(dashboard 🚨要対応 / ntfy)へ倒れること

期待値:
- ユニットでは見えない境界不整合が解消される
- エージェント間運用で再現性がある

---

## 7. E2E範囲（殿担当）

本仕様におけるE2Eは **殿担当** とし、家老/足軽は実施しない。

対象:
- E2E-001: Shogun→Karo→Ashigaruの全系統完走
- E2E-002: redo/clearを含む長時間運用
- E2E-003: 9エージェント並列時の安定性と未読滞留

期待値:
- 組織階層運用での実運用成立
- ★context reset は人が入力する前提で運用が回る(watcher は送らない)
- 届かぬ滞留が人経路へ確実に上がる
- 主要メトリクスが許容範囲に収まる

---

## 8. 前提条件（Preflight）

- `bash`, `python3`, `bats` が利用可能
- L2以上は `tmux`, `inotifywait` が利用可能
- テスト対象のqueue/testsパスへ読み書き可能

前提未充足時:
- 該当テストは実行せず、未充足理由を記録する
- SKIP報告は禁止（未完了として扱う）

---

## 9. FR/NFRトレース運用ルール

- batsテスト名にTC IDを埋め込む（例: `TC-FR-001`）
- テスト結果レポートは TC ID 単位で PASS/FAIL 記録
- 1要件1件以上のTCを維持（欠落禁止）

---

## 10. E2E実施ランブック（殿向け・時系列）

本節は `cmd_117` 要件「殿がE2Eテストを実施できる準備」を満たすための実行手順である。
実施順は固定し、途中で失敗した場合は当該行の診断に従って復旧してから再開する。

| 前提条件 | 手順 | 期待結果 | 失敗時診断 | 証跡 |
|---|---|---|---|---|
| Step 1: tmux基盤が起動済み | `tmux ls` を実行し、`shogun` と `multiagent` セッションを確認する。 | 2セッションが存在し、終了していない。 | セッション欠落時は `bash scripts/shohou/start_or_resume.sh` を実行し再確認。 | `tests/results/e2e_cmd117_step01_tmux_sessions.txt` |
| Step 2: 家老/足軽の監視プロセスが稼働中 | `pgrep -af \"inbox_watcher.sh|inotifywait\"` を実行する。 | 監視プロセスが確認できる。 | 監視が見えない場合は watcher 再起動後、`logs/` の直近エラーを確認。 | `tests/results/e2e_cmd117_step02_watchers.txt` |
| Step 3: E2E開始前に未読滞留が暴発していない | `for f in queue/inbox/*.yaml; do c=$(awk '/read: false/{n++} END{print n+0}' \"$f\"); echo \"$(basename \"$f\"):$c\"; done` を実行する。 | 実施対象エージェントの未読が許容範囲（原則0）である。 | 未読>0が残る場合は先に通常処理を完了させ、再度Step 3を実行。 | `tests/results/e2e_cmd117_step03_unread_baseline.txt` |
| Step 4: E2E-001（Shogun→Karo→Ashigaru全系統）を起動 | `bash scripts/inbox_write.sh karo \"cmd117_e2e_probe: chain test\" cmd_new shogun` を送信し、家老の処理と足軽タスク配備を確認する。 | 家老inboxが処理され、少なくとも1足軽へタスクが流れる。 | 2分以上変化がない場合は `queue/inbox/karo.yaml` と `logs/inbox_watcher/` を確認し、Phase 2/3 エスカレーション条件を点検。 | `tests/results/e2e_cmd117_step04_chain.md` |
| Step 5: E2E-002（redo/context reset系）を検証 | 対象足軽へ `clear_command` を送る（例: `bash scripts/inbox_write.sh ashigaru6 \"cmd117_e2e_probe redo\" clear_command karo`）。★watcher は自動では送らぬため、**殿ご自身が当該 pane へ context reset を入力**する（Claude/Copilot/Kimi → `/clear`、Codex/OpenCode → `/new`）。 | 送信直後は当該メッセージが `read: false` のまま保持され、滞留が家老 inbox（家老/将軍が対象なら ntfy）へ上がる。★殿が context reset を入力した後、対象足軽が task YAML を再読込し停止せず復帰する。 | 滞留通知が上がらない場合は `logs/inbox_watcher/` の `[NO-AUTO-SEND]` 行と未配送連続回数を確認。復帰しない場合は `queue/inbox/ashigaru6.yaml` の `read` 更新と task status を確認。★`read: true` へ勝手に変わっていたら「届かぬ命令を既読にした」不具合である。 | `tests/results/e2e_cmd117_step05_redo_clear.md` |
| Step 6: E2E-003（9エージェント並列安定性）を確認 | `tmux list-panes -t multiagent -F '#{pane_index}:#{pane_current_command}'` と Step 3 を再実行し、並列稼働中の滞留を確認する。 | 多重稼働でも未読滞留が連続増加しない。 | 滞留が増える場合は busy-skip/cooldown 条件の誤設定を確認し、該当agentログを採取。 | `tests/results/e2e_cmd117_step06_parallel_health.txt` |
| Step 7: E2E完了判定を記録 | `tests/results/e2e_cmd117_readiness.md` に E2E-001/002/003 の PASS/FAIL、阻害要因、再試行計画を記載する。 | 殿が次アクションを即決できる判定記録が完成する。 | 判定根拠が不足する場合は不足証跡を再取得してから記録を確定する。 | `tests/results/e2e_cmd117_readiness.md` |

---

以上をもって、`cmd_107` AC-2（テスト仕様書完成）および `cmd_117` の「E2E実施可能な手順整備」を満たす。
