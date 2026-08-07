#!/bin/bash
set -e
cd "/Users/a1-6/AI Shared/repo/Lumi"
APP="Lumi/.build/Lumi.app"
# 同步最新编译的可执行到 .app（swift build 只更新 .build/debug/Lumi，不会自动更新 .app）
cp -f "Lumi/.build/debug/Lumi" "$APP/Contents/MacOS/Lumi"
plutil -replace CFBundleShortVersionString -string "1.1.6" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "1" "$APP/Contents/Info.plist"
rm -rf "$APP/Contents/_CodeSignature"
rm -f Lumi-v1.1.6.zip
ditto -c -k --keepParent "$APP" Lumi-v1.1.6.zip
ls -lh Lumi-v1.1.6.zip
echo "DONE_ZIP"
