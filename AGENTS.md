# AGENTS.md — Lumi 项目指南

## 1. 项目概述

Lumi 是一个 **Swift macOS 桌面应用 + Node.js 后端服务** 的双组件项目：

| 组件 | 技术栈 | 入口 | 职责 |
|------|--------|------|------|
| **Lumi App** | Swift 5.9 / SwiftUI / macOS 14+ | `Lumi/Sources/Lumi/Core/main.swift` | 动态岛 Apple Music 播放器、日历、剪贴板、游戏、直播检测、视频下载等模块 |
| **Node.js 后端** | Express + jsonwebtoken | `server.js` | 托管静态前端、签发 Apple MusicKit JWT 开发者令牌、提供配置 API、激活码换发 |

Swift 包位于 `Lumi/` 子目录，使用 `Lumi/Package.swift` 管理。Node.js 包位于项目根目录，使用 `package.json` 管理。

## 2. Swift 工具链约束

### DEVELOPER_DIR

所有构建脚本（`run.sh`、`sign_and_run.sh`、`run_app.sh`）均要求设置：

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

**原因**：默认的 Xcode Command Line Tools 缺少完整的 SwiftUI 宏插件（SwiftUIMacros），会导致编译失败。必须指向完整 Xcode.app 的工具链。

### SDK 版本

构建时固定使用 **macOS 26.5 SDK**：

```bash
LUMI_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
swift build --sdk "$LUMI_SDK"
```

**原因**：macOS 27 SDK 下 SwiftPM 无法正确解析 SwiftUI 的 SwiftUIMacros 宏插件（环境回归），指定 26.5 SDK 可稳定编译通过。

### 关键依赖框架

- MediaPlayer, EventKit, IOBluetooth, IOKit, CryptoKit, MusicKit, WebKit

### Swift 包结构

| Target | 路径 | 说明 |
|--------|------|------|
| `Lumi` (executable) | `Sources/Lumi` | 主应用 |
| `license-tool` (executable) | `Sources/license-tool` | 激活码签发工具，持私钥签名，独立于 App |
| `LumiTests` (test) | `Tests/LumiTests` | 单元测试 |

## 3. testTarget 的 GUI 框架限制

`LumiTests` 目标 **仅允许依赖 Foundation 和 CryptoKit**，严禁引入 AppKit、SwiftUI 或任何 GUI 框架。

```swift
// Package.swift 中的设计意图：
// 单元测试目标：仅依赖 Foundation/CryptoKit，不引入 AppKit/SwiftUI/GUI 框架，
// 以保证 `swift test` 在 CI/命令行下无需登录会话即可编译运行。
```

**约束**：
- 新增测试必须是纯逻辑测试（哈希、编解码、签名验证等），不涉及 UI
- 测试文件命名以 `Tests.swift` 结尾，方法以 `test` 开头
- 运行测试：`cd Lumi && swift test`（无需 GUI 会话）

## 4. server.js 敏感操作边界

### 私钥路径

激活码换发 API (`POST /api/redeem`) 读取本地 Ed25519 私钥：

```
Lumi/secrets/license_private_key.b64
```

该私钥通过环境变量 `LUMI_LICENSE_PRIVATE_KEY` 传递给 `license-tool` Swift 子进程。**不可将此私钥提交到版本控制或暴露到客户端。**

吊销清单文件路径：

```
Lumi/secrets/revocations.lumi
```

### JWT 配置

Apple MusicKit JWT 开发者令牌签发依赖 `.env` 文件中的三个凭据：

| 环境变量 | 说明 | 格式 |
|----------|------|------|
| `APPLE_TEAM_ID` | Apple Developer Team ID | 10 位数字 |
| `APPLE_KEY_ID` | MusicKit Key ID | 10 位字符 |
| `APPLE_PRIVATE_KEY` | MusicKit .p8 私钥内容 | PEM 格式（含 BEGIN/END 标记） |

**安全边界**：
- `.env` 文件已在 `.gitignore` 中，不得提交
- `.env.example` 提供模板，不含实际值
- `POST /api/setup` 会将凭据写入 `.env` 文件，需校验 PEM 格式
- JWT 算法为 ES256，令牌最长有效期约 6 个月，服务端有缓存机制
- `GET /api/config-status` 仅返回脱敏后的凭据状态（首尾各 2 字符）

### 服务端口

默认 `PORT=3000`，可通过 `.env` 覆盖。

## 5. 构建和运行标准流程

### Swift macOS App

```bash
# 方式一：统一脚本（推荐）
cd Lumi
./run.sh              # 编译 → 打包 → TCC 授权 → 启动
./run.sh build        # 仅编译并打包 .app
./run.sh launch       # 打包 → 授权 → 启动
./run.sh restart      # 结束旧实例后重新启动
./run.sh check        # 查询是否正在运行
./run.sh tcc          # 仅写入用户级 TCC 授权

# 方式二：免费 Apple ID 签名
cd Lumi
./sign_and_run.sh              # 编译 + 免费账号签名 + 启动
./sign_and_run.sh --adhoc      # ad-hoc 自签名（不改 TCC 数据库）

# 方式三：从项目根目录
./run_app.sh           # 编译 → 打包 .app → 签名 → 启动
./run_app.sh nobuild   # 跳过编译，仅打包并启动
./run_app.sh quit      # 退出正在运行的 Lumi
```

### Node.js 后端

```bash
# 安装依赖
npm install

# 启动服务
npm start             # 或 node server.js
./start.sh            # 一键启动（自动停旧进程）
```

### 测试

```bash
cd Lumi
swift test            # 运行纯逻辑单元测试（无需 GUI）
```

### 前置条件

- Xcode 已安装且登录了 Apple ID（用于 SwiftUI 宏和签名）
- macOS 26.5 SDK 可用（位于 `/Library/Developer/CommandLineTools/SDKs/`）
- Node.js 已安装（用于后端服务）
- 如需 MusicKit 功能，需在 `.env` 中配置 Apple Developer 凭据
