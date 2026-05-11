---
name: shogun-codd
description: >
  codd (Coherence-Driven Development v2.14.0) を shogun の cmd駆動・並列ashigaru構造に統合するスキル。
  Greenfield (spec→設計→コード) と Brownfield (既存コード→設計→リファクタ) の双方に対応。
  Wave単位でのドキュメント生成・QCゲート・進捗集約を提供。
  v2.14対応版: Sprintless implement(設計書単位で独立実装) + dag verify --auto-repair
  + Opt-out Policy(v2.13) + 38 lexicons + sidecar codd.yaml(C6/C9)
  + v2.8→v2.14 移行ガイド + Wave 1-N 対応 + archive fallback
  + Brownfield extract/require/restore + Coherence Engine + project_lexicon
  + elicit/brownfield/coverage/lexicon/assemble 各コマンド対応。
  トリガー: /codd-start, /codd-extract, /codd-wave-run, /codd-wave-qc, /codd-status,
  codd-start, codd-extract, codd wave, Brownfield, Wave駆動, CoDD, shogun-codd で起動。
  Do NOT use for: codd CLIの直接操作（codd init/generate等の単発実行）、
  shogun-pokemon-shipmentスキルへの干渉。
---

# shogun-codd

codd (Coherence-Driven Development) を shogun マルチエージェント構造に統合するスキル。
Wave駆動でドキュメント生成・QC・進捗管理を一貫して提供する。

## Commands

| コマンド | 起動者 | 用途 | モード |
|---------|-------|------|--------|
| `/codd-start <project> [--requirements PATH] [--language LANG]` | 殿・将軍 | プロジェクト初期化 + Wave cmd チェーン一括起案 | Greenfield |
| `/codd-extract <project> --target <path> [--source-dirs ...]` | 殿・将軍 | 既存コードから設計ドキュメントを6層MECEで抽出 | Brownfield |
| `/codd-wave-run <N>` | 家老（内部） | Wave N の並列足軽配分 | 共通 |
| `/codd-wave-qc <N>` | 軍師（内部） | Wave N のQC実行 | 共通 |
| `/codd-status [project]` | 殿・家老 | Wave進捗サマリ表示 | 共通 |

### v2.14 新機能一覧

| バージョン | コマンド/機能 | 用途 |
|-----------|-------------|------|
| v2.11 | `codd implement --design <path> --output <dir>` | **Sprintless**: 設計書単位で直接実装コード生成 |
| v2.11 | `codd implement run/plan/steps/augment/resume` | 実装サブコマンド群 |
| v2.12 | `codd dag verify` (C7/C8ゲート) | actors_without_journeys・ci_health チェック |
| v2.13 | `codd validate` (Opt-out Policy) | config opt-out に justification+expires_at を要求 |
| v2.14 | `codd dag verify --auto-repair --apply` | DAG違反をAIが自動修復 |
| v2.14 | sidecar `<test>.codd.yaml` | `verified_by:` (C6) / `axis_matrix:` (C9) |
| v2.14 | `ai_timeout_seconds: 3600` (SSoT) | タイムアウトデフォルト値統一 |
| v2.8+ | `codd lexicon install <name>` × 38種 | 業界標準lexicon(WCAG/OWASP/BABOK等)プラグイン |

> ⚠️ v2.8以前に存在した `codd2` コマンドは廃止。v2.14では `codd` のみ使用。

## Greenfield vs Brownfield 使い分けガイドライン

| 観点 | Greenfield (`/codd-start`) | Brownfield (`/codd-extract`) |
|------|---------------------------|-----------------------------|
| 入口 | 要件文書 (spec.md) | 既存コードベース (target path) |
| 流れ | 要件 → 設計書生成 → 実装 | 既存コード → 設計書抽出 → 要件逆算 → リファクタ計画 |
| 主用途 | 新規機能・新スキル開発 | 既存スキル/コード群のリファクタ・ドキュメント化 |
| codd CLI 中核 | `codd init` + `codd plan --init` + `codd generate` | `codd extract --ai` + `codd require` / `codd restore` |
| 出力先 | `codd/wave1/`, `codd/wave2/` ... | `.codd/extract/` (drafts) → 確認後 promote |
| 並列足軽 | parallel_docs を Wave毎に分配 | 6層 (L1-L6) を担当別に分担可 |
| 軍師QC | `codd validate --wave N` + 4観点 | extracted 6層 + 確認後の Wave 検証 |
| 典型cmd例 | shogun-codd 自体の MVP 開発 | shogun-pokemon-shipment 提出系5モジュール リファクタ (cmd_388要件) |

**判断フロー**:
- 「これから書くコード」を整える → Greenfield
- 「既に動いているコード」を整える → Brownfield
- 既存コードを大幅変更する場合は Brownfield で抽出 → Greenfield的に再設計、の二段階併用も可

## Preflight (必須: /codd-start 冒頭で実行)

```bash
bash skills/shogun-codd/scripts/codd_preflight.sh
```

- `codd --version` を実行し **v2.14.0** であることを確認
- v2.14.0 以外の場合は **警告を出して処理を停止**
- codd が未インストールの場合も停止

## /codd-start <project> 手順

### Step 1: Preflight

```bash
bash skills/shogun-codd/scripts/codd_preflight.sh || exit 1
```

### Step 2: ディレクトリ作成 + codd init

```bash
mkdir -p /mnt/e/WORK/codd_<project>
cd /mnt/e/WORK/codd_<project>
codd init --project-name <project> --language <lang> --dest /mnt/e/WORK/codd_<project> \
          --suggest-lexicons --llm-enhanced
# --suggest-lexicons --llm-enhanced でプロジェクトに合うlexiconをAIが推薦
```

### Step 3: codd.yaml AI モデル設定

codd.yaml を `/mnt/e/WORK/codd_<project>/` に作成またはマージ:

```yaml
# codd.yaml — shogun-codd 標準設定
ai:
  default: "claude --print --model claude-sonnet-4-6"
  l6_override: "claude --print --model claude-opus-4-6"
  # L6タスクのみ Opus、他は Sonnet固定（殿採択: iii）
ai_timeout_seconds: 3600
  # v2.14 SSoT: デフォルト3600s
```

### Step 4: Wave プラン生成

```bash
cd /mnt/e/WORK/codd_<project>
codd plan --init --requirements <requirements_path>
codd plan --waves  # Wave数と各Wave名を取得
```

### Step 5: Wave cmd チェーン生成

`bash skills/shogun-codd/scripts/codd_wave_dispatcher.sh <project> <N_waves>` を実行して
`queue/shogun_to_karo.yaml` に Wave cmd YAML を追記する。

### Step 6: dashboard ⛵ セクション初期化

dashboard.md の `## ⏳ 依存待機中` の直後に `## ⛵ CoDD Wave進行中` セクションを追加。

## /codd-extract <project> 手順 (Brownfield)

既存コード群から 6層 MECE で設計ドキュメントを抽出する。
新規開発ではなく **既存スキル・モジュールのリファクタや文書化** に使う。

### Step 1: Preflight

```bash
bash skills/shogun-codd/scripts/codd_preflight.sh || exit 1
```

### Step 2: ディレクトリ作成 + codd init

```bash
mkdir -p /mnt/e/WORK/codd_<project>
cd /mnt/e/WORK/codd_<project>
codd init --project-name <project> --language <lang> --dest /mnt/e/WORK/codd_<project>
```

`--language` は対象コードの主言語 (python/typescript/javascript/go) を指定。

### Step 3: codd.yaml AI モデル設定 (Brownfield 推奨)

```yaml
# codd.yaml — Brownfield 標準設定
ai:
  default: "claude --print --model claude-sonnet-4-6"
  l6_override: "claude --print --model claude-opus-4-6"
  # extract は既存コード全文を読み込むため長文タスク。Sonnet 維持を強く推奨
  # Haiku では 6層分類が破綻する事例あり (FM14)
ai_timeout_seconds: 3600
extract:
  prompt_preset: baseline   # codd 組込プロンプト
```

**v1.16-alpha 以降: project_lexicon.yaml 自動生成**

v1.16-alpha で導入された **Coherence Engine** により、`codd init` 実行時に `codd/project_lexicon.yaml` が自動生成される。これは抽出時の用語統一・概念マッピングに使われる。

- 通常は手動編集不要 (codd が自動更新)
- カスタム用語 (例: shogun 内部用語「家老」「足軽」「軍師」) を追加する場合のみ手動編集

### Step 4: codd extract 実行 (AI 抽出)

**v2.8.0 では Bug #19 (target汚染) が解消**。出力先が `.codd/extract/` (CWD配下) に固定されたため、source_mirror 回避策は**不要**。

```bash
cd /mnt/e/WORK/codd_<project>
codd extract \
  --path <target_source_dir> \
  --source-dirs scripts \
  --ai
# 出力: /mnt/e/WORK/codd_<project>/.codd/extract/ (targetは汚染されない)
```

`--ai` で AI 抽出 (静的解析のみの場合は `--ai` を外す)。出力は CWD 配下の `.codd/extract/` に **draft** として配置される (この時点では promote しない)。

### Step 5: 殿/将軍レビュー

`.codd/extract/` 内の各層ドキュメントを殿/将軍が確認:

- 抽出内容が現実のコードを反映しているか
- 6層分類が破綻していないか (FM14)
- 補正が必要な層を identify

レビュー OK のドキュメントのみ `.codd/confirmed/` 等に **promote** する (手動 mv で OK)。

### Step 6: codd require / codd restore (任意)

| コマンド | 用途 | 出力 |
|---------|------|------|
| `codd require --path <dir> --output .codd/required/` | extract 結果から要件を逆算 | requirements.md |
| `codd restore --wave <N> --feedback "<指摘>"` | extract 結果を Wave形式の設計ドキュメントに再構築 | codd/wave<N>/*.md |

**使い分け**:
- **codd require**: 「この既存コードはどんな要件を満たそうとしていたのか」を文書化したい場合
- **codd restore**: extract結果を Greenfield と同じ Wave形式に変換し、以降は通常の Wave 駆動に乗せたい場合

リファクタ用途では typically `codd restore` を使い、Wave形式に揃える。

### Step 7: Wave プラン生成 (確定済み extracted を入力に)

```bash
cd /mnt/e/WORK/codd_<project>
codd plan --init --requirements .codd/confirmed/requirements.md
codd plan --waves
```

**Bug #17 (frontmatter 不整合) v2.8解消**: v1.34 で必要だった frontmatter 手動整形 (codd: キー追加 + ```markdown 除去) は v2.8 以降では不要になった。

### Step 8: Wave cmd チェーン生成 + dashboard 初期化

```bash
bash skills/shogun-codd/scripts/codd_wave_dispatcher.sh <project> <N_waves>
```

以降は **Greenfield と同じ dispatcher を流用**。Wave cmd YAML が `queue/shogun_to_karo.yaml` に追記され、家老が通常の `type: codd_wave` ルーティングで処理する。

dashboard.md の `## ⏳ 依存待機中` の直後に `## ⛵ CoDD Wave進行中` セクションを追加 (Greenfield と同手順)。

## Brownfield ワンショット: codd brownfield

v2.8 以降の `codd brownfield` は extract + diff + elicit + 統合レポートを一括実行する。

```bash
cd /mnt/e/WORK/codd_<project>
codd brownfield <target_path> \
  --requirements <requirements_path> \
  --output .codd/brownfield_report.md
```

- `--requirements` 省略時は `<target>/.codd/requirements.md` を参照 (なければスキップ)
- 用途: 簡易な Brownfield 一括調査。Wave 駆動まで進める場合は Step 1-8 の手動フローを推奨

## elicit コマンド

カバレッジ不足・仕様上の穴を発見して適用する。Wave 生成後の品質向上に使う。

```bash
cd /mnt/e/WORK/codd_<project>
codd elicit --interactive
# → findings をインライン確認しながら approved のみ適用

codd elicit apply
# → 承認済み findings を一括適用
```

## coverage コマンド

E2E・design token・lexicon カバレッジのマージゲートを実行する。

```bash
cd /mnt/e/WORK/codd_<project>
codd coverage check \
  --e2e-threshold 100 \
  --lexicon-threshold 100

codd coverage report  # カバレッジマトリクスレポート生成
```

## lexicon コマンド (38種 bundled)

bundled lexicon プラグインを管理する。

```bash
codd lexicon list                        # 利用可能 lexicon 一覧
codd lexicon install <name>              # プロジェクトに lexicon を追加
codd lexicon diff --path <project>       # lexicon と要件/設計テキストの差分検査
```

### 38 lexicons カテゴリ表

| カテゴリ | lexicon 例 |
|---------|-----------|
| Web | WCAG, OWASP, Web Vitals, WebAuthn, forms, SEO, PWA, browser-compat, responsive |
| Mobile | HIG, Material 3, a11y, MASVS |
| Backend | REST, GraphQL, gRPC, events |
| Data | SQL, JSON Schema, event sourcing, governance |
| Ops | CI/CD, Kubernetes, Terraform, observability, DORA |
| Compliance | ISO 27001, HIPAA, PCI DSS, GDPR, EU AI Act |
| Process | ISO 25010, 29119, DDD, 12-factor, i18n, model cards, API rate-limit |
| Methodology | BABOK |

`codd init --suggest-lexicons --llm-enhanced` で AI がプロジェクトに適したlexiconを推薦。

## assemble コマンド

`codd implement` で生成した実装コードの統合ステップ。

```bash
cd /mnt/e/WORK/codd_<project>
codd assemble --output-dir src/
```

## codd implement Sprintless フロー (v2.11+)

**v2.11 Breaking**: Wave/Sprint 単位の実装フェーズが廃止。設計書1つ = 1実装タスクとして独立実行。

```
Wave生成 (codd generate)
  ↓ 設計書ファイル (codd/wave<N>/<doc>.md)
codd implement --design <doc>.md --output src/
  ↓ (derived steps使用時)
  codd implement plan --task <id>    # AIによるステップ派生
  codd implement steps               # 派生ステップ確認・承認
  codd implement run                 # 実装実行
  ↓
codd implement augment               # ベストプラクティス補完
codd implement resume                # チャンク再開 (大規模時)
```

### 足軽への implement タスク割り当て方針

| 観点 | v2.8以前 | v2.14 (Sprintless) |
|------|---------|-------------------|
| 実装タスクの単位 | Wave内の sprint/plan.md | 設計書1ファイル = 1タスク |
| コマンド | `codd generate --wave N` + sprint実行 | `codd implement --design <path> --output <dir>` |
| 並列化 | Wave内を複数足軽でsprint分割 | 設計書ファイル単位で足軽に割り当て |
| 依存関係 | Wave間の depends_on | `codd implement --depends-on <design2>` で設計書間依存を表現 |

**shogun-codd 実装タスクYAMLテンプレ** (Sprintless対応):

```yaml
task:
  task_id: subtask_codd_<project>_impl_<doc_key>
  parent_cmd: cmd_codd_<project>_impl
  bloom_level: L4
  description: |
    cmd_codd_<project>_impl: <doc_key> の Sprintless実装。

    ## 実行手順
    1. cd /mnt/e/WORK/codd_<project>/
    2. codd implement \
         --design codd/wave<N>/<doc>.md \
         --output src/<module>/ \
         --depends-on codd/wave<N>/<dep_doc>.md  # 依存設計書がある場合
    3. (derived stepsを使う場合)
       codd implement plan --task <id>
       codd implement steps   # ステップ確認
       codd implement run
    4. 生成コードを確認し、frontmatter・依存参照を目視チェック
    5. 報告YAMLに成果物パスと生成時間を記録

    ## 厳守
    - codd validate は軍師が実施。足軽は実装生成のみ。
    - --clean は既存ファイルを上書きするため、慎重に使用
    - sidecar <test>.codd.yaml の verified_by: を確認してからテスト実行

  target_path: /mnt/e/WORK/codd_<project>/src/<module>/
  status: assigned
```

## dag verify コマンド (v2.14)

DAG 完全性チェックと AI 自動修復。

```bash
cd /mnt/e/WORK/codd_<project>
# DAG チェック (dry run)
codd dag verify

# AI自動修復 (preview)
codd dag verify --auto-repair

# AI自動修復 (ディスク書込)
codd dag verify --auto-repair --apply

# 特定チェックのみ
codd dag verify --check C7 --check C8

# DAG Mermaid可視化
codd dag visualize
```

### DAG チェック一覧 (v2.14)

| ID | チェック内容 | 重要度 |
|----|------------|-------|
| C6 | `verified_by:` 参照 (sidecar codd.yaml) | amber |
| C7 | `actors_without_journeys` — actor定義があるが journey が未定義 | amber |
| C8 | `ci_health` — CI workflow存在・トリガー・verification in workflow | amber |
| C9 | `axis_matrix:` カバレッジ軸 (sidecar codd.yaml) | amber |

## Opt-out Policy (v2.13+)

v2.13 以降、config-level opt-out には `justification` + `expires_at` が必須。Silent SKIPは廃止。

```yaml
# codd.yaml の opt-out 設定例
ci:
  provider: none
  opt_out:
    justification: "ローカル開発環境のみ使用。CI環境は別プロジェクトで管理。"
    expires_at: "2026-12-31"
```

`codd validate` でpolicy違反を検出:

```bash
codd validate  # → opt-out 未記載の場合 ERROR を報告
```

## audit / risk (codd-pro 機能)

`codd audit` と `codd risk` は **codd-pro 拡張パック** に依存する。

```bash
# audit: validate + impact + policy + review を1レポートに統合
codd audit --diff HEAD --path <project>

# risk: 変更リスク分析 (codd-pro 必須)
codd risk --path <project>
```

**注意**: codd-pro が未インストールの環境では `risk` が動作しない。`audit` は `--skip-review` でAI呼出なしのモードも使用可能。

## Brownfield Wave 連結手順 (まとめ)

```
[Step 1-4] codd extract --ai
   ↓ 出力: .codd/extract/ (drafts)
[Step 5] 殿/将軍レビュー
   ↓ 確定したものを .codd/confirmed/ に promote
[Step 6] codd require / codd restore (任意)
   ↓ 出力: .codd/required/, codd/wave<N>/
[Step 7] codd plan --init + codd plan --waves
   ↓ Wave 数確定
[Step 8] codd_wave_dispatcher.sh で Wave cmd チェーン起案
   ↓ Greenfield と同じ dispatcher 流用
[Wave 1-N 実行] 通常の /codd-wave-run + /codd-wave-qc
[実装フェーズ] codd implement --design <doc> --output <dir>  (Sprintless)
```

**重要**: Step 5 (殿/将軍レビュー) を飛ばさない。extract結果が現実と乖離した状態で Wave 起動すると、設計ドキュメントが既存コードと整合しない (FM13)。

## Brownfield UX ガイドライン (cmd_395 PoC 知見)

restore で生成された `docs/` 配下のドキュメント群は **MECE 8カテゴリ** (`requirements/governance/design/detailed_design/test/operations/infra`) で配置されるが、Wave 番号情報が単体ドキュメントに残らないため、**「各 doc が Wave 何番由来か即時判別できない」** という UX 課題がある (cmd_393/395 PoC で実証)。

### 推奨ガイドライン

| # | 項目 | 実施タイミング | 担当 |
|---|------|--------------|------|
| 1 | **ファイル名に Wave プレフィックス** (`W2_design_system_architecture.md` 形式) | restore 直後に一括 rename | 家老 cmd で `mv` 実施 |
| 2 | **frontmatter に `wave: <N>` 注入** | restore 直後 | shogun-codd post-restore hook で自動化推奨 |
| 3 | **`docs/INDEX.md` 自動生成** (Wave別+MECE別 二軸索引) | restore 直後 | shogun-codd `/codd-status` 拡張 |
| 4 | **dashboard `## ⛵ CoDD Wave進行中` セクションで各 doc 直接リンク** | Wave 進行中常時 | 軍師 (⛵セクション専管) |

## v1.34→v2.8→v2.14 移行ガイド

### 1. v2.8 → v2.14 主要変更点

| 観点 | v2.8.0 | v2.14.0 |
|------|--------|---------|
| **CLI コマンド名** | `codd2` | `codd` (**Breaking**: codd2 は廃止) |
| **実装フロー** | Wave/Sprint 単位 | **Sprintless**: 設計書単位 (`codd implement --design`) |
| `implementation_plan.md` | あり (파서あり) | **廃止** (v2.11 Breaking) |
| `ai_timeout_seconds` デフォルト | codd.yaml で設定 (G1 workaround) | **3600s** に統一 (SSoT) |
| lexicons | あり (一部) | **38種 bundled** |
| Opt-out設定 | justification 任意 | `justification` + `expires_at` **必須** (v2.13) |
| DAG自動修復 | なし | `codd dag verify --auto-repair --apply` |
| Sidecar設定 | なし | `<test>.codd.yaml` (C6/C9) |
| `scan.exclude` | バグあり (過検出) | **修正** (-52% amber noise) |

### 2. v1.34.0 → v2.8.0 主要変更点 (参考)

| 観点 | v1.34.0 | v2.8.0 |
|------|---------|--------|
| CLI コマンド名 | `codd` | `codd2` |
| extract 出力先 | **`<--path>/codd/extracted/`** (target 汚染・Bug #19) | **`.codd/extract/`** (CWD配下・Bug #19 解消) |
| plan --init frontmatter | Bug #17: codd: サブセクション欠落 | **解消** |
| Python AST scan | Bug #18: 0 source files analyzed | **解消** |
| 新コマンド | なし | elicit / brownfield / coverage / lexicon / assemble / audit / risk |
| ai_timeout_seconds | 非対応 (120s hardcoded) | codd.yaml で設定可能 (G1 workaround) |

### 3. v2.8 → v2.14 移行手順

```bash
# 1. codd アップグレード確認
codd --version  # → 2.14.0

# 2. preflight スクリプト更新済み
# skills/shogun-codd/scripts/codd_preflight.sh の REQUIRED_VERSION が "2.14.0" に更新済

# 3. 既存 codd_<project>/ の codd.yaml 更新
# ai_timeout_seconds: 3600 に変更 (デフォルトになったが明示推奨)

# 4. codd2 → codd 置換 (scripts内)
# codd_wave_dispatcher.sh は "codd" コマンドを使用するよう更新済

# 5. opt-out設定がある場合: justification + expires_at 追記
```

### 4. 既存 PoC 資産との互換性

| 資産 | 互換性 | 対応 |
|------|-------|------|
| v1.34/v2.8 生成の設計書 (.md) | 静的ドキュメントとして利用可 | 変更不要 |
| codd validate 結果 | codd validate (v2.14) で再確認推奨 | 別 cmd で再検証 |
| codd.yaml 設定 | **ai_timeout_seconds を 3600 に更新推奨** | 3600未満は実行時警告 |
| source_mirror workaround | **不要** (Bug #19 解消) | 新規 extract は直接 --path 指定可 |
| v2.8時代の `codd2` コマンド呼出 | **動作しない** | `codd` に置換必須 |
| implementation_plan.md 参照 | **廃止** | Sprintless (`codd implement --design`) に移行 |

## 6層 MECE 抽出物のレビュー観点

`codd extract --ai` は以下 6 層に分類してドキュメントを抽出する:

| Layer | 名称 | 抽出対象 | レビュー観点 |
|-------|------|---------|------------|
| L1 | Vision / Why | プロジェクト目的・解決する問題 | 既存コードのコメント・README・テスト名から逆算した目的が現実と一致するか |
| L2 | Goals / Outcomes | 達成したい結果・受入基準 | 各モジュールの責務・サクセス指標 |
| L3 | Behavior / What | 機能仕様・ユーザシナリオ | エンドポイント・CLI引数・入出力契約 |
| L4 | Architecture / How | 全体構造・モジュール分割・依存関係 | 既存コードの import グラフと一致するか |
| L5 | Implementation Notes | アルゴリズム・データモデル・既知の落とし穴 | 「不明(JAN)」のような実装上の癖が拾えているか (cmd_383事故等の固有事情) |
| L6 | Operations / Constraints | デプロイ・運用・パフォーマンス制約 | 環境変数・credentials・cron・hook の存在 |

### confirmed promote タイミング

| 状態 | 場所 | 次のアクション |
|------|------|-------------|
| Draft (AI抽出直後) | `.codd/extract/` | レビュー対象 |
| Reviewed (レビュー済・要修正) | `.codd/extract/` で残置 + 殿コメント | feedback 付きで `codd extract --ai` 再実行 or 手動修正 |
| Confirmed (殿/将軍OK) | `.codd/confirmed/` に手動 mv | `codd plan --init` の入力に使用 |
| Locked (Wave起動済) | `.codd/confirmed/` で frozen | 以降は Wave内で `codd restore --feedback` で修正 |

## /codd-wave-run <N> 手順 (家老内部処理)

1. cmd YAML の `parallel_docs` リストを読む
2. 各 doc について bloom_routing で担当ashigaru選定:
   - L1-L2 → Haiku tier (ashigaru1,2)
   - L3-L5 → Sonnet tier (ashigaru3-6)
   - L6 → Opus tier (ashigaru7)
3. `subtask_codd_<project>_W<N>_<doc_key>` タスクYAML書込
4. `bash scripts/inbox_write.sh ashigaru{N} "タスクYAMLを読んで作業開始せよ。" task_assigned karo`

### 足軽 Wave 生成タスクYAMLテンプレ (ドキュメント生成)

```yaml
task:
  task_id: subtask_codd_<project>_W<N>_<doc_key>
  parent_cmd: cmd_codd_<project>_W<N>
  bloom_level: L4
  description: |
    cmd_codd_<project>_W<N>: Wave <N> <wave_name> の担当ドキュメント生成。

    ## 実行手順
    1. cd /mnt/e/WORK/codd_<project>/
    2. codd generate --wave <N> --ai-cmd "claude --print --model claude-sonnet-4-6"
       ※ 担当ドキュメント: <doc>
    3. 生成結果を確認し、frontmatter・依存参照を目視チェック
    4. 報告YAMLに成果物パスと生成時間を記録

    ## 厳守
    - codd validate は軍師が実施。足軽は生成のみ。
    - --force は使わない（既存ファイル上書き防止）

  target_path: /mnt/e/WORK/codd_<project>/codd/wave<N>/<doc>
  status: assigned
```

## /codd-wave-qc <N> 手順 (軍師内部処理)

### 段階1: 機械QC

```bash
cd /mnt/e/WORK/codd_<project>/
codd validate --wave <N> > /tmp/codd_validate_W<N>.log 2>&1
echo "exit_code: $?"
```

exit code ≠ 0 → **fail確定**。ログを report に引用して差し戻し。

**v2.13+**: opt-out policy 違反も検出。`justification` / `expires_at` 未記載の場合も fail。

### 段階2: 軍師独自QC (段階1 pass 時のみ)

parallel_docs の target_path を各々読込み、4観点でレビュー:

| # | 観点 | チェック内容 |
|---|-----|-------------|
| 1 | **一貫性** | Wave内docs間で矛盾がないか |
| 2 | **曖昧性** | "適切に", "必要に応じて" 等の曖昧表現 |
| 3 | **実装可能性** | 当該 Wave の具体度で実装着手できるか |
| 4 | **冗長性** | 同じ内容が複数docsに重複していないか |

### QC fail 時の処理

1. `context/codd_qc_<project>_W<N>.md` を生成し詳細を記録
2. dashboard の該当Wave行の QC 欄に `❌ [詳細](context/codd_qc_<project>_W<N>.md)` を記載
3. report に `regenerate_docs` リストを記載（該当docのみ、全doc再生成は禁止）

### QC report 形式

```yaml
worker_id: gunshi
task_id: gunshi_codd_qc_<project>_W<N>
parent_cmd: cmd_codd_<project>_W<N>
timestamp: "<ISO8601>"
status: done
result:
  type: codd_wave_qc
  project: <project>
  wave_number: <N>
  qc_result: pass  # pass | fail
  stage1_validate: pass  # pass | fail
  stage2_gunshi: pass  # pass | fail
  qc_notes: |
    [段階1] codd validate: pass
    [段階2] 軍師QC: pass
  regenerate_docs: []  # fail 時に差し戻すdoc名リスト
  qc_detail_path: null  # fail 時: context/codd_qc_<project>_W<N>.md
files_modified: ["dashboard.md"]
```

## /codd-status [project] 手順

dashboard.md の `## ⛵ CoDD Wave進行中` セクションを最新状態に upsert。

### dashboard ⛵ セクション書式

```markdown
## ⛵ CoDD Wave進行中: <project>

| Wave | 内容 | 状態 | 担当 | QC | 完了時刻 |
|------|------|------|------|-----|---------|
| W1 | 受入基準+ADR | ✅ done | ashigaru3,4 | ✅ pass | 10:42 |
| W2 | システム設計 | 🔄 2/3完了 | ashigaru3(core✅),4(db✅),5(api🔄) | - | - |
| W3 | インタフェース設計 | ⏸ depends_on: W2 | - | - | - |

**プロジェクト状況**: Wave2進行中 (2/3 docs完了)
**次マイルストーン**: W2 QC (軍師)
**直近の成果物**: /mnt/e/WORK/<project>/codd/wave2/system_core.md
```

### 状態絵文字凡例

| 絵文字 | 意味 |
|-------|------|
| ⏸ | 依存未解決で待機 |
| 🔄 | 実行中 |
| 🔍 | QC中 |
| ❌ | QC fail 差し戻し中 |
| ✅ | done |
| 🚨 | 失敗・アボート |

### セクション配置 (dashboard.md)

```
## 🚨 要対応
## ⏳ 依存待機中
## ⛵ CoDD Wave進行中    ← ここ
## 🔄 進行中
## ✅ 本日の戦果
```

**⛵ セクションは軍師専管** (dashboard並列編集競合対策 — 案A採択)。
軍師以外はこのセクションを更新しない。家老は Wave開始/完了時に軍師へ inbox_write で依頼。

## Wave cmd YAML スキーマ (shogun_to_karo.yaml)

```yaml
- id: cmd_codd_<project>_W<N>
  type: codd_wave                       # 家老ルーティングキー
  wave_number: <N>
  wave_name: "Wave名"
  project: <project>
  project_dir: /mnt/e/WORK/codd_<project>

  depends_on: cmd_codd_<project>_W<N-1>  # W1 は省略

  timestamp: '<ISO8601>'
  north_star: "このWaveの目標"
  purpose: "Wave<N>: 何を達成するか"
  acceptance_criteria:
    - 全 parallel_docs が codd validate pass
    - 軍師レビューで一貫性問題なし
    - dashboard Wave進捗表が更新済

  parallel_docs:
    - doc: <filename.md>
      assignee: ashigaru<N>             # 家老が bloom_routing で埋める
      bloom_level: L4
      description: "このdocの責務説明"
      target_path: /mnt/e/WORK/codd_<project>/codd/wave<N>/<filename.md>

  qc_command: "codd validate --wave <N>"
  qc_assignee: gunshi
  qc_extra_criteria:
    - 循環依存の有無
    - 冗長記述の検出

  status: pending
  started_at: null
  completed_at: null
  qc_result: null
  qc_notes: null
```

## 家老 codd_wave ルーティング手順

家老が `type: codd_wave` を検知した時点で、通常の cmd 分解フローを**迂回**して以下を実行:

### Step 4.1: type: codd_wave 検知

cmd.type == "codd_wave" の場合 → 以下の Steps 4.2〜4.4 を実行し、Step 5 (通常タスク分解) をスキップ。

### Step 4.2: parallel_docs 並列配分

parallel_docs をイテレート。各 doc について bloom_routing 実行:
- `L1-L2` → Haiku tier (ashigaru1,2)
- `L3-L5` → Sonnet tier (ashigaru3-6)
- `L6` → Opus tier (ashigaru7)

同一足軽への二重割当を避ける（7並列まで）。`parallel_docs[].assignee` を確定。

### Step 4.3: ashigaru task YAML書込

各 doc ごとに `queue/tasks/ashigaru{N}.yaml` を作成 (上記テンプレ参照)。

### Step 4.4: 一括 inbox_write

全 ashigaru に inbox_write で通知。

### Step 11.6: Wave完了判定

同一 parent_cmd の全 subtask が `status: done` か確認:
- **全 done** → 軍師 QC task YAML を `queue/tasks/gunshi.yaml` に書込 → `bash scripts/inbox_write.sh gunshi "cmd_codd_<project>_W<N> QC開始せよ。" task_assigned karo`
- **in_progress あり** → 待機継続

### QC fail 差し戻し手順

```
軍師 report qc_result: fail →
1. regenerate_docs リストの doc のみ subtask 再書込
   description に qc_notes の feedback を埋める
2. bash scripts/inbox_write.sh ashigaru{N} "タスクYAMLを読んで作業開始せよ。" task_assigned karo
3. 最大リトライ 2回。3回目は dashboard 🚨要対応 でエスカレーション。
```

## codd.yaml AI 設定の Brownfield 用途

| 用途 | 推奨モデル | 理由 |
|------|----------|------|
| Greenfield generate | `claude-sonnet-4-6` (default) | 要件→設計の生成は中規模文書・Sonnet で十分 |
| Brownfield extract --ai | `claude-sonnet-4-6` (**default 維持必須**) | 既存コード全文読込で長文タスクになる。Haiku では 6層分類が破綻 (FM14) |
| Brownfield restore --feedback | `claude-sonnet-4-6` | レビュー指摘を反映する小規模再生成 |
| L6 Wave (戦略・アーキ) | `claude-opus-4-6` (l6_override) | 高度判断が必要な層のみ Opus |
| Haiku 利用 | **不可 (extract系は禁止)** | Brownfield では FM14 リスク高 |

## codd.yaml 標準テンプレ

```yaml
# shogun-codd 標準 codd.yaml
# L6タスクのみ Opus、他は Sonnet固定
ai:
  default: "claude --print --model claude-sonnet-4-6"
  l6_override: "claude --print --model claude-opus-4-6"
ai_timeout_seconds: 3600
  # v2.14 SSoT: デフォルト3600sだが明示推奨
waves:
  max_parallel: 7
```

## archive fallback (is_dependency_satisfied)

セッション断後の復帰で Wave cmd が archive 済みの場合、依存解決できなくなるリスクを防ぐ。

依存確認時は以下の順で検索:
1. `queue/shogun_to_karo.yaml` に該当 cmd が `status: done` で存在 → 満足
2. `queue/archive/` 以下のYAMLに `id: <depends_on>` かつ `status: done` が存在 → 満足
3. どちらにも存在しない → 未満足 (pending のまま)

## CoDD ネイティブ dependency 機能と shogun-codd 補助方針

CoDD は **dependency 駆動設計** が根幹で、以下を既にネイティブサポートしている:

### 既存ネイティブ機能

| 機能 | コマンド/箇所 | 内容 |
|------|--------------|------|
| frontmatter 双方向参照 | restored doc の `codd:` セクション | `depends_on` / `depended_by` (relation/semantic 付き) |
| DAG 可視化 | `codd dag visualize` | プロジェクト全体の DAG を Mermaid で標準出力 |
| DAG 検証 | `codd dag verify` | completeness check (v2.14: --auto-repair 対応) |
| 変更影響分析 | `codd impact` | git diff から影響範囲算出 |
| user journey | `codd dag journeys` / `run-journey` | 設計書上の journey 列挙・CDP 実行 |
| Sprintless実装依存 | `codd implement --depends-on` | 設計書間の実装依存を直接指定 |

### 新機能要望前のチェックリスト

CoDD に対して新機能要望を出す前 (or shogun-codd 改修前) に、必ず以下を確認:

```bash
codd --help                # サブコマンド全体俯瞰
codd <subcommand> --help   # 個別オプション
```

→ `memory/feedback_codd_dependency_native_support.md` 参照。

### shogun-codd 補助方針: docs/INDEX.md 自前生成

`docs/INDEX.md` (Wave別 + MECE別 + dependency graph 二軸索引) は **shogun-codd 側で自前生成** する。

```
codd plan --json     → Wave 構成 + node_id ↔ output path 対応
codd dag visualize   → Mermaid DAG (dependency)
            ↓
shogun-codd 側で integration スクリプトで INDEX.md 生成
```

## Failure Mode 要約

| ID | 失敗モード | 対処 |
|----|----------|------|
| FM01 | codd CLI 未インストール | preflight で検出・停止 |
| FM02 | project_dir 未作成 | Step 4.1 で検証・🚨 |
| FM03 | codd generate 失敗 | 足軽 retry 1回→失敗で家老🚨 |
| FM04 | codd validate 失敗 | 軍師が再生成指示 |
| FM07 | QC fail 無限ループ | 3回目で殿🚨エスカレーション |
| FM11 | archive cmd 依存 | archive fallback (本スキル対応) |
| FM12 | codd バージョン変更 | preflight で **v2.14.0** 確認。移行ガイド参照 |
| FM13 | extract 結果が現実コードと乖離 (Brownfield) | Step 5 殿/将軍レビュー必須化。`codd extract --ai` で再抽出。レビューを skip して Wave 起動するのは禁止 |
| FM14 | 6層 MECE 分類が破綻 (層境界が不明瞭・重複・欠落) | Haiku で extract した場合に頻発。`codd.yaml` で Sonnet 維持を必須化。それでも破綻する場合は `--source-dirs` で読込範囲を絞り Wave 単位で再抽出 |
| FM15 | ~~target ディレクトリ汚染 (Bug #19 / v1.34)~~ | **v2.8 で解消**。extract 出力が `.codd/extract/` (CWD) に固定 |
| FM16 | ~~extract → plan --init frontmatter 不整合 (Bug #17 / v1.34)~~ | **v2.8 で解消**。`codd:` サブセクションが正しく生成 |
| FM17 | plan derive timeout (G1) | `ai_timeout_seconds: 3600` を codd.yaml に設定 (v2.14 デフォルト3600) |
| FM18 | derive output と implement extract の整合性破綻 (G2/G3) | **v2.11 Sprintless で構造変更**。`codd implement --design --output` 直接指定で回避 |
| FM19 | generated code の末尾に markdown 解説混入 (G11) | post-process スクリプトで `\n` ``` `\n` 以降を削除 |
| FM20 | `codd2` コマンド not found | v2.14 では `codd` に変更。全スクリプト・タスクYAMLを `codd` に更新 |
| FM21 | implementation_plan.md が見つからない (v2.11 Breaking) | Sprintless への移行。`codd implement --design <path>` を使用 |
| FM22 | Opt-out config で justification/expires_at 未記載 (v2.13) | `codd validate` がエラー。codd.yaml の opt-out セクションに両フィールドを追記 |
| FM23 | DAG verify で amber noise が大量発生 | v2.14 の `scan.exclude` バグ修正適用確認。v2.14未満の場合はアップグレード |
