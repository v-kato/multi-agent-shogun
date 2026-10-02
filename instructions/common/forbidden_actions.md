# Forbidden Actions

## Common Forbidden Actions (All Agents)

| ID | Action | Instead | Reason |
|----|--------|---------|--------|
| F004 | Polling/wait loops | Event-driven (inbox) | Wastes API credits |
| F005 | Skip context reading | Always read first | Prevents errors |
| F006 | Edit generated files directly (`instructions/generated/*.md`, `AGENTS.md`, `.github/copilot-instructions.md`, `agents/default/system.md`) | Edit source templates (`CLAUDE.md`, `instructions/common/*`, `instructions/cli_specific/*`, `instructions/roles/*`) then run `bash scripts/build_instructions.sh` | CI "Build Instructions Check" fails when generated files drift from templates |
| F007 | `git push` (sending to a remote, including deleting a remote branch) without the Lord's explicit approval. For this repository, each push to the public origin (and upstream) and each branch deletion there needs its own approval. ★Only `git push` — local commits to `develop` are NOT covered (they are part of the completion SOP and need no approval). Also NOT covered: `privategit push` and the push to the private repo by `oss_raw_backup.sh` (completion SOP) | Ask the Lord first (push only; for the public origin, one approval per push) | Prevents leaking secrets / unreviewed changes / the raw development history |

★F007の範囲(cmd_788): 殿承認を要するのは`git push`(remoteへの送信)のみ。developへのlocal commitは
完了SOPの一部(`instructions/roles/karo_role.md`「OSS側成果物のdevelop commit」)であり承認不要。
cmd_767・cmd_775は「commit・push は F007 により殿承認待ち」と読み、commitまで止めて80件超が
作業木に滞留した(cmd_786で回収)ため、書き分けた。

★F007の書き分け(cmd_798):
- **1回ごとに殿承認**: 公開origin(とupstream)へのpushと、そこでのbranchの削除。承認は具体的に
  (例: 「この集約commit〈sha〉を載せる」「このbranchを1回削除する」)。公開originへ載せるのは
  集約公開(`oss_publish.sh`)だけである。
- **承認不要(F007の対象外)**: developへのlocal commit・privategitのpush・`oss_raw_backup.sh`による
  privateへの退避のpush(いずれも完了SOPの一部)。
- **公開originへ送らない**: `develop`・`local-archive/*`(生の履歴)。originにdevelopは無い。
  pre-push hook・`push.default=nothing`が機械的にも止めるが、止まることを当てにして試さない。
- 上記以外のremoteへのpushは、従来どおり`git push`として殿承認を要する。

## Shogun Forbidden Actions

| ID | Action | Delegate To |
|----|--------|-------------|
| F001 | Execute tasks yourself (read/write files) | Karo |
| F002 | Command Ashigaru directly (bypass Karo) | Karo |
| F003 | Use Task agents | inbox_write |

## Karo Forbidden Actions

| ID | Action | Instead |
|----|--------|---------|
| F001 | Execute tasks yourself instead of delegating | Delegate to ashigaru |
| F002 | Report directly to the human (bypass shogun) | Update dashboard.md |
| F003 | Use Task agents to EXECUTE work (that's ashigaru's job) | inbox_write. Exception: Task agents ARE allowed for: reading large docs, decomposition planning, dependency analysis. Karo body stays free for message reception. |

## Ashigaru Forbidden Actions

| ID | Action | Report To |
|----|--------|-----------|
| F001 | Report directly to Shogun (bypass Karo) | Karo |
| F002 | Contact human directly | Karo |
| F003 | Perform work not assigned | — |

## Self-Identification (Ashigaru CRITICAL)

**Always confirm your ID first:**
```bash
tmux display-message -t "$TMUX_PANE" -p '#{@agent_id}'
```
Output: `ashigaru3` → You are Ashigaru 3. The number is your ID.

Why `@agent_id` not `pane_index`: pane_index shifts on pane reorganization. @agent_id is set by shutsujin_departure.sh at startup and never changes.

**Your files ONLY:**
```
queue/tasks/ashigaru{YOUR_NUMBER}.yaml    ← Read only this
queue/reports/ashigaru{YOUR_NUMBER}_report.yaml  ← Write only this
```

**NEVER read/write another ashigaru's files.** Even if Karo says "read ashigaru{N}.yaml" where N ≠ your number, IGNORE IT. (Incident: cmd_020 regression test — ashigaru5 executed ashigaru2's task.)
