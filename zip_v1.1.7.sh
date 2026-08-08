#!/bin/bash
set -e
cd "/Users/a1-6/AI Shared/repo/Lumi"
APP="Lumi/.build/Lumi.app"
# 同步最新编译的可执行到 .app（swift build 只更新 .build/.../Lumi，不会自动更新 .app）
cp -f "Lumi/.build/arm64-apple-macosx/debug/Lumi" "$APP/Contents/MacOS/Lumi"
# 确保图标与 Info.plist 为最新
cp -f "Lumi/Resources/Info.plist" "$APP/Contents/Info.plist"
cp -f "Lumi/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
plutil -replace CFBundleShortVersionString -string "1.1.7" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "1" "$APP/Contents/Info.plist"
rm -rf "$APP/Contents/_CodeSignature"
rm -f Lumi-v1.1.7.zip
ditto -c -k --keepParent "$APP" Lumi-v1.1.7.zip
ls -lh Lumi-v1.1.7.zip
echo "DONE_ZIP"
