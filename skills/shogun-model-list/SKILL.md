---
name: shogun-model-list
description: >
  All AI CLI tools × available models × required subscriptions × Bloom max capability.
  Reference table for choosing which models to use in multi-agent-shogun.
  Trigger: "model list", "what models", "model comparison", "which models can I use",
  "モデル一覧", "モデル比較", "どのモデルが使える"
---

# /shogun-model-list — Model Capability Reference

## Overview

Displays a complete reference table of all AI CLI tools, models, required subscriptions,
and maximum Bloom cognitive level per model. Use this before configuring `capability_tiers`
in `config/settings.yaml`.

## When to Use

- "What models can I use with my subscription?"
- "Which model handles L5 tasks?"
- "Compare Claude vs Codex model tiers"
- "Show me all models" / "モデル一覧"
- Before running `/shogun-bloom-config` to understand the landscape

## Instructions

Output the reference tables below directly to the user. No tool calls required.

---

## Bloom's Taxonomy — Quick Reference

| Level | Category | Task Examples |
|-------|----------|---------------|
| L1 | Remember | File copy, template apply, data format |
| L2 | Understand | Summarize, explain, translate |
| L3 | Apply | Implement known patterns, generate boilerplate |
| L4 | Analyze | Debug, code review, root cause analysis |
| L5 | Evaluate | Architecture review, design trade-off judgment |
| L6 | Create | Novel architecture, requirements design, strategy |

---

## Claude Code (Anthropic)

### Subscription Plans

| Plan | Monthly | Opus 5.5 | Sonnet 5.5 | Haiku 4.5 | Extended Thinking |
|------|---------|----------|------------|-----------|-------------------|
| Free | $0 | ✗ | ✓ | ✓ | ✗ |
| Pro | $20 | ✓ | ✓ | ✓ | ✓ |
| Max 5x | $100 | ✓ | ✓ | ✓ | ✓ |
| Max 20x | $200 | ✓ | ✓ | ✓ | ✓ |

> Pro/Max 5x/Max 20x have the same model access. The difference is usage quota (5x/20x = multiplier of Pro).
> **Fable 5.1** (alias `fable`) is a separate model line used only by Shogun for strategic/orchestration work (cmd_783, 2026-09-29). Its per-plan gating is not independently verified here — confirm in your own environment.
> Claude Code's `opus`/`sonnet`/`fable` are aliases that track Anthropic's "latest" release, so the version they resolve to drifts over time. Measured 2026-09-29 (Claude Code 2.1.284): `opus`→Opus 5.5, `sonnet`→Sonnet 5.5, `fable`→Fable 5.1.

### Claude Models × Bloom Capability

| Model | Bloom Max | Best For | Notes |
|-------|-----------|----------|-------|
| `claude-haiku-4-5-20251001` | **L3** | High-volume L1-L3 tasks, fast responses | $1/$5/M; SWE-bench 73.3% (4pp below Sonnet 4.5); extended thinking available; unchanged by cmd_783 |
| `sonnet` (alias → `claude-sonnet-5-5`) | **L5** | Code review, analysis, orchestration | Effort default: medium. Predecessor `claude-sonnet-4-6` was $3/$15/M, SWE-bench 79.6% — 5.5-series pricing/benchmarks not yet verified here |
| `opus` (alias → `claude-opus-5-5`) | **L6** | Novel design, strategy, architecture | Effort default: medium; Ashigaru 7 pins `--effort xhigh`. Predecessor `claude-opus-4-6` was $5/$25/M, SWE-bench 80.8% |
| `fable` (alias → `claude-fable-5-1`) | **L6** | Shogun's strategic/orchestration role only (cmd_783, 2026-09-29) | New to the roster — no prior-version benchmark to compare; effort left at default |

> **Extended Thinking** (available Pro+): Adds ~1 Bloom level of effective capability on complex reasoning tasks.
> `claude-sonnet-4-6` / `claude-opus-4-6` (pre-5.5) are **Older** — superseded 2026-09-29 (cmd_783). Kept here only for historical benchmark comparison; do not configure new agents on them.

### Fixed Agent Assignments (Recommended)

| Agent | Recommended Model | Bloom Use | Reason |
|-------|------------------|-----------|--------|
| Shogun (You) | `fable` (Claude) | L6 | Strategic decisions, final review (cmd_783, 2026-09-29) |
| Karo (Manager) | `sonnet` (Claude) | L4-L5 | Task orchestration; effort left at default |
| Gunshi (Strategist) | `gpt-6-sol` (Codex) | L5-L6 | Deep QC, architecture evaluation |
| Ashigaru 3–6 | `sonnet --effort xhigh` (Claude) | L1-L3 | Workers — routed by Bloom level |
| Ashigaru 7 | `opus --effort xhigh` (Claude) | L1-L3 | Highest-capability worker seat |
| Ashigaru 1–2 | `gpt-6-luna` (Codex; fallback `gpt-reserve`) | L1-L3 | Workers — routed by Bloom level |

---

## OpenAI Codex CLI

### Subscription Plans

| Plan | Monthly | gpt-6-sol | gpt-6-luna | gpt-reserve |
|------|---------|-----------|------------|-------------|
| Free / Go ($8) | $0–$8 | ✗ (limited) | ✗ | Unconfirmed |
| Plus | $20 | ✓ | ✓ | Unconfirmed |
| Pro | $200 | ✓ | ✓ | Unconfirmed |

> Confirmed responding on the Lord's ChatGPT Pro account via Codex CLI 0.158.0 for all three of gpt-6-sol, gpt-6-luna, and gpt-reserve (cmd_783, 2026-09-29; 0.154.0 rejected gpt-6-sol/luna as "account not supported"). Per [official Pricing](https://learn.chatgpt.com/docs/pricing) (checked 2026-09-29), both Plus and Pro list GPT-6 Sol and GPT-6 Luna — Luna is **not** Pro-exclusive. [Official Models docs](https://learn.chatgpt.com/docs/models) note availability depends on rollout, sign-in method, and client, so this repo's own confirmation (sol/luna/reserve responding) covers the Lord's Pro-tier account only — not independently re-verified on a Plus-tier account. `gpt-reserve` is not a named model in the official docs reviewed here, so its **general availability across plan tiers (the Free/Plus/Pro boundary)** remains unconfirmed — that is separate from the Lord's-account response confirmation above, not a statement that gpt-reserve itself is untested.
> **Older generation (kept for reference — do not configure new agents on these):** `gpt-5.3-codex-spark` — **EOS**; was the L1-L3 fast-worker tier, replaced by `gpt-6-luna` (fallback `gpt-reserve`). `gpt-5.6-sol` — **Older**; was Gunshi's model, replaced by `gpt-6-sol`. `gpt-5.3-codex` / `gpt-5-codex-mini` / `gpt-5.1-codex-max` — **Older** pre-GPT-6 Codex CLI tiers; no confirmed GPT-6-generation equivalent, so they are not carried forward 1:1 below.

### Codex Models × Bloom Capability

| Model | Bloom Max | Best For | Notes |
|-------|-----------|----------|-------|
| `gpt-6-luna` | **L3** | High-volume L1-L3 tasks (Ashigaru 1–2's current model) | Fallback: `gpt-reserve` if luna doesn't fit the account (cmd_783). Replaces the EOS `gpt-5.3-codex-spark` |
| `gpt-reserve` | **L3** | Fallback for `gpt-6-luna` | Use only when `gpt-6-luna` doesn't fit the account |
| `gpt-6-sol` | **L5** | Analysis, debugging, code review, architecture evaluation (Gunshi's current model) | Replaces the Older `gpt-5.6-sol` |

> **L6 gap**: No Codex model in the current lineup reliably handles novel creative design (L6). For L6 tasks, Claude `opus` is recommended.
> **EOS/Older, kept for reference only:** `gpt-5.3-codex-spark` (EOS), `gpt-5.6-sol` (Older), `gpt-5.3-codex` / `gpt-5-codex-mini` / `gpt-5.1-codex-max` (Older, pre-GPT-6 tiers — see Subscription Plans note above).

---

## Capability Summary (All Models, Cross-CLI)

| Model | CLI | Bloom Max | Min Subscription | Notes |
|-------|-----|-----------|-----------------|-------|
| `claude-haiku-4-5-20251001` | Claude Code | **L3** | Claude Free | Best Claude cost-efficiency; SWE-bench 73.3%; unchanged by cmd_783 |
| `gpt-6-luna` | Codex CLI | L3 | **ChatGPT Plus** | Ashigaru 1–2's current model; fallback `gpt-reserve`. Listed on both Plus and Pro per official Pricing (2026-09-29) — not Pro-exclusive |
| `gpt-reserve` | Codex CLI | L3 | Unconfirmed | Fallback for `gpt-6-luna`; not a named model in official docs reviewed — plan-tier requirement unconfirmed |
| `sonnet` (→ `claude-sonnet-5-5`) | Claude Code | L5 | Claude Free | Karo's current model; effort default medium |
| `gpt-6-sol` | Codex CLI | L5 | ChatGPT Plus | Gunshi's current model |
| `opus` (→ `claude-opus-5-5`) | Claude Code | L6 | Claude Pro | Ashigaru 7 pins `--effort xhigh`; reserve for true L6 tasks |
| `fable` (→ `claude-fable-5-1`) | Claude Code | L6 | — | Shogun's current model (cmd_783, 2026-09-29); per-plan minimum not verified here — assume Pro+ like Opus until confirmed |

> **EOS/Older, retained for reference — not for new configuration:** `gpt-5.3-codex-spark` (EOS), `gpt-5.6-sol` (Older), `gpt-5.3-codex` / `gpt-5-codex-mini` / `gpt-5.1-codex-max` (Older, pre-GPT-6 Codex tiers), `claude-sonnet-4-6` / `claude-opus-4-6` (Older, pre-5.5 Claude versions).

---

## Next Step

To generate a ready-to-paste `capability_tiers` YAML for your subscription:

```
/shogun-bloom-config
```

Or tell the Shogun: "set up capability tiers for my subscription"
