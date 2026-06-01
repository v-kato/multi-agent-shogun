#!/usr/bin/env python3
"""
chat_listener.py — Google Chat Pub/Sub pull → queue/inbox/google_chat_inbox.yaml
cmd_506 Batch B / phase_h_addendum 反映

使用方法:
  python3 scripts/chat_listener.py \
    --config config/google-chat-events-config.yaml \
    --credentials config/google-chat-events.json

フロー:
  1. Pub/Sub pull
  2. ★ノイズフィルタ (ce-subject + ce-type) — allowlist 前最優先
  3. デコード (message.data bytes → base64? → UTF-8 JSON)
  4. スキーマ検証 + allowlist + dedup
  5. YAML atomic append (flock + temp + rename)
  6. 永続書込成功後に ack (書込失敗時は ack しない)
"""

import argparse
import base64
import fcntl
import json
import logging
import os
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

import yaml

# デフォルト PID file パス
DEFAULT_PID_FILE = "/tmp/chat_listener.pid"

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)


def acquire_pid_lock(pid_file: str) -> None:
    """
    単一起動保証: PID file による二重起動防止。
    既存 PID が稼働中なら exit(1)。stale PID file は上書き。
    """
    pid_path = Path(pid_file)
    if pid_path.exists():
        try:
            existing_pid = int(pid_path.read_text().strip())
            os.kill(existing_pid, 0)  # signal 0 = 生死確認のみ
            logger.error(
                "二重起動を拒否: PID %d が稼働中 (PID file: %s)。"
                "既存プロセスを停止してから再起動してください。",
                existing_pid,
                pid_file,
            )
            sys.exit(1)
        except ValueError:
            logger.warning("PID file の内容が不正。上書きします: %s", pid_file)
        except ProcessLookupError:
            logger.info("stale PID file を上書き (PID: %s)", pid_path.read_text().strip())
        except PermissionError:
            logger.error("PID file の確認に失敗 (PermissionError)。二重起動を拒否します。")
            sys.exit(1)

    pid_path.write_text(str(os.getpid()))
    logger.info("PID file 作成: %s (PID=%d)", pid_file, os.getpid())


def release_pid_lock(pid_file: str) -> None:
    """PID file 削除 (atexit / finally で呼ぶ)"""
    try:
        Path(pid_file).unlink(missing_ok=True)
        logger.info("PID file 削除: %s", pid_file)
    except Exception as e:
        logger.warning("PID file 削除失敗: %s (%s)", pid_file, e)


def load_config(path: str) -> dict:
    with open(path, encoding="utf-8") as f:
        return yaml.safe_load(f)


def build_subscriber(credentials_path: str):
    """Pub/Sub SubscriberClient を SA credentials で構築"""
    from google.cloud import pubsub_v1
    from google.oauth2 import service_account

    creds = service_account.Credentials.from_service_account_file(
        credentials_path,
        scopes=["https://www.googleapis.com/auth/pubsub"],
    )
    return pubsub_v1.SubscriberClient(credentials=creds)


def check_noise_filter(
    attributes: dict, expected_subject: str, expected_type: str
) -> tuple:
    """
    ★ノイズフィルタ最優先 (allowlist より前段)
    ce-subject + ce-type が期待値と完全一致するものだけを通す。
    admin install Everyone 由来の ADDED_TO_SPACE / REMOVED_FROM_SPACE 等を落とす。
    """
    ce_subject = attributes.get("ce-subject", "")
    ce_type = attributes.get("ce-type", "")

    if not ce_subject or not ce_type:
        return False, "missing_attributes"
    if ce_subject != expected_subject:
        return False, "wrong_subject"
    if ce_type != expected_type:
        return False, "unsupported_event_type"
    return True, ""


def decode_payload(data_bytes: bytes) -> dict:
    """
    Pub/Sub message.data bytes → dict

    方針:
    - 外側 JSON に "data" フィールドがある場合 → base64 decode → UTF-8 parse (Pub/Sub 標準形式)
    - そのまま UTF-8 JSON bytes の場合はそのまま parse
    - 日本語 (ポケモン等) が破損しないこと必須
    """
    if not data_bytes:
        raise ValueError("empty data")

    try:
        text = data_bytes.decode("utf-8")
        obj = json.loads(text)
    except (UnicodeDecodeError, json.JSONDecodeError) as e:
        raise ValueError(f"malformed_payload: not valid UTF-8 JSON: {e}")

    if isinstance(obj, dict) and "data" in obj:
        data_field = obj["data"]
        if isinstance(data_field, str):
            try:
                decoded_bytes = base64.b64decode(data_field)
                inner = json.loads(decoded_bytes.decode("utf-8"))
                return inner
            except Exception as e:
                raise ValueError(f"malformed_payload: base64 decode failed: {e}")
        if isinstance(data_field, dict):
            return data_field

    return obj


def extract_chat_message(payload: dict) -> dict:
    """CloudEvent payload から Chat message dict を抽出"""
    if "message" in payload:
        msg = payload["message"]
        return msg if isinstance(msg, dict) else {}
    return payload


def is_bot_sender(sender: dict) -> bool:
    sender_type = sender.get("type", "")
    if sender_type and sender_type.upper() in ("BOT", "APP"):
        return True
    return False


def check_allowlist(sender: dict, allowlist_config: dict) -> tuple:
    """
    allowlist 判定
    allowlist_config = {verified_identifiers: [...], sender_ids: [...]}
    """
    if not sender:
        return False, "sender_missing"

    if is_bot_sender(sender):
        return False, "sender_is_bot"

    sender_id = sender.get("name", "")
    if not sender_id:
        return False, "sender_missing"

    sender_email = sender.get("email", "")

    verified_identifiers = allowlist_config.get("verified_identifiers", []) or []
    sender_ids = allowlist_config.get("sender_ids", []) or []

    if sender_email and sender_email in verified_identifiers:
        return True, ""

    if sender_id in sender_ids:
        return True, ""

    return False, "sender_not_allowlisted"


def load_inbox_dedups(inbox_path: str) -> set:
    """既存 inbox から message_id セットを返す (dedup 用)"""
    p = Path(inbox_path)
    if not p.exists():
        return set()
    with open(inbox_path, encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
    entries = data.get("inbox", []) or []
    return {e.get("message_id") for e in entries if e.get("message_id")}


def build_inbox_entry(
    message_id: str,
    delivery_id: str,
    received_at: str,
    event_time: str,
    event_type: str,
    sender: dict,
    chat_message: dict,
    payload: dict,
    rejected: bool = False,
    reject_reason: str = None,
) -> dict:
    """docs/external_inputs/common/inbox_schema.md 準拠エントリ生成"""
    space_raw = chat_message.get("space", {})
    space_id = space_raw.get("name", "") if isinstance(space_raw, dict) else str(space_raw)

    thread_raw = chat_message.get("thread", {})
    thread_id = thread_raw.get("name", "") if isinstance(thread_raw, dict) else str(thread_raw)

    text = chat_message.get("text", "")
    sender_name = sender.get("name", "")
    sender_display = sender.get("displayName", sender.get("display_name", ""))
    sender_email = sender.get("email", "")

    ts_compact = received_at.replace(":", "").replace("+", "p").replace("-", "")[:15]
    suffix = (delivery_id or "noid")[-8:]
    entry_id = f"ext_{ts_compact}_{suffix}"

    return {
        "id": entry_id,
        "source_channel": "google_chat",
        "message_id": message_id,
        "delivery_id": delivery_id,
        "received_at": received_at,
        "event_time": event_time,
        "event_type": event_type,
        "sender": {
            "id": sender_name,
            "display_name": sender_display,
            "verified_identifier": sender_email if sender_email else None,
            "identifier_type": "email" if sender_email else None,
            "channel_metadata": {},
        },
        "context": {
            "space_id": space_id,
            "thread_id": thread_id,
            "raw_resource_name": message_id,
        },
        "text": text,
        "normalized_text": text,
        "read": False,
        "processed": rejected,
        "rejected": rejected,
        "reject_reason": reject_reason,
        "intent": {
            "status": "pending",
            "core_type": None,
            "skill_id": None,
            "skill_type": None,
            "confidence": None,
            "extracted": None,
        },
        "karo_decision": {
            "status": "pending",
            "reason": None,
            "parent_cmd": None,
            "confirmation_required": False,
            "dashboard_action_required": False,
        },
    }


def atomic_yaml_append(inbox_path: str, entry: dict) -> None:
    """
    flock + temp file + rename による atomic YAML append
    トップキー: inbox
    書込失敗時は例外を送出 (呼び出し元で ack しないこと)
    """
    p = Path(inbox_path)
    p.parent.mkdir(parents=True, exist_ok=True)

    lock_path = str(inbox_path) + ".lock"
    tmp_path = None

    with open(lock_path, "w") as lock_file:
        fcntl.flock(lock_file, fcntl.LOCK_EX)
        try:
            if p.exists():
                with open(inbox_path, encoding="utf-8") as f:
                    data = yaml.safe_load(f) or {}
            else:
                data = {}

            entries = data.get("inbox", []) or []
            entries.append(entry)
            data["inbox"] = entries

            with tempfile.NamedTemporaryFile(
                mode="w",
                encoding="utf-8",
                dir=p.parent,
                suffix=".tmp",
                delete=False,
            ) as tmp:
                yaml.dump(data, tmp, allow_unicode=True, default_flow_style=False, sort_keys=False)
                tmp_path = tmp.name

            os.replace(tmp_path, inbox_path)
            tmp_path = None
        finally:
            if tmp_path and os.path.exists(tmp_path):
                os.unlink(tmp_path)
            fcntl.flock(lock_file, fcntl.LOCK_UN)


def process_message(
    pubsub_message,
    expected_subject: str,
    expected_type: str,
    allowlist_config: dict,
    inbox_path: str,
    dedup_cache: set,
) -> str:
    """
    1 メッセージを処理。
    返り値: "accepted" | "rejected:{reason}" | "error:{msg}"
    ack 判断は呼び出し元が行う。
    """
    attributes = dict(pubsub_message.attributes)
    delivery_id = pubsub_message.message_id
    received_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    event_time = attributes.get("ce-time", "")

    # Step 1: ★ノイズフィルタ (最優先・allowlist より前)
    ok, reason = check_noise_filter(attributes, expected_subject, expected_type)
    if not ok:
        logger.info("ノイズフィルタ拒否: reason=%s delivery_id=%s", reason, delivery_id)
        return f"rejected:{reason}"

    # Step 2: デコード
    try:
        payload = decode_payload(bytes(pubsub_message.data))
    except ValueError as e:
        logger.warning("デコードエラー: %s delivery_id=%s", e, delivery_id)
        return "rejected:malformed_payload"

    # Step 3: Chat message 抽出 + message_id 検証
    chat_message = extract_chat_message(payload)
    message_id = chat_message.get("name", "")

    if not message_id:
        logger.warning("message.name 欠落 delivery_id=%s", delivery_id)
        return "rejected:message_id_missing"

    # Step 4: dedup (message.name が主要 dedup key)
    if message_id in dedup_cache:
        logger.info("重複: message_id=%s delivery_id=%s", message_id, delivery_id)
        return "rejected:duplicate_message"

    # Step 5: allowlist 検証
    sender = chat_message.get("sender", {})
    ok, reason = check_allowlist(sender, allowlist_config)
    if not ok:
        logger.info("allowlist 拒否: reason=%s sender_id=%s sender_type=%s", reason, sender.get("name", "?"), sender.get("type", "?"))
        entry = build_inbox_entry(
            message_id=message_id,
            delivery_id=delivery_id,
            received_at=received_at,
            event_time=event_time,
            event_type=expected_type,
            sender=sender,
            chat_message=chat_message,
            payload=payload,
            rejected=True,
            reject_reason=reason,
        )
        atomic_yaml_append(inbox_path, entry)
        dedup_cache.add(message_id)
        return f"rejected:{reason}"

    # Step 6: inbox 追記 (永続書込成功後に ack)
    entry = build_inbox_entry(
        message_id=message_id,
        delivery_id=delivery_id,
        received_at=received_at,
        event_time=event_time,
        event_type=expected_type,
        sender=sender,
        chat_message=chat_message,
        payload=payload,
    )
    atomic_yaml_append(inbox_path, entry)
    dedup_cache.add(message_id)

    logger.info("inbox 追記: message_id=%s", message_id)
    return "accepted"


def main():
    parser = argparse.ArgumentParser(description="Google Chat Pub/Sub pull listener (cmd_506 Batch B)")
    parser.add_argument("--config", default="config/google-chat-events-config.yaml")
    parser.add_argument("--credentials", default="config/google-chat-events.json")
    parser.add_argument("--inbox", default="queue/inbox/google_chat_inbox.yaml")
    parser.add_argument("--max-messages", type=int, default=10)
    parser.add_argument("--once", action="store_true", help="1 回 pull して終了 (デバッグ用)")
    parser.add_argument("--pid-file", default=DEFAULT_PID_FILE, help="PID file パス (単一起動保証)")
    parser.add_argument("--no-pid-file", action="store_true", help="PID file を使わない (テスト用)")
    args = parser.parse_args()

    # ★単一起動保証
    import atexit
    if not args.no_pid_file:
        acquire_pid_lock(args.pid_file)
        atexit.register(release_pid_lock, args.pid_file)

    cfg = load_config(args.config)
    gc_cfg = cfg.get("google_chat", {})

    project_id = gc_cfg.get("project_id", "")
    subscription_name = gc_cfg.get("subscription_name", "")

    if not project_id or not subscription_name:
        logger.error("config に project_id / subscription_name がありません")
        sys.exit(1)

    space_id = gc_cfg.get("chat_space_id", "")
    expected_subject = f"//chat.googleapis.com/{space_id}"
    expected_type = "google.workspace.chat.message.v1.created"

    ext_cfg = cfg.get("external_inputs", {})
    allowlist_config = (ext_cfg.get("allowlist", {}) or {}).get("google_chat", {}) or {}
    if not allowlist_config:
        allowlist_config = gc_cfg.get("allowlist", {}) or {}

    logger.info("=== chat_listener 起動 ===")
    logger.info("project: %s  subscription: %s", project_id, subscription_name)
    logger.info("inbox: %s", args.inbox)

    subscriber = build_subscriber(args.credentials)
    subscription_path = f"projects/{project_id}/subscriptions/{subscription_name}"

    dedup_cache = load_inbox_dedups(args.inbox)
    logger.info("dedup cache ロード: %d 件", len(dedup_cache))

    try:
        while True:
            response = subscriber.pull(
                request={
                    "subscription": subscription_path,
                    "max_messages": args.max_messages,
                }
            )

            if not response.received_messages:
                if args.once:
                    break
                time.sleep(5)
                continue

            ack_ids = []
            for received in response.received_messages:
                result = process_message(
                    received.message,
                    expected_subject=expected_subject,
                    expected_type=expected_type,
                    allowlist_config=allowlist_config,
                    inbox_path=args.inbox,
                    dedup_cache=dedup_cache,
                )
                if not result.startswith("error:"):
                    ack_ids.append(received.ack_id)

            if ack_ids:
                subscriber.acknowledge(
                    request={
                        "subscription": subscription_path,
                        "ack_ids": ack_ids,
                    }
                )
                logger.info("ack: %d 件", len(ack_ids))

            if args.once:
                break

    except KeyboardInterrupt:
        logger.info("停止 (KeyboardInterrupt)")
    finally:
        subscriber.close()


if __name__ == "__main__":
    main()
