#!/bin/bash
# v1.1.20 发布脚本：打包 .app → 提交 → 打 tag → 建 GitHub Release
set -e
cd "$(dirname "$0")"

APP="Lumi/.build/Lumi.app"
ZIP="Lumi-v1.1.20.zip"
VERSION="v1.1.20"
MSG="v1.1.20: 架构优化——拆分巨型文件、单测 10→41、修复并发问题、插件市场修复"

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
LUMI_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
# 从 git credential store 动态获取 token（不得硬编码，否则触发 GitHub Push Protection）
TOKEN=$(echo "url=https://github.com" | git credential fill 2>/dev/null | grep '^password=' | cut -d= -f2)
[ -z "$TOKEN" ] && { echo "❌ 未获取到 GitHub token"; exit 1; }

# 1. 更新版本号
echo "🔧 更新版本号 → 1.1.20"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.1.20" Lumi/Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 1.1.20" Lumi/Resources/Info.plist

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
git add Lumi/Resources/Info.plist release_v1.1.20.sh
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
  -d '{"tag_name":"v1.1.20","name":"v1.1.20","body":"## v1.1.20 更新内容\n\n### 架构与质量\n- 拆分 ContentView/main/MusicController 三个巨型文件为职责单一模块\n- 单元测试 10 → 41 用例（激活码验证/插件清单/更新器）\n- 修复 4 处并发与主线程问题（数据竞争 x2、主线程 I/O、无锁数组写）\n\n### 插件系统\n- 修复下载包偶发安装失败（URLSession 临时文件生命周期）\n- 插件标签无数据时显示占位面板，不再回退音乐\n- 移除插件模块调试日志\n\n### 交互\n- 动态岛 hover-only：鼠标离开刘海即收起，双击刘海切换固定\n- yt-dlp 路径解析支持 brew symlink 与 PATH 优先","draft":false,"prerelease":false}')
UPLOAD_ID=$(echo "$RESP" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
echo "Release ID: $UPLOAD_ID"
if [ -n "$UPLOAD_ID" ]; then
  # 上传主程序 zip（--retry 5 抗网络抖动）
  curl -s --retry 5 --retry-delay 5 -X POST \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/zip" \
    --data-binary @"$ZIP" \
    "https://uploads.github.com/repos/cpufreestyle/Lumi/releases/$UPLOAD_ID/assets?name=$ZIP" \
    | grep -o '"state":"[a-z]*"' | head -1
fi

echo "✅ 发布完成: https://github.com/cpufreestyle/Lumi/releases/tag/$VERSION"
