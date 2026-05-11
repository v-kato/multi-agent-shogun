#!/usr/bin/env python3
"""
eval.py - CDPでJavaScriptを実行する

Usage:
  python3 eval.py "document.title"
  python3 eval.py "document.querySelector('#price').innerText"
  python3 eval.py --file my_script.js
  python3 eval.py --url-contains "dashboard" "document.title"
  python3 eval.py --return-by-value "document.title"   # 値のみ出力
"""

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _bridge import cdp_send, get_first_target_id, die


def main():
    parser = argparse.ArgumentParser(description="CDPでJavaScriptを実行")
    parser.add_argument("expression", nargs="?", help="実行するJavaScript式")
    parser.add_argument("--file", "-f", help="JSファイルパス")
    parser.add_argument("--host", default="localhost")
    parser.add_argument("--port", type=int, default=9223)
    parser.add_argument("--timeout", type=int, default=10)
    parser.add_argument("--url-contains", metavar="TEXT", help="ターゲットURLフィルタ")
    parser.add_argument("--target-id", metavar="ID", help="ターゲットID直接指定")
    parser.add_argument(
        "--return-by-value", action="store_true",
        help="値のみ出力（JSONオブジェクトはJSON文字列として）"
    )
    parser.add_argument("--await", dest="await_promise", action="store_true",
                        help="Promiseを待機する")
    args = parser.parse_args()

    # 実行するJSを決定
    if args.file:
        expression = Path(args.file).read_text(encoding="utf-8")
    elif args.expression:
        expression = args.expression
    else:
        die("JSの式またはファイルを指定してください (例: eval.py 'document.title')")

    # ターゲット取得
    target_id = args.target_id or ""
    if not target_id:
        try:
            target_id = get_first_target_id(
                args.host, args.port, args.url_contains or "", args.timeout
            )
        except ConnectionError as e:
            die(str(e))

    # CDP Runtime.evaluate 実行
    try:
        resp = cdp_send(
            method="Runtime.evaluate",
            params={
                "expression": expression,
                "returnByValue": True,
                "awaitPromise": args.await_promise,
                "userGesture": True,
            },
            host=args.host,
            port=args.port,
            target_id=target_id,
            timeout=args.timeout,
        )
    except (RuntimeError, ValueError) as e:
        die(str(e))

    result = resp.get("result", {}).get("result", {})

    # 例外チェック
    if result.get("subtype") == "error":
        die(f"JS例外: {result.get('description', '不明なエラー')}")

    value = result.get("value")

    if args.return_by_value:
        if isinstance(value, (dict, list)):
            print(json.dumps(value, ensure_ascii=False))
        elif value is None:
            print("null")
        else:
            print(value)
    else:
        # フルレスポンスを整形表示
        print(json.dumps(resp, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
