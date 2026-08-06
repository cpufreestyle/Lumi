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
    @Published var showLyrics: Bool = true {
        didSet { UserDefaults.standard.set(showLyrics, forKey: showLyricsKey) }
    }
    private let showLyricsKey = "music_show_lyrics"

    enum PlaybackState { case playing, paused, stopped }

    private var timer: Timer?
    private var lastTrackKey: String = ""
    /// 已尝试过在线搜索的曲目集合，避免重复请求（仅在 scriptQueue 上访问）
    private var onlineSearchedKeys = Set<String>()
    /// 当前曲目是否已取到歌词（仅在 scriptQueue 上访问，避免跨线程 sync 读 @Published）
    private var hasLyricsFlag = false
    /// 当前曲目的名称/艺术家（仅在 scriptQueue 上访问）
    private var queueTitle = ""
    private var queueArtist = ""
    /// AppleScript 为同步阻塞调用（约 100–300ms），必须在后台串行队列执行，
    /// 否则 1.5 秒轮询会周期性卡住主线程。
    private let scriptQueue = DispatchQueue(label: "com.lumi.music.script", qos: .utility)

    private init() {
        showLyrics = UserDefaults.standard.object(forKey: showLyricsKey) as? Bool ?? true
        startTimer()
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
            // 切歌先清空歌词，避免短暂显示上一首的歌词
            if trackChanged {
                self.lyrics = ""
                if !hasArt { self.artwork = nil }
            }
        }

        // 以下均为阻塞式 AppleScript / 网络调用，继续留在 scriptQueue 上执行
        if trackChanged, hasArt { fetchArtworkSync() }

        // 歌词：Apple Music 的内嵌歌词在切歌后可能延迟加载，因此周期性重试，
        // 直到取到歌词或曲目再次切换。
        if trackChanged { hasLyricsFlag = false }
        fetchLyricsSync(title: newTitle, artist: newArtist, force: !hasLyricsFlag)
    }

    private func fetchArtworkSync() {
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
        guard let desc = runScript(src) else { return }
        let data = desc.data
        if !data.isEmpty, let img = NSImage(data: data) {
            DispatchQueue.main.async { [weak self] in self?.artwork = img }
        }
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

        let embedded = getEmbeddedLyrics()
        if !embedded.isEmpty {
            hasLyricsFlag = true
            DispatchQueue.main.async { [weak self] in self?.lyrics = embedded }
            return
        }

        // 内嵌歌词为空：Apple Music 的流媒体订阅歌曲大多如此（lyrics 属性恒为空）。
        // 回退到在线歌词（lrclib 免费 API，按 歌名+歌手 搜索）。每首歌只搜一次。
        let key = "\(title)-\(artist)"
        if force, !title.isEmpty, !onlineSearchedKeys.contains(key) {
            onlineSearchedKeys.insert(key)
            // 限制缓存容量，避免长期运行无上限增长
            if onlineSearchedKeys.count > 200 { onlineSearchedKeys.removeAll() }
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
        var tracks: [String] = []
        let cleaned = cleanTrackTitle(title)
        if !cleaned.isEmpty { tracks.append(cleaned) }
        if !title.isEmpty, !tracks.contains(title) { tracks.append(title) }
        tryLyricsCandidates(artist: artist, tracks: tracks, index: 0,
                            originalTitle: title, originalArtist: artist)
    }

    /// 移除曲名里的版本/括号后缀，提高在线匹配成功率
    private func cleanTrackTitle(_ t: String) -> String {
        var s = t
        s = s.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
        if let r = s.range(of: " - ") { s.removeSubrange(r.lowerBound...) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private func tryLyricsCandidates(artist: String, tracks: [String], index: Int,
                                     originalTitle: String, originalArtist: String) {
        guard index < tracks.count else {
            lyricLog("所有候选均未匹配到歌词 artist=\(originalArtist) title=\(originalTitle)")
            return
        }
        let t = tracks[index]
        let a = artist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let tt = t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "https://lrclib.net/api/search?artist_name=\(a)&track_name=\(tt)") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            let result = self?.parseLyricsFromData(data) ?? ""
            if !result.isEmpty {
                DispatchQueue.main.async {
                    // 写回前确认仍是同一首歌，避免串词
                    guard let self = self,
                          self.title == originalTitle,
                          self.artist == originalArtist,
                          self.lyrics.isEmpty else { return }
                    self.lyrics = result
                    self.scriptQueue.async { self.hasLyricsFlag = true }
                }
            } else {
                // 当前候选失败，尝试下一个
                self?.tryLyricsCandidates(artist: artist, tracks: tracks, index: index + 1,
                                          originalTitle: originalTitle, originalArtist: originalArtist)
            }
        }.resume()
    }

    private func parseLyricsFromData(_ data: Data?) -> String {
        guard let data = data else { return "" }
        // /api/search 返回数组；个别情况下也可能返回单个字典
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for d in arr {
                let r = pickLyrics(d)
                if !r.isEmpty { return r }
            }
        } else if let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let r = pickLyrics(d)
            if !r.isEmpty { return r }
        }
        return ""
    }

    private func pickLyrics(_ d: [String: Any]) -> String {
        let synced = (d["syncedLyrics"] as? String) ?? ""
        let plain = (d["plainLyrics"] as? String) ?? ""
        // 优先纯文本歌词（更干净），无则退用带时间戳版本
        return (!plain.isEmpty ? plain : synced).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 调试日志：仅 DEBUG 构建输出到控制台。
    /// （原实现每次调用都向 ~/lumi_lyrics.log 追加写盘，属于生产环境的无谓 IO。）
    private func lyricLog(_ msg: String) {
        #if DEBUG
        print("[Lumi/Music] \(msg)")
        #endif
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
            self.fetchInfoSync()
        }
    }

    func seek(to time: TimeInterval) {
        let t = Int(time)
        scriptQueue.async { [weak self] in
            self?.runScript("tell application \"Music\"\nset player position to \(t)\nend tell")
        }
    }
}
