#!/bin/bash
set -e
cd "/Users/a1-6/AI Shared/repo/Lumi"
git add -A
git commit -m "feat(ui): 新增轻量自研检查更新（GitHub Release 自动读取）

- 新增 Updater：启动时静默读取仓库最新 Release 并与本地 Info.plist 版本比较
- 语义化版本号比较，发现新版本时面板顶部弹出提示横幅（前往下载/忽略）
- TabBar 右上角新增检查更新按钮，图标随状态变化（检查中/有更新/已最新/失败）
- 支持忽略指定版本（UserDefaults 持久化），失败给出友好提示"
git tag v1.1.6
git push origin main --tags
echo "DONE_COMMIT_TAG_PUSH"
