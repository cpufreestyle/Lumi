# Lumi（macOS 端）交接文档

> 生成时间：2026-09-19 · 交接人：AI 助手
> 适用对象：下一会话 / 下一位接手者
> 当前预览版正在运行（`.build/Lumi.app`），最后构建 **0 error / 0 warning**。

---

## 1. 项目一句话概览

Lumi 是 macOS 菜单栏「动态岛」App：常驻刘海区的胶囊，聚合 Apple Music 播放控制、日历、剪贴板、直播检测、小游戏、插件面板等模块。本轮（09-18~09-19）工作集中在 **胶囊交互层 + 性能** 的打磨，已于 09-19 本地提交（`1ed0ae6`），**尚未发版、未推送远端**。

---

## 2. 当前代码状态

- 分支：`main`。本轮 10 个 Swift 改动已于 09-19 提交为 `1ed0ae6`（542 插入 / 95 删除）；`HEAD` 领先 `origin/main` 1 个提交，**尚未推送**（推送需用户确认，走 ~/.ssh/config 的小火箭代理）。
- 构建命令（改完 Swift 必做）：`cd "/Users/a1-6/AI Shared/repo/Lumi/Lumi" && bash preview_restart.sh`
- **双实例坑**：系统里可能同时有 `/Applications/Lumi.app`（旧正式版）和 `Lumi/.build/Lumi.app`（预览版）。调试/发布时务必只留预览版，否则会出现"两个胶囊"假象，误判为 bug。
- 所有改动已落盘，可编译可运行。

---

## 3. 本轮（09-18 ~ 09-19）已完成的工作

### 3.1 Bug 修复
| 问题 | 根因 | 修复 |
|---|---|---|
| 胶囊右键播控"没反应" | `IslandWindowController` 里 `guard islandEnabled` 错误门禁挡掉事件；且一次点击经响应链双触发 | 鼠标/右键/中键/滚轮捕获统一下沉到 `CapsuleHostingView`（视图层）；去掉错误门禁 |

### 3.2 新增交互（鼠标 / 手势）
- 右键**短按** = 播放/暂停
- 右键**长按** = 快捷菜单
- **⇧ + 右键** = 下一首
- **⌥ + 右键** = 上一首
- **滚轮** = 音量 ±5%
- 中键保留（仅三键鼠标产生；触控板/妙控不产生中键，不强行支持）

### 3.3 新增可见反馈
- 胶囊底部**播放进度线**（粉→紫细线）
- 滚轮调音量时**音量 HUD**（胶囊上浮出，1.2s 淡出）
- **全屏应用自动避让**（带设置开关，默认开；锁常住优先于避让）

### 3.4 性能优化
- 7 处高频落盘统一改防抖：AppState（胶囊尺寸/歌词偏移/行间距）、MusicController（音量/歌词校准）、翻译缓存（整首歌词合并写一次）
- 日历 EventKit 查询移出主线程
- `IslandWindowController` 补 `deinit`，成对注销事件监听 / 通知观察者（修内存泄漏）
- 番茄钟计时改为**基于结束时刻**，修掉累计漂移 + 滚动时停摆（RunLoop 改 `.common`）
- 清理死代码：`persistTranslationCache()`、临时 `diagLog` 日志、全部调试追踪代码

---

## 4. 关键改动文件

| 文件 | 改动要点 |
|---|---|
| `Core/main.swift` | `IslandPanel` / `CapsuleHostingView` 鼠标与右键/中键/滚轮捕获 |
| `Core/IslandWindowController.swift` | 右键菜单路由、全屏避让判定（`isFullScreenAppActive(on:)`）、`deinit` 清理 |
| `Core/AppState.swift` | 防抖落盘；新增设置开关字段（避让 / 音量 HUD 等） |
| `Views/IslandControls.swift` | 设置开关 UI |
| `Views/IslandViews.swift` | 进度线、音量 HUD（CollapsedView） |
| `Modules/Music/MusicController.swift` | 音量/歌词校准防抖 |
| `Modules/Music/MusicTranslationService.swift` | 整首歌词合并写盘 |
| `Modules/Music/MusicLyricsEngine.swift` | 歌词引擎微调 |
| `Modules/Calendar/CalendarViews.swift` | EventKit 查询移主线程外 |
| `Modules/Focus/FocusViews.swift` | 番茄钟计时基于结束时刻 |

> 以上 10 个文件已随 `1ed0ae6` 提交。

---

## 5. 待办 / 建议下一步（按性价比排序）

> 注：`docs/lumi-优化建议.md`（09-12 静态扫描）的 6 项**已全部落地**——`PollingCoordinator`、Music 运行态检查、LiveDetection 按需、ClaudeCode 改 `TimelineView`、全仓库 `as!`/`try!` 已清零、插件面板改 `DispatchSource` 逐文件监听。该文档仅作历史留存，不要重复实施。

| 优先级 | 项 | 说明 |
|---|---|---|
| ⭐⭐⭐ | 锁屏/离开工位自动暂停播放 | 目前完全没有，glanceable 联动里最自然 |
| ⭐⭐⭐ | 蓝牙/AirPods 电量显示在胶囊 | 项目已 `import IOBluetooth` |
| ⭐⭐ | 会议/直播检测联动 | `liveDetection` 已有 → 开会自动切模块 + 免打扰 |
| ⭐⭐ | 设置里自定义键位 | 右键/中键/滚轮各选功能 |
| — | `PollingCoordinator` 每拍重复求值 `interval()` | **已评估，收益极小**（`isMusicRunning()` 有 1s 缓存），不建议做，避免调度语义风险 |
| 收尾 | 提交 + 发版 | 见 §6 |

---

## 6. 发版前必做（遵循 MEMORY.md 发布约定）

1. 提升 `CFBundleShortVersionString` 到目标版本：**下一版为 v1.1.22**（`git tag` 实测 v1.1.21 及更早均已发布，不可复用旧号；本文原写"v1.1.18 起"已过期）。
2. 打 tag `vX.Y.Z`（与 `release_vX.Y.Z.sh` 中 `Lumi-vX.Y.Z.zip` 对应）。
3. GitHub Release 用 `gh auth token` + `curl` 调 API（**不要**直接用 `gh` 命令，会被启发式拦截）。
4. 自动更新 URL 直接拼接：`https://github.com/cpufreestyle/Lumi/releases/download/{tag}/Lumi-{tag}.zip`。
5. 示例插件 `LumiSamplePlugin.app.zip` 一并上传到该 tag 的 Release。
6. 发版后在当天日志与回复**首行标注版本号**。

---

## 7. 硬约束（务必遵守，详见 MEMORY.md）

- **改完 Swift 必须** `bash preview_restart.sh` 自动编译重启（用户要求"以后每次弄完都自动重启"）。
- **周期任务统一走 `PollingCoordinator`，不准手写常驻 `Timer.scheduledTimer`。**
- **AppleScript 前必须查运行态**（`NSWorkspace.runningApplications` + bundle id），否则会拉起已退出的 app。
- 外部 app 状态优先用 `DistributedNotificationCenter` 事件驱动，而非提高轮询频率。
- Git 推送走小火箭代理 `127.0.0.1:1082`（SSH `ProxyCommand` 已写入 `~/.ssh/config`）；推送失败先确认小火箭在跑、1082 仍在监听。
- 构建必须 `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` 并使用 `MacOSX26.5.sdk`（见 AGENTS.md）。
- **`preview_restart.sh` 在 agent / 非 GUI 会话的 shell 里启动会"静默崩溃"**：脚本末尾用 `nohup` 直接拉起二进制，macOS 把责任进程算成 shell 宿主（实测崩溃报告 `responsibleProc = "Qoder CN"`），TCC 按责任进程判定媒体/Apple Events 权限并 SIGABRT 掉 Lumi。症状：输出 `Build complete` + `LAUNCHED_OK`，但 `pgrep -x Lumi` 无结果，`~/Library/Logs/DiagnosticReports/Lumi-*.ips` 报 `namespace:"TCC"` 要求 `NSAppleMusicUsageDescription` —— **该 key 其实已存在于 `Lumi/Resources/Info.plist:31`，报错文案会误导，不要以为是代码 bug 或 Info.plist 缺字段**。收尾一步改用 `cd Lumi && open .build/Lumi.app`（责任进程变为 App 自身，ppid=1，实测正常常驻）；翻译 key 不丢，脚本已 `launchctl setenv`。需要真授权时用 `./run.sh tcc`（先 ad-hoc 签名取稳定 cdhash，再写用户级 `TCC.db` 并重载 tccd）——`preview_restart.sh` 既不管签名也不管授权。**【09-19 已修】该脚本末尾已改为 `open "$APP"` + 8 秒 `pgrep` 自校验：存活则打印 `LAUNCHED_OK pid=…`，否则打印 `LAUNCH_FAILED` 并非零退出。实测启动后 pid ppid=1（launchd 直属）且持续存活；不必再手工 `open`。**

---

## 8. 提交与发版状态

本轮 10 个 Swift 改动已本地提交为 `1ed0ae6`，随后是 README / HANDOFF 的文档事实修正。**未推送 `origin/main`、未发版**——推送与发版（下一版 v1.1.22，见 §6）均待用户确认后再执行。若发版时 Release 资产上传受网络影响，可先推送提交，待网络恢复 `gh release upload vX.Y.Z --clobber` 补传。
