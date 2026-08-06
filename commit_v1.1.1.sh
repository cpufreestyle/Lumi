#!/bin/bash
set -e
cd "/Users/a1-6/AI Shared/repo/Lumi"
git add -A
git commit -m "fix(music): 进度条可拖动seek、一键对齐歌词、校准滑块、歌词布局修复

- progressSection 进度条改为 DragGesture 支持点击/拖动跳转
- LyricsSyncView 新增 offset 与点击歌词行一键对齐
- 歌词区新增校准滑块 (±10s, 0.5 步长, UserDefaults 持久化)
- MusicExpandedView 用 ScrollView 包裹，移除底部 Spacer，频谱高度 40->28 修复歌词被裁切"
git tag v1.1.1
git push origin main --tags
echo "DONE_COMMIT_TAG_PUSH"
