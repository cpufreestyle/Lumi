#!/bin/bash
# Lumi L3 插件面板演示（零编译版）。
#
# 不依赖 Swift 工具链：仅用 shell 周期性往
#   ~/Library/Application Support/Lumi/PluginPanels/com.lumi.demo.json
# 写面板数据，Lumi 每 1 秒轮询并渲染。用于直观演示「第三方 app 如何接入灵动岛」。
#
# 用法：
#   bash demo_panel.sh start    # 后台每 3 秒刷新面板
#   bash demo_panel.sh stop     # 停止并清理面板 JSON
#   bash demo_panel.sh once     # 只写一次（用于手动验证格式）

set -e
PANELS_DIR="$HOME/Library/Application Support/Lumi/PluginPanels"
PLUGINS_DIR="$HOME/Library/Application Support/Lumi/Plugins"
DEMO_APP="$PLUGINS_DIR/LumiDemoPanel.app"
PID_FILE="/tmp/lumi_demo_panel.pid"
PLUGIN_ID="com.lumi.demo"

# 为了让 Lumi 标签栏出现「Demo 面板」标签，需要一个被 PluginDiscovery 扫描到的
# manifest（带 panel:true）。这里放一个无二进制的空壳 .app 作为入口；真正的面板
# 内容由本脚本周期写 PluginPanels/<id>.json。这样就实现「零编译、纯文件」接入。
install_manifest_app() {
  mkdir -p "$DEMO_APP/Contents/Resources"
  cat > "$DEMO_APP/Contents/Resources/lumi-plugin.json" <<JSON
{
  "id": "$PLUGIN_ID",
  "name": "Demo 面板",
  "iconName": "sparkles",
  "urlScheme": "lumidemo",
  "panel": true,
  "version": "1.0.0",
  "category": "其它",
  "summary": "第三方 L3 面板演示",
  "permissions": [{ "type": "none", "reason": "仅本地文件桥接演示" }]
}
JSON
  echo "已安装演示清单：($DEMO_APP/Contents/Resources/lumi-plugin.json)"
}

remove_manifest_app() {
  rm -rf "$DEMO_APP"
  echo "已移除演示清单 .app"
}

write_once() {
  mkdir -p "$PANELS_DIR"
  local ts now pct
  ts=$(date +%s)
  # 演示用：进度随时间正弦波动，文本显示当前时间
  now=$(date "+%H:%M:%S")
  pct=$(printf "%.2f" "$(echo "0.5 + 0.45*s($ts/5)" | bc -l 2>/dev/null || echo 0.5)")
  cat > "$PANELS_DIR/$PLUGIN_ID.json.tmp" <<JSON
{
  "id": "$PLUGIN_ID",
  "title": "Demo 面板",
  "iconName": "sparkles",
  "subtitle": "第三方 L3 演示",
  "updatedAt": $ts,
  "lines": [
    { "kind": "kv", "key": "当前时间", "value": "$now" },
    { "kind": "progress", "p": $pct },
    { "kind": "button", "title": "点我回调" },
    { "kind": "text", "value": "这是其他 app 写进 Lumi 的面板" }
  ]
}
JSON
  mv "$PANELS_DIR/$PLUGIN_ID.json.tmp" "$PANELS_DIR/$PLUGIN_ID.json"
  echo "已写入面板：$PANELS_DIR/$PLUGIN_ID.json"
}

stop_demo() {
  if [[ -f "$PID_FILE" ]]; then
    kill "$(cat "$PID_FILE")" 2>/dev/null && echo "已停止演示进程"
    rm -f "$PID_FILE"
  else
    echo "演示未在运行"
  fi
  rm -f "$PANELS_DIR/$PLUGIN_ID.json"
  remove_manifest_app
  echo "已清理面板 JSON 与演示清单"
}

case "$1" in
  once)
    write_once
    ;;
  stop)
    stop_demo
    ;;
  start|"")
    install_manifest_app
    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
      echo "演示已在运行（PID $(cat "$PID_FILE")）"
      exit 0
    fi
    echo "启动 L3 面板演示（每 3 秒刷新，Ctrl+C 或 demo_panel.sh stop 停止）…"
    (
      while true; do
        write_once >/dev/null
        sleep 3
      done
    ) &
    echo $! > "$PID_FILE"
    echo "PID $! 已写入 $PID_FILE"
    echo "现在请重启 Lumi，展开面板标签栏会出现「Demo 面板」标签。"
    echo "按钮回调地址：lumidemo://action?name=点我回调"
    wait
    ;;
  *)
    echo "用法：bash demo_panel.sh {start|stop|once}"
    exit 1
    ;;
esac
