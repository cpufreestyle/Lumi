#!/bin/bash
# Lumi for Windows — 本地开发一键脚本
# 用法: bash dev.sh
# 先装依赖(含 Electron 二进制),编译主进程+渲染进程,启动 Electron。
set -e
cd "$(dirname "$0")"

echo "== 1. 安装依赖(含 Electron 二进制) =="
npm install --no-audit --no-fund

echo "== 2. 编译主进程 =="
npx tsc -p tsconfig.main.json

echo "== 3. 编译渲染进程 =="
npx vite build

echo "== 4. 启动 Electron =="
npx electron .
