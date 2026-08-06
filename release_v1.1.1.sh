#!/bin/bash
set -e
cd "/Users/a1-6/AI Shared/repo/Lumi"
APP="Lumi/.build/Lumi.app"
if [ ! -d "$APP" ]; then
  echo "APP_NOT_FOUND"
  exit 0
fi
rm -f Lumi-v1.1.1.zip
ditto -c -k --keepParent "$APP" Lumi-v1.1.1.zip
gh release create v1.1.1 Lumi-v1.1.1.zip \
  --title "v1.1.1 - 音乐控制与歌词体验修复" \
  --notes "## 改进
- 进度条支持点击/拖动跳转播放进度 (seek)
- 歌词一键对齐：点击当前正在唱的歌词行自动校准时间轴偏移
- 歌词区新增校准滑块 (±10s, 0.5s 步长, 自动持久化)
- 修复歌词被面板底部裁切的问题 (ScrollView 包裹 + 压缩频谱占用)

## 安装
下载 Lumi-v1.1.1.zip，解压后拖入 Applications，首次运行在 设置-隐私与安全性 中允许。"
echo "DONE_RELEASE"
