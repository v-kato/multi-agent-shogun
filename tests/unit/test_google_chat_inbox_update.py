"""
test_google_chat_inbox_update.py — google_chat_inbox_update.py 単体テスト
cmd_506 Phase G-2 K-G2-001〜K-G2-004

テスト観点:
  K-G2-001: intent parse 後、unknown/no action entry が processed:true になる
  K-G2-002: submit/high risk は karo_decision.status:needs_confirmation + processed:true
  K-G2-003: accepted cmd_new は parent cmd とリンクし processed:true + karo_decision.parent_cmd を持つ
  K-G2-004: 処理後 count_unprocessed が 0 になる
"""

import sys
from pathlib import Path
from unittest.mock import patch

import pytest
import yaml

sys.path.insert(0, str(Path(__file__).parent.parent.parent / "scripts"))

from google_chat_inbox_update import (
    count_unprocessed,
    cmd_annotate,
    cmd_mark_processed,
    _load_inbox,
)


def _write_inbox(path: str, entries: list) -> None:
    """テスト用: inbox YAML を直接書き込む"""
    data = {"inbox": entries}
    with open(path, "w", encoding="utf-8") as f:
        yaml.dump(data, f, allow_unicode=True, default_flow_style=False, sort_keys=False)


def _make_entry(
    entry_id: str,
    message_id: str,
    text: str = "@shogun-external-inputs テスト",
    processed: bool = False,
    rejected: bool = False,
) -> dict:
    return {
        "id": entry_id,
        "message_id": message_id,
        "source_channel": "google_chat",
        "text": text,
        "processed": processed,
        "rejected": rejected,
        "intent": {"status": "pending", "core_type": None, "skill_id": None, "skill_type": None, "confidence": None, "extracted": None},
        "karo_decision": {"status": "pending", "reason": None, "parent_cmd": None, "confirmation_required": False, "dashboard_action_required": False},
        "read": False,
    }


class TestK_G2_001_UnknownBecomeProcessed:
    """K-G2-001: unknown/no action entry が mark-processed 後に processed:true になる"""

    def test_unknown_intent_marked_processed(self, tmp_path):
        inbox_path = str(tmp_path / "google_chat_inbox.yaml")
        entry = _make_entry("ext_001", "spaces/AAA/messages/001", text="@shogun-external-inputs も一回テスト")
        # intent.status=parsed, confidence=0.3 (unknown相当) のエントリを準備
        entry["intent"] = {"status": "parsed", "core_type": None, "confidence": 0.3, "skill_id": None, "skill_type": None, "extracted": None}
        _write_inbox(inbox_path, [entry])

        args = _make_mark_processed_args(
            entry_id="ext_001",
            message_id=None,
            decision="rejected",
            reason="no_actionable_intent",
            parent_cmd=None,
            inbox=inbox_path,
        )
        ret = cmd_mark_processed(args)
        assert ret == 0

        _, entries = _load_inbox(inbox_path)
        assert entries[0]["processed"] is True
        assert entries[0]["karo_decision"]["status"] == "rejected"
        assert entries[0]["karo_decision"]["reason"] == "no_actionable_intent"

    def test_mark_processed_by_message_id(self, tmp_path):
        inbox_path = str(tmp_path / "google_chat_inbox.yaml")
        entry = _make_entry("ext_001", "spaces/AAA/messages/msg-001")
        _write_inbox(inbox_path, [entry])

        args = _make_mark_processed_args(
            entry_id=None,
            message_id="spaces/AAA/messages/msg-001",
            decision="rejected",
            reason="no_actionable_intent",
            parent_cmd=None,
            inbox=inbox_path,
        )
        ret = cmd_mark_processed(args)
        assert ret == 0

        _, entries = _load_inbox(inbox_path)
        assert entries[0]["processed"] is True
        assert entries[0]["read"] is True


class TestK_G2_002_HighRiskNeedsConfirmation:
    """K-G2-002: submit/high risk → karo_decision.status:needs_confirmation + processed:true"""

    def test_needs_confirmation_sets_flags(self, tmp_path):
        inbox_path = str(tmp_path / "google_chat_inbox.yaml")
        entry = _make_entry("ext_submit", "spaces/AAA/messages/submit-001", text="出荷依頼書を提出してください")
        entry["intent"] = {"status": "parsed", "core_type": "cmd_new", "skill_id": "pokemon_shipment", "skill_type": "submit", "confidence": 0.9, "extracted": {"requires_karo_approval": True}}
        _write_inbox(inbox_path, [entry])

        args = _make_mark_processed_args(
            entry_id="ext_submit",
            message_id=None,
            decision="needs_confirmation",
            reason="submit_requires_human_approval",
            parent_cmd=None,
            inbox=inbox_path,
        )
        ret = cmd_mark_processed(args)
        assert ret == 0

        _, entries = _load_inbox(inbox_path)
        e = entries[0]
        assert e["processed"] is True
        assert e["karo_decision"]["status"] == "needs_confirmation"
        assert e["karo_decision"]["confirmation_required"] is True
        assert e["karo_decision"]["dashboard_action_required"] is True


class TestK_G2_003_AcceptedWithParentCmd:
    """K-G2-003: accepted → parent_cmd 紐付け + processed:true"""

    def test_accepted_with_parent_cmd(self, tmp_path):
        inbox_path = str(tmp_path / "google_chat_inbox.yaml")
        entry = _make_entry("ext_cmd", "spaces/AAA/messages/cmd-001", text="新規コマンド実行してください")
        _write_inbox(inbox_path, [entry])

        args = _make_mark_processed_args(
            entry_id="ext_cmd",
            message_id=None,
            decision="accepted",
            reason="cmd_new created",
            parent_cmd="cmd_999",
            inbox=inbox_path,
        )
        ret = cmd_mark_processed(args)
        assert ret == 0

        _, entries = _load_inbox(inbox_path)
        e = entries[0]
        assert e["processed"] is True
        assert e["karo_decision"]["status"] == "accepted"
        assert e["karo_decision"]["parent_cmd"] == "cmd_999"


class TestK_G2_004_CountUnprocessedZeroAfterMark:
    """K-G2-004: 処理後 count_unprocessed が 0 になる"""

    def test_count_drops_to_zero_after_mark_processed(self, tmp_path):
        inbox_path = str(tmp_path / "google_chat_inbox.yaml")
        entries = [
            _make_entry("ext_001", "spaces/AAA/messages/001"),
        ]
        _write_inbox(inbox_path, entries)

        _, loaded_entries = _load_inbox(inbox_path)
        assert count_unprocessed(loaded_entries) == 1

        args = _make_mark_processed_args(
            entry_id="ext_001",
            message_id=None,
            decision="rejected",
            reason="no_actionable_intent",
            parent_cmd=None,
            inbox=inbox_path,
        )
        cmd_mark_processed(args)

        _, updated = _load_inbox(inbox_path)
        assert count_unprocessed(updated) == 0

    def test_count_unprocessed_excludes_rejected_and_processed(self, tmp_path):
        """processed=true と rejected=true はカウント外"""
        inbox_path = str(tmp_path / "google_chat_inbox.yaml")
        entries = [
            _make_entry("ext_001", "msg-001", processed=False, rejected=False),  # カウント対象
            _make_entry("ext_002", "msg-002", processed=True, rejected=False),   # 除外
            _make_entry("ext_003", "msg-003", processed=False, rejected=True),   # 除外
        ]
        _write_inbox(inbox_path, entries)

        _, loaded = _load_inbox(inbox_path)
        assert count_unprocessed(loaded) == 1

    def test_not_found_returns_error(self, tmp_path):
        """存在しない entry_id は return 1"""
        inbox_path = str(tmp_path / "google_chat_inbox.yaml")
        _write_inbox(inbox_path, [_make_entry("ext_001", "msg-001")])

        args = _make_mark_processed_args(
            entry_id="non_existent",
            message_id=None,
            decision="rejected",
            reason="test",
            parent_cmd=None,
            inbox=inbox_path,
        )
        ret = cmd_mark_processed(args)
        assert ret == 1


# ─── ヘルパー ───

class _MarkProcessedArgs:
    def __init__(self, entry_id, message_id, decision, reason, parent_cmd, inbox):
        self.id = entry_id
        self.message_id = message_id
        self.decision = decision
        self.reason = reason
        self.parent_cmd = parent_cmd
        self.inbox = inbox


def _make_mark_processed_args(entry_id, message_id, decision, reason, parent_cmd, inbox):
    return _MarkProcessedArgs(entry_id, message_id, decision, reason, parent_cmd, inbox)
