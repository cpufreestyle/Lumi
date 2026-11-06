#!/usr/bin/env bash
# 解析 CI/本机能用的 macOS 26.x SDK 绝对路径（stdout 只输出一行路径，诊断走 stderr）。
#
# 为什么要显式解析：spec.md「版本与运行时」记录了构建约束 —— macOS 27 SDK 下
# SwiftUIMacros 宏插件解析失败，`swift build/test` 必须钉在 macOS 26.x SDK 上。
# 本机（Xcode 27 + CommandLineTools 里残留的 26.5 SDK）和 GitHub macos-26 镜像
# （Xcode 26.5/26.6，自带 MacOSX26.5.sdk）路径不一样，所以不能把绝对路径写死。
#
# 用法：SDK="$(scripts/ci/resolve-sdk.sh)"           # 优先精确命中 26.5
#       SDK="$(scripts/ci/resolve-sdk.sh 26.4)"      # 指定想要的小版本
#
# 找不到任何 26.x SDK 时以退出码 1 结束：宁可报「换 runner 镜像/装 26 SDK」，
# 也不要静默用 27 SDK 跑出一堆看不懂宏解析错误。
set -uo pipefail

WANT="${1:-26.5}"
SEARCH_DIRS=(
  "$(xcode-select -p)/Platforms/MacOSX.platform/Developer/SDKs"
  "/Library/Developer/CommandLineTools/SDKs"
)

is_usable() { # $1: 候选路径（可能是符号链接）
  local p
  p="$(realpath "$1" 2>/dev/null)" || return 1
  [ -f "$p/SDKSettings.plist" ] || return 1
  printf '%s\n' "$p"
}

for dir in "${SEARCH_DIRS[@]}"; do
  [ -d "$dir" ] || continue

  # 1) 精确命中想要的小版本
  if resolved="$(is_usable "$dir/MacOSX${WANT}.sdk")"; then
    echo "resolve-sdk: 精确命中 MacOSX${WANT}.sdk[${dir}]" >&2
    printf '%s\n' "$resolved"
    exit 0
  fi

  # 2) macOS 26 大版本的任意小版本（glob 已按字典序，取第一个可用的）
  for cand in "$dir"/MacOSX26*.sdk; do
    [ -e "$cand" ] || continue
    if resolved="$(is_usable "$cand")"; then
      echo "resolve-sdk: 未找到 MacOSX${WANT}.sdk，改用 macOS 26.x SDK[${cand}]" >&2
      printf '%s\n' "$resolved"
      exit 0
    fi
  done
done

DEFAULT_SDK="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
{
  echo "resolve-sdk: 错误 —— 没有可用的 macOS 26.x SDK。"
  echo "resolve-sdk: 已搜索：${SEARCH_DIRS[*]}"
  echo "resolve-sdk: 当前默认 SDK：${DEFAULT_SDK:-无}（版本 $(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo 未知)）"
  echo "resolve-sdk: spec.md 记录 27 SDK 会让 SwiftUIMacros 解析失败，因此不回退。"
  echo "resolve-sdk: 修法：runner 换成含 26.x SDK 的镜像（如 macos-26），本机则安装/保留 MacOSX26 SDK。"
} >&2
exit 1
