#!/bin/bash
set -e
cd "/Users/a1-6/AI Shared/repo/Lumi"
gh release create v1.1.4 \
  --title "v1.1.4 修复双语翻译崩溃" \
  --notes "## 修复内容
- **修复崩溃**：双语歌词翻译缓存（translationCache）在后台队列写入、主线程读取之间发生并发字典访问，导致随机 EXC_BAD_ACCESS 崩溃。现已统一收敛到专用串行队列，并改用缓存快照 + DispatchGroup 合并重建，彻底消除数据竞争。
- **翻译错误过滤增强**：MyMemory 免费接口超限时返回的是提示文本（如配额/限流警告），现扩大过滤词表，超限不再被当作译文显示或缓存。

## 受影响版本
- v1.1.3 含此崩溃，建议所有用户升级到 v1.1.4。

## 安装
下载 Lumi-v1.1.4.zip，解压后将 Lumi.app 拖入「应用程序」并打开（菜单栏常驻）。" \
  Lumi-v1.1.4.zip#Lumi-v1.1.4.zip
echo "DONE_RELEASE"
