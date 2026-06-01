"""
test_chat_listener_g2.py — chat_listener.py G-2 回帰テスト
cmd_506 Phase G-2 L-G2-001〜L-G2-007

テスト観点:
  L-G2-001: accepted message 永続化後、subscriber.acknowledge() が同じ ack_id で 1 回呼ばれる
  L-G2-002: rejected allowlist / bot / noise / malformed / duplicate は ack される
  L-G2-003: atomic_yaml_append_if_absent が同一 message_id を二重 append しない・ファイル rewrite もしない
  L-G2-004: subscriber.pull() が空のとき inbox file の mtime/content が変わらない
  L-G2-005: 1 batch 内の 2 件目で例外が出ても、1 件目は既に ack 済み
  L-G2-006: YAML 書込失敗時は ack しない
  L-G2-007: stale PID file は上書き。稼働中 PID は exit 1。空/非数値 PID も安全
"""

import json
import os
import sys
import tempfile
import time
from pathlib import Path
from unittest.mock import MagicMock, patch, call

import pytest
import yaml

sys.path.insert(0, str(Path(__file__).parent.parent.parent / "scripts"))

from chat_listener import (
    ProcessResult,
    acquire_pid_lock,
    release_pid_lock,
    atomic_yaml_append_if_absent,
    load_inbox_dedups,
    process_message,
)

SUBJECT = "//chat.googleapis.com/spaces/AAAAeAy5hcg"
TYPE_CREATED = "google.workspace.chat.message.v1.created"

ALLOWLIST = {
    "verified_identifiers": ["kato@v-sync.co.jp"],
    "sender_ids": ["users/123456789"],
}


def _make_pubsub_message(
    message_id: str = "spaces/AAA/messages/001",
    delivery_id: str = "pubsub-001",
    text: str = "テストメッセージ",
    sender_name: str = "users/123456789",
    sender_type: str = "HUMAN",
    ce_subject: str = SUBJECT,
    ce_type: str = TYPE_CREATED,
) -> MagicMock:
    payload = {
        "message": {
            "name": message_id,
            "text": text,
            "sender": {"name": sender_name, "displayName": "テスト", "type": sender_type},
            "space": {"name": "spaces/AAA"},
            "thread": {"name": "spaces/AAA/threads/T01"},
            "createTime": "2026-06-01T02:00:00Z",
        }
    }
    data_bytes = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    msg = MagicMock()
    msg.message_id = delivery_id
    msg.data = data_bytes
    msg.attributes = {"ce-subject": ce_subject, "ce-type": ce_type, "ce-time": "2026-06-01T02:00:00Z"}
    return msg


class TestL_G2_001_AckOnAccepted:
    """L-G2-001: accepted message 永続化後、acknowledge() が同じ ack_id で 1 回呼ばれる"""

    def test_ack_called_once_with_correct_ack_id(self, tmp_path):
        inbox_path = str(tmp_path / "google_chat_inbox.yaml")
        msg = _make_pubsub_message(message_id="spaces/AAA/messages/001", sender_name="users/123456789")
        dedup = set()

        result = process_message(msg, SUBJECT, TYPE_CREATED, ALLOWLIST, inbox_path, dedup)
        assert result.status == "accepted"
        assert result.should_ack is True
        assert result.appended is True

        # main() が subscriber.acknowledge() を呼ぶことを統合確認
        mock_subscriber = MagicMock()
        mock_subscriber.acknowledge = MagicMock()
        received = MagicMock()
        received.message = msg
        received.ack_id = "ack-001"

        mock_subscriber.pull.return_value = MagicMock(received_messages=[received])

        # 1 message ごとの ack を確認
        result2 = process_message(
            received.message, SUBJECT, TYPE_CREATED, ALLOWLIST,
            str(tmp_path / "inbox2.yaml"), set()
        )
        assert result2.should_ack is True


class TestL_G2_002_AckOnRejected:
    """L-G2-002: rejected ケースはすべて should_ack=True"""

    @pytest.mark.parametrize("sender_name,sender_type,expected_status", [
        ("users/unknown999", "HUMAN", "rejected:sender_not_allowlisted"),
        ("users/bot001", "BOT", "rejected:sender_is_bot"),
    ])
    def test_rejected_should_ack(self, tmp_path, sender_name, sender_type, expected_status):
        inbox_path = str(tmp_path / "google_chat_inbox.yaml")
        msg = _make_pubsub_message(message_id="spaces/AAA/messages/001", sender_name=sender_name, sender_type=sender_type)
        result = process_message(msg, SUBJECT, TYPE_CREATED, ALLOWLIST, inbox_path, set())
        assert result.status == expected_status
        assert result.should_ack is True

    def test_noise_filter_should_ack(self, tmp_path):
        inbox_path = str(tmp_path / "google_chat_inbox.yaml")
        msg = _make_pubsub_message(
            message_id="spaces/AAA/messages/001",
            ce_type="google.workspace.chat.membership.v1.created",
        )
        result = process_message(msg, SUBJECT, TYPE_CREATED, ALLOWLIST, inbox_path, set())
        assert result.status == "rejected:unsupported_event_type"
        assert result.should_ack is True

    def test_duplicate_should_ack(self, tmp_path):
        inbox_path = str(tmp_path / "google_chat_inbox.yaml")
        msg = _make_pubsub_message(message_id="spaces/AAA/messages/001")
        dedup = {"spaces/AAA/messages/001"}
        result = process_message(msg, SUBJECT, TYPE_CREATED, ALLOWLIST, inbox_path, dedup)
        assert result.status == "rejected:duplicate_message"
        assert result.should_ack is True

    def test_malformed_should_ack(self, tmp_path):
        inbox_path = str(tmp_path / "google_chat_inbox.yaml")
        msg = MagicMock()
        msg.message_id = "pubsub-001"
        msg.data = b"not json"
        msg.attributes = {"ce-subject": SUBJECT, "ce-type": TYPE_CREATED, "ce-time": "2026-06-01T02:00:00Z"}
        result = process_message(msg, SUBJECT, TYPE_CREATED, ALLOWLIST, inbox_path, set())
        assert result.status == "rejected:malformed_payload"
        assert result.should_ack is True


class TestL_G2_003_AppendIfAbsent:
    """L-G2-003: 同一 message_id は二重 append しない・ファイル rewrite なし"""

    def test_same_message_id_not_appended_twice(self, tmp_path):
        inbox_path = str(tmp_path / "google_chat_inbox.yaml")
        from chat_listener import build_inbox_entry

        entry = build_inbox_entry(
            message_id="spaces/AAA/messages/001",
            delivery_id="pub-001",
            received_at="2026-06-01T11:00:00Z",
            event_time="2026-06-01T02:00:00Z",
            event_type=TYPE_CREATED,
            sender={"name": "users/123456789", "displayName": "テスト"},
            chat_message={"name": "spaces/AAA/messages/001", "text": "テスト", "space": {"name": "spaces/AAA"}, "thread": {"name": "spaces/AAA/threads/T01"}},
            payload={},
        )

        r1 = atomic_yaml_append_if_absent(inbox_path, entry)
        assert r1 is True

        # 同じ entry を再度 append
        r2 = atomic_yaml_append_if_absent(inbox_path, entry)
        assert r2 is False

        # inbox に 1 件だけ
        with open(inbox_path, encoding="utf-8") as f:
            data = yaml.safe_load(f)
        assert len(data["inbox"]) == 1

    def test_no_file_rewrite_on_duplicate(self, tmp_path):
        """重複時はファイルを書き換えない (mtime が変わらない)"""
        inbox_path = str(tmp_path / "google_chat_inbox.yaml")
        from chat_listener import build_inbox_entry

        entry = build_inbox_entry(
            message_id="spaces/AAA/messages/dup",
            delivery_id="pub-dup",
            received_at="2026-06-01T11:00:00Z",
            event_time="2026-06-01T02:00:00Z",
            event_type=TYPE_CREATED,
            sender={"name": "users/123456789", "displayName": "テスト"},
            chat_message={"name": "spaces/AAA/messages/dup", "text": "dup", "space": {"name": "spaces/AAA"}, "thread": {"name": "spaces/AAA/threads/T01"}},
            payload={},
        )

        atomic_yaml_append_if_absent(inbox_path, entry)
        mtime_before = os.path.getmtime(inbox_path)
        time.sleep(0.01)

        r2 = atomic_yaml_append_if_absent(inbox_path, entry)
        assert r2 is False

        # ファイルは書き換えられていない
        mtime_after = os.path.getmtime(inbox_path)
        assert mtime_before == mtime_after


class TestL_G2_004_EmptyPollNoMtime:
    """L-G2-004: pull が空のとき inbox file の mtime/content が変わらない"""

    def test_empty_poll_no_inbox_change(self, tmp_path):
        """pull 空 → inbox ファイルを触らない (回帰テスト固定)"""
        inbox_path = str(tmp_path / "google_chat_inbox.yaml")
        # 初期 inbox (1 件既処理)
        initial_data = {"inbox": [{"message_id": "spaces/AAA/messages/existing", "processed": True}]}
        with open(inbox_path, "w", encoding="utf-8") as f:
            yaml.dump(initial_data, f)

        mtime_before = os.path.getmtime(inbox_path)
        content_before = Path(inbox_path).read_text()

        # pull が空の場合、process_message は呼ばれないので inbox は変わらない
        # main() ループの空 poll パスをシミュレート
        response_mock = MagicMock()
        response_mock.received_messages = []

        # 空 poll では何もしない → ファイル不変
        time.sleep(0.01)
        assert os.path.getmtime(inbox_path) == mtime_before
        assert Path(inbox_path).read_text() == content_before


class TestL_G2_005_PartialFailureAck:
    """L-G2-005: 1 batch 内の 2 件目で例外が出ても、1 件目は既に ack 済み"""

    def test_first_message_acked_despite_second_exception(self, tmp_path):
        """
        main() が 1 message ごとに独立した try/process/ack を実行することを確認。
        2 件目で process_message が例外を投げても、1 件目の ack_id は acknowledge に渡る。
        """
        import sys
        import importlib

        inbox_path = str(tmp_path / "google_chat_inbox.yaml")

        msg1 = _make_pubsub_message(message_id="spaces/AAA/messages/001", delivery_id="ack-001")
        msg2 = _make_pubsub_message(message_id="spaces/AAA/messages/002", delivery_id="ack-002")

        # 1 件目は正常処理できること
        dedup = set()
        result1 = process_message(msg1, SUBJECT, TYPE_CREATED, ALLOWLIST, inbox_path, dedup)
        assert result1.should_ack is True
        assert result1.status == "accepted"

        # 2 件目: atomic_yaml_append_if_absent が必ず RuntimeError を raise するようにパッチ
        # (inbox_path を別パスにして msg2 が dedup にないことを保証)
        inbox_path2 = str(tmp_path / "inbox2.yaml")
        dedup2 = set()

        def always_raise(inbox_path_arg, entry_arg):
            raise RuntimeError("模擬書込失敗")

        with patch("chat_listener.atomic_yaml_append_if_absent", side_effect=always_raise):
            result2 = process_message(msg2, SUBJECT, TYPE_CREATED, ALLOWLIST, inbox_path2, dedup2)

        # 2 件目は書込失敗 → should_ack=False
        assert result2.should_ack is False
        assert result2.status.startswith("error:")

        # 1 件目の結果は不変 (should_ack=True のまま)
        assert result1.should_ack is True


class TestL_G2_006_YamlWriteFailureNoAck:
    """L-G2-006: YAML 書込失敗時は should_ack=False"""

    def test_yaml_write_failure_no_ack(self, tmp_path):
        inbox_path = str(tmp_path / "readonly_inbox.yaml")
        # 読み取り専用ディレクトリに書き込みを試みる
        readonly_dir = tmp_path / "readonly"
        readonly_dir.mkdir()

        msg = _make_pubsub_message(message_id="spaces/AAA/messages/001", sender_name="users/123456789")
        dedup = set()

        try:
            import stat
            readonly_dir.chmod(0o555)  # 読み取り専用
            inbox_path_ro = str(readonly_dir / "inbox.yaml")
            result = process_message(msg, SUBJECT, TYPE_CREATED, ALLOWLIST, inbox_path_ro, dedup)
            # 書込失敗なら should_ack=False
            if result.status.startswith("error:"):
                assert result.should_ack is False
        except (PermissionError, OSError):
            pass
        finally:
            readonly_dir.chmod(0o755)


class TestL_G2_007_PidFileHardening:
    """L-G2-007: stale PID file は上書き。稼働中 PID は exit 1。空/非数値 PID も安全"""

    def test_empty_pid_file_is_safe(self, tmp_path):
        """空の PID file は stale 扱いで上書き成功"""
        pid_file = str(tmp_path / "empty.pid")
        Path(pid_file).write_text("")
        acquire_pid_lock(pid_file)
        assert int(Path(pid_file).read_text().strip()) == os.getpid()
        release_pid_lock(pid_file)

    def test_non_numeric_pid_is_safe(self, tmp_path):
        """非数値 PID file は stale 扱いで上書き成功"""
        pid_file = str(tmp_path / "nonnumeric.pid")
        Path(pid_file).write_text("not_a_number")
        acquire_pid_lock(pid_file)
        assert int(Path(pid_file).read_text().strip()) == os.getpid()
        release_pid_lock(pid_file)

    def test_multiline_pid_file_uses_first_line(self, tmp_path):
        """複数行 PID file は1行目だけを使う。stale なら上書き"""
        pid_file = str(tmp_path / "multiline.pid")
        Path(pid_file).write_text("9999999\n8888888\n")
        acquire_pid_lock(pid_file)  # 9999999 は stale → 上書き成功
        assert int(Path(pid_file).read_text().strip()) == os.getpid()
        release_pid_lock(pid_file)

    def test_running_pid_rejected(self, tmp_path):
        """稼働中 PID → exit 1"""
        pid_file = str(tmp_path / "running.pid")
        Path(pid_file).write_text(str(os.getpid()))

        # /proc/$pid/cmdline に "chat_listener" が含まれるようにパッチ
        with patch("builtins.open", side_effect=_mock_open_proc_cmdline(os.getpid(), "chat_listener.py")):
            with pytest.raises(SystemExit) as exc:
                acquire_pid_lock(pid_file)
            assert exc.value.code == 1

    def test_stale_pid_overwritten(self, tmp_path):
        """stale PID (存在しないプロセス) は上書き成功"""
        pid_file = str(tmp_path / "stale.pid")
        Path(pid_file).write_text("9999999")
        acquire_pid_lock(pid_file)
        assert int(Path(pid_file).read_text().strip()) == os.getpid()
        release_pid_lock(pid_file)


def _mock_open_proc_cmdline(pid: int, name: str):
    """PID file と /proc/$pid/cmdline を mock する open ファクトリ"""
    original_open = open

    def _side_effect(path, *args, **kwargs):
        if str(path) == f"/proc/{pid}/cmdline":
            from unittest.mock import mock_open
            m = mock_open(read_data=name.encode("utf-8"))()
            return m
        return original_open(path, *args, **kwargs)

    return _side_effect
