#!/bin/bash
# v1.2.0 发布脚本：打包 .app → 提交 → 打 tag → 建 GitHub Release
set -e
cd "$(dirname "$0")"

APP="Lumi/.build/Lumi.app"
ZIP="Lumi-v1.2.0.zip"
VERSION="v1.2.0"
MSG="v1.2.0: Liquid Glass 苹果 UI 改造 + 模块分层重构 + AI/听写/TV 新模块"

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
LUMI_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
# 从 git credential store 动态获取 token（不得硬编码，否则触发 GitHub Push Protection）
TOKEN=$(echo "url=https://github.com" | git credential fill 2>/dev/null | grep '^password=' | cut -d= -f2)
[ -z "$TOKEN" ] && { echo "❌ 未获取到 GitHub token"; exit 1; }

# 1. 更新版本号（幂等：已为 1.2.0 时重复设置无副作用）
echo "🔧 更新版本号 → 1.2.0"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.2.0" Lumi/Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 1.2.0" Lumi/Resources/Info.plist

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
# SwiftPM 资源包（插件市场离线 feed）
[ -d "Lumi/.build/debug/Lumi_Lumi.bundle" ] && cp -R "Lumi/.build/debug/Lumi_Lumi.bundle" "$APP/Contents/Resources/"
codesign --force --deep --sign - "$APP" 2>/dev/null || true
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "✅ $ZIP ($(du -h "$ZIP" | cut -f1))"

# 4. 提交（版本号/脚本变动；无改动时跳过）
echo "📝 提交改动"
git add Lumi/Resources/Info.plist release_v1.2.0.sh
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
  -d '{"tag_name":"v1.2.0","name":"v1.2.0","body":"## v1.2.0 更新内容\n\n- **Liquid Glass 苹果 UI 改造**：展开面板、音量 HUD、提示条、许可证面板等浮层改用 macOS 26 系统玻璃，旧系统（< 26）自动回退手搓材质；收缩态胶囊保持纯黑，继续 1:1 贴合真刘海\n- **模块分层重构**：14 个单体文件拆为各模块 Views/Controllers/Models/Services 目录\n- **新增模块**：AIAssist（AI 动作条）、CLIUsage（CLI 用量统计）、Dictation（语音听写）、TV（电视遥控）\n- **桌面歌词**：右键短按切换播放/暂停，与胶囊同一套键位观（左键拖拽 / 中键切歌 / 滚轮字号 / 右键播控）\n- **快捷键提示可发现化**：菜单栏图标菜单新增「快捷键与手势说明」面板（不再只藏在胶囊右键长按里），胶囊右键菜单文案改与面板同源；新增 KeyboardShortcutCatalog 单一数据源 + 8 条不变量测试\n- **标签栏固定两行**：布局计算抽为纯逻辑 TabBarLayout 并由测试守护\n- 质量：swift build 通过、559 个单元测试全部通过（含快捷键目录与全局快捷键匹配不变量测试）\n\n> 版本 1.1.21 → 1.2.0","draft":false,"prerelease":false}')
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
