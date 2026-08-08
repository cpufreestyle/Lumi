#!/bin/bash
# =====================================================
#  Lumi — 统一运行脚本
#  用法:
#    ./run.sh          编译(缺失时) → 打包 → 授权 → 启动
#    ./run.sh build    仅编译并打包 .app
#    ./run.sh launch   打包(已编译) → 授权 → 启动
#    ./run.sh restart  结束旧实例后重新启动
#    ./run.sh check    查询是否正在运行
#    ./run.sh tcc [--dry-run]  仅写入用户级 TCC 授权（--dry-run 仅预览）
# =====================================================
set -e
cd "$(dirname "$0")"

# 使用完整 Xcode 工具链以正确编译 SwiftUI 宏（否则默认命令行工具会编译失败）
if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

APP=.build/Lumi.app
# 固定使用 macOS 26.5 SDK 构建：当前 27 SDK 下 SwiftPM 无法解析 SwiftUI 的
# SwiftUIMacros 宏插件（环境回归），指定 26.5 SDK 可稳定编译通过。
LUMI_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
# 动态获取 swift build 真实产物路径（不同 SwiftPM 版本的 triple 子目录不同）
BIN_PATH="$(swift build --sdk "$LUMI_SDK" --show-bin-path 2>/dev/null || echo .build/debug)"
BIN="$BIN_PATH/Lumi"
BID=com.lumi.app

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
  # 应用图标（AppIcon.icns）：若存在则打入 .app，并在 Info.plist 已声明 CFBundleIconFile
  if [ -f "Resources/AppIcon.icns" ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  fi
  xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
  echo "✅ 已打包 $APP"
}

# ---------- 用户级 TCC 授权 ----------
# 用法: ./run.sh tcc [--dry-run]
#   --dry-run  仅打印将要执行的操作，不修改数据库
tcc() {
  if [ ! -d "$APP" ]; then echo "NO_APP: 请先运行 build"; exit 1; fi

  local DRY_RUN=false
  [ "${1:-}" = "--dry-run" ] && DRY_RUN=true

  SYS_DB="/Library/Application Support/com.apple.TCC/TCC.db"
  DIR="$HOME/Library/Application Support/com.apple.TCC"
  USR_DB="$DIR/TCC.db"
  BACKUP="$DIR/TCC.db.bak"

  echo "== 1. ad-hoc 签名（生成稳定 cdhash）=="
  codesign --force --deep --sign - "$APP" 2>/dev/null || true

  echo "== 2. 提取本应用 csreq =="
  OUR_CD=$(codesign -d -r- "$APP" 2>&1 | grep -oE 'cdhash H"[^"]+"' | head -1)
  [ -z "$OUR_CD" ] && { echo "ERROR: 无法获取 cdhash"; exit 1; }
  echo "$OUR_CD" > /tmp/ly_req.txt
  rm -f /tmp/ly.csreq
  csreq -r /tmp/ly_req.txt -b /tmp/ly.csreq 2>/tmp/csreq_err \
    || { echo "ERROR: csreq 生成失败: $(cat /tmp/csreq_err)"; exit 1; }

  echo "== 3. 提取 Music.app csreq（自动化授权）=="
  MUSIC_REQ=$(codesign -d -r- /System/Applications/Music.app 2>&1 | sed -n 's/.*designated => //p')
  if [ -n "$MUSIC_REQ" ]; then
    echo "$MUSIC_REQ" > /tmp/music_req.txt
    csreq -r /tmp/music_req.txt -b /tmp/music.csreq 2>/dev/null || rm -f /tmp/music.csreq
  fi

  echo "== 4. 创建/复用用户级 TCC.db =="
  mkdir -p "$DIR"; chmod 700 "$DIR"
  if [ ! -f "$USR_DB" ]; then
    [ -f "$SYS_DB" ] && sqlite3 "$SYS_DB" ".schema" | sqlite3 "$USR_DB" \
      || { echo "ERROR: 找不到系统 TCC.db 模板"; exit 1; }
  fi
  chmod 600 "$USR_DB" 2>/dev/null || true

  echo "== 5. 写入授权记录（仅用户级数据库）=="
  SQL=""
  add_row () {
    local svc="$1" ioid="$2" icoi="$3"
    local icoi_sql="NULL"
    [ -n "$icoi" ] && icoi_sql="readfile('$icoi')"
    SQL="$SQL
INSERT OR REPLACE INTO access
 (service, client, client_type, auth_value, auth_reason, auth_version, csreq, indirect_object_identifier, indirect_object_code_identity, flags, last_modified)
 VALUES ('$svc', '$BID', 0, 1, 2, 1, readfile('/tmp/ly.csreq'), '$ioid', $icoi_sql, 0, strftime('%s','now'));"
  }
  add_row "kTCCServiceCalendar" "UNUSED" ""
  add_row "kTCCServiceBluetoothAlways" "UNUSED" ""
  add_row "kTCCServiceBluetooth" "UNUSED" ""
  [ -s /tmp/music.csreq ] && add_row "kTCCServiceAppleEvents" "com.apple.Music" "/tmp/music.csreq"

  # -- dry-run 模式：仅打印将要执行的操作 --
  if $DRY_RUN; then
    echo ""
    echo "🔍 [DRY-RUN] 以下操作不会实际执行："
    echo "  目标数据库: $USR_DB"
    echo "  备份路径:   $BACKUP"
    echo ""
    echo "  即将执行的 SQL:"
    echo "$SQL" | sed 's/^/    /'
    echo ""
    echo "  随后将重载 tccd 并验证写入结果。"
    echo ""
    echo "DRY-RUN 完成：未修改任何数据。去掉 --dry-run 以实际执行。"
    return 0
  fi

  # -- 正常模式：写入前备份用户级数据库 --
  if [ -f "$USR_DB" ]; then
    cp -p "$USR_DB" "$BACKUP" 2>/dev/null \
      || { echo "WARNING: 无法创建备份 ($BACKUP)，继续执行但存在风险"; }
    if [ -f "$BACKUP" ]; then
      echo "  📦 已备份用户级 TCC.db → $BACKUP"
    fi
  fi

  # -- 写入用户级数据库，失败时提供回滚提示 --
  if ! sqlite3 "$USR_DB" "$SQL" 2>/tmp/tcc_write_err; then
    echo ""
    echo "❌ 写入用户级 TCC.db 失败: $(cat /tmp/tcc_write_err)"
    echo ""
    if [ -f "$BACKUP" ]; then
      echo "🔄 回滚方法："
      echo "   cp \"$BACKUP\" \"$USR_DB\""
      echo "   然后执行: killall tccd 2>/dev/null; launchctl kickstart -k \"gui/$(id -u)/com.apple.tccd\""
    else
      echo "⚠️  无可用备份，无法自动回滚。请手动检查 $USR_DB"
    fi
    echo ""
    exit 1
  fi
  chmod 600 "$USR_DB" 2>/dev/null || true

  echo "== 6. 重载 tccd =="
  killall tccd 2>/dev/null || true
  launchctl kickstart -k "gui/$(id -u)/com.apple.tccd" 2>/dev/null || true
  sleep 1

  echo "== 7. 验证（用户级） =="
  sqlite3 "$USR_DB" "SELECT service, allowed FROM access WHERE client='$BID';" 2>&1 | sed 's/^/    /'
  echo "DONE: 用户级权限已尝试自动授权（辅助功能无需授权）。"
  if [ -f "$BACKUP" ]; then
    echo "  📦 备份位于: $BACKUP"
  fi
}

# ---------- 启动 ----------
launch() {
  package
  tcc
  osascript -e 'tell application id "com.lumi.app" to quit' 2>/dev/null || true
  sleep 1
  echo "🚀 正在启动 Lumi..."
  open "$APP"
  echo "LAUNCHED_OK"
}

# ---------- 子命令分发 ----------
case "${1:-}" in
  build)   build; package ;;
  launch)  launch ;;
  reopen|restart)
    # 重新构建并重启：先退出旧实例，再打开新构建。
    # 用 osascript 优雅退出（bundle id），失败则回退到 pgrep+kill。
    osascript -e 'tell application id "com.lumi.app" to quit' 2>/dev/null || \
      for pid in $(pgrep -f "Contents/MacOS/Lumi"); do kill "$pid" 2>/dev/null; done
    build
    osascript -e 'tell application id "com.lumi.app" to activate' 2>/dev/null
    open "$APP"
    echo "REOPENED_OK" ;;
  check)
    pids=$(pgrep -f "Contents/MacOS/Lumi")
    [ -n "$pids" ] && echo "RUNNING pids=$pids" || echo "NOT_RUNNING" ;;
  tcc)     tcc "${@:2}" ;;
  *)       build; launch ;;
esac
