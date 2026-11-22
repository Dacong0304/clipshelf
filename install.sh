#!/bin/bash
# 编译 ClipShelf 并安装到 ~/Applications（不需要 sudo，也不需要 Xcode 工程）
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

DEST="$HOME/Applications"
mkdir -p "$DEST"

# 先停掉旧实例，避免替换后新旧两个进程同时抓剪贴板
if pgrep -x ClipShelf >/dev/null 2>&1; then
  echo "停止正在运行的 ClipShelf …"
  pgrep -x ClipShelf | while read -r pid; do kill "$pid" 2>/dev/null || true; done
  sleep 1
fi

rm -rf "$DEST/ClipShelf.app"
cp -R "ClipShelf.app" "$DEST/"

# 去掉隔离属性，避免本机自编译产物被 Gatekeeper 拦
xattr -dr com.apple.quarantine "$DEST/ClipShelf.app" 2>/dev/null || true

# 如果之前开过开机自启，把它的路径刷新到新位置
PLIST="$HOME/Library/LaunchAgents/local.clipshelf.agent.plist"
if [ -f "$PLIST" ]; then
  launchctl bootout "gui/$(id -u)/local.clipshelf.agent" 2>/dev/null || true
  cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>local.clipshelf.agent</string>
	<key>ProgramArguments</key>
	<array><string>$DEST/ClipShelf.app/Contents/MacOS/ClipShelf</string></array>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><false/>
	<key>ProcessType</key><string>Interactive</string>
	<key>StandardErrorPath</key><string>/tmp/clipshelf.err.log</string>
</dict>
</plist>
PLISTEOF
  launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || true
  echo "已同步开机自启配置"
fi

open "$DEST/ClipShelf.app"

echo
echo "已安装：$DEST/ClipShelf.app"
echo "用法：  ⌥⌘V 打开剪贴历史，或点菜单栏的剪贴板图标"
echo "可选：  菜单里打开「自动粘贴权限…」后，回车可自动粘回原 App"
echo "可选：  菜单里打开「开机自动启动」"
