import AppKit
import CryptoKit
import Foundation
import SwiftUI

/// 歌词诊断日志的串行写入队列。
/// lyricLog 会从 scriptQueue 与多个 URLSession 回调线程进入，
/// 并发 seekToEndOfFile + write 可能交错出行，故统一串行落盘。
private let musicLogQueue = DispatchQueue(label: "com.lumi.musiclog")

// 本文件为控制器本体：状态属性、轮询、播放控制与音量。
// 歌词获取/解析、翻译补全、封面获取分别见同名 extension 文件：
// MusicLyricsEngine.swift / MusicTranslationService.swift / MusicArtworkService.swift。
// 注：部分成员的 private 已放宽为默认访问级别，供上述 extension 跨文件访问
// （单 executable 目标，不构成对外 API 暴露）。
final class MusicController: ObservableObject {
    static let shared = MusicController()

    @Published var title: String = ""
    @Published var artist: String = ""
    @Published var album: String = ""
    @Published var playbackState: PlaybackState = .stopped
    @Published var currentTime: TimeInterval = 0
    /// 最近一次「来自 Music 的真实进度」采样时刻（主线程读写）。
    /// currentTime 只能靠 1.5s 轮询取真值，歌词高亮因此被量化成 1.5 秒台阶；
    /// 播放中用墙钟在两拍之间补间，量化误差降到 0.05s（见 MusicPlaybackClock.swift）。
    var positionSampledAt = Date()
    /// 最近一次提交到 UI 的播放位置。真值采样到主线程之间存在排队延迟，Music 返回的
    /// newPosition 可能比刚补间的进度略旧；直接覆盖会让歌词先前进再拉回上一句。
    /// 同曲目播放中用它过滤短暂回跳，切歌/暂停/停止/seek 时按真值复位。
    var lastCommittedPosition: TimeInterval?
    /// positionSampledAt 时刻的真实播放位置：补间的唯一基准。
    /// 每推进一拍都按当前 elapsed 重新计算，不存在累加漂移。
    var sampledPosition: TimeInterval = 0
    /// 墙钟补间定时器（05s 一拍，仅播放中推进 currentTime）。
    var playbackClockTimer: Timer?
    /// 上次确定的歌词高亮行索引：与展开态共用同一套防抖规则
    /// （LyricsTimeline.debouncedLineIndex），避免 Music 真值回调略旧时
    /// 收缩态胶囊/桌面浮窗歌词闪回上一句。切歌时重置为 nil。
    var lastActiveLineIndex: Int? = nil
    /// 本次 UI 刷新时的实时播放位置（锚点外推到当前墙钟，纳秒级）。
    ///
    /// 为什么需要它：`currentTime` 是补间定时器一拍的**量化快照**。视图刷新与
    /// tick 并非同相位，两次 tick 之间读到的永远是上一拍的旧值。定时器原为 0.25s
    /// 时，实测快照平均滞后 124ms、最坏 250ms —— 这才是「歌词慢半拍」的主因，
    /// 比校准误差（同一链路仅 -0.4ms）大两个数量级。
    ///
    /// 定时器现已收紧到 0.05s（快照滞后均值 ~25ms），本属性再把视图侧残余压到
    /// 一帧渲染时间（~16ms）。进度条 / 时间标签 / 胶囊仍读 currentTime 兜底；
    /// 歌词高亮与双语取行走这里，因此不受 tick 相位影响。
    ///
    /// 安全性：与 `advanceInterpolatedProgress` 用同一个锚点公式，且只在
    /// playing 状态外推；暂停 / 停止 / seek / 切歌都由真值复位锚点。
    var livePosition: TimeInterval {
        guard playbackState == .playing else { return currentTime }
        let elapsed = Date().timeIntervalSince(positionSampledAt)
        guard elapsed >= 0 else { return currentTime }
        let advanced = sampledPosition + elapsed
        let clamped = duration > 0 ? min(advanced, duration) : advanced
        // 只取较新者：真值刚落时 currentTime 可能刚被写成更大的值，别让它倒退。
        return max(clamped, currentTime)
    }
    @Published var duration: TimeInterval = 0
    @Published var artwork: NSImage? = nil
    @Published var lyrics: String = ""
    /// 无时间轴纯文本歌词的整段翻译（双语模式时由联网翻译补全）。
    @Published var lyricsTranslation: String = ""
    /// 歌词取不到时的原因提示（如「纯音乐 · 无歌词」）。为空时 UI 用默认文案。
    @Published var lyricsNote: String = ""
    /// 带时间轴的歌词（Apple Music 官方歌词）。为空时 UI 退化为纯文本展示。
    @Published var syncedLines: [SyncedLine] = []
    @Published var showLyrics: Bool = true {
        didSet { UserDefaults.standard.set(showLyrics, forKey: showLyricsKey) }
    }
    private let showLyricsKey = "music_show_lyrics"

    /// 双语歌词模式。
    /// - `.off`：仅显示原文（默认历史行为）。
    /// - `.auto`：若歌词自带双语（一行内包含两种语言）则显示对照；否则自动联网翻译补全。
    /// - `.on`：无论是否自带，都联网翻译补全另一语言（与 auto 行为几乎一致，预留「强制」语义）。
    enum BilingualMode: Int, CaseIterable {
        case off = 0, auto = 1, on = 2
        var label: String {
            switch self {
            case .off:  return "原文"
            case .auto: return "双语·自动"
            case .on:   return "双语·翻译"
            }
        }
    }
    @Published var bilingualMode: BilingualMode = .auto {
        didSet {
            UserDefaults.standard.set(bilingualMode.rawValue, forKey: bilingualKey)
            // 切换模式：作废旧批次的译文写回，避免两套批次的译文交错错配
            translationGeneration &+= 1
            // 切换模式后，对当前已载入的歌词立即应用（重新翻译/回退）
            reapplyBilingualForCurrentTrack()
        }
    }
    private let bilingualKey = "music_bilingual_mode"

    // MARK: - 桌面歌词浮窗
    /// 桌面歌词浮窗开关：置顶小窗跟随当前歌词行（全屏/切 App 也能看）。
    /// 开启会懒创建 DesktopLyricsWindowController 并显示；关闭只隐藏、不销毁。
    @Published var desktopLyricsEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(desktopLyricsEnabled,
                                      forKey: DesktopLyricsLayout.enabledKey)
            applyDesktopLyricsVisibility()
        }
    }
    /// 锁定后浮窗点击穿透（不拦截鼠标、不能拖动；解锁需回到本面板操作）。
    @Published var desktopLyricsLocked: Bool = false {
        didSet {
            UserDefaults.standard.set(desktopLyricsLocked,
                                      forKey: DesktopLyricsLayout.lockedKey)
            desktopLyricsWindow?.setLocked(desktopLyricsLocked)
        }
    }
    /// 桌面歌词字号档位（小/中/大）：落 UserDefaults，浮窗悬停控制条、滚轮与
    /// 设置区药丸按钮共用同一份状态，任一处切换其余两处立即同步。
    @Published var desktopLyricsSizePreset: DesktopLyricsSizePreset = .medium {
        didSet {
            UserDefaults.standard.set(desktopLyricsSizePreset.rawValue,
                                      forKey: DesktopLyricsLayout.sizeScaleKey)
        }
    }
    /// 浮窗是否被用户主动隐藏（悬停控制条 × 或设置区按钮）。
    /// 刻意不持久化：隐藏只是当次会话的临时诉求，重启后仍跟随开关自动显示。
    @Published var desktopLyricsHidden: Bool = false

    /// 浮窗控制器（懒创建；关闭仅隐藏，重开不重建，拖拽位置等状态保留）。
    var desktopLyricsWindow: DesktopLyricsWindowController?

    /// 应用桌面歌词浮窗显隐/锁定状态（didSet 与 init 恢复默认值时共用）。
    func applyDesktopLyricsVisibility() {
        if desktopLyricsEnabled {
            if desktopLyricsWindow == nil {
                desktopLyricsWindow = DesktopLyricsWindowController(music: self)
            }
            desktopLyricsWindow?.setLocked(desktopLyricsLocked)
            desktopLyricsWindow?.showWindow()
            // 开开关等于明确「我想看浮窗」的诉求，顺手清掉上一次的临时隐藏状态。
            desktopLyricsHidden = false
        } else {
            desktopLyricsWindow?.hideWindow()
        }
    }

    /// 用户主动隐藏浮窗（悬停控制条 ×）：只藏当前窗口，不关开关、不改持久化。
    func hideDesktopLyricsWindow() {
        guard desktopLyricsEnabled else { return }
        desktopLyricsHidden = true
        desktopLyricsWindow?.hideWindow()
    }

    /// 从隐藏状态恢复浮窗（设置区「显示浮窗」按钮，或重新打开开关）。
    func showDesktopLyricsWindow() {
        guard desktopLyricsEnabled else { return }
        desktopLyricsHidden = false
        desktopLyricsWindow?.setLocked(desktopLyricsLocked)
        desktopLyricsWindow?.showWindow()
    }

    /// 歌词时间轴校准偏移（秒）。lrclib/社区 LRC 的时间轴常以 Apple Music 基准标注，
    /// 但实际播放位置可能整体早/晚数秒（前奏 offset 差异），导致逐行高亮错位。
    /// 正值表示歌词时间轴比实际播放「快」了这么多，需要把匹配基准往后推。
    @Published var lyricsOffset: TimeInterval = 0 {
        didSet {
            // 滑块拖动/点击对齐会连续触发多次，落盘合并为「停止变化 0.5s 后写一次」，
            // 避免每步都写 UserDefaults + 重写整个按曲目偏移字典。
            scheduleLyricsOffsetPersist()
        }
    }
    private let lyricsOffsetKey = "music_lyrics_offset"
    /// 按曲目保存的歌词时间轴偏移（title|artist -> offset 秒），用于跨会话记忆校准结果。
    private var offsetByTrack: [String: TimeInterval] = [:]
    private let offsetByTrackKey = "music_lyrics_offset_by_track"
    /// 当前曲目标识（title|artist），用作 offset 记忆的 key；含中文/特殊字符时用
    /// percent-encoding 保证 UserDefaults 字典 key 稳定。
    private var currentTrackKey: String {
        let raw = "\(title)|\(artist)"
        return raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw
    }

    /// 当前时刻正在唱的那一句歌词（仅返回原文，不拼接译文）。
    /// 基于 syncedLines 时间轴 + 校准偏移取当前行；无时间轴或前奏时回退整段歌词。
    /// 双语模式：由 UI 层自行在「当前原文」基础上另起一行/另一控件展示译文，
    /// 避免原本「原文 · 译文」拼接成单条字符串后既被黑岛 MarqueeText 跑成左右并排，
    /// 也污染了展开态「当前句」区块把整串当 zh 显示的问题。
    var currentLineText: String {
        currentLyricPair.text
    }

    /// 一次算出「当前原文 + 当前译文」，避免 refresh 链路上重复调
    /// currentLineText / currentLine / currentTranslationText 导致同一帧内
    /// 多次重算防抖状态（写三遍 lastActiveLineIndex 纯属浪费，且
    /// 任何一处将来若改成 @Published 都会立刻引发刷新风暴）。
    var currentLyricPair: (text: String, translation: String) {
        // 用实时外推值而非 currentTime：后者是补间定时器一拍的量化快照，
        // 两次 tick 之间永远落后，实测平均滞后 124ms（见 livePosition 注释）。
        let t = livePosition - lyricsOffset
        let raw = LyricsTimeline.activeLineIndex(lines: syncedLines, adjustedTime: t)
        let idx = LyricsTimeline.debouncedLineIndex(raw: raw, prev: lastActiveLineIndex,
                                                   lines: syncedLines, adjustedTime: t)
        lastActiveLineIndex = idx
        let text: String
        if let i = idx {
            text = syncedLines[i].text
        } else {
            text = lyrics.isEmpty ? "" : lyrics   // 无时间轴：整段兜底
        }
        var translation = ""
        if bilingualMode != .off {
            if let i = idx, let tr = syncedLines[i].translation, !tr.isEmpty {
                translation = tr
            } else if !lyricsTranslation.isEmpty {
                translation = lyricsTranslation
            } else {
                // 兜底：当前显示文字若已在翻译缓存中，直接取用。
                // 用无锁快照而非 translationQueue.sync：本函数每帧被 UI 调一次，
                // sync 会让主线程阻塞在翻译队列上（队列里有落盘等长任务时
                // 足以让歌词刷新卡一拍，观感就是「歌词卡住」）。
                // 快照可能慢一拍，但下一拍就會补上，任何入眼影响都没有。
                let key = text.isEmpty ? title : text
                if !key.isEmpty, let cached = translationCacheSnapshot[key], !cached.isEmpty {
                    translation = cached
                }
            }
        }
        return (text, translation)
    }

    /// 当前正在唱的那一句（用于展开态两排双语显示）。无翻译时 translation 为 nil。
    var currentLine: SyncedLine? {
        let t = livePosition - lyricsOffset
        guard let i = LyricsTimeline.activeLineIndex(lines: syncedLines, adjustedTime: t) else {
            return nil
        }
        return syncedLines[i]
    }

    /// 当前行的翻译文本（双语模式且已解析出翻译时）；其它情况回退整段译文 / 快照直查。
    /// 与 currentLyricPair 共用同一判定，保证收缩态胶囊与展开态译文一致。
    var currentTranslationText: String {
        currentLyricPair.translation
    }

    // MARK: - 同步精度诊断

    /// 采样间隔（秒）：与播放轮询同频（1.5s），不额外增加 AppleScript 开销。
    private static let syncDiagInterval: TimeInterval = 1.5
    /// 汇总报告间隔（秒）。30s 足以覆盖一次完整的歌词段落切换，又不刷屏。
    private static let syncDiagReportInterval: TimeInterval = 30
    /// 歌词行平均时长（秒），用于把秒级偏差换算成「错了几行」——用户感知是行数。
    private static let syncDiagLineDuration: TimeInterval = 4.0
    /// 最近一批偏差样本（仅主线程访问；recordSyncSample 只在主线程闭包里调用）。
    private var syncDiagSamples: [Double] = []
    private var syncDiagQueueLags: [Double] = []
    private var syncDiagLastReport = Date.distantPast
    private var syncDiagCount: Int = 0

    /// 记录一个同步偏差样本。
    /// - `displayPosition`：歌词高亮实际使用的位置（livePosition 锚点外推）。
    /// - `truePosition`：同一时刻 Music 的真实播放位置（已把读点排队耗时补回）。
    /// - `queueLag`：读点到主线程的排队耗时，单独统计，与歌词偏差分开看。
    ///
    /// 为什么值得单独落日志：用户反馈只有「歌词和歌声不同步」一句，无法区分
    /// 是选错歌词版本（秒级、固定）、锚点/补间误差（百毫秒级、随负载增长）、
    /// 还是 LRC 本身的 offset（固定、整首平移）。有 p50/p95/max 三个数就能定位。
    private func recordSyncSample(truePosition: TimeInterval,
                                  displayPosition: TimeInterval,
                                  queueLag: TimeInterval) {
        // display 落后于 truth：歌词比歌声慢（用户在等歌词）。
        // display 超前于 truth：歌词比歌声快（用户看到还没唱的句子）。
        // 取 display - truth，正=歌词超前。
        let lead = displayPosition - truePosition
        // 只统计 5s 以内的偏差：超过这个量级必然是选错歌词版本或 seek 未完，
        // 混进来会把均值彻底带偏，反而看不出补间链路的真实精度。
        guard abs(lead) < 5.0 else { return }
        syncDiagSamples.append(lead)
        syncDiagQueueLags.append(queueLag)
        syncDiagCount += 1
        let now = Date()
        guard now.timeIntervalSince(syncDiagLastReport) >= Self.syncDiagReportInterval else { return }
        syncDiagLastReport = now
        guard !syncDiagSamples.isEmpty else { return }
        let sorted = syncDiagSamples.sorted()
        let p50 = sorted[sorted.count / 2]
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let maxAbs = sorted.last!
        let minAbs = sorted.first!
        let lines = String(format: "%.1f", abs(maxAbs) / Self.syncDiagLineDuration)
        // 排队耗时单独报：它不代表歌词偏差，但决定了偏差的上限。
        // 排队 p95 很大时，先优化链路排队，再谈补间精度。
        var q50 = 0.0, q95 = 0.0
        if !syncDiagQueueLags.isEmpty {
            let qs = syncDiagQueueLags.sorted()
            q50 = qs[qs.count / 2]
            q95 = qs[min(qs.count - 1, Int(Double(qs.count) * 0.95))]
        }
        lyricLog(String(format: "同步诊断 n=%d 超前p50=%+.3fs p95=%+.3fs 最大=%+.3fs 最小=%+.3fs ≈%@行 排队p50=%.3fs p95=%.3fs title=%@",
                           syncDiagCount, p50, p95, maxAbs, minAbs,
                           lines as NSString, q50, q95, title as NSString))
        // 汇总后清空：下一个 30s 窗口重新开始，避免一次异常长期污染统计。
        syncDiagSamples.removeAll(keepingCapacity: true)
        syncDiagQueueLags.removeAll(keepingCapacity: true)
    }

    enum PlaybackState { case playing, paused, stopped }

    private var lastTrackKey: String = ""
    /// Music 运行态判断缓存（避免每个调度拍都枚举进程列表）。
    /// 跨队列访问（scriptQueue + 主线程），必须配锁：见 isMusicRunning。
    private var musicRunningCache: (value: Bool, at: Date)?
    /// 保护 musicRunningCache 的串行队列。
    private let musicRunningQueue = DispatchQueue(label: "com.lumi.music.running")
    /// Music 播放状态广播监听令牌（deinit 时注销）
    private var playbackObserver: NSObjectProtocol?
    /// 已「成功」取到歌词的曲目集合，避免重复请求（仅在 scriptQueue 上访问）。
    /// 注意：失败不写入此集合，以便后续周期重试。
    var onlineSearchedKeys = Set<String>()
    /// 在线搜索已尝试次数（失败重试用，上限后停止以省流量）。仅在 scriptQueue 上访问。
    var onlineAttempts: [String: Int] = [:]
    /// 当前曲目是否已取到歌词（仅在 scriptQueue 上访问，避免跨线程 sync 读 @Published）
    var hasLyricsFlag = false
    /// 在线取词链「在途」标记 + 起始时间（仅在 scriptQueue 上读写）：
    /// 防止 1.5s 轮询在异步链完成前反复并发拉起同一条链（历史「无法获取歌词」根因之一）。
    var lyricInFlightKey: String? = nil
    var lyricInFlightSince: Date? = nil
    /// 在途标记兜底存活窗口：即便某条失败路径漏了解锁，窗口过后仍允许重试，绝不卡死。
    var lyricInFlightWindow: TimeInterval = 45
    /// 连续网络失败记录 + 重试冷却（秒）：冷却期满把 onlineAttempts 归零，
    /// 让在播曲目在网络恢复后自愈，而不是被尝试上限永久焊死。
    /// 与 onlineAttempts 是同一份「失败记忆」的两半，清理规则也一致：
    /// 切歌/重播时同步 removeValue（fetchInfoSync），外加 200 条容量兜底
    /// （fetchLyricsSync）——两者缺一都会让失败曲目在字典里无限堆积。
    var lyricLastFail: [String: Date] = [:]
    /// 取词失败后的冷却：按连续失败轮次指数增长，见 fetchLyricsSync。
    /// Base 6s：网络只抖一下时很快就能重试成功，不必干等。
    private let lyricRetryCooldownBase: TimeInterval = 6
    /// 冷却上限：反复失败（网络真的不可达）时最长等这么久，避免无谓刷请求。
    private let lyricRetryCooldownMax: TimeInterval = 48
    /// 当前曲目是否已取到封面（仅在 scriptQueue 上访问）。用于封面延迟加载的周期性重试。
    var hasArtFlag = false
    /// 当前曲目是否已确认「AppleScript 取不到封面」（仅在 scriptQueue 上访问）。
    /// macOS 26 起 Music 关闭了 artwork 的 Apple event 读取（data/raw data/bytes 全部报错），
    /// 这时再周期性重试只是空转；置位后改走网易云回退源，并停止无谓的 AppleScript 重试。
    var artworkScriptBlocked = false
    /// 网易云回退封面的歌曲 ID（仅在 scriptQueue 上访问）。与歌词链路复用同一套候选匹配，
    /// 避免「封面与歌词出自不同曲目」。
    var artworkNeteaseSongID: Int?
    /// 封面来源已尝试标记（仅在 scriptQueue 上访问）。每曲目最多试一次，
    /// 避免切歌后反复请求；失败则保持占位图，不再刷接口。
    var artworkNeteaseTried = false
    /// Apple 目录封面是否已尝试过（仅在 scriptQueue 上访问）。与 artworkNeteaseTried
    /// 同一职责、分开记录，便于按来源分别诊断命中情况。
    var artworkAppleTried = false
    /// AppleScript 是否已出现过一次「空字节」（仅在 scriptQueue 上访问）。
    /// 用于把「封面未就绪」与「接口已关」区分开：后者连续两次空才判死。
    var artworkEmptySeen = false
    /// 封面「代号」：每次切歌自增（仅在 scriptQueue 上读写）。取封面是异步的 ——
    /// AppleScript 阻塞读之后还要后台缩放，网易云回退更是搜索 + detail + 下图三跳，
    /// 前后跨度数秒，期间用户很可能已经切歌。发起请求时捕获当时的代号，回填时在
    /// scriptQueue 上比对，不一致即丢弃。这是「图片有时候会不对」（上一首的封面
    /// 盖到下一首，并且被钉住不走）的根因修复。
    var artworkToken = 0
    /// 当前曲目的封面缓存键（仅在 scriptQueue 上读写），与 artworkToken 同时更新。
    /// 两者必须一起捕获：切歌瞬间的「代号 + 缓存键」共同构成
    /// 「这批字节/这张缓存图属于哪一首歌」的完整凭据。
    var artworkCacheKey = ""
    /// 网易云封面的可信度下限。取词可以容忍近似命中（错几句歌词不易察觉），封面错了
    /// 却一眼可见，因此「宁缺毋滥」：最终候选也必须达到与「提前停止搜索」同一个分数线
    /// （歌名完全相同 100 分 + 歌手吻合 30~50 分），否则保持占位图。
    private let artworkMinScore: Int = 115
    /// 候选歌词「自带 LRC 时间轴」的加分：必须大于歌名/歌手/时长三项之和的
    /// 合理上限，否则纯文本候选仅凭时长吻合就能压过有时间轴的候选，
    /// 结果是整段歌词不滚动。
    private let syncedTimelineBonus: Int = 200
    /// 网易云取词的并发预取候选数：前 N 个并行探测谁有 LRC。
    /// 3 是平衡点 —— 再大对命中率帮助有限，却会白白多打请求。
    private let neteasePrefetchCount = 3
    /// QQ 取词的并发预取候选数，取值理由同网易云。
    private let qqPrefetchCount = 3
    // MARK: - lrclib 候选的串行回退

    /// 依次尝试 lrclib 候选（并发预取未命中时的回退路径）。
    /// - streak：连续网络失败次数。lrclib 整体不可达时（代理挂起 / TLS 被打断），
    ///   换候选歌名重试没有意义，累计 2 次就提前结束去试网易云；否则每个候选都要
    ///   耗满 8s 超时，网易云被迟迟等不到。
    private func tryLyricsCandidates(candidates: [(artist: String, track: String)], index: Int,
                                     streak: Int = 0,
                                     originalTitle: String, originalArtist: String) {
        // 已知不可达的主机（lrclib.net）先整源跳过：冷却期内直接走国内链路，
        // 否则每首歌都要在开头耗掉两轮网络超时才轮到网易云。
        if !hostHealthy("lrclib.net") {
            lyricLog("lrclib 处于不可达冷却期，直接回退网易云 artist=\(originalArtist) title=\(originalTitle)")
            fetchLyricsNetease(artist: originalArtist, title: originalTitle)
            return
        }
        guard index < candidates.count, streak < 2 else {
            // lrclib 所有候选均未命中（含网络不可达）：先试网易云（国内网络 DIRECT 可达，
            // 且同时提供带时间轴的原文 LRC 与中文译文 LRC），仍失败才回退 lyrics.ovh。
            lyricLog("lrclib 提前结束（连续网络失败 \(streak) 次）artist=\(originalArtist) title=\(originalTitle)，回退网易云")
            self.fetchLyricsNetease(artist: originalArtist, title: originalTitle)
            return
        }
        let c = candidates[index]
        runLyricsCandidate(c, index: index,
                           originalTitle: originalTitle, originalArtist: originalArtist,
                           onMiss: { [weak self] in
            self?.tryLyricsCandidates(candidates: candidates, index: index + 1, streak: 0,
                                     originalTitle: originalTitle, originalArtist: originalArtist)
        })
    }

    // MARK: - 候选评分与择优

    /// 歌词解析结果：带时间轴的行 + 纯文本兜底。
    private struct ResolvedLyrics {
        let synced: [SyncedLine]
        let plain: String
        var hasContent: Bool { !synced.isEmpty || !plain.isEmpty }
    }

    /// 从 lrclib 返回的条目里挑出与当前曲目最匹配的一个。
    ///
    /// /api/search 是模糊搜索，返回结果可能是同名的另一首歌。评分按五层消歧：
    /// 歌名（清洗后比对，挡住 feat./括号后缀）→ 歌手 → 版本标记 → 时长 → 专辑名，
    /// 并给有长时间轴的候选额外加分，避免纯文本候选靠时长吻合就胜出。
    private func resolveLyrics(_ data: Data?,
                               expectTitle: String,
                               expectArtist: String,
                               expectDuration: Double,
                               expectAlbum: String = "") -> ResolvedLyrics {
        guard let data = data else { return ResolvedLyrics(synced: [], plain: "") }
        var entries: [[String: Any]] = []
        var parsed = false
        // /api/search 返回数组；个别情况下也可能返回单个字典
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            entries = arr
            parsed = true
        } else if let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            entries = [d]
            parsed = true
        }
        // parsed=false 说明响应体不是合法 JSON（典型：被代理截断的 chunked 响应），
        // 与「服务端确实没收录这首歌」是两回事，日志必须能区分，否则排查时全算成没词。
        lyricLog("resolveLyrics: entries=\(entries.count) parsed=\(parsed) bytes=\(data.count) expectTitle=\(expectTitle) expectArtist=\(expectArtist)")

        // 取歌名匹配、且歌手不冲突的最佳条目，而不是第一条有歌词的条目。
        var best: (score: Int, synced: [SyncedLine], plain: String)?
        for d in entries {
            let synced = parseSyncedLyrics(d["syncedLyrics"] as? String)
            let plain = pickLyrics(d)
            if synced.isEmpty, plain.isEmpty { continue }
            // 歌名比对前，双方都剥掉 feat./括号/版本后缀：
            // Music 的 trackName 常带「(feat. 冰球乐团)」，而歌词库收录的是干净名。
            // 只清洗搜索词不清洗校验词，会导致「搜到了也判不匹配」——
            // 四个源全部走完却无歌词（实测《一个吻的时间 (feat. 冰球乐团)》）。
            let cleanedExpect = cleanTrackTitle(expectTitle)
            let cleanedGot = cleanTrackTitle(d["trackName"] as? String ?? "")
            var score = matchScore(["trackName": cleanedGot, "artistName": d["artistName"] as? String ?? ""],
                                   expectTitle: cleanedExpect, expectArtist: expectArtist)
            if score < 0 { continue }   // 歌名对不上，直接排除

            // 歌手主名重罚：与网易云 / QQ / 封面链路同一层判定。
            // matchScore 的歌手加减分压不住翻唱（同名同曲、歌手完全不同仍可能
            // 因歌名满分而总分很高），选中翻唱版后时间轴与演唱必然对不上。
            let expectPrimary = primaryArtist(expectArtist)
            let gotArtist = d["artistName"] as? String ?? ""
            if !expectPrimary.isEmpty,
               !gotArtist.localizedCaseInsensitiveContains(expectPrimary) {
                score -= artistMismatchPenalty
            }

            // 版本标记交叉验证：候选带 Live/Remastered/伴奏 而本曲不带（或反之），
            // 时间轴必然对不上，直接重罚压到不可选。
            // 版本标记用**原始**标题比：清洗会把 (Live)/(伴奏) 一并剥掉，
            // 清洗后再比就恒等、失去区分版本的能力。
            if !LyricsVersionTag.sameTags(expectTitle, d["trackName"] as? String ?? "") {
                score -= versionTagMismatchPenalty
            }

            // 时长比对：Live / Remastered / 伴奏版本的歌名歌手完全相同，
            // 但歌词时间轴往往差数秒，选错版本必然“歌词和歌声不同步”。
            // duration 是 lrclib 搜索结果的权威字段；封面链路的分档规则
            // 已有回归测试，这里直接复用同一套判定，保证两条链路一致。
            let candidateDuration = (d["duration"] as? NSNumber)?.doubleValue ?? 0
            // expectDuration 为 0 说明曲目时长还没拿到（流媒体元数据偶尔晚到）。
            // 此时时长交叉验证等于不参与，选错 Live/伴奏版本的风险上升；
            // 留一行日志，用户反馈"选错版本"时能直接看出是不是这个原因。
            if expectDuration <= 0 {
                lyricLog("候选评分：缺少曲目时长，时长交叉验证未参与 title=\(expectTitle)")
            }
            score += ArtworkScoring.durationScore(candidate: candidateDuration,
                                                  expected: expectDuration)

            // 专辑名交叉验证（复用封面链路同一套判定）。
            // lrclib 确实返回 albumName（实测字段存在），而它是区分
            // 「同名同歌手不同专辑」的强信号——时长缺失或版本标记没写进
            // 标题时，只有专辑名能挡住另一张专辑的同名曲。
            if !expectAlbum.isEmpty {
                let gotAlbum = d["albumName"] as? String ?? ""
                score += ArtworkScoring.albumScore(album: gotAlbum, expAlbum: expectAlbum)
            }

            // 有带时间轴的歌词是**决定性优势**：没有 synced 就整段不滚动，
            // 是用户最能直接感知的「歌词和歌声不一致」。
            // 纯靠歌名/歌手/时长打分时，一个只有纯文本但时长精确的候选
            // 完全可能压过有时间轴却缺 duration 字段的候选 —— 那就丢了同步。
            if !synced.isEmpty { score += syncedTimelineBonus }
            if best.map({ score > $0.score }) ?? true {
                best = (score, synced, plain)
            }
        }
        guard let b = best else { return ResolvedLyrics(synced: [], plain: "") }
        // 有带时间轴的歌词优先使用；否则用纯文本
        if !b.synced.isEmpty {
            return ResolvedLyrics(synced: b.synced, plain: b.plain)
        }
        return ResolvedLyrics(synced: [], plain: b.plain)
    }

    // MARK: - 纯文本兜底源

    /// lyrics.ovh 纯文本兜底源（无时间轴）。当四个源全部失败时调用。
    /// 至少能保证显示歌词文本，尽管无法逐行高亮。
    private func fetchLyricsOvh(artist: String, title: String) {
        if !hostHealthy("api.lyrics.ovh") {
            lyricLog("lyrics.ovh 处于不可达冷却期，直接判定无词 artist=\(artist) title=\(title)")
            markLyricsUnavailable(title: title, artist: artist)
            return
        }
        let a = QueryEncoding.encode(artist)
        let tt = QueryEncoding.encode(title)
        guard !tt.isEmpty,
              let url = URL(string: "https://api.lyrics.ovh/v1/\(a)/\(tt)") else {
            markLyricsUnavailable(title: title, artist: artist)
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            guard let self = self else { return }
            if let err = err {
                self.lyricLog("lyrics.ovh 网络错误 artist=\(artist) title=\(title) err=\(NetworkErrorText.describe(err))")
                // 证书类失败是机器级问题（代理在解密 HTTPS），整源冷却：
                // 否则每首歌都要重复撞一次同一个失败，白等两轮超时。
                if NetworkErrorText.isCertificateFailure(err) {
                    self.markHostUnreachable("api.lyrics.ovh")
                }
                self.markLyricsUnavailable(title: title, artist: artist)
                return
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any],
                  let lyric = obj["lyrics"] as? String, !lyric.isEmpty else {
                self.markLyricsUnavailable(title: title, artist: artist)
                return
            }
            let simplified = self.toSimplified(lyric.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !simplified.isEmpty else {
                self.markLyricsUnavailable(title: title, artist: artist)
                return
            }
            self.lyricLog("lyrics.ovh 命中歌词 len=\(simplified.count) title=\(title)")
            self.setSyncedLyrics(synced: [], plain: simplified, title: title, artist: artist)
        }.resume()
    }

    /// lrclib 候选的并发预取数：串行逐个试最坏要 72s 才轮到国内源
    ///（9 个候选 × 8s 超时），前 2 个并行把最坏延迟砍半。
    private let lrclibPrefetchCount = 2
    /// 候选歌名带版本标记而当前曲目不带（或反之）的重罚：Live/Remastered/伴奏
    /// 版的时间轴与录音室版差数秒到数十秒，选错版本必然「歌词和歌声不一致」，
    /// 且偏差大到用户一眼能看出。必须大于歌名+歌手+时长三项之和，
    /// 否则纯文本候选仍可能靠时长吻合压过正确版本。
    private let versionTagMismatchPenalty = 300
    /// 歌手主名不匹配的罚分：与封面链路同值。压住翻唱/混音候选，
    /// 选中翻唱版后其时间轴与演唱必然对不上（歌词和歌声不一致）。
    private let artistMismatchPenalty = 30
    /// `player position` 在 AppleScript 往返中的读取点占比（实测标定，见 fetchInfoSync）。
    /// 往返成本大头在读取之前：进程启动 + 脚本编译 + player state 查询。
    /// 0.7 是错的：那一版按 `osascript` 子进程标定（往返 ~90ms），而 App 内是
    /// `NSAppleScript` 直调，往返只有 ~50ms，成本构成完全不同。
    /// 三种独立测法收敛到同一区间（0.33 / 0.44 / 0.46），取中间值 0.45：
    /// 留极小回退余量，避免符号估计反了之后整首歌持续超前。
    private let readPointFraction: Double = 0.45
    /// 当前曲目的名称/艺术家/专辑/时长。跨线程访问走下方 queueInfoQueue 保护的方法。
    /// 专辑名与时长是封面匹配的强消歧信号：同名同歌手的歌往往存在录音室版与
    /// Live/串烧版，歌名歌手完全一致，只有专辑与时长能把它们区分开。
    var queueTitle = ""
    var queueArtist = ""
    var queueAlbum = ""
    var queueDuration: Double = 0
    /// 保护上述 queue* 快照的串行队列。
    ///
    /// 写侧在 scriptQueue（fetchInfoSync），但读侧不止它：在线歌词/封面的
    /// URLSession 回调在后台线程上读 queueDuration / queueAlbum 做版本消歧。
    /// 「仅在 scriptQueue 上访问」的旧注释与实际不符——无锁跨线程读虽有
    /// 64 位原子性兜底，但语义上就是 data race，且 Swift 内存模型并不保证。
    private let queueInfoQueue = DispatchQueue(label: "com.lumi.music.queueinfo")

    /// 跨线程安全地读当前曲目的时长（秒）。
    func currentQueueDuration() -> Double {
        queueInfoQueue.sync { queueDuration }
    }

    /// 跨线程安全地读当前曲目的专辑名（歌词版本消歧用）。
    func currentQueueAlbum() -> String {
        queueInfoQueue.sync { queueAlbum }
    }

    /// 歌词翻译缓存：原文 -> 翻译。避免同一句歌词反复请求翻译 API（省流量 + 防限流）。
    /// 所有读写都收敛到 translationQueue（串行），防止与重建 syncedLines 的主线程访问产生数据竞争。
    var translationCache: [String: String] = [:]
    /// 翻译缓存专用串行队列：统一保护 translationCache 的读写，避免跨线程字典崩溃。
    let translationQueue = DispatchQueue(label: "com.lumi.music.translation")

    /// translationCache 的 UI 侧无锁快照：由写侧在每次改动后同步刷新。
    /// 主线程读它不需要排队等翻译队列，避免 UI 被队列里的长任务阻塞。
    private var translationCacheSnapshot: [String: String] = [:]
    /// 歌词源「主机级失败」冷却表：host -> 上次不可达时间。
    /// lrclib.net / lyrics.ovh 在国内网络下 TLS 握手直接失败（实测两者均返回连接错误），
    /// 而取词链路是「先 lrclib 再国内源」，于是每首歌开头都要白等两轮超时，
    /// 表现为歌词迟迟不出现。这里给不可达主机记 15 分钟冷却，期间整源跳过。
    var unreachableHosts: [String: Date] = [:]
    /// 保护 unreachableHosts 的串行队列：URLSession 回调在后台线程读、scriptQueue 写。
    let hostHealthQueue = DispatchQueue(label: "com.lumi.music.hosthealth")
    private let hostCooldown: TimeInterval = 15 * 60

    /// 冷却满该秒数后允许一次「探测」：一次成功的请求即可提前解除冷却。
    ///
    /// 为什么需要：冷却期原为 15 分钟，对**代理/网络的短暂抖动**太不友好 ——
    /// lrclib 是唯一提供高质量逐行时间轴的源，一次抖动后 15 分钟不用它，
    /// 用户观感就是「歌词突然不出 / 明显变慢」，且与播放进度脱节。
    /// 90 秒后给一次机会：网络早已恢复的话立刻回归，仍不可达则继续冷却
    /// （成本只有一次请求，远低于每首歌都白等一轮超时）。
    private let hostProbeAfter: TimeInterval = 90

    /// 该歌词源主机当前是否值得尝试。
    ///
    /// 三种情况：
    /// - 从未失败过 → 直接尝试
    /// - 冷却未满 90 秒 → 跳过（避免每首歌白等超时）
    /// - 冷却已满 90 秒 → 放行一次探测；请求结果由调用方回报
    ///   （成功走 `markHostReachable` 解除冷却，失败重新计时）
    func hostHealthy(_ host: String) -> Bool {
        hostHealthQueue.sync {
            guard let last = unreachableHosts[host] else { return true }
            let elapsed = Date().timeIntervalSince(last)
            // 彻底过冷：清理并恢复正常
            if elapsed > hostCooldown {
                unreachableHosts[host] = nil
                return true
            }
            // 探测窗口内：放行这一次（调用方须回报结果）
            return elapsed >= hostProbeAfter
        }
    }

    /// 一次请求成功回报：解除该主机的冷却，立即恢复正常链路。
    func markHostReachable(_ host: String) {
        hostHealthQueue.sync { unreachableHosts[host] = nil }
    }

    /// 记录一次主机级失败（DNS / 连接被拒 / TLS 被打断），进入冷却期。
    func markHostUnreachable(_ host: String) {
        hostHealthQueue.sync { unreachableHosts[host] = Date() }
    }

    /// 落盘防抖任务。SwiftUI extension 不能声明存储属性，故统一放在主类：
    /// - cachePersistWork：翻译缓存 JSON 批量落盘（见 MusicTranslationService.scheduleCachePersist）
    /// - volumePersistWork / lyricsOffsetPersistWork：滑块拖动过程中合并 UserDefaults 写入
    var cachePersistWork: DispatchWorkItem?
    var volumePersistWork: DispatchWorkItem?
    var lyricsOffsetPersistWork: DispatchWorkItem?
    /// AppleScript 为同步阻塞调用（约 100–300ms），必须在后台串行队列执行，
    /// 否则 1.5 秒轮询会周期性卡住主线程。
    let scriptQueue = DispatchQueue(label: "com.lumi.music.script", qos: .utility)
    /// 专辑封面获取专用队列（高优先级）。封面原始数据较大，且不应与歌词 AppleScript /
    /// 翻译网络请求争用同一队列，否则会拖慢封面出现、产生明显延迟。
    /// 注意：本队列只做「取数据 + 解码缩放」的纯计算工作；任何共享标志位（hasArtFlag 等）
    /// 的写回一律派回 scriptQueue，避免跨队列无锁读写导致偶发崩溃。
    let artworkQueue = DispatchQueue(label: "com.lumi.music.artwork", qos: .userInitiated)
    /// 翻译批次调度专用串行队列。
    ///
    /// 翻译批处理曾在 scriptQueue 上跑：四分钟长歌 120 行 = 15 批，每批间隔
    /// 0.3s，累计约 5s 以上持续占用 scriptQueue —— 而播放进度采样
    /// (fetchInfoSync) 也在同一队列，会被整段延后。表现为「翻译一开始，
    /// 歌词就和歌声不一致」，且长歌越久偏差越大。
    /// 拆出独立队列后，翻译调度与进度采样互不阻塞。
    let translationSchedulerQueue = DispatchQueue(label: "com.lumi.music.translate.schedule",
                                                  qos: .utility)
    /// 翻译批次的「代次」号。切换双语模式 / 换歌 / 换时间轴都会 +1，
    /// 让仍在途的旧批次在回调时发现自己已过期并放弃写回 ——
    /// 否则快速切模式会让两套批次交错写译文，出现原文与译文错配。
    /// 仅在主线程读写。
    private var translationGeneration: UInt64 = 0
    /// 切歌后封面快速重试用的计数器（仅在 scriptQueue 上访问）。
    var artworkRetryCount = 0
    /// 网易云封面的最低可信匹配分。搜索早期退出用 115，但「查询词用尽」时不能照抄
    /// 歌词链路那套「取最高分就行」：歌词还有正文可比对做二次校验，封面没有第二道关，
    /// 低分候选一旦接受就直接把别人的专辑图贴上来。100 的含义是「归一化歌名必须全等，
    /// 或歌名互相包含且歌手全等」；凡歌手对不上（已被扣 30 分）的一律拒绝——错图比无图更糟。
    static let artworkMinMatchScore = 100

    // MARK: - 翻译模型选择
    /// 翻译模型供应商：决定请求端点与 key 来源。
    enum TranslateVendor {
        case google      // Google 公开接口（无需 key）
        case openrouter  // OpenAI 兼容，OpenRouter（LUMI_TRANSLATE_API_KEY）
        case dashscope   // 通义千问兼容模式（LUMI_DASHSCOPE_API_KEY）
        case stepfun     // 阶跃星辰；端点可用 LUMI_STEPFUN_BASE_URL 指向官方 API 或本机中继
    }

    /// 可选翻译模型。
    struct TranslateModelOption: Identifiable, Equatable {
        let id: String          // 模型名
        let label: String       // 显示名
        let vendor: TranslateVendor
        let usesLLM: Bool       // false=Google 公开接口
        /// 单次请求输出上限（token）。推理型模型会把额度全花在思考上，
        /// 沿用旧的 200/800 会拿到空 content，必须给足。
        var maxTokens: Int
        /// 请求超时（秒）。推理模型首字慢，12s 偏紧。
        var timeout: TimeInterval

        init(id: String, label: String, vendor: TranslateVendor, usesLLM: Bool,
             maxTokens: Int = 800, timeout: TimeInterval = 12) {
            self.id = id
            self.label = label
            self.vendor = vendor
            self.usesLLM = usesLLM
            self.maxTokens = maxTokens
            self.timeout = timeout
        }
    }

    /// 候选翻译模型列表；阶跃星辰（stepfun）适合翻译的两个模型排在最前（当前默认）。
    ///
    /// 端点经 `LUMI_STEPFUN_BASE_URL` 可切换：
    /// - 留空 → 本机中继 `http://127.0.0.1:15721/v1`（cc-switch，无需 key，开箱可用）
    /// - 填 `https://api.stepfun.com/v1` + `LUMI_STEPFUN_API_KEY` → 阶跃官方 API
    static let availableTranslateModels: [TranslateModelOption] = [
        TranslateModelOption(id: "step-3.5-flash",
                             label: "阶跃·翻译 Flash", vendor: .stepfun, usesLLM: true,
                             maxTokens: 2000, timeout: 25),
        TranslateModelOption(id: "step-5-preview",
                             label: "阶跃·翻译 Preview", vendor: .stepfun, usesLLM: true,
                             maxTokens: 2000, timeout: 25),
        TranslateModelOption(id: "qwen3.5-livetranslate-flash-realtime",
                             label: "通义·实时翻译 Flash", vendor: .dashscope, usesLLM: true),
        TranslateModelOption(id: "qwen3.5-livetranslate-flash-realtime-2026-05-19",
                             label: "通义·实时翻译 Flash(05-19)", vendor: .dashscope, usesLLM: true),
        TranslateModelOption(id: "google/gemma-4-26b-a4b-it:free",
                             label: "Gemma 4 26B (OpenRouter)", vendor: .openrouter, usesLLM: true),
    ]

    private let translateModelKey = "lumi_selected_translate_model"

    /// 当前选中的翻译模型（UserDefaults 持久化）；默认优先第一个通义实时翻译模型。
    @Published var selectedTranslateModelID: String = ""

    /// 当前选中的模型选项（含供应商信息），供 UI 显示。
    var selectedTranslateOption: TranslateModelOption {
        Self.availableTranslateModels.first(where: { $0.id == selectedTranslateModelID })
            ?? Self.availableTranslateModels[0]
    }

    /// 选中的模型是否走大模型通道（false=Google 公开接口，无需 key）。
    var useLLMTranslate: Bool { selectedTranslateOption.usesLLM }

    /// 当前通道实际使用的模型名。
    var activeTranslateModel: String { selectedTranslateOption.id }

    /// 当前通道实际使用的端点。
    /// stepfun 默认指向本机中继（无需 key）；填了 LUMI_STEPFUN_BASE_URL 则改用该地址
    /// （如官方 `https://api.stepfun.com/v1`）。
    var activeTranslateBaseURL: String {
        switch selectedTranslateOption.vendor {
        case .dashscope:  return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .openrouter: return envValue("LUMI_TRANSLATE_BASE_URL") ?? "https://openrouter.ai/api/v1"
        case .stepfun:    return envValue("LUMI_STEPFUN_BASE_URL") ?? "http://127.0.0.1:15721/v1"
        case .google:     return ""
        }
    }

    /// 当前通道实际使用的 key。
    /// stepfun 走本机中继时可留空（返回 nil），只有指向官方 API 时才需要 LUMI_STEPFUN_API_KEY。
    var activeTranslateAPIKey: String? {
        switch selectedTranslateOption.vendor {
        case .dashscope:  return envValue("LUMI_DASHSCOPE_API_KEY")
        case .openrouter: return envValue("LUMI_TRANSLATE_API_KEY")
        case .stepfun:    return envValue("LUMI_STEPFUN_API_KEY")
        case .google:     return nil
        }
    }

    /// 当前模型能否走大模型通道：有 key，或所选通道本就无需 key（stepfun·本机中继）。
    var canUseLLMTranslate: Bool {
        useLLMTranslate && (activeTranslateAPIKey != nil || selectedTranslateOption.vendor == .stepfun)
    }

    private init() {
        showLyrics = UserDefaults.standard.object(forKey: showLyricsKey) as? Bool ?? true
        lyricsOffset = UserDefaults.standard.object(forKey: lyricsOffsetKey) as? TimeInterval ?? 0
        offsetByTrack = UserDefaults.standard.dictionary(forKey: offsetByTrackKey) as? [String: TimeInterval] ?? [:]
        // 历史版本可能在停止态把空 title/artist 写成 "%7C"，加载时清掉。
        // 清完立刻回写，否则旧假键会一直留在 UserDefaults 文件里误导排查。
        if offsetByTrack.removeValue(forKey: "%7C") != nil {
            UserDefaults.standard.set(offsetByTrack, forKey: offsetByTrackKey)
        }
        // 直接用赋值 + 显式 didSet 语义：init 里给 stored property 赋值不会触发
        // didSet，因此这里不需要（也不该）装作会触发。歌词此刻还没载入，
        // reapplyBilingualForCurrentTrack 必然是空转；取到词后由
        // setSyncedLyrics → fetchTranslations 自己补译。
        bilingualMode = BilingualMode(rawValue: UserDefaults.standard.object(forKey: bilingualKey) as? Int ?? BilingualMode.auto.rawValue) ?? .auto
        // 顺序很关键：先轮询（内部立即同步取一次真值，写入 positionSampledAt），
        // 再启动补间时钟。反序会让第一拍补间以未初始化的采样时刻为基准。
        startPolling()
        startPlaybackClock()
        loadVolumeIfNeeded()
        loadTranslationCache()
        selectedTranslateModelID = UserDefaults.standard.string(forKey: translateModelKey)
            ?? Self.availableTranslateModels[0].id
        refreshVolume()
        // 恢复桌面歌词浮窗开关；init 内赋值不触发 didSet，需显式应用一次
        desktopLyricsEnabled = UserDefaults.standard.object(forKey: DesktopLyricsLayout.enabledKey) as? Bool ?? false
        desktopLyricsLocked = UserDefaults.standard.object(forKey: DesktopLyricsLayout.lockedKey) as? Bool ?? false
        desktopLyricsSizePreset = DesktopLyricsSizePreset.stored(
            UserDefaults.standard.string(forKey: DesktopLyricsLayout.sizeScaleKey))
        applyDesktopLyricsVisibility()
    }

    // MARK: - 轮询调度（按需）

    /// 原实现为 1.5s 常驻 Timer 无条件执行 `tell application "Music"` 的 AppleScript，存在两个问题：
    /// 1. 即使 Music 从未运行也持续跨进程调用，白白消耗 CPU/电量；
    /// 2. AppleScript 的 `tell application X` 在目标未运行时**会启动该应用**，
    ///    导致用户退出 Music 后又被 Lumi 每 1.5s 重新拉起，Music 根本退不掉。
    ///
    /// 现改为按需：Music 未运行时完全不轮询；播放中 1.5s（跟进度），暂停/停止降到 8s 兜底；
    /// 并用 DistributedNotificationCenter 在播放/暂停/切歌时立即刷新，实时性不依赖轮询频率。
    private func startPolling() {
        setupPlaybackNotifications()
        PollingCoordinator.shared.register(
            id: "music.playback",
            interval: { [weak self] in self?.pollInterval() ?? 0 },
            action: { [weak self] in self?.fetchInfo() }
        )
        fetchInfo()
    }

    /// 当前期望的轮询间隔（秒）；返回 `<= 0` 表示无需轮询。
    private func pollInterval() -> TimeInterval {
        // Music 未运行：完全不轮询（既省跨进程开销，也避免把 Music 重新拉起）
        guard isMusicRunning() else { return 0 }
        switch playbackState {
        case .playing: return 1.5   // 跟播放进度
        case .paused:  return 8.0   // 低频兜底：检测手动切歌等未广播的变化
        case .stopped: return 8.0
        }
    }

    /// Music 是否正在运行（带 1s 缓存，避免每个调度拍都枚举进程列表）。
    /// Music.app 是否在运行（带 1s 缓存）。跨模块复用（如专注联动先查运行态再发脚本）。
    func isMusicRunning() -> Bool {
        // 串行队列保护：本方法会被 scriptQueue（pollInterval）与主线程（UI 检查）
        // 同时调用，无锁读写元组是 data race。与 hostHealthQueue 同款做法。
        musicRunningQueue.sync {
            let now = Date()
            if let cached = musicRunningCache, now.timeIntervalSince(cached.at) < 1.0 {
                return cached.value
            }
            let running = NSWorkspace.shared.runningApplications.contains {
                $0.bundleIdentifier == "com.apple.Music"
            }
            musicRunningCache = (running, now)
            return running
        }
    }

    /// 外部（系统广播）确认 Music 正在运行时刷新缓存。锁内写，避免 data race。
    func noteMusicRunning() {
        musicRunningQueue.sync { musicRunningCache = (true, Date()) }
    }

    /// 播放状态变化（播放/暂停/切歌）由系统广播，收到即刷新——
    /// 这样「按需轮询」不必靠提高频率来换取实时性。
    private func setupPlaybackNotifications() {
        playbackObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.Music.playerInfo"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // 能收到 Music 的广播即说明它正在运行，顺带修正运行态缓存
            // 锁内更新：裸写元组是被本方法修掉的 data race
            self?.noteMusicRunning()
            self?.fetchInfo()
        }
    }

    deinit {
        if let observer = playbackObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    // MARK: - AppleScript 执行
    @discardableResult
    func runScript(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result: NSAppleEventDescriptor? = script.executeAndReturnError(&error)
        if let error = error {
            // 常见错误：Music 未运行 / 未授权 -> 忽略
            lyricLog("AppleScript error: \(error)")
        }
        return result
    }

    // MARK: - 获取当前播放信息
    func fetchInfo() {
        scriptQueue.async { [weak self] in self?.fetchInfoSync() }
    }

    private func fetchInfoSync() {
        let src = """
        tell application "Music"
            try
                set pState to (player state) as text
                if pState is "playing" or pState is "paused" then
                    -- 先取位置再取元数据：AppleScript 顺序执行，后面每个属性查询都会
                    -- 花时间；位置读得越早，sampledAt 与真实位置之间的时间差越小。
                    set tPos to (player position) as text
                    set tName to (name of current track) as text
                    set tArtist to (artist of current track) as text
                    set tAlbum to (album of current track) as text
                    set tDur to (duration of current track) as text
                    set artFlag to ""
                    try
                        if exists artwork 1 of current track then set artFlag to "ART"
                    end try
                    return pState & "|" & tName & "|" & tArtist & "|" & tAlbum & "|" & tDur & "|" & tPos & "|" & artFlag
                else
                    return "stopped|||||0|0|"
                end if
            on error
                return "stopped|||||0|0|"
            end try
        end tell
        """
        // `player position` 在 AppleScript 执行到中段时才被真实读取，而下面补间
        // 要以「那个时刻」为起点，否则会把整段脚本往返都算成音乐已播放 → 歌词
        // 系统性超前。真实读取点的占比见下方标定。
        // 切歌/暂停/停止/seek 仍按真值复位，不受影响。
        let scriptStartedAt = Date()

        guard let desc = runScript(src),
              let raw = desc.stringValue else {
            lyricLog("fetchInfo: AppleScript 无返回（Music 未运行或未授权自动化）")
            return
        }

        // `player position` 的真实读取点：三种独立测法收敛到 0.33~0.46，取 0.45。
        // 1) 同往返内比 position-first 与 position-last 两种脚本：position 之后的
        //    4 个元数据属性约占往返 2/3 → 读取点约在 1/3 处。
        // 2) 只读 position 的往返 ~17ms，完整脚本 ~50ms：差额正是读取之后的元数据，
        //    读取点 = 17/50 ≈ 0.34。
        // 3) 按显示进度公式反解残差：f=0.7 系统性超前 -31.5ms，f=0.45 降到 -5.7ms。
        //
        // 不要用 `osascript` 子进程标定：子进程往返 ~110ms 且读取点占比不同
        // （旧值 0.7 就是这么得出的，导致歌词系统性超前 20~35ms）。
        //
        // 上限说明：`player position` 本身并非粗糙的量化值。带状态守卫的对照实测
        // （n=121）显示它随墙钟间隔线性跟踪，误差限于 ±13ms、无固定网格。
        // 早期结论「16~17ms 量化台阶」出自对暂停数据的采样，是假象，已废弃。
        // 真正剩下的残余只有两项：读点占比 f≈0.45 的标定误差（约 ±0.4ms），
        // 以及补间快照端的滞后（已由 20Hz + livePosition 压到一帧）。
        let roundTrip = Date().timeIntervalSince(scriptStartedAt)
        let sampledAt = scriptStartedAt.addingTimeInterval(roundTrip * readPointFraction)

        let parts = raw.components(separatedBy: "|")
        guard parts.count >= 7 else { return }

        let stateStr = parts[0]
        let newTitle = parts[1]
        let newArtist = parts[2]
        let newAlbum = parts[3]
        let newDuration = Double(parts[4]) ?? 0
        let newPosition = Double(parts[5]) ?? 0
        let hasArt = parts[6] == "ART"

        // 曲目是否发生变化（lastTrackKey 仅在 scriptQueue 上读写）
        let artKey = "\(newTitle)-\(newArtist)"
        let trackChanged = artKey != lastTrackKey
        // 同一首歌「从头重播」：用户点重播、或播放完自动回到开头。此时 artKey
        // 不变、trackChanged 为 false，但歌词/防抖/偏移都还是上一轮的状态 ——
        // 直接接着旧位置渲染，观感就是「重播时歌词和歌声不一致」。
        // 判定：未切歌且位置从明显靠前大幅回落到接近开头。
        let restartedFromBeginning = PlaybackRestart.isRestartFromBeginning(
            trackChanged: trackChanged,
            title: newTitle,
            previousPosition: lastCommittedPosition,
            sampledPosition: newPosition,
            isPlaying: playbackState == .playing || stateStr == "playing"
        )
        // 覆盖 lastTrackKey 之前先留住上一 key：Music 停止时 AppleScript 返回
        // "stopped|||||0|0|"，newTitle/newArtist 为空、artKey 变成 "-"，本轮会清空歌词。
        // 若不同时清掉上一首的在线取词记忆，重播同一首歌时
        // onlineSearchedKeys.contains(key) 仍为 true，整条在线链路被静默跳过，
        // 表现为「无法获取歌词」，只能重开 App 或手动点重新获取才恢复。
        let previousTrackKey = lastTrackKey
        if trackChanged { lastTrackKey = artKey }
        // 与 currentQueueDuration() 配对：写侧也过同一把锁，
        // 否则读侧的 queueInfoQueue 保护形同虚设。
        queueInfoQueue.sync {
            self.queueTitle = newTitle
            self.queueArtist = newArtist
            self.queueAlbum = newAlbum
            self.queueDuration = newDuration
        }

        // 按曲目记忆的校准偏移：offsetByTrack 仅允许在 scriptQueue 上访问
        // （写侧 lyricsOffset didSet 也派发到 scriptQueue），故在派发主线程前先取值捕获，
        // 消除原先主线程闭包直接读字典的跨线程竞争（与历史翻译缓存崩溃同款根因）。
        var savedOffset: (key: String, value: TimeInterval)?
        if trackChanged || restartedFromBeginning {
            // 换歌与同曲重播都要恢复该曲记忆的偏移：
            // 重播时 trackChanged 为 false，若不一起捕获，savedOffset 是 nil，
            // 下面就会把用户调好的校准重置成 0 —— 重播后歌词整体错位。
            let rawKey = "\(newTitle)|\(newArtist)"
            let key = rawKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? rawKey
            savedOffset = (key, offsetByTrack[key] ?? 0)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // 本轮 AppleScript 真值到达主线程的时刻：拒绝陈旧采样时用作补间锚点
            // （见下方 MusicPlaybackSample.shouldAccept 拒绝分支注释）。
            let mainThreadAt = Date()
            self.title = newTitle
            self.artist = newArtist
            self.album = newAlbum
            self.duration = newDuration
            let sampleAccepted = MusicPlaybackSample.shouldAccept(
                sampledPosition: newPosition,
                previousPosition: self.lastCommittedPosition,
                isSameTrackPlaying: self.playbackState == .playing && !trackChanged
            )
            // 同步诊断：按拍采样「歌词位置」与「此刻真实播放位置」的偏差，每 30s 汇总，
            // 把「歌词和歌声差多少」从主观听感变成可核对的数字。
            //
            // 关键：newPosition 是 sampledAt（AppleScript 里 position 被真读到的时刻）
            // 的值，而它在 mainThreadAt 才到主线程。这段时间音频一直在走，所以
            // 「此刻真实位置」= newPosition + 排队耗时。直接拿 livePosition 减 newPosition
            // 会把排队耗时算成歌词超前（常年 +50~150ms 的假信号），必须扣掉。
            let queueLag = mainThreadAt.timeIntervalSince(sampledAt)
            let truthAtMain = newPosition + queueLag
            if self.playbackState == .playing && !trackChanged, self.duration > 0 {
                self.recordSyncSample(truePosition: truthAtMain,
                                      displayPosition: self.livePosition,
                                      queueLag: queueLag)
            }
            if !sampleAccepted, let last = self.lastCommittedPosition {
                // Music 真值比刚补间的进度略旧（排队延迟所致）；直接覆盖会让
                // 歌词先前进再回跳。保留较新的插值进度，并把锚点时间对齐到
                // mainThreadAt（本轮真值到达主线程的时刻）。
                //
                // 注意：大幅回退是用户在 Music 里主动 seek，
                // MusicPlaybackSample 会让它走下方真值分支并马上刷新歌词，不能
                // 与这类几十毫秒的陈旧采样混为一谈。
                //
                // 为什么不能用 sampledAt（AppleScript 真实读点）：这里保留的是
                // 插值终点 last，而 sampledAt 是更早就过去的读点。读点与到达之间
                // 的排队耗时（数毫秒到数百毫秒）已经在补间里算过一遍，若锚点仍取
                // sampledAt，这段时间会被再算一次，等于每次拒绝都把时钟多推进一次
                // 排队耗时。实测（播放中 Load 级排队、约 30ms 主线程延误）单次即可
                // 注入 ~0.6s 超前：歌词整体提前约 13 行，正是「歌词和演唱不同步」
                // 最常见且最难解释的形态。
                // mainThreadAt 与 last 同刻（见下方 positionSampledAt 统一写入），
                // 真实播放位置仍由下一拍的真值（采用分支）校准，不会漂走。
                self.commitProgress(last)
                self.sampledPosition = last
            } else {
                self.currentTime = newPosition
                self.lastCommittedPosition = newPosition
                self.sampledPosition = newPosition
            }
            // 补间起点：
            //   - 采用真值 → 真值读点 sampledAt（AppleScript 里 position 真正被读到的时刻）
            //   - 拒绝陈旧采样 → mainThreadAt（被保留的那个插值终点的时刻）
            // 两者必须分开：读点到主线程之间的排队耗时已计入插值，若锚点仍取
            // sampledAt，同一段时间会被再算一次，每次拒绝都把时钟多推进一次，
            // 歌词整体超前（实测单次最高约 0.6s，约 13 行）。
            self.positionSampledAt = MusicPlaybackSample.anchorTime(
                sampledAt: sampledAt,
                mainThreadAt: mainThreadAt,
                accepted: sampleAccepted
            )
            switch stateStr {
            case "playing": self.playbackState = .playing
            case "paused":  self.playbackState = .paused
            default:        self.playbackState = .stopped
            }
            // 切歌先清空歌词，避免短暂显示上一首的歌词。
            // 这些 @Published 属性改动必须回到主线程，否则 SwiftUI 在后台线程刷新可能崩溃（Data race）。
            // trackChanged 或 restartedFromBeginning 都要重置：两者都是「新的一次播放」
            if trackChanged || restartedFromBeginning {
                let clearArt = !hasArt
                // 切歌/重播同帧就恢复该曲的偏移：不能等到下一帧再异步写入，否则
                // 新歌歌词可能先用旧偏移渲染几拍；更不能写成
                // "值不同才写入"——两首歌偏移相同时就永远不恢复。
                // 用 savedOffset 而非 UserDefaults 现读，是因为它在本轮
                // scriptQueue 上就已捕获，与本次写回同一时刻。
                let restore = savedOffset?.value ?? 0
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.lyrics = ""
                    self.lyricsTranslation = ""
                    self.syncedLines = []
                    self.lyricsNote = ""
                    // 切歌重置防抖状态：新歌第一行不应被旧歌的回退余量挡住
                    self.lastActiveLineIndex = nil
                    // 锚点复位到**本轮真值**：用户在 Music 里手动切歌时不经过
                    // switchTrack 的乐观更新，不复位的话补期会以「旧歌的位置」
                    // 继续外推，新歌歌词从错误位置起跳。
                    // 用 newPosition 而不是硬编码 0：它此刻就是新曲的真实位置，
                    // 丢真值改 0 会让补间从错误的起点外推（表现为起跳偏慢/偏快）。
                    self.commitProgress(newPosition)
                    self.sampledPosition = newPosition
                    self.positionSampledAt = Date()
                    if clearArt { self.artwork = nil }
                    // 按曲目记忆的校准偏移：切歌即刻生效，不留旧偏移残留
                    self.lyricsOffset = restore
                }
            }
        }

        // 以下均为阻塞式 AppleScript / 网络调用，继续留在 scriptQueue 上执行
        // 封面：Music 在切歌瞬间可能尚未加载好 artwork（hasArt 暂时为 false），
        // 因此周期性重试直到取到，避免封面长期缺失/延迟。
        // 切歌时立即安排「快速重试」：不等 1.5s 主轮询，主动在 0.5/0.9/1.5/2.2s 各探一次，
        // 显著缩短流媒体封面下载完成后的首屏延迟。
        if trackChanged {
            // 先换代号：从这一刻起，任何在途封面结果回填时都会被判为过期并丢弃。
            artworkToken += 1
            hasArtFlag = false
            artworkRetryCount = 0
            // 网易云回退状态按曲目复位；artworkScriptBlocked 不在此复位 —— 它描述的是
            // 「这台机器的 Music 还能不能读 artwork」，与当前曲目无关，一旦判死就保持，
            // 否则每切一首歌都要重新空转两轮 AppleScript。
            artworkNeteaseTried = false
            artworkNeteaseSongID = nil
            artworkAppleTried = false
            artworkEmptySeen = false
            // 缓存键与代号同时更新，两者共同构成「这张图属于哪一首歌」的凭据。
            artworkCacheKey = ArtworkScoring.cacheKey(title: queueTitle,
                                                       artist: queueArtist,
                                                       album: queueAlbum)
            // 磁盘缓存优先：本机 AppleScript 已恒返回 0 字节，同一首歌每次都会
            // 走一遍 4 店铺 + 网易云的在线链路。命中缓存即零网络直接装图，
            // 并跳过下面全部在线分支；miss 才回退到原有链路。
            if let cached = cachedArtworkImage(forKey: artworkCacheKey) {
                hasArtFlag = true
                lyricLog("封面：命中磁盘缓存 title=\(queueTitle)")
                DispatchQueue.main.async { [weak self] in self?.artwork = cached }
            } else if artworkScriptBlocked {
                fetchArtworkFromAppleCatalog()
            } else {
                scheduleArtworkRetry()
            }
        }
        // hasArtFlag 也可能是「命中磁盘缓存」置真的，此时不能再发起在线/AppleScript
        // 取图 —— 那会让缓存白白失效，甚至在缓存图之后被低置信度的在线结果覆盖。
        if !hasArtFlag && hasArt {
            fetchArtwork()
        }

        // 歌词：Apple Music 的内嵌歌词在切歌后可能延迟加载，因此周期性重试，
        // 直到取到歌词或曲目再次切换。
        // trackChanged（换歌）或 restartedFromBeginning（同曲重播）都视为
        // 「新的一次播放」：取出词记忆复位，让本轮重新走一遍在线链路。
        if trackChanged || restartedFromBeginning {
            hasLyricsFlag = false
            // 清掉当前曲的取词记忆：重播同一首时 onlineSearchedKeys 若仍命中，
            // 整条链路会被静默跳过，歌词就再也回不来。
            onlineSearchedKeys.remove("\(newTitle)-\(newArtist)")
            onlineAttempts.removeValue(forKey: "\(newTitle)-\(newArtist)")
            // lyricLastFail 必须跟着一起复位：它和 onlineAttempts 是同一份
            // 「失败记忆」的两半（冷却判定要两个一起读）。只清 attempts 会让
            // 上一轮的 lastFail 永久留在字典里——既读不回去（attempts 已归零），
            // 也没有容量兜底，失败过的曲目无限堆积。
            lyricLastFail.removeValue(forKey: "\(newTitle)-\(newArtist)")
            if !previousTrackKey.isEmpty {
                // 连同上一曲目的取词记忆一起复位。
                onlineSearchedKeys.remove(previousTrackKey)
                onlineAttempts.removeValue(forKey: previousTrackKey)
                lyricLastFail.removeValue(forKey: previousTrackKey)
            }
        }
        fetchLyricsSync(title: newTitle, artist: newArtist, force: !hasLyricsFlag)
    }

    /// 调试日志：系统 unified log + ~/Library/Logs/Lumi/music.log 双写。
    /// 落盘是必需的：本机 `log show --predicate 'process == "Lumi"'` 抓不到 App 的
    /// NSLog 输出，歌词链路（lrclib -> 网易云 -> lyrics.ovh）在代理不可用时全靠
    /// 这个文件定位断在哪一环。
    func lyricLog(_ msg: String) {
        NSLog("[Lumi/Music] \(msg)")
        appendMusicLog(msg)
    }

    /// 诊断日志落盘：单文件滚动，超过 512KB 截断重写，避免无限增长。
    private func appendMusicLog(_ msg: String) {
        musicLogQueue.async {
            let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Logs/Lumi")
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let file = dir.appendingPathComponent("music.log")
                let ts = ISO8601DateFormatter().string(from: Date())
                let line = "[\(ts)] \(msg)\n"
                if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
                   (attrs[.size] as? UInt64) ?? 0 > 512 * 1024 {
                    try line.write(to: file, atomically: true, encoding: .utf8)
                    return
                }
                if let handle = try? FileHandle(forWritingTo: file) {
                    handle.seekToEndOfFile()
                    handle.write(line.data(using: .utf8)!)
                    handle.closeFile()
                } else {
                    try line.write(to: file, atomically: true, encoding: .utf8)
                }
            } catch { /* 诊断日志写入失败不影响主流程 */ }
        }
    }

    // MARK: - 控制
    /// 实例启动留痕（配合单实例护栏）：一条日志即可看出一共拉起过几个实例、分别来自哪个
    /// 二进制。撞上排障手册第 3 节「完全无新行」判定时，先排除「两份实例互相打断」。
    func logInstanceLaunch() {
        let exe = Bundle.main.executablePath ?? CommandLine.arguments.first ?? "unknown"
        lyricLog("实例启动 pid=" + String(ProcessInfo.processInfo.processIdentifier) + " exe=" + exe)
    }

    var isPlaying: Bool { playbackState == .playing }

    func togglePlayPause() {
        // 乐观切状态：只发 AppleScript 而不动本地 playbackState 的话，
        // 暂停后到下一拍轮询（最长 1.5s）之前，补间时钟的 playing 守卫仍为真，
        // currentTime 会继续外推 —— 用户看到暂停了歌词还在往下滚。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let nowPlaying: Bool
            switch self.playbackState {
            case .playing: nowPlaying = false
            default:        nowPlaying = true
            }
            self.playbackState = nowPlaying ? .playing : .paused
            // 状态切换即重置补间锚点：以「当前可见进度」为新基准，
            // 恢复播放时从 pause 的那个点接着走，不跳变。
            self.sampledPosition = self.currentTime
            self.positionSampledAt = Date()
        }
        scriptQueue.async { [weak self] in
            self?.runScript("tell application \"Music\"\nplaypause\nend tell")
        }
    }

    /// 仅在「确实正在播放」时暂停（锁屏 / 屏保 / 睡眠等离开工位场景专用）。
    /// 与 `togglePlayPause()` 的区别：后者对已暂停的曲目会反向变成播放，
    /// 在自动场景里会造成「锁个屏回来突然响起来」的误播，故这里用幂等的 pause。
    /// 前置 `isMusicRunning()` 检查：`tell application "Music"` 在 Music 未运行时
    /// 会把它拉起来（AppleScript 语义），必须避免在用户没开 Music 时自作主张启动。
    func pauseIfPlaying() {
        guard isMusicRunning(), isPlaying else { return }
        // 同样乐观置为暂停：否则锁屏/屏保触发暂停后，补间仍按 playing
        // 继续外推，解锁回来歌词已经跑过头。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.playbackState = .paused
            self.sampledPosition = self.currentTime
            self.positionSampledAt = Date()
        }
        scriptQueue.async { [weak self] in
            self?.runScript("tell application \"Music\"\nif player state is playing then pause\nend tell")
        }
    }

    /// 播放指定歌单。遵循项目约定：仅当 Music 已在运行时执行，不冷启动。
    /// 歌单名做引号转义，防止含引号的歌单名破坏 AppleScript 语法。
    func playPlaylist(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isMusicRunning() else { return }
        let escaped = trimmed.replacingOccurrences(of: "\"", with: "\\\"")
        scriptQueue.async { [weak self] in
            self?.runScript("tell application \"Music\"\nplay playlist \"\(escaped)\"\nend tell")
            // 播完立即取一次真值：否则停止/暂停态下轮询间隔是 8s，
            // 歌单已经开始放、歌词却要等最多 8 秒才跟上。
            self?.fetchInfoSync()
        }
    }

    func nextTrack() { switchTrack("next track") }

    func previousTrack() { switchTrack("previous track") }

    private func switchTrack(_ command: String) {
        artwork = nil
        // 乐观锚点：切歌后新曲从 0 开始播，先在本帧把进度/锚点对齐到 0，
        // 否则到下一拍真值之间补间仍以旧曲锚点外推，旧歌词会继续跑。
        // 不在这里猜新状态：实测 Music 在暂停态执行 next/previous 仍是暂停
        // （位置 0、不推进）。乐观置 .playing 会让补间跑在静止的播放前面 ——
        // 歌词一行行滚而音频没动。状态交给紧随其后的 fetchInfoSync 真值纠正，
        // 最多滞后一拍；而锚点归零是安全的（暂停态补间本就不推进）。
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.commitProgress(0)
            self.sampledPosition = 0
            self.positionSampledAt = Date()
        }
        scriptQueue.async { [weak self] in
            guard let self = self else { return }
            self.runScript("tell application \"Music\"\n\(command)\nend tell")
            // 主动切歌同样换代号：新封面的请求由随后的 fetchInfoSync 发起，
            // 上一首尚未回填的结果全部作废。
            self.artworkToken += 1
            self.lastTrackKey = ""
            self.hasLyricsFlag = false
            self.lyricInFlightKey = nil
            self.lyricInFlightSince = nil
            self.hasArtFlag = false
            // 顺序：先取播放信息（进度 + 歌词/封面都依赖它），音量刷新延后。
            // refreshVolume 是一次阻塞式 AppleScript，和本队列上的进度采样/取词
            // 串行；把它排在前面会让新歌的进度与歌词都晚一步才就绪，
            // 而音量晚 1.5s 更新用户毫无感知。
            self.fetchInfoSync()
            self.refreshVolume()
        }
    }

    func seek(to time: TimeInterval) {
        // 不用 Int() 取整：AppleScript 的 set player position 接受小数，
        // 取整会让拖到 30.7s 的进度条实际跳到 30s，歌词锚点跟着差最多 1 秒。
        // 夹到合法范围，负值传给 AppleScript 会静默失败。
        let upper = duration > 0 ? duration : .greatestFiniteMagnitude
        let t = min(max(time, 0), upper)
        // AppleScript 需要 C  locale 的小数点，避免本地化把 30.7 写成 30,7 破坏语法。
        let literal = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), t)
        // 乐观更新：拖动进度条后不等下一轮 1.5s 轮询，立刻把进度与采样时刻对齐。
        // 否则墙钟补间会以跳转前的旧位置为起点继续往前推，歌词会跟着错一段。
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.currentTime = t
            self.lastCommittedPosition = t
            self.sampledPosition = t
            self.positionSampledAt = Date()
        }
        scriptQueue.async { [weak self] in
            self?.runScript("tell application \"Music\"\nset player position to \(literal)\nend tell")
            // 立刻取一次真值：seek 后本地是乐观位置，若 AppleScript 执行有延迟
            // 或失败，两者会不一致，而轮询最多要等 1.5s 才纠正 —— 那 1.5s 内
            // 歌词跟着错误的乐观位置走。与 switchTrack / playPlaylist 同一策略。
            self?.fetchInfoSync()
        }
    }

    /// 相对快进/快退 delta 秒（正为快进，负为快退）。基于当前 position 计算目标位置并跳转。
    func skip(by delta: TimeInterval) {
        // 乐观锚点：跳转目标现在就已知，不必等 AppleScript 回来。
        // 若不先更新，跳转到下一拍真值之间的补间仍以旧锚点外推，
        // 歌词会从旧位置往前跑，直到下一拍真值才被拽回 —— 观感就是「闪一下错歌词」。
        //
        // 基准取真实位置锚点而非 currentTime：currentTime 是补间插值出来的，
        // 与 AppleScript 读到的 player position 可能差几十毫秒。连点快进时
        // 用插值做基准会把这点偏差带进下一轮，用户听到的位置与歌词不一致。
        // sampledPosition 是上一拍真值或乐观更新的落点，正是 AppleScript 的基准。
        let target = MusicSeekFormat.clampedTarget(sampledPosition + delta,
                                                  duration: duration)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.commitProgress(target)
            self.sampledPosition = target
            self.positionSampledAt = Date()
        }
        scriptQueue.async { [weak self] in
            guard let self = self else { return }
            let src = """
            tell application "Music"
                try
                    if player state is playing or player state is paused then
                        set cur to player position
                        set dur to duration of current track
                        set target to cur + \(String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), delta))
                        if target < 0 then set target to 0
                        if target > dur then set target to dur
                        set player position to target
                    end if
                end try
            end tell
            """
            self.runScript(src)
            // 跳转后立刻刷新一次进度，避免界面停留在旧位置
            self.fetchInfoSync()
        }
    }

    // MARK: 音量
    @Published var volume: Int = -1 {
        didSet {
            // 滑块拖动 / 滚轮连续调节会高频触发，落盘合并为「停止变化 0.5s 后写一次」。
            guard volume >= 0 else { return }
            scheduleVolumePersist()
        }
    }
    private let volumeKey = "music_volume"

    /// 歌词校准偏移的防抖落盘：除写 UserDefaults 外，还把按曲目记忆字典整体重写一遍，
    /// 拖动滑块时若每步都写会放大 I/O，故统一合并。
    func scheduleLyricsOffsetPersist() {
        lyricsOffsetPersistWork?.cancel()
        // 取曲目快照：防抖 0.5s 后才真正落盘，若这期间切了歌，
        // 实时读 currentTrackKey 会拿到新曲名 —— 用户为 A 歌调好的偏移
        // 就被存到 B 歌名下，下次播 B 时套用错误的偏移（歌词整首错位）。
        let key = currentTrackKey
        let offset = lyricsOffset
        guard !title.isEmpty, !artist.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            UserDefaults.standard.set(offset, forKey: self.lyricsOffsetKey)
            // 按曲目记忆校准：用户拖动滑块/点击对齐后，记下当前曲的偏移，
            // 下次再播放同一首自动套用，避免每次都重新调（解决「时间轴不对」反复出现）。
            self.scriptQueue.async { [weak self] in
                guard let self = self else { return }
                self.offsetByTrack[key] = offset
                UserDefaults.standard.set(self.offsetByTrack, forKey: self.offsetByTrackKey)
            }
        }
        lyricsOffsetPersistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// 音量的防抖落盘。
    func scheduleVolumePersist() {
        volumePersistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.volume >= 0 else { return }
            UserDefaults.standard.set(self.volume, forKey: self.volumeKey)
        }
        volumePersistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// 启动时读取持久化的音量（-1 表示尚未初始化，由 UI 在首次拿到真实音量后回填）。
    func loadVolumeIfNeeded() {
        if volume < 0 {
            let saved = UserDefaults.standard.object(forKey: volumeKey) as? Int
            volume = saved ?? -1
        }
    }

    /// 读取 Music.app 当前音量（0-100）。在主线程回调以避免跨线程读写 @Published。
    func refreshVolume() {
        scriptQueue.async { [weak self] in
            guard let self = self else { return }
            let src = """
            tell application "Music"
                try
                    return sound volume as text
                end try
                return ""
            end tell
            """
            guard let desc = self.runScript(src), let raw = desc.stringValue,
                  let v = Int(raw.trimmingCharacters(in: .whitespaces)) else { return }
            let clamped = max(0, min(100, v))
            DispatchQueue.main.async {
                // 仅当未手动设置过时，用真实值回填，避免覆盖用户拖动
                if self.volume < 0 { self.volume = clamped }
            }
        }
    }

    func setVolume(_ v: Int) {
        let clamped = max(0, min(100, v))
        volume = clamped
        scriptQueue.async { [weak self] in
            self?.runScript("tell application \"Music\"\nset sound volume to \(clamped)\nend tell")
        }
    }
}

// MusicController 的封面 extension：AppleScript 取封面数据、稳健解码缩放、切歌快速重试。
extension MusicController {

    /// 取专辑封面：先走 AppleScript（Music 本地数据，最快且零网络）。
    /// 取不到时分两种情形：
    ///   - 数据还没就绪（流媒体封面仍在下载）→ 快速重试；
    ///   - macOS 26 起 Music 关闭了 artwork 的 Apple event 读取 → 转网易云回退源
    ///     （实测新版 Music 下 data/raw data/bytes 全部报 -50 或返回 0 字节）。
    /// 结果统一走 installArtwork(_:token:cacheKey:)：后台缩放后回主线程赋值，并核对代号。
    func fetchArtwork() {
        // 在 scriptQueue 上取「期望曲名 + 当代代号」快照，两者共同构成
        // 「这批字节必须属于哪一首歌」的凭据。queueTitle 只在 scriptQueue 上写，
        // 在这里读才不会与 fetchInfoSync 的更新形成竞争。
        scriptQueue.async { [weak self] in
            guard let self else { return }
            let expect = self.queueTitle
            guard !expect.isEmpty else { return }
            let token = self.artworkToken
            let cacheKey = ArtworkScoring.cacheKey(title: self.queueTitle,
                                                   artist: self.queueArtist,
                                                   album: self.queueAlbum)
            self.artworkQueue.async { [weak self] in
                guard let self else { return }
                let literal = Self.appleScriptString(expect)
                // 关键：曲名核对与封面字节读取放在同一次 AppleScript 调用里。
                // Music 处理 Apple event 是串行的，因此「当前曲名」与「当前封面」
                // 必然对应同一首歌；曲名已变则直接返回 STALE 哨兵，一个字节都不取。
                // 这消除了原先「读到的其实是下一首封面」的错图根因。
                let src = """
                tell application "Music"
                    try
                        if name of current track is not "\(literal)" then return "STALE"
                        if exists artwork 1 of current track then return data of artwork 1 of current track
                    end try
                    return ""
                end tell
                """
                // AppleScript 内部 try 会把「接口已关」静默吞掉、返回空结果，
                // 因此这里无法从 error 区分「没数据」与「接口被拒」，只能按字节数判断。
                guard let desc = self.runScript(src) else {
                    self.scheduleArtworkRetry()
                    return
                }
                guard !desc.data.isEmpty, let original = NSImage(data: desc.data) else {
                    if desc.stringValue == "STALE" {
                        // 读取瞬间当前曲目已不是发起请求那一首：本轮结果与请求无关。
                        // 既不算「接口已关」（否则会误判死、永久转网易云源），
                        // 也不算「封面未就绪」，静默丢弃，交给 1.5s 主轮询重来。
                        return
                    }
                    // descriptor 有类型但 0 字节：这是「接口读不到」而非「封面未就绪」。
                    // 连续两次都空才判死，转在线目录源，避免切歌瞬间误判、也避免原地空转。
                    self.noteArtworkUnavailable { blocked in
                        if blocked { self.fetchArtworkFromAppleCatalog() }
                        else { self.scheduleArtworkRetry() }
                    }
                    return
                }
                self.installArtwork(original, token: token, cacheKey: cacheKey)
            }
        }
    }

    /// 把任意文本安全地写进 AppleScript 字符串字面量：转义反斜杠、引号与控制字符。
    /// 曲名来自 Music 曲库，可能含引号（例如 "Don't Stop Me Now"），不转义会破坏脚本语法。
    private static func appleScriptString(_ text: String) -> String {
        var out = ""
        for ch in text {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(ch)
            }
        }
        return out
    }

    /// AppleScript 未取到封面字节时调用：连续两次都空即判定「接口不可用」，置位
    /// artworkScriptBlocked 并停止 AppleScript 重试（改走网易云回退）。
    /// 计数与标志统一在 scriptQueue 上读写，避免与 fetchInfoSync 的复位形成跨队列竞争。
    private func noteArtworkUnavailable(completion: @escaping (_ blocked: Bool) -> Void) {
        scriptQueue.async { [weak self] in
            guard let self else { return }
            if self.artworkScriptBlocked {
                completion(true)
                return
            }
            // 首次空不算：Music 封面在切歌瞬间确实常未就绪，给它一次快速重试的机会。
            if !self.artworkEmptySeen {
                self.artworkEmptySeen = true
                self.scheduleArtworkRetry()
                completion(false)
                return
            }
            self.artworkScriptBlocked = true
            self.lyricLog("封面：AppleScript 取不到 artwork 字节，转在线目录源")
            completion(true)
        }
    }

    /// 展示尺寸上限 240pt，Retina 下需要 480px；留 640 给缩放拖拽的余量。
    /// （原实现缩到 280，等于 140pt@2x，放大到 240pt 会明显发虚。）
    private static let artworkRenderSize: CGFloat = 640

    /// 安装封面：后台缩放至 artworkRenderSize，并同步写入磁盘缓存。
    /// 回主线程赋值前先在 scriptQueue 上核对代号。
    /// hasArtFlag 与 artwork 必须同时门控：若过期结果也把 hasArtFlag 置真，
    /// 主轮询的 `!hasArtFlag && hasArt` 与快速重试都会停止，错误封面就被永久钉在界面上
    /// ——这正是「封面不对且一直不变」的成因。
    private func installArtwork(_ original: NSImage, token: Int, cacheKey: String) {
        artworkQueue.async { [weak self] in
            guard let self else { return }
            let size = NSSize(width: Self.artworkRenderSize, height: Self.artworkRenderSize)
            guard let thumb = Self.scaledImage(original, to: size) else { return }
            // 写缓存放在代号核对之前是可以的：缓存键来自请求发起时的曲目快照，
            // 即便已切歌，这张图对该键仍是正确的 —— 下次重播直接命中，反而更省。
            self.storeArtwork(thumb, key: cacheKey)
            self.scriptQueue.async { [weak self] in
                guard let self else { return }
                guard token == self.artworkToken else {
                    self.lyricLog("封面：丢弃过期结果 token=\(token) 当前=\(self.artworkToken)")
                    return
                }
                self.hasArtFlag = true
                DispatchQueue.main.async { [weak self] in self?.artwork = thumb }
            }
        }
    }

    // MARK: - 封面磁盘缓存

    /// 封面缓存目录：~/Library/Caches/Lumi/artwork/<sha256>.jpg
    /// 放 Caches 而非 App Support —— 可被系统清理，清理后只是重新取一次图，
    /// 不会损坏任何状态。
    private static var artworkCacheDir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lumi/artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// 缓存键 → 文件路径。用 SHA256 而非直接当文件名：键含歌名/歌手/专辑，
    /// 可能带斜杠、超长、含不合法字符，哈希避开全部这些问题。
    private static func artworkCacheFile(forKey key: String) -> URL? {
        guard !key.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return artworkCacheDir.appendingPathComponent(name + ".jpg")
    }

    /// 读缓存。同步执行（调用点在 scriptQueue）：本地磁盘读一张 <200KB 的 JPEG
    /// 远快于既有的 AppleScript 阻塞调用（100–300ms），不会显著拖慢轮询。
    private func cachedArtworkImage(forKey key: String) -> NSImage? {
        guard let file = Self.artworkCacheFile(forKey: key) else { return nil }
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return nil }
        return NSImage(data: data)
    }

    /// 写缓存。在 artworkQueue 上执行（调用点即该队列），写失败静默忽略 ——
    /// 缓存只是加速手段，失败不影响功能。
    private func storeArtwork(_ image: NSImage, key: String) {
        guard let file = Self.artworkCacheFile(forKey: key),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        else { return }
        try? jpeg.write(to: file, options: .atomic)
        pruneArtworkCache()
    }

    /// 缓存容量上限（张）。超出时按修改时间淘汰最旧的，避免长期使用后无限增长。
    /// 单张 640×640 JPEG 约 60–90KB，600 张 ≈ 50MB 上限。
    private static let artworkCacheMaxItems = 600

    private func pruneArtworkCache() {
        let dir = Self.artworkCacheDir
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        guard files.count > Self.artworkCacheMaxItems else { return }
        let sorted = files.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return da < db
        }
        for file in sorted.prefix(files.count - Self.artworkCacheMaxItems) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// 切歌后用 scriptQueue 周期性探一次封面：Music 封面往往晚于切歌事件就绪，
    /// 因此主动重试若干次（总跨度约 2.2s），不等 1.5s 主轮询，缩短首屏延迟。
    /// 计数器与探测闭包统一收敛到 scriptQueue：fetchArtwork 从 artworkQueue 调用
    /// 本方法时，原实现会在 artworkQueue 上读写 artworkRetryCount，与 fetchInfoSync
    /// 在 scriptQueue 上的重置形成跨队列无锁访问。
    func scheduleArtworkRetry() {
        scriptQueue.async { [weak self] in
            guard let self = self else { return }
            guard self.artworkRetryCount < 4 else { return }
            self.artworkRetryCount += 1
            let delay = [0.5, 0.9, 1.5, 2.2][self.artworkRetryCount - 1]
            self.scriptQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self else { return }
                if self.hasArtFlag { return }   // 已取到封面
                let src = """
                tell application "Music"
                    try
                        if player state is not stopped and exists artwork 1 of current track then
                            return "yes"
                        else
                            return "no"
                        end if
                    end try
                    return "no"
                end tell
                """
                guard let d = self.runScript(src), d.stringValue == "yes" else { return }
                self.fetchArtwork()
            }
        }
    }

    // MARK: - 在线目录封面（AppleScript 读不到 artwork 时）

    /// Apple Music 目录源（首选回退源）。
    ///
    /// 为什么优先 Apple 而非网易云：iTunes Search API 返回的 artwork 就是 Apple Music
    /// 自己在用的那张图，同源即同图 —— 命中时不存在「取到另一个版本专辑封面」的可能。
    /// 网易云只能做同名同歌手的模糊匹配，实测《神预言》袁娅维会同时命中录音室版与
    /// 《为歌而赞》Live 版，两者歌名歌手完全相同，只有专辑名和时长能区分，取到哪个
    /// 取决于接口排序，这就是「图片有时候会不对」的主因。
    ///
    /// 店铺选择：实测 country=cn 恒返回 0 条（Apple 中国区目录未开放该接口），
    /// 而 tw/hk/sg/jp 四个区对华语曲库覆盖都很好。逐个试，第一个有结果的即采用。
    private func fetchArtworkFromAppleCatalog() {
        scriptQueue.async { [weak self] in
            guard let self else { return }
            guard !self.artworkAppleTried, !self.artworkNeteaseTried else { return }
            guard !self.queueTitle.isEmpty else { return }
            self.artworkAppleTried = true

            let title = self.queueTitle
            let artist = self.queueArtist
            let album = self.queueAlbum
            let duration = self.queueDuration
            let token = self.artworkToken
            // 缓存键必须与 token 同时从 scriptQueue 捕获：切歌后回填时用的
            // 是「发起请求那一刻」的曲目，否则会把 B 歌的图写进 A 歌的缓存键。
            let cacheKey = ArtworkScoring.cacheKey(title: title, artist: artist, album: album)
            // 查询词优先「歌手 + 歌名」，Apple 目录对这种组合的排序明显优于纯歌名。
            let term = artist.isEmpty ? title : "\(artist) \(title)"
            self.artworkAppleSearch(term: term, title: title, artist: artist,
                                    album: album, duration: duration,
                                    countries: Self.artworkAppleCountries, index: 0) { [weak self] result in
                guard let self else { return }
                guard let result else {
                    // Apple 目录全部店铺都没命中，才退到网易云（覆盖 Apple 未收录的独立音乐人）。
                    self.lyricLog("封面：Apple 目录未命中，退网易云 title=\(title) artist=\(artist)")
                    self.fetchArtworkFromNetease()
                    return
                }
                self.artworkDownload(result.url, token: token, label: "Apple 目录") { [weak self] data in
                    guard let self, let data, let image = NSImage(data: data) else {
                        self?.lyricLog("封面：Apple 目录图下载失败 bytes=\(data?.count ?? -1) title=\(title)")
                        return
                    }
                    self.lyricLog("封面：命中 Apple 目录 \(result.album) 评分=\(result.score) title=\(title)")
                    self.installArtwork(image, token: token, cacheKey: cacheKey)
                }
            }
        }
    }

    /// 实测覆盖最好的几个区，顺序即尝试顺序。
    private static let artworkAppleCountries = ["tw", "hk", "sg", "jp"]

    /// 封面专用打分：在歌词的 matchScore 之上追加专辑名与时长两项。
    /// 歌词错几句不易察觉，封面错一张一眼可见，因此这里对「版本差异」扣得很重。
    /// 复用 `ArtworkScoring.integratedScore` 纯函数，便于单测覆盖完整四路规则。
    func artworkMatchScore(title: String, artist: String, album: String, durSec: Double,
                           expTitle: String, expArtist: String,
                           expAlbum: String, expDur: Double) -> Int {
        ArtworkScoring.integratedScore(rTitle: title, rArtist: artist,
                                       rAlbum: album, rDurSec: durSec,
                                       eTitle: expTitle, eArtist: expArtist,
                                       eAlbum: expAlbum, eDurSec: expDur)
    }

    /// 下线通用图片下载：结果统一回主线程，由调用方决定安装与否。
    private func artworkDownload(_ url: URL, token: Int, label: String,
                                 completion: @escaping (Data?) -> Void) {
        // 过期曲目连图片都不下载：这一步省的是最贵的一次网络往返。
        scriptQueue.async { [weak self] in
            guard let self else { return }
            guard token == self.artworkToken else {
                self.lyricLog("封面：\(label)链路已过期 token=\(token) 当前=\(self.artworkToken)")
                return
            }
            var req = URLRequest(url: url)
            req.timeoutInterval = 10
            req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            if url.host?.hasSuffix("music.126.net") == true {
                req.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
            }
            URLSession.shared.dataTask(with: req) { data, _, err in
                DispatchQueue.main.async { completion(err == nil ? data : nil) }
            }.resume()
        }
    }

    /// Apple 目录命中结果。
    struct ArtworkAppleHit {
        let url: URL
        let album: String
        let score: Int
    }

    /// 逐个店铺检索 Apple 目录。任一店铺返回可接受候选即停止。
    private func artworkAppleSearch(term: String, title: String, artist: String,
                                    album: String, duration: Double,
                                    countries: [String], index: Int,
                                    completion: @escaping (ArtworkAppleHit?) -> Void) {
        guard index < countries.count else {
            completion(nil)
            return
        }
        let country = countries[index]
        var comps = URLComponents(string: "https://itunes.apple.com/search")
        comps?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "20"),
            URLQueryItem(name: "country", value: country),
        ]
        guard let url = comps?.url else {
            artworkAppleSearch(term: term, title: title, artist: artist, album: album,
                               duration: duration, countries: countries, index: index + 1,
                               completion: completion)
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self else { return }
            let retryNext = {
                self.artworkAppleSearch(term: term, title: title, artist: artist,
                                        album: album, duration: duration,
                                        countries: countries, index: index + 1,
                                        completion: completion)
            }
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = obj["results"] as? [[String: Any]] else {
                retryNext()
                return
            }
            if let hit = self.bestAppleHit(results, title: title, artist: artist,
                                           album: album, duration: duration) {
                completion(hit)
            } else {
                retryNext()
            }
        }.resume()
    }

    /// Apple 目录候选打分：歌名 + 歌手 + 专辑名 + 时长四路交叉验证，取最高分。
    /// 时长是最强信号 —— 录音室版与 Live 版时长常差 30s 以上，而歌名歌手完全一致。
    private func bestAppleHit(_ results: [[String: Any]], title: String, artist: String,
                              album: String, duration: Double) -> ArtworkAppleHit? {
        var best: ArtworkAppleHit?
        for r in results {
            let t = r["trackName"] as? String ?? ""
            let a = r["artistName"] as? String ?? ""
            let al = r["collectionName"] as? String ?? ""
            let ms = (r["trackTimeMillis"] as? NSNumber)?.doubleValue ?? 0
            guard let art = r["artworkUrl100"] as? String, !art.isEmpty else { continue }
            // 100x100 直接替换成 600x600：同一 URL 模板，Apple 侧按尺寸出图。
            let big = art.replacingOccurrences(of: "100x100bb", with: "600x600bb")
            guard let url = URL(string: big) else { continue }
            let score = artworkMatchScore(title: t, artist: a, album: al,
                                          durSec: ms / 1000.0,
                                          expTitle: title, expArtist: artist,
                                          expAlbum: album, expDur: duration)
            guard score >= artworkMinScore else { continue }
            if best == nil || score > best!.score {
                best = ArtworkAppleHit(url: url, album: al, score: score)
            }
        }
        return best
    }

    // MARK: - 网易云回退封面（Apple 目录也没命中时）

    /// 从网易云取封面：Apple 目录未收录的独立音乐人只能靠这里。
    ///
    /// 为什么复用 neteaseSearch 的候选：封面必须与歌词出自同一曲目，否则会出现
    /// 「歌词是 A 歌、封面是 B 歌」的错位。两处共用 matchScore，串曲风险一致可控。
    ///
    /// 每曲目只试一次（artworkNeteaseTried），失败保持占位图，不反复刷接口。
    private func fetchArtworkFromNetease() {
        scriptQueue.async { [weak self] in
            guard let self else { return }
            guard !self.artworkNeteaseTried else { return }
            guard !self.queueTitle.isEmpty else { return }
            self.artworkNeteaseTried = true

            let title = self.queueTitle
            let artist = self.queueArtist
            let album = self.queueAlbum
            let duration = self.queueDuration
            let token = self.artworkToken
            // 缓存键与 token 一同在 scriptQueue 捕获，理由同 Apple 目录源。
            let cacheKey = ArtworkScoring.cacheKey(title: title, artist: artist, album: album)
            self.artworkNeteaseResolve(title: title, artist: artist,
                                       album: album, duration: duration) { [weak self] songID in
                guard let self, let songID else {
                    self?.lyricLog("封面：网易云未命中歌曲 title=\(title) artist=\(artist)")
                    return
                }
                // 回调来自网络线程：代号必须回到 scriptQueue 上读，且过期时连图片请求都不发
                // （三跳网络耗时数秒，切歌后继续下载正是「贴错封面」的高发窗口）。
                self.scriptQueue.async {
                    guard token == self.artworkToken else {
                        self.lyricLog("封面：网易云链路已过期 token=\(token) 当前=\(self.artworkToken)")
                        return
                    }
                    self.artworkNeteasePic(songID: songID, title: title, artist: artist,
                                           album: album, duration: duration) { data in
                        guard let data, let image = NSImage(data: data) else {
                            self.lyricLog("封面：songID=\(songID) 下载字节=\(data?.count ?? -1) title=\(title)")
                            return
                        }
                        self.installArtwork(image, token: token, cacheKey: cacheKey)
                    }
                }
            }
        }
    }

    /// 用与歌词一致的候选匹配找出歌曲 ID。只在 scriptQueue 上读写输入，
    /// 网络回调里只回传 ID，不做共享状态写操作。
    private func artworkNeteaseResolve(title: String, artist: String,
                                       album: String, duration: Double,
                                       completion: @escaping (Int?) -> Void) {
        let cleaned = cleanTrackTitle(title)
        let primary = primaryArtist(artist)
        var queries: [String] = []
        for a in [artist, primary] where !a.isEmpty {
            for t in [cleaned, title] where !t.isEmpty {
                let q = "\(a) \(t)"
                if !queries.contains(q) { queries.append(q) }
            }
        }
        for t in [cleaned, title] where !t.isEmpty {
            if !queries.contains(t) { queries.append(t) }
        }
        guard !queries.isEmpty else {
            completion(nil)
            return
        }
        artworkNeteaseSearch(queries: queries, index: 0, expectTitle: title,
                             expectArtist: artist, primaryArtist: primary,
                             expectAlbum: album, expectDuration: duration,
                             accumulated: []) { [weak self] best in
            // 兜底候选同样要过分数线。原实现把所有查询跑完之后的「最高分」直接返回，
            // 哪怕只有 60 分（歌名互相包含、歌手对不上）也会贴上去 —— 网易云的海量
            // Live / Acoustic / 翻唱条目正是「图片不对」的第二个根因。
            // 不到线就返回 nil，界面保持占位图：没有封面远好于错封面。
            guard let self, let best, best.score >= self.artworkMinScore else {
                completion(nil)
                return
            }
            completion(best.id)
        }
    }

    /// 依次尝试查询候选，命中即停（与歌词链路同策略，省请求）。
    private func artworkNeteaseSearch(queries: [String], index: Int,
                                      expectTitle: String, expectArtist: String,
                                      primaryArtist: String,
                                      expectAlbum: String, expectDuration: Double,
                                      accumulated: [(score: Int, id: Int)],
                                      completion: @escaping ((score: Int, id: Int)?) -> Void) {
        guard index < queries.count else {
            completion(accumulated.sorted { $0.score > $1.score }.first)
            return
        }
        let q = QueryEncoding.encode(queries[index])
        guard !q.isEmpty,
              let url = URL(string: "https://music.163.com/api/search/get?s=\(q)&type=1&limit=10") else {
            artworkNeteaseSearch(queries: queries, index: index + 1, expectTitle: expectTitle,
                                expectArtist: expectArtist, primaryArtist: primaryArtist,
                                expectAlbum: expectAlbum, expectDuration: expectDuration,
                                accumulated: accumulated, completion: completion)
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        req.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            guard let self else { return }
            var ranked: [(score: Int, id: Int)] = []
            if err == nil,
               let obj = try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any],
               let songs = ((obj["result"] as? [String: Any])?["songs"]) as? [[String: Any]] {
                for song in songs {
                    guard let id = song["id"] as? Int else { continue }
                    let name = song["name"] as? String ?? ""
                    let artists = (song["artists"] as? [[String: Any]])?
                        .compactMap { $0["name"] as? String }.joined(separator: "/") ?? ""
                    // 与 Apple 目录同一套四路打分：歌名 + 歌手 + 专辑名 + 时长。
                    // 网易云的 Live / 串烧条目歌名歌手与原曲一字不差，只有后两项能区分。
                    let album = (song["album"] as? [String: Any])?["name"] as? String ?? ""
                    let ms = (song["duration"] as? NSNumber)?.doubleValue ?? 0
                    var score = self.artworkMatchScore(
                        title: name, artist: artists, album: album, durSec: ms / 1000.0,
                        expTitle: expectTitle, expArtist: expectArtist,
                        expAlbum: expectAlbum, expDur: expectDuration)
                    if score < 0 { continue }
                    // 与歌词链路同一层重罚：压住网易海量翻唱/混音，防串封面。
                    if !primaryArtist.isEmpty,
                       !artists.localizedCaseInsensitiveContains(primaryArtist) {
                        score -= 30
                    }
                    ranked.append((score, id))
                }
                ranked.sort { $0.score > $1.score }
            }
            let pool = (accumulated + ranked).sorted { $0.score > $1.score }
            // 与歌词链路同阈值：115 分即停止继续搜索。
            if let top = pool.first, top.score >= 115 {
                completion(top)
            } else {
                self.artworkNeteaseSearch(queries: queries, index: index + 1,
                                          expectTitle: expectTitle, expectArtist: expectArtist,
                                          primaryArtist: primaryArtist,
                                          expectAlbum: expectAlbum, expectDuration: expectDuration,
                                          accumulated: pool, completion: completion)
            }
        }.resume()
    }

    /// 由歌曲 ID 取 album.picUrl 并下载图片。
    /// 搜索接口只回 picId 不回 picUrl，必须再调一次 song/detail。
    ///
    /// detail 返回后按同一套 matchScore 再复核一次歌名/歌手：搜索接口排序带热度权重，
    /// 同名不同版本（Live、伴奏、翻唱）的封面完全是另一张图，这一步把「搜到了但贴错」
    /// 挡在下载之前。
    private func artworkNeteasePic(songID: Int, title: String, artist: String,
                                   album: String, duration: Double,
                                   completion: @escaping (Data?) -> Void) {
        let ids = QueryEncoding.encode("[\(songID)]")
        guard let url = URL(string: "https://music.163.com/api/song/detail?ids=\(ids)") else {
            completion(nil)
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        req.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        artworkQueue.async {
            URLSession.shared.dataTask(with: req) { data, _, err in
                guard err == nil,
                      let data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let songs = obj["songs"] as? [[String: Any]],
                      let song = songs.first,
                      let albumDict = (song["album"] as? [String: Any]),
                      let picUrl = albumDict["picUrl"] as? String,
                      let picURL = URL(string: picUrl + "?param=280y280") else {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                let detailArtist = (song["artists"] as? [[String: Any]])?
                    .compactMap { $0["name"] as? String }.joined(separator: "/") ?? ""
                // 四路复核：歌名 + 歌手 + 专辑名 + 时长。专辑/时长用 song/detail 的
                // 权威字段（搜索接口的可能是简写），复核不过就不下载。
                let detailAlbum = albumDict["name"] as? String ?? ""
                let detailMS = (song["duration"] as? NSNumber)?.doubleValue ?? 0
                var detailScore = self.artworkMatchScore(
                    title: song["name"] as? String ?? "", artist: detailArtist,
                    album: detailAlbum, durSec: detailMS / 1000.0,
                    expTitle: title, expArtist: artist,
                    expAlbum: album, expDur: duration)
                if detailScore >= 0 {
                    let primary = self.primaryArtist(artist)
                    if !primary.isEmpty, !detailArtist.localizedCaseInsensitiveContains(primary) {
                        detailScore -= 30
                    }
                }
                guard detailScore >= self.artworkMinScore else {
                    self.lyricLog("封面：detail 复核未通过 score=\(detailScore) songID=\(songID) title=\(title)")
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                var picReq = URLRequest(url: picURL)
                picReq.timeoutInterval = 10
                picReq.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
                picReq.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
                URLSession.shared.dataTask(with: picReq) { picData, _, picErr in
                    DispatchQueue.main.async {
                        completion(picErr == nil ? picData : nil)
                    }
                }.resume()
            }.resume()
        }
    }

    /// 在后台把 NSImage 稳健缩放为目标尺寸（CGContext 绘制，避免 lockFocus 隐患）。
    private static func scaledImage(_ image: NSImage, to size: NSSize) -> NSImage? {
        var srcCG: CGImage?
        if let tiff = image.tiffRepresentation,
           let src = CGImageSourceCreateWithData(tiff as CFData, nil),
           let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            srcCG = cg
        } else if let rep = image.representations.first as? NSBitmapImageRep {
            srcCG = rep.cgImage
        }
        guard let cg = srcCG else { return nil }
        let target = CGSize(width: size.width, height: size.height)
        guard let context = CGContext(data: nil,
                                      width: Int(target.width),
                                      height: Int(target.height),
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(cg, in: CGRect(x: 0, y: 0, width: target.width, height: target.height))
        guard let out = context.makeImage() else { return nil }
        return NSImage(cgImage: out, size: size)
    }
}

// MusicController 的歌词引擎 extension：内嵌歌词读取、在线歌词（lrclib/lyrics.ovh）
// 搜索与匹配、LRC 时间轴解析、自带双语行拆分、繁转简。
extension MusicController {

    // MARK: - 歌词获取
    /// 外部入口：调度到 scriptQueue 执行，避免在主线程同步执行 AppleScript。
    func fetchLyrics(force: Bool = true) {
        scriptQueue.async { [weak self] in
            guard let self = self else { return }
            self.fetchLyricsSync(title: self.queueTitle,
                                 artist: self.queueArtist,
                                 force: force)
        }
    }

    /// 必须在 scriptQueue 上调用。
    /// force=false 且当前曲目已取到歌词时跳过，避免无谓的 AppleScript 调用。
    func fetchLyricsSync(title: String, artist: String, force: Bool) {
        // 守卫必须全部排在阻塞式 AppleScript 之前：getEmbeddedLyrics 是一次跨进程
        // 调用，播放中每 1.5s 轮询都会经过这里。旧实现把它放在最前面，于是
        // 「已判定过」的歌曲每拍仍要多打一次 AppleScript，占着 scriptQueue ——
        // 同一队列上的播放进度采样被拖慢，歌词就会比歌声晚。
        if !force, hasLyricsFlag { return }

        // 走到这里说明内嵌歌词为空：Apple Music 的流媒体订阅歌曲大多如此。
        // 回退到在线歌词（lrclib 免费 API，按 歌名+歌手 搜索）。
        // lrclib 的 syncedLyrics 是社区从 Apple Music 扒取的逐行时间轴歌词，
        // 优先拿它做带时间轴的逐行高亮。
        let key = "\(title)-\(artist)"
        // 成功取过则跳过；失败（含网络不可达）不记入 onlineSearchedKeys，允许后续周期重试，
        // 但限制每首最多 3 次尝试，避免无谓刷请求。
        // 兜底：该曲记录过成功/纯音乐结论、但当前歌词已被清空（停止→重播、切歌竞态）时，
        // 仍允许重新请求。
        // 守卫路径全部落日志：此前这些 return 全是静默的，用户报「无法获取歌词」时，
        // 日志与链根本没跑过的表现一模一样，无法区分「没触发」还是「被拦截」。
        guard !title.isEmpty else {
            lyricLog("取词跳过：标题为空（Music 未返回当前曲目）")
            return
        }
        guard force,
              (!onlineSearchedKeys.contains(key) || !hasLyricsFlag) else {
            lyricLog("取词跳过：该曲已判定过（有词/纯音乐结论）且当前仍有歌词 title=\(title)")
            return
        }
        // 在途去重：同一首歌的上一条取词链还没跑完（异步全链可能耗时数十秒），
        // 1.5s 轮询会再次触发 —— 直接跳过，避免并发风暴一次烧光 onlineAttempts。
        if lyricInFlightKey == key,
           let since = lyricInFlightSince,
           Date().timeIntervalSince(since) < lyricInFlightWindow {
            lyricLog("取词在途去重：同曲上一条链仍在运行（已 \(Int(Date().timeIntervalSince(since)))s/\(Int(lyricInFlightWindow))s），跳过 title=\(title)")
            return
        }
        var attempts = onlineAttempts[key] ?? 0
        if attempts >= 3 {
            // 已达尝试上限：等一段冷却再归零重试（应对网络不可达/代理抖动）。
            // 冷却按**连续命中次数**递减：网络只抖了一下就能很快卷土重来，
            // 反复失败才拉长间隔。一刀切 60s 的旧行为会让「网络早恢复了、
            // 歌词却还要等半分钟以上」——用户感知就是歌词卡住不出。
            if let lastFail = lyricLastFail[key] {
                let elapsed = Date().timeIntervalSince(lastFail)
                // 首次冷却 6s，之后每多失败一轮翻倍，上限 48s
                let cooldown = min(lyricRetryCooldownBase * pow(2, Double(attempts / 3 - 1)),
                                   lyricRetryCooldownMax)
                if elapsed < cooldown {
                    lyricLog("取词冷却中：该曲已失败 \(attempts) 次，距上次失败 \(Int(elapsed))s < \(Int(cooldown))s，跳过 title=\(title)")
                    return
                }
            }
            attempts = 0
        }
        // 全部便宜守卫都过了，这才打这次阻塞式 AppleScript 读内嵌歌词。
        // 顺序很关键：内嵌歌词是本地音轨最同源的歌词，必须优先于在线源；
        // 但它也是这里唯一的一次跨进程调用，不能放在 early-return 之前，
        // 否则已判定过的歌曲每 1.5s 轮询都要白打一次，占住 scriptQueue。
        let embedded = getEmbeddedLyrics()
        if !embedded.isEmpty {
            hasLyricsFlag = true
            // 内嵌歌词可能是带 [mm:ss.xx] 的 LRC（本地导入音轨最常见），
            // 必须解析为时间轴逐行高亮，而不是一律退化成纯文本。
            let synced = parseSyncedLyrics(embedded)
            let plain = synced.isEmpty ? embedded : synced.map(\.text).joined(separator: "\n")
            setSyncedLyrics(synced: synced, plain: plain, title: title, artist: artist)
            lyricLog("命中 Music 内嵌歌词 len=\(embedded.count) synced=\(synced.count) title=\(title)")
            // 已写回内嵌歌词：释放在途标记并收尾，不再走在线源
            lyricInFlightKey = nil
            lyricInFlightSince = nil
            return
        }

        lyricInFlightKey = key
        lyricInFlightSince = Date()
        onlineAttempts[key] = attempts + 1
        if onlineAttempts.count > 200 { onlineAttempts.removeAll() }
        // 同一份失败记忆的容量兜底：切歌复位覆盖正常路径，这里防的是
        // 同一会话里连切几百首都没命中复位的极端情况（与 onlineAttempts 同规则）。
        if lyricLastFail.count > 200 { lyricLastFail.removeAll() }
        fetchLyricsOnline(artist: artist, title: title)
    }

    /// 读取 Apple Music 内嵌歌词（本地导入文件才有，流媒体通常为空）
    private func getEmbeddedLyrics() -> String {
        let src = """
        tell application "Music"
            try
                if exists current track then
                    set rawLyrics to lyrics of current track
                    if rawLyrics is not missing value then
                        return rawLyrics as text
                    end if
                end if
            end try
            return ""
        end tell
        """
        guard let desc = runScript(src) else { return "" }
        return (desc.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 在线歌词回退：从 lrclib.net 搜索（流媒体歌曲也有效）
    /// 策略：清洗曲名（移除 (Bonus Track) / - Remastered 等版本后缀）→ 优先精确匹配，
    /// 失败再回退到原始曲名；使用更宽松的 /api/search 接口。
    private func fetchLyricsOnline(artist: String, title: String) {
        // 候选歌名：清洗后的简体名 + 原始名 + 原始名的简体，尽量覆盖 lrclib 收录形态。
        // lrclib 中文歌词多为简体收录，繁体歌名直接搜常落空，故显式加入简体变体。
        var tracks: [String] = []
        let cleaned = cleanTrackTitle(title)
        let simpTitle = toSimplified(title)
        for t in [cleaned, simpTitle, title] where !t.isEmpty {
            if !tracks.contains(t) { tracks.append(t) }
        }

        // 候选组合：先带歌手精确搜，再逐步放宽。
        // 很多歌搜不到是因为 Music 里的歌手字段是 "A & B" / "A feat. B" /
        // "A, B" 这类组合，与 lrclib 收录的主歌手对不上。
        var candidates: [(artist: String, track: String)] = []
        for t in tracks { candidates.append((artist, t)) }
        let primary = primaryArtist(artist)
        if primary != artist, !primary.isEmpty {
            for t in tracks { candidates.append((primary, t)) }
        }
        // 最后兜底：只用歌名搜索（不带歌手），靠后续校验过滤错误结果
        for t in tracks { candidates.append(("", t)) }

        tryLyricsCandidatesFast(candidates: candidates,
                                originalTitle: title, originalArtist: artist)
    }

    /// lrclib 候选的并发预取数。
    ///
    /// 首候选命中率最高（精确歌手 + 歌名），但旧实现是纯串行：每个候选最多
    /// 8s 超时，而候选最多约 9 个（清洗名 × 原始名 × 纯歌名）—— 最坏要 72s
    /// 才轮到国内源，用户观感就是「歌词迟迟不出」。
    /// 前 2 个并行把最坏延迟砍掉一半，又不至于像全并发那样打满请求。
    /// 并发探测前 N 个 lrclib 候选：谁先返回可用歌词就用谁，
    /// 全都没词才回到串行路径试剩余候选。
    private func tryLyricsCandidatesFast(candidates: [(artist: String, track: String)],
                                        originalTitle: String, originalArtist: String) {
        let batch = Array(candidates.prefix(lrclibPrefetchCount))
        guard batch.count > 1, hostHealthy("lrclib.net") else {
            tryLyricsCandidates(candidates: candidates, index: 0,
                                originalTitle: originalTitle, originalArtist: originalArtist)
            return
        }
        let group = DispatchGroup()
        let lock = NSLock()
        var winnerIndex: Int?
        for (offset, c) in batch.enumerated() {
            group.enter()
            lrclibProbe(artist: c.artist, track: c.track) { hasLyrics in
                defer { group.leave() }
                guard hasLyrics else { return }
                lock.lock()
                if winnerIndex == nil { winnerIndex = offset }
                lock.unlock()
            }
        }
        group.notify(queue: scriptQueue) { [weak self] in
            guard let self else { return }
            lock.lock()
            let won = winnerIndex
            lock.unlock()
            if let won {
                // 胜出者走完整流程：解析 + 评分 + 写回（唯一，不会互相覆盖）
                self.runLyricsCandidate(batch[won], index: won,
                                        originalTitle: originalTitle,
                                        originalArtist: originalArtist,
                                        onMiss: { [weak self] in
                    // 胜出者也没词：继续串行试剩余候选
                    self?.tryLyricsCandidates(candidates: candidates,
                                             index: self?.lrclibPrefetchCount ?? 0,
                                             originalTitle: originalTitle,
                                             originalArtist: originalArtist)
                })
                return
            }
            // 前 N 个都没词：串行试剩余候选（含网络失败计数）
            self.tryLyricsCandidates(candidates: candidates, index: self.lrclibPrefetchCount,
                                     originalTitle: originalTitle, originalArtist: originalArtist)
        }
    }

    /// 构造 lrclib 搜索请求（探测与完整流程共用同一 URL，避免重复网络往返）。
    private func lrclibSearchRequest(artist: String, track: String) -> URLRequest? {
        let a = QueryEncoding.encode(artist)
        let tt = QueryEncoding.encode(track)
        var urlStr = "https://lrclib.net/api/search?track_name=\(tt)"
        if !a.isEmpty { urlStr += "&artist_name=\(a)" }
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        return req
    }

    /// 只探测不写回：问某个 lrclib 候选有没有可用歌词。
    /// 与完整流程分离，避免并发多成功互相覆盖歌词。
    private func lrclibProbe(artist: String, track: String,
                            completion: @escaping (_ hasLyrics: Bool) -> Void) {
        guard let req = lrclibSearchRequest(artist: artist, track: track) else {
            completion(false)
            return
        }
        URLSession.shared.dataTask(with: req) { data, _, err in
            if let err = err {
                if NetworkErrorText.isCertificateFailure(err) {
                    self.markHostUnreachable("lrclib.net")
                }
                completion(false)
                return
            }
            guard let data,
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else { completion(false); return }
            let hasLyrics = arr.contains { d in
                let synced = d["syncedLyrics"] as? String ?? ""
                let plain = d["plainLyrics"] as? String ?? ""
                return !synced.isEmpty || !plain.isEmpty
            }
            completion(hasLyrics)
        }.resume()
    }

    /// 跑单个 lrclib 候选的完整流程（解析 + 评分 + 写回）。
    /// 未命中时通过 `onMiss` 回调交还调度方，由它决定试下一个还是换源。
    private func runLyricsCandidate(_ c: (artist: String, track: String),
                                   index: Int,
                                   originalTitle: String, originalArtist: String,
                                   onMiss: @escaping () -> Void) {
        guard let req = lrclibSearchRequest(artist: c.artist, track: c.track) else {
            onMiss()
            return
        }
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            guard let self else { return }
            let hostFailure: Bool
            if let err = err {
                self.lyricLog("候选[\(index)]网络错误 artist=\(c.artist) track=\(c.track) err=\(NetworkErrorText.describe(err))")
                hostFailure = (err as NSError).domain == NSURLErrorDomain
                if hostFailure { self.markHostUnreachable("lrclib.net") }
            } else if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                self.lyricLog("候选[\(index)]HTTP \(http.statusCode) artist=\(c.artist) track=\(c.track)，交棒网易云")
                self.markHostUnreachable("lrclib.net")
                self.fetchLyricsNetease(artist: originalArtist, title: originalTitle)
                return
            } else {
                hostFailure = false
            }
            let resolved = self.resolveLyrics(data,
                                              expectTitle: originalTitle,
                                              expectArtist: originalArtist,
                                              expectDuration: self.currentQueueDuration(),
                                              expectAlbum: self.currentQueueAlbum())
            if resolved.hasContent {
                self.lyricLog("候选[\(index)]命中歌词 synced=\(resolved.synced.count) plainLen=\(resolved.plain.count) title=\(originalTitle)")
                self.setSyncedLyrics(synced: resolved.synced,
                                     plain: resolved.plain,
                                     title: originalTitle,
                                     artist: originalArtist)
                if resolved.synced.isEmpty {
                    self.lyricLog("纯文本已显示，继续向国内源争取时间轴 title=\(originalTitle)")
                    self.fetchLyricsNetease(artist: originalArtist, title: originalTitle)
                }
            } else {
                self.lyricLog("候选[\(index)]未命中，尝试下一个 title=\(originalTitle)")
                onMiss()
            }
        }.resume()
    }

    // MARK: - LRC 解析

    /// 把 LRC 文本（含 [mm:ss.xx] 时间戳）解析为带时间轴的 SyncedLine 数组。
    ///
    /// 优先走共享的 LRCParser（预编译正则、[offset:] 元数据、多时间戳、稳定排序），
    /// 在此之上做行内双语拆分与繁转简。
    private func parseSyncedLyrics(_ raw: String?) -> [SyncedLine] {
        LRCParser.parse(raw ?? "").map { line in
            let (text, translation) = splitBilingualLine(line.text)
            return SyncedLine(
                text: toSimplified(text),
                time: line.time,
                translation: translation.map { toSimplified($0) }
            )
        }
    }

    /// 过滤 LRC 里的制作信息行：这些不是歌词，显示出来很碍眼。
    /// 覆盖中英文 LRC 常见的词曲/录音/混音/母带/后期等署名。
    private func isLyricMetadataLine(_ line: String) -> Bool {
        LyricMetadataLine.isMetadata(line)
    }

    /// 与 `parseSyncedLyrics` 的区别：不做「一行内双语」拆分——网易云的译文是独立
    /// 一份 LRC，按时间戳单独对齐即可，拆行反而会把正常的 ` / ` 误判成双语。
    private func parseLrcPairs(_ raw: String) -> [(time: TimeInterval, text: String)] {
        LRCParser.parse(raw)
            .filter { !isLyricMetadataLine($0.text) }
    }

    /// 全部歌词源都不可用（网络不可达）：记一次失败并释放在途标记，
    /// 让渐进退避决定何时重试，不要把该曲焊死。
    private func markLyricsUnavailable(title: String, artist: String) {
        let key = "\(title)-\(artist)"
        scriptQueue.async {
            self.lyricLastFail[key] = Date()
            if self.lyricInFlightKey == key {
                self.lyricInFlightKey = nil
                self.lyricInFlightSince = nil
            }
        }
    }

    // MARK: - 国内歌词源回退

    /// 网易云歌词源（国内网络 DIRECT 可达，且同时提供原文 LRC 与中文译文 LRC）。
    private func fetchLyricsNetease(artist: String, title: String) {
        // 该主机若因证书校验失败（代理在解密 HTTPS）被判不可用，直接交棒 QQ 源：
        // 否则每首歌开头都要先白等一轮 10s 超时，表现为「歌词迟迟不出现」。
        if !hostHealthy("music.163.com") {
            lyricLog("网易云处于不可达冷却期，直接用 QQ 源 artist=\(artist) title=\(title)")
            fetchLyricsQQ(artist: artist, title: title)
            return
        }
        let cleaned = cleanTrackTitle(title)
        let primary = primaryArtist(artist)
        // 候选查询词：精确歌手 + 清洗歌名优先，逐步放宽到纯歌名，
        // 覆盖「张惠妹 & 某」这类组合歌手在网易云收录形态不一致的情况。
        var queries: [String] = []
        for a in [artist, primary] where !a.isEmpty {
            for t in [cleaned, title] where !t.isEmpty {
                let q = "\(a) \(t)"
                if !queries.contains(q) { queries.append(q) }
            }
        }
        for t in [cleaned, title] where !t.isEmpty {
            if !queries.contains(t) { queries.append(t) }
        }
        guard !queries.isEmpty else {
            fetchLyricsOvh(artist: artist, title: title)
            return
        }
        neteaseSearch(queries: queries, index: 0,
                      originalTitle: title, originalArtist: artist)
    }

    /// 依次查询网易云搜索接口，聚合所有查询的候选后按分数排序。
    private func neteaseSearch(queries: [String], index: Int,
                               originalTitle: String, originalArtist: String,
                               accumulated: [(score: Int, id: Int)] = []) {
        guard index < queries.count else {
            // 全部查询跑完：按分数排序取前若干个（并发预取用）
            let ranked = accumulated.sorted { $0.score > $1.score }
            guard !ranked.isEmpty else {
                lyricLog("网易云 候选均无结果，回退 QQ 音乐 artist=\(originalArtist) title=\(originalTitle)")
                self.fetchLyricsQQ(artist: originalArtist, title: originalTitle)
                return
            }
            neteaseLyricTryFast(candidates: ranked,
                                originalTitle: originalTitle, originalArtist: originalArtist)
            return
        }
        let q = QueryEncoding.encode(queries[index])
        guard !q.isEmpty,
              let url = URL(string: "https://music.163.com/api/search/get?s=\(q)&type=1&limit=10") else {
            neteaseSearch(queries: queries, index: index + 1,
                          originalTitle: originalTitle, originalArtist: originalArtist,
                          accumulated: accumulated)
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        req.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            guard let self = self else { return }
            var ranked: [(score: Int, id: Int)] = []
            if err == nil,
               let obj = try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any],
               let songs = ((obj["result"] as? [String: Any])?["songs"]) as? [[String: Any]] {
                let primary = self.primaryArtist(originalArtist)
                for song in songs {
                    guard let id = song["id"] as? Int else { continue }
                    let name = song["name"] as? String ?? ""
                    let artists = (song["artists"] as? [[String: Any]])?
                        .compactMap { $0["name"] as? String }.joined(separator: "/") ?? ""
                    // 复用 lrclib 那套 matchScore（歌名匹配/包含判定），包装成同样字段名，
                    // 避免搜到同名不同曲（串词）。
                    var score = self.matchScore(["trackName": name, "artistName": artists],
                                               expectTitle: originalTitle, expectArtist: originalArtist)
                    if score < 0 { continue }
                    // matchScore 的歌手不一致只扣 6 分，压不住网易的海量翻唱/混音
                    // （实测搜「稻香」前排几乎全是翻唱）。这里补一层重罚。
                    if !primary.isEmpty,
                       !artists.localizedCaseInsensitiveContains(primary) {
                        score -= 30
                    }
                    ranked.append((score, id))
                }
                ranked.sort { $0.score > $1.score }
            } else if let err = err {
                self.lyricLog("网易云 搜索网络错误 q=\(queries[index]) err=\(NetworkErrorText.describe(err))")
                // 证书类失败是机器级问题（代理在解密 HTTPS），整源冷却：
                // 否则每首歌都要重复撞一次同一个失败，白等两轮超时。
                if NetworkErrorText.isCertificateFailure(err) {
                    self.markHostUnreachable("music.163.com")
                    self.fetchLyricsQQ(artist: originalArtist, title: originalTitle)
                    return
                }
            }
            // 跨查询合并后必须重新按分排序：否则早退判断看的「第一个」
            // 只是上一轮查询的首条，不是池内最高分。
            let pool = (accumulated + ranked).sorted { $0.score > $1.score }
            if let top = pool.first, top.score >= 115 {
                // 已有可信候选：不再搜后续查询
                self.neteaseLyricTryFast(candidates: pool,
                                        originalTitle: originalTitle, originalArtist: originalArtist)
            } else {                self.neteaseSearch(queries: queries, index: index + 1,
                                  originalTitle: originalTitle, originalArtist: originalArtist,
                                  accumulated: pool)
            }
        }.resume()
    }

    /// 并发预取前 N 个网易云候选的歌词：谁先返回可用 LRC 就用谁。
    ///
    /// 旧实现串行逐个试：前几个候选若是翻唱/漏传，每个都要等满 10s 超时，
    /// 用户观感就是「歌词迟迟不出现」。探测与写回分离，避免互相覆盖。
    private func neteaseLyricTryFast(candidates: [(score: Int, id: Int)],
                                    originalTitle: String, originalArtist: String) {
        let batch = Array(candidates.prefix(neteasePrefetchCount))
        guard batch.count > 1 else {
            neteaseLyricTry(candidates: candidates, index: 0,
                            originalTitle: originalTitle, originalArtist: originalArtist)
            return
        }
        let group = DispatchGroup()
        let lock = NSLock()
        var winnerID: Int?
        var anyPure = false
        for c in batch {
            group.enter()
            neteaseLyricProbe(songID: c.id) { hasLRC, pure in
                defer { group.leave() }
                guard hasLRC else { return }
                lock.lock()
                if winnerID == nil { winnerID = c.id }
                anyPure = anyPure || pure
                lock.unlock()
            }
        }
        group.notify(queue: scriptQueue) { [weak self] in
            guard let self else { return }
            lock.lock()
            let won = winnerID
            let pure = anyPure
            lock.unlock()
            if let won {
                self.neteaseLyric(songID: won, originalTitle: originalTitle,
                                  artist: originalArtist) { _, _ in }
                return
            }
            if pure {
                self.lyricLog("网易云 标注纯音乐，停止后续歌词源 artist=\(originalArtist) title=\(originalTitle)")
                self.markNoLyrics(pureMusic: true, title: originalTitle, artist: originalArtist)
                return
            }
            guard !self.hasLyricsFlag else { return }
            // 并发批全都没词：串行试第 N 个之后的候选
            self.neteaseLyricTry(candidates: candidates, index: self.neteasePrefetchCount,
                                originalTitle: originalTitle, originalArtist: originalArtist)
        }
    }

    /// 只探测不写回：问某个 songID 有没有可用 LRC。
    private func neteaseLyricProbe(songID: Int,
                                  completion: @escaping (_ hasLRC: Bool, _ pureMusic: Bool) -> Void) {
        guard let url = URL(string: "https://music.163.com/api/song/lyric?id=\(songID)&lv=1&kv=1&tv=-1") else {
            completion(false, false)
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        req.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        URLSession.shared.dataTask(with: req) { data, _, err in
            if let err = err {
                if NetworkErrorText.isCertificateFailure(err) {
                    self.markHostUnreachable("music.163.com")
                }
                completion(false, false)
                return
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any],
                  (obj["code"] as? Int) == 200 else {
                completion(false, false)
                return
            }
            let lrc = (obj["lrc"] as? [String: Any])?["lyric"] as? String ?? ""
            let pure = (obj["pureMusic"] as? Bool) ?? false
            completion(!self.parseLrcPairs(lrc).isEmpty, pure)
        }.resume()
    }

    /// 串行逐个试候选（并发预取未命中时的回退路径）。
    private func neteaseLyricTry(candidates: [(score: Int, id: Int)], index: Int,
                                originalTitle: String, originalArtist: String,
                                pureMusic: Bool = false) {
        guard index < min(candidates.count, 8) else {
            // 纯音乐是权威标记：再换 QQ / lyrics.ovh 也拿不到词，直接收尾并记住结论，
            // 否则每轮轮询都会把四个源重刷一遍（实测一次取词打满 12 个请求）。
            if pureMusic {
                lyricLog("网易云 标注纯音乐，停止后续歌词源 artist=\(originalArtist) title=\(originalTitle)")
                self.markNoLyrics(pureMusic: true, title: originalTitle, artist: originalArtist)
                return
            }
            lyricLog("网易云 候选均无歌词，回退 QQ 音乐 artist=\(originalArtist) title=\(originalTitle)")
            self.fetchLyricsQQ(artist: originalArtist, title: originalTitle)
            return
        }
        let songID = candidates[index].id
        neteaseLyric(songID: songID, originalTitle: originalTitle, artist: originalArtist) { [weak self] ok, isPure in
            guard let self = self else { return }
            guard !ok else { return }
            self.neteaseLyricTry(candidates: candidates, index: index + 1,
                                originalTitle: originalTitle, originalArtist: originalArtist,
                                pureMusic: pureMusic || isPure)
        }
    }

    /// 取指定歌曲的 LRC；译文按时间戳对齐后写入 `SyncedLine.translation`。
    /// completion(已写回, 是否纯音乐)：纯音乐曲目（`pureMusic` 标记）不要再换源。
    private func neteaseLyric(songID: Int, originalTitle: String, artist: String,
                             completion: @escaping (Bool, Bool) -> Void) {
        guard let url = URL(string: "https://music.163.com/api/song/lyric?id=\(songID)&lv=1&kv=1&tv=-1") else {
            fetchLyricsOvh(artist: artist, title: originalTitle)
            completion(false, false)
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        req.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            guard let self = self else { completion(false, false); return }
            if let err = err {
                self.lyricLog("网易云 歌词网络错误 id=\(songID) err=\(NetworkErrorText.describe(err))")
                if NetworkErrorText.isCertificateFailure(err) {
                    self.markHostUnreachable("music.163.com")
                }
                completion(false, false)
                return
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any],
                  obj["code"] as? Int == 200 else {
                self.lyricLog("网易云 歌词接口异常 id=\(songID)")
                completion(false, false)
                return
            }
            let lrc = (obj["lrc"] as? [String: Any])?["lyric"] as? String ?? ""
            let tlyric = (obj["tlyric"] as? [String: Any])?["lyric"] as? String ?? ""
            // pureMusic：唱片方声明该曲为纯音乐（没人唱，所以没有词）。
            // 与「LRC 为空但没人上传」是两回事——后者可能是漏传，仍值得换源。
            let pure = (obj["pureMusic"] as? Bool) ?? false
            let pairs = self.parseLrcPairs(lrc)
            guard !pairs.isEmpty else {
                self.lyricLog(pure
                              ? "网易云 标注纯音乐 id=\(songID) title=\(originalTitle)"
                              : "网易云 候选无 LRC id=\(songID)")
                completion(false, pure)
                return
            }
            let translations = self.parseLrcPairs(tlyric)
            // 译文与原文时间戳一致（同为网易上传），允许 60ms 容差对齐
            let synced: [SyncedLine] = pairs.map { p in
                let tr = translations.first { abs($0.time - p.time) < 0.06 }?.text
                return SyncedLine(text: self.toSimplified(p.text), time: p.time,
                                  translation: tr.map { self.toSimplified($0) })
            }
            self.lyricLog("网易云 命中 LRC id=\(songID) 行数=\(synced.count) 译文=\(translations.count) title=\(originalTitle)")
            let plain = synced.map { $0.text }.joined(separator: "\\n")
            self.setSyncedLyrics(synced: synced, plain: plain,
                                title: originalTitle, artist: artist)
            completion(true, false)
        }.resume()
    }

    /// QQ 音乐歌词源（网易云不可达或未命中时的回退）。
    private func fetchLyricsQQ(artist: String, title: String) {
        // 该主机若因证书校验失败被判不可用，直接交棒 lyrics.ovh：
        // 否则每首歌开头都要先白等一轮 10s 超时，表现为「歌词迟迟不出现」。
        if !hostHealthy("c.y.qq.com") {
            lyricLog("QQ 处于不可达冷却期，回退 lyrics.ovh artist=\(artist) title=\(title)")
            fetchLyricsOvh(artist: artist, title: title)
            return
        }
        let cleaned = cleanTrackTitle(title)
        let primary = primaryArtist(artist)
        var queries: [String] = []
        for a in [artist, primary] where !a.isEmpty {
            for t in [cleaned, title] where !t.isEmpty {
                let q = "\(a) \(t)"
                if !queries.contains(q) { queries.append(q) }
            }
        }
        for t in [cleaned, title] where !t.isEmpty {
            if !queries.contains(t) { queries.append(t) }
        }
        guard !queries.isEmpty else {
            fetchLyricsOvh(artist: artist, title: title)
            return
        }
        qqSearch(queries: queries, index: 0,
                 originalTitle: title, originalArtist: artist)
    }

    /// 依次查询 QQ 搜索接口，聚合候选后按分数排序。
    private func qqSearch(queries: [String], index: Int,
                         originalTitle: String, originalArtist: String,
                         accumulated: [(score: Int, mid: String)] = []) {
        guard index < queries.count else {
            let ranked = accumulated.sorted { $0.score > $1.score }
            guard !ranked.isEmpty else {
                lyricLog("QQ 候选均无结果，回退 lyrics.ovh artist=\(originalArtist) title=\(originalTitle)")
                self.fetchLyricsOvh(artist: originalArtist, title: originalTitle)
                return
            }
            neteaseLyricTryFastQQ(candidates: ranked,
                                  originalTitle: originalTitle, originalArtist: originalArtist)
            return
        }
        let q = QueryEncoding.encode(queries[index])
        guard !q.isEmpty,
              let url = URL(string: "https://c.y.qq.com/soso/fcgi-bin/client_search_cp?w=\(q)&format=json&p=1&n=10") else {
            qqSearch(queries: queries, index: index + 1,
                     originalTitle: originalTitle, originalArtist: originalArtist,
                     accumulated: accumulated)
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue("https://y.qq.com/portal/player.html", forHTTPHeaderField: "Referer")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            guard let self = self else { return }
            var ranked: [(score: Int, mid: String)] = []
            if err == nil,
               let obj = try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any],
               let list = (((obj["data"] as? [String: Any])?["song"]) as? [String: Any])?["list"] as? [[String: Any]] {
                let primary = self.primaryArtist(originalArtist)
                for song in list {
                    guard let mid = song["songmid"] as? String, !mid.isEmpty else { continue }
                    let name = song["songname"] as? String ?? ""
                    let singers = (song["singer"] as? [[String: Any]])?
                        .compactMap { $0["name"] as? String }.joined(separator: "/") ?? ""
                    // 复用 lrclib 那套 matchScore，避免同名曲（翻唱/混音）串词
                    var score = self.matchScore(["trackName": name, "artistName": singers],
                                               expectTitle: originalTitle, expectArtist: originalArtist)
                    if score < 0 { continue }
                    if !primary.isEmpty,
                       !singers.localizedCaseInsensitiveContains(primary) {
                        score -= 30
                    }
                    ranked.append((score, mid))
                }
                ranked.sort { $0.score > $1.score }
            } else if let err = err {
                self.lyricLog("QQ 搜索网络错误 q=\(queries[index]) err=\(NetworkErrorText.describe(err))")
                // 证书类失败是机器级问题（代理在解密 HTTPS），整源冷却：
                // 否则每首歌都要重复撞一次同一个失败，白等两轮超时。
                if NetworkErrorText.isCertificateFailure(err) {
                    self.markHostUnreachable("c.y.qq.com")
                    self.fetchLyricsOvh(artist: originalArtist, title: originalTitle)
                    return
                }
            }
            let pool = (accumulated + ranked).sorted { $0.score > $1.score }
            if let top = pool.first, top.score >= 115 {
                self.neteaseLyricTryFastQQ(candidates: pool,
                                        originalTitle: originalTitle, originalArtist: originalArtist)
            } else {
                self.qqSearch(queries: queries, index: index + 1,
                             originalTitle: originalTitle, originalArtist: originalArtist,
                             accumulated: pool)
            }
        }.resume()
    }

    /// 并发预取前 N 个 QQ 候选的歌词：谁先返回可用 LRC 就用谁。
    private func neteaseLyricTryFastQQ(candidates: [(score: Int, mid: String)],
                                      originalTitle: String, originalArtist: String) {
        let batch = Array(candidates.prefix(qqPrefetchCount))
        guard batch.count > 1 else {
            qqLyricTry(candidates: candidates, index: 0,
                       originalTitle: originalTitle, originalArtist: originalArtist)
            return
        }
        let group = DispatchGroup()
        let lock = NSLock()
        var winnerMid: String?
        for c in batch {
            group.enter()
            qqLyricProbe(mid: c.mid) { hasLRC in
                defer { group.leave() }
                guard hasLRC else { return }
                lock.lock()
                if winnerMid == nil { winnerMid = c.mid }
                lock.unlock()
            }
        }
        group.notify(queue: scriptQueue) { [weak self] in
            guard let self else { return }
            lock.lock()
            let won = winnerMid
            lock.unlock()
            if let won {
                self.qqLyric(mid: won, originalTitle: originalTitle,
                            artist: originalArtist) { [weak self] ok in
                    guard let self, !ok, !self.hasLyricsFlag else { return }
                    self.qqLyricTry(candidates: candidates, index: self.qqPrefetchCount,
                                   originalTitle: originalTitle, originalArtist: originalArtist)
                }
                return
            }
            guard !self.hasLyricsFlag else { return }
            self.qqLyricTry(candidates: candidates, index: self.qqPrefetchCount,
                           originalTitle: originalTitle, originalArtist: originalArtist)
        }
    }

    /// 只探测不写回：问某个 mid 有没有可用 LRC。
    private func qqLyricProbe(mid: String,
                             completion: @escaping (_ hasLRC: Bool) -> Void) {
        let percent = QueryEncoding.encode(mid)
        guard let url = URL(string: "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?songmid=\(percent)&format=json&nobase64=1") else {
            completion(false)
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("https://y.qq.com/portal/player.html", forHTTPHeaderField: "Referer")
        URLSession.shared.dataTask(with: req) { data, _, err in
            if let err = err {
                if NetworkErrorText.isCertificateFailure(err) {
                    self.markHostUnreachable("c.y.qq.com")
                }
                completion(false)
                return
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any],
                  (obj["retcode"] as? Int) == 0,
                  let lyric = obj["lyric"] as? String, !lyric.isEmpty else {
                completion(false)
                return
            }
            completion(!self.parseLrcPairs(lyric).isEmpty)
        }.resume()
    }

    /// 串行逐个试候选（并发预取未命中时的回退路径）。
    private func qqLyricTry(candidates: [(score: Int, mid: String)], index: Int,
                           originalTitle: String, originalArtist: String) {
        guard index < min(candidates.count, 6) else {
            lyricLog("QQ 候选均无歌词，回退 lyrics.ovh artist=\(originalArtist) title=\(originalTitle)")
            self.fetchLyricsOvh(artist: originalArtist, title: originalTitle)
            return
        }
        let mid = candidates[index].mid
        qqLyric(mid: mid, originalTitle: originalTitle, artist: originalArtist) { [weak self] ok in
            guard let self = self else { return }
            guard !ok else { return }
            self.qqLyricTry(candidates: candidates, index: index + 1,
                           originalTitle: originalTitle, originalArtist: originalArtist)
        }
    }

    /// 取指定 mid 的 QQ 歌词并写回。
    private func qqLyric(mid: String, originalTitle: String, artist: String,
                        completion: @escaping (Bool) -> Void) {
        let percent = QueryEncoding.encode(mid)
        guard let url = URL(string: "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?songmid=\(percent)&format=json&nobase64=1") else {
            fetchLyricsOvh(artist: artist, title: originalTitle)
            completion(false)
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("https://y.qq.com/portal/player.html", forHTTPHeaderField: "Referer")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            guard let self = self else { completion(false); return }
            if let err = err {
                self.lyricLog("QQ 歌词网络错误 mid=\(mid) err=\(NetworkErrorText.describe(err))")
                if NetworkErrorText.isCertificateFailure(err) {
                    self.markHostUnreachable("c.y.qq.com")
                }
                completion(false)
                return
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any],
                  (obj["retcode"] as? Int) == 0,
                  let lyric = obj["lyric"] as? String, !lyric.isEmpty else {
                self.lyricLog("QQ 候选无 LRC mid=\(mid)")
                completion(false)
                return
            }
            let pairs = self.parseLrcPairs(lyric)
            guard !pairs.isEmpty else {
                self.lyricLog("QQ LRC 解析为空 mid=\(mid)")
                completion(false)
                return
            }
            let translations = self.parseLrcPairs(obj["trans"] as? String ?? "")
            // 译文与原文时间戳一致（同为 QQ 上传），允许 60ms 容差对齐
            let synced: [SyncedLine] = pairs.map { p in
                let tr = translations.first { abs($0.time - p.time) < 0.06 }?.text
                return SyncedLine(text: self.toSimplified(p.text), time: p.time,
                                  translation: tr.map { self.toSimplified($0) })
            }
            self.lyricLog("QQ 命中 LRC mid=\(mid) 行数=\(synced.count) 译文=\(translations.count) title=\(originalTitle)")
            let plain = synced.map { $0.text }.joined(separator: "\\n")
            self.setSyncedLyrics(synced: synced, plain: plain,
                                title: originalTitle, artist: artist)
            completion(true)
        }.resume()
    }


    /// 繁体中文 → 简体中文（CFStringTransform "Hant-Hans"）。
    /// 仅转换 CJK 字符，英文/拉丁/标点原样保留，可安全用于中英混合歌词与翻译文本。
    func toSimplified(_ s: String) -> String {
        let mutable = NSMutableString(string: s)
        CFStringTransform(mutable, nil, "Hant-Hans" as CFString, false)
        return mutable as String
    }

    /// 检测并拆分一行内「自带双语」的歌词文本。
    /// 支持的格式：
    ///   - `原文 / 翻译`、`原文 /翻译`
    ///   - `原文 (翻译)`、`原文（翻译）`
    ///   - `原文【翻译】`、`原文 [翻译]`
    ///   - `原文：翻译`、`原文: 翻译`
    /// 仅当两侧确实分属不同语言（中 vs 英/其他拉丁）时才拆分，避免把带括号的原文误拆。
    /// 双语分隔符的预编译正则（与 kind 一一对应）。
    ///
    /// 每行歌词都要跑这四个模式。原先在函数体内 `try? NSRegularExpression`
    /// 现场编译：一首 40 行的歌就是 160 次编译，而这发生在**写回主线程**的
    /// 路径上（用户切歌后歌词出现的延迟组成部分）。实测预编译后每行
    /// 从 0.0153ms 降到 0.0021ms（约 7 倍）。
    private static let bilingualSeparators: [(NSRegularExpression, String)] = {
        let raws: [(String, String)] = [
            (#"\s*/\s*"#, "/"),          // 斜杠分隔
            (#"[（(]\s*"#, "("),          // 半角/全角左括号
            (#"[【\[]\s*"#, "["),        // 全角/半角方括号
            (#"\s*[:：]\s*"#, ":")       // 冒号分隔
        ]
        return raws.compactMap { spec in
            guard let re = try? NSRegularExpression(pattern: spec.0) else { return nil }
            return (re, spec.1)
        }
    }()

    private func splitBilingualLine(_ line: String) -> (text: String, translation: String?) {
        for (re, sepKind) in Self.bilingualSeparators {
            let ns = NSRange(line.startIndex..., in: line)
            guard let m = re.firstMatch(in: line, range: ns) else { continue }
            let sepRange = m.range
            guard let r = Range(sepRange, in: line) else { continue }
            // 找到分隔符对应的右闭合符号（括号/方括号需配对到行尾或闭合符）
            if sepKind == "(" {
                if let close = line[r.upperBound...].range(of: "）")?.lowerBound ??
                    line[r.upperBound...].range(of: ")")?.lowerBound {
                    let translated = String(line[r.upperBound..<close]).trimmingCharacters(in: .whitespaces)
                    let original = String(line[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                    if let result = validateBilingual(original, translated) { return result }
                }
                continue
            } else if sepKind == "[" {
                if let close = line[r.upperBound...].range(of: "】")?.lowerBound ??
                    line[r.upperBound...].range(of: "]")?.lowerBound {
                    let translated = String(line[r.upperBound..<close]).trimmingCharacters(in: .whitespaces)
                    let original = String(line[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                    if let result = validateBilingual(original, translated) { return result }
                }
                continue
            } else {
                let translated = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                let original = String(line[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                if let result = validateBilingual(original, translated) { return result }
            }
        }
        return (line, nil)
    }

    /// 校验两侧是否确为不同语言（避免误拆）。
    ///
    /// 委托 BilingualSplit：那里挡住了一行内冒号被当双语分隔符的误拆
    ///（如「CD机：播这首歌」原文前半被当译文丢掉）。
    private func validateBilingual(_ original: String, _ translated: String) -> (text: String, translation: String)? {
        BilingualSplit.validate(original, translated)
    }

    /// 写入歌词：带时间轴优先写入 syncedLines 供逐行高亮；同时生成纯文本 lyrics 兜底展示。
    private func setSyncedLyrics(synced: [SyncedLine], plain: String,
                                 title: String, artist: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lyricsNote = ""
            // 写回前确认仍是同一首歌，避免串词。
            // 注意：不要要求 self.lyrics.isEmpty —— 否则播放中歌词异步返回时，
            // 若歌词字段已被占用（或正处于某次清空/重试间隙之外）就会被整条丢弃，
            // 只有切歌/暂停等让 lyrics 恰好为空的瞬间才写进去，表现为「暂停才显示」。
            guard self.title == title || title.isEmpty else {
                lyricLog("歌词写回丢弃（曲目已切换）target=\(title) current=\(self.title)")
                return
            }
            if !synced.isEmpty {
                // 当前行查找依赖「时间递增」，遇到乱序数组会在第一次
                // line.time > t 时提前 break，选错行。写入前统一排序，
                // 不依赖各来源/重试路径自行保证顺序。
                let ordered = synced.sorted { $0.time < $1.time }
                // 换的是**另一套时间轴**：防抖索引必须重置。
                // 否则旧索引在新数组里指向完全不同的行 —— 迟到命中的换源
                // （lrclib 失败后网易云补上）会让歌词突然跳到错误句子，
                // 而播放位置根本没变。上一首的行序号对新的歌词毫无意义。
                self.lastActiveLineIndex = nil
                // 新时间轴：作废旧批次的译文写回
                self.translationGeneration &+= 1
                self.syncedLines = ordered
                // 收缩态/无时间轴兜底展示：用 synced 的文本
                self.lyrics = ordered.map { $0.text }.joined(separator: "\n")
                // 双语：对带时间轴的歌词逐行补全翻译（自带双语已写入 translation，跳过）
                self.fetchTranslations(synced: ordered, title: title)
            } else {
                let simplifiedPlain = self.toSimplified(plain)
                self.lyrics = simplifiedPlain
                // 双语：无时间轴纯文本歌词，整段翻译补全
                self.fetchPlainTranslation(plain: simplifiedPlain, title: title)
            }
            // 带上播放位置与校准偏移：用户反馈「歌词和歌声不一致」时，日志必须能
            // 区分是「歌词没到」还是「到了但位置对不上」——否则只能靠猜。
            lyricLog(String(format: "歌词写回 synced=%d plainLen=%d pos=%.2f offset=%+.2f title=%@",
                           synced.count, plain.count, currentTime, lyricsOffset,
                           title as NSString))
            // 成功取到歌词：记入成功缓存，停止对该曲的后续重试
            let key = "\(title)-\(artist)"
            self.scriptQueue.async {
                self.hasLyricsFlag = true
                self.onlineSearchedKeys.insert(key)
                if self.lyricInFlightKey == key {
                    self.lyricInFlightKey = nil
                    self.lyricInFlightSince = nil
                }
            }
        }
    }

    /// 明确知道「这首歌没有歌词」（如网易云 `pureMusic` 纯音乐标记）时调用：
    /// 写入原因文案让 UI 说清是「纯音乐」而不是笼统的「暂无歌词」，同时记入成功缓存，
    /// 后续轮询不再重跑整条链路（否则纯音乐曲目每 1.5s 就重刷一遍四个源）。
    private func markNoLyrics(pureMusic: Bool, title: String, artist: String) {
        let note = pureMusic ? "纯音乐 · 无歌词" : ""
        let key = "\(title)-\(artist)"
        scriptQueue.async { [weak self] in
            guard let self = self else { return }
            self.onlineSearchedKeys.insert(key)
            // 必须同时把该曲目标为「已判定」：hasLyricsFlag 的语义是「当前曲目还要不要
            // 再跑取词链」。纯音乐只记 onlineSearchedKeys 时，fetchLyricsSync 的
            // (!contains || !hasLyricsFlag) 判据依然放行，每轮轮询都会把四个源重刷一遍
            // （实测一次取词打满 12 个请求）。网易云/QQ 被刷到限流后，
            // 后面的正常歌曲反而取不到词——这才是最难排查的那种「无法获取歌词」。
            self.hasLyricsFlag = true
            if self.lyricInFlightKey == key {
                self.lyricInFlightKey = nil
                self.lyricInFlightSince = nil
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if title.isEmpty || self.title == title { self.lyricsNote = note }
        }
    }

    /// 手动重新获取歌词：清掉该曲目的失败缓存与纯音乐结论，强制重跑整条取词链路。
    /// 在线源全部异步，首次失败常只是网络抖动，用户需要一条不用切歌的补救路径。
    func retryLyrics() {
        scriptQueue.async { [weak self] in
            guard let self = self else { return }
            let key = "\(self.queueTitle)-\(self.queueArtist)"
            self.onlineSearchedKeys.remove(key)
            self.onlineAttempts.removeValue(forKey: key)
            self.hasLyricsFlag = false
            // 手动重试必须清掉在途标记：否则上一条链还在跑时点重试会被在途去重
            // 静默拦截 45 秒，而 UI 歌词已被清空——用户看到的就是「无法获取歌词」。
            self.lyricInFlightKey = nil
            self.lyricInFlightSince = nil
            DispatchQueue.main.async { [weak self] in
                self?.lyricsNote = ""
                self?.lyrics = ""
                self?.lyricsTranslation = ""
                self?.syncedLines = []
            }
            self.lyricLog("手动重试取词 title=\(self.queueTitle) artist=\(self.queueArtist)")
            self.fetchLyricsSync(title: self.queueTitle, artist: self.queueArtist, force: true)
        }
    }

    /// 评估搜索结果与当前曲目的匹配度。
    /// 返回 -1 表示歌名不匹配（应排除）；分值越高越可信。
    /// 测试用的候选匹配入口：与 `matchScore` 同一判定，但以显式字段调用
    /// （避免 LumiTests 构造 NSDictionary 桥接）。返回 -1 表示歌名不匹配。
    static func testableMatchScore(trackName: String, artistName: String,
                                  albumName: String,
                                  expectTitle: String, expectArtist: String,
                                  expectAlbum: String, expectDuration: Double) -> Int {
        // 专辑 + 时长交给 ArtworkScoring（与封面/歌词链路同一套判定）
        let base = testableTitleArtistScore(trackName: trackName, artistName: artistName,
                                            expectTitle: expectTitle, expectArtist: expectArtist)
        guard base >= 0 else { return -1 }
        return base + ArtworkScoring.score(album: albumName, durSec: expectDuration,
                                          expAlbum: expectAlbum, expDur: expectDuration)
    }

    /// 测试用的歌名 + 歌手匹配（与 matchScore 的前两段同规则）。
    static func testableTitleArtistScore(trackName: String, artistName: String,
                                        expectTitle: String, expectArtist: String) -> Int {
        let rTitle = ArtworkScoring.norm(trackName)
        let rArtist = ArtworkScoring.norm(artistName)
        let eTitle = ArtworkScoring.norm(expectTitle)
        let eArtist = ArtworkScoring.norm(expectArtist)
        guard !rTitle.isEmpty, !eTitle.isEmpty else { return -1 }
        var score: Int
        if rTitle == eTitle {
            score = 100
        } else if rTitle.contains(eTitle) || eTitle.contains(rTitle) {
            score = 60
        } else {
            return -1
        }
        if !eArtist.isEmpty, !rArtist.isEmpty {
            if rArtist == eArtist {
                score += 50
            } else if rArtist.contains(eArtist) || eArtist.contains(rArtist) {
                score += 30
            }
        }
        return score
    }

    /// 移除曲名里的版本/括号后缀，提高在线匹配成功率。
    /// 同时把繁体转简体：lrclib 等公开源的中文歌词多为简体收录，
    /// 直接用繁体歌名（如「瀟洒小姐」）搜索常落空，转简体后才能命中。
    private func cleanTrackTitle(_ t: String) -> String {
        var s = toSimplified(t)
        // 英文括号 / 方括号后缀
        s = s.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
        // 中文括号后缀（全角）
        s = s.replacingOccurrences(of: #"（[^）]*）"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"【[^】]*】"#, with: "", options: .regularExpression)
        // 常见中文后缀（伴奏 / 国语 / 粤语 / Live / 现场 等版本标记）
        s = s.replacingOccurrences(of: #"(伴奏|伴唱|国语|粤语|普通话|Live|live|现场|原版|Remaster|remaster).*$"#,
                                   with: "", options: .regularExpression)
        if let r = s.range(of: " - ") { s.removeSubrange(r.lowerBound...) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// 提取主歌手：截断 feat./ft./与/&/, 等协作分隔符
    private func primaryArtist(_ a: String) -> String {
        var s = a
        let seps = [" feat.", " feat ", " ft.", " ft ", " & ", ", ", " x ", " X ", " 、"]
        for sep in seps {
            if let r = s.range(of: sep, options: .caseInsensitive) {
                s = String(s[s.startIndex..<r.lowerBound])
            }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private func matchScore(_ d: [String: Any], expectTitle: String, expectArtist: String) -> Int {
        let rTitle = norm((d["trackName"] as? String) ?? "")
        let rArtist = norm((d["artistName"] as? String) ?? "")
        let eTitle = norm(expectTitle)
        let eArtist = norm(expectArtist)
        guard !rTitle.isEmpty, !eTitle.isEmpty else { return -1 }

        // 歌名：必须相等或互相包含，否则判定为不同的歌
        var score: Int
        if rTitle == eTitle {
            score = 100
        } else if rTitle.contains(eTitle) || eTitle.contains(rTitle) {
            score = 60
        } else {
            return -1
        }

        // 歌手：匹配加分；对不上不直接否决（组合歌手/译名差异很常见）
        if !eArtist.isEmpty, !rArtist.isEmpty {
            if rArtist == eArtist {
                score += 50
            } else if rArtist.contains(eArtist) || eArtist.contains(rArtist) {
                score += 30
            }
        }
        // 有逐行时间戳的版本更优
        if let s = d["syncedLyrics"] as? String, !s.isEmpty { score += 5 }
        return score
    }

    /// 归一化：小写、去掉空白与标点，并统一繁简，便于宽松比较。
    /// 繁简统一是必须的：Apple 目录按店铺返回不同字形（tw/hk 给繁体「神預言」，
    /// Music 报简体「神预言」），不统一则歌名直接判不匹配。
    private func norm(_ s: String) -> String {
        ArtworkScoring.norm(s)
    }

    private func pickLyrics(_ d: [String: Any]) -> String {
        let synced = (d["syncedLyrics"] as? String) ?? ""
        let plain = (d["plainLyrics"] as? String) ?? ""
        // 优先纯文本歌词（更干净）；只有带时间戳版本时，先剥离 [mm:ss.xx] 前缀，
        // 否则界面会直接把时间戳当歌词文本显示出来。
        if !plain.isEmpty {
            return plain.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return stripTimestamps(synced)
    }

    /// 去掉 LRC 行首时间戳，并丢弃空行
    private func stripTimestamps(_ s: String) -> String {
        guard !s.isEmpty else { return "" }
        let lines = s.components(separatedBy: .newlines).map { line -> String in
            line.replacingOccurrences(of: #"^(\[\d{1,2}:\d{2}(\.\d{1,3})?\])+"#,
                                      with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        return lines.filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MusicController 的翻译 extension：翻译缓存（内存 + 落盘）、大模型/Google 双通道、
// 批量翻译与重试、双语歌词逐行补全。
extension MusicController {

    // MARK: - 翻译缓存（内存 + 磁盘持久化）
    /// 翻译缓存持久化文件路径：~/Library/Application Support/Lumi/translation_cache.json
    private var translationCacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lumi")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("translation_cache.json")
    }
    /// 启动时从磁盘加载已翻译歌词缓存，避免重复翻译（命中即跳过网络请求）。
    func loadTranslationCache() {
        translationQueue.async { [weak self] in
            guard let self = self else { return }
            guard let data = try? Data(contentsOf: self.translationCacheURL),
                  let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return }
            self.translationCache = dict
            // 同步 UI 侧快照：否则首次启动后 UI 读到空缓存，
            // 要等下一次 cacheTranslation 才补上，表现为「译文慢一拍才出现」。
            self.refreshTranslationCacheSnapshot()
        }
    }
    /// 翻译缓存批量落盘（防抖）。
    ///
    /// 整首歌可能连续写入几十行译文；若每行都把整个缓存 JSON 重写一遍（atomic 写 = 全量重写），
    /// 会产生大量重复磁盘 I/O。这里合并为「停止写入 1s 后写一次」。
    /// 注意必须在 translationQueue 上调度执行，保证与 translationCache 的读写同队列、无竞争。
    func scheduleCachePersist() {
        cachePersistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let url = self.translationCacheURL
            let snapshot = self.translationCache
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
        cachePersistWork = work
        translationQueue.asyncAfter(deadline: .now() + 1.0, execute: work)
    }
    /// 写入一条译文到内存缓存并防抖持久化到磁盘（统一入口，覆盖所有翻译来源）。
    private func cacheTranslation(_ src: String, _ tr: String) {
        translationQueue.async { [weak self] in
            guard let self = self else { return }
            self.translationCache[src] = tr
            // 先增量预置这一条（立即可见），再异步整表刷新（覆盖其余改动）
            self.primeTranslationSnapshot(src: src, tr: tr)
            self.refreshTranslationCacheSnapshot()
            self.scheduleCachePersist()
        }
    }

    /// 重建 UI 侧缓存快照。只能在 translationQueue 上调用：
    /// 跳到主线程覆盖，主线程读快照不再与翻译队列争锁。
    ///
    /// 必须异步跳主线程：本方法在 translationQueue 上调用，若同步等主线程
    /// 执行完赋值，翻译队列就会被 UI 布局阻塞（反过来更糟）。
    ///
    /// 异步派发的代价是快照最多慢一帧；为此 `cacheTranslation` 会额外做一次
    /// 增量预置（见下），让刚译出的那行立刻可见，不必等整表拷贝。
    private func refreshTranslationCacheSnapshot() {
        let copy = translationCache
        DispatchQueue.main.async { [weak self] in
            self?.translationCacheSnapshot = copy
        }
    }

    /// 增量预置：把刚译出的单条译文立刻写进 UI 快照。
    ///
    /// 整表拷贝是异步派发，主线程繁忙时最慢一帧；这一条是同步的
    /// （调用点本就负责把结果送交 UI）。没有它，「歌词出来了但译文
    /// 要等下一刻才出现」——用户感知就是歌词和译文不同步。
    private func primeTranslationSnapshot(src: String, tr: String) {
        DispatchQueue.main.async { [weak self] in
            self?.translationCacheSnapshot[src] = tr
        }
    }

    // MARK: - 双语歌词翻译补全
    /// 对带时间轴的歌词逐行补全翻译（仅针对没有自带 translation 的行）。
    /// 自带双语已在 parseSyncedLyrics 拆分，无需联网；联网用 MyMemory 免费 API（无需 key）。
    /// 译文按行缓存，避免重复请求。整段翻译结果在回调中重建 syncedLines 写回主线程。
    func fetchTranslations(synced: [SyncedLine], title: String) {
        guard bilingualMode != .off else { return }
        // 记下本轮代次：回调时若已过期（用户切了模式/换了歌），整批放弃。
        // 串行队列保证批次之间不会真并发，但「旧批次还没跑完就又开一轮」
        // 是可能的（切模式 → 立即重新翻译），靠代次把旧的那轮踢掉。
        let generation = translationGeneration
        // 待译文本：translation 为 nil 或空字符串都算未翻译
        //（避免"假完成"——空译文被当成已完成而永不重译）
        let pending = synced.filter {
            ($0.translation ?? "").isEmpty && !$0.text.isEmpty
        }
        guard !pending.isEmpty else { return }
        // 限流保护：未认证 MyMemory 约 5000 词/日，整首一次性灌入容易
        // 触发「翻译到一半断掉」。因此按「窗口」推进，而不是一刀截断 ——
        // 演唱会版 / 音乐剧 / HIP-HOP 常有 150~200 行，硬截断会让后半段
        // **永远**没有译文，双语面板出现「前半有译、后半空白」；
        // 而用户逐句跟唱，越到后半段偏差越明显，正是歌词与歌声对不上。
        // 窗口之间留间隔：既避免限流，也让上半段先可用（不必等整首）。
        processTranslationWindow(pending.map(\.text),
                                 at: 0,
                                 title: title,
                                 generation: translationGeneration)
    }

    /// 每个窗口的待译文本行数。
    private static let translationWindowSize = 120

    /// 逐窗口处理翻译：一个窗口内的批次跑完，间隔一段时间再跑下一个。
    /// 代次过期（切歌 / 切双语模式 / 换时间轴）时整轮放弃。
    private func processTranslationWindow(_ texts: [String],
                                          at index: Int,
                                          title: String,
                                          generation: UInt64) {
        guard generation == translationGeneration else { return }
        let start = index * Self.translationWindowSize
        guard start < texts.count else { return }
        let window = Array(texts[start..<min(start + Self.translationWindowSize, texts.count)])
        // 每批 8 行拼接成一段一次请求，显著减少网络往返（RTT），加快整首补全速度。
        let batchSize = 8
        let batches = stride(from: 0, to: window.count, by: batchSize).map {
            Array(window[$0..<min($0 + batchSize, window.count)])
        }
        // 串行处理各批次：避免一次性并发所有请求触发 Google/LLM 限流（表现为"翻译到一半断掉"）。
        // 每批之间间隔 0.4s，且每批失败重试 1 次；失败的行不写空占位，保留"翻译中"状态，
        // 下一轮轮询可再次补译，避免永久断掉。
        func processBatch(at index: Int) {
            guard index < batches.count else {
                self.rebuildSyncedWithTranslations(title: title)
                // 本窗口译完：间隔一段时间再推进到下一个窗口。
                // 间隔是限流保护——连续灌入容易触发「翻译到一半断掉」。
                self.translationSchedulerQueue.asyncAfter(deadline: .now() + 2.0) {
                    self.processTranslationWindow(texts, at: index + 1,
                                                 title: title, generation: generation)
                }
                return
            }
            let batch = batches[index]
            let pending = batch.filter { line in
                var cached: String?
                self.translationQueue.sync { cached = self.translationCache[line] }
                return cached == nil
            }
            guard !pending.isEmpty else {
                // 整批已命中缓存，直接下一批
                self.translationSchedulerQueue.asyncAfter(deadline: .now() + 0.1) { processBatch(at: index + 1) }
                return
            }
            let srcs = pending
            var attempts = 0
            /// 代次已校验且已在主线程：落译文并推进下一批。
            func applyResult(_ translated: [String]?, _ currentAttempts: Int) {
                if let translated = translated, translated.count == srcs.count {
                    for (k, src) in srcs.enumerated() {
                        let tr = translated[k]
                        guard !tr.isEmpty else { continue }
                        self.cacheTranslation(src, tr)
                    }
                    self.translationSchedulerQueue.asyncAfter(deadline: .now() + 0.3) {
                        processBatch(at: index + 1)
                    }
                } else if currentAttempts < 2 {
                    // 整批失败：重试一次（限流往往是突发并发导致，稍后重试大多成功）
                    self.translationSchedulerQueue.asyncAfter(deadline: .now() + 0.8) {
                        attempt()
                    }
                } else {
                    // 重试仍失败：逐行兜底翻译（每条计入批次完成信号）
                    let subgroup = DispatchGroup()
                    for src in srcs {
                        var cached: String?
                        self.translationQueue.sync { cached = self.translationCache[src] }
                        guard cached == nil else { continue }
                        subgroup.enter()
                        self.translateWithRetry(text: src, attempt: 1) { tr in
                            defer { subgroup.leave() }
                            if let tr = tr, !tr.isEmpty { self.cacheTranslation(src, tr) }
                            // 失败不写空占位，保留翻译中状态，下一轮可补译
                        }
                    }
                    // 汇合也放翻译调度队列：不再借用 scriptQueue，
                    // 避免与播放进度采样队列产生无谓耦合。
                    subgroup.notify(queue: self.translationSchedulerQueue) {
                        // 本批兜底完成，进入下一批
                        self.translationSchedulerQueue.asyncAfter(deadline: .now() + 0.3) {
                            processBatch(at: index + 1)
                        }
                    }
                }
            }
            func attempt() {
                attempts += 1
                self.translateBatchWithRetry(lines: srcs, attempt: attempts) { translated in
                    // 代次过期：本轮批次的译文已不属于当前播放上下文，丢弃。
                    // 代次是主线程状态，而网络回调可能在后台线程，必须回主线程比。
                    // 过期批次若继续写译文，会与新一轮的译文交错，出现原文/译文错配。
                    DispatchQueue.main.async {
                        guard generation == self.translationGeneration else { return }
                        applyResult(translated, attempts)
                    }
                }
            }
            attempt()
        }
        translationSchedulerQueue.async { processBatch(at: 0) }
    }

    /// 根据翻译缓存重建 syncedLines（为每行缺失 translation 的行补全译文）。
    /// 仅当仍是同一首歌时写回，避免串词。
    private func rebuildSyncedWithTranslations(title: String) {
        // 同步从 translationQueue 取快照到局部变量，再回到主线程重建。
        // 必须 sync 取快照（而非在 translationQueue.async 闭包里捕获 snapshot 再
        // 跨到 DispatchQueue.main.async）：之前的 async 写法会让 snapshot 在后台队列
        // 与主线程闭包之间被多次并发捕获，配合 translationCache 的并发写入触发
        // 字典桥接损坏（unrecognized selector objectForKey: sent to NSNumber），导致崩溃。
        var snapshot: [String: String] = [:]
        translationQueue.sync { snapshot = self.translationCache }
        // 记下本轮代次：切歌/切双语模式/换时间轴都会 +1，
        // 晚到的重建若发现已过期就整批放弃，避免把旧一代的译文
        // 写进新一代的歌词行（原文相同但时间轴不同，译文会错行）。
        let generation = self.translationGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard self.title == title || title.isEmpty else { return }
            guard generation == self.translationGeneration else { return }
            let synced = self.syncedLines
            var rebuilt = synced
            var filled = 0
            for i in synced.indices {
                let line = synced[i]
                if line.translation != nil { continue }
                // 显式以 String? 取值，避免任何桥接把值当字典
                if let tr = snapshot[line.text] as String?, !tr.isEmpty {
                    rebuilt[i] = SyncedLine(text: line.text, time: line.time, translation: tr)
                    filled += 1
                }
            }
            // 仅在有变化时写回，减少无谓的 @Published 刷新
            if rebuilt != self.syncedLines { self.syncedLines = rebuilt }
        }
    }

    /// 无时间轴纯文本歌词：整段翻译补全（双语模式时展示原文 + 译文）。
    func fetchPlainTranslation(plain: String, title: String) {
        guard bilingualMode != .off, !plain.isEmpty else { return }
        scriptQueue.async { [weak self] in
            guard let self = self else { return }
            var cached: String?
            self.translationQueue.sync { cached = self.translationCache[plain] }
            if let cached = cached, !cached.isEmpty {
                DispatchQueue.main.async { if self.title == title { self.lyricsTranslation = cached } }
                return
            }
            self.translate(text: plain) { [weak self] tr in
                guard let self = self else { return }
                if let tr = tr, !tr.isEmpty {
                    self.cacheTranslation(plain, tr)
                    DispatchQueue.main.async {
                        if self.title == title || title.isEmpty { self.lyricsTranslation = tr }
                    }
                } else {
                    // 翻译失败：写空占位，避免 UI 永久卡在"翻译中"
                    self.cacheTranslation(plain, "")
                }
            }
        }
    }

    /// 切换双语模式后，对当前已载入歌词重新应用（触发翻译或仅依赖 UI 隐藏）。
    func reapplyBilingualForCurrentTrack() {
        guard bilingualMode != .off else { return }
        if !syncedLines.isEmpty {
            fetchTranslations(synced: syncedLines, title: title)
        } else if !lyrics.isEmpty {
            fetchPlainTranslation(plain: lyrics, title: title)
        }
    }

    // MARK: - 翻译后端配置（大模型，OpenAI 兼容 Chat Completions）
    /// key / baseURL / model 均从环境变量读取，不写死在代码里、不进 git。
    /// 实际用哪一组由「选中的翻译模型」的 vendor 决定：
    /// - `.dashscope`：`LUMI_DASHSCOPE_API_KEY`
    /// - `.openrouter`：`LUMI_TRANSLATE_API_KEY` / `LUMI_TRANSLATE_BASE_URL`
    /// - `.stepfun`：`LUMI_STEPFUN_BASE_URL`（留空=本机中继，无需 key）
    ///               / `LUMI_STEPFUN_API_KEY`（仅官方 API 需要）
    /// 统一从 ~/Library/Application Support/Lumi/translate.env 解析翻译配置。
    /// 该文件是用户维护的权威配置源（不进 git）。为避免历史 `launchctl setenv` 写入的旧
    /// OpenRouter key（已 401 失效）残留在进程环境中、悄悄覆盖正确配置，这里**只认文件，
    /// 不再 fallback 进程环境变量**（仅在文件本身不存在/无该 key 时才退回默认值）。
    private var translateEnv: [String: String] {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Lumi/translate.env")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var dict: [String: String] = [:]
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq])
            let val = String(trimmed[trimmed.index(after: eq)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !val.isEmpty { dict[key] = val }
        }
        return dict
    }

    /// 仅从 translate.env 文件读取值（不再回退进程环境变量，杜绝旧 key 污染）。
    /// 文件缺 key 时返回 nil，由调用方决定是否用代码内置默认 baseURL/model。
    func envValue(_ name: String) -> String? {
        translateEnv[name]
    }

    // 翻译端点/key 现由「选中的模型」驱动（见 MusicController.swift 中 activeTranslate* 计算属性），
    // 不再使用 LUMI_FORCE_LLM 环境变量开关。

    /// 翻译主入口。
    /// 通道由「当前选中的翻译模型」决定：选中大模型类模型 -> 优先走大模型；
    /// 大模型失败则回退 Google 公开接口。最终失败返回 nil（UI 显示原文），不长时间挂起。
    private func translate(text: String, completion: @escaping (String?) -> Void) {
        if canUseLLMTranslate {
            self.translateViaLLM(text: text) { result in
                if let result { completion(result) }
                else { self.translateViaGoogle(text: text, completion: completion) }
            }
        } else {
            translateViaGoogle(text: text) { result in
                if let result { completion(result) }
                else if self.canUseLLMTranslate {
                    self.translateViaLLM(text: text) { completion($0) }
                } else { completion(nil) }
            }
        }
    }

    /// 调用大模型（OpenAI 兼容 Chat Completions）补全翻译。
    /// 端点与 key 由选中的模型决定（dashscope 走兼容模式，openrouter 沿用原配置）。
    /// 目标语言：原文含中文 -> 译为英文；否则 -> 译为中文。失败时返回 nil，由调用方兜底。
    private func translateViaLLM(text: String, completion: @escaping (String?) -> Void) {
        guard canUseLLMTranslate else { completion(nil); return }
        let hasCJK = text.contains { 0x4E00...0x9FFF ~= $0.unicodeScalars.first?.value ?? 0 }
        let targetLang = hasCJK ? "English" : "Chinese"
        let sysPrompt = "You are a lyrics translator. Translate the given line into \(targetLang) only. Keep it concise, preserve tone, do NOT add explanations or quotes. Output only the translation."
        let urlStr = "\(activeTranslateBaseURL)/chat/completions"
        guard let url = URL(string: urlStr) else { completion(nil); return }

        let body: [String: Any] = [
            "model": activeTranslateModel,
            "messages": [
                ["role": "system", "content": sysPrompt],
                ["role": "user", "content": text]
            ],
            "temperature": 0.3,
            "max_tokens": selectedTranslateOption.maxTokens
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = selectedTranslateOption.timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 本机中继无需鉴权；仅在真有 key 时才带 Authorization，避免把空 Bearer 发出去
        if let key = activeTranslateAPIKey, !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                completion(nil); return
            }
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any],
                  let tr = msg["content"] as? String else {
                completion(nil); return
            }
            let cleaned = tr.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'‘’“”"))
            guard !cleaned.isEmpty else { completion(nil); return }
            completion(cleaned)
        }.resume()
    }

    // MARK: - 带重试的翻译封装

    /// 单句翻译，最多重试 2 次（限流时重试通常成功）。失败不写空占位。
    private func translateWithRetry(text: String, attempt: Int, completion: @escaping (String?) -> Void) {
        let maxAttempts = 2
        translate(text: text) { [weak self] result in
            guard let self = self else { return }
            if let result = result, !result.isEmpty {
                completion(result)
            } else if attempt < maxAttempts {
                self.scriptQueue.asyncAfter(deadline: .now() + 0.6) {
                    self.translateWithRetry(text: text, attempt: attempt + 1, completion: completion)
                }
            } else {
                completion(nil)
            }
        }
    }

    /// 批量翻译，最多重试 2 次。
    private func translateBatchWithRetry(lines: [String], attempt: Int, completion: @escaping ([String]?) -> Void) {
        let maxAttempts = 2
        translateBatch(lines: lines) { [weak self] result in
            guard let self = self else { return }
            if let result = result, result.count == lines.count {
                completion(result)
            } else if attempt < maxAttempts {
                self.scriptQueue.asyncAfter(deadline: .now() + 0.6) {
                    self.translateBatchWithRetry(lines: lines, attempt: attempt + 1, completion: completion)
                }
            } else {
                completion(nil)
            }
        }
    }

    /// 批量翻译：把多行歌词拼成一个段落一次请求，大幅减少网络往返（RTT），
    /// 从而显著加快整首歌双语译文的补全速度。
    /// 返回按原顺序拆分的译文数组（与输入行数一致）；失败或行数不符时返回 nil，由调用方逐行兜底。
    private func translateBatch(lines: [String], completion: @escaping ([String]?) -> Void) {
        let joined = lines.joined(separator: "\n")
        guard !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion(nil); return
        }
        // 大模型优先通道（按选中的模型驱动）；否则默认 Google 公开接口
        if canUseLLMTranslate {
            translateBatchViaLLM(lines: lines, joined: joined, completion: completion)
            return
        }
        translateViaGoogle(text: joined) { tr in
            if let tr, self.splitBatch(tr, expected: lines.count) != nil {
                completion(self.splitBatch(tr, expected: lines.count))
            } else if self.canUseLLMTranslate {
                self.translateBatchViaLLM(lines: lines, joined: joined, completion: completion)
            } else { completion(nil) }
        }
    }

    /// 批量翻译走大模型（LLM 优先通道）。失败时回退 Google 公开接口，最终失败返回 nil。
    private func translateBatchViaLLM(lines: [String], joined: String,
                                      completion: @escaping ([String]?) -> Void) {
        guard canUseLLMTranslate else {
            translateViaGoogle(text: joined) { completion(self.splitBatch($0, expected: lines.count)) }
            return
        }
        let hasCJK = joined.contains { 0x4E00...0x9FFF ~= $0.unicodeScalars.first?.value ?? 0 }
        let targetLang = hasCJK ? "English" : "Chinese"
        let sysPrompt = "You are a lyrics translator. Translate each line of the given text into \(targetLang), keeping the SAME number of lines as the input, and use a single newline to separate lines. Keep it concise, preserve tone. Do NOT add explanations, numbering, or quotes. Output only the translated lines."
        let urlStr = "\(activeTranslateBaseURL)/chat/completions"
        guard let url = URL(string: urlStr) else {
            translateViaGoogle(text: joined) { completion(self.splitBatch($0, expected: lines.count)) }
            return
        }
        let body: [String: Any] = [
            "model": activeTranslateModel,
            "messages": [
                ["role": "system", "content": sysPrompt],
                ["role": "user", "content": joined]
            ],
            "temperature": 0.3,
            "max_tokens": selectedTranslateOption.maxTokens
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = selectedTranslateOption.timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = activeTranslateAPIKey, !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                self.translateViaGoogle(text: joined) { completion(self.splitBatch($0, expected: lines.count)) }
                return
            }
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any],
                  let tr = msg["content"] as? String,
                  !tr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.translateViaGoogle(text: joined) { completion(self.splitBatch($0, expected: lines.count)) }
                return
            }
            let split = self.splitBatch(tr, expected: lines.count)
            if let split { completion(split) }
            else { self.translateViaGoogle(text: joined) { completion(self.splitBatch($0, expected: lines.count)) } }
        }.resume()
    }

    /// 把批量译文按换行拆回逐行；空行保留以对应原行位置；行数不符或为空返回 nil。
    /// 把批量翻译结果按行拆回，与请求的 `expected` 行一一对应。
    ///
    /// 旧实现严格要求返回行数相等，否则**整批丢弃**（`return nil`）。实测翻译
    /// API 的返回有几种常见偏差：尾部多一个换行、把两个短行合并、在某一行内
    /// 插入换行——任一种都让整批 8 行译文全部丢失，双语歌词出现成片空缺。
    ///
    /// 现在改为容错对齐：
    /// - 先规范化（CRLF→LF、丢弃首尾空行）；
    /// - 行数正好 → 直接用；
    /// - 行数过多 → 按比例就近合并多出的行；
    /// - 行数过少 → 用空串补齐（该行无译文但不阻塞其余行）。
    /// 宁可某一行译文略不准，也不能让整批消失。
    private func splitBatch(_ text: String?, expected: Int) -> [String]? {
        Self.splitBatchForTest(text, expected: expected)
    }

    /// 测试用的 splitBatch 入口（与生产实现同一个静态函数，避免两处漂移）。
    static func testableSplitBatch(_ text: String?, expected: Int) -> [String]? {
        Self.splitBatchForTest(text, expected: expected)
    }

    /// splitBatch 的实现体（生产与测试共用）。
    static func splitBatchForTest(_ text: String?, expected: Int) -> [String]? {
        guard expected > 0, let text = text else { return nil }
        // 统一换行符：CRLF 与 CR 都要归一成 LF，否则 components 数不准
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var lines = normalized.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        // 丢掉首尾空行：翻译 API 常在结尾多送一个换行
        while lines.first == "" { lines.removeFirst() }
        while lines.last == "" { lines.removeLast() }
        guard !lines.isEmpty else { return nil }

        if lines.count == expected { return lines }

        if lines.count > expected {
            // 行数偏多（某行被拆开 / 短行被合并）：按比例把相邻行并回去
            var merged: [String] = []
            var cursor = 0
            for i in 0..<expected {
                let remaining = expected - i
                let take = max(1, (lines.count - cursor + remaining - 1) / remaining)
                let slice = lines[cursor..<min(cursor + take, lines.count)]
                merged.append(slice.joined(separator: " "))
                cursor += take
                if cursor >= lines.count {
                    while merged.count < expected { merged.append("") }
                    break
                }
            }
            while merged.count < expected { merged.append("") }
            return merged
        }

        // 行数偏少（某行译文缺失 / 被合并）：补空串，不让整批作废
        while lines.count < expected { lines.append("") }
        return lines
    }

    /// 免费翻译回退源：Google 翻译公开网页接口（translate.googleapis.com/translate_a/single）。
    /// 无需 key、无每日硬限额（仅频率限制，个人使用足够），替代原 MyMemory（有每日限额易耗尽）。
    private func translateViaGoogle(text: String, completion: @escaping (String?) -> Void) {
        // 同样走严格编码：歌词译文里的 + &= 会让查询变形（与歌词搜索同一套理由）
        let q = QueryEncoding.encode(text)
        guard !q.isEmpty else { completion(nil); return }
        let hasCJK = text.contains { 0x4E00...0x9FFF ~= $0.unicodeScalars.first?.value ?? 0 }
        let target = hasCJK ? "en" : "zh"
        let urlStr = "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=\(target)&dt=t&q=\(q)"
        guard let url = URL(string: urlStr) else { completion(nil); return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        URLSession.shared.dataTask(with: req) { data, resp, err in
            guard let data = data,
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  let seg0 = arr.first as? [Any], !seg0.isEmpty else {
                completion(nil)
                return
            }
            // 译文分布在 seg0 每个子数组的第 0 个元素，拼接得到完整翻译
            var out = ""
            for piece in seg0 {
                if let p = piece as? [Any], let t = p.first as? String { out += t }
            }
            let cleaned = out.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { completion(nil); return }
            completion(cleaned)
        }.resume()
    }
}
