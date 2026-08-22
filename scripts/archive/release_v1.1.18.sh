#!/bin/bash
# v1.1.18 发布脚本：打包 .app → 提交 → 打 tag → 建 GitHub Release
set -e
cd "$(dirname "$0")"

APP="Lumi/.build/Lumi.app"
ZIP="Lumi-v1.1.18.zip"
VERSION="v1.1.18"
MSG="v1.1.18: 收缩态胶囊精简——歌词静态显示、移除歌名与预览卡片、宽度手柄移至右侧"

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# 1. 更新版本号
echo "🔧 更新版本号 → 1.1.18"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.1.18" Lumi/Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 1.1.18" Lumi/Resources/Info.plist

# 2. 编译
echo "🎵 编译 Lumi..."
(cd Lumi && swift build)

# 3. 打包
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

# 4. 提交
echo "📝 提交改动"
git add -A
git commit -m "$MSG" || echo "（无新改动可提交）"

# 5. 打 tag + 推送
echo "🏷️  打 tag $VERSION"
git tag -a "$VERSION" -m "$MSG" || echo "（tag 已存在）"
git push origin main
git push origin "$VERSION"

# 6. 生成 release notes
cat > /tmp/lumi_release_notes.md <<'EOF'
## v1.1.18 更新内容

- 收缩态胶囊歌词改为**静态居中显示**，移除跑马灯滚动效果
- 移除胶囊内歌名与悬停预览卡片，胶囊更精简
- 宽度拉宽手柄移至胶囊**右侧竖直居中**，拖拽只改宽度、高度不变
EOF

# 7. 创建 GitHub Release
echo "🌐 创建 GitHub Release"
gh release create "$VERSION" "$ZIP" \
  --title "$VERSION" \
  -F /tmp/lumi_release_notes.md \
  || gh release upload "$VERSION" "$ZIP" --clobber

echo "✅ 发布完成: https://github.com/cpufreestyle/Lumi/releases/tag/$VERSION"
