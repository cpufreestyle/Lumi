#!/bin/bash
set -e
cd "/Users/a1-6/AI Shared/repo/Lumi"
git add -A
git commit -m "feat(music): 双语歌词、繁简转换、封面加载加速、按曲目记忆时间轴校准

- 歌词双语对照：自带双语自动拆分 + 联网翻译补全（MyMemory 免费 API，无需 key），两种来源都支持
- 新增 bilingualMode 开关（原/双/译），UserDefaults 持久化，歌词区一键切换
- 繁体歌词统一转简体（CFStringTransform Hant-Hans），中英文混合/翻译文本不受影响
- 专辑封面获取移到独立高优先级队列，后台解码缩放为 280px，明显缩短出现延迟
- 时间轴按曲目记忆校准：拖动滑块/点击对齐调一次后持久化，再次播放同一首自动套用"
git tag v1.1.3
git push origin main --tags
echo "DONE_COMMIT_TAG_PUSH"
