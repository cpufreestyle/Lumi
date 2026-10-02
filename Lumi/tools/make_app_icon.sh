#!/bin/bash
# 重新生成 Lumi 应用图标（Apple 风格）并打包为 AppIcon.icns
#
# 设计约定见 tools/make_icon.swift 头部注释：1024 全出血 + 粉紫渐变 + 黑岛 + 双语歌词行。
# 用法：bash tools/make_app_icon.sh   （在 Lumi/ 目录下执行）
set -euo pipefail
cd "$(dirname "$0")/.."

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
# 兼容 set -u：用空串占位，而不是空数组（旧 bash 展开空数组会报 unbound）
if [[ -f "$SDK" ]]; then SDKARG="--sdk $SDK"; else SDKARG=""; fi

OUT=Resources/AppIcon.assets
mkdir -p "$OUT"

echo "[1/3] 生成 1024 母图..."
swift $SDKARG tools/make_icon.swift "$OUT"

echo "[2/3] 缩放全倍率 PNG..."
swift $SDKARG tools/make_iconset.swift "$OUT/AppIcon_1024.png" "$OUT"

echo "[3/3] 打包 AppIcon.icns..."
iconutil -c icns "$OUT/AppIcon.iconset" -o Resources/AppIcon.icns

echo "完成：Resources/AppIcon.icns"
