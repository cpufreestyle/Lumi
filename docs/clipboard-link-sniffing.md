# 剪贴板链接嗅探 + 下载完成通报（VideoDownload 模块）

> 建立时间：2026-09-26 ｜ 关联模块：`Sources/Lumi/Modules/VideoDownload`
> 对应提案：`docs/lumi-功能提案-2026-09-23.md` 提案 7
> 对应本轮目标：**学习和调用开源项目，增加项目实用性**

## 1. 功能形态

| 能力 | 触发 | 表现 |
| --- | --- | --- |
| 剪贴板嗅探 | 开关打开后，每次系统剪贴板 changeCount 变化 | 命中视频站点白名单 → 胶囊下沿浮 `bilibili.com [MP4][MP3][忽略]`，12 秒无操作自动隐藏 |
| 下载完成闪烁 | 下载进程正常退出 | 胶囊 brief 切 `checkmark.circle.fill` + 标题，4 秒后回落进度/默认态 |
| 下载完成通报 | 同上 | 系统通知「下载完成 / 标题」，授权被拒则静默跳过 |

开关在视频下载展开态的「剪贴板嗅探」区：Toggle + 自定义域名输入（保存后立即生效），
`onAppear` 载入当前值。「忽略」只关本次浮条，不改设置。

## 2. 隐私与打扰边界（硬约束，勿回退）

- **默认关闭**：`ClipboardSniffSettings.enabled` 默认 false，只在展开态显式开启后才轮询剪贴板；
- **开启瞬间先同步 changeCount**：不把「开启前就躺在剪贴板里的内容」当成新复制弹出来；
- **只对白名单站点出手**：普通网页、文档、代码不触发，用户可在设置追加自定义域名；
- **不落盘剪贴板原文**：命中后仅在内存暂存一条 DetectedLink 供一键入队，写 UserDefaults 的只有开关与域名；
- **已在下载列表的链接不重复提示**：按 canonicalKey（剥跟踪参数后的归一化 URL）比对。

## 3. 调度：不增加常驻开销

复用项目统一调度设施 `PollingCoordinator`，注册条件是**动态**的：

    interval: { [weak self] in
        (self.settings.enabled && self.pending == nil) ? 1 : 0
    }

- 开关关闭 / 已有待处理浮条时返回 0 → 调度器退化为空闲拍，零额外负载；
- 只有「开着且没有浮条」时才占 1s 拍 → 与提案 1（划词 AI）共用同一 changeCount 源，两处订阅互不重叠；
- 下载中（vd.isDownloading == true）时**故意不更新 lastChangeCount**：此刻复制的不弹，
  等这次下载结束后的下一拍再评估当前剪贴板，避免「正在下载还一直往外蹦新链接」。

## 4. 通知 delegate 链式前级联（关键设计）

`UNUserNotificationCenter.delegate` 是**单值**，后注册者会直接顶掉前者。视频下载通报比
会议提醒调度器晚构造，若不处理就会把会议提醒的「前台横幅」打没。

    DownloadNotifier.init: previousDelegate = center.delegate   // 捕获前级
                            center.delegate = self
    willPresent / didReceive: 有前级则把 completionHandler 透传给前级，缺失才自己兜底

装配顺序因此成为隐式依赖：`Core/main.swift` 中 `DownloadNotifier.shared` 必须在
`MeetingReminderScheduler.shared` **之后**首次取值，否则 previousDelegate 捕不到会议提醒。

## 5. 复用而非重写（yt-dlp 链路）

嗅探命中后不自己拼下载参数，而是走视频下载既有链路：

    ClipboardLinkController.acceptPending(format:)
      -> vd.selectedFormat = format
      -> vd.startDownload(url:)              // 填 urlInput 后直接复用 startDownload()
           -> getTitle() -> performDownload() // 既有的 Process + --newline 进度解析

好处：格式、输出目录、进度解析、历史记录、失败态全部沿用一处实现，不引入第二套下载代码。

## 6. 域名白名单与 www 等价

白名单（`VideoLinkDetector.defaultHosts`）覆盖国际站（YouTube / Vimeo / TikTok / X / Reddit 等）
与国内站（B 站 / 抖音 / 快手 / 小红书 / 微博 / 优酷 / 爱奇艺 / 腾讯视频 / 知乎 / 公众号等）共约 40 个主机名。

踩过的坑：**用户实际复制最多的正是 `www.bilibili.com` 这种带 www. 的形式**，而白名单里
只有裸域。`isSupported(url:extraHosts:)` 因此对非白名单主机剥一次 www. 再判等价，
并用单测 `testIsSupportedWwwEquivalentToBareDomain` 锁定，防回归。

## 7. 测试

`Tests/LumiTests/VideoLinkDetectorTests.swift`（30 用例）锁定纯逻辑，不碰 GUI：

- 从混合文本里按出现顺序提取链接（复制一整段话夹一个链接的场景）；
- www. 与裸域等价、主机名大小写不敏感、自定义白名单合并；
- `canonicalKey` 剥除 utm_* / spm_id_from / vd_source 等跟踪参数；
- `pick` 排除已在下载列表的链接、非白名单返回 nil、空文本返回 nil；
- `ClipboardSniffSettings` 编解码往返与 load/save（suiteName: UUID() 注入隔离）。

## 8. 修复记录

| 时间 | 问题 | 修复 |
| --- | --- | --- |
| 09-26 | VideoLinkDetector.swift 原写 for match in matches where ... let url = match.url，Swift 不支持，整文件编译失败 | 改为 guard ... else { continue } 双段式 |
| 09-26 | 白名单缺 www. 变体，复制 www.bilibili.com 不触发 | isSupported 增裸域等价 + 单测锁定 |

## 9. 验证记录

- `swift build --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk` → Build complete!
- `swift test --sdk ...` → **221 tests, 0 failures**（含本模块 30 条）

