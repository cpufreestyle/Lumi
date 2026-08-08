#!/bin/bash
# v1.1.11 发布脚本：打包 .app → 提交 → 打 tag → 建 GitHub Release
# 注意：本次已手动执行过发布流程（commit 98ba3da / tag v1.1.11 / Release 已建）。
# 本脚本作为可复现的发布记录保留，与历史 release_v1.1.x.sh 保持一致。
set -e
cd "$(dirname "$0")"

APP="Lumi/.build/Lumi.app"
ZIP="Lumi-v1.1.11.zip"
VERSION="v1.1.11"
MSG="v1.1.11: 修复音乐/游戏空白 + 退出按钮 + 标签栏两行布局"

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

echo "🎵 编译 Lumi..."
(cd Lumi && swift build)
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
git add -A
git commit -m "$MSG" || echo "（无新改动可提交）"

echo "🏷️  打 tag $VERSION"
git tag -a "$VERSION" -m "$MSG" || echo "（tag 已存在）"

echo "🚀 推送"
git push origin main
git push origin "$VERSION"

echo "🌐 创建 GitHub Release"
gh release create "$VERSION" "$ZIP" \
  --title "$VERSION" \
  -F /tmp/lumi_release_v111.md \
  || gh release upload "$VERSION" "$ZIP" --clobber

echo "✅ 发布完成: https://github.com/cpufreestyle/Lumi/releases/tag/$VERSION"
