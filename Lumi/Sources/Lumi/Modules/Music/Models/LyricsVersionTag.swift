import Foundation

/// 歌词版本标记识别（纯逻辑，Foundation only，可进 LumiTests）。
///
/// 为什么需要：社区歌词库对同一首歌常同时收录音音室版与 Live / Remastered /
/// 伴奏版，歌名完全相同，只有括号里的版本标记不同。各版本的时间轴往往差
/// 数秒甚至数十秒——《稻香》录音室版与 Live 版能差 40 秒以上。
/// 匹配算法若只看歌名（`contains` 判定），所有版本都算命中，选错版本必然
/// 「歌词和歌声不一致」，而且偏差大得离谱。
enum LyricsVersionTag {
    /// 版本标记的「同义族」：族内各写法视为**同一个**版本标记。
    ///
    /// 必须归并：网易云常标「现场」而 lrclib 标「Live」，若不归一，
    /// 同一版本的两种标注会被判成版本不符，反而把正确歌词罚掉。
    /// 每个族第一个元素是规范名，用于集合比较。
    static let groups: [[String]] = [
        ["live", "现场", "演唱会"],
        ["remaster", "remastered"],
        ["instrumental", "伴奏", "伴唱", "karaoke"],
        ["acoustic", "unplugged"],
        ["cover", "翻唱", "重唱"],
        ["deluxe", "bonus"],
        ["extended"],
        ["radio edit"],
        ["single version"],
        ["album version"],
        ["demo"],
        ["mandarin", "国语", "普通话"],
        ["cantonese", "粤语"],
        ["japanese", "日语"],
        ["matinee", "早场"],
    ]

    /// 扁平化的全部标记写法（供存在性判断使用）。
    static var tags: [String] { groups.flatMap { $0 } }

    /// 从标题中提取版本标记（可能多个，按出现顺序去重）。
    ///
    /// 只扫描「括号内」与「破折号后」的区域 —— 歌名正文里也可能出现这些词
    /// （例如《Live & Learn》），不能因为正文出现 live 就判定为版本标记。
    static func tags(in title: String) -> [String] {
        let lowered = title.lowercased()
        var found: [String] = []
        func record(_ text: String) {
            for group in groups {
                // 同一族只记规范名，保证「Live」与「现场」归一
                if group.contains(where: { text.contains($0) }) {
                    if !found.contains(group[0]) { found.append(group[0]) }
                }
            }
        }

        // 1) 括号 / 方括号内的片段（中英括号都算）
        let bracketRegex = #"[(\[（【][^)\]）】]*[)\]）】]"#
        if let re = try? NSRegularExpression(pattern: bracketRegex) {
            let ns = NSRange(lowered.startIndex..., in: lowered)
            re.enumerateMatches(in: lowered, range: ns) { m, _, _ in
                guard let m, let r = Range(m.range, in: lowered) else { return }
                record(String(lowered[r]).lowercased())
            }
        }

        // 2) 破折号后的后缀（" - Remastered" / " – Live"）
        if let dashRange = lowered.range(of: #"\s[-–—]\s"#, options: .regularExpression) {
            record(String(lowered[dashRange.upperBound...]))
        }

        return found
    }

    /// 标题是否带任何版本标记。
    static func hasTag(_ title: String) -> Bool {
        !tags(in: title).isEmpty
    }

    /// 两个标题的版本标记是否一致（都不带、或带的集合相同）。
    static func sameTags(_ a: String, _ b: String) -> Bool {
        let ta = Set(tags(in: a))
        let tb = Set(tags(in: b))
        return ta == tb
    }
}
