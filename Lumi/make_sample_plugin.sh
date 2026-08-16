#!/bin/bash
# 构建并安装「Lumi 示例插件」（真实可运行版 · Phase 2 L3 演示）。
#
# 与旧版不同：本脚本会真正编译 Sources/LumiSamplePlugin 中的 Swift 工程，
# 生成一个带可执行二进制 + Info.plist（含 URL Scheme 注册）+ lumi-plugin.json
# 的完整 .app，而不是只有清单的空壳。
#
# 该 app 是 LSUIElement（无窗口菜单栏常驻），启动后：
#   1. 向 Lumi 共享目录写入面板 JSON（L3 内嵌面板）；
#   2. 后台每 3 秒刷新面板数据；
#   3. 注册 lumi-sample://，响应 Lumi 面板按钮回调。
#
# 用法：
#   ./make_sample_plugin.sh            # 编译 + 安装到 Plugins 目录 + 写入初始面板
#   ./make_sample_plugin.sh --zip      # 额外打包 LumiSamplePlugin.app.zip（上传 Release）
#   ./make_sample_plugin.sh --clean    # 卸载示例插件

set -e
cd "$(dirname "$0")"

PLUGINS_DIR="$HOME/Library/Application Support/Lumi/Plugins"
APP_NAME="LumiSamplePlugin.app"
APP_PATH="$PLUGINS_DIR/$APP_NAME"
SAMPLE_DIR="SamplePlugin"

if [[ "$1" == "--clean" ]]; then
    rm -rf "$APP_PATH"
    echo "已删除示例插件：$APP_PATH"
    exit 0
fi

DO_ZIP=0
[[ "$1" == "--zip" ]] && DO_ZIP=1

# 使用完整 Xcode 工具链（如存在），保证 SwiftUI/AppKit 宏正常编译
if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

echo "🎵 编译示例插件（SwiftPM）..."
pushd "$SAMPLE_DIR" >/dev/null
# 用本机默认 SDK 编译，不锁定 Lumi 宿主的固定 26.5 SDK，提升可移植性
swift build -c release > /tmp/lumi_sample_build.log 2>&1 || {
    echo "❌ 编译失败："; tail -25 /tmp/lumi_sample_build.log; exit 1
}
BIN_PATH="$(swift build -c release --show-bin-path)"
popd >/dev/null
BIN="$BIN_PATH/LumiSamplePlugin"

echo "✅ 编译完成：$BIN"

# 组装 .app
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN" "$APP_PATH/Contents/MacOS/LumiSamplePlugin"
cp "$SAMPLE_DIR/Info.plist" "$APP_PATH/Contents/Info.plist"
cp "$SAMPLE_DIR/lumi-plugin.json" "$APP_PATH/Contents/Resources/lumi-plugin.json"

# ad-hoc 签名（示例插件本地运行无需账号）
codesign --force --deep --sign - "$APP_PATH" 2>/dev/null || true
xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true

echo "已安装示例插件：$APP_PATH"

# 写入初始面板数据，让 Lumi 立即能渲染（app 启动后也会自己写）
PANELS_DIR="$HOME/Library/Application Support/Lumi/PluginPanels"
mkdir -p "$PANELS_DIR"
cat > "$PANELS_DIR/com.lumi.sample-plugin.json" <<JSON
{
  "id": "com.lumi.sample-plugin",
  "title": "示例插件（天气）",
  "iconName": "cloud.sun",
  "subtitle": "上海 · 实时",
  "lines": [
    { "kv": { "key": "天气", "value": "初始化中…" } },
    { "progress": 0.5 },
    { "button": { "title": "刷新天气" } }
  ],
  "updatedAt": $(date +%s)
}
JSON
echo "已写入初始 L3 面板：$PANELS_DIR/com.lumi.sample-plugin.json"

echo ""
echo "下一步："
echo "  1) 启动示例插件：open '$APP_PATH'（菜单栏出现☁️图标，每3秒刷新面板）"
echo "  2) 重启 Lumi：展开面板标签栏会出现「示例插件（天气）」标签，点开即内嵌面板"
echo "  3) 面板里「刷新天气」按钮会回传 lumi-sample://action?name=刷新天气 给插件"

if [[ "$DO_ZIP" == "1" ]]; then
    ZIP_NAME="LumiSamplePlugin.app.zip"
    # --keepParent：保留 .app 外壳。缺省时 ditto 只打包 .app 的内容（zip 根为 Contents/），
    # 市场端解压后找不到 .app 会报「压缩包内无 .app」，导致卸载后无法重新安装。
    ditto -c -k --keepParent "$APP_PATH" "$ZIP_NAME"
    echo "已打包：$ZIP_NAME（上传到 GitHub Release 后，市场中的「安装」按钮即可下载）"
fi
