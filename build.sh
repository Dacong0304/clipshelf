#!/bin/bash
# 构建 ClipShelf.app（只需要 Command Line Tools 里的 swiftc，不需要 Xcode 工程）
set -euo pipefail
cd "$(dirname "$0")"

APP="ClipShelf.app"
BIN="$APP/Contents/MacOS/ClipShelf"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "编译 Sources/*.swift …"
swiftc -O -swift-version 5 \
  -framework AppKit -framework SwiftUI -framework Carbon -lsqlite3 \
  -o "$BIN" Sources/*.swift

cp Info.plist "$APP/Contents/Info.plist"
if [ -f AppIcon.icns ]; then
  cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
  echo "⚠ 缺少 AppIcon.icns，先执行：python3 design/icon.py icns"
fi

# 本地临时签名，避免 Gatekeeper 对未签名包的骚扰（无证书也能过）
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "完成：$(pwd)/$APP"
echo "自检：'$BIN' --selftest"
