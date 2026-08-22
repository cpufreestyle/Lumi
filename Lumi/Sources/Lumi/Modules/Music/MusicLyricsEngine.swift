import Foundation
import AppKit

// MARK: - 音乐模块：歌词获取与解析
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
}
