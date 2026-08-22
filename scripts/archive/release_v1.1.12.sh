#!/bin/bash
# v1.1.12 发布脚本：打包 .app → 提交 → 打 tag → 建 GitHub Release
# 与历史 release_v1.1.x.sh 保持一致，但改进：
#  - 使用 clean build 确保源码改动确实编入 .app（此前 SwiftPM 缓存曾导致改动未生效）
#  - git add 仅指定源码文件，避免误提交 .codebuddy/ 工作记忆
set -e
cd "$(dirname "$0")"

APP="Lumi/.build/Lumi.app"
ZIP="Lumi-v1.1.12.zip"
VERSION="v1.1.12"
MSG="v1.1.12: 小胶囊歌词撑大 + 音乐页头部收纳歌手名与固定标志 + 权限徽标仅限插件分页 + 已安装列表模块仅放入天气插件"

# 要提交的源码改动（显式列出，不 git add -A）
FILES=(
  "Lumi/Sources/Lumi/Modules/Music/MusicViews.swift"
  "Lumi/Sources/Lumi/Views/ContentView.swift"
  "Lumi/Sources/Lumi/Views/PluginPanelView.swift"
  "Lumi/Sources/Lumi/Views/PluginSection.swift"
)

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

echo "🎵 编译 Lumi (clean build)..."
(cd Lumi && swift package clean && swift build)
echo "✅ 编译完成"

echo "📦 打包 $APP → $ZIP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "Lumi/.build/debug/Lumi" "$APP/Contents/MacOS/Lumi"
cp "Lumi/Resources/Info.plist" "$APP/Contents/Info.plist"
[ -f "Lumi/Resources/AppIcon.icns" ] && cp "Lumi/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign - "$APP" 2>/dev/null || true
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "✅ $ZIP ($(du -h "$ZIP" | cut -f1))"

echo "📝 提交改动"
git add "${FILES[@]}"
git commit -m "$MSG" || echo "（无新改动可提交）"

echo "🏷️  打 tag $VERSION"
git tag -a "$VERSION" -m "$MSG" || echo "（tag 已存在）"

echo "🚀 推送"
git push origin main
git push origin "$VERSION"

echo "🌐 创建 GitHub Release"
gh release create "$VERSION" "$ZIP" \
  --title "$VERSION" \
  -F /tmp/lumi_release_v1112.md \
  || gh release upload "$VERSION" "$ZIP" --clobber

echo "✅ 发布完成: https://github.com/cpufreestyle/Lumi/releases/tag/$VERSION"
