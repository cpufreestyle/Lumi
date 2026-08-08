#!/bin/bash
# v1.1.8 发布脚本：打包 .app → 提交 → 打 tag → 建 GitHub Release
set -e
cd "$(dirname "$0")"

APP="Lumi/.build/Lumi.app"
ZIP="Lumi-v1.1.8.zip"
VERSION="v1.1.8"
MSG="v1.1.8: 新增菜单栏图标入口（修复无辅助功能权限时动态岛无法触发的问题）"

echo "📦 打包 $APP → $ZIP"
rm -f "$ZIP"
# 用 ditto 保留资源分叉与签名信息
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
- 新增菜单栏（Status Bar）图标入口：点击可手动显示/隐藏动态岛
- 修复 ad-hoc 签名每次重新打包导致辅助功能授权失效、全局鼠标监控无法触发动态岛的问题
- 辅助功能 TCC 授权脚本补充 kTCCServiceAccessibility

> 安装：下载 Lumi-v1.1.8.zip，解压后将 Lumi.app 拖入应用程序，首次运行若提示辅助功能可在系统设置中跳过（菜单栏图标无需该权限）。"

echo "✅ 发布完成: https://github.com/cpufreestyle/Lumi/releases/tag/$VERSION"
