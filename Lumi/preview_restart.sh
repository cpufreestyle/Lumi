#!/bin/bash
# 预览重启：先关旧进程，再编译产物并启动（避免长命令被工具跳过）
set -e
cd "$(dirname "$0")"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
LUMI_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"

# 先真正编译（之前只取 bin-path 不编译，导致改完代码重启还是旧产物）
swift build --sdk "$LUMI_SDK"
BIN_PATH="$(swift build --sdk "$LUMI_SDK" --show-bin-path 2>/dev/null || echo .build/debug)"
APP=.build/Lumi.app

# 关掉旧进程（按 bundle id 优雅退出，回退 pgrep+kill）
osascript -e 'tell application id "com.lumi.app" to quit' 2>/dev/null || true
for pid in $(pgrep -f "Contents/MacOS/Lumi"); do kill "$pid" 2>/dev/null || true; done
sleep 1

# 打包
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/Lumi" "$APP/Contents/MacOS/Lumi"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R "$BIN_PATH/Lumi_Lumi.bundle" "$APP/Contents/Resources/" 2>/dev/null || true
cp Sources/Lumi/Resources/plugin-feed.json "$APP/Contents/Resources/" 2>/dev/null || true
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

# 从 translate.env 读取翻译 key 注入环境，再直接运行二进制（继承 shell 环境），
# 避免 `open` 不继承环境导致 key 丢失、翻译回退到已限流的 MyMemory 而卡住。
ENV_FILE="$HOME/Library/Application Support/Lumi/translate.env"
if [ -f "$ENV_FILE" ]; then
  KEY=$(grep '^LUMI_TRANSLATE_API_KEY=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d "'\"" | xargs)
  if [ -n "$KEY" ]; then
    export LUMI_TRANSLATE_API_KEY="$KEY"
    BASE=$(grep '^LUMI_TRANSLATE_BASE_URL=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d "'\"" | xargs)
    MODEL=$(grep '^LUMI_TRANSLATE_MODEL=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d "'\"" | xargs)
    [ -n "$BASE" ] && export LUMI_TRANSLATE_BASE_URL="$BASE"
    [ -n "$MODEL" ] && export LUMI_TRANSLATE_MODEL="$MODEL"
    FORCE=$(grep '^LUMI_FORCE_LLM=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d "'\"" | xargs)
    [ -n "$FORCE" ] && export LUMI_FORCE_LLM="$FORCE"
    # 同时写入登陆会话环境，使后续双击 .app（open 不继承本 shell 环境）也能读到
    launchctl setenv LUMI_TRANSLATE_API_KEY "$KEY" 2>/dev/null || true
    launchctl setenv LUMI_TRANSLATE_BASE_URL "$BASE" 2>/dev/null || true
    launchctl setenv LUMI_TRANSLATE_MODEL "$MODEL" 2>/dev/null || true
    launchctl setenv LUMI_FORCE_LLM "$FORCE" 2>/dev/null || true
  fi
fi

# 用 LaunchServices 启动，让 App 自身成为 TCC 责任进程。
# 原先 `nohup 二进制 &` 的做法会把责任进程算成调用方的 shell 宿主：在 agent /
# 非 GUI 会话下 TCC 按宿主判定媒体与 Apple Events 权限，直接 SIGABRT 杀掉 Lumi，
# 且报错误导为「缺 NSAppleMusicUsageDescription」（该 key 其实存在于 Info.plist）。
# 翻译 key 不依赖 shell 继承——上面已 launchctl setenv 写入登陆会话环境。
open "$APP"

# `open` 返回 0 不代表进程真的活着（TCC / 签名问题会静默杀掉），必须自校验。
for _ in 1 2 3 4 5 6 7 8; do
  sleep 1
  if pgrep -x Lumi >/dev/null 2>&1; then
    echo "LAUNCHED_OK pid=$(pgrep -x Lumi | tr '\n' ' ')"
    exit 0
  fi
done

echo "LAUNCH_FAILED: Lumi 进程未存活，查看 ~/Library/Logs/DiagnosticReports/Lumi-*.ips"
exit 1
