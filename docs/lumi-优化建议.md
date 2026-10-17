# Lumi 优化建议（2026-09-12 代码静态扫描）— 已全部落地

> **2026-10-04 复审结论：本文档的 P0 / P1 全部项均已在后续工作中落地，**
> **仅剩 P2 第 6 项（PluginPanelBridge 文件轮询）为有意保留的折中。**
> 下文每项附「落地情况」核对结果；保留原始描述作为决策背景。

## 结论摘要（复审后）

最大的问题集中在**四处永不停止的常驻轮询**。其中最严重的是 MusicController
每 1.5 秒无条件执行 `tell application "Music"` 的 AppleScript——AppleScript 的
`tell application X` 在目标未运行时**会启动该应用**，全仓库 Music 模块没有任何
运行态检查，意味着用户退出 Music.app 后会被 Lumi 反复拉起。

**以上问题现已全部解决**：

- `Core/PollingCoordinator.swift` 统一管理 8 个模块的轮询，各模块只注册
  「间隔 + 可见性条件」，不可见即 `invalidate()` 并置 `nil`；
- `MusicController.swift:876` 增加 `NSWorkspace` 运行态检查，Music 未运行时
  完全不轮询（播放中 1.5s 跟进度，暂停/停止降到 8s 兜底）。

---

## P0（已落地）

### 1. Music 1.5s AppleScript 轮询：持续跨进程开销 + 会把 Music.app 拉起 ✅

原问题（保留备查）：单例启动 1.5s 常驻 Timer 无条件执行 `tell application "Music"`，
目标未运行时 AppleScript 会启动该应用，用户退出 Music 后又被反复拉起。

**落地情况**：`MusicController.swift:843-849` 改为按需轮询，`:876` 加运行态检查。

### 2. LiveDetection 每 2s 采集：fork 子进程 + AppleScript，且永不停止 ✅

**落地情况**：`Modules/LiveDetection/Controllers/LiveDetectionController.swift:47`
已接入 `PollingCoordinator` 按需注册，面板不可见时不采集。

### 3. 四处常驻轮询统一改「按需」 ✅

| 位置 | 间隔 | 动作 | 现状 |
|---|---|---|---|
| LiveDetectionController | 2s | 子进程 + AppleScript | 已按需 |
| MusicController | 1.5s / 8s | AppleScript | 已按需 + 运行态检查 |
| CalendarController | 60s | EventKit 查询 | 已按需 |
| PluginPanelBridge | 1s | 读 JSON 文件 | 已按需（仍轮询，见 P2） |

**落地情况**：`Core/PollingCoordinator.swift` 已建成，覆盖 Music、LiveDetection、
Calendar、PluginPanelBridge、TV、Focus、ClipboardLink、Dictation 共 8 个模块。
统一 `[weak self]`、统一 RunLoop `.common`。

---

## P1（已落地）

### 4. ClaudeCode 用 0.4s Timer 驱动纯 UI 点动画 ✅

**落地情况**：`Modules/ClaudeCode/Views/CCLoadingBubble.swift` 已改用 `TimelineView`，
Timer 已删除，不再有 2.5Hz 无谓 body 重算。

### 5. 消除强制解包，降低崩溃风险 ✅

原分布：GameViews(4)、MusicLyricsEngine(3)，以及 CalendarViews / Updater /
VideoDownloadViews / LicenseManager / PluginPanelBridge 各 1。

**落地情况**：2026-10-04 复核，
`grep -rn --include="*.swift" -E "as!|try!" Lumi/Sources/Lumi` 为 0 处匹配。

---

## P2（有意保留，未改）

### 6. PluginPanelBridge 文件轮询 → 文件监听

**维持轮询**（2026-10-04 复审确认）：该桥已接入 `PollingCoordinator` 按需注册，
仅在插件面板启用时占 1s 拍，空转已消除。改用
`DispatchSource.makeFileSystemObjectSource` 需额外处理第三方频繁写 / 非原子写，
并加 debounce，复杂度和出 bug 的概率高于收益。代码注释亦已说明此取舍。

---

## 备注与局限

- 原报告基于静态代码扫描与代码内注释自述的耗时，未做运行时 profile（Instruments）量化。
- 本次（2026-10-04）复审同为静态复核：grep 定位 + 读代码注释确认实现。
- 若需进一步量化收益，建议对 Music 播放态与 LiveDetection 展开态各做一次
  Instruments Energy Log 采样，再决定是否继续降频。
