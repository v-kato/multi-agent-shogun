#!/usr/bin/env python3
"""
google_chat_inbox_update.py — Google Chat inbox エントリ更新ヘルパー
cmd_506 Phase G-2 ① Karo processed:true 導線

家老が channel inbox entry を処理後に processed:true へ遷移させるためのツール。
flock + temp + rename による atomic update。

使用方法:
  # intent 付与 (parse のみ)
  python3 scripts/google_chat_inbox_update.py annotate \
    --id ext_20260601T052654_30577456 \
    --inbox queue/inbox/google_chat_inbox.yaml

  # 処理完了マーク
  python3 scripts/google_chat_inbox_update.py mark-processed \
    --id ext_20260601T052654_30577456 \
    --decision rejected \
    --reason "no_actionable_intent" \
    --inbox queue/inbox/google_chat_inbox.yaml

  # message_id 指定も可
  python3 scripts/google_chat_inbox_update.py mark-processed \
    --message-id "spaces/AAA/messages/001" \
    --decision accepted \
    --parent-cmd cmd_506
"""

import argparse
import fcntl
import logging
import os
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

import yaml

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)

DEFAULT_INBOX = "queue/inbox/google_chat_inbox.yaml"
DEFAULT_CONFIG = "config/external_inputs.yaml"


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _load_inbox(inbox_path: str) -> tuple[dict, list]:
    """inbox YAML を読んで (data, entries) を返す。"""
    p = Path(inbox_path)
    if not p.exists():
        return {"inbox": []}, []
    with open(inbox_path, encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
    entries = data.get("inbox", []) or []
    return data, entries


def _find_entry(entries: list, entry_id: str = None, message_id: str = None) -> tuple[int, dict | None]:
    """entries から id または message_id でエントリを検索。(index, entry) を返す。"""
    for i, e in enumerate(entries):
        if entry_id and e.get("id") == entry_id:
            return i, e
        if message_id and e.get("message_id") == message_id:
            return i, e
    return -1, None


def _atomic_write(inbox_path: str, data: dict) -> None:
    """flock + temp file + rename による atomic write。"""
    p = Path(inbox_path)
    p.parent.mkdir(parents=True, exist_ok=True)

    lock_path = str(inbox_path) + ".lock"
    tmp_path = None

    with open(lock_path, "w") as lock_file:
        fcntl.flock(lock_file, fcntl.LOCK_EX)
        try:
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


def count_unprocessed(entries: list) -> int:
    """processed=false かつ rejected=false の件数を返す。"""
    return sum(1 for e in entries if not e.get("processed", False) and not e.get("rejected", False))


def cmd_annotate(args) -> int:
    """intent 解析結果を entry に付与して保存する。"""
    inbox_path = args.inbox
    lock_path = inbox_path + ".lock"

    sys.path.insert(0, str(Path(__file__).parent))
    try:
        from chat_intent_parser import annotate_chat_inbox_entry
    except ImportError as e:
        logger.error("chat_intent_parser をインポートできません: %s", e)
        return 1

    with open(lock_path, "w") as lock_file:
        fcntl.flock(lock_file, fcntl.LOCK_EX)
        try:
            data, entries = _load_inbox(inbox_path)
            idx, entry = _find_entry(entries, entry_id=args.id, message_id=args.message_id)
            if entry is None:
                logger.error("エントリが見つかりません: id=%s message_id=%s", args.id, args.message_id)
                return 1

            updated = annotate_chat_inbox_entry(dict(entry), config_path=args.config)
            entries[idx] = updated
            data["inbox"] = entries

            tmp_path = None
            p = Path(inbox_path)
            try:
                with tempfile.NamedTemporaryFile(
                    mode="w", encoding="utf-8", dir=p.parent, suffix=".tmp", delete=False
                ) as tmp:
                    yaml.dump(data, tmp, allow_unicode=True, default_flow_style=False, sort_keys=False)
                    tmp_path = tmp.name
                os.replace(tmp_path, inbox_path)
                tmp_path = None
            finally:
                if tmp_path and os.path.exists(tmp_path):
                    os.unlink(tmp_path)
        finally:
            fcntl.flock(lock_file, fcntl.LOCK_UN)

    logger.info("annotate 完了: id=%s intent=%s", entry.get("id"), updated.get("intent", {}).get("status"))
    return 0


def cmd_mark_processed(args) -> int:
    """エントリを processed:true に更新する。karo_decision も設定する。"""
    inbox_path = args.inbox
    lock_path = inbox_path + ".lock"

    decision = args.decision
    if decision not in ("accepted", "needs_confirmation", "rejected"):
        logger.error("--decision は accepted/needs_confirmation/rejected のいずれか")
        return 1

    with open(lock_path, "w") as lock_file:
        fcntl.flock(lock_file, fcntl.LOCK_EX)
        try:
            data, entries = _load_inbox(inbox_path)
            idx, entry = _find_entry(entries, entry_id=args.id, message_id=args.message_id)
            if entry is None:
                logger.error("エントリが見つかりません: id=%s message_id=%s", args.id, args.message_id)
                return 1

            entry = dict(entry)
            entry["processed"] = True
            entry["read"] = True

            karo = dict(entry.get("karo_decision") or {})
            karo["status"] = decision
            if args.reason:
                karo["reason"] = args.reason
            if args.parent_cmd:
                karo["parent_cmd"] = args.parent_cmd
            if decision == "needs_confirmation":
                karo["confirmation_required"] = True
                karo["dashboard_action_required"] = True
            entry["karo_decision"] = karo

            entries[idx] = entry
            data["inbox"] = entries

            tmp_path = None
            p = Path(inbox_path)
            try:
                with tempfile.NamedTemporaryFile(
                    mode="w", encoding="utf-8", dir=p.parent, suffix=".tmp", delete=False
                ) as tmp:
                    yaml.dump(data, tmp, allow_unicode=True, default_flow_style=False, sort_keys=False)
                    tmp_path = tmp.name
                os.replace(tmp_path, inbox_path)
                tmp_path = None
            finally:
                if tmp_path and os.path.exists(tmp_path):
                    os.unlink(tmp_path)
        finally:
            fcntl.flock(lock_file, fcntl.LOCK_UN)

    remaining = count_unprocessed(entries)
    logger.info(
        "mark-processed 完了: id=%s decision=%s 残未処理=%d",
        entry.get("id"), decision, remaining
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Google Chat inbox エントリ更新ヘルパー (cmd_506 G-2)")
    sub = parser.add_subparsers(dest="command")

    # annotate サブコマンド
    p_ann = sub.add_parser("annotate", help="intent 解析結果を entry に付与")
    p_ann.add_argument("--id", help="エントリ id (ext_...)")
    p_ann.add_argument("--message-id", help="message_id (spaces/.../messages/...)")
    p_ann.add_argument("--inbox", default=DEFAULT_INBOX)
    p_ann.add_argument("--config", default=DEFAULT_CONFIG)

    # mark-processed サブコマンド
    p_mp = sub.add_parser("mark-processed", help="処理完了マーク (processed:true)")
    p_mp.add_argument("--id", help="エントリ id")
    p_mp.add_argument("--message-id", help="message_id")
    p_mp.add_argument(
        "--decision",
        required=True,
        choices=["accepted", "needs_confirmation", "rejected"],
    )
    p_mp.add_argument("--reason", help="決定理由")
    p_mp.add_argument("--parent-cmd", help="紐付け cmd_id (decision=accepted 時)")
    p_mp.add_argument("--inbox", default=DEFAULT_INBOX)

    args = parser.parse_args()

    if args.command == "annotate":
        if not args.id and not args.message_id:
            parser.error("--id または --message-id が必要です")
        return cmd_annotate(args)
    elif args.command == "mark-processed":
        if not args.id and not args.message_id:
            parser.error("--id または --message-id が必要です")
        return cmd_mark_processed(args)
    else:
        parser.print_help()
        return 1


if __name__ == "__main__":
    sys.exit(main())
