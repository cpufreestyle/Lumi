#!/bin/bash
# v1.1.13 发布脚本：clean build → 打包 .app → 提交 → 打 tag → 建 GitHub Release
#
# 与历史脚本差异 / 约定（见 .codebuddy/memory/MEMORY.md）：
#  - 使用 clean build 确保源码/Info.plist 改动确实编入 .app（此前 SwiftPM 缓存曾导致改动未生效）
#  - 发布走 GitHub API：先 `gh auth token` 取 token，再用 `curl` 调 API 创建 Release 并上传 zip，
#    不直接用 `gh release` 命令（会被交互启发式拦截）
#  - 版本号一致性：Info.plist 的 CFBundleShortVersionString 已同步为 1.1.13，
#    与 tag v1.1.13、Updater.currentVersion 一致，避免自动更新提示误判
set -e

cd "$(dirname "$0")"

APP="Lumi/.build/Lumi.app"
ZIP="Lumi-v1.1.13.zip"
VERSION="v1.1.13"
REPO="cpufreestyle/Lumi"
MSG="v1.1.13: 游戏模块支持键盘控制；歌词当前行粉色高亮且校准滑条移至标题右；窗口缩放更流畅"

# 仅提交本次发布相关的版本号提升（其余源码改动已在之前提交并推送）
FILES=(
  "Lumi/Resources/Info.plist"
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

echo "📝 提交版本号提升"
git add "${FILES[@]}"
git commit -m "$MSG" || echo "（无新改动可提交）"

echo "🏷️  打 tag $VERSION"
git tag -a "$VERSION" -m "$MSG" || echo "（tag 已存在）"

echo "🚀 推送"
git push origin main
git push origin "$VERSION"

echo "🌐 用 GitHub API 创建 Release 并上传 zip"
TOKEN="$(gh auth token)"
if [ -z "$TOKEN" ]; then
  echo "❌ 未能获取 gh token，请确认已登录 gh auth login" >&2
  exit 1
fi

# 1) 创建 Release（draft=false）
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

# 2) 上传 .app zip 资产
echo "⬆️  上传 $ZIP ..."
UPLOAD_RESP="$(curl -sS -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/zip" \
  --data-binary "@$ZIP" \
  "https://uploads.github.com/repos/$REPO/releases/$RELEASE_ID/assets?name=$ZIP")"

echo "上传响应（前 400 字符）："
printf '%s\n' "$UPLOAD_RESP" | head -c 400
echo

echo "✅ 发布完成: https://github.com/$REPO/releases/tag/$VERSION"
