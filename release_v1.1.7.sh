#!/bin/bash
set -e
cd "/Users/a1-6/AI Shared/repo/Lumi"
gh release create v1.1.7 \
  --title "Lumi v1.1.7" \
  --notes "v1.1.7

- 新增应用图标（动态岛 / 月光主题）
- 修复音乐专辑封面显示延迟：切歌后主动快速重试拉取封面，不再干等轮询
- 修复偶发崩溃：消除封面标志位跨队列无锁竞争，并加固后台线程的 SwiftUI 属性写入
- 封面解码改用 CGContext 稳健缩放，避免后台锁焦点绘图隐患" \
  Lumi-v1.1.7.zip
echo "DONE_RELEASE"
