#!/bin/bash
# =====================================================
#  Lumi — 重启脚本（免费账号自签名版）
# -----------------------------------------------------
#  先退出旧实例，再调用 sign_and_run.sh 重新签名并启动。
#  证书过期时 sign_and_run.sh 会自动检测并尝试重置。
#
#  用法:
#    ./restart_lumi.sh          退出旧实例 → 重签名 → 启动
#    ./restart_lumi.sh --adhoc  同上，但用 ad-hoc 自签名（不依赖账号）
# =====================================================
set -e
cd "$(dirname "$0")"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SIGN_SCRIPT="$SCRIPT_DIR/sign_and_run.sh"

# 退出旧实例
osascript -e 'tell application id "com.lumi.app" to quit' 2>/dev/null || \
  for pid in $(pgrep -f "Contents/MacOS/Lumi"); do kill "$pid" 2>/dev/null; done
sleep 1

# 重新签名并启动（复用 sign_and_run.sh 的证书检测/重签逻辑）
if [ "${1:-}" = "--adhoc" ]; then
  exec "$SIGN_SCRIPT" --adhoc run
else
  exec "$SIGN_SCRIPT" run
fi
