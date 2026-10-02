---
name: shogun-model-switch
description: |
  エージェントのCLI/モデルをライブ切替するスキル。settings.yaml更新→/exit→新CLI起動→
  pane metadata更新を一発で実行。Thinking有無も制御。
  「モデル切替」「Sonnetにして」「Opusに変えて」「足軽全員切替」「Thinking切って」で起動。
argument-hint: "[agent-name target-model e.g. ashigaru1 sonnet]"
allowed-tools: Bash(bash scripts/switch_cli.sh *), Read, Edit
---

# /model-switch - Agent CLI Live Switcher

## Overview

稼働中のエージェントのCLI種別・モデル・Thinking設定をライブで切り替える。
`settings.yaml` → `build_cli_command()` → `/exit` → 新CLI起動 → pane metadata更新 を一貫実行。

## When to Use

- 「ashigaru3をOpusにして」「足軽全員Sonnetに切替」
- 「モデル切替」「モデル変えて」「CLI変えて」
- 「Thinking切って」「Thinking有効にして」
- 「CodexからClaudeに戻して」「Sparkにして」
- タスクの性質に応じてモデルを切り替えたいとき

## Architecture

```
settings.yaml (source of truth)
    │
    ├─ cli.agents.{id}.type      → claude | codex | copilot | kimi
    ├─ cli.agents.{id}.model     → sonnet | opus | fable | gpt-6-sol | gpt-6-luna | ...
    └─ cli.agents.{id}.thinking  → true | false
         │
         ├── build_cli_command()
         │   └─ thinking: false → "MAX_THINKING_TOKENS=0 claude --model ..."
         │   └─ thinking: true  → "claude --model ..."
         │
         └── get_model_display_name()
             └─ thinking: true  → "Sonnet+T" / "Opus+T"
             └─ thinking: false → "Sonnet" / "Opus"
```

## Display Name Mapping

| model (settings.yaml) | 表示名 | +Thinking |
|---|---|---|
| fable | fable | fable+T |
| sonnet | Sonnet | Sonnet+T |
| opus | Opus | Opus+T |
| claude-haiku-4-5-20251001 | Haiku | Haiku+T |
| gpt-6-sol | Codex | — |
| gpt-6-luna | Codex | — |
| gpt-reserve | Codex | — |

> `get_model_display_name()`実装(`lib/cli_adapter.sh:409`)を実行して確認した実際の出力(2026-09-29時点)。fableはどの短縮パターンにも一致せず`$model`文字列がそのまま使われるため小文字の`fable`/`fable+T`になる。gpt-6-sol・gpt-6-luna・gpt-reserveもいずれのモデル名パターンにも一致せず、cli_type(`codex`)からの既定分岐で`Codex`に落ちる——3モデルとも表示名は区別されない。
> **Older/EOS(参考・新規設定には使わないこと)**: `claude-sonnet-4-6`→Sonnet、`claude-opus-4-6`→Opus(旧版・cmd_783で置換)。`gpt-5.3-codex`→Codex5.3、`gpt-5.3-codex-spark`→Spark(EOS)。

## Instructions

> **★`--human-initiated` は必須である (cmd_754 将軍裁定 E-1)**
>
> switch_cli.sh は agent CLI が動いている pane へ `/exit` を打ち込む。
> 2026-09-08、自動打鍵の Enter が確認モーダルの既定選択肢を押し、
> D002-E1 違反の削除が実行された。以後、稼働 pane への★自動打鍵は廃止した。
>
> `--human-initiated` は「人が今この切替を命じ、当該 pane を見ている」
> ことの表明である。★これ無しでは1打鍵も送らず exit 3 で中止する。
> 自動経路(inbox_watcher 等)は決してこの旗を付けてはならぬ。
>
> ★残余リスク: 旗を付けたその瞬間に pane がモーダルを出していれば、
> `/exit` の Enter がそれを答え得る。旗は危険を消さず、責任を人へ移す。
> 実行前に当該 pane を目で確かめよ。

### 単体切替

```bash
# settings.yaml の現在値で再起動（CLIリセットしたいだけのとき）
bash scripts/switch_cli.sh ashigaru3 --human-initiated

# モデル変更（settings.yaml も自動更新）
bash scripts/switch_cli.sh ashigaru3 --human-initiated --model opus

# CLI種別ごと変更（Codex → Claude）
bash scripts/switch_cli.sh ashigaru3 --human-initiated --type claude --model sonnet

# Claude → Codex（高速ワーカー枠。2026-09-29のcmd_783でSpark→gpt-6-lunaに交代)
bash scripts/switch_cli.sh ashigaru5 --human-initiated --type codex --model gpt-6-luna
```

### 一括切替

```bash
# 全足軽をSonnetに
for i in $(seq 1 7); do
    bash scripts/switch_cli.sh ashigaru$i --human-initiated --type claude --model sonnet
done

# 全足軽をgpt-6-lunaに(旧Spark相当。Sparkは2026-09-29のcmd_783でEOS)
for i in $(seq 1 7); do
    bash scripts/switch_cli.sh ashigaru$i --human-initiated --type codex --model gpt-6-luna
done

# 全エージェント（家老・軍師含む）を再起動
for agent in karo ashigaru1 ashigaru2 ashigaru3 ashigaru4 ashigaru5 ashigaru6 ashigaru7 gunshi; do
    bash scripts/switch_cli.sh "$agent" --human-initiated
done
```

### Thinking 制御

settings.yaml の `thinking` フィールドを編集してから switch_cli.sh を実行:

```yaml
# config/settings.yaml
cli:
  agents:
    ashigaru3:
      type: claude
      model: opus
      thinking: false  # ← MAX_THINKING_TOKENS=0 で起動
```

```bash
# settings.yaml 編集後に再起動
bash scripts/switch_cli.sh ashigaru3 --human-initiated
```

Thinking ON/OFF の切替手順:
1. `config/settings.yaml` の対象エージェントの `thinking:` を `true` / `false` に変更
2. `bash scripts/switch_cli.sh <agent_id> --human-initiated` で再起動
3. pane border に `+T` の有無が反映される

### inbox 経由（家老からの切替）— ★自動実行は廃止した (cmd_754)

```bash
# 家老が cli_restart を投げること自体は今も可能である
bash scripts/inbox_write.sh ashigaru3 "--type claude --model opus" cli_restart karo
```

★ただし inbox_watcher は switch_cli.sh を★自動実行しない。
cli_restart は未読のまま保持され、人が実行すべきコマンドを添えて
人経路(家老 inbox → dashboard 🚨要対応)へ上げられる。
実際の切替は殿または将軍が手ずから次を実行する:

```bash
bash scripts/switch_cli.sh ashigaru3 --human-initiated --type claude --model opus
```

## What switch_cli.sh Does (internal)

1. **settings.yaml 更新**（`--type`/`--model` 指定時のみ）
2. **現在のCLI種別を検出**（tmux pane metadata `@agent_cli`）
3. **CLI別の exit コマンドを送信**
   - Claude: `/exit` + Enter
   - Codex: Escape → Ctrl-C → `/exit` + Enter
   - Copilot/Kimi: Ctrl-C → `/exit` + Enter
4. **シェルプロンプト復帰を待機**（最大15秒、1秒ごとにキャプチャ）
5. **`build_cli_command()` で新コマンド構築**
   - thinking: false → `MAX_THINKING_TOKENS=0` prefix 付与
6. **tmux send-keys で新CLI起動**（テキストとEnterを分離送信）
7. **pane metadata 更新**: `@agent_cli`, `@model_name`

## Files

| ファイル | 役割 |
|---|---|
| `scripts/switch_cli.sh` | メインスクリプト |
| `lib/cli_adapter.sh` | `build_cli_command()`, `get_model_display_name()` |
| `config/settings.yaml` | エージェント設定（type, model, thinking） |
| `scripts/inbox_watcher.sh` | `cli_restart` type ハンドリング |
| `logs/switch_cli.log` | 実行ログ |

## Constraints

- **将軍(shogun)ペインには送信しない**: switch_cli.sh は multiagent セッションのペインのみ対象
- **実行中のエージェントに注意**: タスク実行中に切り替えるとデータ消失の可能性あり。idle確認してから実行
- **Codex → Claude 切替時**: Codex の /exit が不安定な場合がある。Escape + Ctrl-C で確実に終了させる
- **inbox_watcher との連携**: ★cli_restart の自動実行は cmd_754 で廃止した。
  inbox_watcher は switch_cli.sh を起動せず、人経路へ上げるのみである
- **新CLI起動の条件**: `/exit` の後、pane の★前景プロセスが素のシェルで
  あることを確かめてから起動打鍵を送る。CLI が生き残っていれば送らない
- **配送経路の全体像**: `docs/delivery_channels.md` を見よ
