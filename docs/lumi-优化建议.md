# Lumi 优化建议（2026-09-12 代码静态扫描）

## 结论摘要

最大的问题集中在**四处永不停止的常驻轮询**。其中最严重的是 `MusicController` 每 1.5 秒无条件执行 `tell application "Music"` 的 AppleScript——AppleScript 的 `tell application X` 在目标未运行时**会启动该应用**，而全仓库 Music 模块没有任何运行态检查，意味着**用户退出 Music.app 后会被 Lumi 反复拉起**。建议优先止血。

---

## P0（建议尽快处理）

### 1. Music 1.5s AppleScript 轮询：持续跨进程开销 + 会把 Music.app 拉起

- **证据**
  - `MusicController.swift:236-241` 单例启动 1.5s 常驻 Timer → `fetchInfo()`（`:257`）→ `fetchInfoSync()`（`:261`），内部 `tell application "Music"`
  - 全仓库 Music 模块**没有任何** `runningApplications` / `NSWorkspace` 运行态检查（0 处匹配）
- **影响**
  - AppleScript `tell application X` 在目标未运行时会启动该应用 → 用户退出 Music 后会被 1.5s 轮询重新拉起，Music 无法保持退出
  - 持续跨进程调用，菜单栏常驻 App 的长期 CPU/能耗负担
- **建议**
  1. **先加运行态检查**（改动最小）：仅当 Music 在运行时才发 AppleScript（用 `NSWorkspace.shared.runningApplications` 判断）
  2. **事件驱动**：监听 `DistributedNotificationCenter` 的 `com.apple.Music.playerInfo`，播放/暂停/切歌即时更新
  3. 仅在"播放中"保留低频兜底（5–10s）用于进度同步；暂停/退出即停止轮询
- **收益**：消除 Music 自启动、大幅降低常驻开销
- **成本**：止血项低；完整改事件驱动中等

### 2. LiveDetection 每 2s 采集：fork 子进程 + AppleScript，且永不停止

- **证据**：`LiveDetectionViews.swift:46` 单例 `init` 启动 2s Timer → `refresh()`（`:94`）
- **代码注释自述**："采集涉及同步子进程（pmset / defaults）与 AppleScript，耗时可达**数百毫秒**"
- **影响**：每 2 秒 fork 子进程并跑 AppleScript，即使用户从不打开该面板；能耗与系统负载明显
- **建议**
  1. 改**按需**：仅在面板可见（`isExpanded && activeModule == .liveDetection`）时按 2s 跑，不可见即停
  2. **事件驱动**替代轮询：外观变化用 `NSWorkspace` 通知，电源状态用 IOKit 通知，去掉 `pmset` 子进程 fork
  3. 不可见时最多保留 60s 低频兜底
- **收益**：显著降能耗，去掉周期性子进程 fork
- **成本**：中

### 3. 四处常驻轮询统一改「按需」

| 位置 | 间隔 | 动作 | 是否常驻 |
|---|---|---|---|
| `LiveDetectionViews.swift:46` | 2s | `refresh()`（子进程 + AppleScript） | 是，永不停止 |
| `MusicController.swift:237` | 1.5s | `fetchInfo()`（AppleScript） | 是，永不停止 |
| `CalendarViews.swift:16` | 60s | `fetchEvents()`（EventKit 查询） | 是，永不停止 |
| `PluginPanelBridge.swift:138` | 1s | 读 JSON 文件 | 是（已优化到后台队列） |

- **可行性**：`AppState.swift:68-69` 已有 `activeModule` 与 `isExpanded`，足以驱动"可见才轮询"
- **建议**：引入统一的 `PollingCoordinator`，集中管理 start/stop、统一 `[weak self]`、统一 RunLoop `.common`（避免滚动时定时器暂停）；各模块注册自己的间隔与可见条件，不可见时 `invalidate()` 并置 `nil`
- **收益**：一处改造覆盖四个模块，消除后台空转
- **成本**：中（收益面最大）

---

## P1

### 4. ClaudeCode 用 0.4s Timer 驱动纯 UI 点动画

- **证据**：`ClaudeCodeViews.swift:357-365`，Timer 每 0.4s 只做 `dotCount += 1`；闭包用 `[self]` 强捕获（其余模块均为 `[weak self]`）
- **影响**：每 0.4s 触发 SwiftUI body 重算（约 2.5Hz 无谓重渲染）。`onAppear/onDisappear` 有 `invalidate()`，故不泄漏，但属纯浪费
- **建议**：改用 SwiftUI 原生动画（`TimelineView` 或 `.animation`/`withAnimation`）实现省略号动效，删除该 Timer；捕获统一为 `[weak self]`
- **收益**：去掉 2.5Hz 无谓重渲染
- **成本**：低

### 5. 消除强制解包，降低崩溃风险

- **分布**：`GameViews`(4)、`MusicLyricsEngine`(3)，以及 `CalendarViews` / `Updater` / `VideoDownloadViews` / `LicenseManager` / `PluginPanelBridge` 各 1
- **风险**：`as!` 在类型不符时直接崩溃，对常驻菜单栏 App 是硬性稳定性风险
- **建议**：改为 `guard let` / `do-catch` 并给出降级路径（默认值 + 日志）
- **收益**：稳定性
- **成本**：低（机械替换）

---

## P2（可选）

### 6. PluginPanelBridge 文件轮询 → 文件监听

- **现状已优化**：后台队列读、主线程仅在数据变化时写回（`PluginPanelBridge.swift:138-155`）
- 若追求零轮询：改用 `DispatchSource.makeFileSystemObjectSource` 监听目录，文件变更即触发；需加 debounce 防抖（第三方可能频繁写或非原子写）
- 代码注释已说明选轮询是为避免 XPC/复杂度 → 优先级低，属可选优化
- **成本**：中低

---

## 建议实施顺序

1. **Music 运行态检查** — 止血，阻止 Music 自启动（改动最小、收益最直接）
2. **引入 `PollingCoordinator`** — 四处轮询改按需
3. **Music 改事件驱动** — 去掉 1.5s 固定轮询
4. **LiveDetection 采集降频 / 事件驱动**
5. **ClaudeCode 动画改造 + 强制解包清理**
6. （可选）PluginPanelBridge 文件监听

---

## 备注与局限

- 本报告基于**静态代码扫描**与代码内注释自述的耗时，未做运行时 profile（Instruments）量化
- 建议实施后按项目约定执行 `cd Lumi && bash preview_restart.sh` 编译并重启预览验证
- 如需，我可以先针对某一项加轻量埋点或用 Instruments 量化，再决定改法
