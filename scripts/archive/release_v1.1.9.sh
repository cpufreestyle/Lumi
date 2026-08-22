#!/bin/bash
# v1.1.9 发布脚本：打包 .app → 提交 → 打 tag → 建 GitHub Release
set -e
cd "$(dirname "$0")"

APP="Lumi/.build/Lumi.app"
ZIP="Lumi-v1.1.9.zip"
VERSION="v1.1.9"
MSG="v1.1.9: 新增游戏模块（面板内即点即玩 H5 小游戏）+ 更新检查与动态岛体验优化"

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
git commit -m "$MSG"

echo "🏷️  打 tag $VERSION"
git tag -a "$VERSION" -m "$MSG"

echo "🚀 推送"
git push origin main
git push origin "$VERSION"

echo "🌐 创建 GitHub Release"
gh release create "$VERSION" "$ZIP" \
  --title "$VERSION" \
  --notes "## 更新内容
- 新增「游戏」模块：面板内直接加载 H5 小游戏（默认《星球大合成》即点即玩），点开即用、可交互，面板自动放大到 480×600
- 手动检查更新：无论结果（已是最新/发现新版本/失败）都会给出明确反馈提示（图标变绿并显示提示条）
- 更新失败提示的「×」可正常关闭
- 更新检查改用 GitHub Release 页面 HTML 解析，绕过匿名 API 限流；1 小时间隔缓存 + 后台静默检查
- 动态岛热区：锁定常驻（islandPinned）时鼠标触碰仍自动显示
- 去除收缩态胶囊右侧顽固的模块切换小点
- 音乐模块展开态字号/布局随面板尺寸自适应
- 修复游戏 WebView 因 KVC 设未知 key 导致的闪退

> 安装：下载 Lumi-v1.1.9.zip，解压后将 Lumi.app 拖入应用程序。未签名应用首次运行若被拦截，可在系统设置→隐私与安全性中允许，或在终端执行 \`sudo spctl --master-disable\` 开启「任何来源」。"

echo "✅ 发布完成: https://github.com/cpufreestyle/Lumi/releases/tag/$VERSION"
