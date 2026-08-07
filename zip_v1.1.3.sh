#!/bin/bash
set -e
cd "/Users/a1-6/AI Shared/repo/Lumi"
APP="Lumi/.build/Lumi.app"
# 1) 同步最新编译的可执行到 .app（swift build 只更新 .build/debug/Lumi，不会自动更新 .app）
cp -f "Lumi/.build/debug/Lumi" "$APP/Contents/MacOS/Lumi"
# 2) 更新版本号与构建号
plutil -replace CFBundleShortVersionString -string "1.1.3" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "1" "$APP/Contents/Info.plist"
# 3) 移除旧签名（本地运行无需签名，避免与已替换的可执行不匹配）
rm -rf "$APP/Contents/_CodeSignature"
# 4) 打包
rm -f Lumi-v1.1.3.zip
ditto -c -k --keepParent "$APP" Lumi-v1.1.3.zip
ls -lh Lumi-v1.1.3.zip
echo "DONE_ZIP"
