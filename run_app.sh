#!/bin/bash
# =====================================================
#  Lumi — macOS App 一键构建并启动
#  用法:
#    ./run_app.sh          编译 → 打包 .app → 签名 → 启动
#    ./run_app.sh nobuild  跳过编译，仅打包已存在的二进制并启动
#    ./run_app.sh quit     退出正在运行的 Lumi
# =====================================================
set -e
cd "$(dirname "$0")"

# 使用完整 Xcode 工具链以正确编译 SwiftUI 宏
if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

APP="Lumi/.build/Lumi.app"
BIN_DIR="Lumi/.build"
SRC="Lumi/.build/debug/Lumi"

# ---------- 退出 ----------
if [ "${1:-}" = "quit" ]; then
  osascript -e 'tell application id "com.lumi.app" to quit' 2>/dev/null || \
    for pid in $(pgrep -f "Contents/MacOS/Lumi"); do kill "$pid" 2>/dev/null; done
  echo "已请求退出 Lumi"
  exit 0
fi

# ---------- 编译 ----------
if [ "${1:-}" != "nobuild" ]; then
  echo "🎵 正在编译 Lumi..."
  (cd Lumi && swift build)
  echo "✅ 编译完成"
fi

# ---------- 打包 ----------
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SRC" "$APP/Contents/MacOS/Lumi"
cp "Lumi/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "Lumi/Resources/AppIcon.icns" ]; then
  cp "Lumi/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
echo "✅ 已打包 $APP"

# ---------- 签名并启动 ----------
codesign --force --deep --sign - "$APP" 2>/dev/null || true
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
osascript -e 'tell application id "com.lumi.app" to quit' 2>/dev/null || true
sleep 1
echo "🚀 正在启动 Lumi..."
open "$APP"
echo "LAUNCHED_OK"
