#!/usr/bin/env python3
"""
chat_intent_parser.py — Google Chat 外部入力の intent 解析 (deterministic rules)
cmd_506 Batch D

使用方法:
  result = parse_intent(text, config_path="config/external_inputs.yaml")

設計原則:
- parser は判定のみ。cmd YAML / task YAML を直接作らない (家老解釈経由必須)。
- 高リスク intent (submit / 外部送信 / 削除 / 公開) は requires_karo_approval=True で明示。
- Prompt injection 風テキストは unknown / 低 confidence に落とす。
- skill 拡張点: config/external_inputs.yaml の skill_extensions に rules を登録。
- LLM fallback: feature flag off (採用時は Claude CLI subprocess・SDK 直叩き禁止)。
"""

from __future__ import annotations

import re
import logging
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

import yaml

logger = logging.getLogger(__name__)

# confidence 定数
CONFIDENCE_HIGH = 0.9
CONFIDENCE_MEDIUM = 0.7
CONFIDENCE_LOW = 0.3
CONFIDENCE_INJECTION_PENALTY = 0.4  # injection 検出時の penalty


@dataclass
class IntentResult:
    intent: str
    confidence: float
    requires_karo_approval: bool
    raw_text: str
    matched_pattern: Optional[str] = None
    skill_source: Optional[str] = None
    injection_detected: bool = False
    metadata: dict = field(default_factory=dict)

    def to_dict(self) -> dict:
        return {
            "intent": self.intent,
            "confidence": self.confidence,
            "requires_karo_approval": self.requires_karo_approval,
            "raw_text": self.raw_text,
            "matched_pattern": self.matched_pattern,
            "skill_source": self.skill_source,
            "injection_detected": self.injection_detected,
            "metadata": self.metadata,
        }


def _load_config(config_path: str) -> dict:
    p = Path(config_path)
    if not p.exists():
        logger.warning("config not found: %s — using empty config", config_path)
        return {}
    with open(p, encoding="utf-8") as f:
        return yaml.safe_load(f) or {}


def _normalize(text: str) -> str:
    return text.strip()


def _detect_injection(text: str, injection_patterns: list[str]) -> bool:
    """Prompt injection 風テキストを検出する。"""
    normalized = text.lower()
    for pat in injection_patterns:
        if re.search(pat, normalized, re.IGNORECASE):
            return True
    return False


def _match_patterns(text: str, patterns: list[str]) -> Optional[str]:
    """patterns のいずれかにマッチすれば最初にマッチしたパターンを返す。"""
    for pat in patterns:
        if re.search(pat, text, re.IGNORECASE):
            return pat
    return None


def _build_candidates(
    text: str,
    config: dict,
    high_risk_intents: set[str],
) -> list[tuple[float, IntentResult]]:
    """core + skill extensions のすべての候補を (score, result) リストで返す。"""
    candidates: list[tuple[float, IntentResult]] = []
    parser_cfg = config.get("intent_parser", {})

    # core intents
    for entry in parser_cfg.get("core_intents", []):
        intent_name = entry["intent"]
        matched = _match_patterns(text, entry.get("patterns", []))
        if matched:
            high_risk = entry.get("high_risk", False) or intent_name in high_risk_intents
            candidates.append((
                CONFIDENCE_HIGH,
                IntentResult(
                    intent=intent_name,
                    confidence=CONFIDENCE_HIGH,
                    requires_karo_approval=high_risk,
                    raw_text=text,
                    matched_pattern=matched,
                    skill_source="core",
                ),
            ))

    # skill extensions
    for skill_key, skill_cfg in parser_cfg.get("skill_extensions", {}).items():
        if not skill_cfg.get("enabled", True):
            continue
        for entry in skill_cfg.get("intents", []):
            intent_name = entry["intent"]
            matched = _match_patterns(text, entry.get("patterns", []))
            if matched:
                high_risk = entry.get("high_risk", False) or intent_name in high_risk_intents
                candidates.append((
                    CONFIDENCE_HIGH,
                    IntentResult(
                        intent=intent_name,
                        confidence=CONFIDENCE_HIGH,
                        requires_karo_approval=high_risk,
                        raw_text=text,
                        matched_pattern=matched,
                        skill_source=skill_key,
                    ),
                ))

    return candidates


def parse_intent(
    text: str,
    config_path: str = "config/external_inputs.yaml",
    _config: Optional[dict] = None,
) -> IntentResult:
    """
    text の intent を解析して IntentResult を返す。
    _config は単体テスト用 override (config_path より優先)。

    ★ この関数は判定のみ。cmd YAML / task YAML を作らない。
    """
    config = _config if _config is not None else _load_config(config_path)
    parser_cfg = config.get("intent_parser", {})

    text = _normalize(text)
    if not text:
        return IntentResult(
            intent="unknown",
            confidence=0.0,
            requires_karo_approval=False,
            raw_text=text,
            metadata={"reason": "empty_input"},
        )

    # 高リスク intent セット
    high_risk_intents: set[str] = set(parser_cfg.get("high_risk_intents", []))

    # Prompt injection 検出
    injection_patterns = parser_cfg.get("prompt_injection_patterns", [])
    injection_detected = _detect_injection(text, injection_patterns)

    # candidates を収集
    candidates = _build_candidates(text, config, high_risk_intents)

    if not candidates:
        # マッチなし → unknown
        confidence = CONFIDENCE_LOW if not injection_detected else CONFIDENCE_LOW * (1 - CONFIDENCE_INJECTION_PENALTY)
        return IntentResult(
            intent="unknown",
            confidence=round(confidence, 3),
            requires_karo_approval=False,
            raw_text=text,
            injection_detected=injection_detected,
            metadata={"reason": "no_pattern_match"},
        )

    # 最高スコアを選択
    _, best = max(candidates, key=lambda x: x[0])

    # injection penalty 適用
    if injection_detected:
        penalized = best.confidence * (1 - CONFIDENCE_INJECTION_PENALTY)
        best = IntentResult(
            intent="unknown",
            confidence=round(penalized, 3),
            requires_karo_approval=False,
            raw_text=text,
            matched_pattern=best.matched_pattern,
            skill_source=best.skill_source,
            injection_detected=True,
            metadata={"reason": "injection_detected", "original_intent": best.intent},
        )

    return best


def annotate_chat_inbox_entry(entry: dict, config_path: str = "config/external_inputs.yaml") -> dict:
    """
    chat_inbox.yaml のエントリに intent 解析結果を追記して返す。
    実際の YAML 書き込みは呼び出し元 (家老 / watcher) が行う。

    parser 内部の IntentResult を inbox schema 形式に写像する:
      - skill_source == "core" → core_type = intent, skill_id/skill_type = null
      - skill_source != "core" → core_type = "cmd_new", skill_id = skill_source, skill_type = intent
      - requires_karo_approval は intent.extracted に明示
    """
    text = entry.get("text", "")
    result = parse_intent(text, config_path=config_path)

    if result.skill_source and result.skill_source != "core":
        core_type = "cmd_new"
        skill_id = result.skill_source
        skill_type = result.intent if result.intent != "unknown" else None
    else:
        core_type = result.intent if result.intent != "unknown" else None
        skill_id = None
        skill_type = None

    extracted: Optional[dict] = None
    if result.requires_karo_approval or result.injection_detected:
        extracted = {
            "requires_karo_approval": result.requires_karo_approval,
            "injection_detected": result.injection_detected,
        }

    entry["intent"] = {
        "status": "parsed",
        "core_type": core_type,
        "skill_id": skill_id,
        "skill_type": skill_type,
        "confidence": result.confidence,
        "extracted": extracted,
    }

    if "karo_decision" in entry and result.requires_karo_approval:
        entry["karo_decision"]["confirmation_required"] = True

    return entry
