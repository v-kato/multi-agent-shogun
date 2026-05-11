#!/usr/bin/env python3
"""
screenshot.py - CDPでスクリーンショットを取得する

Usage:
  python3 screenshot.py --out capture.png
  python3 screenshot.py --url-contains "dashboard" --out dashboard.png
  python3 screenshot.py --full-page --out fullpage.png
  python3 screenshot.py --quality 80 --out capture.jpg   # JPEG
"""

import argparse
import base64
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _bridge import cdp_send, get_first_target_id, die


def main():
    parser = argparse.ArgumentParser(description="CDPでスクリーンショット取得")
    parser.add_argument("--out", "-o", default="screenshot.png", help="保存先ファイルパス")
    parser.add_argument("--host", default="localhost")
    parser.add_argument("--port", type=int, default=9223)
    parser.add_argument("--timeout", type=int, default=15)
    parser.add_argument("--url-contains", metavar="TEXT", help="ターゲットURLフィルタ")
    parser.add_argument("--target-id", metavar="ID", help="ターゲットID直接指定")
    parser.add_argument("--full-page", action="store_true", help="フルページキャプチャ")
    parser.add_argument(
        "--format", choices=["png", "jpeg", "webp"], default="png",
        help="出力フォーマット"
    )
    parser.add_argument(
        "--quality", type=int, default=90,
        help="JPEG/WebP品質 (1-100)"
    )
    parser.add_argument(
        "--clip", metavar="x,y,w,h",
        help="クリップ領域 (例: 0,0,800,600)"
    )
    args = parser.parse_args()

    # ターゲット取得
    target_id = args.target_id or ""
    if not target_id:
        try:
            target_id = get_first_target_id(
                args.host, args.port, args.url_contains or "", args.timeout
            )
        except ConnectionError as e:
            die(str(e))

    # CDP Page.captureScreenshot パラメータ構築
    params: dict = {
        "format": args.format,
        "captureBeyondViewport": args.full_page,
    }
    if args.format != "png":
        params["quality"] = args.quality
    if args.clip:
        parts = args.clip.split(",")
        if len(parts) != 4:
            die("--clip の形式: x,y,w,h (例: 0,0,800,600)")
        x, y, w, h = (float(p) for p in parts)
        params["clip"] = {"x": x, "y": y, "width": w, "height": h, "scale": 1}

    try:
        resp = cdp_send(
            method="Page.captureScreenshot",
            params=params,
            host=args.host,
            port=args.port,
            target_id=target_id,
            timeout=args.timeout,
        )
    except (RuntimeError, ValueError) as e:
        die(str(e))

    data_b64 = resp.get("result", {}).get("result", {}).get("value")
    if not data_b64:
        # 一部のEdgeバージョンはネストが異なる
        data_b64 = resp.get("result", {}).get("data")

    if not data_b64:
        die(f"スクリーンショットデータが取得できませんでした\n{json.dumps(resp, indent=2)}")

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_bytes(base64.b64decode(data_b64))
    print(f"保存完了: {out_path.resolve()}")


if __name__ == "__main__":
    main()
