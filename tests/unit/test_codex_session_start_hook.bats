#!/usr/bin/env bats
# test_codex_session_start_hook.bats — Codex CLI 版 SessionStart hook 回帰試験
# (cmd_757④redo1, G757-HOOK-REGRESSION-05是正)
#
# 背景: cmd_757④初版は codex_session_start_hook.sh が Claude 用生成器
# (session_start_hook.sh)を無引数(=claude向け)のまま流用し、Codex宛にも
# CLAUDE.md・instructions/${AGENT_ID}.md・/clear 前提の誤った persona 文面を
# 注入していた(G757-CODEX-PERSONA-PATH-01)。この経路を直接検証するtestが
# 0件で全回帰をすり抜けたため、本ファイルを新設する。
#
# ★注意 (本ファイル自身の教訓): アサーションは `echo "$x" | grep -qF pat` を
# `!` で否定する形は書かない。bash の `set -e` は「!」で否定されたコマンドの
# 非ゼロ終了を検知しない(POSIX仕様どおり)ため、関数内の最後の文でない限り
# 検証が黙って無効化される。本ファイルは `[[ "$x" == *pat* ]]` /
# `[[ "$x" != *pat* ]]` の bash 条件式のみを使い、この落とし穴を避ける。
#
# テスト構成:
#   T-CODEX-SS-001: .codex/hooks.json.template は有効なJSON
#   T-CODEX-SS-002: generate_codex_hooks.sh が実行時PROJECT_ROOTの絶対パスで
#                    .codex/hooks.json を生成し、参照スクリプトが実在・実行可能
#   T-CODEX-SS-003〜006: 全Codex role(shogun/karo/gunshi/ashigaru)で
#                    instructions/generated/codex-{role}.md を参照する
#   T-CODEX-SS-007: command-layer・ashigaru とも AGENTS.md と /new に言及し、
#                    CLAUDE.md・/clear には言及しない
#   T-CODEX-SS-008: 空 agent_id → codex wrapper は {} を返し exit 0
#   T-CODEX-SS-009: 空 agent_id → claude(無引数)は無出力で exit 0 (既存動作)
#   T-CODEX-SS-010: claude(無引数)の karo は instructions/generated/karo.md を
#                    参照し、AGENTS.md・codex wrapper への言及はない(非退行確認)
#   T-CODEX-SS-011: hooks.json の Stop 配線は stop_hook_inbox.sh を無改変で再利用
#   T-CODEX-SS-012: codex wrapper の出力は正しい JSON 封筒
#                    ({"hookSpecificOutput":{"hookEventName":"SessionStart",...}})
#   T-CODEX-SS-013: 未知の agent_id (フォールバック分岐) も AGENTS.md を参照する
#   T-CODEX-SS-014・015: codex wrapper (codex_session_start_hook.sh) 経由の
#                    end-to-end内容検証 (wrapperがcodex引数を渡し忘れる型の
#                    regressionを直接検知する。session_start_hook.shへの
#                    直接呼び出しだけでは検知できないことを確認済み)

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SESSION_HOOK="$SCRIPT_DIR/scripts/session_start_hook.sh"
CODEX_WRAPPER="$SCRIPT_DIR/scripts/codex_session_start_hook.sh"
GENERATE_HOOKS="$SCRIPT_DIR/scripts/generate_codex_hooks.sh"
TEMPLATE="$SCRIPT_DIR/.codex/hooks.json.template"

setup() {
    TEST_TMP="$(mktemp -d)"
}

teardown() {
    rm -rf "$TEST_TMP"
}

# ─── T-CODEX-SS-001 ───

@test "T-CODEX-SS-001: .codex/hooks.json.template は有効なJSON" {
    [ -f "$TEMPLATE" ]
    run python3 -c "import json; json.load(open('$TEMPLATE'))"
    [ "$status" -eq 0 ]
}

# ─── T-CODEX-SS-002 ───

@test "T-CODEX-SS-002: generate_codex_hooks.sh は現在のPROJECT_ROOTで絶対パスhooks.jsonを生成する" {
    [ -x "$GENERATE_HOOKS" ]

    # 隔離コピーで実行 (実プロジェクトの .codex/hooks.json を書き換えない)
    mkdir -p "$TEST_TMP/scripts" "$TEST_TMP/.codex"
    cp "$GENERATE_HOOKS" "$TEST_TMP/scripts/generate_codex_hooks.sh"
    cp "$TEMPLATE" "$TEST_TMP/.codex/hooks.json.template"

    run bash "$TEST_TMP/scripts/generate_codex_hooks.sh"
    [ "$status" -eq 0 ]
    [ -f "$TEST_TMP/.codex/hooks.json" ]

    run python3 -c "import json; json.load(open('$TEST_TMP/.codex/hooks.json'))"
    [ "$status" -eq 0 ]

    # PROJECT_ROOT(=TEST_TMPの実パス)が絶対パスとして展開されていること
    real_root="$(cd "$TEST_TMP" && pwd)"
    run python3 -c "
import json
d = json.load(open('$TEST_TMP/.codex/hooks.json'))
cmd = d['hooks']['SessionStart'][0]['hooks'][0]['command']
assert cmd == '$real_root/scripts/codex_session_start_hook.sh', cmd
cmd2 = d['hooks']['Stop'][0]['hooks'][0]['command']
assert cmd2 == '$real_root/scripts/stop_hook_inbox.sh', cmd2
print('ok')
"
    [ "$status" -eq 0 ]

    # プレースホルダが残っていないこと
    run grep -c "__PROJECT_ROOT__" "$TEST_TMP/.codex/hooks.json"
    [ "$status" -ne 0 ]
}

# ─── T-CODEX-SS-003〜006: 全roleの正本instructionsパス ───

@test "T-CODEX-SS-003: codex/shogun は instructions/generated/codex-shogun.md を参照する" {
    run env __SESSION_START_HOOK_AGENT_ID="shogun" __SESSION_START_HOOK_LOG_DIR="$TEST_TMP" \
        bash "$SESSION_HOOK" codex
    [ "$status" -eq 0 ]
    [[ "$output" == *"instructions/generated/codex-shogun.md"* ]]
}

@test "T-CODEX-SS-004: codex/karo は instructions/generated/codex-karo.md を参照する" {
    run env __SESSION_START_HOOK_AGENT_ID="karo" __SESSION_START_HOOK_LOG_DIR="$TEST_TMP" \
        bash "$SESSION_HOOK" codex
    [ "$status" -eq 0 ]
    [[ "$output" == *"instructions/generated/codex-karo.md"* ]]
    # Claude版の特例(instructions/generated/karo.md、codex-接頭辞なし)が誤って混入していないこと
    [[ "$output" != *"instructions/generated/karo.md"* ]]
}

@test "T-CODEX-SS-005: codex/gunshi は instructions/generated/codex-gunshi.md を参照する" {
    run env __SESSION_START_HOOK_AGENT_ID="gunshi" __SESSION_START_HOOK_LOG_DIR="$TEST_TMP" \
        bash "$SESSION_HOOK" codex
    [ "$status" -eq 0 ]
    [[ "$output" == *"instructions/generated/codex-gunshi.md"* ]]
}

@test "T-CODEX-SS-006: codex/ashigaru は queue/tasks/{id}.yaml を参照し、instructions再読を求めない" {
    run env __SESSION_START_HOOK_AGENT_ID="ashigaru3" __SESSION_START_HOOK_LOG_DIR="$TEST_TMP" \
        bash "$SESSION_HOOK" codex
    [ "$status" -eq 0 ]
    [[ "$output" == *"queue/tasks/ashigaru3.yaml"* ]]
    [[ "$output" == *"instructions/generated/codex-ashigaru.md"* ]]
}

# ─── T-CODEX-SS-007: AGENTS.md/`/new` 言及、CLAUDE.md/`/clear` 前提の不在 ───

@test "T-CODEX-SS-007a: codex/karo(command-layer)はAGENTS.mdと/newに言及し、CLAUDE.mdには言及しない" {
    run env __SESSION_START_HOOK_AGENT_ID="karo" __SESSION_START_HOOK_LOG_DIR="$TEST_TMP" \
        bash "$SESSION_HOOK" codex
    [ "$status" -eq 0 ]
    [[ "$output" == *"AGENTS.md"* ]]
    [[ "$output" == *"/new"* ]]
    [[ "$output" != *"CLAUDE.md"* ]]
    [[ "$output" != *"「/clear Recovery"* ]]
}

@test "T-CODEX-SS-007b: codex/ashigaruはAGENTS.mdと/newに言及し、CLAUDE.mdには言及しない" {
    run env __SESSION_START_HOOK_AGENT_ID="ashigaru5" __SESSION_START_HOOK_LOG_DIR="$TEST_TMP" \
        bash "$SESSION_HOOK" codex
    [ "$status" -eq 0 ]
    [[ "$output" == *"AGENTS.md"* ]]
    [[ "$output" == *"/new"* ]]
    [[ "$output" != *"CLAUDE.md"* ]]
}

# ─── T-CODEX-SS-008: 空agent fail-safe (codex wrapper) ───

@test "T-CODEX-SS-008: 空agent_idではcodex wrapperは{}を返しexit 0" {
    run bash -c "echo '{}' | __SESSION_START_HOOK_AGENT_ID='' __SESSION_START_HOOK_LOG_DIR='$TEST_TMP' bash '$CODEX_WRAPPER'"
    [ "$status" -eq 0 ]
    [ "$output" = "{}" ]
}

# ─── T-CODEX-SS-009: 空agent fail-safe (claude, 無引数) — 既存動作の非退行 ───

@test "T-CODEX-SS-009: 空agent_idではclaude(無引数)は無出力でexit 0" {
    run env __SESSION_START_HOOK_AGENT_ID="" __SESSION_START_HOOK_LOG_DIR="$TEST_TMP" \
        bash "$SESSION_HOOK"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ─── T-CODEX-SS-010: claude(無引数)の非退行確認 ───

@test "T-CODEX-SS-010: claude(無引数)のkaroはinstructions/generated/karo.mdを参照し、AGENTS.md/codex wrapperには言及しない" {
    run env __SESSION_START_HOOK_AGENT_ID="karo" __SESSION_START_HOOK_LOG_DIR="$TEST_TMP" \
        bash "$SESSION_HOOK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"instructions/generated/karo.md"* ]]
    [[ "$output" != *"AGENTS.md"* ]]
    [[ "$output" != *"codex_session_start_hook.sh"* ]]
}

# ─── T-CODEX-SS-011: Stop配線の確認 ───

@test "T-CODEX-SS-011: hooks.json.templateのStop配線はstop_hook_inbox.shを参照する" {
    run python3 -c "
import json
d = json.load(open('$TEMPLATE'))
cmd = d['hooks']['Stop'][0]['hooks'][0]['command']
assert cmd.endswith('scripts/stop_hook_inbox.sh'), cmd
print('ok')
"
    [ "$status" -eq 0 ]
}

# ─── T-CODEX-SS-012: JSON封筒の形式確認 ───

@test "T-CODEX-SS-012: codex wrapperの出力はSessionStart用JSON封筒である" {
    run bash -c "echo '{}' | __SESSION_START_HOOK_AGENT_ID='ashigaru1' __SESSION_START_HOOK_LOG_DIR='$TEST_TMP' bash '$CODEX_WRAPPER'"
    [ "$status" -eq 0 ]

    printf '%s' "$output" > "$TEST_TMP/wrapper_output.json"
    run python3 -c "
import json
d = json.load(open('$TEST_TMP/wrapper_output.json'))
assert d['hookSpecificOutput']['hookEventName'] == 'SessionStart'
assert 'additionalContext' in d['hookSpecificOutput']
assert len(d['hookSpecificOutput']['additionalContext']) > 0
print('ok')
"
    [ "$status" -eq 0 ]
}

# ─── T-CODEX-SS-013: フォールバック分岐もAGENTS.mdを参照する ───

@test "T-CODEX-SS-013: codexの未知agent_idでもAGENTS.mdを参照し、CLAUDE.mdには言及しない" {
    run env __SESSION_START_HOOK_AGENT_ID="mysteryagent" __SESSION_START_HOOK_LOG_DIR="$TEST_TMP" \
        bash "$SESSION_HOOK" codex
    [ "$status" -eq 0 ]
    [[ "$output" == *"AGENTS.md"* ]]
    [[ "$output" != *"CLAUDE.md"* ]]
}

# ─── T-CODEX-SS-014・015: codex wrapper 経由のend-to-end内容検証 ───
# ★T-003〜007bはsession_start_hook.shを直接叩いており、
#   「wrapperがcodex引数を渡し忘れる」という実際のG757-CODEX-PERSONA-PATH-01型
#   regression(=wrapperがsession_start_hook.shを無引数で呼ぶ)を検知できない
#   (旧バグを実際に再現させて確認済み: T-001〜013は全てokのまま素通りした)。
#   wrapper (codex_session_start_hook.sh) を経由した内容検証を別途必須とする。

extract_additional_context() {
    # $1: wrapper JSON 出力ファイル, $2: 抽出先テキストファイル
    python3 -c "
import json
d = json.load(open('$1'))
with open('$2', 'w', encoding='utf-8') as f:
    f.write(d['hookSpecificOutput']['additionalContext'])
"
}

@test "T-CODEX-SS-014: codex wrapper経由(karo)はinstructions/generated/codex-karo.mdとAGENTS.md/newを含み、CLAUDE.mdは含まない" {
    run bash -c "echo '{}' | __SESSION_START_HOOK_AGENT_ID='karo' __SESSION_START_HOOK_LOG_DIR='$TEST_TMP' bash '$CODEX_WRAPPER'"
    [ "$status" -eq 0 ]
    printf '%s' "$output" > "$TEST_TMP/wrapper_karo.json"
    extract_additional_context "$TEST_TMP/wrapper_karo.json" "$TEST_TMP/wrapper_karo.txt"

    ctx="$(cat "$TEST_TMP/wrapper_karo.txt")"
    [[ "$ctx" == *"instructions/generated/codex-karo.md"* ]]
    [[ "$ctx" == *"AGENTS.md"* ]]
    [[ "$ctx" == *"/new"* ]]
    [[ "$ctx" != *"CLAUDE.md"* ]]
    [[ "$ctx" != *"instructions/generated/karo.md"* ]]
}

@test "T-CODEX-SS-015: codex wrapper経由(ashigaru)はqueue/tasks/{id}.yamlとAGENTS.mdを含み、CLAUDE.mdは含まない" {
    run bash -c "echo '{}' | __SESSION_START_HOOK_AGENT_ID='ashigaru7' __SESSION_START_HOOK_LOG_DIR='$TEST_TMP' bash '$CODEX_WRAPPER'"
    [ "$status" -eq 0 ]
    printf '%s' "$output" > "$TEST_TMP/wrapper_ashigaru.json"
    extract_additional_context "$TEST_TMP/wrapper_ashigaru.json" "$TEST_TMP/wrapper_ashigaru.txt"

    ctx="$(cat "$TEST_TMP/wrapper_ashigaru.txt")"
    [[ "$ctx" == *"queue/tasks/ashigaru7.yaml"* ]]
    [[ "$ctx" == *"AGENTS.md"* ]]
    [[ "$ctx" != *"CLAUDE.md"* ]]
}

# ─── T-CODEX-SS-016: 実行bit網羅 (cmd_757④redo2, G757-CODEX-EXECBIT-COVERAGE-REDO1-03是正) ───
# ★T-CODEX-SS-002は隔離コピー内でgenerate_codex_hooks.sh自身の-xしか検証しておらず、
#   hooks.jsonが実際に直接起動する codex_session_start_hook.sh / stop_hook_inbox.sh の
#   実行bit喪失を検知できなかった。本testは実プロジェクトの実体ファイルに対し、
#   __PROJECT_ROOT__展開後の絶対パス・実在・通常file・実行可能の4点を全commandについて検証する。

@test "T-CODEX-SS-016: hooks.json.templateの各commandは__PROJECT_ROOT__展開後、絶対パス・実在・通常file・実行可能である" {
    run python3 -c "
import json
d = json.load(open('$TEMPLATE'))
print(d['hooks']['SessionStart'][0]['hooks'][0]['command'])
print(d['hooks']['Stop'][0]['hooks'][0]['command'])
"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]

    ss_abs="${lines[0]/__PROJECT_ROOT__/$SCRIPT_DIR}"
    stop_abs="${lines[1]/__PROJECT_ROOT__/$SCRIPT_DIR}"

    # SessionStart command: scripts/codex_session_start_hook.sh
    [[ "$ss_abs" == /* ]]
    [ -e "$ss_abs" ]
    [ -f "$ss_abs" ]
    [ -x "$ss_abs" ]

    # Stop command: scripts/stop_hook_inbox.sh
    [[ "$stop_abs" == /* ]]
    [ -e "$stop_abs" ]
    [ -f "$stop_abs" ]
    [ -x "$stop_abs" ]
}

# ─── T-CODEX-SS-017: 足軽回復契約テスト (cmd_757④redo2, G757-CODEX-TEST-MISSES-CONTRACT-REDO1-04是正) ───
# ★旧テスト(T-003〜007b)は「queue/tasks/{id}.yamlとinstructions/generated/codex-ashigaru.mdへの
#   言及」しか検証しておらず、G757-CODEX-ASHIGARU-RECOVERY-REDO1-01(自己識別Step欠落・
#   非schemaのwork条件を暗示する「assignedかつwork」誤記)を16件全PASSのまま見逃した。
#   本testは(a)tmux自己識別command (b)assigned即実行 (c)idle/done待機 の3点の存在と、
#   (d)非schemaのwork条件(AND表現)の不在を固定する。

@test "T-CODEX-SS-017: codex/ashigaruはtmux自己識別Step・assigned即実行・idle/done待機を含み、非schemaのwork条件(AND表現)を含まない" {
    run env __SESSION_START_HOOK_AGENT_ID="ashigaru2" __SESSION_START_HOOK_LOG_DIR="$TEST_TMP" \
        bash "$SESSION_HOOK" codex
    [ "$status" -eq 0 ]

    # (a) 自己識別: モデル自身がtmuxコマンドを実行するstepが明記されている
    [[ "$output" == *'tmux display-message -t "$TMUX_PANE" -p'* ]]

    # (b) assigned即実行 (AGENTS.md「/new Recovery」Step2に逐語一致)
    [[ "$output" == *"assigned=work (execute task)"* ]]

    # (c) idle/done待機 (AGENTS.md「/new Recovery」Step2に逐語一致)
    [[ "$output" == *"idle=wait"* ]]
    [[ "$output" == *"done=wait"* ]]

    # (d) 非schemaのwork条件(AND表現)が存在しない — 旧バグ文言の再発防止
    [[ "$output" != *"assigned かつ work"* ]]
    [[ "$output" != *"assignedかつwork"* ]]
    [[ "$output" != *"assigned且つwork"* ]]
}

@test "T-CODEX-SS-018: codex wrapper経由(ashigaru)でもtmux自己識別Step・assigned即実行が保持される(end-to-end)" {
    run bash -c "echo '{}' | __SESSION_START_HOOK_AGENT_ID='ashigaru4' __SESSION_START_HOOK_LOG_DIR='$TEST_TMP' bash '$CODEX_WRAPPER'"
    [ "$status" -eq 0 ]
    printf '%s' "$output" > "$TEST_TMP/wrapper_ashigaru4.json"
    extract_additional_context "$TEST_TMP/wrapper_ashigaru4.json" "$TEST_TMP/wrapper_ashigaru4.txt"

    ctx="$(cat "$TEST_TMP/wrapper_ashigaru4.txt")"
    [[ "$ctx" == *'tmux display-message -t "$TMUX_PANE" -p'* ]]
    [[ "$ctx" == *"assigned=work (execute task)"* ]]
    [[ "$ctx" != *"assigned かつ work"* ]]
}
