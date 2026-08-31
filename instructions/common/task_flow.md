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
statuses — the work is finished or will never resume), Karo must move
the entire YAML entry to `queue/shogun_to_karo_archive.yaml`.

| Status | In active file? | Action |
|--------|----------------|--------|
| pending | YES | Keep |
| in_progress | YES | Keep |
| paused | YES | Keep (stopped but not abandoned; stays visible) |
| done | NO | Move to archive |
| cancelled | NO | Move to archive |

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
Step 9: Ashigaru completes → inbox_write karo → watcher nudges karo
  → Karo wakes, scans reports, acts
```

**Why no background monitor**: inbox_watcher.sh detects ashigaru's inbox_write to karo and sends a nudge. This is true event-driven. No sleep, no polling, no CPU waste.

**Karo wakes via**: inbox nudge from ashigaru report, shogun new cmd, or system event. Nothing else.

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
- Ask the Lord before any `git push`.

Minimum local checks:
```bash
# Unit tests (same as CI)
bats tests/*.bats tests/unit/*.bats

# Instruction generation must be in sync (same as CI "Build Instructions Check")
bash scripts/build_instructions.sh
git diff --exit-code instructions/generated/
```
