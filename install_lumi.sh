#!/bin/bash
# 构建并安装 Lumi 到 /Applications
set -e
cd "$(dirname "$0")"

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

echo "🎵 编译 Lumi..."
(cd Lumi && swift build)
echo "✅ 编译完成"

APP="Lumi/.build/Lumi.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "Lumi/.build/debug/Lumi" "$APP/Contents/MacOS/Lumi"
cp "Lumi/Resources/Info.plist" "$APP/Contents/Info.plist"
[ -f "Lumi/Resources/AppIcon.icns" ] && cp "Lumi/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign - "$APP" 2>/dev/null || true
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
echo "✅ 打包完成: $APP"

# 关闭当前运行实例（按 bundle id）
osascript -e 'tell application id "com.lumi.app" to quit' 2>/dev/null || true
sleep 1

# 安装到 /Applications
DEST="/Applications/Lumi.app"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
codesign --force --deep --sign - "$DEST" 2>/dev/null || true

echo "INSTALLED_OK -> $DEST"
open "$DEST"
echo "LAUNCHED_OK"
