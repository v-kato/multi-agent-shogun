# Claude Code Tools

This section describes Claude Code-specific tools and features.

## Tool Usage

Claude Code provides specialized tools for file operations, code execution, and system interaction:

- **Read**: Read files from the filesystem (supports images, PDFs, Jupyter notebooks)
- **Write**: Create new files or overwrite existing files
- **Edit**: Perform exact string replacements in files
- **Bash**: Execute bash commands with timeout control
- **Glob**: Fast file pattern matching with glob patterns
- **Grep**: Content search using ripgrep
- **Task**: Launch specialized agents for complex multi-step tasks
- **WebFetch**: Fetch and process web content
- **WebSearch**: Search the web for information

## Tool Guidelines

1. **Read before Write/Edit**: Always read a file before writing or editing it
2. **Use dedicated tools**: Don't use Bash for file operations when dedicated tools exist (Read, Write, Edit, Glob, Grep)
3. **Parallel execution**: Call multiple independent tools in a single message for optimal performance
4. **Avoid over-engineering**: Only make changes that are directly requested or clearly necessary

## Task Tool Usage

The Task tool launches specialized agents for complex work:

- **Explore**: Fast agent specialized for codebase exploration
- **Plan**: Software architect agent for designing implementation plans
- **general-purpose**: For researching complex questions and multi-step tasks
- **Bash**: Command execution specialist

Use Task tool when:
- You need to explore the codebase thoroughly (medium or very thorough)
- Complex multi-step tasks require autonomous handling
- You need to plan implementation strategy

## Memory MCP

Save important information to Memory MCP:

```python
mcp__memory__create_entities([{
    "name": "preference_name",
    "entityType": "preference",
    "observations": ["Lord prefers X over Y"]
}])

mcp__memory__add_observations([{
    "entityName": "existing_entity",
    "contents": ["New observation"]
}])
```

Use for: Lord's preferences, key decisions + reasons, cross-project insights, solved problems.

Don't save: temporary task details (use YAML), file contents (just read them), in-progress details (use dashboard.md).

## Model Switching

Ashigaru models are set in `config/settings.yaml` and applied at startup.
Runtime switching is available but rarely needed (Gunshi handles L4+ tasks instead):

```bash
# Manual override only — not for Bloom-based auto-switching
bash scripts/inbox_write.sh ashigaru{N} "/model <new_model>" model_switch karo
tmux set-option -p -t multiagent:0.{N} @model_name '<DisplayName>'
```

For Ashigaru: You don't switch models yourself. Karo manages this.

## /clear Protocol

For Karo only: Queue a context reset **request** for ashigaru:

```bash
bash scripts/inbox_write.sh ashigaru{N} "タスクYAMLを読んで作業開始せよ。" clear_command karo
```

`clear_command` は★自動で送信される(CLI別: Claude/Copilot/Kimi→`/clear`、
Codex/OpenCode→`/new`としてpaneへ直接打鍵される)。送信前に対象paneへ
確認モーダルが表示されていないか確認すること(モーダル表示中はnudgeの
Enterが既定選択肢を誤って押す危険があるため。詳細はCLAUDE.md
「Delivery Mechanism」節)。

送信後、inbox_watcherが`[auto-recovery] task_assigned`を自動投入する。
投入内容は永続化されるが、起床(即時の気づき)はベストエフォート(nudge)
または確定的だがターン終了時点の遅延を伴う経路(Stop hook)によるもので
あり、確実ではない。

For Ashigaru: After the context reset is entered, follow CLAUDE.md /clear recovery procedure. Do NOT read instructions/ashigaru.md for the first task (cost saving).

## Compaction Recovery

All agents: Follow the Session Start / Recovery procedure in CLAUDE.md. Key steps:

1. Identify self: `tmux display-message -t "$TMUX_PANE" -p '#{@agent_id}'`
2. `mcp__memory__read_graph` — restore rules, preferences, lessons
3. Read your instructions file (shogun→instructions/shogun.md, karo→instructions/generated/karo.md, ashigaru→instructions/ashigaru.md)
4. Rebuild state from primary YAML data (queue/, tasks/, reports/)
5. Review forbidden actions, then start work
