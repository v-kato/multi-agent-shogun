# Task Flow

## Workflow: Shogun → Karo → Ashigaru

```
Lord: command → Shogun: write YAML → inbox_write → Karo: decompose → inbox_write → Ashigaru: execute → report YAML → inbox_write → Karo: update dashboard → Shogun: read dashboard
```

## Status Reference (Single Source)

Status is defined per YAML file type. **Keep it minimal. Simple is best.**

Fixed status set (do not add casually):
- `queue/shogun_to_karo.yaml`: `pending`, `in_progress`, `done`, `cancelled`, `paused`
- `queue/tasks/ashigaruN.yaml`: `assigned`, `blocked`, `done`, `failed`
- `queue/tasks/pending.yaml`: `pending_blocked`
- `queue/ntfy_inbox.yaml`: `pending`, `processed`

Do NOT invent new status values without updating this section.

### Command Queue: `queue/shogun_to_karo.yaml`

Meanings and allowed/forbidden actions (short):

- `pending`: not acknowledged yet
  - Allowed: Karo reads and immediately ACKs (`pending → in_progress`)
  - Forbidden: dispatching subtasks while still `pending`

- `in_progress`: acknowledged and being worked
  - Allowed: decompose/dispatch/collect/consolidate
  - Forbidden: moving goalposts (editing acceptance_criteria), or marking `done` without meeting all criteria

- `done`: complete and validated
  - Allowed: read-only (history)
  - Forbidden: editing old cmd to "reopen" (use a new cmd instead)

- `cancelled`: intentionally stopped
  - Allowed: read-only (history)
  - Forbidden: continuing work under this cmd (use a new cmd instead)

- `paused`: ACKed but deliberately stopped, not abandoned
  - Allowed: Karo/Shogun resumes by moving back to `in_progress` (or
    `pending` if re-ACK is needed) when priority returns
  - Forbidden: continuing work under this cmd while still `paused`;
    archiving it (stays in the active file — see Archive Rule below)

### Archive Rule

The active queue file (`queue/shogun_to_karo.yaml`) must contain
`pending`, `in_progress`, and `paused` entries. Only `done` and
`cancelled` are archived.

`paused` is deliberately kept in the active file even though the work
is stopped: archiving it would make stopped-but-not-abandoned work
invisible. This is the exact failure the Lord hit on 2026-08-20 — 8
unclosed cmds sitting where nobody could see them because they had
been archived out of the active file. Paused work must stay visible
until it is resumed or explicitly cancelled.

When a cmd reaches `done` or `cancelled` (the only truly terminal
statuses — the work is finished or will never resume), the entire
YAML entry is moved to `queue/shogun_to_karo_archive.yaml`. ★Since
cmd_707 (2026-08-19), this move is Shogun's responsibility, not
Karo's. Karo's part ends at updating the entry's `status` to `done`/
`cancelled` via `shogun_to_karo_lock.sh update`. Before that update
(after Gunshi QC PASS) comes step 0, the OSS-side develop commit
(cmd_788 — "Commit gate for OSS-side deliverables" below); after it
come Karo's usual completion steps (dashboard ✅戦果 → privategit
commit/push → ntfy) — see `instructions/roles/karo_role.md`
"Archive on Completion" for Karo's exact steps.

| Status | In active file? | Action | Actor |
|--------|----------------|--------|-------|
| pending | YES | Keep | — |
| in_progress | YES | Keep | — |
| paused | YES | Keep (stopped but not abandoned; stays visible) | — |
| done | NO | Move to archive | Shogun |
| cancelled | NO | Move to archive | Shogun |

**Canonical statuses (exhaustive list — do NOT invent others)**:
- `pending` — not started
- `in_progress` — acknowledged, being worked
- `done` — complete (covers former "completed", "superseded", "active")
- `cancelled` — intentionally stopped, will not resume (covers former
  "deprecated")
- `paused` — ACKed but deliberately stopped, not abandoned, may
  resume later (covers former "on_hold", "deprioritized"). Stays in
  the active file — never archived while still `paused` (see Archive
  Rule above).

Any other status value (e.g., `completed`, `active`, `superseded`,
`on_hold`, `deprioritized`, `deprecated`) is forbidden. If found
during archive or audit, normalize to the canonical set above and
record the original value + mapping reason on the entry (e.g. in a
`karo_note` field) rather than silently overwriting it.

### Status Vocabulary Authority (established cmd_714, 2026-08-20)

An audit (cmd_714, 2026-08-20) found three different status
vocabularies in disagreement at the same time: this file's own "Fixed
status set" above (4 values, no `paused`) vs. its own "Canonical
statuses" list (5 values, `paused` included) vs. `scripts/slim_yaml.py`,
whose `ACTIVE_STATUSES` has no `paused` at all (only `blocked`) while
its separate `TERMINAL_STATUSES` does include `paused` vs. the live
`queue/shogun_to_karo.yaml`, which had 3 commands (`cmd_493`,
`cmd_349`, `cmd_361`) using `on_hold` / `deprioritized` / `deprecated`
— none of which appear in any canonical list anywhere. cmd_710 Phase
B's redo cycle failed 3 rounds in a row specifically on cmd_493's
classification wording, precisely because the three "source of
truth" documents didn't agree with each other.

**Resolution: this file (`instructions/common/task_flow.md`) is the
single source of truth for status vocabulary.** Code
(`scripts/slim_yaml.py` and any future equivalent) must follow the
vocabulary defined here, not the reverse. When code and this file
disagree, either fix the code to match this file, or propose a change
to this file first (subject to Shogun approval per the Destructive
Operation Safety / broad-impact-change norm) — never just let the
code's current behavior stand as a silent second vocabulary.

**Karo rule (ack fast)**:
- The moment Karo starts processing a cmd (after reading it), update that cmd status:
  - `pending` → `in_progress`
  - This prevents "nobody is working" confusion and stabilizes escalation logic.

### Ashigaru Task File: `queue/tasks/ashigaruN.yaml`

Meanings and allowed/forbidden actions (short):

- `assigned`: start now
  - Allowed: assignee ashigaru executes and updates to `done/failed` + report + inbox_write
  - Forbidden: other agents editing that ashigaru YAML

- `blocked`: do NOT start yet (prereqs missing)
  - Allowed: Karo unblocks by changing to `assigned` when ready, then inbox_write
  - Forbidden: nudging or starting work while `blocked`

- `done`: completed
  - Allowed: read-only; used for consolidation
  - Forbidden: reusing task_id for redo (use redo protocol)

- `failed`: failed with reason
  - Allowed: report must include reason + unblock suggestion
  - Forbidden: silent failure

Note:
- Normally, "idle" is a UI state (no active task), not a YAML status value.
- Exception (placeholder only): `status: idle` is allowed **only** when `task_id: null` (clean start template written by `shutsujin_departure.sh --clean`).
  - In that state, the file is a placeholder and should be treated as "no task assigned yet".

### working_dir フィールド (作業ツリー排他制御, cmd_695)

`queue/tasks/ashigaruN.yaml` の `task:` ブロックが持てる任意フィールド。

- **値がある場合**: そのタスクが占有する作業ツリーの絶対パス
  (例: git checkout・ローカルサーバ起動・実機検証を伴うタスク)。
- **省略した場合**: そのタスクは作業ツリーを占有しない、という意味。
  既存タスクYAML(本フィールド導入前に書かれたもの)は全てこの意味
  として扱われ、遡及的な付与は不要かつ行わない。
- **`working_dir_released: true`**: `status: done` または `status:
  failed` と同時に足軽が明記する。そのworking_dirを使うプロセス
  (dev server・electron等)を残さず終了した場合に限り付与する。
  無ければ `done`/`failed` いずれになっても「占有継続中」として
  扱われる(fail-safe)。

家老の割当時チェック規則(割当先自身の検査・`failed` の扱い・
path正規化を含む)は `instructions/common/protocol.md` の
「Task Working Directory Exclusivity」参照。

### parallelizable フィールド (足軽内部の並行化, cmd_780)

`queue/tasks/ashigaruN.yaml` の `task:` ブロックが持てる任意フィールド。
**家老の並行化(複数の足軽へ分割)とは別の判断**であり、足軽1体の内側で
SubAgent・別プロセスagentを使わせるときだけ書く。

```yaml
task:
  task_id: subtask_xxx
  # ... 既存フィールド ...
  parallelizable:
    allowed: true                # 必須。false または欄ごと省略 = 並行化しない
    branches:                    # allowed: true のとき必須
      - id: b1
        description: "docs/ 配下から X の定義を探す"
        outputs: ["(要約のみ・ファイル出力なし)"]
      - id: b2
        description: "scripts/ 配下から X の呼び出し箇所を数える"
        outputs: ["tmp/cmd_xxx_b2_count.txt"]
    max_concurrent: 2            # 上限は 3 (cmd_780 Phase D 暫定値)
    mechanisms: [A-1, A-3]       # 任意。省略時は A-1 のみ
    notes: "b1/b2 は互いに触れない。統合は足軽本体が単独で行う"   # 任意
```

| 欄 | 必須 | 意味 |
|----|------|------|
| `allowed` | ○ | `true` のときのみ並行化してよい。`false` または欄の省略は「並行化しない」 |
| `branches` | `allowed: true` のとき○ | 枝の一覧。家老は枝を切る時点で PAR-5(2) の Q1〜Q5 をすべて「いいえ」にしておく。`outputs` は枝ごとに**別 path** とする |
| `max_concurrent` | ○ | 同時に走らせる子の数の上限。★**3を超えない**(1〜3体の実測に基づく暫定値・4体以上は未実測)。3と枝数のいずれをも超えないタスク別の値を家老が明記する |
| `mechanisms` | — | 許可する機構の略号。省略時は **A-1(汎用SubAgent)のみ**。A-2 `fork`・D-2 headless を使わせる場合は明示が必須。★これは**承認欄**であり、PAR-4(0)(同一turn内で完了まで待つ)を**免除しない** |
| `notes` | — | 枝どうしが触れない根拠、統合の担当など |

- **省略した場合**: そのタスクは並行化しない、という意味。既存タスクYAML
  (本フィールド導入前に書かれたもの)は全てこの意味として扱われ、遡及的な
  付与は不要かつ行わない(`working_dir` の前例に倣う)。
- `allowed: true` であっても、足軽が PAR-5 の判定で危険と見たときは**単独で
  実行してよい**(安全側への逸脱は常に許される)。その場合は報告に理由を書く。
- Workflow を許可する場合は `parallelizable` とは別に
  `workflow: {allowed: true, max_agents: N, reason: ...}` を置く。★この欄が
  あっても**userの明示 opt-in** が確認できなければ足軽は Workflow を呼ばない。
  ★さらにこの欄は**承認欄**であり、PAR-4(0)(子が動いているまま親のturnを
  終えない=同一turn内で完了まで待つ)を**免除しない**。承認4条件がすべて
  揃っても、同一turn内で完了まで待てる根拠が無い現状では足軽は Workflow を
  **呼ばない**(PAR-3-e)。欄を書く側もそれを前提とすること。

規則本文(PAR-1〜PAR-5)は `instructions/common/parallelization_rules.md` を正本とする。

### Pending Tasks (Karo-managed): `queue/tasks/pending.yaml`

- `pending_blocked`: holding area; **must not** be assigned yet
  - Allowed: Karo moves it to an `ashigaruN.yaml` as `assigned` after prerequisites complete
  - Forbidden: pre-assigning to ashigaru before ready

### NTFY Inbox (Lord phone): `queue/ntfy_inbox.yaml`

- `pending`: needs processing
  - Allowed: Shogun processes and sets `processed`
  - Forbidden: leaving it pending without reason

- `processed`: processed; keep record
  - Allowed: read-only
  - Forbidden: flipping back to pending without creating a new entry

## Immediate Delegation Principle (Shogun)

**Delegate to Karo immediately and end your turn** so the Lord can input next command.

```
Lord: command → Shogun: write YAML → inbox_write → END TURN
                                        ↓
                                  Lord: can input next
                                        ↓
                              Karo/Ashigaru: work in background
                                        ↓
                              dashboard.md updated as report
```

## Event-Driven Wait Pattern (Karo)

**After dispatching all subtasks: STOP.** Do not launch background monitors or sleep loops.

```
Step 7: Dispatch cmd_N subtasks → inbox_write to ashigaru
Step 8: check_pending → if pending cmd_N+1, process it → then STOP
  → Karo becomes idle (prompt waiting)
Step 9: Ashigaru completes → inbox_write karo → 家老の Stop hook が未読を拾う
  → Karo wakes, scans reports, acts
```

**Why no background monitor**: 家老(Claude)は Stop hook がターン終了時に未読を
拾って起こす。これも event-driven であり、sleep も polling も要らぬ。
nudge(`inboxN`打鍵)も★実際に送信され、Stop hookと併存する(他のClaude系
エージェントと同様。詳細は`instructions/common/protocol.md`の「Delivery
Mechanism」節)。家老はcommand-layer agentゆえ、watcherは2〜4分でも
Escape+nudgeに留まり(`/clear`は送らない)、4分を過ぎても打鍵自体は
続く。★Stop hook の窓(1回あたり最大55秒)を過ぎて完全に idle になった
後は、これらの打鍵が届かない限り自動では気づけない。ntfyで殿へ上げるのは
watcherの自動処理ではなく、家老自身が滞留に気づいた際に判断して
`scripts/ntfy.sh`を手動実行する人経路である。

**Karo wakes via**: nudge(`inboxN`打鍵)・Stop hook が拾う inbox 未読
(足軽報告・将軍の新cmd)、または殿/将軍の直接入力のいずれか。

## "Wake = Full Scan" Pattern

Claude Code cannot "wait". Prompt-wait = stopped.

1. Dispatch ashigaru
2. Say "stopping here" and end processing
3. Ashigaru wakes you via inbox
4. Scan ALL report files (not just the reporting one)
5. Assess situation, then act

## Report Scanning (Communication Loss Safety)

On every wakeup (regardless of reason), scan ALL `queue/reports/ashigaru*_report.yaml`.
Cross-reference with dashboard.md — process any reports not yet reflected.

**Why**: Ashigaru inbox messages may be delayed. Report files are already written and scannable as a safety net.

## Foreground Block Prevention (24-min Freeze Lesson)

**Karo blocking = entire army halts.** On 2026-02-06, foreground `sleep` during delivery checks froze karo for 24 minutes.

**Rule: NEVER use `sleep` in foreground.** After dispatching tasks → stop and wait for inbox wakeup.

| Command Type | Execution Method | Reason |
|-------------|-----------------|--------|
| Read / Write / Edit | Foreground | Completes instantly |
| inbox_write.sh | Foreground | Completes instantly |
| `sleep N` | **FORBIDDEN** | Use inbox event-driven instead |
| tmux capture-pane | **FORBIDDEN** | Read report YAML instead |

### Dispatch-then-Stop Pattern

```
✅ Correct (event-driven):
  cmd_008 dispatch → inbox_write ashigaru → stop (await inbox wakeup)
  → ashigaru completes → inbox_write karo → karo wakes → process report

❌ Wrong (polling):
  cmd_008 dispatch → sleep 30 → capture-pane → check status → sleep 30 ...
```

## Timestamps

**Always use `date` command.** Never guess.
```bash
date "+%Y-%m-%d %H:%M"       # For dashboard.md
date "+%Y-%m-%dT%H:%M:%S"    # For YAML (ISO 8601)
```

## Pre-Commit Gate (CI-Aligned)

Rule:
- Run the same checks as GitHub Actions *before* committing.
- Only commit when checks are OK.
- Ask the Lord before any `git push`. ★push only: a local commit to
  `develop` is part of the completion SOP and needs no approval (F007).

Minimum local checks:
```bash
# Unit tests (same as CI)
bats tests/*.bats tests/unit/*.bats

# Instruction generation must be in sync (same as CI "Build Instructions Check")
bash scripts/build_instructions.sh
git diff --exit-code instructions/generated/ .opencode/agents/
```

### Commit gate for OSS-side deliverables (cmd_788・完了SOP step 0)

責任者=家老・実作業=足軽・時点=軍師QC PASS後で`done`化の前(役割分担は
`instructions/roles/karo_role.md`「OSS側成果物のdevelop commit」)。ここは通すgateの正本である。
実作業の足軽は各gateの証跡をreportへ載せる。件数は必ずディレクトリ別に報告する(総数のみ禁止)。

★根拠(殿の指示 2026-09-30): originは公開リポジトリである。shogunシステムに関するものだけを
置き、個別業務に由来する名称を混入させない。何が是正対象で何が残留してよいかは、殿確定
(2026-09-30)により次のとおり。
- **是正対象(混入させない・走査0件が合格)**: 業務で用いた固有名詞(プロジェクト・商品・顧客・
  取引先・倉庫・店舗・Google Chat space名・人名等)と、自社ドメイン以外の業務繋がりのドメイン・
  メールアドレス。
- **残留許容(対象外・走査で数えず是正もしない・新規に追加してもよい)**: ①個人環境のhome path
  (`/home/kato`)、②`cmd_xxx`形式のcmd識別子、③`v-sync.co.jp`のアドレス(自社ドメイン。
  `局部@v-sync.co.jp`と、URL等に現れる単独の`v-sync.co.jp`)。許容はこの3種だけである。
  ★許容は表記そのものだけを指す。自社ドメインを含んでいても、組織名だけの記述・サブドメイン・
  局部に是正対象の語を含むアドレスは許容ではなく、走査で検出される。具体的な表記と走査上の
  扱いは正本リストが定める。

1. **追跡確認(commit前)**: 新規`lib/*.sh`・`scripts/*.sh`・`tests/**`・`docs/**`が追跡できるか
   確認する。`.gitignore`は`*`で全除外し、許可行(`!lib/x.sh`等)のものだけを追跡する
   ホワイトリスト方式であり、許可行の無い新規ファイルは`git status`に現れず棚卸しから漏れる
   (許可行だけcommitして本体をadd漏れした例と、許可行そのものが無かった例が実際に起きた)。
   ```bash
   bash scripts/check_tracked.sh <path>...   # path別に IGNORED/MISSING/UNTRACKED/STAGED/COMMITTED を表示
   ```
   `IGNORED`・`MISSING`は常にNG(非0)。`IGNORED`の新規pathには`.gitignore`へ許可行を足す。
   **許可行の追加も成果物に含める**。
   ★手で確かめるときも、追跡の判定に`git check-ignore -v`の終了コードを使わない。`-v`は許可行
   (`!`始まりの否定規則)に一致したpathでもその規則を表示して終了コード0を返すため、許可行で
   再包含したファイルを「無視されている」と取り違える。判定は`git check-ignore -q`の終了コード
   (0=無視/1=無視されない)で行い、`-v`は無視と分かった後の規則表示にだけ使う。gitの終了コードが
   0・1以外(128等)なら判定不能であり、「無視されない」と読み替えず失敗として扱う(道具は終了コード2)。
   HEADの有無の確認(`git rev-parse --verify --quiet HEAD`)も同じで、0=あり・1=なし(未commitの
   新規repoの正常な状態)、それ以外は「HEADなし」と読み替えず判定不能の失敗として扱う(同じく終了コード2)。
2. **path明示のadd**: `git add -- <path>...`(`git add -A`・`git add .`は禁止)。
   `git diff --cached --name-only`が計画のpath一覧と一致し、`node_modules/`・`tmp/`・
   privategit専用のskill配下が0件であること。
3. **禁則語走査(commit直前・0件が合格)**: 追加行とcommit messageを走査する。
   ```bash
   bash scripts/public_repo_scan.sh --staged --message-file <msg_file>
   # --staged=git diff -U0 --cached の追加行 / --message-file=commit message案(#始まりの行も走査)
   ```
   終了コード0(ヒット0件)が合格。1(ヒットあり)・2(使い方誤り・実行失敗)はFAIL。出力に付く
   トップディレクトリ別のヒット件数を、そのままreportへ転記する。
   走査は上記の残留許容3種(`/home/kato`・`cmd_xxx`・`v-sync.co.jp`のアドレス)を数えない。許容の
   表記だけを含む行はヒット0件になる。許容の表記と是正対象の語が同じ行に混在する場合は、
   是正対象の語で検出される(許容を除いて数えるだけで、是正対象の語まで消しはしない)。
   ★是正対象の分担: 「業務で用いた固有名詞」は禁則語で検出する(公開側の正本は具体語を持たない
   番兵のみで、具体語はローカル拡張だけが持つ)。
   「`v-sync.co.jp`以外の業務繋がりのドメイン・メールアドレス」は、業務繋がりかを機械では判定
   できない(判定できるのは許可ドメインの一覧にあるかだけ)ため、許可ドメイン外のアドレスを
   「要確認(WARN)」として別に出力し、人の目視へ回す。WARNだけでは終了コード・ヒット件数を
   変えない(NGにすると、メールでない文字列や第三者の公開アドレスまで止めてcommitが滞留する)。
   WARNの出力行は0件でも1行出る(走査した上での0)。WARNが出たら、業務繋がりのアドレスかを目視
   で確かめ、業務繋がりなら中立表現へ直し、reportにWARNの件数(ディレクトリ別)と各件の判断
   (要対応/非該当)を載せる。許可ドメインの追加は、正本リストのブロックへ根拠のコメントを
   添えて行う。
   禁則語の正本リストは`instructions/common/public_repo_forbidden_words.md`の1箇所のみ(ここへ
   語を転記しない)。取引先名などの具体名は、git管理外の
   `config/public_repo_forbidden_words.local.txt`へ置き、公開側のリストには書かない。★このローカル
   拡張は走査に必須である: 無い(または有効な語が0行の)ときは、公開側が番兵のみなので走査は黙って
   通さず終了コード2で止まる(fail-closed・cmd_797)。走査は`/usr/bin/grep`をフルパスで呼ぶ(シェル関数版grepはgitignore領域を黙って
   素通りする)。1件でも出たらcommitせず、中立表現へ直して再走査する。commit後の検収では
   `--range <commit前のHEAD>..HEAD`で範囲内の全追加行と全messageを再走査できる(merge commit
   自身の差分は対象外)。公開木全体の最終確認は`--tree HEAD`(追跡木の本文・バイナリ除外)。
   ★限界と注意: (a)走査するのは追加行・追跡木の本文・commit messageで、**path名(ファイル名)は
   走査しない**。業務名を含む名前の新規ファイルはこの道具では検出できないので、`git diff --cached
   --name-only`を目視する。(b)走査の出力にはヒット行(禁則語そのもの)が含まれる。**走査ログを
   commit・公開する成果物(OSS側の追跡ファイル)へ入れない**。(c)取引先名・倉庫名・店舗名等の
   具体名は、ローカル拡張に載せた語しか検出できない。ローカル拡張が無いときは走査が終了コード2で
   止まり、0件で通ることはない。拡張が在って0件でも、それは「拡張に載せた語が無い」ことしか意味せず、
   載っていない未知の固有名詞が無い証明ではない。reportにそう明記し、追加行を目視する。
4. **commit(pushしない)**: `git commit -F <msg_file>`。messageは日本語・cmd_id・機能名のみ。
5. **commit後の追跡確認**: `git ls-tree -r --name-only HEAD -- <path>...`が計画の全pathを返す
   こと(新規ファイルが実際にHEADへ入った証拠)。`bash scripts/check_tracked.sh
   --require-committed <path>...`が終了コード0でも同じ確認になる。
6. **clean archive build(cmd完了前・`done`化の前)**: 追跡木だけからbuildし、生成物のdiffが0で
   あること。作業木でのbuildは、未追跡の必須入力があっても通ってしまうため代わりにならない
   (cmd_786 §2のT2〜T4方式)。CIの検査対象(`instructions/generated/`・`.opencode/agents/`)に、
   CLAUDE.md派生の3ミラーを加えた33ファイルを照合する。
   ```bash
   gate=$(mktemp -d /tmp/gate.XXXXXX)   # 絶対パスtemplate・変数へ即捕捉(D002-E1(b))
   git archive HEAD | tar -x -C "$gate"
   GEN='instructions/generated .opencode/agents AGENTS.md .github/copilot-instructions.md agents/default/system.md'
   ( cd "$gate" && find $GEN -type f -exec sha256sum {} + | sort -k2 > "$gate.before" \
     && bash scripts/build_instructions.sh > "$gate.build.log" 2>&1 \
     && find $GEN -type f -exec sha256sum {} + | sort -k2 > "$gate.after" ) \
     && cmp "$gate.before" "$gate.after" && echo "生成物 diff 0"
   ```
   buildが非0で終わるか、`生成物 diff 0`が出なければFAIL。★展開先`$gate`の削除は書かない
   (`/tmp`は再起動で片付く。Tooling Pitfalls 5)。
7. **失敗時**: commit後にgate 5・6が落ちたら、`git reset --hard`(D004)やamendで巻き戻さず、
   追加commitで是正してgate 6をやり直す。
