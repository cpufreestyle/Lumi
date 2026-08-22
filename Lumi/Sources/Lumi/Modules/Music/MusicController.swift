import SwiftUI
import AppKit

// MARK: - 音乐模块控制器（macOS 通过 AppleScript 控制 Apple Music）
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
    @Published var duration: TimeInterval = 0
    @Published var artwork: NSImage? = nil
    @Published var lyrics: String = ""
    /// 无时间轴纯文本歌词的整段翻译（双语模式时由联网翻译补全）。
    @Published var lyricsTranslation: String = ""
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
            // 切换模式后，对当前已载入的歌词立即应用（重新翻译/回退）
            reapplyBilingualForCurrentTrack()
        }
    }
    private let bilingualKey = "music_bilingual_mode"

    /// 歌词时间轴校准偏移（秒）。lrclib/社区 LRC 的时间轴常以 Apple Music 基准标注，
    /// 但实际播放位置可能整体早/晚数秒（前奏 offset 差异），导致逐行高亮错位。
    /// 正值表示歌词时间轴比实际播放「快」了这么多，需要把匹配基准往后推。
    @Published var lyricsOffset: TimeInterval = 0 {
        didSet {
            UserDefaults.standard.set(lyricsOffset, forKey: lyricsOffsetKey)
            // 按曲目记忆校准：用户拖动滑块/点击对齐后，记下当前曲的偏移，
            // 下次再播放同一首自动套用，避免每次都重新调（解决「时间轴不对」反复出现）。
            let key = currentTrackKey
            guard !key.isEmpty else { return }
            scriptQueue.async { [weak self] in
                guard let self = self else { return }
                self.offsetByTrack[key] = self.lyricsOffset
                UserDefaults.standard.set(self.offsetByTrack, forKey: self.offsetByTrackKey)
            }
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
        let t = currentTime - lyricsOffset
        var cur: SyncedLine?
        for line in syncedLines where line.time >= 0 {
            if line.time <= t { cur = line }
            else { break }
        }
        if let line = cur { return line.text }
        // 无时间轴（纯文本歌词）：整段兜底
        if !lyrics.isEmpty { return lyrics }
        return ""
    }

    /// 当前正在唱的那一句（用于展开态两排双语显示）。无翻译时 translation 为 nil。
    var currentLine: SyncedLine? {
        let t = currentTime - lyricsOffset
        var cur: SyncedLine?
        for line in syncedLines where line.time >= 0 {
            if line.time <= t { cur = line }
            else { break }
        }
        return cur
    }

    /// 当前行的翻译文本（双语模式且已解析出翻译时）；其它情况回退整段译文 / 缓存直查。
    var currentTranslationText: String {
        if bilingualMode != .off {
            if let line = currentLine, let tr = line.translation, !tr.isEmpty {
                return tr
            }
            if !lyricsTranslation.isEmpty { return lyricsTranslation }
            // 兜底：当前显示文字（同步行或歌名）若已在翻译缓存中，直接取用，
            // 避免 rebuild 未回填或纯文本歌词路径未触发时译文始终为空 → 胶囊单色。
            let key = currentLineText.isEmpty ? title : currentLineText
            if !key.isEmpty {
                var cached: String?
                translationQueue.sync { cached = translationCache[key] }
                if let cached = cached, !cached.isEmpty { return cached }
            }
        }
        return ""
    }

    enum PlaybackState { case playing, paused, stopped }

    private var timer: Timer?
    private var lastTrackKey: String = ""
    /// 已「成功」取到歌词的曲目集合，避免重复请求（仅在 scriptQueue 上访问）。
    /// 注意：失败不写入此集合，以便后续周期重试。
    var onlineSearchedKeys = Set<String>()
    /// 在线搜索已尝试次数（失败重试用，上限后停止以省流量）。仅在 scriptQueue 上访问。
    var onlineAttempts: [String: Int] = [:]
    /// 当前曲目是否已取到歌词（仅在 scriptQueue 上访问，避免跨线程 sync 读 @Published）
    var hasLyricsFlag = false
    /// 当前曲目是否已取到封面（仅在 scriptQueue 上访问）。用于封面延迟加载的周期性重试。
    var hasArtFlag = false
    /// 当前曲目的名称/艺术家（仅在 scriptQueue 上访问）
    var queueTitle = ""
    var queueArtist = ""
    /// 歌词翻译缓存：原文 -> 翻译。避免同一句歌词反复请求翻译 API（省流量 + 防限流）。
    /// 所有读写都收敛到 translationQueue（串行），防止与重建 syncedLines 的主线程访问产生数据竞争。
    var translationCache: [String: String] = [:]
    /// 翻译缓存专用串行队列：统一保护 translationCache 的读写，避免跨线程字典崩溃。
    let translationQueue = DispatchQueue(label: "com.lumi.music.translation")
    /// AppleScript 为同步阻塞调用（约 100–300ms），必须在后台串行队列执行，
    /// 否则 1.5 秒轮询会周期性卡住主线程。
    let scriptQueue = DispatchQueue(label: "com.lumi.music.script", qos: .utility)
    /// 专辑封面获取专用队列（高优先级）。封面原始数据较大，且不应与歌词 AppleScript /
    /// 翻译网络请求争用同一队列，否则会拖慢封面出现、产生明显延迟。
    /// 注意：本队列只做「取数据 + 解码缩放」的纯计算工作；任何共享标志位（hasArtFlag 等）
    /// 的写回一律派回 scriptQueue，避免跨队列无锁读写导致偶发崩溃。
    let artworkQueue = DispatchQueue(label: "com.lumi.music.artwork", qos: .userInitiated)
    /// 切歌后封面快速重试用的计数器（仅在 scriptQueue 上访问）。
    var artworkRetryCount = 0

    // MARK: - 翻译模型选择
    /// 翻译模型供应商：决定请求端点与 key 来源。
    enum TranslateVendor {
        case google      // Google 公开接口（无需 key）
        case openrouter  // OpenAI 兼容，OpenRouter（LUMI_TRANSLATE_API_KEY）
        case dashscope   // 通义千问兼容模式（LUMI_DASHSCOPE_API_KEY）
    }

    /// 可选翻译模型。
    struct TranslateModelOption: Identifiable, Equatable {
        let id: String          // 模型名
        let label: String       // 显示名
        let vendor: TranslateVendor
        let usesLLM: Bool       // false=Google 公开接口
    }

    /// 候选翻译模型列表；通义千问实时翻译模型排在最前（优先）。
    static let availableTranslateModels: [TranslateModelOption] = [
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

    /// 当前通道实际使用的端点：dashscope 走兼容模式，openrouter 沿用原配置。
    var activeTranslateBaseURL: String {
        switch selectedTranslateOption.vendor {
        case .dashscope:  return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .openrouter: return envValue("LUMI_TRANSLATE_BASE_URL") ?? "https://openrouter.ai/api/v1"
        case .google:     return ""
        }
    }

    /// 当前通道实际使用的 key：dashscope 读 LUMI_DASHSCOPE_API_KEY，openrouter 读 LUMI_TRANSLATE_API_KEY。
    var activeTranslateAPIKey: String? {
        switch selectedTranslateOption.vendor {
        case .dashscope:  return envValue("LUMI_DASHSCOPE_API_KEY")
        case .openrouter: return envValue("LUMI_TRANSLATE_API_KEY")
        case .google:     return nil
        }
    }

    private init() {
        showLyrics = UserDefaults.standard.object(forKey: showLyricsKey) as? Bool ?? true
        lyricsOffset = UserDefaults.standard.object(forKey: lyricsOffsetKey) as? TimeInterval ?? 0
        offsetByTrack = UserDefaults.standard.dictionary(forKey: offsetByTrackKey) as? [String: TimeInterval] ?? [:]
        let savedBilingual = UserDefaults.standard.object(forKey: bilingualKey) as? Int ?? BilingualMode.auto.rawValue
        bilingualMode = BilingualMode(rawValue: savedBilingual) ?? .auto
        startTimer()
        loadVolumeIfNeeded()
        loadTranslationCache()
        selectedTranslateModelID = UserDefaults.standard.string(forKey: translateModelKey)
            ?? Self.availableTranslateModels[0].id
        refreshVolume()
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.fetchInfo()
        }
        fetchInfo()
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
                    set tName to (name of current track) as text
                    set tArtist to (artist of current track) as text
                    set tAlbum to (album of current track) as text
                    set tDur to (duration of current track) as text
                    set tPos to (player position) as text
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

        guard let desc = runScript(src),
              let raw = desc.stringValue else {
            lyricLog("fetchInfo: AppleScript 无返回（Music 未运行或未授权自动化）")
            return
        }

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
        if trackChanged { lastTrackKey = artKey }
        queueTitle = newTitle
        queueArtist = newArtist

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.title = newTitle
            self.artist = newArtist
            self.album = newAlbum
            self.duration = newDuration
            self.currentTime = newPosition
            switch stateStr {
            case "playing": self.playbackState = .playing
            case "paused":  self.playbackState = .paused
            default:        self.playbackState = .stopped
            }
            // 切歌先清空歌词，避免短暂显示上一首的歌词。
            // 这些 @Published 属性改动必须回到主线程，否则 SwiftUI 在后台线程刷新可能崩溃（Data race）。
            if trackChanged {
                let clearArt = !hasArt
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.lyrics = ""
                    self.lyricsTranslation = ""
                    self.syncedLines = []
                    if clearArt { self.artwork = nil }
                    // 载入该曲目此前校准过的时间轴偏移（按曲目记忆，解决反复「时间轴不对」）
                    let rawKey = "\(newTitle)|\(newArtist)"
                    let key = rawKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? rawKey
                    let savedOffset = self.offsetByTrack[key] ?? 0
                    if savedOffset != self.lyricsOffset { self.lyricsOffset = savedOffset }
                }
            }
        }

        // 以下均为阻塞式 AppleScript / 网络调用，继续留在 scriptQueue 上执行
        // 封面：Music 在切歌瞬间可能尚未加载好 artwork（hasArt 暂时为 false），
        // 因此周期性重试直到取到，避免封面长期缺失/延迟。
        // 切歌时立即安排「快速重试」：不等 1.5s 主轮询，主动在 0.5/0.9/1.5/2.2s 各探一次，
        // 显著缩短流媒体封面下载完成后的首屏延迟。
        if trackChanged {
            hasArtFlag = false
            artworkRetryCount = 0
            scheduleArtworkRetry()
        }
        if (trackChanged && hasArt) || (!hasArtFlag && hasArt) {
            fetchArtwork()
        }

        // 歌词：Apple Music 的内嵌歌词在切歌后可能延迟加载，因此周期性重试，
        // 直到取到歌词或曲目再次切换。
        if trackChanged { hasLyricsFlag = false }
        fetchLyricsSync(title: newTitle, artist: newArtist, force: !hasLyricsFlag)
    }

    /// 调试日志：输出到系统日志（unified log，可用 `log show` 抓取）。
    func lyricLog(_ msg: String) {
        NSLog("[Lumi/Music] \(msg)")
    }

    // MARK: - 控制
    var isPlaying: Bool { playbackState == .playing }

    func togglePlayPause() {
        scriptQueue.async { [weak self] in
            self?.runScript("tell application \"Music\"\nplaypause\nend tell")
        }
    }

    func nextTrack() { switchTrack("next track") }

    func previousTrack() { switchTrack("previous track") }

    private func switchTrack(_ command: String) {
        artwork = nil
        scriptQueue.async { [weak self] in
            guard let self = self else { return }
            self.runScript("tell application \"Music\"\n\(command)\nend tell")
            self.lastTrackKey = ""
            self.hasLyricsFlag = false
            self.hasArtFlag = false
            self.refreshVolume()
            self.fetchInfoSync()
        }
    }

    func seek(to time: TimeInterval) {
        let t = Int(time)
        scriptQueue.async { [weak self] in
            self?.runScript("tell application \"Music\"\nset player position to \(t)\nend tell")
        }
    }

    /// 相对快进/快退 delta 秒（正为快进，负为快退）。基于当前 position 计算目标位置并跳转。
    func skip(by delta: TimeInterval) {
        scriptQueue.async { [weak self] in
            guard let self = self else { return }
            let src = """
            tell application "Music"
                try
                    if player state is playing or player state is paused then
                        set cur to player position
                        set dur to duration of current track
                        set target to cur + \(Int(delta))
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
            guard volume >= 0 else { return }
            UserDefaults.standard.set(volume, forKey: volumeKey)
        }
    }
    private let volumeKey = "music_volume"

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
