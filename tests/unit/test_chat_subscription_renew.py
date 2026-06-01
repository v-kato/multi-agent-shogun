"""
tests/unit/test_chat_subscription_renew.py
cmd_506 Batch E0 — chat_subscription_renew.py 単体テスト
ケース: success / 403 / 404 / LRO error / expired-soon alert
"""

import sys
import os
import pytest
from datetime import datetime, timezone, timedelta
from unittest.mock import MagicMock, patch, call
from googleapiclient.errors import HttpError
import httplib2

# プロジェクトルートを sys.path に追加
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from scripts.chat_subscription_renew import (
    parse_expire_time,
    remaining_ttl_seconds,
    poll_lro,
    validate_only,
    renew_subscription,
    update_config_expire_time,
    write_execution_log,
    check_remaining_ttl,
    ALERT_TTL_THRESHOLD_SECONDS,
)


# ─── helpers ────────────────────────────────────────────────────────────────

def make_http_error(status: int, reason: str = "") -> HttpError:
    resp = httplib2.Response({"status": status})
    resp.reason = reason
    return HttpError(resp=resp, content=reason.encode())


def future_expire(hours: float = 4.0) -> str:
    dt = datetime.now(timezone.utc) + timedelta(hours=hours)
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def past_expire(minutes: float = 30.0) -> str:
    dt = datetime.now(timezone.utc) - timedelta(minutes=minutes)
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


# ─── parse_expire_time / remaining_ttl_seconds ──────────────────────────────

class TestParseExpireTime:
    def test_z_suffix(self):
        dt = parse_expire_time("2026-06-02T01:02:13Z")
        assert dt.tzinfo is not None
        assert dt.year == 2026

    def test_offset_suffix(self):
        dt = parse_expire_time("2026-06-02T10:00:00+09:00")
        assert dt.utcoffset().seconds == 0 or dt.utcoffset().total_seconds() in (0, 32400)

    def test_remaining_positive(self):
        expire = future_expire(4.0)
        rem = remaining_ttl_seconds(expire)
        assert rem > 3 * 3600

    def test_remaining_negative(self):
        expire = past_expire(30.0)
        rem = remaining_ttl_seconds(expire)
        assert rem < 0


# ─── check_remaining_ttl (expired-soon alert) ───────────────────────────────

class TestCheckRemainingTtl:
    def test_no_alert_when_plenty(self):
        """十分 TTL がある場合はアラート不送信"""
        expire = future_expire(4.0)
        with patch("scripts.chat_subscription_renew.subprocess") as mock_sub:
            check_remaining_ttl(expire)
            mock_sub.run.assert_not_called()

    def test_alert_when_less_than_90min(self):
        """残 TTL ≤ 90 分でアラート送信"""
        expire = future_expire(1.0)  # 1 時間後 → 90 分以下
        with patch("scripts.chat_subscription_renew.subprocess") as mock_sub:
            mock_sub.run = MagicMock()
            check_remaining_ttl(expire)
            mock_sub.run.assert_called_once()
            call_args = mock_sub.run.call_args[0][0]
            assert "karo" in call_args

    def test_alert_when_expired(self):
        """すでに期限切れでもアラート送信"""
        expire = past_expire(10.0)
        with patch("scripts.chat_subscription_renew.subprocess") as mock_sub:
            mock_sub.run = MagicMock()
            check_remaining_ttl(expire)
            mock_sub.run.assert_called_once()


# ─── poll_lro ────────────────────────────────────────────────────────────────

class TestPollLro:
    def _make_service(self, responses: list) -> MagicMock:
        service = MagicMock()
        service.operations().get().execute.side_effect = responses
        return service

    def test_success_immediately_done(self):
        service = self._make_service([{"done": True, "response": {"expireTime": "2026-06-03T00:00:00Z"}}])
        with patch("scripts.chat_subscription_renew.time") as mock_time:
            result = poll_lro(service, "operations/abc123")
        assert result["expireTime"] == "2026-06-03T00:00:00Z"

    def test_success_after_two_polls(self):
        service = self._make_service([
            {"done": False},
            {"done": False},
            {"done": True, "response": {"expireTime": "2026-06-04T00:00:00Z"}},
        ])
        with patch("scripts.chat_subscription_renew.time") as mock_time:
            result = poll_lro(service, "operations/xyz")
        assert result["expireTime"] == "2026-06-04T00:00:00Z"

    def test_lro_error(self):
        service = self._make_service([{"done": True, "error": {"code": 403, "message": "Forbidden"}}])
        with pytest.raises(RuntimeError, match="LRO error"):
            poll_lro(service, "operations/fail")

    def test_timeout(self):
        service = MagicMock()
        service.operations().get().execute.return_value = {"done": False}
        with patch("scripts.chat_subscription_renew.LRO_POLL_MAX", 2), \
             patch("scripts.chat_subscription_renew.time"):
            with pytest.raises(TimeoutError):
                poll_lro(service, "operations/never-done")


# ─── validate_only ───────────────────────────────────────────────────────────

class TestValidateOnly:
    def test_success(self):
        service = MagicMock()
        service.subscriptions().patch().execute.return_value = {"name": "operations/val-ok"}
        result = validate_only(service, "subscriptions/test-sub")
        assert result is True

    def test_failure_continues(self):
        service = MagicMock()
        service.subscriptions().patch().execute.side_effect = make_http_error(403, "Forbidden")
        result = validate_only(service, "subscriptions/test-sub")
        assert result is False


# ─── renew_subscription (success / 403 / 404) ────────────────────────────────

class TestRenewSubscription:
    def _make_service_with_lro(self, after_expire: str) -> MagicMock:
        service = MagicMock()
        # patch → LRO (not done yet)
        service.subscriptions().patch().execute.return_value = {"name": "operations/renew-op"}
        # operations.get → done
        service.operations().get().execute.return_value = {
            "done": True,
            "response": {"expireTime": after_expire},
        }
        # subscriptions.get → updated subscription
        service.subscriptions().get().execute.return_value = {"expireTime": after_expire}
        return service

    def test_success(self):
        after = future_expire(4.0)
        service = self._make_service_with_lro(after)
        with patch("scripts.chat_subscription_renew.time"):
            result = renew_subscription(service, "subscriptions/test-sub")
        assert result.get("expireTime") == after

    def test_403_raises(self):
        service = MagicMock()
        service.subscriptions().patch().execute.side_effect = make_http_error(403, "Forbidden")
        with pytest.raises(HttpError):
            renew_subscription(service, "subscriptions/test-sub")

    def test_404_raises(self):
        service = MagicMock()
        service.subscriptions().patch().execute.side_effect = make_http_error(404, "Not Found")
        with pytest.raises(HttpError):
            renew_subscription(service, "subscriptions/test-sub")

    def test_lro_error_raises(self):
        service = MagicMock()
        service.subscriptions().patch().execute.return_value = {"name": "operations/fail-op"}
        service.operations().get().execute.return_value = {
            "done": True,
            "error": {"code": 500, "message": "internal"},
        }
        with patch("scripts.chat_subscription_renew.time"):
            with pytest.raises(RuntimeError, match="LRO error"):
                renew_subscription(service, "subscriptions/test-sub")

    def test_immediately_done_lro(self):
        """LRO が PATCH レスポンスで即 done の場合"""
        after = future_expire(4.0)
        service = MagicMock()
        service.subscriptions().patch().execute.return_value = {
            "done": True,
            "response": {"expireTime": after},
        }
        result = renew_subscription(service, "subscriptions/test-sub")
        assert result.get("expireTime") == after


# ─── write_execution_log ─────────────────────────────────────────────────────

class TestWriteExecutionLog:
    def test_creates_file(self, tmp_path):
        log_path = str(tmp_path / "renewal_log.md")
        before = "2026-06-02T01:02:13Z"
        after = "2026-06-03T01:02:13Z"
        write_execution_log(log_path, before, after, "operations/test-op", "subscriptions/test-sub", True)
        content = open(log_path, encoding="utf-8").read()
        assert "workspaceevents v1" in content
        assert before in content
        assert after in content
        assert "✅ 成功" in content

    def test_failure_log(self, tmp_path):
        log_path = str(tmp_path / "renewal_log.md")
        write_execution_log(
            log_path, "2026-06-02T01:02:13Z", "2026-06-02T01:02:13Z",
            "", "subscriptions/test-sub", False, "403 Forbidden"
        )
        content = open(log_path, encoding="utf-8").read()
        assert "❌ 失敗" in content
        assert "403 Forbidden" in content


# ─── update_config_expire_time ───────────────────────────────────────────────

class TestUpdateConfigExpireTime:
    def test_updates_expire_time(self, tmp_path):
        config_file = tmp_path / "config.yaml"
        config_file.write_text(
            'workspace_events_subscription:\n  expire_time: "2026-06-02T01:02:13Z"  # 旧値\n',
            encoding="utf-8",
        )
        update_config_expire_time(str(config_file), "2026-06-03T01:02:13Z")
        content = config_file.read_text(encoding="utf-8")
        assert "2026-06-03T01:02:13Z" in content
        assert "renewal 更新済" in content
