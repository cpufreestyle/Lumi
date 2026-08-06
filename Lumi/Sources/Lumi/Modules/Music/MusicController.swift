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
    /// 带时间轴的歌词（Apple Music 官方歌词）。为空时 UI 退化为纯文本展示。
    @Published var syncedLines: [SyncedLine] = []
    @Published var showLyrics: Bool = true {
        didSet { UserDefaults.standard.set(showLyrics, forKey: showLyricsKey) }
    }
    private let showLyricsKey = "music_show_lyrics"

    /// 歌词时间轴校准偏移（秒）。lrclib/社区 LRC 的时间轴常以 Apple Music 基准标注，
    /// 但实际播放位置可能整体早/晚数秒（前奏 offset 差异），导致逐行高亮错位。
    /// 正值表示歌词时间轴比实际播放「快」了这么多，需要把匹配基准往后推。
    @Published var lyricsOffset: TimeInterval = 0 {
        didSet { UserDefaults.standard.set(lyricsOffset, forKey: lyricsOffsetKey) }
    }
    private let lyricsOffsetKey = "music_lyrics_offset"

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
    /// AppleScript 为同步阻塞调用（约 100–300ms），必须在后台串行队列执行，
    /// 否则 1.5 秒轮询会周期性卡住主线程。
    private let scriptQueue = DispatchQueue(label: "com.lumi.music.script", qos: .utility)

    private init() {
        showLyrics = UserDefaults.standard.object(forKey: showLyricsKey) as? Bool ?? true
        lyricsOffset = UserDefaults.standard.object(forKey: lyricsOffsetKey) as? TimeInterval ?? 0
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
                self.syncedLines = []
                if !hasArt { self.artwork = nil }
            }
        }

        // 以下均为阻塞式 AppleScript / 网络调用，继续留在 scriptQueue 上执行
        // 封面：Music 在切歌瞬间可能尚未加载好 artwork（hasArt 暂时为 false），
        // 因此周期性重试直到取到，避免封面长期缺失/延迟。
        if trackChanged { hasArtFlag = false }
        if (trackChanged && hasArt) || (!hasArtFlag && hasArt) {
            fetchArtworkSync()
        }

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
            hasArtFlag = true
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
        var tracks: [String] = []
        let cleaned = cleanTrackTitle(title)
        if !cleaned.isEmpty { tracks.append(cleaned) }
        if !title.isEmpty, !tracks.contains(title) { tracks.append(title) }

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

    /// 移除曲名里的版本/括号后缀，提高在线匹配成功率
    private func cleanTrackTitle(_ t: String) -> String {
        var s = t
        s = s.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
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
            lines.append(SyncedLine(text: body, time: t))
        }
        return lines
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
            } else {
                self.lyrics = plain
            }
            // 成功取到歌词：记入成功缓存，停止对该曲的后续重试
            let key = "\(title)-\(artist)"
            self.scriptQueue.async {
                self.hasLyricsFlag = true
                self.onlineSearchedKeys.insert(key)
            }
        }
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
