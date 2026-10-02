import Foundation

/// 封面候选的「专辑 + 时长」交叉验证评分（纯逻辑，Foundation only）。
///
/// 抽成独立类型是为了能进 `LumiTests`：这类消歧规则是封面正确与否的决定因素，
/// 必须有回归测试兜住，不能只靠实机肉眼确认。
///
/// 背景：同一首歌常同时存在录音室版、Live 版、串烧版，歌名与歌手完全相同，
/// 只有专辑名与时长能把它们区分开。实测《神预言》袁娅维的录音室版 191.6s 与
/// 《为歌而赞》Live 版 268.7s 歌名歌手一字不差，只看歌名歌手必然张冠李戴。
enum ArtworkScoring {

    // MARK: - 权重

    /// 专辑名完全一致。
    static let albumExactBonus = 40
    /// 专辑名互相包含（如「月亮失眠了」vs「月亮失眠了 (DELUXE EDITION)」）。
    static let albumContainsBonus = 20
    /// 专辑名明确不同：几乎必然是另一张专辑的封面，重罚。
    static let albumMismatchPenalty = -40
    /// 时长 2s 内视为同一录音（Apple 与 Music 的时长取整误差极小，实测 0.0s）。
    static let durationExactBonus = 30
    /// 时长 5s 内：可接受。
    static let durationNearBonus = 10
    /// 时长 10s 内：偏轻的版本差异。
    static let durationLoosePenalty = -20
    /// 时长偏差超过 10s：基本可判定为不同版本（Live / 剪辑 / 串烧）。
    static let durationMismatchPenalty = -50

    /// 判定为「同一录音」的时长容差（秒）。
    ///
    /// 2s 是过严的：实测《So Crazy》Music 报 290.99s，而 lrclib 上同一版本
    /// 的多个上传分别是 291.0 / 293.0 / 291.4 / 298.7s。这些差异来自元数据
    /// 精度、淡入淡出、剪辑，**不是** Live/伴奏版（那些能差 40s 以上）。
    /// 容差太紧会把正确版本的另一个上传误罚，甚至让纯文本候选
    /// 趁分值接近而胜出——歌词整段不滚动。放宽到 3s 仍能稳稳区分
    /// 真正的版本差异（Live 版差 40s+，远在惩罚档）。
    static let durationTolerance: Double = 3

    // MARK: - 歌名 + 歌手打分权重

    /// 歌名完全相同（归一化后）。
    static let titleExactBonus = 100
    /// 歌名互相包含（如「稻香」vs「稻香 (Live)」）。
    static let titleContainsBonus = 60
    /// 歌名互相包含时允许的最大长度差（归一化后的字符数）。
    ///
    /// 为什么需要：纯 contains 会把**跨歌曲前缀**也判成命中 ——
    /// 实测「后来」/「后来的我们」、「遇见」/「遇见你」、「童话」/「童话镇」
    /// 全部 contains=true。这些是**完全不同的歌**，歌词时间轴毫无关系；
    /// 一旦被选中，用户听到的是整首别人的歌词，是“歌词和歌声不一致”
    /// 最刺眼的形式。长度差约束把「包含」限制在版本标记范围内
    /// （Live / 伴奏 / Remastered 通常只增加几个字符），
    /// 又不至于误伤同一首歌的细微写法差异。
    static let titleContainsMaxLengthGap = 4
    /// 歌手完全相同。
    static let artistExactBonus = 50
    /// 歌手互相包含（合作曲目 / 译名差异）。
    static let artistContainsBonus = 30
    /// 歌手主名不匹配的罚分：压住国内源的海量翻唱/混音，防贴错封面。
    static let artistMismatchPenalty = -30

    // MARK: - 评分

    /// 歌名 + 歌手打分（不含专辑/时长）。
    ///
    /// 这是 `matchScore` 的纯函数版本，专为封面链路复用：
    /// 歌名必须相等或互相包含，否则判为不同歌曲（返回 -1）；
    /// 歌手不匹配不否决（组合歌手/译名差异常见），由调用方在主名层补罚分。
    /// 判断两个归一化歌名是否「同一首歌的不同写法」。
    ///
    /// 只看 contains 会把跨歌曲前缀也判成命中：实测「后来」/「后来的我们」、
    /// 「遇见」/「遇见你」、「童话」/「童话镇」全部 contains=true。
    /// 这些是**完全不同的歌**，歌词时间轴毫无关系；一旦被选中，
    /// 用户听到的是整首别人的歌词 —— 这是“歌词和歌声不一致”最刺眼的形式。
    ///
    /// 规则：短名必须是长名的**前缀或后缀**，且多出的部分只是版本标记
    /// （长度有上限）。「后来的我们」中「后来」虽是前缀，但多出的
    /// 「的我们」不是版本标记且超长，故判不同歌；而「稻香live」
    /// 中「稻香」是前缀、多出部分只有 4 字符且在版本词表内，判同一首。
    /// 版本标记词表（与 LyricsVersionTag 的族扁平表同源）。
    /// 用于判断歌名多出的片段**只是版本标记**，而不是另一首歌的名字。
    static let versionTagWords: Set<String> = [
        "live", "remaster", "remastered", "instrumental", "伴奏", "伴唱",
        "karaoke", "acoustic", "unplugged", "现场", "演唱会", "cover",
        "翻唱", "重唱", "deluxe", "bonus", "extended", "demo",
        "radioedit", "singleversion", "albumversion", "mandarin", "国语",
        "cantonese", "粤语", "japanese", "日语", "matinee", "早场",
    ]

    /// 判断两个归一化歌名是否「同一首歌的不同写法」。
    ///
    /// 只看 contains 会把跨歌曲前缀也判成命中：实测「后来」/「后来的我们」、
    /// 「遇见」/「遇见你」、「童话」/「童话镇」全部 contains=true。
    /// 这些是**完全不同的歌**，歌词时间轴毫无关系；一旦被选中，
    /// 用户听到的是整首别人的歌词 —— 这是“歌词和歌声不一致”最刺眼的形式。
    ///
    /// 中文歌名普遍只有三四字，纯长度阈值无法区分
    /// 「后来 / 后来的我们」（差 3 字）与「稻香 / 稻香live」（差 4 字符）。
    /// 因此判据是：多出的那一段**必须是版本标记词**，而不是别的字。
    static func isSameSongTitle(_ a: String, _ b: String) -> Bool {
        guard a != b else { return true }
        let short = a.count <= b.count ? a : b
        let long = a.count <= b.count ? b : a
        guard long.hasPrefix(short) || long.hasSuffix(short) else { return false }
        let extra = String(long.hasPrefix(short)
                            ? long.dropFirst(short.count)
                            : long.dropLast(short.count))
        guard !extra.isEmpty else { return true }
        // 多出部分整段都是已知版本标记词，才算同一首歌
        return versionTagWords.contains(extra.lowercased())
    }

    static func trackArtistScore(rTitle: String, rArtist: String,
                                 eTitle: String, eArtist: String) -> Int {
        let rt = norm(rTitle), ra = norm(rArtist)
        let et = norm(eTitle), ea = norm(eArtist)
        guard !rt.isEmpty, !et.isEmpty else { return -1 }
        var score: Int
        if rt == et {
            score = titleExactBonus
        } else if isSameSongTitle(rt, et) {
            score = titleContainsBonus
        } else {
            return -1
        }
        if !ea.isEmpty, !ra.isEmpty {
            if ra == ea {
                score += artistExactBonus
            } else if ra.contains(ea) || ea.contains(ra) {
                score += artistContainsBonus
            }
        }
        return score
    }

    /// 歌手主名（拆掉 feat./合作后缀），用于封面链路的「主名不匹配」罚分。
    static func primaryArtist(_ a: String) -> String {
        var s = a
        let seps = [" feat.", " feat ", " ft.", " ft ", " & ", ", ", " x ", " X ", " 、"]
        for sep in seps {
            if let r = s.range(of: sep, options: .caseInsensitive) {
                s = String(s[s.startIndex..<r.lowerBound])
            }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// 封面候选整合评分：歌名 + 歌手 + 专辑名 + 时长四路合计。
    ///
    /// 返回 -1 表示歌名不匹配（应排除）。调用方用 `artworkMinScore`(115)
    /// 阈值决定是否采纳：达不到线就保持占位图（无封面远好于错封面）。
    static func integratedScore(rTitle: String, rArtist: String,
                                rAlbum: String, rDurSec: Double,
                                eTitle: String, eArtist: String,
                                eAlbum: String, eDurSec: Double) -> Int {
        var total = trackArtistScore(rTitle: rTitle, rArtist: rArtist,
                                     eTitle: eTitle, eArtist: eArtist)
        guard total >= 0 else { return -1 }
        let pE = primaryArtist(eArtist), pR = primaryArtist(rArtist)
        if !pE.isEmpty, !pR.isEmpty,
           !pR.localizedCaseInsensitiveContains(pE) {
            total += artistMismatchPenalty
        }
        total += score(album: rAlbum, durSec: rDurSec, expAlbum: eAlbum, expDur: eDurSec)
        return total
    }

    /// 专辑 + 时长两项合计加分。任一侧信息缺失即该项不参与（返回 0），
    /// 避免用「没有专辑名」这种信息缺失去误伤本该命中的候选。
    static func score(album: String, durSec: Double,
                      expAlbum: String, expDur: Double) -> Int {
        score(album: album, durSec: durSec, expAlbum: expAlbum, expDur: expDur,
              norm: { norm($0) })
    }

    /// 注入归一化函数的重载，便于测试直接控制「繁简/标点」这层差异。
    static func score(album: String, durSec: Double,
                      expAlbum: String, expDur: Double,
                      norm: (String) -> String) -> Int {
        var total = 0
        total += albumScore(album: album, expAlbum: expAlbum, norm: norm)
        total += durationScore(candidate: durSec, expected: expDur)
        return total
    }

    /// 专辑名比对：全等加分 > 互相包含小幅加分 > 明确不同重罚。
    static func albumScore(album: String, expAlbum: String) -> Int {
        albumScore(album: album, expAlbum: expAlbum, norm: { norm($0) })
    }

    static func albumScore(album: String, expAlbum: String,
                           norm: (String) -> String) -> Int {
        let a = norm(album), e = norm(expAlbum)
        guard !a.isEmpty, !e.isEmpty else { return 0 }
        if a == e { return albumExactBonus }
        if a.contains(e) || e.contains(a) { return albumContainsBonus }
        return albumMismatchPenalty
    }

    /// 时长比对：分档而非线性，避免「差 0.5s」和「差 9s」被同等对待。
    static func durationScore(candidate: Double, expected: Double) -> Int {
        guard candidate > 0, expected > 0 else { return 0 }
        let diff = abs(candidate - expected)
        if diff <= durationTolerance { return durationExactBonus }
        if diff <= 5 { return durationNearBonus }
        if diff <= 10 { return durationLoosePenalty }
        return durationMismatchPenalty
    }

    // MARK: - 归一化

    /// 封面缓存键：歌名 + 歌手 + 专辑，三者归一化后拼接。
    ///
    /// 必须带专辑：同一首歌的录音室版与 Live 版歌名歌手完全相同，
    /// 少了专辑就会把两个版本的封面互相顶掉（正是本轮要修的错图根因）。
    /// 归一化保证繁简店铺的差异也落到同一个键上。
    static func cacheKey(title: String, artist: String, album: String) -> String {
        "\(norm(title))|\(norm(artist))|\(norm(album))"
    }

    /// 归一化：小写、去空白与标点，并统一繁简。
    ///
    /// 繁简必须处理：Apple 目录按店铺返回不同字形（tw/hk 返回繁体「神預言 袁婭維」，
    /// 而 Music 报的是简体「神预言 袁娅维」），不统一的话歌名直接判不匹配。
    static func norm(_ s: String) -> String {
        let lowered = s.lowercased()
        let stripped = lowered.replacingOccurrences(
            of: #"[\s\-_'’,.!?()\[\]（）【】/]+"#,
            with: "", options: .regularExpression
        )
        // 统一到简体再比：Hans-Hant 转换可用且稳定，两边都转即可对齐字形。
        return (stripped.applyingTransform(StringTransform("Hans-Hant"), reverse: true)) ?? stripped
    }
}
