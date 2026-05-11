#!/usr/bin/env python3
"""
input.py - CDPでテキスト入力を送信する

Usage:
  python3 input.py "Hello World"
  python3 input.py --selector "#search-box" "検索キーワード"
  python3 input.py --selector "#field" --clear "新しいテキスト"
  python3 input.py --key Enter              # キー送信のみ
  python3 input.py --selector "#pass" --type password "secret"
"""

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _bridge import cdp_send, get_first_target_id, die

# 特殊キーマップ (CDP Input.dispatchKeyEvent用)
KEY_MAP = {
    "Enter": ("Enter", "\r", 13),
    "Tab": ("Tab", "\t", 9),
    "Escape": ("Escape", "\x1b", 27),
    "Backspace": ("Backspace", "\x08", 8),
    "Delete": ("Delete", "\x7f", 46),
    "ArrowUp": ("ArrowUp", "", 38),
    "ArrowDown": ("ArrowDown", "", 40),
    "ArrowLeft": ("ArrowLeft", "", 37),
    "ArrowRight": ("ArrowRight", "", 39),
    "Home": ("Home", "", 36),
    "End": ("End", "", 35),
    "PageUp": ("PageUp", "", 33),
    "PageDown": ("PageDown", "", 34),
    "F5": ("F5", "", 116),
}


def focus_element(
    selector: str, host: str, port: int, target_id: str, timeout: int
) -> None:
    """セレクタで要素をフォーカスする。"""
    js = f"document.querySelector({json.dumps(selector)})?.focus()"
    cdp_send(
        method="Runtime.evaluate",
        params={"expression": js, "returnByValue": True},
        host=host, port=port, target_id=target_id, timeout=timeout,
    )


def clear_element(
    selector: str, host: str, port: int, target_id: str, timeout: int
) -> None:
    """セレクタで要素のvalueをクリアする。"""
    js = f"""
    (() => {{
        const el = document.querySelector({json.dumps(selector)});
        if (!el) return;
        const nativeInputProp = Object.getOwnPropertyDescriptor(
            window.HTMLInputElement.prototype, 'value'
        );
        if (nativeInputProp) {{
            nativeInputProp.set.call(el, '');
        }} else {{
            el.value = '';
        }}
        el.dispatchEvent(new Event('input', {{ bubbles: true }}));
    }})()
    """
    cdp_send(
        method="Runtime.evaluate",
        params={"expression": js},
        host=host, port=port, target_id=target_id, timeout=timeout,
    )


def type_text(
    text: str, host: str, port: int, target_id: str, timeout: int
) -> None:
    """Input.insertTextでテキストを入力する（フォーカス済み前提）。"""
    cdp_send(
        method="Input.insertText",
        params={"text": text},
        host=host, port=port, target_id=target_id, timeout=timeout,
    )


def press_key(
    key: str, host: str, port: int, target_id: str, timeout: int
) -> None:
    """特殊キーを送信する。"""
    key_info = KEY_MAP.get(key)
    if not key_info:
        die(f"未対応のキー: {key}. 対応キー: {', '.join(KEY_MAP.keys())}")
    key_code_name, key_text, windows_virtual_key = key_info

    for event_type in ("keyDown", "keyUp"):
        cdp_send(
            method="Input.dispatchKeyEvent",
            params={
                "type": event_type,
                "key": key_code_name,
                "text": key_text if event_type == "keyDown" else "",
                "windowsVirtualKeyCode": windows_virtual_key,
                "nativeVirtualKeyCode": windows_virtual_key,
            },
            host=host, port=port, target_id=target_id, timeout=timeout,
        )


def main():
    parser = argparse.ArgumentParser(description="CDPでテキスト入力")
    parser.add_argument("text", nargs="?", help="入力するテキスト")
    parser.add_argument("--selector", "-s", help="フォーカス対象のCSSセレクタ")
    parser.add_argument("--clear", action="store_true", help="入力前にフィールドをクリア")
    parser.add_argument("--key", help="特殊キー送信 (Enter/Tab/Escape等)")
    parser.add_argument("--host", default="localhost")
    parser.add_argument("--port", type=int, default=9223)
    parser.add_argument("--timeout", type=int, default=10)
    parser.add_argument("--url-contains", metavar="TEXT", help="ターゲットURLフィルタ")
    parser.add_argument("--target-id", metavar="ID", help="ターゲットID直接指定")
    args = parser.parse_args()

    if not args.text and not args.key:
        die("テキストまたは --key を指定してください")

    target_id = args.target_id or ""
    if not target_id:
        try:
            target_id = get_first_target_id(
                args.host, args.port, args.url_contains or "", args.timeout
            )
        except ConnectionError as e:
            die(str(e))

    try:
        if args.selector:
            focus_element(args.selector, args.host, args.port, target_id, args.timeout)
            print(f"フォーカス: {args.selector}")

        if args.clear and args.selector:
            clear_element(args.selector, args.host, args.port, target_id, args.timeout)
            print("フィールドをクリアしました")

        if args.text:
            type_text(args.text, args.host, args.port, target_id, args.timeout)
            print(f"入力完了: {args.text[:50]}{'...' if len(args.text) > 50 else ''}")

        if args.key:
            press_key(args.key, args.host, args.port, target_id, args.timeout)
            print(f"キー送信完了: {args.key}")

    except (RuntimeError, ValueError) as e:
        die(str(e))


if __name__ == "__main__":
    main()
