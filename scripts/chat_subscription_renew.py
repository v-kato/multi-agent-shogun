#!/usr/bin/env python3
"""
chat_subscription_renew.py — Google Workspace Events subscription renewal
cmd_506 Batch E0 / phase_h_addendum: 初回は単体テスト PASS 後、即実行 (殿確認なし)

使用方法:
  python3 scripts/chat_subscription_renew.py \
    --config config/google-chat-events-config.yaml \
    --credentials config/google-chat-events.json

API: Workspace Events v1 subscriptions.patch (updateMask=ttl, body={"ttl":"0s"})
LRO: operations.get でポーリング → 完了後に subscriptions.get で expireTime 確認
"""

import argparse
import json
import logging
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import yaml
from google.oauth2.service_account import Credentials
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError

SCOPES = [
    "https://www.googleapis.com/auth/chat.app.messages.readonly",
]
API_VERSION = "v1"
ALERT_TTL_THRESHOLD_SECONDS = 90 * 60  # 残 TTL ≤ 90 分でアラート
LRO_POLL_INTERVAL = 3
LRO_POLL_MAX = 60

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)


def load_config(config_path: str) -> dict:
    with open(config_path, encoding="utf-8") as f:
        return yaml.safe_load(f)


def build_service(credentials_path: str):
    creds = Credentials.from_service_account_file(credentials_path, scopes=SCOPES)
    return build("workspaceevents", API_VERSION, credentials=creds, cache_discovery=False)


def parse_expire_time(expire_str: str) -> datetime:
    """ISO 8601 文字列を aware datetime (UTC) に変換"""
    if expire_str.endswith("Z"):
        expire_str = expire_str[:-1] + "+00:00"
    return datetime.fromisoformat(expire_str).astimezone(timezone.utc)


def remaining_ttl_seconds(expire_time_str: str) -> float:
    expire_dt = parse_expire_time(expire_time_str)
    now = datetime.now(timezone.utc)
    return (expire_dt - now).total_seconds()


def check_remaining_ttl(expire_time_str: str) -> None:
    remaining = remaining_ttl_seconds(expire_time_str)
    if remaining <= ALERT_TTL_THRESHOLD_SECONDS:
        logger.warning(
            "残 TTL が %.0f 分以下です (%.1f 分)。家老に alert を送ります。",
            ALERT_TTL_THRESHOLD_SECONDS / 60,
            remaining / 60,
        )
        try:
            alert_msg = (
                f"★ subscription TTL 警告: 残 {remaining/60:.0f} 分。"
                "手動 renewal が必要です。"
            )
            subprocess.run(
                ["bash", "scripts/inbox_write.sh", "karo", alert_msg, "alert", "chat_subscription_renew"],
                check=False,
            )
        except Exception as e:
            logger.error("alert 送信失敗: %s", e)


def poll_lro(service, operation_name: str) -> dict:
    """LRO が完了するまでポーリング。完了したら response を返す。失敗時は例外。"""
    for attempt in range(LRO_POLL_MAX):
        op = service.operations().get(name=operation_name).execute()
        if op.get("done"):
            if "error" in op:
                raise RuntimeError(f"LRO error: {op['error']}")
            return op.get("response", {})
        logger.info("LRO ポーリング %d/%d: %s", attempt + 1, LRO_POLL_MAX, operation_name)
        time.sleep(LRO_POLL_INTERVAL)
    raise TimeoutError(f"LRO タイムアウト: {operation_name}")


def validate_only(service, subscription_name: str) -> bool:
    """validateOnly=true で事前検証。失敗しても実更新は継続する。"""
    try:
        result = (
            service.subscriptions()
            .patch(
                name=subscription_name,
                updateMask="ttl",
                validateOnly=True,
                body={"ttl": "0s"},
            )
            .execute()
        )
        logger.info("validateOnly 成功: %s", result)
        return True
    except HttpError as e:
        logger.warning("validateOnly 失敗 (実更新は継続): %s", e)
        return False


def renew_subscription(service, subscription_name: str) -> dict:
    """subscriptions.patch で renewal。LRO を poll して完了後の subscription を返す。"""
    op = (
        service.subscriptions()
        .patch(
            name=subscription_name,
            updateMask="ttl",
            body={"ttl": "0s"},
        )
        .execute()
    )
    op_name = op.get("name", "")
    logger.info("PATCH 実行 → LRO: %s", op_name)

    if op.get("done"):
        return op.get("response", op)

    poll_lro(service, op_name)

    updated = service.subscriptions().get(name=subscription_name).execute()
    return updated


def update_config_expire_time(config_path: str, new_expire_time: str) -> None:
    """config YAML の expire_time を更新する。"""
    with open(config_path, encoding="utf-8") as f:
        raw = f.read()

    old_expire = None
    lines = raw.splitlines()
    new_lines = []
    for line in lines:
        if "expire_time:" in line and "2026" in line:
            old_expire = line.strip()
            new_lines.append(f'  expire_time: "{new_expire_time}"  # renewal 更新済')
        else:
            new_lines.append(line)

    with open(config_path, "w", encoding="utf-8") as f:
        f.write("\n".join(new_lines) + "\n")

    logger.info("config 更新: %s → %s", old_expire, new_expire_time)


def write_execution_log(
    log_path: str,
    before_expire: str,
    after_expire: str,
    operation_name: str,
    subscription_name: str,
    success: bool,
    error_msg: str = "",
) -> None:
    now_jst = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    content = f"""# cmd_506 Batch E0 — renewal 実行ログ

## 実行情報

| 項目 | 値 |
|------|-----|
| 実行時刻 (UTC) | {now_jst} |
| API version | workspaceevents {API_VERSION} |
| Subscription | {subscription_name} |
| Operation name | {operation_name} |
| 結果 | {"✅ 成功" if success else "❌ 失敗"} |

## expireTime before/after

| | 値 |
|---|-----|
| Before | {before_expire} |
| After  | {after_expire} |
| 延伸確認 | {"✅ after > before" if success and after_expire > before_expire else "❌ 延伸なし"} |

{"" if success else f"## エラー詳細\\n\\n```\\n{error_msg}\\n```\\n"}
"""
    Path(log_path).parent.mkdir(parents=True, exist_ok=True)
    with open(log_path, "w", encoding="utf-8") as f:
        f.write(content)
    logger.info("実行ログ保存: %s", log_path)


def main():
    parser = argparse.ArgumentParser(description="Google Chat subscription renewal")
    parser.add_argument("--config", default="config/google-chat-events-config.yaml")
    parser.add_argument("--credentials", default="config/google-chat-events.json")
    parser.add_argument("--log-path", default="tmp/cmd_506/renewal_execution_log.md")
    parser.add_argument("--dry-run", action="store_true", help="validateOnly のみ実行")
    args = parser.parse_args()

    cfg = load_config(args.config)
    ws_cfg = cfg.get("workspace_events_subscription", {})
    subscription_name = ws_cfg.get("name", "")
    before_expire = ws_cfg.get("expire_time", "")

    if not subscription_name:
        logger.error("config に workspace_events_subscription.name がありません")
        sys.exit(1)

    logger.info("=== subscription renewal 開始 ===")
    logger.info("Subscription: %s", subscription_name)
    logger.info("Before expireTime: %s", before_expire)

    check_remaining_ttl(before_expire)

    service = build_service(args.credentials)

    logger.info("validateOnly=true で事前検証...")
    validate_only(service, subscription_name)

    if args.dry_run:
        logger.info("--dry-run 指定: 実更新をスキップ")
        return

    operation_name = ""
    after_expire = before_expire
    success = False
    error_msg = ""

    try:
        logger.info("subscriptions.patch (updateMask=ttl, ttl=0s) 実行...")
        # PATCH → LRO 取得
        op = (
            service.subscriptions()
            .patch(
                name=subscription_name,
                updateMask="ttl",
                body={"ttl": "0s"},
            )
            .execute()
        )
        operation_name = op.get("name", "")
        logger.info("LRO: %s", operation_name)

        if op.get("done"):
            updated = op.get("response", op)
        else:
            poll_lro(service, operation_name)
            updated = service.subscriptions().get(name=subscription_name).execute()

        after_expire = updated.get("expireTime", before_expire)
        logger.info("After expireTime: %s", after_expire)

        if after_expire > before_expire:
            logger.info("✅ renewal 成功: %s → %s", before_expire, after_expire)
            success = True
        else:
            logger.warning("expireTime が延伸されていません: %s", after_expire)
            success = False

    except HttpError as e:
        error_msg = str(e)
        logger.error("HttpError: %s", e)
        success = False
    except Exception as e:
        error_msg = str(e)
        logger.error("予期せぬエラー: %s", e)
        success = False

    write_execution_log(
        args.log_path,
        before_expire,
        after_expire,
        operation_name,
        subscription_name,
        success,
        error_msg,
    )

    if success:
        update_config_expire_time(args.config, after_expire)
    else:
        remaining = remaining_ttl_seconds(before_expire)
        if remaining <= 2 * 3600:
            logger.error("★ 残 TTL 2 時間以内・renewal 失敗 → 家老緊急 alert")
            try:
                subprocess.run(
                    [
                        "bash", "scripts/inbox_write.sh", "karo",
                        f"★緊急★ subscription renewal 失敗 + 残 TTL {remaining/60:.0f} 分。即座に手動対応が必要。エラー: {error_msg[:200]}",
                        "alert", "chat_subscription_renew",
                    ],
                    check=False,
                )
            except Exception:
                pass
        sys.exit(1)


if __name__ == "__main__":
    main()
