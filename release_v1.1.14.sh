#!/bin/bash
# v1.1.14 发布脚本：clean build → 打包 .app → 打 tag → push → 建 Release 并上传两个资产
#
# 约定（见 .codebuddy/memory/MEMORY.md）：
#  - clean build 确保源码/Info.plist 改动确实编入 .app
#  - 发布走 GitHub API：先 `gh auth token` 取 token，再用 `curl` 调 API 创建 Release 并上传 zip，
#    不直接用 `gh release` 命令（会被交互启发式拦截）
#  - 版本号一致性：Info.plist 的 CFBundleShortVersionString = 1.1.14，与 tag v1.1.14、Updater 一致
#  - 本次代码改动（插件市场 0b13712 + SDK 文档 e61bc1d）已先行提交，故本脚本只负责构建/tag/push/发布
set -e

cd "$(dirname "$0")"

APP="Lumi/.build/Lumi.app"
ZIP="Lumi-v1.1.14.zip"
PLUGIN_ZIP="Lumi/LumiSamplePlugin.app.zip"
VERSION="v1.1.14"
REPO="cpufreestyle/Lumi"
MSG="v1.1.14: 插件市场（常驻入口/分类/详情/一键安装更新卸载/多源/版本检测）+ 第三方插件开发指南与零编译 L3 演示"

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

# 示例插件 zip 必须存在（市场「安装」按钮下载地址指向它）
if [ ! -f "$PLUGIN_ZIP" ]; then
  echo "❌ 缺少示例插件 zip：$PLUGIN_ZIP，请先运行 Lumi/make_sample_plugin.sh --zip" >&2
  exit 1
fi

echo "🏷️  打 tag $VERSION"
git tag -a "$VERSION" -m "$MSG" || echo "（tag 已存在）"

echo "🚀 推送 main + tag"
git push origin main
git push origin "$VERSION"

echo "🌐 用 GitHub API 创建 Release 并上传两个资产"
TOKEN="$(gh auth token)"
if [ -z "$TOKEN" ]; then
  echo "❌ 未能获取 gh token，请确认已登录 gh auth login" >&2
  exit 1
fi

CREATE_RESP="$(curl -sS -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/$REPO/releases" \
  -d "$(python3 -c "import json,sys; print(json.dumps({'tag_name':'$VERSION','name':'$VERSION','body':'''$(printf '%s' "$MSG")''','draft':False,'prerelease':False}))")")"

RELEASE_ID="$(printf '%s' "$CREATE_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || true)"
echo "Release ID: $RELEASE_ID"

if [ -z "$RELEASE_ID" ]; then
  echo "⚠️  创建 Release 失败，响应："
  printf '%s\n' "$CREATE_RESP" | head -c 800
  echo
  exit 1
fi

upload() {
  local f="$1" name="$(basename "$1")"
  echo "⬆️  上传 $name ..."
  curl -sS -X POST \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/zip" \
    --data-binary "@$f" \
    "https://uploads.github.com/repos/$REPO/releases/$RELEASE_ID/assets?name=$name" \
    | head -c 400
  echo
}

upload "$ZIP"
upload "$PLUGIN_ZIP"

echo "✅ 发布完成: https://github.com/$REPO/releases/tag/$VERSION"
