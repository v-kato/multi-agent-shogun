#!/usr/bin/env python3
"""
click.py - CDPでマウスクリックを送信する

Usage:
  python3 click.py --x 500 --y 300
  python3 click.py --selector "#submit-button"
  python3 click.py --x 200 --y 400 --double
  python3 click.py --selector "button[type=submit]" --url-contains "login"
"""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _bridge import cdp_send, get_first_target_id, die


def dispatch_mouse_event(
    event_type: str, x: float, y: float,
    button: str, click_count: int,
    host: str, port: int, target_id: str, timeout: int,
    cmd_id: int = 1,
) -> None:
    cdp_send(
        method="Input.dispatchMouseEvent",
        params={
            "type": event_type,
            "x": x,
            "y": y,
            "button": button,
            "clickCount": click_count,
        },
        host=host, port=port, target_id=target_id, timeout=timeout, cmd_id=cmd_id,
    )


def click_at(
    x: float, y: float, double: bool,
    host: str, port: int, target_id: str, timeout: int,
) -> None:
    click_count = 2 if double else 1
    dispatch_mouse_event("mouseMoved", x, y, "none", 0, host, port, target_id, timeout, 1)
    dispatch_mouse_event("mousePressed", x, y, "left", click_count, host, port, target_id, timeout, 2)
    dispatch_mouse_event("mouseReleased", x, y, "left", click_count, host, port, target_id, timeout, 3)


def get_element_center(
    selector: str, host: str, port: int, target_id: str, timeout: int
) -> tuple[float, float]:
    """CSSセレクタで要素を探し、その中央座標を返す。"""
    js = f"""
    (() => {{
        const el = document.querySelector({json_str(selector)});
        if (!el) return null;
        const r = el.getBoundingClientRect();
        return {{ x: r.left + r.width / 2, y: r.top + r.height / 2 }};
    }})()
    """
    resp = cdp_send(
        method="Runtime.evaluate",
        params={"expression": js, "returnByValue": True},
        host=host, port=port, target_id=target_id, timeout=timeout,
    )
    value = resp.get("result", {}).get("result", {}).get("value")
    if not value:
        raise ValueError(f"セレクタが見つかりません: {selector}")
    return value["x"], value["y"]


def json_str(s: str) -> str:
    import json
    return json.dumps(s)


def main():
    parser = argparse.ArgumentParser(description="CDPでマウスクリック送信")
    parser.add_argument("--x", type=float, help="クリックX座標")
    parser.add_argument("--y", type=float, help="クリックY座標")
    parser.add_argument("--selector", "-s", help="CSSセレクタ")
    parser.add_argument("--double", action="store_true", help="ダブルクリック")
    parser.add_argument("--host", default="localhost")
    parser.add_argument("--port", type=int, default=9223)
    parser.add_argument("--timeout", type=int, default=10)
    parser.add_argument("--url-contains", metavar="TEXT", help="ターゲットURLフィルタ")
    parser.add_argument("--target-id", metavar="ID", help="ターゲットID直接指定")
    args = parser.parse_args()

    if not args.selector and (args.x is None or args.y is None):
        die("--selector または --x と --y のどちらかを指定してください")

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
            x, y = get_element_center(
                args.selector, args.host, args.port, target_id, args.timeout
            )
            print(f"セレクタ '{args.selector}' → 座標 ({x:.0f}, {y:.0f})")
        else:
            x, y = args.x, args.y

        click_at(x, y, args.double, args.host, args.port, target_id, args.timeout)
        action = "ダブルクリック" if args.double else "クリック"
        print(f"{action}完了: ({x:.0f}, {y:.0f})")

    except (RuntimeError, ValueError) as e:
        die(str(e))


if __name__ == "__main__":
    main()
