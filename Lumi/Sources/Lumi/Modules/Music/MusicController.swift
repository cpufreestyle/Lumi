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
    /// 已尝试过在线搜索的曲目集合，避免重复请求
    private var onlineSearchedKeys = Set<String>()

    private init() {
        lyricLog("MusicController init")
        showLyrics = UserDefaults.standard.object(forKey: showLyricsKey) as? Bool ?? true
        startTimer()
    }

    private func startTimer() {
        lyricLog("startTimer scheduled")
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.fetchInfo()
        }
        fetchInfo()
    }

    // MARK: - AppleScript 执行
    private func runScript(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result: NSAppleEventDescriptor? = script.executeAndReturnError(&error)
        if let error = error {
            // 常见错误：Music 未运行 / 未授权 -> 忽略
            lyricLog("AppleScript error: \(error)")
            print("[Music] AppleScript: \(error)")
        }
        return result
    }

    // MARK: - 获取当前播放信息
    func fetchInfo() {
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

            // 封面：仅在曲目变化时重新获取
            let artKey = "\(newTitle)-\(newArtist)"
            if artKey != self.lastTrackKey {
                self.lastTrackKey = artKey
                // 切歌先清空歌词，避免短暂显示上一首歌词
                self.lyrics = ""
                if hasArt {
                    self.fetchArtwork()
                } else {
                    self.artwork = nil
                }
            }
            // 歌词：每次刷新都尝试获取。Apple Music 的内嵌歌词元数据在切歌后
            // 可能延迟加载或初始为 stopped 状态导致取不到，因此周期性重试，
            // 直到成功取到歌词或曲目再次切换时才重置。
            let hadLyrics = !self.lyrics.isEmpty
            self.fetchLyrics(force: !hadLyrics || artKey != self.lastTrackKey)
        }
    }

    private func fetchArtwork() {
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
    /// force=true 时无论当前是否有歌词都重新请求（用于切歌或歌词为空时重试）；
    /// force=false 时若已有歌词则跳过，避免无谓的 AppleScript 调用。
    func fetchLyrics(force: Bool = true) {
        // 已有歌词且非强制刷新 -> 跳过
        if !force, !lyrics.isEmpty { return }

        let embedded = getEmbeddedLyrics()
        if !embedded.isEmpty {
            DispatchQueue.main.async { [weak self] in self?.lyrics = embedded }
            return
        }

        // 内嵌歌词为空：Apple Music 的流媒体订阅歌曲大多如此（lyrics 属性恒为空）。
        // 回退到在线歌词（lrclib 免费 API，按 歌名+歌手 搜索）。每首歌只搜一次。
        let key = "\(title)-\(artist)"
        lyricLog("fetchLyrics force=\(force) title=\"\(title)\" cached=\(onlineSearchedKeys.contains(key))")
        if force, !title.isEmpty, !onlineSearchedKeys.contains(key) {
            onlineSearchedKeys.insert(key)
            lyricLog("-> online search for \(title)-\(artist)")
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
                self?.lyricLog("命中歌词 artist=\(artist) track=\(t) len=\(result.count)")
                DispatchQueue.main.async {
                    // 写回前确认仍是同一首歌，避免串词
                    if self?.title == originalTitle, self?.artist == originalArtist, self?.lyrics.isEmpty == true {
                        self?.lyrics = result
                    }
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

    /// 调试日志：写入 ~/lumi_lyrics.log，便于排查歌词拉取情况
    private func lyricLog(_ msg: String) {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent("lumi_lyrics.log")
        let line = "\(Date()) [Lumi] \(msg)\n"
        if let data = line.data(using: .utf8) {
            if let fh = FileHandle(forWritingAtPath: path) {
                fh.seekToEndOfFile()
                fh.write(data)
                try? fh.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
        }
    }

    // MARK: - 控制
    var isPlaying: Bool { playbackState == .playing }

    func togglePlayPause() {
        runScript("tell application \"Music\"\nplaypause\nend tell")
    }

    func nextTrack() {
        runScript("tell application \"Music\"\nnext track\nend tell")
        lastTrackKey = ""; artwork = nil
    }

    func previousTrack() {
        runScript("tell application \"Music\"\nprevious track\nend tell")
        lastTrackKey = ""; artwork = nil
    }

    func seek(to time: TimeInterval) {
        let t = Int(time)
        runScript("tell application \"Music\"\nset player position to \(t)\nend tell")
    }
}
