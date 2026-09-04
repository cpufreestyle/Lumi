#!/bin/bash
# v1.1.21 发布脚本：打包 .app → 提交 → 打 tag → 建 GitHub Release
set -e
cd "$(dirname "$0")"

APP="Lumi/.build/Lumi.app"
ZIP="Lumi-v1.1.21.zip"
VERSION="v1.1.21"
MSG="v1.1.21: 市场安装全程后台化——解压/去隔离/落位不再阻塞灵动岛 UI"

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
LUMI_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
# 从 git credential store 动态获取 token（不得硬编码，否则触发 GitHub Push Protection）
TOKEN=$(echo "url=https://github.com" | git credential fill 2>/dev/null | grep '^password=' | cut -d= -f2)
[ -z "$TOKEN" ] && { echo "❌ 未获取到 GitHub token"; exit 1; }

# 1. 更新版本号
echo "🔧 更新版本号 → 1.1.21"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.1.21" Lumi/Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 1.1.21" Lumi/Resources/Info.plist

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

# 4. 提交版本号变更
echo "📝 提交改动"
git add Lumi/Resources/Info.plist release_v1.1.21.sh
git commit -m "$MSG" || echo "（无新改动可提交）"

# 5. 打 tag + 推送
echo "🏷️  打 tag $VERSION"
git tag -a "$VERSION" -m "$MSG" || echo "（tag 已存在）"
git -c http.version=HTTP/1.1 push origin main
git -c http.version=HTTP/1.1 push origin "$VERSION"

# 6. 创建 GitHub Release
echo "🌐 创建 GitHub Release"
RESP=$(curl -s --retry 3 -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/cpufreestyle/Lumi/releases" \
  -d '{"tag_name":"v1.1.21","name":"v1.1.21","body":"## v1.1.21 更新内容\n\n- **市场安装不再卡 UI**：解压/去隔离/落位全部移交后台线程，安装大插件时灵动岛保持流畅，安装过程中显示「安装中」状态\n- 安装临时目录改用 UUID 隔离并发安装，完成后自动清理\n\n> 内部性能修复版；插件市场 HiDPI/占位面板等改进见 v1.1.20","draft":false,"prerelease":false}')
UPLOAD_ID=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id',''))")
echo "Release ID: $UPLOAD_ID"
if [ -n "$UPLOAD_ID" ]; then
  curl -s --retry 5 --retry-delay 5 -X POST \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/zip" \
    --data-binary @"$ZIP" \
    "https://uploads.github.com/repos/cpufreestyle/Lumi/releases/$UPLOAD_ID/assets?name=$ZIP" \
    | grep -o '"state":"[a-z]*"' | head -1
fi

echo "✅ 发布完成: https://github.com/cpufreestyle/Lumi/releases/tag/$VERSION"
