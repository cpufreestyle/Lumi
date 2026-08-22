#!/bin/bash
set -e
cd "/Users/a1-6/AI Shared/repo/Lumi"
git add -A
git commit -m "fix(ui): 修复展开面板右下角缩放手柄拖拽无效

- IslandWindowController 新增 isResizing 标志，updateWindowFrame 在缩放期间
  跳过尺寸重置，避免面板内鼠标移动触发 isHovering 变化后把窗口拽回旧尺寸
- resizeBy 拖拽中实时把最新尺寸写入 userSize，使状态刷新只沿用最新值而非旧尺寸
- saveUserSize（松手）负责持久化并复位 isResizing，恢复正常窗口重排"
git tag v1.1.5
git push origin main --tags
echo "DONE_COMMIT_TAG_PUSH"
