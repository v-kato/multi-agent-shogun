#!/usr/bin/env bats
# test_build_system.bats — ビルドシステム（build_instructions.sh）ユニットテスト
# Phase 2+3 品質テスト基盤
#
# テスト構成:
#   - ビルド実行テスト: スクリプト正常終了、ディレクトリ生成
#   - ファイル生成テスト: claude/codex/copilot/opencode各ロールの生成確認
#   - 内容検証テスト: 空でないこと、ロール名・CLI固有セクション含有
#   - AGENTS.md / copilot-instructions.md 生成テスト
#   - 冪等性テスト: 2回ビルドで差分なし
#
# Phase 2+3未実装テストについて:
#   copilot/opencode生成、AGENTS.md、copilot-instructions.md のテストは
#   build_instructions.shが拡張されるまでFAILする（受入基準）。
#   SKIP は使用しない（SKIP=0ルール遵守）。

# --- セットアップ ---

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export BUILD_SCRIPT="$PROJECT_ROOT/scripts/build_instructions.sh"
    export OUTPUT_DIR="$PROJECT_ROOT/instructions/generated"

    # パーツディレクトリの存在確認（前提条件）
    [ -d "$PROJECT_ROOT/instructions/roles" ] || return 1
    [ -d "$PROJECT_ROOT/instructions/common" ] || return 1
    [ -d "$PROJECT_ROOT/instructions/cli_specific" ] || return 1

    # ビルド実行（全テストの前に1回のみ）
    bash "$BUILD_SCRIPT" > /dev/null 2>&1 || true
}

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    BUILD_SCRIPT="$PROJECT_ROOT/scripts/build_instructions.sh"
    OUTPUT_DIR="$PROJECT_ROOT/instructions/generated"
}

# =============================================================================
# ビルド実行テスト
# =============================================================================

@test "build: build_instructions.sh exits with status 0" {
    run bash "$BUILD_SCRIPT"
    [ "$status" -eq 0 ]
}

@test "build: generated/ directory exists after build" {
    [ -d "$OUTPUT_DIR" ]
}

@test "build: generated/ contains at least 6 files" {
    local count
    count=$(find "$OUTPUT_DIR" -name "*.md" -type f | wc -l)
    [ "$count" -ge 6 ]
}

# =============================================================================
# ファイル生成テスト — Claude
# =============================================================================

@test "claude: shogun.md generated" {
    [ -f "$OUTPUT_DIR/shogun.md" ]
}

@test "claude: karo.md generated" {
    [ -f "$OUTPUT_DIR/karo.md" ]
}

@test "claude: ashigaru.md generated" {
    [ -f "$OUTPUT_DIR/ashigaru.md" ]
}

# =============================================================================
# ファイル生成テスト — Codex / OpenCode
# =============================================================================

@test "codex: codex-shogun.md generated" {
    [ -f "$OUTPUT_DIR/codex-shogun.md" ]
}

@test "codex: codex-karo.md generated" {
    [ -f "$OUTPUT_DIR/codex-karo.md" ]
}

@test "codex: codex-ashigaru.md generated" {
    [ -f "$OUTPUT_DIR/codex-ashigaru.md" ]
}

@test "opencode: opencode-shogun.md generated [R6]" {
    [ -f "$OUTPUT_DIR/opencode-shogun.md" ]
}

@test "opencode: opencode-karo.md generated [R6]" {
    [ -f "$OUTPUT_DIR/opencode-karo.md" ]
}

@test "opencode: opencode-ashigaru.md generated [R6]" {
    [ -f "$OUTPUT_DIR/opencode-ashigaru.md" ]
}

@test "opencode: opencode-gunshi.md generated [R6]" {
    [ -f "$OUTPUT_DIR/opencode-gunshi.md" ]
}

@test "opencode: generated markdown is LF-only and has no trailing whitespace [R6]" {
    local file

    for file in "$OUTPUT_DIR"/opencode-*.md "$PROJECT_ROOT"/.opencode/agents/*.md; do
        [ -f "$file" ] || continue

        if LC_ALL=C grep -n $'\r' "$file"; then
            echo "CR line ending found in $file" >&2
            return 1
        fi

        if grep -nE '[[:blank:]]+$' "$file"; then
            echo "Trailing whitespace found in $file" >&2
            return 1
        fi
    done
}

# =============================================================================
# ファイル生成テスト — Copilot (Phase 2+3 受入基準)
# =============================================================================

@test "copilot: copilot-shogun.md generated [Phase 2+3]" {
    [ -f "$OUTPUT_DIR/copilot-shogun.md" ]
}

@test "copilot: copilot-karo.md generated [Phase 2+3]" {
    [ -f "$OUTPUT_DIR/copilot-karo.md" ]
}

@test "copilot: copilot-ashigaru.md generated [Phase 2+3]" {
    [ -f "$OUTPUT_DIR/copilot-ashigaru.md" ]
}

# =============================================================================
# 内容検証テスト — 空でないこと
# =============================================================================

@test "content: shogun.md is not empty" {
    [ -s "$OUTPUT_DIR/shogun.md" ]
}

@test "content: karo.md is not empty" {
    [ -s "$OUTPUT_DIR/karo.md" ]
}

@test "content: ashigaru.md is not empty" {
    [ -s "$OUTPUT_DIR/ashigaru.md" ]
}

@test "content: codex-shogun.md is not empty" {
    [ -s "$OUTPUT_DIR/codex-shogun.md" ]
}

@test "content: codex-karo.md is not empty" {
    [ -s "$OUTPUT_DIR/codex-karo.md" ]
}

@test "content: codex-ashigaru.md is not empty" {
    [ -s "$OUTPUT_DIR/codex-ashigaru.md" ]
}

@test "content: opencode-shogun.md is not empty" {
    [ -s "$OUTPUT_DIR/opencode-shogun.md" ]
}

@test "content: opencode-karo.md is not empty" {
    [ -s "$OUTPUT_DIR/opencode-karo.md" ]
}

@test "content: opencode-ashigaru.md is not empty" {
    [ -s "$OUTPUT_DIR/opencode-ashigaru.md" ]
}

@test "content: opencode-gunshi.md is not empty" {
    [ -s "$OUTPUT_DIR/opencode-gunshi.md" ]
}

# =============================================================================
# 内容検証テスト — ロール名含有
# =============================================================================

@test "content: shogun.md contains shogun role reference" {
    grep -qi "shogun\|将軍" "$OUTPUT_DIR/shogun.md"
}

@test "content: karo.md contains karo role reference" {
    grep -qi "karo\|家老" "$OUTPUT_DIR/karo.md"
}

@test "content: ashigaru.md contains ashigaru role reference" {
    grep -qi "ashigaru\|足軽" "$OUTPUT_DIR/ashigaru.md"
}

@test "content: codex-shogun.md contains shogun role reference" {
    grep -qi "shogun\|将軍" "$OUTPUT_DIR/codex-shogun.md"
}

@test "content: codex-karo.md contains karo role reference" {
    grep -qi "karo\|家老" "$OUTPUT_DIR/codex-karo.md"
}

@test "content: codex-ashigaru.md contains ashigaru role reference" {
    grep -qi "ashigaru\|足軽" "$OUTPUT_DIR/codex-ashigaru.md"
}

@test "content: opencode-shogun.md contains shogun role reference" {
    grep -qi "shogun\|将軍" "$OUTPUT_DIR/opencode-shogun.md"
}

@test "content: opencode-karo.md contains karo role reference" {
    grep -qi "karo\|家老" "$OUTPUT_DIR/opencode-karo.md"
}

@test "content: opencode-ashigaru.md contains ashigaru role reference" {
    grep -qi "ashigaru\|足軽" "$OUTPUT_DIR/opencode-ashigaru.md"
}

@test "content: opencode-gunshi.md contains gunshi role reference" {
    grep -qi "gunshi\|軍師" "$OUTPUT_DIR/opencode-gunshi.md"
}

# =============================================================================
# 内容検証テスト — CLI固有セクション
# =============================================================================

@test "content: claude files contain Claude-specific tools" {
    # Claude Code固有ツール: Read, Write, Edit, Bash等
    grep -qi "claude\|Read\|Write\|Edit\|Bash" "$OUTPUT_DIR/shogun.md"
}

@test "content: codex files contain Codex-specific content" {
    grep -qi "codex\|AGENTS.md\|Codex" "$OUTPUT_DIR/codex-shogun.md"
}

@test "content: opencode files contain OpenCode-specific content [R6]" {
    grep -qi "opencode\|OpenCode\|--agent" "$OUTPUT_DIR/opencode-shogun.md"
}

@test "content: copilot files contain Copilot-specific content [Phase 2+3]" {
    grep -qi "copilot\|Copilot" "$OUTPUT_DIR/copilot-shogun.md"
}

# =============================================================================
# AGENTS.md 生成テスト (Phase 2+3 受入基準)
# =============================================================================

@test "agents: AGENTS.md generated [Phase 2+3]" {
    [ -f "$PROJECT_ROOT/AGENTS.md" ]
}

@test "agents: AGENTS.md contains Codex-specific content [Phase 2+3]" {
    [ -f "$PROJECT_ROOT/AGENTS.md" ] && grep -qi "codex\|agent" "$PROJECT_ROOT/AGENTS.md"
}

# =============================================================================
# OpenCode instruction generation (R6)
# =============================================================================

@test "opencode-inst: instructions/generated/opencode-shogun.md generated [R6]" {
    [ -f "$OUTPUT_DIR/opencode-shogun.md" ]
}

@test "opencode-inst: instructions/generated/opencode-karo.md generated [R6]" {
    [ -f "$OUTPUT_DIR/opencode-karo.md" ]
}

@test "opencode-inst: instructions/generated/opencode-ashigaru.md generated [R6]" {
    [ -f "$OUTPUT_DIR/opencode-ashigaru.md" ]
}

@test "opencode-inst: instructions/generated/opencode-gunshi.md generated [R6]" {
    [ -f "$OUTPUT_DIR/opencode-gunshi.md" ]
}

@test "opencode-agent: .opencode/agents/shogun.md generated [R6]" {
    [ -f "$PROJECT_ROOT/.opencode/agents/shogun.md" ]
}

@test "opencode-agent: generated agent frontmatter contains permission section [R6]" {
    grep -q '^permission:' "$PROJECT_ROOT/.opencode/agents/shogun.md"
}

@test "opencode-agent: tracked agent frontmatter excludes runtime routing [R6]" {
    PROJECT_ROOT="$PROJECT_ROOT" "$PROJECT_ROOT/.venv/bin/python3" - <<'PYEOF'
from pathlib import Path
import os
import yaml

project_root = Path(os.environ["PROJECT_ROOT"])
agents_dir = project_root / ".opencode" / "agents"
for path in sorted(agents_dir.glob("*.md")):
    if path.name.endswith("-runtime.md"):
        continue
    text = path.read_text(encoding="utf-8")
    frontmatter = yaml.safe_load(text.split("---", 2)[1])
    assert "model" not in frontmatter, f"{path.name}: tracked generated agent must not depend on local settings.yaml"
    assert "variant" not in frontmatter, f"{path.name}: tracked generated agent must not depend on local settings.yaml"
PYEOF
}

@test "opencode-agent: ashigaru1 read permissions allow own inbox/report/task [R6]" {
    PROJECT_ROOT="$PROJECT_ROOT" "$PROJECT_ROOT/.venv/bin/python3" - <<'PYEOF'
from pathlib import Path
import os
import yaml

project_root = Path(os.environ["PROJECT_ROOT"])
text = (project_root / ".opencode/agents/ashigaru1.md").read_text(encoding="utf-8")
parts = text.split("---", 2)
frontmatter = yaml.safe_load(parts[1])
perm = frontmatter["permission"]

assert perm["question"] == "deny"
assert perm["read"]["queue/inbox/*"] == "deny"
assert perm["read"]["queue/inbox/ashigaru1.yaml"] == "allow"
assert perm["read"]["queue/tasks/*"] == "deny"
assert perm["read"]["queue/tasks/ashigaru1.yaml"] == "allow"
assert perm["read"]["queue/reports/*"] == "deny"
assert perm["read"]["queue/reports/ashigaru1_report.yaml"] == "allow"

for tool_name in ("glob", "list"):
    assert perm[tool_name]["queue/inbox/*"] == "deny"
    assert perm[tool_name]["queue/inbox/ashigaru1.yaml"] == "allow"
    assert perm[tool_name]["queue/tasks/*"] == "deny"
    assert perm[tool_name]["queue/tasks/ashigaru1.yaml"] == "allow"
    assert perm[tool_name]["queue/reports/*"] == "deny"
    assert perm[tool_name]["queue/reports/ashigaru1_report.yaml"] == "allow"
PYEOF
}

@test "opencode-agent: grep permission is intentionally not path-scoped [R6]" {
    PROJECT_ROOT="$PROJECT_ROOT" "$PROJECT_ROOT/.venv/bin/python3" - <<'PYEOF'
from pathlib import Path
import os
import yaml

agents_dir = Path(os.environ["PROJECT_ROOT"]) / ".opencode/agents"
for path in sorted(agents_dir.glob("*.md")):
    text = path.read_text(encoding="utf-8")
    frontmatter = yaml.safe_load(text.split("---", 2)[1])
    perm = frontmatter["permission"]
    assert "grep" not in perm, f"{path.name}: grep must inherit '*: allow', not path-scoped rules"
    assert "grep intentionally inherits '*: allow'" in text, f"{path.name}: missing intentional grep comment"
PYEOF
}

@test "opencode-agent: shogun can read reports for oversight [R6]" {
    PROJECT_ROOT="$PROJECT_ROOT" "$PROJECT_ROOT/.venv/bin/python3" - <<'PYEOF'
from pathlib import Path
import os
import yaml

path = Path(os.environ["PROJECT_ROOT"]) / ".opencode/agents/shogun.md"
text = path.read_text(encoding="utf-8")
frontmatter = yaml.safe_load(text.split("---", 2)[1])
perm = frontmatter["permission"]

assert perm["read"]["queue/reports/*"] == "allow"
assert perm["glob"]["queue/reports/*"] == "allow"
assert perm["list"]["queue/reports/*"] == "allow"
assert perm["edit"]["queue/reports/*"] == "deny"
PYEOF
}

@test "opencode-agent: inbox edits are denied for every role [R6]" {
    PROJECT_ROOT="$PROJECT_ROOT" "$PROJECT_ROOT/.venv/bin/python3" - <<'PYEOF'
from pathlib import Path
import os
import yaml

agents_dir = Path(os.environ["PROJECT_ROOT"]) / ".opencode/agents"
for path in sorted(agents_dir.glob("*.md")):
    text = path.read_text(encoding="utf-8")
    frontmatter = yaml.safe_load(text.split("---", 2)[1])
    edit = frontmatter["permission"]["edit"]
    inbox_rules = {key: value for key, value in edit.items() if key.startswith("queue/inbox/")}
    exact_rule = edit.get("queue/inbox/*.yaml")
    unexpected_rules = {key: value for key, value in inbox_rules.items() if key != "queue/inbox/*.yaml"}

    assert exact_rule == "deny", f"{path.name}: queue/inbox/*.yaml edit rule missing or not deny: {exact_rule!r}"
    assert not unexpected_rules, f"{path.name}: unexpected inbox edit rules: {unexpected_rules}"
PYEOF
}

@test "opencode-agent: invalid permission YAML fails generation [R6]" {
    local permissions_file
    permissions_file="$BATS_TEST_TMPDIR/opencode-permissions.invalid.yaml"

    printf 'roles: [invalid\n' > "$permissions_file"
    run env OPENCODE_PERMISSIONS_FILE="$permissions_file" bash "$BUILD_SCRIPT"

    [ "$status" -ne 0 ]
}

@test "opencode-config: root edit permissions deny inbox YAML [R6]" {
    PROJECT_ROOT="$PROJECT_ROOT" "$PROJECT_ROOT/.venv/bin/python3" - <<'PYEOF'
from pathlib import Path
import os
import yaml

config = yaml.safe_load((Path(os.environ["PROJECT_ROOT"]) / "config/opencode-permissions.yaml").read_text(encoding="utf-8"))
assert config["common"]["edit_deny"]
assert "queue/inbox/*.yaml" in config["common"]["edit_deny"]
PYEOF
}

@test "opencode-tool: mark-as-read enforces current agent and inbox lock [R6]" {
    local tool_file="$PROJECT_ROOT/.opencode/tools/mark-as-read.ts"

    grep -q 'process.env.OPENCODE_AGENT_ID' "$tool_file"
    grep -q 'Refusing to mark another agent' "$tool_file"
    grep -q 'withInboxLock' "$tool_file"
    grep -q '.lock.d' "$tool_file"
}

# =============================================================================
# copilot-instructions.md 生成テスト (Phase 2+3 受入基準)
# =============================================================================

@test "copilot-inst: .github/copilot-instructions.md generated [Phase 2+3]" {
    [ -f "$PROJECT_ROOT/.github/copilot-instructions.md" ]
}

@test "copilot-inst: contains Copilot-specific content [Phase 2+3]" {
    [ -f "$PROJECT_ROOT/.github/copilot-instructions.md" ] && \
        grep -qi "copilot" "$PROJECT_ROOT/.github/copilot-instructions.md"
}

# =============================================================================
# 冪等性テスト
# =============================================================================

# =============================================================================
# Codex /clear → /new 変換テスト
# =============================================================================
# Codex CLIは/clearでセッション終了するため、AGENTS.mdおよびcodex-*.mdで
# /clearが命令として残存していないことを検証する。
# 比較表や変換説明の文脈での/clear言及はOK。

@test "codex-clear: AGENTS.md has no /clear Recovery section" {
    # /clear Recoveryは/new Recoveryに変換されるべき
    run grep -c "## /clear Recovery" "$PROJECT_ROOT/AGENTS.md"
    [ "$output" = "0" ]
}

@test "codex-clear: AGENTS.md has /new Recovery section" {
    grep -q "## /new Recovery" "$PROJECT_ROOT/AGENTS.md"
}

@test "codex-clear: AGENTS.md has no 'Forbidden after /clear'" {
    run grep -c "Forbidden after /clear" "$PROJECT_ROOT/AGENTS.md"
    [ "$output" = "0" ]
}

@test "codex-clear: AGENTS.md has no 'sends \`/clear\` + Enter via send-keys' (unconverted)" {
    # 変換済みは「sends /new + Enter」になっているべき
    run grep -c 'sends `/clear` + Enter via send-keys$' "$PROJECT_ROOT/AGENTS.md"
    [ "$output" = "0" ]
}

@test "codex-clear: AGENTS.md has no 'delivers \`/clear\` to the agent' (unconverted)" {
    # 変換済みは「delivers /new to the agent」になっているべき
    run grep -c 'delivers `/clear` to the agent →' "$PROJECT_ROOT/AGENTS.md"
    [ "$output" = "0" ]
}

@test "codex-clear: AGENTS.md has no '/clear wipes old context'" {
    run grep -c '`/clear` wipes old context' "$PROJECT_ROOT/AGENTS.md"
    [ "$output" = "0" ]
}

@test "codex-clear: codex-ashigaru.md has no bare '/clear' in escalation table" {
    # 比較表(codex_tools.md由来)以外で/clearが命令として現れないこと
    # エスカレーション行に「/clear sent」があればNG
    run grep -c '`/clear` sent (max once' "$OUTPUT_DIR/codex-ashigaru.md"
    [ "$output" = "0" ]
}

@test "codex-clear: codex-ashigaru.md protocol uses CLI-neutral context reset" {
    # ★cmd_754: clear_command は自動では送らなくなった。protocol.md の記述が
    #   CLI 中立(特定CLIの打鍵を指示しない)であることを検査する。
    grep -q "自動では送らない" "$OUTPUT_DIR/codex-ashigaru.md"
    # 「send-keys で context reset を送る」という旧記述が残っていないこと
    run bash -c "grep -c 'context reset command via send-keys' '$OUTPUT_DIR/codex-ashigaru.md' || true"
    [ "$output" = "0" ]
}

@test "codex-clear: codex-karo.md has no bare '/clear' in redo protocol" {
    # Redo Protocolで「delivers /clear to the agent →」がそのまま残っていないこと
    run grep -c 'delivers `/clear` to the agent →' "$OUTPUT_DIR/codex-karo.md"
    [ "$output" = "0" ]
}

@test "codex-clear: codex-gunshi.md protocol uses CLI-neutral context reset" {
    # ★cmd_754: clear_command は自動では送らなくなった。protocol.md の記述が
    #   CLI 中立(特定CLIの打鍵を指示しない)であることを検査する。
    grep -q "自動では送らない" "$OUTPUT_DIR/codex-gunshi.md"
    # 「send-keys で context reset を送る」という旧記述が残っていないこと
    run bash -c "grep -c 'context reset command via send-keys' '$OUTPUT_DIR/codex-gunshi.md' || true"
    [ "$output" = "0" ]
}

@test "codex-clear: codex-shogun.md protocol uses CLI-neutral context reset" {
    # ★cmd_754: clear_command は自動では送らなくなった。protocol.md の記述が
    #   CLI 中立(特定CLIの打鍵を指示しない)であることを検査する。
    grep -q "自動では送らない" "$OUTPUT_DIR/codex-shogun.md"
    # 「send-keys で context reset を送る」という旧記述が残っていないこと
    run bash -c "grep -c 'context reset command via send-keys' '$OUTPUT_DIR/codex-shogun.md' || true"
    [ "$output" = "0" ]
}

# =============================================================================
# Ashigaru Report Write Lock (cmd_734 redo1)
# =============================================================================
# G734-C-01: 足軽report追記(queue/reports/ashigaru{N}_report.yaml)がロック
# 経由に限定されず、report.yaml EOFへの直接追記が指示され得た欠陥の回帰
# テスト。ソース(instructions/ashigaru.md)と、共通protocol.md経由で全CLI
# 変種の生成物に反映されることの両方を検証する。
#
# 注記: instructions/{shogun,karo,gunshi,ashigaru}.md はCRLFを含み、
# build_instruction_file() のfrontmatter抽出(awk '/^---$/')が空振りする
# 既知の別問題があるため、ashigaru.mdのworkflow step 5そのものは生成物へ
# 伝播しない。そのためスクリプト呼出しの検証は、CRLFの影響を受けない
# instructions/common/protocol.md経由の伝播で行う(instructions/ashigaru.md
# 自体はソース直読み〈CLAUDE.md Session Start手順〉のため別途ソース単体で検証する)。

@test "report-lock: source instructions/ashigaru.md workflow step 5 references ashigaru_report_lock.sh" {
    grep -q "ashigaru_report_lock.sh append ashigaru{N}" "$PROJECT_ROOT/instructions/ashigaru.md"
}

@test "report-lock: source instructions/ashigaru.md forbids direct EOF append" {
    grep -q "Edit/Write/EOF" "$PROJECT_ROOT/instructions/ashigaru.md"
}

@test "report-lock: common/protocol.md documents ashigaru_report_lock.sh append/archive" {
    grep -q "bash scripts/ashigaru_report_lock.sh append <agent_id>" "$PROJECT_ROOT/instructions/common/protocol.md"
    grep -q "bash scripts/ashigaru_report_lock.sh archive <agent_id>" "$PROJECT_ROOT/instructions/common/protocol.md"
    grep -q "report.yamlのEOFへの直接Edit/Write追記は禁止" "$PROJECT_ROOT/instructions/common/protocol.md"
}

@test "report-lock: generated ashigaru.md (claude) references ashigaru_report_lock.sh append" {
    grep -q "ashigaru_report_lock.sh append" "$OUTPUT_DIR/ashigaru.md"
}

@test "report-lock: generated codex-ashigaru.md references ashigaru_report_lock.sh append" {
    grep -q "ashigaru_report_lock.sh append" "$OUTPUT_DIR/codex-ashigaru.md"
}

@test "report-lock: generated copilot-ashigaru.md references ashigaru_report_lock.sh append" {
    grep -q "ashigaru_report_lock.sh append" "$OUTPUT_DIR/copilot-ashigaru.md"
}

@test "report-lock: generated kimi-ashigaru.md references ashigaru_report_lock.sh append" {
    grep -q "ashigaru_report_lock.sh append" "$OUTPUT_DIR/kimi-ashigaru.md"
}

@test "report-lock: generated opencode-ashigaru.md references ashigaru_report_lock.sh append" {
    grep -q "ashigaru_report_lock.sh append" "$OUTPUT_DIR/opencode-ashigaru.md"
}

@test "report-lock: generated ashigaru variants forbid direct EOF append" {
    local file
    for file in "$OUTPUT_DIR/ashigaru.md" "$OUTPUT_DIR/codex-ashigaru.md" \
                "$OUTPUT_DIR/copilot-ashigaru.md" "$OUTPUT_DIR/kimi-ashigaru.md" \
                "$OUTPUT_DIR/opencode-ashigaru.md"; do
        grep -q "直接Edit/Write追記は禁止" "$file" || {
            echo "missing prohibition text in $file" >&2
            return 1
        }
    done
}

# =============================================================================
# Karo Task-Authoring Rule for Ashigaru Report Lock (cmd_734 redo2)
# =============================================================================
# G734-C-01-R1: 家老のtask YAML作成手順(instructions/roles/karo_role.md)へ、
# 全ashigaru taskの完了報告節がashigaru_report_lock.sh append経由の追記を
# 指示し、report.yamlへの直接Edit/Write/heredoc追記を禁止する規則が存在
# することの回帰テスト。karo_role.mdはrole body(instructions/roles/
# ${role}_role.md)としてbuild_instruction_file()内でcatにより無条件に
# 結合される(frontmatter抽出のCRLF既知問題[G734-FOLLOWUP-CRLF-01]の
# 影響を受けない経路)。そのため生成物5変種+.opencode/agents/karo.mdの
# 全てで直接検証できる。

@test "karo-report-lock: source instructions/roles/karo_role.md documents append rule" {
    grep -q "ashigaru_report_lock.sh append ashigaru{N}" "$PROJECT_ROOT/instructions/roles/karo_role.md"
}

@test "karo-report-lock: source instructions/roles/karo_role.md forbids direct EOF append instruction" {
    grep -q "直接 Edit/Write/heredoc" "$PROJECT_ROOT/instructions/roles/karo_role.md"
}

@test "karo-report-lock: generated karo.md (claude) references task-authoring append rule" {
    grep -q "Ashigaru完了報告節の記述規則" "$OUTPUT_DIR/karo.md"
}

@test "karo-report-lock: generated codex-karo.md references task-authoring append rule" {
    grep -q "Ashigaru完了報告節の記述規則" "$OUTPUT_DIR/codex-karo.md"
}

@test "karo-report-lock: generated copilot-karo.md references task-authoring append rule" {
    grep -q "Ashigaru完了報告節の記述規則" "$OUTPUT_DIR/copilot-karo.md"
}

@test "karo-report-lock: generated kimi-karo.md references task-authoring append rule" {
    grep -q "Ashigaru完了報告節の記述規則" "$OUTPUT_DIR/kimi-karo.md"
}

@test "karo-report-lock: generated opencode-karo.md references task-authoring append rule" {
    grep -q "Ashigaru完了報告節の記述規則" "$OUTPUT_DIR/opencode-karo.md"
}

@test "karo-report-lock: .opencode/agents/karo.md references task-authoring append rule [R6]" {
    grep -q "Ashigaru完了報告節の記述規則" "$PROJECT_ROOT/.opencode/agents/karo.md"
}

@test "karo-report-lock: generated karo variants forbid direct EOF append instruction" {
    local file
    for file in "$OUTPUT_DIR/karo.md" "$OUTPUT_DIR/codex-karo.md" \
                "$OUTPUT_DIR/copilot-karo.md" "$OUTPUT_DIR/kimi-karo.md" \
                "$OUTPUT_DIR/opencode-karo.md" "$PROJECT_ROOT/.opencode/agents/karo.md"; do
        grep -q "直接 Edit/Write/heredoc" "$file" || {
            echo "missing prohibition text in $file" >&2
            return 1
        }
    done
}

# =============================================================================
# 冪等性テスト
# =============================================================================

@test "idempotent: second build produces identical output" {
    # 1st build
    bash "$BUILD_SCRIPT" > /dev/null 2>&1
    local checksums_first
    checksums_first=$(find "$OUTPUT_DIR" -name "*.md" -type f -exec md5sum {} \; | sort)

    # 2nd build
    bash "$BUILD_SCRIPT" > /dev/null 2>&1
    local checksums_second
    checksums_second=$(find "$OUTPUT_DIR" -name "*.md" -type f -exec md5sum {} \; | sort)

    [ "$checksums_first" = "$checksums_second" ]
}

# =============================================================================
# Ashigaru Report Lock Allowlist ashigaru1〜7 (cmd_734 redo1 — G734-DOC-01)
# =============================================================================
# 軍師QC(subtask_734_report_format_migration_gap_qc)がblocking指摘した
# 不整合の回帰テスト: 実装(ashigaru_report_lock.shの_ALLOWLIST)は既に
# ashigaru1〜7を受理するが、instructions/common/protocol.md:376は
# 「ashigaru3〜7のみ受理」と誤記したままgenerated全変種へ伝播していた。
# sourceと全generated変種がashigaru1・ashigaru2を含むことを検証する。

@test "report-lock-allowlist: source common/protocol.md documents ashigaru1/ashigaru2 in allowlist" {
    grep -q '`ashigaru1`/`ashigaru2`/`ashigaru3`' "$PROJECT_ROOT/instructions/common/protocol.md"
}

@test "report-lock-allowlist: source common/protocol.md no longer opens the allowlist at ashigaru3" {
    # 是正前は「は `ashigaru3`/`ashigaru4`/...」の並びでashigaru3始まりだった。
    # 是正後はashigaru1始まりになるため、この開始位置パターンは消えているはず。
    run grep -c 'は `ashigaru3`/`ashigaru4`/`ashigaru5`/`ashigaru6`/`ashigaru7`' "$PROJECT_ROOT/instructions/common/protocol.md"
    [ "$output" = "0" ]
}

@test "report-lock-allowlist: all instructions/generated/*.md variants document ashigaru1/ashigaru2" {
    local file
    for file in "$OUTPUT_DIR"/*.md; do
        grep -q '`ashigaru1`/`ashigaru2`/`ashigaru3`' "$file" || {
            echo "missing ashigaru1/ashigaru2 allowlist text in $file" >&2
            return 1
        }
    done
}

@test "report-lock-allowlist: .opencode/agents/*.md (non-runtime) variants document ashigaru1/ashigaru2" {
    local file
    for file in "$PROJECT_ROOT"/.opencode/agents/*.md; do
        [[ "$file" == *-runtime.md ]] && continue
        grep -q '`ashigaru1`/`ashigaru2`/`ashigaru3`' "$file" || {
            echo "missing ashigaru1/ashigaru2 allowlist text in $file" >&2
            return 1
        }
    done
}
