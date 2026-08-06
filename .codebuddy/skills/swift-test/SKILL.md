---
name: swift-test
description: >-
  SwiftPM / macOS 原生 App 的单元测试工作流。当用户需要为 Swift 项目
  添加 XCTest 用例、配置 testTarget、在 Cursor/VS Code 里运行
  `swift test`、或排查测试编译失败（尤其是 SwiftUI 宏解析、SDK 版本、
  无登录会话导致的 GUI 框架链接错误）时使用本 skill。
triggers:
  - 添加单元测试 / XCTest
  - swift test 编译失败 / SwiftUIMacros 找不到
  - 配置 SwiftPM testTarget
  - 在编辑器里跑 Swift 测试
---

# Swift 单元测试工作流（SwiftPM / macOS）

本 skill 面向 **Swift Package Manager** 工程（可执行 App 或库），目标是建立可命令行运行、
可在 Cursor/VS Code 中一键触发的单元测试体系。

## 何时使用
- 用户要求"加测试 / 跑单测 / 配置 XCTest"。
- `swift test` 报 `external macro implementation ... SwiftUIMacros ... not found`。
- 用户想在编辑器内用 CodeLLDB / 测试 task 跑 Swift 测试。

## 核心约束（必读）
1. **工具链**：本机默认 `swift` 来自 CommandLineTools（27 SDK），**无法解析 SwiftUI 宏**。
   必须在 Xcode 工具链下运行：
   ```bash
   export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
   ```
2. **test target 不引入 GUI 框架**：`testTarget` 编译在无登录会话下执行，
   依赖 `AppKit`/`SwiftUI`/`WebKit` 等会链接/运行时失败。把被测逻辑拆成
   `internal`/`public` 纯函数（CryptoKit、Foundation、算法、编解码、校验），
   测试只覆盖这些。GUI 行为用 `Lumi (.app build & run)` / `attach` 手动验证。
3. **固定 SDK**：若 Xcode 默认 SDK 仍解析失败，回退到 `run.sh` 的
   `MacOSX26.5.sdk` 方案：`swift test --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`。

## 标准流程（SOP）
1. 在 `Package.swift` 声明 `testTarget`（见下）。
2. 在 `Tests/<Name>Tests/` 放 `*Tests.swift`，方法以 `test` 开头，继承 `XCTestCase`。
3. 运行：
   - CLI：`cd Lumi && export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift test`
   - 编辑器：运行 `swift-test` task（`Cmd/Ctrl+Shift+P` → Tasks: Run Task）。
4. 加用例时优先覆盖纯逻辑（哈希、签名验签、编解码、状态机），保证零 GUI 依赖。

## Package.swift 片段
```swift
.testTarget(
    name: "LumiTests",
    dependencies: [ .target(name: "Lumi") ],   // 仅依赖被测试的纯逻辑 module
    path: "Tests/LumiTests"
)
```
注意：`testTarget` 是独立 module，只能访问主 target 的 `public`/`open` 符号；
若需访问 `internal`，把逻辑抽到独立的、可被 testTarget 依赖的 library target。

## 示例测试（零依赖，必过）
见 `references/sample_tests.md`。包含 SHA-256 标准向量校验与 Ed25519 签名/验签往返，
用于确认工具链与 CryptoKit 可用。

## 常见故障
| 现象 | 原因 | 解决 |
| --- | --- | --- |
| `SwiftUIMacros ... not found` | 用了 27 SDK / CommandLineTools | 设 `DEVELOPER_DIR=Xcode` |
| `cannot find auto-linked framework AppKit` | test target 引了 GUI | 拆纯逻辑，移除 GUI 依赖 |
| 编辑器里无"测试"任务 | 缺 task | 加 `swift-test` task（见 `references/vscode_tasks.json`） | 

## 与调试 skill 协同
本 skill 负责**命令行/CI 单测**；GUI 行为调试交给 `launch.json` 的
`Lumi (.app build & run)` / `Lumi (attach & wait)`（CodeLLDB）。
