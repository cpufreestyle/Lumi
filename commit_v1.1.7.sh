#!/bin/bash
set -e
cd "/Users/a1-6/AI Shared/repo/Lumi"
git add -A
git commit -m "v1.1.7: 应用图标 + 音乐封面延迟/崩溃修复"
git tag v1.1.7
git push origin main --tags
echo "DONE_COMMIT"
