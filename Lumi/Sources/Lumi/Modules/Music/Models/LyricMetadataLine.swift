import Foundation

/// LRC 制作信息行的识别（纯逻辑，Foundation only，可进 LumiTests）。
///
/// 这些行不是歌词，显示出来既碍眼又挤占时间轴位置——用户感知就是
/// 「歌词行数不对、对不上歌声」。网易云 LRC 用全角冒号 + 中文标签，
/// 欧美 LRC 用半角冒号 + 英文标签（Written by: / Composer: ...），
/// 两种都必须覆盖。
enum LyricMetadataLine {

    /// 行首的 LRC 元信息标签（如 `[by:署名]`）。
    private static let lrcTags = ["[by:", "[ti:", "[ar:", "[al:", "[offset:", "[re:", "[length:", "[au:", "[ve:"]

    /// 中文署名标签（网易云常见）。
    private static let chineseLabels: Set<String> = [
        "作词", "作曲", "作词人", "作曲人", "编曲", "制作人", "制作", "词", "曲", "演唱", "歌手",
        "专辑", "发行", "录音师", "录音室", "录音", "混音", "混音师", "混音工程师",
        "混音录音室", "母带", "母带处理", "后期", "和声", "合声", "弦乐", "鼓", "贝斯",
        "吉他", "钢琴", "键盘", "编程", "企划", "监制", "出品", "版权", "出版商", "出版",
        "设计", "美术", "摄影", "感谢", "特别感谢", "原唱", "翻唱", "填词", "谱曲", "配唱",
        // 网易云在曲末追加的完整制作名单，实测《如初之光》莫文蔚 就有
        // 「和声编写 : Lisa Djaati」「混音室 : Horus Studio」两个标签原表里没有，
        // 漏掉会让它们作为歌词行高亮（用户看到「和声编写」被当成正在唱的一句）。
        "和声编写", "和声配唱", "混音室", "混音录音棚", "录音棚", "录音工程师",
        "母带工程师", "母带室", "编程师", "配唱制作", "配唱制作人", "人声录音",
        "人声录音师", "人声编辑", "弦乐编写", "鼓手", "贝斯手", "吉他手", "钢琴手",
        "监制工程师", "出品公司", "发行公司", "版权公司", "OP", "SP",
    ]

    /// 英文署名标签（欧美 LRC 常见，小写比较）。
    private static let englishLabels: Set<String> = [
        "written by", "writer", "words by", "lyrics by", "lyricist",
        "composer", "composed by", "music by", "music", "melody",
        "arranger", "arranged by", "arrangement",
        "producer", "produced by", "production",
        "engineer", "engineered by", "mixed by", "mixing", "mix",
        "mastered by", "mastering", "master",
        "studio", "recorded at", "recorded in", "recording",
        "guitar", "guitars", "bass", "drums", "piano", "keyboards", "keys",
        "strings", "violin", "cello", "saxophone", "trumpet",
        "background vocals", "backing vocals", "vocals", "featuring", "feat",
        "publisher", "label", "copyright", "artwork", "design", "photo",
    ]

    /// 是否是制作信息行。
    static func isMetadata(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        // 1) 行首 LRC 元信息标签
        let lower = trimmed.lowercased()
        for tag in lrcTags where lower.hasPrefix(tag) { return true }
        // 2) 「标签：值」形态。冒号取**第一个**，兼容半角与全角
        guard let colonRange = trimmed.rangeOfCharacter(
            from: CharacterSet(charactersIn: ":\u{FF1A}")) else { return false }
        let label = String(trimmed[trimmed.startIndex..<colonRange.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return false }
        // 标签里含空白/过长的基本是正常歌词句（「他说：你好吗」的前段是句子）
        guard label.count <= 20 else { return false }
        if chineseLabels.contains(label) { return true }
        if englishLabels.contains(label.lowercased()) { return true }
        return false
    }
}
