#!/bin/bash
set -e
cd "/Users/a1-6/AI Shared/repo/Lumi"
git add -A
git commit -m "fix(music): 修复双语翻译缓存跨线程字典竞争导致的崩溃

- translationCache 的读写统一收敛到专用串行队列 translationQueue，消除
  scriptQueue 写入与主线程读取 syncedLines 重建之间的并发字典访问（EXC_BAD_ACCESS）
- rebuildSyncedWithTranslations 改为先取缓存快照再回主线程重建，并用 DispatchGroup
  合并多次翻译回调为单次重建，减少高频 @Published 刷新
- 增强 MyMemory 翻译失败/配额提示文本过滤（quota/used all available/exceeded/
  unavailable/warning/limit reached 等），超限不再当作译文显示或缓存"
git tag v1.1.4
git push origin main --tags
echo "DONE_COMMIT_TAG_PUSH"
