#!/bin/bash
# 生成 Lumi 桌面快捷方式（与应用本体同一套 Apple 风格图标）
#
# 背景：Lumi 声明 LSUIElement=true，是 agent app：没有 Dock 图标、访达里也不显示，
# 装完只能从启动台或 Spotlight 找，桌面天然没入口。
#
# 产物：
#   1) /Applications/Lumi.app  正式安装位（当前构建产物 + 新图标）
#   2) ~/Desktop/Lumi.app      迷你启动器，双击即拉起正式版；已在跑时只唤醒、不重复起进程
#
# 用法：bash tools/make_desktop_shortcut.sh   （在 Lumi/ 目录下执行）
set -euo pipefail
cd "$(dirname "$0")/.."

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
if [[ -f "$SDK" ]]; then SDKARG="--sdk $SDK"; else SDKARG=""; fi

SRC=".build/Lumi.app"
INSTALL="/Applications/Lumi.app"
DESKTOP="$HOME/Desktop/Lumi.app"
VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)

# —— 1) 编译并打包（preview_restart.sh 内含打包 + 启动自校验）——
echo "[1/4] 编译并打包 $SRC ..."
bash preview_restart.sh >/dev/null

# —— 2) 安装到 /Applications（正式安装位）——
echo "[2/4] 安装到 $INSTALL ..."
if [[ -d "$INSTALL" ]]; then rm -rf "$INSTALL"; fi
cp -R "$SRC" "$INSTALL"
xattr -dr com.apple.quarantine "$INSTALL" 2>/dev/null || true

# —— 3) 桌面放 mini 启动器（不拷 14MB 二进制：用 shell 脚本做 exec，只占几 KB）——
echo "[3/4] 生成桌面启动器 $DESKTOP ..."
mkdir -p "$DESKTOP/Contents/MacOS" "$DESKTOP/Contents/Resources"
cat > "$DESKTOP/Contents/MacOS/Lumi" <<'LAUNCHER'
#!/bin/bash
# Lumi 桌面启动器：优先启动 /Applications 的正式版，找不到再回退到源构建产物。
# agent app 没有 Dock 图标，重复启动只会多一个进程，所以已在跑时只唤醒、不重启。
set -euo pipefail
for CAND in \
  "/Applications/Lumi.app" \
  "/Users/a1-6/AI Shared/repo/Lumi/Lumi/.build/Lumi.app"; do
  if [[ -x "$CAND/Contents/MacOS/Lumi" ]]; then
    if pgrep -x Lumi >/dev/null 2>&1; then
      open -b com.lumi.app 2>/dev/null || open "$CAND"
    else
      open "$CAND"
    fi
    exit 0
  fi
done
echo "未找到 Lumi.app，请先运行 tools/make_desktop_shortcut.sh" >&2
exit 1
LAUNCHER
chmod +x "$DESKTOP/Contents/MacOS/Lumi"

# —— 4) 打上同一套图标 + Info.plist（别让访达显示默认图标）——
echo "[4/4] 写入图标与 Info.plist ..."
cp Resources/AppIcon.icns "$DESKTOP/Contents/Resources/AppIcon.icns"
cat > "$DESKTOP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>CFBundleExecutable</key>
    <string>Lumi</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon.icns</string>
    <key>CFBundleIdentifier</key>
    <string>com.lumi.app.desktop</string>
    <key>CFBundleName</key>
    <string>Lumi</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VER</string>
    <key>CFBundleVersion</key>
    <string>$VER</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
  </dict>
</plist>
PLIST

# 刷新访达缓存，让图标立刻生效（否则要等几秒或重新登录才显示）
touch "$DESKTOP"

echo
echo "完成："
echo "  安装位 $INSTALL (v$VER)"
echo "  桌面   $DESKTOP"
echo "  图标   $(md5 -q Resources/AppIcon.icns)"
