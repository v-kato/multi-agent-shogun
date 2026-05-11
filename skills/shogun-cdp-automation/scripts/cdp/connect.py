#!/usr/bin/env python3
"""
connect.py - CDP接続確認・ターゲット一覧表示

WSL2からEdge/ChromeのCDPエンドポイントに接続し、
利用可能なページ（タブ）の一覧を表示する。

Usage:
  python3 connect.py
  python3 connect.py --port 9223
  python3 connect.py --first-id         # 最初のターゲットIDのみ出力
  python3 connect.py --url-contains foo # URLにfooを含むターゲットのみ
"""

import argparse
import json
import sys
import subprocess


def get_targets(host: str, port: int, timeout: int = 5) -> list[dict]:
    """ps-bridge.ps1経由でCDPターゲット一覧を取得する。"""
    script_path = _ps_bridge_path()
    cmd = [
        "powershell.exe", "-ExecutionPolicy", "Bypass",
        "-File", script_path,
        "-Action", "list",
        "-CdpHost", host,
        "-Port", str(port),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout + 5)
    if result.returncode != 0:
        raise ConnectionError(
            f"CDP connection failed (port={port}): {result.stderr.strip()}"
        )
    raw = result.stdout.strip()
    if not raw:
        return []
    data = json.loads(raw)
    # PowerShellは単一オブジェクトをdictで返す場合がある
    if isinstance(data, dict):
        return [data]
    return data


def _ps_bridge_path() -> str:
    """ps-bridge.ps1のWindowsパスを返す。"""
    import os
    script_dir = os.path.dirname(os.path.abspath(__file__))
    ps_path = os.path.join(script_dir, "..", "ps-bridge.ps1")
    ps_path = os.path.normpath(ps_path)
    # WSLパス → Windowsパス変換
    result = subprocess.run(
        ["wslpath", "-w", ps_path], capture_output=True, text=True
    )
    if result.returncode == 0:
        return result.stdout.strip()
    return ps_path


def main():
    parser = argparse.ArgumentParser(description="CDP接続確認・ターゲット一覧")
    parser.add_argument("--host", default="localhost", help="CDPホスト")
    parser.add_argument("--port", type=int, default=9223, help="CDPポート番号")
    parser.add_argument("--timeout", type=int, default=5, help="タイムアウト秒数")
    parser.add_argument("--url-contains", metavar="TEXT", help="URLフィルタ")
    parser.add_argument("--first-id", action="store_true", help="最初のターゲットIDのみ出力")
    parser.add_argument("--json", action="store_true", help="JSON形式で出力")
    args = parser.parse_args()

    try:
        targets = get_targets(args.host, args.port, args.timeout)
    except ConnectionError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        print("\nTip: EdgeをCDPモードで起動してください:", file=sys.stderr)
        print(
            '  powershell.exe -ExecutionPolicy Bypass -File '
            '"<path>/ps-bridge.ps1" -Action start',
            file=sys.stderr,
        )
        sys.exit(1)
    except subprocess.TimeoutExpired:
        print(f"ERROR: タイムアウト ({args.timeout}s)", file=sys.stderr)
        sys.exit(1)

    if args.url_contains:
        targets = [t for t in targets if args.url_contains in t.get("url", "")]

    if not targets:
        print("ターゲットが見つかりません。", file=sys.stderr)
        sys.exit(1)

    if args.first_id:
        print(targets[0].get("id", ""))
        return

    if args.json:
        print(json.dumps(targets, ensure_ascii=False, indent=2))
        return

    print(f"CDP接続成功 ({args.host}:{args.port}) — {len(targets)}ページ\n")
    for i, t in enumerate(targets):
        print(f"  [{i}] {t.get('title', '(no title)')}")
        print(f"       url: {t.get('url', '')}")
        print(f"       id:  {t.get('id', '')}")


if __name__ == "__main__":
    main()
