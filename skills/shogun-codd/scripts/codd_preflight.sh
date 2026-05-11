#!/usr/bin/env bash
# codd preflight check — v2.14.0 であることを確認
# Usage: bash skills/shogun-codd/scripts/codd_preflight.sh
# Exit code: 0=OK, 1=version mismatch or not installed

set -euo pipefail

REQUIRED_VERSION="2.14.0"

# codd が存在するか確認
if ! command -v codd &>/dev/null; then
    echo "❌ [codd_preflight] codd コマンドが見つかりません。" >&2
    echo "   インストール: pipx install codd-dev" >&2
    exit 1
fi

# バージョン取得
ACTUAL_VERSION=$(codd --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown")

if [ "$ACTUAL_VERSION" = "$REQUIRED_VERSION" ]; then
    echo "✅ [codd_preflight] codd v${ACTUAL_VERSION} — OK"
    exit 0
else
    echo "⚠️  [codd_preflight] codd バージョン不一致!" >&2
    echo "   必要: v${REQUIRED_VERSION}  実際: v${ACTUAL_VERSION}" >&2
    echo "   codd の仕様変更により Wave 生成が失敗する可能性があります。" >&2
    echo "   アップグレード: pipx upgrade codd-dev" >&2
    exit 1
fi
