#!/bin/bash
# =====================================================
#  Lumi — 免费 Apple ID 本地自签名运行脚本
# -----------------------------------------------------
#  适用场景：你已用【普通免费 Apple ID】登录 Xcode，
#  想在不上架、不付费的情况下，把 Lumi 跑在自己的 Mac 上。
#
#  原理：
#    1. 用 Xcode 里登录的免费个人开发者身份做 development 签名
#       （比 ad-hoc 更稳定，系统会正常弹窗请求 AppleEvents 等权限）。
#    2. macOS 个人开发证书签名的 app 可一直在本机运行，
#       若某天提示“已损坏/无法验证”，重跑本脚本重新签名即可。
#
#  用法：
#    ./sign_and_run.sh              编译 + 用免费账号签名 + 启动
#    ./sign_and_run.sh build        仅编译并签名打包 .app
#    ./sign_and_run.sh run          已编译过则只重新签名并启动
#    ./sign_and_run.sh identities   列出本机可用的免费签名身份
#    ./sign_and_run.sh --adhoc      退回 ad-hoc 自签名（不改任何系统数据库，
#                                   仅去掉 quarantine 属性，权限弹窗照常）
#
#  前置条件：
#    - 打开过一次 Xcode，并登录了你的 Apple ID
#      （Xcode ▸ Settings ▸ Accounts ▸ 左下 + 添加 Apple ID）。
#      免费账号即可，无需付费开发者计划。
#    - 首次运行若报错“no identity found”，按下方“排查”处理。
# =====================================================
set -e
cd "$(dirname "$0")"

# 使用完整 Xcode 工具链以正确编译 SwiftUI 宏
if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

APP=.build/Lumi.app
# 固定使用 macOS 26.5 SDK 构建（与 run.sh 保持一致）
LUMI_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
BIN_PATH="$(swift build --sdk "$LUMI_SDK" --show-bin-path 2>/dev/null || echo .build/debug)"
BIN="$BIN_PATH/Lumi"
BID=com.lumi.app

AD_HOC=false
if [ "${1:-}" = "--adhoc" ]; then AD_HOC=true; shift; fi

# ---------- 列出可用签名身份 ----------
list_identities() {
  echo "🔎 本机可用签名身份（免费 Apple ID 会显示为 'Apple Development: xxx'）："
  security find-identity -v -p codesigning | sed 's/^/    /'
  echo ""
  echo "  若列表为空或没有 'Apple Development:'，请先在 Xcode ▸ Settings ▸ Accounts 登录免费 Apple ID，"
  echo "  然后新建/打开任意项目，在 Signing & Capabilities 勾选你的账号，Xcode 会自动生成开发证书。"
}

# ---------- 检测开发证书是否仍有效（免费账号证书会过期） ----------
# 返回 0 表示有效；非 0 表示无效/过期/缺失。
check_cert_valid() {
  local ID="$1"
  [ -z "$ID" ] && return 1
  # 在钥匙串里找出该签名身份对应的证书，判断是否过期。
  # security 输出形如：
  #   1) <hash> "Apple Development: name (TEAMID)"  (valid, 2027-01-01 ...)
  # 用 find-identity 无法直接看有效期，改为 find-certificate 取有效期字段。
  local common
  common="$(echo "$ID" | sed -E 's/^Apple Development: ?//; s/ \([^)]*\)$//')"
  [ -z "$common" ] && return 1
  local cert_info
  cert_info="$(security find-certificate -a -c "$common" -p 2>/dev/null \
               | openssl x509 -noout -enddate 2>/dev/null | sed 's/notAfter=//')"
  [ -z "$cert_info" ] && return 1
  local exp_ts now_ts
  exp_ts="$(date -j -f "%b %d %H:%M:%S %Y %Z" "$cert_info" +%s 2>/dev/null || echo 0)"
  now_ts="$(date +%s)"
  if [ "$exp_ts" -gt "$now_ts" ]; then
    echo "   开发证书有效期至：$cert_info"
    return 0
  else
    echo "   ⚠️  开发证书已于 $cert_info 过期"
    return 1
  fi
}

# ---------- 解析免费签名身份 ----------
resolve_identity() {
  # 优先使用 Apple Development（免费账号即可生成）
  local id
  id="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -oE '"Apple Development:[^"]+"' | head -1 | tr -d '"')"
  if [ -z "$id" ]; then
    # 退而求其次：任意开发类签名身份
    id="$(security find-identity -v -p codesigning 2>/dev/null \
          | grep -oE '"[^"]*(Development|Developer)[^"]*"|"Mac Developer[^"]*"' \
          | head -1 | tr -d '"')"
  fi
  echo "$id"
}

# ---------- 编译 ----------
build() {
  echo "🎵 正在编译 Lumi (SDK: MacOSX26.5)..."
  if ! swift build --sdk "$LUMI_SDK" > /tmp/lumi_swiftbuild.log 2>&1; then
    echo "❌ 编译失败："
    tail -25 /tmp/lumi_swiftbuild.log
    exit 1
  fi
  echo "✅ 编译完成"
}

# ---------- 打包 .app ----------
package() {
  if [ ! -f "$BIN" ]; then echo "NO_BINARY: 请先编译"; exit 1; fi
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp "$BIN" "$APP/Contents/MacOS/Lumi"
  cp Resources/Info.plist "$APP/Contents/Info.plist"
  if [ -f "Resources/AppIcon.icns" ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  fi
  echo "✅ 已打包 $APP"
}

# ---------- 签名 ----------
sign() {
  if $AD_HOC; then
    echo "🔏 使用 ad-hoc 自签名（免费账号无关，仅去 quarantine）..."
    codesign --force --deep --sign - "$APP"
    xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
    echo "✅ ad-hoc 签名完成"
    return 0
  fi

  local ID
  ID="$(resolve_identity)"
  if [ -z "$ID" ]; then
    echo "❌ 未找到可用的免费 Apple ID 签名身份。"
    echo "   请先在 Xcode ▸ Settings ▸ Accounts 登录你的免费 Apple ID，"
    echo "   并任意触发一次开发证书生成（打开/新建项目勾选 Signing 即可）。"
    echo ""
    echo "   或改用 ad-hoc 方案： ./sign_and_run.sh --adhoc"
    exit 1
  fi

  # 证书过期自动检测：若免费开发证书已过期，尝试自动重置（需 Xcode 在场）。
  if ! check_cert_valid "$ID"; then
    echo "🔄 尝试自动重置开发证书..."
    if command -v xcodebuild >/dev/null 2>&1; then
      # 触发 Xcode 重新生成/续期开发证书（无项目也不影响，仅做证书同步）
      xcodebuild -downloadAllPlatforms >/dev/null 2>&1 || true
    fi
    # 重新解析身份，看是否已续期
    ID="$(resolve_identity)"
    if [ -z "$ID" ] || ! check_cert_valid "$ID"; then
      echo "❌ 证书仍无效。请手动处理："
      echo "   Xcode ▸ Settings ▸ Accounts ▸ 选中你的 Apple ID"
      echo "   ▸ Manage Certificates ▸ 右键重置『Apple Development』证书。"
      echo ""
      echo "   或改用 ad-hoc 方案（无需账号，但会改 TCC 数据库）："
      echo "   ./sign_and_run.sh --adhoc"
      exit 1
    fi
  fi

  echo "🔏 使用开发签名身份：$ID"

  # 用免费账号 development 签名。macOS 个人开发证书签的 app 可在本机长期运行，
  # 无需额外的 entitlements（Lumi 仅用 AppleScript 控制 Music，不申请特殊权限）。
  if ! codesign --force --deep --options runtime --sign "$ID" "$APP" 2>/tmp/lumi_sign.log; then
    echo "❌ 签名失败："
    cat /tmp/lumi_sign.log
    echo ""
    echo "   常见原因与处理："
    echo "   - 证书已过期：Xcode ▸ Settings ▸ Accounts ▸ 选中账号 ▸ Manage Certificates ▸ 右键重置。"
    echo "   - 仍失败可退回 ad-hoc： ./sign_and_run.sh --adhoc"
    exit 1
  fi
  xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
  echo "✅ 开发签名完成"
}

# ---------- 启动 ----------
launch() {
  osascript -e 'tell application id "com.lumi.app" to quit' 2>/dev/null || true
  sleep 1
  echo "🚀 正在启动 Lumi..."
  open "$APP"
  echo "LAUNCHED_OK"
  echo ""
  echo "ℹ️  首次运行会弹出『Lumi 想控制“音乐”』等授权框，点击“好/允许”即可。"
  echo "    若弹窗缺失或功能异常，可在 系统设置 ▸ 隐私与安全性 ▸ 自动化/辅助功能 中手动勾选 Lumi。"
}

# ---------- 子命令分发 ----------
case "${1:-}" in
  build)  build; package; sign ;;
  run)    package; sign; launch ;;
  identities) list_identities ;;
  *)      build; package; sign; launch ;;
esac
