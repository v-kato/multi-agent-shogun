#!/usr/bin/env bash
# SessionStart hook — 起動/resume//clear/compact 全経路で Session Start 手順を確定的に注入
#
# 公式仕様 (hooks-guide.md):
#   - matcher: startup / resume / clear / compact (全 matcher で発火させる)
#   - stdout の plain text は additionalContext として Claude の context に注入される
#   - exit 0 で正常終了。失敗しても black hole にならぬよう set -e は使わず graceful degrade
#
# 本 hook の目的:
#   shutsujin_departure.sh の STEP 6.7 (起動時 inbox broadcast) 廃止 (commit 485ab9f, 2026-02-08)
#   以降、起動時に Session Start が発火せず、persona 未確立で「自己紹介して」に対し
#   全エージェントが「我は将軍」と誤認する事故が発生 (2026-04-19)。
#   SessionStart hook で確定的に Session Start 手順を注入し、/clear・compaction も同時カバーする。
#
# CLI種別 (cmd_757④redo1, G757-CODEX-PERSONA-PATH-01是正):
#   本スクリプトは第1引数で CLI 種別 (claude|codex) を受け取る。省略時は
#   claude (.claude/settings.json からの既存呼び出しは無引数のため後方互換)。
#   以前は CLI 種別を区別せず、Codex 向け呼び出し (scripts/codex_session_start_hook.sh
#   経由) でも常に claude 向け文面 (CLAUDE.md・instructions/${AGENT_ID}.md・/clear 前提)
#   を出力しており、Codex の正本 (AGENTS.md・instructions/generated/codex-{role}.md・
#   /new 契約) と食い違う誤った回復文面を注入していた。本引数で分岐する。
#
# Environment:
#   TMUX_PANE — used to identify which agent is running
#   __SESSION_START_HOOK_AGENT_ID — override for testing (default: from tmux)
#   __SESSION_START_HOOK_LOG_DIR  — override log dir for testing (default: <repo>/logs)
#
# Note: Codex CLI で動く agent (どの agent が Codex かは config/settings.yaml の
# cli.agents が決める。陣容は変わるため本註には特定の号との対応を書かない) は
# scripts/codex_session_start_hook.sh が本スクリプトを明示的に "codex" 引数
# 付きで呼び出す (JSON 封筒への変換も codex_session_start_hook.sh 側が担う)。
# 本スクリプト単体を .claude/settings.json から無引数で呼ぶ既存経路は
# claude 向け plain text 契約のまま変更していない。

set -uo pipefail

CLI_TYPE="${1:-claude}"

if [ -n "${__SESSION_START_HOOK_AGENT_ID+x}" ]; then
    AGENT_ID="$__SESSION_START_HOOK_AGENT_ID"
elif [ -n "${TMUX_PANE:-}" ]; then
    AGENT_ID=$(tmux display-message -t "$TMUX_PANE" -p '#{@agent_id}' 2>/dev/null || true)
else
    AGENT_ID=""
fi

# @agent_id 未設定 (= multi-agent 環境外の個人 CLI 利用) → silent exit で干渉せぬ
if [ -z "$AGENT_ID" ]; then
    exit 0
fi

LOG_DIR="${__SESSION_START_HOOK_LOG_DIR:-$(dirname "$0")/../logs}"
mkdir -p "$LOG_DIR" || true
echo "[$(date -Iseconds)] $AGENT_ID session_start_hook fired (cli=${CLI_TYPE})" \
    >> "$LOG_DIR/session_start_hook.log" || true

# ═══════════════════════════════════════════════════════════════
# Codex 版回復文面 (AGENTS.md・instructions/generated/codex-{role}.md・/new契約)
# ═══════════════════════════════════════════════════════════════
if [ "$CLI_TYPE" = "codex" ]; then
    case "$AGENT_ID" in
        shogun|karo|gunshi)
            # command-layer agents: AGENTS.md「Session Start / Recovery (all agents)」Step1-5
            # Codex は全role共通で instructions/generated/codex-{role}.md が正本 (AGENTS.md Step4)
            INSTR_PATH="instructions/generated/codex-${AGENT_ID}.md"
            cat <<EOF
**CRITICAL: Session Start 手順を最優先で実行せよ**

貴殿は **${AGENT_ID}** である。tmux pane から確定的に読み出した事実であり、推測不要。

以下を順番に実行せよ (省略禁止、ユーザ応答/inbox 処理はこの後):

1. \`tmux display-message -t "\$TMUX_PANE" -p '#{@agent_id}'\` で自己識別を再確認
2. \`mcp__memory__read_graph\` でルール・嗜好・教訓を復元
3. (shogun のみ) \`memory/MEMORY.md\` を Read
4. \`${INSTR_PATH}\` を最後まで必読 — persona・戦国口調・forbidden_actions 再確立 **(絶対省略禁止)**
   (本 CLI の自動ロード正本は AGENTS.md である)
5. \`queue/\` 配下 (tasks/, inbox/, reports/) から state 再構築

**Step 1-4 完了まで inbox 処理・ユーザ応答は禁止**。inbox{N} nudge が先に届いても無視し、persona 確立を優先せよ。

Rationale: 2026-04-18 に家老が「我は将軍」と役職誤認する persona 崩壊事例あり。
command-layer agent は persona + 戦国口調 + forbidden_actions の再確立が必須。

なお、本メッセージは SessionStart hook (Codex 版: scripts/codex_session_start_hook.sh
経由で scripts/session_start_hook.sh codex を実行) が tmux pane の @agent_id を
読み出して生成したものであり、推測や混同の余地はない。本 CLI の context reset は
\`/clear\` ではなく \`/new\` である。
EOF
            ;;
        ashigaru*)
            # worker agents: AGENTS.md「/new Recovery (ashigaru only)」Step 1-4に
            # 逐語的に一致させる (cmd_757④redo2, G757-CODEX-ASHIGARU-RECOVERY-REDO1-01是正:
            # 旧文面はStep1の自己識別をモデル自身に実行させず、かつ「status=assignedかつwork」
            # という非schemaのwork条件を暗示する誤読可能な文面だった。work というfieldは
            # task schemaに存在せず、正本は「status=assignedならworkとして実行する」である)
            cat <<EOF
**CRITICAL: Session Start 手順を最優先で実行せよ**

貴殿は **${AGENT_ID}** である。tmux pane から確定的に読み出した事実だが、
以下 Step 1 で自ら再確認せよ (AGENTS.md「/new Recovery (ashigaru only)」Step 1-4に逐語準拠):

Step 1: \`tmux display-message -t "\$TMUX_PANE" -p '#{@agent_id}'\` → ${AGENT_ID}
Step 2: \`queue/tasks/${AGENT_ID}.yaml\` を Read →
        assigned=work (execute task), idle=wait, done=wait (DO NOT re-report)
Step 3: タスクに \`project:\` field があれば \`context/{project}.md\` を Read
        タスクに \`target_path:\` があれば対象ファイルを Read
Step 4: Start work (only if assigned=work)

**Step 1-2 完了まで inbox 処理・ユーザ応答は禁止**。
初回起動時は AGENTS.md 自動ロード済み、
instructions/generated/codex-ashigaru.md の再読は不要 (コスト節約)。
本 CLI の context reset は \`/clear\` ではなく \`/new\` である。

本メッセージは SessionStart hook (Codex 版: scripts/codex_session_start_hook.sh
経由で scripts/session_start_hook.sh codex を実行) が tmux pane の @agent_id を
読み出して生成したものであり、推測や混同の余地はない。
EOF
            ;;
        *)
            cat <<EOF
**Session Start**: agent_id=${AGENT_ID}。AGENTS.md の Session Start 手順に従い
instructions/generated/codex-${AGENT_ID}.md を読み込め。
EOF
            ;;
    esac
    exit 0
fi

# ═══════════════════════════════════════════════════════════════
# Claude 版回復文面 (CLAUDE.md・instructions/*.md・/clear契約) — 既存動作を無変更で維持
# ═══════════════════════════════════════════════════════════════
case "$AGENT_ID" in
    shogun|karo|gunshi)
        # command-layer agents: full Session Start (Step 1-5)
        # karo のみ instructions/generated/karo.md が runtime canonical source (cmd_693): CLAUDE.md Step4 と揃える
        INSTR_PATH="instructions/${AGENT_ID}.md"
        if [ "$AGENT_ID" = "karo" ]; then
            INSTR_PATH="instructions/generated/karo.md"
        fi
        cat <<EOF
**CRITICAL: Session Start 手順を最優先で実行せよ**

貴殿は **${AGENT_ID}** である。tmux pane から確定的に読み出した事実であり、推測不要。

以下を順番に実行せよ (省略禁止、ユーザ応答/inbox 処理はこの後):

1. \`tmux display-message -t "\$TMUX_PANE" -p '#{@agent_id}'\` で自己識別を再確認
2. \`mcp__memory__read_graph\` でルール・嗜好・教訓を復元
3. (shogun のみ) \`memory/MEMORY.md\` を Read
4. \`${INSTR_PATH}\` を最後まで必読 — persona・戦国口調・forbidden_actions 再確立 **(絶対省略禁止)**
5. \`queue/\` 配下 (tasks/, inbox/, reports/) から state 再構築

**Step 1-4 完了まで inbox 処理・ユーザ応答は禁止**。inbox{N} nudge が先に届いても無視し、persona 確立を優先せよ。

Rationale: 2026-04-18 に家老が「我は将軍」と役職誤認する persona 崩壊事例あり。
command-layer agent は persona + 戦国口調 + forbidden_actions の再確立が必須。

なお、本メッセージは SessionStart hook (scripts/session_start_hook.sh) が
tmux pane の @agent_id を読み出して生成したものであり、推測や混同の余地はない。
EOF
        ;;
    ashigaru*)
        # worker agents: /clear Recovery (ashigaru only) 準拠の軽量手順
        cat <<EOF
**CRITICAL: Session Start 手順を最優先で実行せよ**

貴殿は **${AGENT_ID}** である。tmux pane から確定的に読み出した事実。

足軽用軽量手順 (CLAUDE.md「/clear Recovery (ashigaru only)」準拠):

1. \`queue/tasks/${AGENT_ID}.yaml\` を Read
   - status=assigned かつ work → タスク実行
   - idle → 待機
   - done → 待機 (再報告禁止)
2. タスクに \`project:\` があれば \`context/{project}.md\` を Read
3. タスクに \`target_path:\` があれば対象ファイルを Read
4. Step 1-3 完了後にタスク着手

**Step 1-2 完了まで inbox 処理・ユーザ応答は禁止**。
初回起動時は CLAUDE.md 自動ロード済み、instructions/ashigaru.md の再読は不要 (コスト節約)。

本メッセージは SessionStart hook (scripts/session_start_hook.sh) が
tmux pane の @agent_id を読み出して生成したものであり、推測や混同の余地はない。
EOF
        ;;
    *)
        cat <<EOF
**Session Start**: agent_id=${AGENT_ID}。CLAUDE.md の Session Start 手順に従い自己の instructions/*.md を読み込め。
EOF
        ;;
esac

# cmd_785 Phase 1b: resume の時、注入がその会話に既にある注入と同一だと会話へ加わらない
# (隔離実測: context/cmd_785_phase1b_experiment.md §3-5)。毎回変わる1行を足し、
# 再開のたびにも手順の合図がモデルへ届くようにする。
echo ""
echo "起動時刻: $(date '+%Y-%m-%dT%H:%M:%S%:z')(毎回変わる行。resume 時も、記憶に頼らず上記の手順を今あらためて実行せよ)"

exit 0
