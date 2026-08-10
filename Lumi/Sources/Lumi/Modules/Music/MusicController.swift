import SwiftUI
import AppKit

// MARK: - 音乐模块控制器（macOS 通过 AppleScript 控制 Apple Music）
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
    private var onlineSearchedKeys = Set<String>()
    /// 在线搜索已尝试次数（失败重试用，上限后停止以省流量）。仅在 scriptQueue 上访问。
    private var onlineAttempts: [String: Int] = [:]
    /// 当前曲目是否已取到歌词（仅在 scriptQueue 上访问，避免跨线程 sync 读 @Published）
    private var hasLyricsFlag = false
    /// 当前曲目是否已取到封面（仅在 scriptQueue 上访问）。用于封面延迟加载的周期性重试。
    private var hasArtFlag = false
    /// 当前曲目的名称/艺术家（仅在 scriptQueue 上访问）
    private var queueTitle = ""
    private var queueArtist = ""
    /// 歌词翻译缓存：原文 -> 翻译。避免同一句歌词反复请求翻译 API（省流量 + 防限流）。
    /// 所有读写都收敛到 translationQueue（串行），防止与重建 syncedLines 的主线程访问产生数据竞争。
    private var translationCache: [String: String] = [:]
    /// 翻译缓存专用串行队列：统一保护 translationCache 的读写，避免跨线程字典崩溃。
    private let translationQueue = DispatchQueue(label: "com.lumi.music.translation")
    /// 翻译缓存持久化文件路径：~/Library/Application Support/Lumi/translation_cache.json
    private var translationCacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lumi")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("translation_cache.json")
    }
    /// 启动时从磁盘加载已翻译歌词缓存，避免重复翻译（命中即跳过网络请求）。
    private func loadTranslationCache() {
        translationQueue.async { [weak self] in
            guard let self = self else { return }
            guard let data = try? Data(contentsOf: self.translationCacheURL),
                  let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return }
            self.translationCache = dict
        }
    }
    /// 将当前翻译缓存写盘（在 translationQueue 内调用，保证与内存读写一致）。
    private func persistTranslationCache() {
        let url = self.translationCacheURL
        let snapshot = self.translationCache
        translationQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
    /// 写入一条译文到内存缓存并异步持久化到磁盘（统一入口，覆盖所有翻译来源）。
    private func cacheTranslation(_ src: String, _ tr: String) {
        translationQueue.async { [weak self] in
            guard let self = self else { return }
            self.translationCache[src] = tr
            // 落盘（粗粒度写整文件，缓存规模小，写盘成本低）
            let url = self.translationCacheURL
            let snapshot = self.translationCache
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
    /// AppleScript 为同步阻塞调用（约 100–300ms），必须在后台串行队列执行，
    /// 否则 1.5 秒轮询会周期性卡住主线程。
    private let scriptQueue = DispatchQueue(label: "com.lumi.music.script", qos: .utility)
    /// 专辑封面获取专用队列（高优先级）。封面原始数据较大，且不应与歌词 AppleScript /
    /// 翻译网络请求争用同一队列，否则会拖慢封面出现、产生明显延迟。
    /// 注意：本队列只做「取数据 + 解码缩放」的纯计算工作；任何共享标志位（hasArtFlag 等）
    /// 的写回一律派回 scriptQueue，避免跨队列无锁读写导致偶发崩溃。
    private let artworkQueue = DispatchQueue(label: "com.lumi.music.artwork", qos: .userInitiated)
    /// 切歌后封面快速重试用的计数器（仅在 scriptQueue 上访问）。
    private var artworkRetryCount = 0

    private init() {
        showLyrics = UserDefaults.standard.object(forKey: showLyricsKey) as? Bool ?? true
        lyricsOffset = UserDefaults.standard.object(forKey: lyricsOffsetKey) as? TimeInterval ?? 0
        offsetByTrack = UserDefaults.standard.dictionary(forKey: offsetByTrackKey) as? [String: TimeInterval] ?? [:]
        let savedBilingual = UserDefaults.standard.object(forKey: bilingualKey) as? Int ?? BilingualMode.auto.rawValue
        bilingualMode = BilingualMode(rawValue: savedBilingual) ?? .auto
        startTimer()
        loadVolumeIfNeeded()
        loadTranslationCache()
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
    private func runScript(_ source: String) -> NSAppleEventDescriptor? {
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

    /// 取专辑封面：在 artworkQueue（高优先级）上取数据并稳健解码缩放（纯计算），
    /// 结果回主线程赋值，标志位 hasArtFlag 写回 scriptQueue（消除跨队列竞争导致的偶发崩溃）。
    /// 取不到（Music 封面尚未下载好）时安排下一次快速重试。
    private func fetchArtwork() {
        artworkQueue.async { [weak self] in
            guard let self = self else { return }
            let src = """
            tell application "Music"
                try
                    if exists artwork 1 of current track then
                        return data of artwork 1 of current track
                    end if
                end try
                return ""
            end tell
            """
            guard let desc = self.runScript(src) else {
                self.scheduleArtworkRetry()
                return
            }
            let data = desc.data
            guard !data.isEmpty else {
                // 封面数据还没就绪（流媒体正在下载），安排重试
                self.scheduleArtworkRetry()
                return
            }
            guard let original = NSImage(data: data) else {
                self.scheduleArtworkRetry()
                return
            }
            // 用 CGContext 稳健缩放至 280×280（避免后台队列 lockFocus 的隐患）
            guard let thumb = Self.scaledImage(original, to: NSSize(width: 280, height: 280)) else {
                self.scheduleArtworkRetry()
                return
            }
            DispatchQueue.main.async { [weak self] in self?.artwork = thumb }
            self.scriptQueue.async { [weak self] in self?.hasArtFlag = true }
        }
    }

    /// 切歌后用 scriptQueue 周期性探一次封面：Music 封面往往晚于切歌事件就绪，
    /// 因此主动重试若干次（总跨度约 2.2s），不等 1.5s 主轮询，缩短首屏延迟。
    private func scheduleArtworkRetry() {
        guard artworkRetryCount < 4 else { return }
        artworkRetryCount += 1
        let delay = [0.5, 0.9, 1.5, 2.2][artworkRetryCount - 1]
        scriptQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
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
    private func fetchLyricsSync(title: String, artist: String, force: Bool) {
        if !force, hasLyricsFlag { return }
        diagLog("fetchLyricsSync title=\(title.prefix(20)) artist=\(artist.prefix(15)) force=\(force) hasLyrics=\(hasLyricsFlag)")

        let embedded = getEmbeddedLyrics()
        if !embedded.isEmpty {
            hasLyricsFlag = true
            DispatchQueue.main.async { [weak self] in self?.lyrics = embedded }
            return
        }

        // 内嵌歌词为空：Apple Music 的流媒体订阅歌曲大多如此（lyrics 属性恒为空）。
        // 回退到在线歌词（lrclib 免费 API，按 歌名+歌手 搜索）。
        // lrclib 的 syncedLyrics 是社区从 Apple Music 扒取的逐行时间轴歌词，
        // 优先拿它做带时间轴的逐行高亮。
        let key = "\(title)-\(artist)"
        // 成功取过则跳过；失败（含网络不可达）不记入 onlineSearchedKeys，允许后续周期重试，
        // 但限制每首最多 3 次尝试，避免无谓刷请求。
        if force, !title.isEmpty, !onlineSearchedKeys.contains(key), (onlineAttempts[key] ?? 0) < 3 {
            onlineAttempts[key] = (onlineAttempts[key] ?? 0) + 1
            if onlineAttempts.count > 200 { onlineAttempts.removeAll() }
            fetchLyricsOnline(artist: artist, title: title)
        }
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

        tryLyricsCandidates(candidates: candidates, index: 0,
                            originalTitle: title, originalArtist: artist)
    }

    /// lyrics.ovh 纯文本兜底源（无时间轴）。当 lrclib 全部候选失败（含网络不可达）时调用。
    /// 至少能保证显示歌词文本，尽管无法逐行高亮。
    private func fetchLyricsOvh(artist: String, title: String) {
        let a = artist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let tt = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard !tt.isEmpty else { return }
        let urlStr = "https://api.lyrics.ovh/v1/\(a)/\(tt)"
        guard let url = URL(string: urlStr) else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            guard let self = self else { return }
            if let err = err {
                self.lyricLog("lyrics.ovh 网络错误 artist=\(artist) title=\(title) err=\(err.localizedDescription)")
                return
            }
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let lyr = obj["lyrics"] as? String, !lyr.trimmingCharacters(in: .whitespaces).isEmpty else {
                self.lyricLog("lyrics.ovh 未返回歌词 artist=\(artist) title=\(title)")
                return
            }
            self.lyricLog("lyrics.ovh 命中纯文本歌词 len=\(lyr.count) title=\(title)")
            self.setSyncedLyrics(synced: [], plain: lyr, title: title, artist: artist)
        }.resume()
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

    /// 移除曲名里的版本/括号后缀，提高在线匹配成功率。
    /// 同时把繁体转简体：lrclib 等公开源的中文歌词多为简体收录，
    /// 直接用繁体歌名（如「瀟洒小姐」）搜索常落空，转简体后能命中。
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

    private func tryLyricsCandidates(candidates: [(artist: String, track: String)], index: Int,
                                     originalTitle: String, originalArtist: String) {
        guard index < candidates.count else {
            // lrclib 所有候选均未命中（含网络不可达）：回退到 lyrics.ovh 纯文本源。
            lyricLog("lrclib 候选均失败，回退 lyrics.ovh artist=\(originalArtist) title=\(originalTitle)")
            self.fetchLyricsOvh(artist: originalArtist, title: originalTitle)
            return
        }
        let c = candidates[index]
        let a = c.artist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let tt = c.track.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        var urlStr = "https://lrclib.net/api/search?track_name=\(tt)"
        if !a.isEmpty { urlStr += "&artist_name=\(a)" }
        guard let url = URL(string: urlStr) else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            guard let self = self else { return }
            if let err = err {
                self.lyricLog("候选[\(index)]网络错误 artist=\(c.artist) track=\(c.track) err=\(err.localizedDescription)")
            } else if data == nil || data!.isEmpty {
                self.lyricLog("候选[\(index)]返回空 data artist=\(c.artist) track=\(c.track)")
            }
            // 按与当前曲目的相似度挑选，而不是无脑取第一条，避免同名歌串词
            let resolved = self.resolveLyrics(data,
                                              expectTitle: originalTitle,
                                              expectArtist: originalArtist)
            if resolved.hasContent {
                self.lyricLog("候选[\(index)]命中歌词 synced=\(resolved.synced.count) plainLen=\(resolved.plain.count) title=\(originalTitle)")
                self.setSyncedLyrics(synced: resolved.synced,
                                     plain: resolved.plain,
                                     title: originalTitle,
                                     artist: originalArtist)
            } else {
                // 当前候选失败，尝试下一个
                self.lyricLog("候选[\(index)]未命中，尝试下一个 title=\(originalTitle)")
                self.tryLyricsCandidates(candidates: candidates, index: index + 1,
                                         originalTitle: originalTitle, originalArtist: originalArtist)
            }
        }.resume()
    }

    /// 解析歌词结果：优先返回带时间轴的 synced 行（来自 lrclib 的 syncedLyrics，
    /// 即社区从 Apple Music 扒取的逐行时间轴歌词），否则回退纯文本。
    private struct ResolvedLyrics {
        let synced: [SyncedLine]
        let plain: String
        var hasContent: Bool { !synced.isEmpty || !plain.isEmpty }
    }

    private func resolveLyrics(_ data: Data?,
                               expectTitle: String,
                               expectArtist: String) -> ResolvedLyrics {
        guard let data = data else { return ResolvedLyrics(synced: [], plain: "") }
        var entries: [[String: Any]] = []
        // /api/search 返回数组；个别情况下也可能返回单个字典
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            entries = arr
        } else if let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            entries = [d]
        }
        lyricLog("resolveLyrics: entries=\(entries.count) expectTitle=\(expectTitle) expectArtist=\(expectArtist)")

        // /api/search 是模糊搜索，返回结果可能是同名的另一首歌。
        // 取歌名匹配、且歌手不冲突的最佳条目，而不是第一条有歌词的条目。
        var best: (score: Int, synced: [SyncedLine], plain: String)?
        for d in entries {
            let synced = parseSyncedLyrics(d["syncedLyrics"] as? String)
            let plain = pickLyrics(d)
            if synced.isEmpty, plain.isEmpty { continue }
            let score = matchScore(d, expectTitle: expectTitle, expectArtist: expectArtist)
            if score < 0 { continue }   // 歌名对不上，直接排除
            if best == nil || score > best!.score {
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

    /// 把 LRC 文本（含 [mm:ss.xx] 时间戳）解析为带时间轴的 SyncedLine 数组。
    /// 解析时会尝试拆分「自带双语」行（一行内同时含两种语言，如 `原文 / 翻译`），
    /// 拆出的翻译写入 SyncedLine.translation，避免后续联网重复翻译。
    private func parseSyncedLyrics(_ raw: String?) -> [SyncedLine] {
        guard let raw = raw, !raw.isEmpty else { return [] }
        var lines: [SyncedLine] = []
        let regex = try? NSRegularExpression(pattern: #"^(\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?\])+(.*)$"#)
        for line in raw.components(separatedBy: .newlines) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let regex = regex,
                  let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let minR = Range(m.range(at: 2), in: text),
                  let secR = Range(m.range(at: 3), in: text),
                  let bodyR = Range(m.range(at: 5), in: text) else { continue }
            guard let min = Int(text[minR]), let sec = Int(text[secR]) else { continue }
            let msRange = m.range(at: 4)
            let msStr = (Range(msRange, in: text).map { String(text[$0]) }) ?? ""
            // lrclib 的 syncedLyrics 时间戳 [mm:ss.xx] 中 .xx 可能是厘秒（2 位）或毫秒（3 位），
            // 按小数位数自适应换算，避免时间整体偏移导致逐行高亮错位。
            let divisor = pow(10.0, Double(msStr.count))
            let ms = (Double(msStr) ?? 0) / (divisor > 1 ? divisor : 1000)
            let t = TimeInterval(min * 60 + sec) + ms
            let body = String(text[bodyR]).trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { continue }
            let (textPart, translation) = splitBilingualLine(body)
            // 繁体歌词统一转简体（lrclib 社区上传常含繁体中文）；英文/拉丁部分不受影响。
            let simplified = toSimplified(textPart)
            let simplifiedTr = translation.map { toSimplified($0) }
            lines.append(SyncedLine(text: simplified, time: t, translation: simplifiedTr))
        }
        return lines
    }

    /// 繁体中文 → 简体中文（CFStringTransform "Hant-Hans"）。
    /// 仅转换 CJK 字符，英文/拉丁/标点原样保留，可安全用于中英混合歌词与翻译文本。
    private func toSimplified(_ s: String) -> String {
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
    private func splitBilingualLine(_ line: String) -> (text: String, translation: String?) {
        let patterns: [(String, String)] = [
            ("\\s*/\\s*", "/"),          // 斜杠分隔
            ("[（(]\\s*", "("),          // 半角/全角左括号
            ("[【\\[]\\s*", "["),        // 全角/半角方括号
            ("\\s*[:：]\\s*", ":")       // 冒号分隔
        ]
        for (sepRegex, sepKind) in patterns {
            guard let re = try? NSRegularExpression(pattern: sepRegex) else { continue }
            let ns = NSRange(line.startIndex..., in: line)
            guard let m = re.firstMatch(in: line, range: ns) else { continue }
            let sepRange = m.range
            guard let r = Range(sepRange, in: line) else { continue }
            // 找到分隔符对应的右闭合符号（括号/方括号需配对到行尾或闭合符）
            var tailStart = r.upperBound
            if sepKind == "(" {
                if let close = line[r.upperBound...].range(of: "）")?.lowerBound ??
                    line[r.upperBound...].range(of: ")")?.lowerBound {
                    tailStart = r.upperBound
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

    /// 校验两侧是否确为不同语言（避免误拆）。CJK 与拉丁字母混合即视为双语。
    private func validateBilingual(_ original: String, _ translated: String) -> (text: String, translation: String)? {
        guard !original.isEmpty, !translated.isEmpty else { return nil }
        // 两侧不能完全相同
        guard original != translated else { return nil }
        let hasCJK: (String) -> Bool = { s in s.contains { 0x4E00...0x9FFF ~= $0.unicodeScalars.first!.value } }
        let hasLatin: (String) -> Bool = { s in
            s.rangeOfCharacter(from: CharacterSet.letters.subtracting(CharacterSet(charactersIn: "　-￿"))) != nil
        }
        let oCJK = hasCJK(original), oLat = hasLatin(original)
        let tCJK = hasCJK(translated), tLat = hasLatin(translated)
        // 一侧中文一侧拉丁（任一组合），判定为双语对照
        if (oCJK != tCJK) || (oLat != tLat) {
            if (oCJK || oLat), (tCJK || tLat) {
                return (original, translated)
            }
        }
        return nil
    }

    /// 写入歌词：带时间轴优先写入 syncedLines 供逐行高亮；同时生成纯文本 lyrics 兜底展示。
    private func setSyncedLyrics(synced: [SyncedLine], plain: String,
                                 title: String, artist: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // 写回前确认仍是同一首歌，避免串词。
            // 注意：不要要求 self.lyrics.isEmpty —— 否则播放中歌词异步返回时，
            // 若歌词字段已被占用（或正处于某次清空/重试间隙之外）就会被整条丢弃，
            // 只有切歌/暂停等让 lyrics 恰好为空的瞬间才写进去，表现为「暂停才显示」。
            guard self.title == title || title.isEmpty else { return }
            if !synced.isEmpty {
                self.syncedLines = synced
                // 收缩态/无时间轴兜底展示：用 synced 的文本
                self.lyrics = synced.map { $0.text }.joined(separator: "\n")
                // 双语：对带时间轴的歌词逐行补全翻译（自带双语已写入 translation，跳过）
                self.fetchTranslations(synced: synced, title: title)
            } else {
                let simplifiedPlain = self.toSimplified(plain)
                self.lyrics = simplifiedPlain
                // 双语：无时间轴纯文本歌词，整段翻译补全
                self.fetchPlainTranslation(plain: simplifiedPlain, title: title)
            }
            // 成功取到歌词：记入成功缓存，停止对该曲的后续重试
            let key = "\(title)-\(artist)"
            self.scriptQueue.async {
                self.hasLyricsFlag = true
                self.onlineSearchedKeys.insert(key)
            }
        }
    }

    // MARK: - 双语歌词翻译补全
    /// 对带时间轴的歌词逐行补全翻译（仅针对没有自带 translation 的行）。
    /// 自带双语已在 parseSyncedLyrics 拆分，无需联网；联网用 MyMemory 免费 API（无需 key）。
    /// 译文按行缓存，避免重复请求。整段翻译结果在回调中重建 syncedLines 写回主线程。
    private func fetchTranslations(synced: [SyncedLine], title: String) {
        guard bilingualMode != .off else { return }
        // 待译行：translation 为 nil 或空字符串都算未翻译（避免"假完成"——空译文被当成已完成而永不重译）
        let targets = synced.enumerated().filter {
            ($0.element.translation ?? "").isEmpty && !$0.element.text.isEmpty
        }
        guard !targets.isEmpty else { return }
        // 限制单首翻译行数，避免触发翻译 API 限流（MyMemory 未认证约 5000 词/日）
        let capped = Array(targets.prefix(60))
        // 每批 8 行拼接成一段一次请求，显著减少网络往返（RTT），加快整首补全速度。
        let batchSize = 8
        let batches = stride(from: 0, to: capped.count, by: batchSize).map {
            Array(capped[$0..<min($0 + batchSize, capped.count)])
        }
        // 串行处理各批次：避免一次性并发所有请求触发 Google/LLM 限流（表现为"翻译到一半断掉"）。
        // 每批之间间隔 0.4s，且每批失败重试 1 次；失败的行不写空占位，保留"翻译中"状态，
        // 下一轮轮询可再次补译，避免永久断掉。
        func processBatch(at index: Int) {
            guard index < batches.count else {
                self.rebuildSyncedWithTranslations(title: title)
                return
            }
            let batch = batches[index]
            let pending = batch.filter { line in
                var cached: String?
                self.translationQueue.sync { cached = self.translationCache[line.element.text] }
                return cached == nil
            }
            guard !pending.isEmpty else {
                // 整批已命中缓存，直接下一批
                self.scriptQueue.asyncAfter(deadline: .now() + 0.1) { processBatch(at: index + 1) }
                return
            }
            let srcs = pending.map { $0.element.text }
            var attempts = 0
            func attempt() {
                attempts += 1
                self.translateBatchWithRetry(lines: srcs, attempt: attempts) { [weak self] translated in
                    guard let self = self else { return }
                    if let translated = translated, translated.count == srcs.count {
                        for (k, src) in srcs.enumerated() {
                            let tr = translated[k]
                            guard !tr.isEmpty else { continue }
                            self.cacheTranslation(src, tr)
                        }
                        self.scriptQueue.asyncAfter(deadline: .now() + 0.3) { processBatch(at: index + 1) }
                    } else if attempts < 2 {
                        // 整批失败：重试一次（限流往往是突发并发导致，稍后重试大多成功）
                        self.diagLog("translateBatch 整批失败，重试（attempt=\(attempts)）")
                        self.scriptQueue.asyncAfter(deadline: .now() + 0.8) { attempt() }
                    } else {
                        // 重试仍失败：逐行兜底翻译（每条计入批次完成信号）
                        let subgroup = DispatchGroup()
                        for src in srcs {
                            var cached: String?
                            self.translationQueue.sync { cached = self.translationCache[src] }
                            guard cached == nil else { continue }
                            subgroup.enter()
                            self.translateWithRetry(text: src, attempt: 1) { [weak self] tr in
                                defer { subgroup.leave() }
                                guard let self = self else { return }
                                if let tr = tr, !tr.isEmpty {
                                    self.cacheTranslation(src, tr)
                                }
                                // 注意：失败不写空占位，保留"翻译中"，下一轮可补译
                            }
                        }
                        subgroup.notify(queue: self.scriptQueue) {
                            // 本批兜底完成，进入下一批
                            self.scriptQueue.asyncAfter(deadline: .now() + 0.3) { processBatch(at: index + 1) }
                        }
                    }
                }
            }
            attempt()
        }
        scriptQueue.async { processBatch(at: 0) }
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
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard self.title == title || title.isEmpty else { return }
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
    private func fetchPlainTranslation(plain: String, title: String) {
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
    private func reapplyBilingualForCurrentTrack() {
        guard bilingualMode != .off else { return }
        if !syncedLines.isEmpty {
            fetchTranslations(synced: syncedLines, title: title)
        } else if !lyrics.isEmpty {
            fetchPlainTranslation(plain: lyrics, title: title)
        }
    }

    // MARK: - 翻译后端配置（大模型，OpenAI 兼容 Chat Completions）
    /// key / baseURL / model 均从环境变量读取，不写死在代码里、不进 git。
    /// - LUMI_TRANSLATE_API_KEY：必填。免费 key 可去 OpenRouter（默认）/ Gemini 等注册。
    /// - LUMI_TRANSLATE_BASE_URL：OpenAI 兼容端点，默认 OpenRouter。
    /// - LUMI_TRANSLATE_MODEL：模型名，默认 OpenRouter 免费模型。
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
    private func envValue(_ name: String) -> String? {
        translateEnv[name]
    }

    private var translateAPIKey: String? { envValue("LUMI_TRANSLATE_API_KEY") }
    private var translateBaseURL: String {
        envValue("LUMI_TRANSLATE_BASE_URL") ?? "https://openrouter.ai/api/v1"
    }
    private var translateModel: String {
        envValue("LUMI_TRANSLATE_MODEL") ?? "google/gemma-4-26b-a4b-it:free"
    }
    private var translateForceLLM: Bool {
        (envValue("LUMI_FORCE_LLM") ?? "0") == "1"
    }

    /// 翻译主入口。
    /// 默认走 Google 公开翻译接口（无需 key、无每日硬限额、对歌词足够准确、稳定可用）；
    /// 仅当用户通过 LUMI_FORCE_LLM=1 显式开启且已配置有效 key 时，才优先走大模型（OpenAI 兼容）。
    /// 任一通道失败都回退到另一通道，最终失败返回 nil（UI 显示原文），不长时间挂起。
    private func translate(text: String, completion: @escaping (String?) -> Void) {
        let forceLLM = translateForceLLM
        if forceLLM, let key = translateAPIKey {
            self.diagLog("translate: 强制大模型 key=\(String(key.prefix(12)))... model=\(translateModel)")
            self.translateViaLLM(text: text) { result in
                if let result { completion(result) }
                else { self.translateViaGoogle(text: text, completion: completion) }
            }
        } else {
            self.diagLog("translate: 走 Google 公开接口（稳定、无 key）")
            translateViaGoogle(text: text) { result in
                if let result { completion(result) }
                else if self.translateAPIKey != nil {
                    self.translateViaLLM(text: text) { completion($0) }
                } else { completion(nil) }
            }
        }
    }

    /// 调用大模型（OpenAI 兼容 Chat Completions）补全翻译。
    /// 目标语言：原文含中文 -> 译为英文；否则 -> 译为中文。失败时返回 nil，由调用方兜底。
    private func translateViaLLM(text: String, completion: @escaping (String?) -> Void) {
        guard let key = translateAPIKey else { completion(nil); return }
        let hasCJK = text.contains { 0x4E00...0x9FFF ~= $0.unicodeScalars.first?.value ?? 0 }
        let targetLang = hasCJK ? "English" : "Chinese"
        let sysPrompt = "You are a lyrics translator. Translate the given line into \(targetLang) only. Keep it concise, preserve tone, do NOT add explanations or quotes. Output only the translation."
        let urlStr = "\(translateBaseURL)/chat/completions"
        guard let url = URL(string: urlStr) else { completion(nil); return }

        let body: [String: Any] = [
            "model": translateModel,
            "messages": [
                ["role": "system", "content": sysPrompt],
                ["role": "user", "content": text]
            ],
            "temperature": 0.3,
            "max_tokens": 200
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 12
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                self.diagLog("translateViaLLM: HTTP \(http.statusCode) 失败，回退")
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
            self.diagLog("translateViaLLM OK: \(text) -> \(cleaned)")
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
                self.diagLog("translate 单句失败，重试（attempt=\(attempt)）：\(text.prefix(20))")
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
                self.diagLog("translateBatch 失败，重试（attempt=\(attempt)），行数=\(lines.count)")
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
        let forceLLM = translateForceLLM
        // 默认 Google 公开接口；仅 LUMI_FORCE_LLM=1 且配置了 key 才优先大模型
        if !(forceLLM && translateAPIKey != nil) {
            translateViaGoogle(text: joined) { tr in
                if let tr, self.splitBatch(tr, expected: lines.count) != nil {
                    completion(self.splitBatch(tr, expected: lines.count))
                } else if self.translateAPIKey != nil {
                    self.translateBatchViaLLM(lines: lines, joined: joined, completion: completion)
                } else { completion(nil) }
            }
            return
        }
        translateBatchViaLLM(lines: lines, joined: joined, completion: completion)
    }

    /// 批量翻译走大模型（LLM 优先通道）。失败时回退 Google 公开接口，最终失败返回 nil。
    private func translateBatchViaLLM(lines: [String], joined: String,
                                      completion: @escaping ([String]?) -> Void) {
        guard let key = translateAPIKey else {
            translateViaGoogle(text: joined) { completion(self.splitBatch($0, expected: lines.count)) }
            return
        }
        let hasCJK = joined.contains { 0x4E00...0x9FFF ~= $0.unicodeScalars.first?.value ?? 0 }
        let targetLang = hasCJK ? "English" : "Chinese"
        let sysPrompt = "You are a lyrics translator. Translate each line of the given text into \(targetLang), keeping the SAME number of lines as the input, and use a single newline to separate lines. Keep it concise, preserve tone. Do NOT add explanations, numbering, or quotes. Output only the translated lines."
        let urlStr = "\(translateBaseURL)/chat/completions"
        guard let url = URL(string: urlStr) else {
            translateViaGoogle(text: joined) { completion(self.splitBatch($0, expected: lines.count)) }
            return
        }
        let body: [String: Any] = [
            "model": translateModel,
            "messages": [
                ["role": "system", "content": sysPrompt],
                ["role": "user", "content": joined]
            ],
            "temperature": 0.3,
            "max_tokens": 800
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 12
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
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
    private func splitBatch(_ text: String?, expected: Int) -> [String]? {
        guard let text = text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let parts = text.components(separatedBy: "\n")
        guard parts.count == expected else { return nil }
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// 免费翻译回退源：Google 翻译公开网页接口（translate.googleapis.com/translate_a/single）。
    /// 无需 key、无每日硬限额（仅频率限制，个人使用足够），替代原 MyMemory（有每日限额易耗尽）。
    private func translateViaGoogle(text: String, completion: @escaping (String?) -> Void) {
        let q = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard !q.isEmpty else { completion(nil); return }
        let hasCJK = text.contains { 0x4E00...0x9FFF ~= $0.unicodeScalars.first?.value ?? 0 }
        let target = hasCJK ? "en" : "zh"
        let urlStr = "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=\(target)&dt=t&q=\(q)"
        guard let url = URL(string: urlStr) else { completion(nil); return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let e = err { self.diagLog("translateViaGoogle 网络错误: \(e.localizedDescription)") }
            guard let data = data,
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  let seg0 = arr.first as? [Any], !seg0.isEmpty else {
                if let http = resp as? HTTPURLResponse { self.diagLog("translateViaGoogle HTTP \(http.statusCode) 失败") }
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

    /// 评估搜索结果与当前曲目的匹配度。
    /// 返回 -1 表示歌名不匹配（应排除）；分值越高越可信。
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

    /// 归一化：小写、去掉空白与标点，便于宽松比较
    private func norm(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: #"[\s\-_'’,.!?()\[\]（）【】]"#,
                                  with: "", options: .regularExpression)
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

    /// 调试日志：输出到系统日志（unified log，可用 `log show` 抓取）。
    private func lyricLog(_ msg: String) {
        NSLog("[Lumi/Music] \(msg)")
    }

    /// [临时诊断] 写入 ~/Library/Application Support/Lumi/lumi_translate.log 便于离线排查翻译。确认后移除。
    private func diagLog(_ msg: String) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lumi")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("lumi_translate.log")
        let line = "\(Date()) [diag] \(msg)\n"
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile()
            fh.write(line.data(using: .utf8) ?? Data())
            try? fh.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
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
