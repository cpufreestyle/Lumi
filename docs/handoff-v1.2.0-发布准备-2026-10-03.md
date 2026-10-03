# 交接：v1.2.0 发布准备（2026-10-03）

> 本篇只覆盖 **v1.2.0 的发布准备状态与操作步骤**。
> Liquid Glass 改造、模块分层重构的技术细节见提交 `46d596c` 及其说明；
> Swift 6 并发技术债见 `docs/tech-debt-swift6-concurrency.md`。

## 一句话

v1.2.0 的**代码与发布脚本都已就绪并本地验证通过**，但**发布动作尚未执行**——
远端 `cpufreestyle/Lumi` 仍是 v1.1.21，未 push、未打 tag、未建 Release；
发布脚本 `release_v1.2.0.sh` 本身也还**未提交**（未跟踪文件，且无执行权限）。

## 当前状态（截至 2026-10-03）

| 项 | 值 |
|---|---|
| `Info.plist` 版本 | **1.2.0**（`CFBundleShortVersionString` / `CFBundleVersion` 均为 1.2.0） |
| 最新 tag | `v1.1.21`（下一个应为 `v1.2.0`） |
| 最新提交 | `d1ee05f` 桌面歌词浮窗右键短按切换播放/暂停 |
| 工作区 | 仅 `?? release_v1.2.0.sh` 未跟踪；其余全部已提交 |
| 远端发布 | **未执行**（未 push、未建 Release） |
| 编译 | `swift build --sdk MacOSX26.5.sdk` → Build complete |
| 测试 | `swift test` → 532 passed / 0 failed |

## 本轮已完成的提交（自 `08b9269` 起，全部已入库）

| 提交 | 内容 |
|---|---|
| `46d596c` | **主提交**：MVCS 模块分层重构 + Liquid Glass 苹果 UI 改造 + AI/TV/听写/CLI 新模块 + 30 个测试（174 文件，+21191/−4132） |
| `11411c0` | `.gitignore` 排除旧图标备份 `*.pre-liquid-glass` |
| `36a42cf` | 各模块集成文档、交接记录 + 图标生成脚本入库 |
| `2a55eb1` | 版本 1.1.21 → 1.2.0 |
| `b1d13af` | 修正 `Package.swift` 过期注释（testTarget 实际依赖完整 Lumi target） |
| `ab5ce4a` | 技术债：MusicController 歌词翻译重试的 Swift 6 并发问题 |
| `d1ee05f` | 桌面歌词浮窗右键短按切换播放/暂停 |

### 为什么源码没拆成多个提交

核查发现 `Core/AppState.swift` 引用新模块 9 次、`Views/` 下 10 个文件引用
`LiquidGlass`/`PanelInk`——重构、新模块、UI 改造三者**深度互依赖**。
拆开会产生编译失败的中间提交，因此源码作为同一工作单元一次性提交；
只有不被编译的 `docs/`、`tools/`、`.gitignore` 才单独拆出。

## 待办（按优先级）

### P0 — 发布 v1.2.0（未完成，需人工确认后执行）

发布是对远端的**不可逆操作**，故在本轮暂停、未执行。执行前需确认。

### P1 — Swift 6 并发技术债（已记录，未修）

`MusicController.swift:3487-3494` 有 3 条 Sendable 并发警告
（`attempts` 捕获变量在并发闭包中修改、`self` 非 Sendable）。
当前 `swift-tools-version` 5.9 下仅为 warning，**升级 Swift 6 语言模式即变编译错误**。
未修原因：这段代码是「网络重试 + 代次防错配」的时序敏感逻辑，
草率重构易引入「译文与播放上下文错配」的偶发 bug。
修复思路与验收标准见 `docs/tech-debt-swift6-concurrency.md`。

### P2 — 运行态：双进程并存（非代码缺陷）

`/Applications/Lumi.app`（正式版）与 `Lumi/.build/Lumi.app`（预览版）若同时运行，
会出现两个胶囊。代码层面无法根治（用户曾拒绝关闭正式版）。

## 如何发布 v1.2.0（接手者照此执行）

```bash
cd "/Users/a1-6/AI Shared/repo/Lumi"

# 1. 提交发布脚本并赋予执行权限（当前是未跟踪文件、权限 644）
chmod +x release_v1.2.0.sh
git add release_v1.2.0.sh
git commit -m "发布：新增 v1.2.0 发布脚本（打包 → tag → GitHub Release）"

# 2. 执行发布（编译 → 打包 → 打 tag → push → 建 Release 并上传 zip）
./release_v1.2.0.sh
```

脚本已包含完整流程（沿用最近一次成功的 `release_v1.1.21.sh`）：

1. 用 `PlistBuddy` 写入版本号 1.2.0（幂等）
2. `swift build --sdk MacOSX26.5.sdk` 编译
3. 打包 `Lumi/.build/Lumi.app` → `ditto` 压缩为 `Lumi-v1.2.0.zip`
   （含 `codesign --deep --sign -` 与去隔离属性）
4. 提交版本号/脚本变动（无改动时跳过）
5. `git tag -a v1.2.0` + `push origin main` + `push origin v1.2.0`
6. 调 GitHub API 建 Release 并上传 zip

### 注意事项（踩过的坑）

- **必须指定 `--sdk MacOSX26.5.sdk`**：macOS 27 SDK 下 SwiftPM 无法解析
  SwiftUIMacros 宏插件；旧脚本 `release_v1.1.14.sh` 就因缺此参数而不可用。
- **必须 `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`**：
  默认 Command Line Tools 缺 SwiftUI 宏插件，会编译失败。
- **token 不得硬编码**：脚本用 `git credential fill` 动态获取，
  否则会触发 GitHub Push Protection。
- 打包路径硬编码 `Lumi/.build/debug/Lumi`（debug 配置），与历次发布一致。

## 验证方式（接手后自查）

```bash
cd Lumi
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build --sdk "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
swift test  --sdk "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
# 期望：Build complete；532 tests / 0 failures
```

发布后核对：<https://github.com/cpufreestyle/Lumi/releases/tag/v1.2.0>
应含 `Lumi-v1.2.0.zip` 附件，且 tag 存在。

## 尚未决定的范围问题

苹果 UI（Liquid Glass）改造覆盖的是**浮层/面板类视图**
（展开面板、音量 HUD、提示条、许可证面板、歌词玻璃、AI 动作条、剪贴板栏）。
若期望「所有视图都玻璃化」（例如桌面歌词浮窗目前仍是自绘底），
属于目标范围界定，尚有剩余工作，需产品侧拍板。
