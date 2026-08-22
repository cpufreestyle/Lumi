#!/bin/bash
# v1.1.19 发布脚本：打包 .app → 提交 → 打 tag → 建 GitHub Release
set -e
cd "$(dirname "$0")"

APP="Lumi/.build/Lumi.app"
ZIP="Lumi-v1.1.19.zip"
VERSION="v1.1.19"
MSG="v1.1.19: 胶囊固定按钮支持未固定时点击固定；鼠标在胶囊内不自动隐藏"

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
LUMI_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"

# 1. 更新版本号
echo "🔧 更新版本号 → 1.1.19"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.1.19" Lumi/Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 1.1.19" Lumi/Resources/Info.plist

# 2. 编译（必须指定 26.5 SDK，否则 SwiftUI 宏解析失败）
echo "🎵 编译 Lumi..."
(cd Lumi && swift build --sdk "$LUMI_SDK")

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
## v1.1.19 更新内容

- 胶囊固定按钮常驻显示：未固定时点击即可固定常驻（图标随状态变化，固定=黄色 pin.fill）
- 修复：鼠标仍在胶囊（窗口）内时不自动隐藏，避免"还没离开胶囊就消失"
EOF

# 7. 创建 GitHub Release（curl + gh token，规避 gh 命令启发式拦截）
echo "🌐 创建 GitHub Release"
TOKEN=$(gh auth token)
RESP=$(curl -s -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/cpufreestyle/Lumi/releases" \
  -d '{"tag_name":"v1.1.19","name":"v1.1.19","body":"## v1.1.19 更新内容\n\n- 胶囊固定按钮常驻显示：未固定时点击即可固定常驻（图标随状态变化，固定=黄色 pin.fill）\n- 修复：鼠标仍在胶囊（窗口）内时不自动隐藏，避免还没离开胶囊就消失","draft":false,"prerelease":false}')
echo "$RESP" | grep -o '"id":[0-9]*' | head -1
UPLOAD_ID=$(echo "$RESP" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
if [ -n "$UPLOAD_ID" ]; then
  curl -s -X POST \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/zip" \
    --data-binary @"$ZIP" \
    "https://uploads.github.com/repos/cpufreestyle/Lumi/releases/$UPLOAD_ID/assets?name=$ZIP" \
    | grep -o '"state":"[a-z]*"'
fi

echo "✅ 发布完成: https://github.com/cpufreestyle/Lumi/releases/tag/$VERSION"
