#!/usr/bin/env bats
# test_cli_adapter.bats — cli_adapter.sh ユニットテスト
# Multi-CLI統合設計書 §4.1 準拠

# --- セットアップ ---

setup() {
    unset PERMISSION_FLAG

    # テスト用のtmpディレクトリ
    TEST_TMP="$(mktemp -d)"

    # プロジェクトルート
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

    # ★実 tmux の隔離 (cmd_791 A)
    #   find_agent_for_model() は候補足軽の実 pane を `tmux list-panes -a` で
    #   逆引きし agent_is_busy_check() へ掛ける。T-1〜T-3 は「tmux セッションが
    #   存在しない」ことを前提に期待値を置いているが、稼働中の足軽 pane を持つ
    #   環境ではその前提が崩れ、pane の busy/idle で結果が変わっていた
    #   (T-3 は該当足軽が busy だと SWITCH が返らず FAIL)。
    #   ★T-1〜T-3 の題名の「該当足軽なし」等は fixture が作る tier の有無を指す。
    #     隔離下では pane が引けず候補は空き(pane 不在)扱いとなり、busy 判定経路は
    #     通らない。busy 判定そのものの検査は T-BUSY 群(test_send_wakeup.bats)の責務。
    #   tmux クライアントの到達先を、この試験専用の空領域へ向けて実 tmux サーバ
    #   へ届かなくする。★$TMUX(稼働中サーバのソケット)が設定されていると tmux は
    #   TMUX_TMPDIR より$TMUX を優先するため、TMUX_TMPDIR の切替と unset の
    #   両方が要る。片方だけでは隔離にならない。
    #   ★領域は TEST_TMP(上の mktemp -d)の配下ゆえ、teardown の既存の後始末に
    #     含まれる。ここでは何も削除しない。
    mkdir -p "${TEST_TMP}/tmux_none"
    export TMUX_TMPDIR="${TEST_TMP}/tmux_none"
    unset TMUX TMUX_PANE

    # デフォルトsettings（cliセクションなし = 後方互換テスト）
    cat > "${TEST_TMP}/settings_none.yaml" << 'YAML'
language: ja
shell: bash
display_mode: shout
YAML

    # claude only settings
    cat > "${TEST_TMP}/settings_claude_only.yaml" << 'YAML'
cli:
  default: claude
YAML

    # mixed CLI settings (dict形式)
    cat > "${TEST_TMP}/settings_mixed.yaml" << 'YAML'
cli:
  default: claude
  agents:
    shogun:
      type: claude
      model: opus
    karo:
      type: claude
      model: opus
    ashigaru1:
      type: claude
      model: sonnet
    ashigaru2:
      type: claude
      model: sonnet
    ashigaru3:
      type: claude
      model: sonnet
    ashigaru4:
      type: claude
      model: sonnet
    ashigaru5:
      type: codex
    ashigaru6:
      type: codex
    ashigaru7:
      type: copilot
    ashigaru8:
      type: copilot
YAML

    # 文字列形式のagent設定
    cat > "${TEST_TMP}/settings_string_agents.yaml" << 'YAML'
cli:
  default: claude
  agents:
    ashigaru5: codex
    ashigaru7: copilot
YAML

    # 不正CLI名
    cat > "${TEST_TMP}/settings_invalid_cli.yaml" << 'YAML'
cli:
  default: claudee
  agents:
    ashigaru1: invalid_cli
YAML

    # codexデフォルト
    cat > "${TEST_TMP}/settings_codex_default.yaml" << 'YAML'
cli:
  default: codex
YAML

    # 空ファイル
    cat > "${TEST_TMP}/settings_empty.yaml" << 'YAML'
YAML

    # YAML構文エラー
    cat > "${TEST_TMP}/settings_broken.yaml" << 'YAML'
cli:
  default: [broken yaml
  agents: {{invalid
YAML

    # モデル指定付き
    cat > "${TEST_TMP}/settings_with_models.yaml" << 'YAML'
cli:
  default: claude
  agents:
    ashigaru1:
      type: claude
      model: haiku
    ashigaru5:
      type: codex
      model: gpt-5
models:
  karo: sonnet
YAML

    # kimi CLI settings
    cat > "${TEST_TMP}/settings_kimi.yaml" << 'YAML'
cli:
  default: claude
  agents:
    ashigaru3:
      type: kimi
      model: k2.5
    ashigaru4:
      type: kimi
YAML

    # kimi default settings
    cat > "${TEST_TMP}/settings_kimi_default.yaml" << 'YAML'
cli:
  default: kimi
YAML

    # find_agent_for_model T-1: 完全一致回帰 (sonnet 該当足軽あり・pane 不在=空き扱い → ashigaru2)
    cat > "${TEST_TMP}/settings_tier_t1.yaml" << 'YAML'
capability_tiers:
  claude-sonnet-4-6:
    max_bloom: 5
  claude-opus-4-6:
    max_bloom: 6
cli:
  default: claude
  agents:
    ashigaru1:
      type: claude
      model: claude-opus-4-6
    ashigaru2:
      type: claude
      model: claude-sonnet-4-6
YAML

    # find_agent_for_model T-2: 上位tierフォールバック (sonnet 該当足軽なし・opus のみ存在 → ashigaru1)
    cat > "${TEST_TMP}/settings_tier_t2.yaml" << 'YAML'
capability_tiers:
  claude-sonnet-4-6:
    max_bloom: 5
  claude-opus-4-6:
    max_bloom: 6
cli:
  default: claude
  agents:
    ashigaru1:
      type: claude
      model: claude-opus-4-6
YAML

    # find_agent_for_model T-3: 下位tierフォールバック (sonnet/opus 該当足軽なし・haiku のみ存在 → SWITCH)
    cat > "${TEST_TMP}/settings_tier_t3.yaml" << 'YAML'
capability_tiers:
  claude-sonnet-4-6:
    max_bloom: 5
  claude-haiku-4-5-20251001:
    max_bloom: 2
cli:
  default: claude
  agents:
    ashigaru3:
      type: claude
      model: claude-haiku-4-5-20251001
YAML

    # opencode settings
    cat > "${TEST_TMP}/settings_opencode.yaml" << 'YAML'
cli:
  default: opencode
  agents:
    shogun:
      type: opencode
      model: openai/gpt-5.4-mini
    karo:
      type: opencode
      model: gpt-5.4
    gunshi:
      type: opencode
      model: anthropic/claude-opus-4-6
    ashigaru1:
      type: opencode
      model: k2.5
    ashigaru2:
      type: opencode
      model: moonshot-k2.5
    ashigaru3:
      type: opencode
      model: claude-sonnet-4-6
    ashigaru4:
      type: opencode
      model: gpt-5.3-codex-spark
    ashigaru5:
      type: opencode
      model: openrouter/minimax/minimax-m2.5
      variant: xhigh
YAML

    # Claude系全エージェント(shogun/karo/ashigaru1〜7)+ gunshi(非Claude・codex)
    # cmd_759 redo1 G759-TEST-COVERAGE-05: --name付与の検査範囲を
    # 「ashigaru1..7全て」という試験名の実態に一致させるためのfixture。
    # gunshiは実運用でも非Claudeであり(config/settings.yaml参照)、
    # ここでも意図して区別する(claude以外には--nameを付与しない設計を
    # 併せて検証するため)。
    cat > "${TEST_TMP}/settings_all_claude.yaml" << 'YAML'
cli:
  default: claude
  agents:
    shogun:
      type: claude
      model: opus
    karo:
      type: claude
      model: opus
    ashigaru1:
      type: claude
      model: sonnet
    ashigaru2:
      type: claude
      model: sonnet
    ashigaru3:
      type: claude
      model: sonnet
    ashigaru4:
      type: claude
      model: sonnet
    ashigaru5:
      type: claude
      model: sonnet
    ashigaru6:
      type: claude
      model: sonnet
    ashigaru7:
      type: claude
      model: sonnet
    gunshi:
      type: codex
      model: gpt-5.6-sol
YAML
}

# =============================================================================
# normalize_opencode_model / shell quote テスト
# =============================================================================

@test "normalize_opencode_model: 空文字 → 空文字" {
    load_adapter_with "${TEST_TMP}/settings_opencode.yaml"
    result=$(normalize_opencode_model "")
    [ "$result" = "" ]
}

@test "normalize_opencode_model: 既知aliasを provider/model に正規化" {
    load_adapter_with "${TEST_TMP}/settings_opencode.yaml"
    [ "$(normalize_opencode_model gpt-5.4-mini)" = "openai/gpt-5.4-mini" ]
    [ "$(normalize_opencode_model gpt-5.3-codex-spark)" = "openai/gpt-5.3-codex-spark" ]
    [ "$(normalize_opencode_model opus)" = "anthropic/claude-opus-5-5" ]
    [ "$(normalize_opencode_model sonnet)" = "anthropic/claude-sonnet-5-5" ]
    [ "$(normalize_opencode_model haiku)" = "anthropic/claude-haiku-4-5-20251001" ]
    [ "$(normalize_opencode_model k2.5)" = "moonshot/kimi-k2.5" ]
    [ "$(normalize_opencode_model moonshot-k2.5)" = "moonshot/kimi-k2.5" ]
    [ "$(normalize_opencode_model kimi-k2.5)" = "moonshot/kimi-k2.5" ]
    [ "$(normalize_opencode_model kimi-k2-turbo)" = "moonshot/kimi-k2-turbo" ]
}

@test "normalize_opencode_model: cmd_783 新モデル(fable/opus-5.5/sonnet-5.5/gpt-6系)が正しく正規化される" {
    load_adapter_with "${TEST_TMP}/settings_opencode.yaml"
    [ "$(normalize_opencode_model fable)" = "anthropic/claude-fable-5-1" ]
    [ "$(normalize_opencode_model claude-fable-5-1)" = "anthropic/claude-fable-5-1" ]
    [ "$(normalize_opencode_model claude-opus-5-5)" = "anthropic/claude-opus-5-5" ]
    [ "$(normalize_opencode_model claude-sonnet-5-5)" = "anthropic/claude-sonnet-5-5" ]
    [ "$(normalize_opencode_model gpt-6-sol)" = "openai/gpt-6-sol" ]
    [ "$(normalize_opencode_model gpt-6-luna)" = "openai/gpt-6-luna" ]
    [ "$(normalize_opencode_model gpt-reserve)" = "openai/gpt-reserve" ]
    # G783-02是正(cmd_783 Phase1 redo1): 別名opus/sonnetは5.5系へ移した。
    # 明示ID claude-opus-4-6/claude-sonnet-4-6 は旧版互換として残し、
    # 削除せずそれぞれの4.6系へ解決され続けることを併せて確認する。
    [ "$(normalize_opencode_model opus)" = "anthropic/claude-opus-5-5" ]
    [ "$(normalize_opencode_model sonnet)" = "anthropic/claude-sonnet-5-5" ]
    [ "$(normalize_opencode_model claude-opus-4-6)" = "anthropic/claude-opus-4-6" ]
    [ "$(normalize_opencode_model claude-sonnet-4-6)" = "anthropic/claude-sonnet-4-6" ]
}

# cmd_799 ⑥: ドット付きの版(現行の軍師モデル名 gpt-6.1-sol 等)も openai/ に正規化される。
# これは provider の付与であり codex 型の自動判定(switch_cli.sh Step 0.5)とは目的が別で、
# gpt-* を広く openai/ へ寄せる。scripts/build_instructions.sh 内の同名の正規化とも同じ結果になる。
@test "normalize_opencode_model: cmd_799 ドット付きの版(gpt-6.1-sol / gpt-6.2-luna)も openai/ に正規化される" {
    load_adapter_with "${TEST_TMP}/settings_opencode.yaml"
    [ "$(normalize_opencode_model gpt-6.1-sol)" = "openai/gpt-6.1-sol" ]
    [ "$(normalize_opencode_model gpt-6.2-luna)" = "openai/gpt-6.2-luna" ]
    [ "$(normalize_opencode_model gpt-5.6-sol)" = "openai/gpt-5.6-sol" ]
}

@test "normalize_opencode_model: provider-qualified と未知モデルはそのまま" {
    load_adapter_with "${TEST_TMP}/settings_opencode.yaml"
    [ "$(normalize_opencode_model anthropic/claude-sonnet-4-6)" = "anthropic/claude-sonnet-4-6" ]
    [ "$(normalize_opencode_model custom-provider/custom-model)" = "custom-provider/custom-model" ]
    [ "$(normalize_opencode_model unknown-model)" = "unknown-model" ]
}

@test "_cli_adapter_shell_quote: .venv 不在時は bash fallback で quote" {
    load_adapter_with "${TEST_TMP}/settings_opencode.yaml"
    CLI_ADAPTER_PROJECT_ROOT="${TEST_TMP}/no_venv_root"
    mkdir -p "$CLI_ADAPTER_PROJECT_ROOT"

    sample='path with spaces $HOME'
    quoted=$(_cli_adapter_shell_quote "$sample")
    eval "roundtrip=$quoted"

    [ "$roundtrip" = "$sample" ]
}

teardown() {
    unset PERMISSION_FLAG
    rm -rf "$TEST_TMP"
}

# ヘルパー: 特定のsettings.yamlでcli_adapterをロード
load_adapter_with() {
    local settings_file="$1"
    export CLI_ADAPTER_SETTINGS="$settings_file"
    source "${PROJECT_ROOT}/lib/cli_adapter.sh"
}

# =============================================================================
# get_cli_type テスト
# =============================================================================

# --- 正常系 ---

@test "get_cli_type: cliセクションなし → claude (後方互換)" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    result=$(get_cli_type "shogun")
    [ "$result" = "claude" ]
}

@test "get_cli_type: claude only設定 → claude" {
    load_adapter_with "${TEST_TMP}/settings_claude_only.yaml"
    result=$(get_cli_type "ashigaru1")
    [ "$result" = "claude" ]
}

@test "get_cli_type: mixed設定 shogun → claude" {
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    result=$(get_cli_type "shogun")
    [ "$result" = "claude" ]
}

@test "get_cli_type: mixed設定 ashigaru5 → codex" {
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    result=$(get_cli_type "ashigaru5")
    [ "$result" = "codex" ]
}

@test "get_cli_type: mixed設定 ashigaru7 → copilot" {
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    result=$(get_cli_type "ashigaru7")
    [ "$result" = "copilot" ]
}

@test "get_cli_type: mixed設定 ashigaru1 → claude (個別設定)" {
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    result=$(get_cli_type "ashigaru1")
    [ "$result" = "claude" ]
}

@test "get_cli_type: 文字列形式 ashigaru5 → codex" {
    load_adapter_with "${TEST_TMP}/settings_string_agents.yaml"
    result=$(get_cli_type "ashigaru5")
    [ "$result" = "codex" ]
}

@test "get_cli_type: 文字列形式 ashigaru7 → copilot" {
    load_adapter_with "${TEST_TMP}/settings_string_agents.yaml"
    result=$(get_cli_type "ashigaru7")
    [ "$result" = "copilot" ]
}

@test "get_cli_type: kimi設定 ashigaru3 → kimi" {
    load_adapter_with "${TEST_TMP}/settings_kimi.yaml"
    result=$(get_cli_type "ashigaru3")
    [ "$result" = "kimi" ]
}

@test "get_cli_type: kimi設定 ashigaru4 → kimi (モデル指定なし)" {
    load_adapter_with "${TEST_TMP}/settings_kimi.yaml"
    result=$(get_cli_type "ashigaru4")
    [ "$result" = "kimi" ]
}

@test "get_cli_type: kimiデフォルト設定 → kimi" {
    load_adapter_with "${TEST_TMP}/settings_kimi_default.yaml"
    result=$(get_cli_type "ashigaru1")
    [ "$result" = "kimi" ]
}

@test "get_cli_type: opencode設定 shogun → opencode" {
    load_adapter_with "${TEST_TMP}/settings_opencode.yaml"
    result=$(get_cli_type "shogun")
    [ "$result" = "opencode" ]
}

@test "get_cli_type: opencode default → opencode" {
    load_adapter_with "${TEST_TMP}/settings_opencode.yaml"
    result=$(get_cli_type "unknown_agent")
    [ "$result" = "opencode" ]
}

@test "get_cli_type: 未定義agent → default継承" {
    load_adapter_with "${TEST_TMP}/settings_codex_default.yaml"
    result=$(get_cli_type "ashigaru3")
    [ "$result" = "codex" ]
}

@test "get_cli_type: 空agent_id → claude" {
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    result=$(get_cli_type "")
    [ "$result" = "claude" ]
}

# --- 全ashigaru パターン ---

@test "get_cli_type: mixed設定 ashigaru1-8全パターン" {
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    [ "$(get_cli_type ashigaru1)" = "claude" ]
    [ "$(get_cli_type ashigaru2)" = "claude" ]
    [ "$(get_cli_type ashigaru3)" = "claude" ]
    [ "$(get_cli_type ashigaru4)" = "claude" ]
    [ "$(get_cli_type ashigaru5)" = "codex" ]
    [ "$(get_cli_type ashigaru6)" = "codex" ]
    [ "$(get_cli_type ashigaru7)" = "copilot" ]
    [ "$(get_cli_type ashigaru8)" = "copilot" ]
}

# --- エラー系 ---

@test "get_cli_type: 不正CLI名 → claude フォールバック" {
    load_adapter_with "${TEST_TMP}/settings_invalid_cli.yaml"
    result=$(get_cli_type "ashigaru1")
    [ "$result" = "claude" ]
}

@test "get_cli_type: 不正default → claude フォールバック" {
    load_adapter_with "${TEST_TMP}/settings_invalid_cli.yaml"
    result=$(get_cli_type "karo")
    [ "$result" = "claude" ]
}

@test "get_cli_type: 空YAMLファイル → claude" {
    load_adapter_with "${TEST_TMP}/settings_empty.yaml"
    result=$(get_cli_type "shogun")
    [ "$result" = "claude" ]
}

@test "get_cli_type: YAML構文エラー → claude" {
    load_adapter_with "${TEST_TMP}/settings_broken.yaml"
    result=$(get_cli_type "ashigaru1")
    [ "$result" = "claude" ]
}

@test "get_cli_type: 存在しないファイル → claude" {
    load_adapter_with "/nonexistent/path/settings.yaml"
    result=$(get_cli_type "shogun")
    [ "$result" = "claude" ]
}

# =============================================================================
# build_cli_command テスト
# =============================================================================

@test "build_cli_command: claude + model → claude --model opus --name shogun --dangerously-skip-permissions" {
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    result=$(build_cli_command "shogun")
    [ "$result" = "claude --model opus --name shogun --dangerously-skip-permissions" ]
}

@test "build_cli_command: PERMISSION_FLAG override → claude --permission-mode auto-approved" {
    PERMISSION_FLAG="--permission-mode auto-approved"
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    result=$(build_cli_command "shogun")
    [ "$result" = "claude --model opus --name shogun --permission-mode auto-approved" ]
}

@test "build_cli_command: claude --name値はagent_idとbyte一致する(shogun/karo/ashigaru1..7全て)" {
    # cmd_759 redo1 G759-TEST-COVERAGE-05: 旧版はsettings_mixed.yamlを使い
    # shogun/karo/ashigaru1-4の6値のみを検査しており、試験名の「ashigaru1..7
    # 全て」と実態が食い違っていた。settings_all_claude.yaml(shogun/karo/
    # ashigaru1〜7が全てclaude)へ切り替え、試験名どおりの範囲を検査する。
    load_adapter_with "${TEST_TMP}/settings_all_claude.yaml"
    for agent in shogun karo ashigaru1 ashigaru2 ashigaru3 ashigaru4 ashigaru5 ashigaru6 ashigaru7; do
        result=$(build_cli_command "$agent")
        [[ "$result" == *" --name ${agent} "* || "$result" == *" --name ${agent}" ]]
    done
}

@test "build_cli_command: gunshi(非Claude・codex)には--nameを付与しない" {
    # cmd_759 redo1 G759-TEST-COVERAGE-05: gunshiは実運用でも非Claude
    # (config/settings.yaml参照)であり、Claude系全エージェント検査からは
    # 意図して除外・区別する。build_cli_commandのclaude以外分岐には
    # そもそも--nameの付与ロジックが無いことを明示的に固定する。
    load_adapter_with "${TEST_TMP}/settings_all_claude.yaml"
    result=$(build_cli_command "gunshi")
    [[ "$result" != *"--name"* ]]
}

@test "build_cli_command: codex + default model → codex --model sonnet ..." {
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    expected_prompt_arg=$(get_startup_prompt_arg "ashigaru5")
    result=$(build_cli_command "ashigaru5")
    [ "$result" = "codex --model sonnet --search --dangerously-bypass-approvals-and-sandbox --no-alt-screen $expected_prompt_arg" ]
}

@test "build_cli_command: copilot → copilot --yolo" {
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    result=$(build_cli_command "ashigaru7")
    [ "$result" = "copilot --yolo" ]
}

@test "build_cli_command: kimi + model → kimi --yolo --model k2.5" {
    load_adapter_with "${TEST_TMP}/settings_kimi.yaml"
    result=$(build_cli_command "ashigaru3")
    [ "$result" = "kimi --yolo --model k2.5" ]
}

@test "build_cli_command: kimi (モデル指定なし) → kimi --yolo --model k2.5" {
    load_adapter_with "${TEST_TMP}/settings_kimi.yaml"
    result=$(build_cli_command "ashigaru4")
    [ "$result" = "kimi --yolo --model k2.5" ]
}

@test "build_cli_command: opencode shogun → --agent shogun + pinned tui config" {
    load_adapter_with "${TEST_TMP}/settings_opencode.yaml"
    result=$(build_cli_command "shogun")
    expected_tui_config=$(_cli_adapter_shell_quote "${PROJECT_ROOT}/config/opencode-tui.json")
    [[ "$result" == "OPENCODE_AGENT_ID=shogun OPENCODE_TUI_CONFIG=$expected_tui_config"* ]]
    [[ "$result" == *'opencode --model openai/gpt-5.4-mini --agent shogun'* ]]
    # No OPENCODE_CONFIG_CONTENT — permissions are in .opencode/agents/shogun.md
    [[ "$result" != *'OPENCODE_CONFIG_CONTENT'* ]]
    # No --prompt — system prompt loaded from .opencode/agents/shogun.md
    [[ "$result" != *'--prompt'* ]]
}

@test "build_cli_command: opencode karo → --agent karo + pinned tui config" {
    load_adapter_with "${TEST_TMP}/settings_opencode.yaml"
    result=$(build_cli_command "karo")
    expected_tui_config=$(_cli_adapter_shell_quote "${PROJECT_ROOT}/config/opencode-tui.json")
    [[ "$result" == "OPENCODE_AGENT_ID=karo OPENCODE_TUI_CONFIG=$expected_tui_config"* ]]
    [[ "$result" == *'opencode --model openai/gpt-5.4 --agent karo'* ]]
    [[ "$result" != *'OPENCODE_CONFIG_CONTENT'* ]]
    [[ "$result" != *'--prompt'* ]]
}

@test "build_cli_command: opencode ashigaru → --agent ashigaru1 + pinned tui config" {
    load_adapter_with "${TEST_TMP}/settings_opencode.yaml"
    result=$(build_cli_command "ashigaru1")
    expected_tui_config=$(_cli_adapter_shell_quote "${PROJECT_ROOT}/config/opencode-tui.json")
    [[ "$result" == "OPENCODE_AGENT_ID=ashigaru1 OPENCODE_TUI_CONFIG=$expected_tui_config"* ]]
    [[ "$result" == *'opencode --model moonshot/kimi-k2.5 --agent ashigaru1'* ]]
    [[ "$result" != *'OPENCODE_CONFIG_CONTENT'* ]]
    [[ "$result" != *'--prompt'* ]]
}

@test "build_cli_command: opencode gunshi → --agent gunshi + pinned tui config" {
    load_adapter_with "${TEST_TMP}/settings_opencode.yaml"
    result=$(build_cli_command "gunshi")
    expected_tui_config=$(_cli_adapter_shell_quote "${PROJECT_ROOT}/config/opencode-tui.json")
    [[ "$result" == "OPENCODE_AGENT_ID=gunshi OPENCODE_TUI_CONFIG=$expected_tui_config"* ]]
    [[ "$result" == *'opencode --model anthropic/claude-opus-4-6 --agent gunshi'* ]]
    [[ "$result" != *'OPENCODE_CONFIG_CONTENT'* ]]
    [[ "$result" != *'--prompt'* ]]
}

@test "build_cli_command: opencode deterministic output" {
    load_adapter_with "${TEST_TMP}/settings_opencode.yaml"
    first=$(build_cli_command "ashigaru3")
    second=$(build_cli_command "ashigaru3")
    expected_tui_config=$(_cli_adapter_shell_quote "${PROJECT_ROOT}/config/opencode-tui.json")
    [[ "$first" == "$second" ]]
    [[ "$first" == "OPENCODE_AGENT_ID=ashigaru3 OPENCODE_TUI_CONFIG=$expected_tui_config"* ]]
    [[ "$first" == *'opencode --model anthropic/claude-sonnet-4-6 --agent ashigaru3'* ]]
    [[ "$first" != *'OPENCODE_CONFIG_CONTENT'* ]]
    [[ "$first" != *'--prompt'* ]]
}

@test "build_cli_command: opencode omits provider-specific variant from TUI args" {
    load_adapter_with "${TEST_TMP}/settings_opencode.yaml"
    result=$(build_cli_command "ashigaru5")
    expected_tui_config=$(_cli_adapter_shell_quote "${PROJECT_ROOT}/config/opencode-tui.json")
    [[ "$result" == "OPENCODE_AGENT_ID=ashigaru5 OPENCODE_TUI_CONFIG=$expected_tui_config"* ]]
    [[ "$result" == *'opencode --model openrouter/minimax/minimax-m2.5 --agent ashigaru5-runtime'* ]]
    [[ "$result" != *'--variant'* ]]
    [[ "$result" != *'OPENCODE_CONFIG_CONTENT'* ]]
    [[ "$result" != *'--prompt'* ]]
}

@test "opencode tui config pins app_exit and keybinds" {
    grep -q '"app_exit": "none"' "${PROJECT_ROOT}/config/opencode-tui.json"
    grep -q '"session_interrupt": "escape"' "${PROJECT_ROOT}/config/opencode-tui.json"
    grep -q '"input_clear": "ctrl+c,ctrl+u"' "${PROJECT_ROOT}/config/opencode-tui.json"
}

@test "build_cli_command: cliセクションなし → claude フォールバック" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    result=$(build_cli_command "ashigaru1")
    [[ "$result" == claude*--dangerously-skip-permissions ]]
}

@test "build_cli_command: settings読取失敗 → claude フォールバック" {
    load_adapter_with "/nonexistent/settings.yaml"
    result=$(build_cli_command "ashigaru1")
    [[ "$result" == claude*--dangerously-skip-permissions ]]
}

# =============================================================================
# get_instruction_file テスト
# =============================================================================

@test "get_instruction_file: shogun + claude → instructions/shogun.md" {
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    result=$(get_instruction_file "shogun")
    [ "$result" = "instructions/shogun.md" ]
}

@test "get_instruction_file: karo + claude → instructions/karo.md" {
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    result=$(get_instruction_file "karo")
    [ "$result" = "instructions/karo.md" ]
}

@test "get_instruction_file: ashigaru1 + claude → instructions/ashigaru.md" {
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    result=$(get_instruction_file "ashigaru1")
    [ "$result" = "instructions/ashigaru.md" ]
}

@test "get_instruction_file: ashigaru5 + codex → instructions/codex-ashigaru.md" {
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    result=$(get_instruction_file "ashigaru5")
    [ "$result" = "instructions/codex-ashigaru.md" ]
}

@test "get_instruction_file: ashigaru7 + copilot → .github/copilot-instructions-ashigaru.md" {
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    result=$(get_instruction_file "ashigaru7")
    [ "$result" = ".github/copilot-instructions-ashigaru.md" ]
}

@test "get_instruction_file: ashigaru3 + kimi → instructions/generated/kimi-ashigaru.md" {
    load_adapter_with "${TEST_TMP}/settings_kimi.yaml"
    result=$(get_instruction_file "ashigaru3")
    [ "$result" = "instructions/generated/kimi-ashigaru.md" ]
}

@test "get_instruction_file: shogun + kimi → instructions/generated/kimi-shogun.md" {
    load_adapter_with "${TEST_TMP}/settings_kimi_default.yaml"
    result=$(get_instruction_file "shogun")
    [ "$result" = "instructions/generated/kimi-shogun.md" ]
}

@test "get_instruction_file: cli_type引数で明示指定 (codex)" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    result=$(get_instruction_file "shogun" "codex")
    [ "$result" = "instructions/codex-shogun.md" ]
}

@test "get_instruction_file: cli_type引数で明示指定 (copilot)" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    result=$(get_instruction_file "karo" "copilot")
    [ "$result" = ".github/copilot-instructions-karo.md" ]
}

@test "get_instruction_file: 全CLI × 全role組み合わせ" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    # claude
    [ "$(get_instruction_file shogun claude)" = "instructions/shogun.md" ]
    [ "$(get_instruction_file karo claude)" = "instructions/karo.md" ]
    [ "$(get_instruction_file ashigaru1 claude)" = "instructions/ashigaru.md" ]
    # codex
    [ "$(get_instruction_file shogun codex)" = "instructions/codex-shogun.md" ]
    [ "$(get_instruction_file karo codex)" = "instructions/codex-karo.md" ]
    [ "$(get_instruction_file ashigaru3 codex)" = "instructions/codex-ashigaru.md" ]
    # copilot
    [ "$(get_instruction_file shogun copilot)" = ".github/copilot-instructions-shogun.md" ]
    [ "$(get_instruction_file karo copilot)" = ".github/copilot-instructions-karo.md" ]
    [ "$(get_instruction_file ashigaru5 copilot)" = ".github/copilot-instructions-ashigaru.md" ]
    # kimi
    [ "$(get_instruction_file shogun kimi)" = "instructions/generated/kimi-shogun.md" ]
    [ "$(get_instruction_file karo kimi)" = "instructions/generated/kimi-karo.md" ]
    [ "$(get_instruction_file ashigaru7 kimi)" = "instructions/generated/kimi-ashigaru.md" ]
}

@test "get_instruction_file: 不明なagent_id → 空文字 + return 1" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    run get_instruction_file "unknown_agent"
    [ "$status" -eq 1 ]
}

@test "get_instruction_file: opencode + any role → instructions/generated/opencode-shogun.md" {
    load_adapter_with "${TEST_TMP}/settings_opencode.yaml"
    result=$(get_instruction_file "shogun")
    [ "$result" = "instructions/generated/opencode-shogun.md" ]
}

# =============================================================================
# get_startup_prompt テスト
# =============================================================================

@test "get_startup_prompt: opencode shogun → empty (uses --agent, no prompt needed)" {
    load_adapter_with "${TEST_TMP}/settings_opencode.yaml"
    result=$(get_startup_prompt "shogun")
    [ -z "$result" ]
}

@test "get_startup_prompt: opencode karo → empty (uses --agent, no prompt needed)" {
    load_adapter_with "${TEST_TMP}/settings_opencode.yaml"
    result=$(get_startup_prompt "karo")
    [ -z "$result" ]
}

@test "get_startup_prompt: opencode gunshi → empty (uses --agent, no prompt needed)" {
    load_adapter_with "${TEST_TMP}/settings_opencode.yaml"
    result=$(get_startup_prompt "gunshi")
    [ -z "$result" ]
}

@test "get_startup_prompt: opencode ashigaru1 → empty (uses --agent, no prompt needed)" {
    load_adapter_with "${TEST_TMP}/settings_opencode.yaml"
    result=$(get_startup_prompt "ashigaru1")
    [ -z "$result" ]
}

# =============================================================================
# get_startup_prompt_arg テスト
# =============================================================================

@test "get_startup_prompt_arg: codex → positional prompt" {
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    result=$(get_startup_prompt_arg "ashigaru5")
    [[ "$result" != --prompt* ]]
    [[ "$result" == *"Session Start"* ]]
}

@test "get_startup_prompt_arg: opencode → empty (uses --agent instead)" {
    load_adapter_with "${TEST_TMP}/settings_opencode.yaml"
    result=$(get_startup_prompt_arg "shogun")
    [[ "$result" == "" ]]
}

# =============================================================================
# validate_cli_availability テスト
# =============================================================================

@test "validate_cli_availability: claude → 0 (インストール済み)" {
    command -v claude >/dev/null 2>&1 || skip "claude not installed (CI environment)"
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    run validate_cli_availability "claude"
    [ "$status" -eq 0 ]
}

@test "validate_cli_availability: 不正CLI名 → 1 + エラーメッセージ" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    run validate_cli_availability "invalid_type"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown CLI type"* ]]
}

@test "validate_cli_availability: 空文字 → 1" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    run validate_cli_availability ""
    [ "$status" -eq 1 ]
}

@test "validate_cli_availability: codex mock (PATH操作)" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    # モックcodexコマンドを作成
    mkdir -p "${TEST_TMP}/bin"
    echo '#!/bin/bash' > "${TEST_TMP}/bin/codex"
    chmod +x "${TEST_TMP}/bin/codex"
    PATH="${TEST_TMP}/bin:$PATH" run validate_cli_availability "codex"
    [ "$status" -eq 0 ]
}

@test "validate_cli_availability: copilot mock (PATH操作)" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    mkdir -p "${TEST_TMP}/bin"
    echo '#!/bin/bash' > "${TEST_TMP}/bin/copilot"
    chmod +x "${TEST_TMP}/bin/copilot"
    PATH="${TEST_TMP}/bin:$PATH" run validate_cli_availability "copilot"
    [ "$status" -eq 0 ]
}

@test "validate_cli_availability: kimi-cli mock (PATH操作)" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    mkdir -p "${TEST_TMP}/bin"
    echo '#!/bin/bash' > "${TEST_TMP}/bin/kimi-cli"
    chmod +x "${TEST_TMP}/bin/kimi-cli"
    PATH="${TEST_TMP}/bin:$PATH" run validate_cli_availability "kimi"
    [ "$status" -eq 0 ]
}

@test "validate_cli_availability: kimi mock (PATH操作)" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    mkdir -p "${TEST_TMP}/bin"
    echo '#!/bin/bash' > "${TEST_TMP}/bin/kimi"
    chmod +x "${TEST_TMP}/bin/kimi"
    PATH="${TEST_TMP}/bin:$PATH" run validate_cli_availability "kimi"
    [ "$status" -eq 0 ]
}

@test "validate_cli_availability: opencode mock (PATH操作)" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    mkdir -p "${TEST_TMP}/bin"
    echo '#!/bin/bash' > "${TEST_TMP}/bin/opencode"
    chmod +x "${TEST_TMP}/bin/opencode"
    PATH="${TEST_TMP}/bin:$PATH" run validate_cli_availability "opencode"
    [ "$status" -eq 0 ]
}

@test "validate_cli_availability: codex未インストール → 1 + エラーメッセージ" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    # PATHからcodexを除外（空PATHは危険なのでminimal PATHを設定）
    PATH="/usr/bin:/bin" run validate_cli_availability "codex"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Codex CLI not found"* ]]
}

@test "validate_cli_availability: kimi未インストール → 1 + エラーメッセージ" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    PATH="/usr/bin:/bin" run validate_cli_availability "kimi"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Kimi CLI not found"* ]]
}

# =============================================================================
# get_agent_model テスト
# =============================================================================

@test "get_agent_model: cliセクションなし shogun → opus (デフォルト)" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    result=$(get_agent_model "shogun")
    [ "$result" = "opus" ]
}

@test "get_agent_model: cliセクションなし karo → sonnet (デフォルト)" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    result=$(get_agent_model "karo")
    [ "$result" = "sonnet" ]
}

@test "get_agent_model: cliセクションなし ashigaru1 → sonnet (デフォルト)" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    result=$(get_agent_model "ashigaru1")
    [ "$result" = "sonnet" ]
}

@test "get_agent_model: cliセクションなし ashigaru5 → sonnet (デフォルト)" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    result=$(get_agent_model "ashigaru5")
    [ "$result" = "sonnet" ]
}

@test "get_agent_model: YAML指定 ashigaru1 → haiku (オーバーライド)" {
    load_adapter_with "${TEST_TMP}/settings_with_models.yaml"
    result=$(get_agent_model "ashigaru1")
    [ "$result" = "haiku" ]
}

@test "get_agent_model: modelsセクションから取得 karo → sonnet" {
    load_adapter_with "${TEST_TMP}/settings_with_models.yaml"
    result=$(get_agent_model "karo")
    [ "$result" = "sonnet" ]
}

@test "get_agent_model: codexエージェントのmodel ashigaru5 → gpt-5" {
    load_adapter_with "${TEST_TMP}/settings_with_models.yaml"
    result=$(get_agent_model "ashigaru5")
    [ "$result" = "gpt-5" ]
}

@test "get_agent_model: 未知agent → sonnet (デフォルト)" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    result=$(get_agent_model "unknown_agent")
    [ "$result" = "sonnet" ]
}

@test "get_agent_model: kimi CLI ashigaru3 → k2.5 (YAML指定)" {
    load_adapter_with "${TEST_TMP}/settings_kimi.yaml"
    result=$(get_agent_model "ashigaru3")
    [ "$result" = "k2.5" ]
}

@test "get_agent_model: kimi CLI ashigaru4 → k2.5 (デフォルト)" {
    load_adapter_with "${TEST_TMP}/settings_kimi.yaml"
    result=$(get_agent_model "ashigaru4")
    [ "$result" = "k2.5" ]
}

@test "get_agent_model: kimi CLI shogun → k2.5 (デフォルト)" {
    load_adapter_with "${TEST_TMP}/settings_kimi_default.yaml"
    result=$(get_agent_model "shogun")
    [ "$result" = "k2.5" ]
}

@test "get_agent_model: kimi CLI karo → k2.5 (デフォルト)" {
    load_adapter_with "${TEST_TMP}/settings_kimi_default.yaml"
    result=$(get_agent_model "karo")
    [ "$result" = "k2.5" ]
}

# =============================================================================
# get_model_display_name テスト
# =============================================================================

@test "get_model_display_name: Sonnet + thinking:true → Sonnet+T" {
    cat > "${TEST_TMP}/settings_display.yaml" << 'YAML'
cli:
  default: claude
  agents:
    ashigaru1:
      type: claude
      model: claude-sonnet-4-6
      thinking: true
YAML
    load_adapter_with "${TEST_TMP}/settings_display.yaml"
    result=$(get_model_display_name "ashigaru1")
    [ "$result" = "Sonnet+T" ]
}

@test "get_model_display_name: Opus + thinking:true → Opus+T" {
    cat > "${TEST_TMP}/settings_display.yaml" << 'YAML'
cli:
  default: claude
  agents:
    gunshi:
      type: claude
      model: claude-opus-4-6
      thinking: true
YAML
    load_adapter_with "${TEST_TMP}/settings_display.yaml"
    result=$(get_model_display_name "gunshi")
    [ "$result" = "Opus+T" ]
}

@test "get_model_display_name: Haiku + thinking:false → Haiku" {
    cat > "${TEST_TMP}/settings_display.yaml" << 'YAML'
cli:
  default: claude
  agents:
    ashigaru2:
      type: claude
      model: claude-haiku-4-5-20251001
      thinking: false
YAML
    load_adapter_with "${TEST_TMP}/settings_display.yaml"
    result=$(get_model_display_name "ashigaru2")
    [ "$result" = "Haiku" ]
}

@test "get_model_display_name: Sonnet + thinking未設定 → Sonnet+T (default ON)" {
    cat > "${TEST_TMP}/settings_display.yaml" << 'YAML'
cli:
  default: claude
  agents:
    ashigaru3:
      type: claude
      model: claude-sonnet-4-6
YAML
    load_adapter_with "${TEST_TMP}/settings_display.yaml"
    result=$(get_model_display_name "ashigaru3")
    [ "$result" = "Sonnet+T" ]
}

@test "get_model_display_name: Codex Spark → Spark (thinking無関係)" {
    cat > "${TEST_TMP}/settings_display.yaml" << 'YAML'
cli:
  default: claude
  agents:
    ashigaru4:
      type: codex
      model: gpt-5.3-codex-spark
YAML
    load_adapter_with "${TEST_TMP}/settings_display.yaml"
    result=$(get_model_display_name "ashigaru4")
    [ "$result" = "Spark" ]
}

@test "get_model_display_name: Codex 5.3 → Codex5.3" {
    cat > "${TEST_TMP}/settings_display.yaml" << 'YAML'
cli:
  default: claude
  agents:
    ashigaru5:
      type: codex
      model: gpt-5.3-codex
YAML
    load_adapter_with "${TEST_TMP}/settings_display.yaml"
    result=$(get_model_display_name "ashigaru5")
    [ "$result" = "Codex5.3" ]
}

@test "get_model_display_name: Kimi → Kimi" {
    cat > "${TEST_TMP}/settings_display.yaml" << 'YAML'
cli:
  default: kimi
  agents:
    ashigaru6:
      type: kimi
      model: k2.5
YAML
    load_adapter_with "${TEST_TMP}/settings_display.yaml"
    result=$(get_model_display_name "ashigaru6")
    [ "$result" = "Kimi" ]
}

@test "get_model_display_name: 全モデル × thinking組み合わせ" {
    cat > "${TEST_TMP}/settings_display_all.yaml" << 'YAML'
cli:
  default: claude
  agents:
    ashigaru1:
      type: claude
      model: claude-sonnet-4-6
      thinking: true
    ashigaru2:
      type: claude
      model: claude-opus-4-6
      thinking: false
    ashigaru3:
      type: claude
      model: claude-haiku-4-5-20251001
      thinking: true
    ashigaru4:
      type: codex
      model: gpt-5.3-codex-spark
    ashigaru5:
      type: codex
      model: gpt-5.3-codex
YAML
    load_adapter_with "${TEST_TMP}/settings_display_all.yaml"
    [ "$(get_model_display_name ashigaru1)" = "Sonnet+T" ]
    [ "$(get_model_display_name ashigaru2)" = "Opus" ]
    [ "$(get_model_display_name ashigaru3)" = "Haiku+T" ]
    [ "$(get_model_display_name ashigaru4)" = "Spark" ]
    [ "$(get_model_display_name ashigaru5)" = "Codex5.3" ]
}

# =============================================================================
# build_cli_command Thinking制御テスト
# =============================================================================

@test "build_cli_command: thinking:true → MAX_THINKING_TOKENS=0 なし" {
    cat > "${TEST_TMP}/settings_thinking.yaml" << 'YAML'
cli:
  default: claude
  agents:
    ashigaru1:
      type: claude
      model: claude-sonnet-4-6
      thinking: true
YAML
    load_adapter_with "${TEST_TMP}/settings_thinking.yaml"
    result=$(build_cli_command "ashigaru1")
    [ "$result" = "claude --model claude-sonnet-4-6 --name ashigaru1 --dangerously-skip-permissions" ]
}

@test "build_cli_command: thinking:false → MAX_THINKING_TOKENS=0 prefix" {
    cat > "${TEST_TMP}/settings_thinking.yaml" << 'YAML'
cli:
  default: claude
  agents:
    ashigaru1:
      type: claude
      model: claude-sonnet-4-6
      thinking: false
YAML
    load_adapter_with "${TEST_TMP}/settings_thinking.yaml"
    result=$(build_cli_command "ashigaru1")
    [ "$result" = "MAX_THINKING_TOKENS=0 claude --model claude-sonnet-4-6 --name ashigaru1 --dangerously-skip-permissions" ]
}

@test "build_cli_command: thinking未設定 → MAX_THINKING_TOKENS=0 なし (デフォルトThinking ON)" {
    cat > "${TEST_TMP}/settings_thinking.yaml" << 'YAML'
cli:
  default: claude
  agents:
    ashigaru1:
      type: claude
      model: claude-sonnet-4-6
YAML
    load_adapter_with "${TEST_TMP}/settings_thinking.yaml"
    result=$(build_cli_command "ashigaru1")
    [ "$result" = "claude --model claude-sonnet-4-6 --name ashigaru1 --dangerously-skip-permissions" ]
}

@test "build_cli_command: codex + thinking:false → MAX_THINKING_TOKENS=0 なし (Codexには無関係)" {
    cat > "${TEST_TMP}/settings_thinking.yaml" << 'YAML'
cli:
  default: claude
  agents:
    ashigaru5:
      type: codex
      model: gpt-5.3-codex
      thinking: false
YAML
    load_adapter_with "${TEST_TMP}/settings_thinking.yaml"
    result=$(build_cli_command "ashigaru5")
    [[ "$result" != MAX_THINKING_TOKENS* ]]
    [[ "$result" == codex* ]]
}

# =============================================================================
# find_agent_for_model テスト (T-1/T-2/T-3: tier-aware fallback f513fcc 復元)
# =============================================================================
# ★T-1〜T-3 は fixture が「該当 tier の足軽が居る/居ない」を作り、tier 選択(完全一致・
#   上位tier・下位tier SWITCH)を検査する。setup が実 tmux から隔離されているため pane は
#   引けず、候補は空き(pane 不在)扱いとなる。busy 判定経路は通らない(busy 判定そのものの
#   検査は T-BUSY 群=test_send_wakeup.bats の責務)。

@test "find_agent_for_model T-1: sonnet 該当足軽あり(実tmux非依存・pane不在=空き扱い) → 完全一致 ashigaru2 返却 (regression)" {
    load_adapter_with "${TEST_TMP}/settings_tier_t1.yaml"
    result=$(find_agent_for_model "claude-sonnet-4-6")
    [ "$result" = "ashigaru2" ]
}

@test "find_agent_for_model T-2: sonnet 該当足軽なし(実tmux非依存)・opus のみ存在 → 上位tier ashigaru1 返却 (SWITCH不要)" {
    load_adapter_with "${TEST_TMP}/settings_tier_t2.yaml"
    result=$(find_agent_for_model "claude-sonnet-4-6")
    [ "$result" = "ashigaru1" ]
}

@test "find_agent_for_model T-3: sonnet/opus 該当足軽なし(実tmux非依存)・haiku のみ存在 → SWITCH:ashigaru3:claude-sonnet-4-6" {
    load_adapter_with "${TEST_TMP}/settings_tier_t3.yaml"
    result=$(find_agent_for_model "claude-sonnet-4-6")
    [ "$result" = "SWITCH:ashigaru3:claude-sonnet-4-6" ]
}

# ---------------------------------------------------------------------------
# 実 tmux 隔離の固定 (cmd_791 A)
# ---------------------------------------------------------------------------

@test "find_agent_for_model 隔離: setup が実 tmux サーバ(稼働中の足軽pane)への到達を断っている" {
    # 稼働中サーバのソケットが渡っておらず、既定ソケットの置場が試験専用領域であること
    [ -z "${TMUX:-}" ]
    [ -z "${TMUX_PANE:-}" ]
    [ "$TMUX_TMPDIR" = "${TEST_TMP}/tmux_none" ]
    # 実 tmux に届けば @agent_id 付き pane が返る。何も見えてはならない。
    local visible
    visible=$(tmux list-panes -a -F '#{@agent_id}' 2>/dev/null || true)
    [ -z "$visible" ]
}

@test "find_agent_for_model 隔離: busy判定の実装が何を返しても T-3 の結果は変わらない(pane不在ゆえ busy判定経路を通らず、実paneのbusy/idleに依存しない)" {
    load_adapter_with "${TEST_TMP}/settings_tier_t3.yaml"
    local mode result
    for mode in busy idle; do
        # agent_is_busy_check を先に宣言しておけば find_agent_for_model は差し替えない。
        # 隔離下では pane が引けず、この関数は呼ばれないことを結果の同一性で示す。
        if [ "$mode" = "busy" ]; then
            agent_is_busy_check() { return 0; }
        else
            agent_is_busy_check() { return 1; }
        fi
        result=$(find_agent_for_model "claude-sonnet-4-6")
        [ "$result" = "SWITCH:ashigaru3:claude-sonnet-4-6" ]
    done
}
