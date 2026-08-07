#!/bin/bash
set -e
cd "/Users/a1-6/AI Shared/repo/Lumi"
gh release create v1.1.3 \
  --title "v1.1.3 双语歌词 / 繁简转换 / 封面加速 / 时间轴按曲校准" \
  --notes "## 更新内容
- **双语歌词对照**：自带双语自动拆分 + 联网翻译补全（MyMemory 免费 API，无需 key），两种来源均支持
- **新增双语开关**（原 / 双 / 译），歌词区一键切换，UserDefaults 持久化
- **繁体歌词自动转简体**（CFStringTransform Hant-Hans），英文/翻译文本不受影响
- **封面加载加速**：独立高优先级队列获取，后台解码缩放为 280px，明显缩短出现延迟
- **时间轴按曲目记忆校准**：拖动滑块或点击歌词对齐调一次后持久化，再次播放同一首自动套用

## 安装
下载 Lumi-v1.1.3.zip，解压后将 Lumi.app 拖入「应用程序」，从启动台或访达打开即可（菜单栏常驻）。" \
  Lumi-v1.1.3.zip#Lumi-v1.1.3.zip
echo "DONE_RELEASE"
