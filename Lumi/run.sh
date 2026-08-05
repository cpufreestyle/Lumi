#!/bin/bash
# =====================================================
#  Lumi — 统一运行脚本
#  用法:
#    ./run.sh          编译(缺失时) → 打包 → 授权 → 启动
#    ./run.sh build    仅编译并打包 .app
#    ./run.sh launch   打包(已编译) → 授权 → 启动
#    ./run.sh restart  结束旧实例后重新启动
#    ./run.sh check    查询是否正在运行
#    ./run.sh tcc      仅写入用户级 TCC 授权
# =====================================================
set -e
cd "$(dirname "$0")"

APP=.build/Lumi.app
BIN=.build/arm64-apple-macosx/debug/Lumi
BID=com.lumi.app

# ---------- 编译 ----------
build() {
  if [ ! -f "$BIN" ]; then
    echo "🎵 正在编译 Lumi（首次可能需要一两分钟）..."
    if ! swift build 2>&1 | tail -20; then
      echo "❌ 编译失败：请确认已安装 Xcode 命令行工具 (xcode-select --install)"
      exit 1
    fi
    echo "✅ 编译完成"
  else
    echo "ℹ️  已编译，跳过 swift build"
  fi
}

# ---------- 打包 .app ----------
package() {
  if [ ! -f "$BIN" ]; then echo "NO_BINARY: 请先编译"; exit 1; fi
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp "$BIN" "$APP/Contents/MacOS/Lumi"
  cp Resources/Info.plist "$APP/Contents/Info.plist"
  xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
  echo "✅ 已打包 $APP"
}

# ---------- 用户级 TCC 授权 ----------
tcc() {
  if [ ! -d "$APP" ]; then echo "NO_APP: 请先运行 build"; exit 1; fi

  SYS_DB=/Library/Application\ Support/com.apple.TCC/TCC.db
  DIR="$HOME/Library/Application Support/com.apple.TCC"
  USR_DB="$DIR/TCC.db"

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

  echo "== 5. 写入授权记录 =="
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
  sqlite3 "$USR_DB" "$SQL"
  chmod 600 "$USR_DB" 2>/dev/null || true

  echo "== 6. 重载 tccd =="
  killall tccd 2>/dev/null || true
  launchctl kickstart -k "gui/$(id -u)/com.apple.tccd" 2>/dev/null || true
  sleep 1

  echo "== 7. 验证 =="
  sqlite3 "$USR_DB" "SELECT service, allowed FROM access WHERE client='$BID';" 2>&1 | sed 's/^/    /'
  echo "DONE: 用户级权限已尝试自动授权（辅助功能无需授权）。"
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
  restart) pkill -x Lumi 2>/dev/null || true; sleep 1; launch ;;
  check)
    pids=$(pgrep -f "Contents/MacOS/Lumi")
    [ -n "$pids" ] && echo "RUNNING pids=$pids" || echo "NOT_RUNNING" ;;
  tcc)     tcc ;;
  *)       build; launch ;;
esac
