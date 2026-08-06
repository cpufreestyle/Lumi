#!/bin/bash
set -e
cd "/Users/a1-6/AI Shared/repo/Lumi"
git add -A
git commit -m "feat(music+island): 快进快退、音量控制、hover收敛、热区按刘海型号精确计算

- 音乐控制新增快退/快进 15 秒按钮 (skip(by:))
- 新增音量滑块 (0-100, UserDefaults 持久化, 实时读写 Music.app sound volume)
- 悬浮预览触发从整窗 onHover 收敛到收缩胶囊本身，避免靠近顶部就展开
- 动态岛热区按 MacBook 型号刘海实际度量 (safeAreaInsets) 精确计算，支持 14/16 寸及无刘海机型"
git tag v1.1.2
git push origin main --tags
echo "DONE_COMMIT_TAG_PUSH"
