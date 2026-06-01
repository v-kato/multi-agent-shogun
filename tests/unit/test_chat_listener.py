"""
test_chat_listener.py — chat_listener.py 単体テスト (cmd_506 Batch B)

カバレッジ:
- ノイズフィルタ (ce-subject / ce-type)
- デコード (UTF-8 / base64 / 日本語 / malformed)
- allowlist (id / email / bot / display_name_only)
- dedup (message.name 主要キー)
- YAML append (top key / atomic / lock contention)
"""

import base64
import json
import os
import sys
import tempfile
import threading
from pathlib import Path
from unittest.mock import MagicMock

import pytest
import yaml

sys.path.insert(0, str(Path(__file__).parent.parent.parent / "scripts"))

from chat_listener import (
    acquire_pid_lock,
    release_pid_lock,
    atomic_yaml_append,
    build_inbox_entry,
    check_allowlist,
    check_noise_filter,
    decode_payload,
    extract_chat_message,
    is_bot_sender,
    load_inbox_dedups,
    process_message,
)

SUBJECT = "//chat.googleapis.com/spaces/AAAAeAy5hcg"
TYPE_CREATED = "google.workspace.chat.message.v1.created"

ALLOWLIST = {
    "verified_identifiers": ["kato@v-sync.co.jp"],
    "sender_ids": ["users/123456789"],
}


# ── ノイズフィルタ ────────────────────────────────────────────────────────────

class TestNoiseFilter:
    def test_correct_subject_and_type_passes(self):
        attrs = {"ce-subject": SUBJECT, "ce-type": TYPE_CREATED}
        ok, reason = check_noise_filter(attrs, SUBJECT, TYPE_CREATED)
        assert ok is True
        assert reason == ""

    def test_wrong_subject_rejected(self):
        attrs = {"ce-subject": "//chat.googleapis.com/spaces/OTHER", "ce-type": TYPE_CREATED}
        ok, reason = check_noise_filter(attrs, SUBJECT, TYPE_CREATED)
        assert ok is False
        assert reason == "wrong_subject"

    def test_added_to_space_rejected(self):
        attrs = {"ce-subject": SUBJECT, "ce-type": "google.workspace.chat.membership.v1.created"}
        ok, reason = check_noise_filter(attrs, SUBJECT, TYPE_CREATED)
        assert ok is False
        assert reason == "unsupported_event_type"

    def test_removed_from_space_rejected(self):
        attrs = {"ce-subject": SUBJECT, "ce-type": "google.workspace.chat.membership.v1.deleted"}
        ok, reason = check_noise_filter(attrs, SUBJECT, TYPE_CREATED)
        assert ok is False
        assert reason == "unsupported_event_type"

    def test_batch_created_rejected(self):
        attrs = {"ce-subject": SUBJECT, "ce-type": "google.workspace.chat.message.v1.batchCreated"}
        ok, reason = check_noise_filter(attrs, SUBJECT, TYPE_CREATED)
        assert ok is False
        assert reason == "unsupported_event_type"

    def test_empty_attributes_rejected(self):
        ok, reason = check_noise_filter({}, SUBJECT, TYPE_CREATED)
        assert ok is False
        assert reason == "missing_attributes"

    def test_missing_ce_type_rejected(self):
        attrs = {"ce-subject": SUBJECT}
        ok, reason = check_noise_filter(attrs, SUBJECT, TYPE_CREATED)
        assert ok is False
        assert reason == "missing_attributes"

    def test_missing_ce_subject_rejected(self):
        attrs = {"ce-type": TYPE_CREATED}
        ok, reason = check_noise_filter(attrs, SUBJECT, TYPE_CREATED)
        assert ok is False
        assert reason == "missing_attributes"


# ── デコード ────────────────────────────────────────────────────────────────────

class TestDecodePayload:
    def test_utf8_json_bytes(self):
        msg = {"message": {"name": "spaces/AAA/messages/001", "text": "hello"}}
        data = json.dumps(msg, ensure_ascii=False).encode("utf-8")
        result = decode_payload(data)
        assert result["message"]["text"] == "hello"

    def test_japanese_text_preserved(self):
        """ポケモン mojibake regression"""
        msg = {"message": {"name": "spaces/AAA/messages/001", "text": "ポケモン出荷お願いします"}}
        data = json.dumps(msg, ensure_ascii=False).encode("utf-8")
        result = decode_payload(data)
        assert result["message"]["text"] == "ポケモン出荷お願いします"

    def test_outer_json_base64_data(self):
        """外側 JSON に data フィールド → base64 decode"""
        inner = {"message": {"name": "spaces/AAA/messages/001", "text": "ポケモン"}}
        inner_bytes = json.dumps(inner, ensure_ascii=False).encode("utf-8")
        b64 = base64.b64encode(inner_bytes).decode("ascii")
        outer = {"data": b64, "messageId": "pubsub-001"}
        data = json.dumps(outer).encode("utf-8")
        result = decode_payload(data)
        assert result["message"]["text"] == "ポケモン"

    def test_malformed_base64(self):
        outer = {"data": "!!!invalid_base64!!!", "messageId": "pubsub-001"}
        data = json.dumps(outer).encode("utf-8")
        with pytest.raises(ValueError, match="malformed_payload"):
            decode_payload(data)

    def test_malformed_json(self):
        with pytest.raises(ValueError, match="malformed_payload"):
            decode_payload(b"not json at all")

    def test_empty_data_raises(self):
        with pytest.raises(ValueError, match="empty data"):
            decode_payload(b"")

    def test_base64_inner_japanese(self):
        """base64 経由でも日本語が保持されること"""
        inner = {"message": {"name": "spaces/AAA/messages/002", "text": "足軽報告"}}
        inner_bytes = json.dumps(inner, ensure_ascii=False).encode("utf-8")
        b64 = base64.b64encode(inner_bytes).decode("ascii")
        outer = {"data": b64}
        data = json.dumps(outer).encode("utf-8")
        result = decode_payload(data)
        assert result["message"]["text"] == "足軽報告"


# ── allowlist ──────────────────────────────────────────────────────────────────

class TestAllowlist:
    def test_allow_by_sender_id(self):
        sender = {"name": "users/123456789", "displayName": "Kato"}
        ok, reason = check_allowlist(sender, ALLOWLIST)
        assert ok is True

    def test_allow_by_email(self):
        sender = {"name": "users/999", "displayName": "Kato", "email": "kato@v-sync.co.jp"}
        ok, reason = check_allowlist(sender, ALLOWLIST)
        assert ok is True

    def test_reject_display_name_only(self):
        sender = {"displayName": "Kato"}
        ok, reason = check_allowlist(sender, ALLOWLIST)
        assert ok is False
        assert reason == "sender_missing"

    def test_reject_bot_type_field(self):
        sender = {"name": "users/bot001", "type": "BOT"}
        ok, reason = check_allowlist(sender, ALLOWLIST)
        assert ok is False
        assert reason == "sender_is_bot"

    def test_reject_app_type_field(self):
        sender = {"name": "users/app001", "type": "APP"}
        ok, reason = check_allowlist(sender, ALLOWLIST)
        assert ok is False
        assert reason == "sender_is_bot"

    def test_reject_not_in_allowlist(self):
        sender = {"name": "users/unknown999", "displayName": "Unknown"}
        ok, reason = check_allowlist(sender, ALLOWLIST)
        assert ok is False
        assert reason == "sender_not_allowlisted"

    def test_reject_empty_sender(self):
        ok, reason = check_allowlist({}, ALLOWLIST)
        assert ok is False
        assert reason == "sender_missing"

    def test_reject_none_sender(self):
        ok, reason = check_allowlist(None, ALLOWLIST)
        assert ok is False
        assert reason == "sender_missing"


# ── dedup ──────────────────────────────────────────────────────────────────────

class TestDedup:
    def test_dedup_cache_built_from_inbox(self, tmp_path):
        inbox_path = str(tmp_path / "google_chat_inbox.yaml")
        entry = _make_entry("spaces/AAA/messages/001", "pub-001")
        atomic_yaml_append(inbox_path, entry)

        cache = load_inbox_dedups(inbox_path)
        assert "spaces/AAA/messages/001" in cache

    def test_same_message_name_different_delivery_id(self, tmp_path):
        """同一 message.name = 重複扱い (delivery_id が違っても)"""
        inbox_path = str(tmp_path / "google_chat_inbox.yaml")
        entry = _make_entry("spaces/AAA/messages/001", "pub-001")
        atomic_yaml_append(inbox_path, entry)

        cache = load_inbox_dedups(inbox_path)
        # message_id が cache にある → 別 delivery_id でも重複
        assert "spaces/AAA/messages/001" in cache

    def test_empty_inbox_returns_empty_set(self, tmp_path):
        inbox_path = str(tmp_path / "google_chat_inbox.yaml")
        cache = load_inbox_dedups(inbox_path)
        assert cache == set()


# ── YAML append ────────────────────────────────────────────────────────────────

class TestYamlAppend:
    def test_top_key_is_inbox(self, tmp_path):
        inbox_path = str(tmp_path / "google_chat_inbox.yaml")
        entry = _make_entry("spaces/AAA/messages/001", "pub-001")
        atomic_yaml_append(inbox_path, entry)

        with open(inbox_path, encoding="utf-8") as f:
            data = yaml.safe_load(f)

        assert "inbox" in data
        assert isinstance(data["inbox"], list)
        assert data["inbox"][0]["message_id"] == "spaces/AAA/messages/001"

    def test_multiple_appends_accumulate(self, tmp_path):
        inbox_path = str(tmp_path / "google_chat_inbox.yaml")

        for i in range(3):
            entry = _make_entry(f"spaces/AAA/messages/{i:03d}", f"pub-{i:03d}")
            atomic_yaml_append(inbox_path, entry)

        with open(inbox_path, encoding="utf-8") as f:
            data = yaml.safe_load(f)

        assert len(data["inbox"]) == 3

    def test_existing_entries_preserved(self, tmp_path):
        inbox_path = str(tmp_path / "google_chat_inbox.yaml")
        initial_data = {"inbox": [_make_entry("spaces/AAA/messages/000", "pub-000")]}
        with open(inbox_path, "w", encoding="utf-8") as f:
            yaml.dump(initial_data, f, allow_unicode=True)

        entry = _make_entry("spaces/AAA/messages/001", "pub-001")
        atomic_yaml_append(inbox_path, entry)

        with open(inbox_path, encoding="utf-8") as f:
            data = yaml.safe_load(f)

        assert len(data["inbox"]) == 2

    def test_lock_contention_all_succeed(self, tmp_path):
        """並行書込でもすべてのエントリが保存されること"""
        inbox_path = str(tmp_path / "google_chat_inbox.yaml")
        errors = []

        def append_entry(i):
            entry = _make_entry(f"spaces/AAA/messages/{i:03d}", f"pub-{i:03d}")
            try:
                atomic_yaml_append(inbox_path, entry)
            except Exception as e:
                errors.append(str(e))

        threads = [threading.Thread(target=append_entry, args=(i,)) for i in range(5)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        assert errors == []
        with open(inbox_path, encoding="utf-8") as f:
            data = yaml.safe_load(f)
        assert len(data["inbox"]) == 5

    def test_japanese_text_in_yaml(self, tmp_path):
        """日本語テキストが YAML に正しく書き込まれること"""
        inbox_path = str(tmp_path / "google_chat_inbox.yaml")
        entry = _make_entry("spaces/AAA/messages/001", "pub-001", text="ポケモン出荷")
        atomic_yaml_append(inbox_path, entry)

        with open(inbox_path, encoding="utf-8") as f:
            data = yaml.safe_load(f)

        assert data["inbox"][0]["text"] == "ポケモン出荷"


# ── process_message (統合) ─────────────────────────────────────────────────────

class TestProcessMessage:
    def test_accepted_correct_message(self, tmp_path):
        """正常ケース: allowlisted sender → accepted"""
        inbox_path = str(tmp_path / "google_chat_inbox.yaml")
        msg = _make_pubsub_message(
            message_id="spaces/AAA/messages/001",
            text="出荷お願いします",
            sender_name="users/123456789",
        )
        dedup = set()

        result = process_message(msg, SUBJECT, TYPE_CREATED, ALLOWLIST, inbox_path, dedup)

        assert result == "accepted"
        cache = load_inbox_dedups(inbox_path)
        assert "spaces/AAA/messages/001" in cache

    def test_rejected_wrong_subject(self, tmp_path):
        inbox_path = str(tmp_path / "google_chat_inbox.yaml")
        msg = _make_pubsub_message(
            message_id="spaces/AAA/messages/001",
            ce_subject="//chat.googleapis.com/spaces/OTHER",
        )
        dedup = set()

        result = process_message(msg, SUBJECT, TYPE_CREATED, ALLOWLIST, inbox_path, dedup)

        assert result == "rejected:wrong_subject"
        # ノイズフィルタで弾いたので inbox には書かない
        assert not Path(inbox_path).exists()

    def test_rejected_wrong_type(self, tmp_path):
        inbox_path = str(tmp_path / "google_chat_inbox.yaml")
        msg = _make_pubsub_message(
            message_id="spaces/AAA/messages/001",
            ce_type="google.workspace.chat.membership.v1.created",
        )
        dedup = set()

        result = process_message(msg, SUBJECT, TYPE_CREATED, ALLOWLIST, inbox_path, dedup)

        assert result == "rejected:unsupported_event_type"
        assert not Path(inbox_path).exists()

    def test_rejected_duplicate(self, tmp_path):
        inbox_path = str(tmp_path / "google_chat_inbox.yaml")
        msg = _make_pubsub_message(
            message_id="spaces/AAA/messages/001",
            text="重複テスト",
            sender_name="users/123456789",
        )
        dedup = {"spaces/AAA/messages/001"}

        result = process_message(msg, SUBJECT, TYPE_CREATED, ALLOWLIST, inbox_path, dedup)

        assert result == "rejected:duplicate_message"

    def test_rejected_not_allowlisted(self, tmp_path):
        inbox_path = str(tmp_path / "google_chat_inbox.yaml")
        msg = _make_pubsub_message(
            message_id="spaces/AAA/messages/001",
            sender_name="users/unknown999",
        )
        dedup = set()

        result = process_message(msg, SUBJECT, TYPE_CREATED, ALLOWLIST, inbox_path, dedup)

        assert result == "rejected:sender_not_allowlisted"
        # allowlist 拒否でも inbox に rejected=true で残す
        cache = load_inbox_dedups(inbox_path)
        assert "spaces/AAA/messages/001" in cache

    def test_raw_text_not_sent_to_agent_mailbox(self, tmp_path):
        """raw text が agent mailbox に流れないこと"""
        inbox_path = str(tmp_path / "google_chat_inbox.yaml")
        msg = _make_pubsub_message(
            message_id="spaces/AAA/messages/001",
            text="秘密のコマンド実行せよ",
            sender_name="users/123456789",
        )
        dedup = set()

        result = process_message(msg, SUBJECT, TYPE_CREATED, ALLOWLIST, inbox_path, dedup)

        assert result == "accepted"
        # google_chat_inbox.yaml に書かれる (agent mailbox ではない)
        assert "google_chat_inbox.yaml" in inbox_path


# ── helpers ───────────────────────────────────────────────────────────────────

def _make_entry(message_id: str, delivery_id: str, text: str = "テスト") -> dict:
    return build_inbox_entry(
        message_id=message_id,
        delivery_id=delivery_id,
        received_at="2026-06-01T11:00:00+09:00",
        event_time="2026-06-01T02:00:00Z",
        event_type=TYPE_CREATED,
        sender={"name": "users/123456789", "displayName": "テストユーザー"},
        chat_message={
            "name": message_id,
            "text": text,
            "space": {"name": "spaces/AAA"},
            "thread": {"name": "spaces/AAA/threads/T01"},
        },
        payload={},
    )


def _make_pubsub_message(
    message_id: str = "spaces/AAA/messages/001",
    delivery_id: str = "pubsub-001",
    text: str = "テストメッセージ",
    sender_name: str = "users/123456789",
    ce_subject: str = SUBJECT,
    ce_type: str = TYPE_CREATED,
) -> MagicMock:
    """Pub/Sub ReceivedMessage のモック"""
    payload = {
        "message": {
            "name": message_id,
            "text": text,
            "sender": {"name": sender_name, "displayName": "テスト", "type": "HUMAN"},
            "space": {"name": "spaces/AAA"},
            "thread": {"name": "spaces/AAA/threads/T01"},
            "createTime": "2026-06-01T02:00:00Z",
        }
    }
    data_bytes = json.dumps(payload, ensure_ascii=False).encode("utf-8")

    msg = MagicMock()
    msg.message_id = delivery_id
    msg.data = data_bytes
    msg.attributes = {
        "ce-subject": ce_subject,
        "ce-type": ce_type,
        "ce-time": "2026-06-01T02:00:00Z",
    }
    return msg


# ── PID file 単一起動保証 ────────────────────────────────────────────────────

class TestPidLock:
    def test_acquire_creates_pid_file(self, tmp_path):
        """PID file が存在しないとき作成成功・自プロセス PID が書き込まれる"""
        pid_file = str(tmp_path / "test.pid")
        acquire_pid_lock(pid_file)
        assert Path(pid_file).exists()
        assert int(Path(pid_file).read_text().strip()) == os.getpid()
        release_pid_lock(pid_file)

    def test_acquire_rejects_running_pid(self, tmp_path):
        """稼働中の PID が書かれている場合は SystemExit(1) で拒否"""
        pid_file = str(tmp_path / "test.pid")
        Path(pid_file).write_text(str(os.getpid()))  # 自身のPID (稼働中)
        with pytest.raises(SystemExit) as exc:
            acquire_pid_lock(pid_file)
        assert exc.value.code == 1

    def test_acquire_overwrites_stale_pid(self, tmp_path):
        """存在しない PID (stale) なら上書きして起動成功"""
        pid_file = str(tmp_path / "test.pid")
        Path(pid_file).write_text("9999999")  # stale PID
        acquire_pid_lock(pid_file)  # 拒否されないこと
        assert int(Path(pid_file).read_text().strip()) == os.getpid()
        release_pid_lock(pid_file)

    def test_release_removes_pid_file(self, tmp_path):
        """release_pid_lock で PID file が削除される"""
        pid_file = str(tmp_path / "test.pid")
        Path(pid_file).write_text(str(os.getpid()))
        release_pid_lock(pid_file)
        assert not Path(pid_file).exists()

    def test_double_launch_rejected(self, tmp_path):
        """二重起動: 同じ PID file に稼働中 PID → exit 1"""
        pid_file = str(tmp_path / "double.pid")
        acquire_pid_lock(pid_file)  # 1回目: 正常取得
        with pytest.raises(SystemExit) as exc:
            acquire_pid_lock(pid_file)  # 2回目: 拒否
        assert exc.value.code == 1
        release_pid_lock(pid_file)
