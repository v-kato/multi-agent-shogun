"""
_bridge.py - CDPコマンド送信の共通ユーティリティ

各スクリプトが import して使う内部モジュール。
直接実行しない。
"""

import base64
import json
import os
import subprocess
import sys


def ps_bridge_win_path() -> str:
    """ps-bridge.ps1のWindowsパスを返す。"""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    ps_path = os.path.normpath(os.path.join(script_dir, "..", "ps-bridge.ps1"))
    result = subprocess.run(
        ["wslpath", "-w", ps_path], capture_output=True, text=True
    )
    return result.stdout.strip() if result.returncode == 0 else ps_path


def cdp_send(
    method: str,
    params: dict,
    host: str = "localhost",
    port: int = 9223,
    url_contains: str = "",
    target_id: str = "",
    timeout: int = 10,
    cmd_id: int = 1,
) -> dict:
    """
    CDPコマンドをps-bridge.ps1経由で送信し、レスポンスを返す。

    Args:
        method: CDPメソッド名 (e.g., "Runtime.evaluate")
        params: CDPパラメータ dict
        host, port: CDP接続先
        url_contains: ターゲットURLフィルタ
        target_id: ターゲットID (直接指定)
        timeout: タイムアウト秒数
        cmd_id: CDP commandのid

    Returns:
        CDPレスポンスのdict

    Raises:
        RuntimeError: PS bridge呼び出し失敗
        ValueError: CDPレスポンスにerrorフィールドがある場合
    """
    payload = json.dumps({"id": cmd_id, "method": method, "params": params})
    payload_b64 = base64.b64encode(payload.encode("utf-8")).decode("ascii")

    cmd = [
        "powershell.exe", "-ExecutionPolicy", "Bypass",
        "-File", ps_bridge_win_path(),
        "-Action", "send",
        "-CdpHost", host,
        "-Port", str(port),
        "-PayloadBase64", payload_b64,
        "-TimeoutMs", str(timeout * 1000),
    ]
    if target_id:
        cmd += ["-TargetId", target_id]

    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout + 10
        )
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"PS bridge timeout ({timeout}s)")

    if result.returncode != 0:
        raise RuntimeError(
            f"PS bridge error (exit={result.returncode}): {result.stderr.strip()}"
        )

    raw = result.stdout.strip()
    if not raw:
        raise RuntimeError("PS bridge returned empty response")

    data = json.loads(raw)
    if "error" in data:
        raise ValueError(f"CDP error: {data['error']}")
    return data


def get_first_target_id(
    host: str = "localhost",
    port: int = 9223,
    url_contains: str = "",
    timeout: int = 5,
) -> str:
    """利用可能なターゲットの最初のIDを返す。"""
    cmd = [
        "powershell.exe", "-ExecutionPolicy", "Bypass",
        "-File", ps_bridge_win_path(),
        "-Action", "list",
        "-CdpHost", host,
        "-Port", str(port),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout + 5)
    if result.returncode != 0:
        raise ConnectionError(
            f"CDP接続失敗 (port={port}): {result.stderr.strip()}"
        )
    raw = result.stdout.strip()
    if not raw:
        raise ConnectionError("CDPターゲットが見つかりません")

    targets = json.loads(raw)
    if isinstance(targets, dict):
        targets = [targets]

    if url_contains:
        targets = [t for t in targets if url_contains in t.get("url", "")]

    if not targets:
        raise ConnectionError(
            f"URLに '{url_contains}' を含むターゲットが見つかりません"
        )
    return targets[0].get("id", "")


def die(msg: str, code: int = 1) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(code)
