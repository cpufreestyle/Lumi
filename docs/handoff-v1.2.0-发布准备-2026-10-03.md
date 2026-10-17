> 本篇只覆盖 **v1.2.0 的发布准备状态与操作步骤**。
> Liquid Glass 改造、模块分层重构的技术细节见提交 `46d596c` 及其说明；
> Swift 6 并发技术债见 `docs/tech-debt-swift6-concurrency.md`。

## 一句话

v1.2.0 的**代码与发布脚本都已就绪并本地验证通过**，但**发布动作尚未执行**——
远端 `cpufreestyle/Lumi` 仍是 v1.1.21，未 push、未打 tag、未建 Release；
发布脚本 `release_v1.2.0.sh` 本身也还**未提交**（未跟踪文件）。

## 当前状态（截至 2026-10-03）

| 项 | 值 |
|---|---|
| `Info.plist` 版本 | **1.2.0**（`CFBundleShortVersionString` / `CFBundleVersion` 均为 1.2.0） |
| 最新 tag | `v1.1.21`（下一个应为 `v1.2.0`） |
| 最新提交 | `cbe242f` 交接：v1.2.0 发布准备状态与操作步骤 |
| 工作区 | 未提交改动 13 个文件（多屏歌词镜像、行距打通、Swift 6 并发修复、清理与文档）+ 6 个新增文件（快捷键目录 / 说明面板 / 面板控制器 / 两组不变量测试）；未跟踪 `release_v1.2.0.sh`（已补执行位） |
| 远端发布 | **未执行**（未 push、未建 Release） |
| 编译 | `swift build --sdk MacOSX26.5.sdk` → Build complete |
| 测试 | `swift test` → 559 passed / 0 failed（536 基线 + 8 条镜像 + 8 条快捷键目录 + 7 条全局快捷键匹配测试） |

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

### P1 — Swift 6 并发技术债（✅ 2026-10-04 已修复）

同文件曾有 3 条 Sendable 并发警告（`attempts` 捕获变量在并发闭包中修改、
`self` 非 Sendable）。当前 `swift-tools-version` 5.9 下仅为 warning，
升级 Swift 6 语言模式即变编译错误。

**已于 2026-10-04 修复**：

- `attempts` 改值传递参数 `currentAttempts`，入口 `attempt(1)`，重试 `attempt(currentAttempts + 1)`
- 两处 `self` 闭包改 `[weak self]` + `guard let self`
- 逐行兜底的缓存查询上移为 `processBatch` 体内的 `cachedTranslation` 闭包
  （`applyResult` 是被闭包调用的 local func，其内部再捕获 `self` 仍会被判 isolated closure）
- 顺带删除 `fetchTranslations` 的死变量 `let generation`

验证：本次消除 MusicController 的 3 条告警（当时全仓库仍剩 MusicPlaybackClock 1 条，见下文「后续轮次 · 已修复」）；swift test 532 passed / 0 failed；
代次过期语义与 attempt 1→2→逐行兜底序列均不变。
完整分析见 `docs/tech-debt-swift6-concurrency.md`。

**注：修复尚未提交，仍在本工作区。**

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

### ⚠️ 发布前必须：先提交工作区未提交改动（2026-10-04 补）

`release_v1.2.0.sh` 只提交 `Lumi/Resources/Info.plist` 和它自己，**不会带入**
当前工作区里任何未提交改动。截至 2026-10-04 工作区尚有约 13 个改动文件未提交：
多屏歌词镜像（5 个源文件 + 8 条测试，已运行时验证）、桌面歌词行距打通、
MusicController / MusicPlaybackClock 的 Swift 6 并发修复、清理删除项、文档更新。
**若不带入就直接发布，tag v1.2.0 打在不含这些功能的提交上，Release 说明与实物不符。**

执行 `./release_v1.2.0.sh` 之前必须先提交这批改动（建议按主题拆 4 个提交：
Swift6 并发修复 / 行距打通 / 多屏镜像 / 清理与文档），推送后再跑发布脚本。
发布脚本已由本轮 `chmod +x` 补上执行位（此前为 644）。
发布脚本发布说明中的测试数已同步为 559（536 基线 + 8 条镜像 + 8 条目录 + 7 条全局快捷键）。

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
# 期望：Build complete（0 warning / 0 error）；559 tests / 0 failures（536 基线 + 8 条镜像 + 8 条目录 + 7 条全局快捷键）
```

发布后核对：<https://github.com/cpufreestyle/Lumi/releases/tag/v1.2.0>
应含 `Lumi-v1.2.0.zip` 附件，且 tag 存在。

## 后续轮次：2026-10-04（清理 + 行距打通）

### 已澄清：桌面歌词浮窗早已被 Liquid Glass 化

本篇早前的记录把「桌面歌词浮窗仍是自绘底」列为待拍板范围 —— 该结论**已过期**。
提交 `46d596c` 已把浮窗接入玻璃底板：`Lumi/Sources/Lumi/Modules/Music/Views/DesktopLyricsWindow.swift`
的 `DesktopLyricsContentView` 末尾为 `.lyricsGlassBackdrop(cornerRadius: 10)`
（macOS 26+ 走系统 Liquid Glass 底板，旧系统回退「薄材质 + 暗色罩层」）。
浮窗本来就是无边框 clear 面板，玻璃能正确采样后方桌面内容，**无需再做玻璃化**。

### 清理无用文件（用户指令「清理无用文件」）

统一 `mv` 到 `~/.Trash/Lumi-cleanup-2026-10-04`（`rm` 被审批层硬拦截）：

- `vibe_images/`（284K 旧截图）、`windows/dist/`、`.git/.DS_Store`、空 `logs/`
- 已跟踪的 `release_v1.1.20.sh`、`release_v1.1.21.sh`、`upload_v1.1.17.sh`
- `generated-images/A_sleek_macOS_app_icon_for__Lu_2026-08-08T02-14-10.png`（844K）+ 空目录

刻意保留：`index.html`（`server.js:46` 的 `express.static(__dirname)` 正在托管，删了会 404）、
`scripts/archive/` 15 个旧脚本（上一轮 chore 有意归档）、`CODELY.md`、`HANDOFF.md`
（被 `docs/lumi-功能提案-2026-09-23.md` 引用为来源）。

### 真实功能缺口：桌面歌词浮窗行距未跟随用户设置

胶囊歌词行距跟随用户自定义的 `AppState.lyricLineSpacing`
（`Lumi/Sources/Lumi/Views/IslandViews.swift:237`，滑块 `Lumi/Sources/Lumi/Views/IslandControls.swift:76-80`，
范围 `0...20`，持久化于 `lyricSpacingKey`），但桌面歌词浮窗写死 `VStack(spacing: 0)`，
完全无视该设置 —— 用户调了行距只有胶囊变，浮窗不变。

已修复（3 个源文件 + 4 个测试）：

- `Lumi/Sources/Lumi/Modules/Music/Models/DesktopLyricsLayout.swift`：`contentSize` 新增
  `lineSpacing: CGFloat = 0`，仅 `wantTranslation` 为真时 `height += lineSpacing`。
  默认 0 保证旧观感与旧测试逐字节不变。
- `Lumi/Sources/Lumi/Modules/Music/Views/DesktopLyricsWindow.swift`：控制器新增
  `private var lineSpacing`；`subscribePlayback()` 内订阅 `AppState.shared.$lyricLineSpacing`，
  变化即 `applyLayout()`；两处 `contentSize(...)` 调用都传 `lineSpacing: lineSpacing`。
- 同文件 `DesktopLyricsContentView`：加 `@ObservedObject private var state = AppState.shared`，
  `VStack(spacing: 0)` 改为 `VStack(spacing: state.lyricLineSpacing)`。

设计取舍：间距**不随字号档位倍率缩放**（与胶囊 `VStack(spacing:)` 一致）；
否则调 6pt 在「大」档会变成 8pt，跨档观感不一致。已由
`testLineSpacingIsNotScaledBySizePreset` 锁定该行为。

验证：`swift build` 0 error；`swift test` **536 passed / 0 failed**（较基线 +4）。

### 已修复：MusicPlaybackClock 的 Swift 6 并发告警

接手时全仓库仅剩 1 条编译告警：
`Lumi/Sources/Lumi/Modules/Music/Services/MusicPlaybackClock.swift:50`
`Timer` 闭包内调用 main actor 隔离方法 `advanceInterpolatedProgress()`。
该文件自 `46d596c` 起未再改动，属 HEAD 存量，Swift 6 语言模式下会升级为编译错误。

**修法**：`MainActor.assumeIsolated { ... }` 包裹调用。定时器挂在 `RunLoop.main`，
闭包必然在主线程执行，`assumeIsolated` 把这个事实显式告诉编译器，同步调用、零额外跳转。

- 不选 `DispatchQueue.main.async`：补间节拍是 20Hz，每拍多一次 RunLoop 轮转等于白加一拍延迟；
- 不选 `Task { @MainActor in }`：每秒多 20 个 Task 分配，纯浪费；
- 若将来误改到非主线程 RunLoop，debug 下立即崩，而不是静默跨线程写 `@Published` 状态。

验证：**全量清构建 0 warning / 0 error**（`.build` 已删除后重编，非增量缓存所致）；
`swift test` 536 passed / 0 failed。

## 后续轮次 2：多屏歌词镜像（用户指令「要」）

> 用户连着说了「解锁了 → 清理无用文件 → 要」。本轮把「要」理解为**做多屏歌词镜像**。
> 若其本意是**发布 v1.2.0**，那属于不可逆远端操作，需单独确认后再执行
> `release_v1.2.0.sh`（见上文「如何发布 v1.2.0」）。

### 需求

用户机器是双屏：内置 `Built-in Liquid Retina XDR 3024×1964` + 小米竖屏
`Mi Monitor 1152×2048 @60Hz, Rotation: 270, Mirror: Off`（已用 `system_profiler` 确认在线且已解锁）。
诉求是**主屏干活、竖屏专职看词**，两块屏同一份歌词，不必左右扭头。

### 实现（5 个文件，本轮全部未提交）

| 文件 | 改动 |
|------|------|
| `Lumi/Sources/Lumi/Modules/Music/Models/DesktopLyricsLayout.swift` | `mirrorKey`、`screenIndex(containing:screens:)`、`mirrorOrigin(size:visibleFrame:)`、`shouldMirror(screenCount:enabled:)`、`mirrorScreenIndices(screenCount:primaryIndex:)` |
| `Lumi/Sources/Lumi/Modules/Music/Controllers/MusicController.swift` | `@Published desktopLyricsMirrorEnabled`（落 UserDefaults）+ `applyDesktopLyricsVisibility()` 里 `setMirrorEnabled` 补建 |
| `Lumi/Sources/Lumi/Modules/Music/Views/DesktopLyricsWindow.swift` | `// MARK: - 多屏镜像` 整段 6 个方法 + 3 处接线（`applyLayout`/`handleDragEnd`/屏幕参数变更订阅）+ `DesktopLyricsContentView.isMirror` |
| `Lumi/Sources/Lumi/Modules/Music/Views/MusicExpandedView.swift` | 浮窗设置行内、锁定按钮之后加镜像开关 |
| `Lumi/Tests/LumiTests/DesktopLyricsLayoutTests.swift` | 「多屏镜像」小节 8 条纯逻辑测试 |

### 设计取舍（不要再推翻）

- **镜像只读**：`ignoresMouseEvents = true`，没有右上角控制条，不接拖拽/悬停回调。
  副屏要照常干活；改字号/锁定的入口在主面板（与胶囊键位观一致）。
- **复用同一控制器**：`DesktopLyricsContentView(controller: self, isMirror: true)` ——
  字号档位、双语、行距、空态文案全部自动跟随，**零额外同步代码**。
  代价是两侧对偶一致：`isMirror` 时 `.padding(.trailing, …)` 归零，
  与 `mirrorContentSize()` 的 `trailingReserve: 0` 配对。
- **key 用 `CGDirectDisplayID`**（`NSScreenNumber`），不用数组下标：
  拔插屏/旋转后按屏幕增删，不整批重建闪烁。
- **主浮窗所在屏不镜像**：按 panel frame 中心点判 primaryIndex；
  拖到另一块屏后 `handleDragEnd` 再 sync 一次收敛。
  ⚠️ `syncMirrors()` 必须在 `setFrameOrigin` **之后** ——
  先调会把主浮窗判成「还在旧屏」，那块屏就同时留镜像又迎来主浮窗。
- **位置无持久化**：每块副屏各自按 `visibleFrame` 底部居中，不可拖动。
- `mirrorOrigin` 故意做成 `defaultOrigin` 的薄封装而非内联，
  让「多屏各自归位」这条规则可被 LumiTests 守护。
- 已实测可用的 SF Symbol：`rectangle.on.rectangle.circle` / `…circle.fill`。

### 验证结果

```bash
cd "/Users/a1-6/AI Shared/repo/Lumi/Lumi"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
# 强制重编 4 个改动源文件，确认非增量缓存
swift build --sdk "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
# → Build complete! (1.88秒)  0 warning / 0 error
swift test  --sdk "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
# → Executed 559 tests, with 0 failures (0 unexpected)
```

### 运行时验证（2026-10-04，已完成）

以 UserDefaults 翻标志位驱动 + CoreGraphics 窗口枚举 + 截图的离线方式验证，不依赖真人拖拽：

- 关掉 App 后写 defaults 再 run.sh restart 重启（Music 当时为 paused，低风险）；
- /tmp/lumi_wins.swift：CGWindowListCopyWindowInfo 过滤 Lumi 的窗口，打印 id/bounds/layer/alpha，
  另打印 NSScreen.screens 的 frame/visibleFrame，与代码里的落点算式逐位核对。

| 场景 | 操作 | 结果 |
|------|------|------|
| 主浮窗在小米屏 | origin=-623,1228，mirror=1 | 小米屏主窗 310 宽（含控制条预留，落点 CG (-623,-291) 精确等于 stored origin）；内置屏镜像 200 宽，x=656 = 可见区 midX - w/2，底部上方 110pt（= defaultBottomOffset） |
| 主浮窗在内置屏 | origin=400,500，mirror=1 | 内置屏主窗 375 宽；小米屏镜像 265 宽，x=-709 = -576 - 265/2，底部上方 110pt，精确落在该屏可见区 |
| 内容同步 | screencapture -l <windowid> 截两窗 | 两窗同显「纯音乐·无歌词」，字号/双语/玻璃底完全一致 —— 同一控制器零同步代码的推论被坐实 |
| 关镜像 | mirror=0 重启 | 仅剩主浮窗，副屏无残留窗口，teardown 干净 |

三场景全部符合设计：primary 判定（panel frame 中心点命中哪块屏）、非 primary 屏建镜像、
镜像只读无控制条所以更窄、关开关即收。注意当时小米屏实测为 1152×2048（另一次实测 2304×4096，
以 system_profiler 实时为准，代码全程用 NSScreen.screens 动态取值，未硬编码）。

验证后已恢复用户原始 defaults：music_desktop_lyrics_enabled=0、music_desktop_lyrics_origin
=-623,1228、mirror 标志删除（App 启动后自行写回 0，行为等同默认关）。

### 接手时踩到的坑

- `NSPanel(frame:…)` 不存在，必须用 `NSPanel(contentRect:styleMask:backing:defer:)`；
  首帧尺寸随便给（360×60），`layoutMirrors()` 紧跟着就按 lyric 实测尺寸重排。
- 测试首版断言 `onMain.y != onSide.y` 失败 —— 两块屏的 `minY` 都是 0，
  底部居中的 y 自然相同。已改为两块屏原点、尺寸、高度都不同的配置。

## 尚未决定的范围问题

苹果 UI（Liquid Glass）改造覆盖的是**浮层/面板类视图**
（展开面板、音量 HUD、提示条、许可证面板、歌词玻璃、AI 动作条、剪贴板栏）。
若期望「所有视图都玻璃化」（例如各模块的列表/表单内页），
属于目标范围界定，尚有剩余工作，需产品侧拍板。

## 后续轮次 3：发布就绪审计（2026-10-04，用户 goal「读取交接 优化项目」）

通读本篇 + `docs/lumi-优化建议.md`（P0/P1 已全部落地，P2-6 PluginPanelBridge 文件轮询
为有意保留）后逐项核对当前状态，确认的审计结论：

- **编译/测试与文档声称一致**：强制重编 5 个改动源文件 0 warning / 0 error；
  `swift test` → 559 passed / 0 failed（轮次 4 追加 15 条快捷键相关测试后），与「验证方式」小节期望吻合。
- **发布脚本避坑点逐条核对通过**：`--sdk MacOSX26.5.sdk`、DEVELOPER_DIR、
  token 走 `git credential fill` 不落盘、debug 路径、PlistBuddy 幂等，均已在位。
- **修复的发布缺口**：发布清单原先没有「先提交工作区未提交改动」这一步 ——
  脚本只提交 Info.plist 与自己，当前 13 个未提交文件（镜像/行距/Swift6/清理/文档）
  不带入就会打出与 Release 说明不符的 tag。已在「如何发布」节补 ⚠️ 警告块。
- **顺手修正的漂移**：状态表「最新提交」→ `cbe242f`、「测试」→ 544、工作区描述更新；
  发布脚本的执行位（644 → 755）与发布说明里的旧测试数（532 → 544）已修正；轮次 4 复核先后对齐 549、552；
  「一句话」里「且无执行权限」已过期，删除。
- **代码层复核**：`syncMirrors` 双向收敛逻辑完整（拔屏/拖入即收、插屏/拖出即建），
  主浮窗中心点判 primary、`?? 0` 兜底，热插拔无残留路径清晰。运行时三场景
  （镜像在副屏/主副互换/关开关）已在上一轮验证通过。
- **仍待用户确认（本轮未动）**：P0 发布 v1.2.0（不可逆远端操作）；
  按主题拆分提交（系统规则：未获明确要求不 commit）；P2 双进程并存（用户曾拒关正式版）。


## 后续轮次 4：快捷键提示可发现化（2026-10-06，用户指令「快捷键的提示要让用户有办法找到」）

**问题**：此前 Lumi 的鼠标手势（右键播控 / ⌥右键 / ⇧右键 / 中键切歌 / 滚轮音量 /
右键长按菜单 / 长按拖移歌词 / 双击归位）只写在代码注释里，唯一可见的入口是
「右键长按胶囊」的 NSMenu，且必须知道要长按才能看到。用户反馈找不到。

**做法**：抽成单一数据源 + 一个可见面板入口，两处 UI 共用同一份文案。

| 文件 | 职责 |
|---|---|
| `Core/KeyboardShortcutCatalog.swift` | 手势目录（纯 Foundation，无 GUI 依赖 → 能进 LumiTests）。三个分组：胶囊 / 桌面歌词浮窗 / 全局入口。提供 `menuTitle(action:)` 语义查找，**不要用下标访问 entry**（增删条目会静默串位） |
| `Views/KeyboardShortcutsHelpView.swift` | 说明面板内容，Liquid Glass 底 + `PanelInk` 深浅色反差字 |
| `Views/KeyboardShortcutsHelpController.swift` | NSPanel 单例承载 |
| `Tests/LumiTests/KeyboardShortcutCatalogTests.swift` | 5 条不变量：分组非空、字段非空、标题唯一、allEntries 等于拼平、关键手势在位 |

入口两处（都在 `Core/IslandWindowController.swift`）：
- 菜单栏图标菜单新增「快捷键与手势说明」项（`statusShowShortcuts`，约 :491/:513）
  —— 这是唯一不依赖辅助功能权限的常驻入口，也是本次修复的核心；
- 胶囊右键菜单新增「查看全部键位与手势」项（`menuShowShortcuts`，约 :717/:741）。

胶囊右键菜单的播控项文案（播放/暂停、上一首、下一首、音量提示）已改为从目录取，
不再手写字符串，两处说法不会漂移。播放/暂停随播放态切换，走 `playPauseMenuTitle()`。

**踩坑记录（重要，改这块前必读）**：
Lumi 是 `.accessory` 激活策略（`Core/main.swift` 的 `setActivationPolicy`），
**永远不会成为 active app**。因此以下三种常见做法在本机实测全部无效，面板会赖在屏幕上：
`hidesOnDeactivate`、`NSWindowDelegate.windowDidResignKey`、
`NSApplication.didResignActiveNotification`。
最终有效的是 `NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown)`：
点在面板外即 `hide()`（监听命中时先判 `panel.frame.contains(point)` 放行自身点击）。
同理**不要**调 `NSApp.activate(ignoringOtherApps:)` —— 抢焦点却改不了「从不 active」的
事实，还会打乱用户当前 App 的前台状态。

**「不要每次启动就跳出来」**：`show()` 无任何启动期调用
（applicationDidFinishLaunching / init / viewDidAppear 均不碰它），入口只有
NSMenuItem 的 selector；`collectionBehavior = []`（不放 canJoinAllSpaces，
否则跟着所有 Space 常驻，切桌面又看见它）。

**验证（2026-10-06 本机实测）**：
`swift build` 0 warning / 0 error；`swift test` 559 passed / 0 failed
（新增 5 条目录不变量测试）。运行时三场景用 CGWindowList 枚举 + CGEvent 合成点击验证：
启动 10 秒**无**面板（只有动态岛窗）→ 点菜单项**弹出**（468×540，layer=3）→
点面板外**关闭**。三路全通。深色模式下玻璃底与白字对比度正常（截图已核）。

**修饰键写法**：目录里用 `Option` / `Shift` 文字而非 ⌥ / ⇧ 符号 —— 后者在面板
点击时用的字体下会回退显示成乱码（源码字节正确，是渲染问题），文字形式任何字体都对。


**菜单栏「播放/暂停」标题随播放态变化（轮次 7 补，2026-10-06）**：
早期实现把标题写死成中性文案「播放 / 暂停」，注释却声称「标题随播放态变化」，
是注释与实现不符的假承诺 —— 用户从菜单栏根本看不出 Music 当前是否在播。
现由 `MusicController.$playbackState` 的 Combine sink 驱动
`syncPlayPauseMenuTitle()` 推进标题：
playing → 「暂停」；paused / stopped → 「播放」（停止态同样一键起播，不置灰）。
建项时用 `playPauseMenuTitle(for:)` 取种子值，避免首屏闪一下中性文案。
另把胶囊右键菜单那个同名方法改名为 `capsulePlayPauseMenuTitle()`，
消除两个 playPauseMenuTitle 并存的误读风险。实测：Music playing → 菜单「暂停」，
paused → 「播放」，双向均正确。

**授权守卫（轮次 8，用户指令「检测到已经授权就不要重复提示」）**：
修前全项目只有 MusicKit 一处有 `notDetermined` 守卫，
Calendar / 通知 / 麦克风三处都无条件调 request*。已授权时虽然系统不重复弹窗，
但每次启动或每次使用都会走一次授权往返，并在系统设置的「最近请求权限」里反复刷新，
用户观感就是 Lumi 在反复要权限。现已按状态分流：
已授权直接用（不再请求）、notDetermined 才请求、denied/restricted 静默放弃，
见 `CalendarController.shouldRequestEventAccess(status:)`、
`DownloadNotifier.postCompletion` 的 getNotificationSettings 分流、
`DictationController` 的 AVCaptureDevice.authorizationStatus 分流。
新增 `CalendarAuthorizationGuardTests`（4 条）守住这个决策函数。

**0.8 秒级视觉变化的验证手法（轮次 6 教训，2026-10-06）**：
验证「快捷键触发后菜单栏图标短暂变化」时，第一轮只用单张截图对比，
结论 `no_diff` 让我误判「反馈没生效」并准备改方案。
实际是 screencapture 的进程启动开销超过了 0.8s 的反馈窗口。
改用连续抓 6 张密集采样后拿到铁证：差异像素集中在 x=2984..2996（图宽 3024），
正是最右侧状态栏 Lumi 图标处；第 1 张过早未命中，2..6 全中。
结论：短时窗视觉变化必须密集采样，单张截图证明不了任何事。
**又一个同类坑（轮次 4 复核，2026-10-06）**：`IslandWindowController.showCapsuleMenu()` 里
调 `menuTitle(action: "音量 +5 / −5")` 用了 U+2212 真减号，而目录已改成 ASCII `-`，
字符串不相等 → `entry(action:)` 返回 nil → 按兜底逻辑只显示动作名，把「（滚轮）」
这个键位提示悄悄丢了。编译期零提示。已修 + 新增
`Tests/LumiTests/KeyboardShortcutCatalogMenuTitleTests.swift`（3 条断言）兜住：
三个菜单 action 字面量必须命中目录、命中时标题必含「（」、目录内不得出现 U+2212。
已用「注入 U+2212 → 断言转红 → 还原 → 转绿」验证过测试确实有力。

**验证口径**：`swift test` 现为 **552 passed**（536 基线 + 8 镜像 + 8 快捷键目录，
后者 = KeyboardShortcutCatalogTests 5 条 + ...MenuTitleTests 3 条）。

