"""
test_chat_listener_interaction.py — chat_listener.py interaction event mode テスト (cmd_554 Phase C)

カバレッジ:
- decode_payload_interaction (json.loads のみ・base64 なし)
- check_noise_filter_interaction (type==MESSAGE && target_space 照合)
- extract_chat_message_interaction
- build_inbox_entry_interaction (space/thread 両系統 fallback)
- process_message_interaction (7 fixture 種 + 旧 CloudEvent 回帰)

fixtures:
  1. MESSAGE @mention — allowlisted sender → accepted
  2. MESSAGE DM — singleUserBotDm=true → accepted
  3. ADDED_TO_SPACE — noise filter → rejected ack のみ
  4. REMOVED_FROM_SPACE — noise filter → rejected ack のみ
  5. allowlist 外 — rejected:sender_not_allowlisted
  6. 重複 message_id — rejected:duplicate_message
  7. 不正 JSON — rejected:malformed_payload
  + 旧 CloudEvent 回帰 — 旧 process_message が壊れていないことを確認
"""

import base64
import json
import sys
from pathlib import Path
from unittest.mock import MagicMock

import pytest
import yaml

sys.path.insert(0, str(Path(__file__).parent.parent.parent / "scripts"))

from chat_listener import (
    ProcessResult,
    atomic_yaml_append_if_absent,
    build_inbox_entry_interaction,
    check_noise_filter_interaction,
    decode_payload_interaction,
    extract_chat_message_interaction,
    load_inbox_dedups,
    process_message,
    process_message_interaction,
)

TARGET_SPACE = "spaces/AAAAeAy5hcg"
ALLOWLIST = {
    "verified_identifiers": ["kato@v-sync.co.jp"],
    "sender_ids": ["users/115970327619114022410"],
}

# 旧 Workspace Events mode 用 (回帰確認)
SUBJECT = "//chat.googleapis.com/spaces/AAAAeAy5hcg"
TYPE_CREATED = "google.workspace.chat.message.v1.created"


# ── fixture ヘルパー ───────────────────────────────────────────────────────────


def _make_interaction_event(
    event_type: str = "MESSAGE",
    message_name: str = "spaces/AAAAeAy5hcg/messages/MSG001",
    sender_id: str = "users/115970327619114022410",
    sender_email: str = "kato@v-sync.co.jp",
    text: str = "@外部入力テスト 出荷お願いします",
    space_name: str = TARGET_SPACE,
    space_in_message: bool = True,
    single_user_bot_dm: bool = False,
) -> dict:
    """interaction event の top-level Event オブジェクトを生成"""
    event = {
        "type": event_type,
        "eventTime": "2026-06-03T18:00:00Z",
        "token": "test-verification-token",
    }
    if space_in_message:
        event["space"] = {
            "name": space_name,
            "type": "ROOM",
            "spaceType": "SPACE",
            "displayName": "テストスペース",
            "singleUserBotDm": single_user_bot_dm,
        }
    if event_type in ("MESSAGE",):
        event["message"] = {
            "name": message_name,
            "sender": {
                "name": sender_id,
                "displayName": "殿",
                "email": sender_email,
                "type": "HUMAN",
            },
            "text": text,
            "argumentText": text,
            "createTime": "2026-06-03T18:00:00Z",
            "thread": {"name": f"{space_name}/threads/TH001"},
            "space": {"name": space_name},
        }
        event["user"] = event["message"]["sender"]
        event["thread"] = event["message"]["thread"]
    elif event_type == "ADDED_TO_SPACE":
        event["user"] = {"name": sender_id, "displayName": "殿", "type": "HUMAN"}
    elif event_type == "REMOVED_FROM_SPACE":
        event["user"] = {"name": sender_id, "displayName": "殿", "type": "HUMAN"}
    return event


def _make_pubsub_message_interaction(
    event: dict,
    delivery_id: str = "pubsub-interaction-001",
) -> MagicMock:
    """interaction event を Pub/Sub ReceivedMessage モックに包む"""
    data_bytes = json.dumps(event, ensure_ascii=False).encode("utf-8")
    msg = MagicMock()
    msg.message_id = delivery_id
    msg.data = data_bytes
    msg.attributes = {}  # interaction mode では attributes を使わない
    return msg


def _make_pubsub_message_workspace_events(
    message_id: str = "spaces/AAAAeAy5hcg/messages/WS001",
    delivery_id: str = "pubsub-ws-001",
    text: str = "テストメッセージ",
    sender_name: str = "users/115970327619114022410",
    ce_subject: str = SUBJECT,
    ce_type: str = TYPE_CREATED,
) -> MagicMock:
    """旧 Workspace Events CloudEvent 形式のモック"""
    payload = {
        "message": {
            "name": message_id,
            "text": text,
            "sender": {"name": sender_name, "displayName": "殿", "type": "HUMAN"},
            "space": {"name": "spaces/AAAAeAy5hcg"},
            "thread": {"name": "spaces/AAAAeAy5hcg/threads/T01"},
            "createTime": "2026-06-03T18:00:00Z",
        }
    }
    data_bytes = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    msg = MagicMock()
    msg.message_id = delivery_id
    msg.data = data_bytes
    msg.attributes = {"ce-subject": ce_subject, "ce-type": ce_type, "ce-time": "2026-06-03T18:00:00Z"}
    return msg


# ── decode_payload_interaction ─────────────────────────────────────────────────


class TestDecodePayloadInteraction:
    def test_json_direct_parse(self):
        """interaction mode: json.loads のみで parse"""
        event = _make_interaction_event()
        data = json.dumps(event, ensure_ascii=False).encode("utf-8")
        result = decode_payload_interaction(data)
        assert result["type"] == "MESSAGE"
        assert result["space"]["name"] == TARGET_SPACE

    def test_japanese_preserved(self):
        """日本語テキストが破損しない"""
        event = _make_interaction_event(text="ポケモン出荷お願いします")
        data = json.dumps(event, ensure_ascii=False).encode("utf-8")
        result = decode_payload_interaction(data)
        assert result["message"]["text"] == "ポケモン出荷お願いします"

    def test_empty_data_raises(self):
        with pytest.raises(ValueError, match="empty data"):
            decode_payload_interaction(b"")

    def test_malformed_json_raises(self):
        with pytest.raises(ValueError, match="malformed_payload"):
            decode_payload_interaction(b"not valid json !!!")

    def test_no_base64_unwrapping(self):
        """interaction mode では base64 unwrap しない (data フィールドが dict でも json.loads のみ)"""
        inner = {"message": {"name": "spaces/AAA/messages/001"}}
        inner_bytes = json.dumps(inner).encode("utf-8")
        b64 = base64.b64encode(inner_bytes).decode("ascii")
        # base64 文字列が含まれていても unwrap しない → {"data": "..."} のまま返す
        outer = {"data": b64, "type": "MESSAGE"}
        data = json.dumps(outer).encode("utf-8")
        result = decode_payload_interaction(data)
        # 旧 decode_payload は base64 unwrap するが、interaction mode は unwrap しない
        assert result.get("data") == b64


# ── check_noise_filter_interaction ────────────────────────────────────────────


class TestNoiseFilterInteraction:
    def test_message_correct_space_passes(self):
        event = _make_interaction_event(event_type="MESSAGE")
        ok, reason = check_noise_filter_interaction(event, TARGET_SPACE)
        assert ok is True
        assert reason == ""

    def test_added_to_space_rejected(self):
        event = _make_interaction_event(event_type="ADDED_TO_SPACE", space_in_message=False)
        event["space"] = {"name": TARGET_SPACE}
        ok, reason = check_noise_filter_interaction(event, TARGET_SPACE)
        assert ok is False
        assert "ADDED_TO_SPACE" in reason

    def test_removed_from_space_rejected(self):
        event = _make_interaction_event(event_type="REMOVED_FROM_SPACE", space_in_message=False)
        event["space"] = {"name": TARGET_SPACE}
        ok, reason = check_noise_filter_interaction(event, TARGET_SPACE)
        assert ok is False
        assert "REMOVED_FROM_SPACE" in reason

    def test_card_clicked_rejected(self):
        event = {"type": "CARD_CLICKED", "space": {"name": TARGET_SPACE}}
        ok, reason = check_noise_filter_interaction(event, TARGET_SPACE)
        assert ok is False
        assert "CARD_CLICKED" in reason

    def test_wrong_space_rejected(self):
        """通常 space (singleUserBotDm=False) で wrong-space は拒否"""
        event = _make_interaction_event(event_type="MESSAGE", space_name="spaces/OTHER")
        ok, reason = check_noise_filter_interaction(event, TARGET_SPACE)
        assert ok is False
        assert reason == "wrong_space"

    def test_dm_single_user_bot_dm_passes_with_different_space(self):
        """DM (singleUserBotDm=True) は dedicated space と異なる space.name でも通す"""
        event = _make_interaction_event(
            event_type="MESSAGE",
            space_name="spaces/DM_WITH_BOT_001",
            single_user_bot_dm=True,
        )
        ok, reason = check_noise_filter_interaction(event, TARGET_SPACE)
        assert ok is True
        assert reason == ""

    def test_dm_space_type_direct_message_passes(self):
        """DM (spaceType=DIRECT_MESSAGE) は dedicated space と異なる space.name でも通す"""
        event = _make_interaction_event(
            event_type="MESSAGE",
            space_name="spaces/DM_WITH_BOT_002",
        )
        event["space"]["spaceType"] = "DIRECT_MESSAGE"
        ok, reason = check_noise_filter_interaction(event, TARGET_SPACE)
        assert ok is True
        assert reason == ""

    def test_missing_type_rejected(self):
        ok, reason = check_noise_filter_interaction({}, TARGET_SPACE)
        assert ok is False
        assert reason == "missing_event_type"

    def test_missing_space_rejected(self):
        """type==MESSAGE だが space フィールドがない"""
        event = {"type": "MESSAGE", "message": {"name": "spaces/AAA/messages/001"}}
        ok, reason = check_noise_filter_interaction(event, TARGET_SPACE)
        assert ok is False
        assert reason == "missing_space"

    def test_space_fallback_from_message(self):
        """event['space'] がなくても event['message']['space'] から判定"""
        event = {
            "type": "MESSAGE",
            "message": {
                "name": f"{TARGET_SPACE}/messages/001",
                "space": {"name": TARGET_SPACE},
            },
        }
        ok, reason = check_noise_filter_interaction(event, TARGET_SPACE)
        assert ok is True


# ── process_message_interaction (7 fixture 種) ────────────────────────────────


class TestProcessMessageInteraction:

    # Fixture 1: MESSAGE @mention
    def test_fixture1_mention_accepted(self, tmp_path):
        """@mention メッセージ (スペース) allowlist 通過 → accepted"""
        inbox_path = str(tmp_path / "google_chat_inbox.yaml")
        event = _make_interaction_event(
            event_type="MESSAGE",
            message_name=f"{TARGET_SPACE}/messages/MSG001",
            sender_id="users/115970327619114022410",
            text="@外部入力テスト 出荷お願いします",
            single_user_bot_dm=False,
        )
        msg = _make_pubsub_message_interaction(event)
        dedup = set()

        result = process_message_interaction(msg, TARGET_SPACE, ALLOWLIST, inbox_path, dedup)

        assert result.status == "accepted"
        assert result.should_ack is True
        assert result.appended is True
        assert f"{TARGET_SPACE}/messages/MSG001" in load_inbox_dedups(inbox_path)

        with open(inbox_path, encoding="utf-8") as f:
            data = yaml.safe_load(f)
        entry = data["inbox"][0]
        assert entry["event_type"] == "MESSAGE"
        assert entry["source_channel"] == "google_chat"
        assert "出荷お願いします" in entry["text"]

    # Fixture 2: MESSAGE DM
    def test_fixture2_dm_accepted(self, tmp_path):
        """DM メッセージ (singleUserBotDm=true, dedicated space と別の space.name) allowlist 通過 → accepted
        DM metadata (spaceType / singleUserBotDm) が context に保存されることを確認。"""
        inbox_path = str(tmp_path / "google_chat_inbox.yaml")
        DM_SPACE = "spaces/DM_WITH_BOT_001"  # dedicated space と異なる
        event = _make_interaction_event(
            event_type="MESSAGE",
            message_name=f"{DM_SPACE}/messages/DM001",
            sender_id="users/115970327619114022410",
            text="DM テストメッセージ",
            space_name=DM_SPACE,
            single_user_bot_dm=True,
        )
        event["space"]["spaceType"] = "DIRECT_MESSAGE"  # DM 判定フィールドを明示
        msg = _make_pubsub_message_interaction(event)
        dedup = set()

        result = process_message_interaction(msg, TARGET_SPACE, ALLOWLIST, inbox_path, dedup)

        assert result.status == "accepted"
        assert result.should_ack is True
        assert result.appended is True

        with open(inbox_path, encoding="utf-8") as f:
            data = yaml.safe_load(f)
        entry = data["inbox"][0]
        # DM dedicated space の space_id が保存される
        assert entry["context"]["space_id"] == DM_SPACE
        # DM 判定フィールドが context に保存される
        assert entry["context"]["space_type"] == "DIRECT_MESSAGE"
        assert entry["context"]["single_user_bot_dm"] is True

    # Fixture 3: ADDED_TO_SPACE
    def test_fixture3_added_to_space_ack_only(self, tmp_path):
        """ADDED_TO_SPACE → ノイズフィルタで ack のみ (inbox に追記しない)"""
        inbox_path = str(tmp_path / "google_chat_inbox.yaml")
        event = _make_interaction_event(event_type="ADDED_TO_SPACE", space_in_message=False)
        event["space"] = {"name": TARGET_SPACE}
        msg = _make_pubsub_message_interaction(event)
        dedup = set()

        result = process_message_interaction(msg, TARGET_SPACE, ALLOWLIST, inbox_path, dedup)

        assert result.should_ack is True
        assert result.appended is False
        assert "noise_event_type" in result.status or "ADDED_TO_SPACE" in result.status
        assert not Path(inbox_path).exists()

    # Fixture 4: REMOVED_FROM_SPACE
    def test_fixture4_removed_from_space_ack_only(self, tmp_path):
        """REMOVED_FROM_SPACE → ノイズフィルタで ack のみ (inbox に追記しない)"""
        inbox_path = str(tmp_path / "google_chat_inbox.yaml")
        event = _make_interaction_event(event_type="REMOVED_FROM_SPACE", space_in_message=False)
        event["space"] = {"name": TARGET_SPACE}
        msg = _make_pubsub_message_interaction(event)
        dedup = set()

        result = process_message_interaction(msg, TARGET_SPACE, ALLOWLIST, inbox_path, dedup)

        assert result.should_ack is True
        assert result.appended is False
        assert "REMOVED_FROM_SPACE" in result.status or "noise_event_type" in result.status
        assert not Path(inbox_path).exists()

    # Fixture 5: allowlist 外
    def test_fixture5_not_allowlisted(self, tmp_path):
        """allowlist 外 sender → rejected:sender_not_allowlisted (inbox に rejected=true で残す)"""
        inbox_path = str(tmp_path / "google_chat_inbox.yaml")
        event = _make_interaction_event(
            event_type="MESSAGE",
            message_name=f"{TARGET_SPACE}/messages/NOAUTH001",
            sender_id="users/UNKNOWN_SENDER",
            sender_email="unknown@example.com",
        )
        msg = _make_pubsub_message_interaction(event)
        dedup = set()

        result = process_message_interaction(msg, TARGET_SPACE, ALLOWLIST, inbox_path, dedup)

        assert result.status == "rejected:sender_not_allowlisted"
        assert result.should_ack is True
        # allowlist 拒否でも rejected=true で inbox に追記
        assert result.appended is True
        with open(inbox_path, encoding="utf-8") as f:
            data = yaml.safe_load(f)
        entry = data["inbox"][0]
        assert entry["rejected"] is True
        assert entry["reject_reason"] == "sender_not_allowlisted"

    # Fixture 6: 重複 message_id
    def test_fixture6_duplicate_message_id(self, tmp_path):
        """重複 message_id → rejected:duplicate_message"""
        inbox_path = str(tmp_path / "google_chat_inbox.yaml")
        event = _make_interaction_event(
            event_type="MESSAGE",
            message_name=f"{TARGET_SPACE}/messages/DUP001",
            sender_id="users/115970327619114022410",
        )
        msg = _make_pubsub_message_interaction(event)
        dedup = {f"{TARGET_SPACE}/messages/DUP001"}  # 既に dedup cache に存在

        result = process_message_interaction(msg, TARGET_SPACE, ALLOWLIST, inbox_path, dedup)

        assert result.status == "rejected:duplicate_message"
        assert result.should_ack is True
        assert result.appended is False

    # Fixture 7: 不正 JSON
    def test_fixture7_malformed_json(self, tmp_path):
        """不正 JSON → rejected:malformed_payload (ack は行う)"""
        inbox_path = str(tmp_path / "google_chat_inbox.yaml")
        msg = MagicMock()
        msg.message_id = "pubsub-malformed-001"
        msg.data = b"this is not valid json !!!"
        msg.attributes = {}
        dedup = set()

        result = process_message_interaction(msg, TARGET_SPACE, ALLOWLIST, inbox_path, dedup)

        assert result.status == "rejected:malformed_payload"
        assert result.should_ack is True
        assert not Path(inbox_path).exists()


# ── 旧 CloudEvent 回帰テスト ─────────────────────────────────────────────────


class TestCloudEventRegression:
    """旧 Workspace Events mode (process_message) が interaction mode 追加後も壊れていないことを確認"""

    def test_workspace_events_accepted(self, tmp_path):
        """旧 workspace_events mode で正常 accept"""
        inbox_path = str(tmp_path / "google_chat_inbox.yaml")
        msg = _make_pubsub_message_workspace_events(
            message_id="spaces/AAAAeAy5hcg/messages/WS001",
            sender_name="users/115970327619114022410",
        )
        dedup = set()
        result = process_message(msg, SUBJECT, TYPE_CREATED, ALLOWLIST, inbox_path, dedup)
        assert result.status == "accepted"
        assert result.should_ack is True

    def test_workspace_events_noise_rejected(self, tmp_path):
        """旧 workspace_events mode で ce-type 不一致 → ノイズ拒否"""
        inbox_path = str(tmp_path / "google_chat_inbox.yaml")
        msg = _make_pubsub_message_workspace_events(
            message_id="spaces/AAAAeAy5hcg/messages/WS002",
            ce_type="google.workspace.chat.membership.v1.created",
        )
        dedup = set()
        result = process_message(msg, SUBJECT, TYPE_CREATED, ALLOWLIST, inbox_path, dedup)
        assert result.status == "rejected:unsupported_event_type"
        assert result.should_ack is True

    def test_workspace_events_wrong_subject(self, tmp_path):
        """旧 workspace_events mode で ce-subject 不一致 → 拒否"""
        inbox_path = str(tmp_path / "google_chat_inbox.yaml")
        msg = _make_pubsub_message_workspace_events(
            ce_subject="//chat.googleapis.com/spaces/OTHER",
        )
        dedup = set()
        result = process_message(msg, SUBJECT, TYPE_CREATED, ALLOWLIST, inbox_path, dedup)
        assert result.status == "rejected:wrong_subject"

    def test_workspace_events_duplicate(self, tmp_path):
        """旧 workspace_events mode で重複 → 拒否"""
        inbox_path = str(tmp_path / "google_chat_inbox.yaml")
        msg = _make_pubsub_message_workspace_events(
            message_id="spaces/AAAAeAy5hcg/messages/WS003",
        )
        dedup = {"spaces/AAAAeAy5hcg/messages/WS003"}
        result = process_message(msg, SUBJECT, TYPE_CREATED, ALLOWLIST, inbox_path, dedup)
        assert result.status == "rejected:duplicate_message"


# ── build_inbox_entry_interaction (space/thread fallback) ─────────────────────


class TestBuildInboxEntryInteraction:
    def test_space_from_event_space(self):
        """event['space']['name'] が優先される"""
        event = {
            "type": "MESSAGE",
            "space": {"name": TARGET_SPACE, "type": "ROOM"},
            "eventTime": "2026-06-03T18:00:00Z",
        }
        message_data = {
            "name": f"{TARGET_SPACE}/messages/MSG001",
            "sender": {"name": "users/115970327619114022410", "type": "HUMAN"},
            "text": "テスト",
            "thread": {"name": f"{TARGET_SPACE}/threads/T01"},
            "space": {"name": "spaces/OTHER"},  # event['space'] が優先
        }
        entry = build_inbox_entry_interaction(
            message_id=f"{TARGET_SPACE}/messages/MSG001",
            delivery_id="d001",
            received_at="2026-06-03T18:00:00Z",
            event_time="2026-06-03T18:00:00Z",
            event=event,
            message_data=message_data,
        )
        assert entry["context"]["space_id"] == TARGET_SPACE

    def test_space_fallback_to_message_space(self):
        """event['space'] がなければ message_data['space'] にフォールバック"""
        event = {
            "type": "MESSAGE",
            "eventTime": "2026-06-03T18:00:00Z",
        }
        message_data = {
            "name": f"{TARGET_SPACE}/messages/MSG001",
            "sender": {"name": "users/115970327619114022410"},
            "text": "テスト",
            "space": {"name": TARGET_SPACE},
            "thread": {"name": f"{TARGET_SPACE}/threads/T01"},
        }
        entry = build_inbox_entry_interaction(
            message_id=f"{TARGET_SPACE}/messages/MSG001",
            delivery_id="d001",
            received_at="2026-06-03T18:00:00Z",
            event_time="2026-06-03T18:00:00Z",
            event=event,
            message_data=message_data,
        )
        assert entry["context"]["space_id"] == TARGET_SPACE

    def test_event_type_from_event(self):
        """event_type は event['type'] の値"""
        event = {"type": "MESSAGE", "space": {"name": TARGET_SPACE}, "eventTime": "2026-06-03T18:00:00Z"}
        message_data = {
            "name": f"{TARGET_SPACE}/messages/MSG001",
            "sender": {"name": "users/001"},
            "text": "test",
        }
        entry = build_inbox_entry_interaction(
            message_id=f"{TARGET_SPACE}/messages/MSG001",
            delivery_id="d001",
            received_at="2026-06-03T18:00:00Z",
            event_time="2026-06-03T18:00:00Z",
            event=event,
            message_data=message_data,
        )
        assert entry["event_type"] == "MESSAGE"

    def test_rejected_entry(self):
        """rejected=True のエントリが正しく生成される"""
        event = {"type": "MESSAGE", "space": {"name": TARGET_SPACE}, "eventTime": "2026-06-03T18:00:00Z"}
        message_data = {
            "name": f"{TARGET_SPACE}/messages/MSG001",
            "sender": {"name": "users/UNKNOWN"},
        }
        entry = build_inbox_entry_interaction(
            message_id=f"{TARGET_SPACE}/messages/MSG001",
            delivery_id="d001",
            received_at="2026-06-03T18:00:00Z",
            event_time="2026-06-03T18:00:00Z",
            event=event,
            message_data=message_data,
            rejected=True,
            reject_reason="sender_not_allowlisted",
        )
        assert entry["rejected"] is True
        assert entry["reject_reason"] == "sender_not_allowlisted"
        assert entry["processed"] is True

    def test_dm_metadata_saved_in_context(self):
        """DM event の spaceType / singleUserBotDm が context に保存される"""
        DM_SPACE = "spaces/DM_DEDICATED_001"
        event = {
            "type": "MESSAGE",
            "space": {
                "name": DM_SPACE,
                "spaceType": "DIRECT_MESSAGE",
                "singleUserBotDm": True,
            },
            "eventTime": "2026-06-03T18:00:00Z",
        }
        message_data = {
            "name": f"{DM_SPACE}/messages/DM001",
            "sender": {"name": "users/115970327619114022410", "type": "HUMAN"},
            "text": "DM テスト",
            "thread": {"name": f"{DM_SPACE}/threads/T01"},
            "space": {"name": DM_SPACE},
        }
        entry = build_inbox_entry_interaction(
            message_id=f"{DM_SPACE}/messages/DM001",
            delivery_id="d001",
            received_at="2026-06-03T18:00:00Z",
            event_time="2026-06-03T18:00:00Z",
            event=event,
            message_data=message_data,
        )
        assert entry["context"]["space_id"] == DM_SPACE
        assert entry["context"]["space_type"] == "DIRECT_MESSAGE"
        assert entry["context"]["single_user_bot_dm"] is True

    def test_non_dm_single_user_bot_dm_is_none(self):
        """通常 space では single_user_bot_dm が None"""
        event = {
            "type": "MESSAGE",
            "space": {
                "name": TARGET_SPACE,
                "spaceType": "SPACE",
                "singleUserBotDm": False,
            },
            "eventTime": "2026-06-03T18:00:00Z",
        }
        message_data = {
            "name": f"{TARGET_SPACE}/messages/MSG001",
            "sender": {"name": "users/115970327619114022410", "type": "HUMAN"},
            "text": "テスト",
            "thread": {"name": f"{TARGET_SPACE}/threads/T01"},
            "space": {"name": TARGET_SPACE},
        }
        entry = build_inbox_entry_interaction(
            message_id=f"{TARGET_SPACE}/messages/MSG001",
            delivery_id="d001",
            received_at="2026-06-03T18:00:00Z",
            event_time="2026-06-03T18:00:00Z",
            event=event,
            message_data=message_data,
        )
        assert entry["context"]["space_id"] == TARGET_SPACE
        assert entry["context"]["space_type"] == "SPACE"
        assert entry["context"]["single_user_bot_dm"] is None


# ── 2 mode 独立性確認 ─────────────────────────────────────────────────────────


class TestModeSeparation:
    """interaction mode と workspace_events mode が独立して動作することを確認"""

    def test_interaction_message_rejected_by_workspace_events_noise_filter(self, tmp_path):
        """interaction event JSON は workspace_events noise filter で拒否される (ce-type なし)"""
        inbox_path = str(tmp_path / "inbox.yaml")
        event = _make_interaction_event(event_type="MESSAGE")
        data_bytes = json.dumps(event, ensure_ascii=False).encode("utf-8")

        msg = MagicMock()
        msg.message_id = "pubsub-001"
        msg.data = data_bytes
        msg.attributes = {}  # ce-subject / ce-type なし

        result = process_message(msg, SUBJECT, TYPE_CREATED, ALLOWLIST, inbox_path, set())
        # ce-subject / ce-type が欠落 → missing_attributes で拒否
        assert result.status == "rejected:missing_attributes"

    def test_workspace_events_payload_rejected_by_interaction_noise_filter(self, tmp_path):
        """旧 CloudEvent payload は interaction noise filter で拒否される (type フィールドなし)"""
        inbox_path = str(tmp_path / "inbox.yaml")
        msg = _make_pubsub_message_workspace_events()
        # CloudEvent payload に "type" フィールドなし → missing_event_type
        result = process_message_interaction(msg, TARGET_SPACE, ALLOWLIST, inbox_path, set())
        assert result.status == "rejected:missing_event_type"
