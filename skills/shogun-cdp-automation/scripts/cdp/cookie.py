#!/usr/bin/env python3
"""
cookie.py - CDPでCookieを管理する

Usage:
  python3 cookie.py get
  python3 cookie.py get --domain example.com
  python3 cookie.py set --name "session" --value "abc123" --domain "example.com"
  python3 cookie.py delete --name "session" --domain "example.com"
  python3 cookie.py clear
  python3 cookie.py export --out cookies.json
  python3 cookie.py import --file cookies.json
"""

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _bridge import cdp_send, get_first_target_id, die


def main():
    parser = argparse.ArgumentParser(description="CDPでCookie管理")
    sub = parser.add_subparsers(dest="action", required=True)

    # get
    p_get = sub.add_parser("get", help="Cookie一覧取得")
    p_get.add_argument("--domain", help="ドメインフィルタ")
    p_get.add_argument("--name", help="名前フィルタ")
    p_get.add_argument("--json", dest="as_json", action="store_true", help="JSON出力")

    # set
    p_set = sub.add_parser("set", help="Cookieを設定")
    p_set.add_argument("--name", required=True)
    p_set.add_argument("--value", required=True)
    p_set.add_argument("--domain", required=True)
    p_set.add_argument("--path", default="/")
    p_set.add_argument("--expires", type=float, help="有効期限（UNIXタイムスタンプ）")
    p_set.add_argument("--secure", action="store_true")
    p_set.add_argument("--http-only", action="store_true")
    p_set.add_argument("--same-site", choices=["Strict", "Lax", "None"], default="Lax")

    # delete
    p_del = sub.add_parser("delete", help="Cookieを削除")
    p_del.add_argument("--name", required=True)
    p_del.add_argument("--domain", help="ドメイン（指定推奨）")
    p_del.add_argument("--url", help="URL指定でCookieを特定")

    # clear
    sub.add_parser("clear", help="全Cookie削除")

    # export
    p_exp = sub.add_parser("export", help="CookieをJSONファイルにエクスポート")
    p_exp.add_argument("--out", default="cookies.json")

    # import
    p_imp = sub.add_parser("import", help="JSONファイルからCookieをインポート")
    p_imp.add_argument("--file", required=True)

    # common options
    for p in [p_get, p_set, p_del, sub.choices.get("clear"), p_exp, p_imp]:
        if p:
            p.add_argument("--host", default="localhost")
            p.add_argument("--port", type=int, default=9223)
            p.add_argument("--timeout", type=int, default=10)
            p.add_argument("--url-contains", metavar="TEXT", help="ターゲットURLフィルタ")
            p.add_argument("--target-id", metavar="ID", help="ターゲットID直接指定")

    args = parser.parse_args()

    target_id = getattr(args, "target_id", "") or ""
    url_contains = getattr(args, "url_contains", "") or ""
    host = getattr(args, "host", "localhost")
    port = getattr(args, "port", 9223)
    timeout = getattr(args, "timeout", 10)

    if not target_id:
        try:
            target_id = get_first_target_id(host, port, url_contains, timeout)
        except ConnectionError as e:
            die(str(e))

    def send(method, params):
        return cdp_send(method, params, host, port, target_id=target_id, timeout=timeout)

    try:
        if args.action == "get":
            resp = send("Network.getAllCookies", {})
            cookies = resp.get("result", {}).get("cookies", [])
            if args.domain:
                cookies = [c for c in cookies if args.domain in c.get("domain", "")]
            if args.name:
                cookies = [c for c in cookies if c.get("name") == args.name]
            if args.as_json:
                print(json.dumps(cookies, ensure_ascii=False, indent=2))
            else:
                print(f"Cookie数: {len(cookies)}")
                for c in cookies:
                    expires = f" (expires: {c.get('expires', 'session')})" if c.get("expires", -1) > 0 else ""
                    print(f"  {c.get('name')}={c.get('value')!r}"
                          f"  domain={c.get('domain')}{expires}")

        elif args.action == "set":
            params = {
                "name": args.name,
                "value": args.value,
                "domain": args.domain,
                "path": args.path,
                "secure": args.secure,
                "httpOnly": args.http_only,
                "sameSite": args.same_site,
            }
            if args.expires:
                params["expires"] = args.expires
            resp = send("Network.setCookie", params)
            success = resp.get("result", {}).get("success", False)
            if success:
                print(f"Cookie設定完了: {args.name}={args.value!r} @ {args.domain}")
            else:
                die("Cookie設定失敗")

        elif args.action == "delete":
            params = {"name": args.name}
            if args.url:
                params["url"] = args.url
            if args.domain:
                params["domain"] = args.domain
            send("Network.deleteCookies", params)
            print(f"Cookie削除完了: {args.name}")

        elif args.action == "clear":
            send("Network.clearBrowserCookies", {})
            print("全Cookie削除完了")

        elif args.action == "export":
            resp = send("Network.getAllCookies", {})
            cookies = resp.get("result", {}).get("cookies", [])
            Path(args.out).write_text(
                json.dumps(cookies, ensure_ascii=False, indent=2), encoding="utf-8"
            )
            print(f"エクスポート完了: {args.out} ({len(cookies)}件)")

        elif args.action == "import":
            cookies = json.loads(Path(args.file).read_text(encoding="utf-8"))
            ok = ng = 0
            for cookie in cookies:
                # 不要フィールド除去
                cookie.pop("session", None)
                cookie.pop("size", None)
                try:
                    resp = send("Network.setCookie", cookie)
                    if resp.get("result", {}).get("success"):
                        ok += 1
                    else:
                        ng += 1
                except Exception:
                    ng += 1
            print(f"インポート完了: {ok}件成功 / {ng}件失敗")

    except (RuntimeError, ValueError) as e:
        die(str(e))


if __name__ == "__main__":
    main()
