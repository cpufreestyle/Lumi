#!/bin/bash
# Lumi 启动脚本
cd "$(dirname "$0")"

echo "🔊 停止旧进程..."
lsof -ti:3000 | xargs -r kill 2>/dev/null
sleep 1

echo "🎵 启动 Lumi..."
node server.js &
SERVER_PID=$!

sleep 

# 验证服务是否启动
if curl -s http://localhost:3000/api/config-status > /dev/null 2>&1; then
    echo "✅ 服务已启动: http://localhost:3000"
    echo "   按 Ctrl+C 停止服务"
    wait $SERVER_PID
else
    echo "❌ 服务启动失败，请查看 server.log"
    exit 1
fi
