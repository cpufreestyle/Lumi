import Foundation

/// 「一行内自带双语」的识别与拆分（纯逻辑，Foundation only，可进 LumiTests）。
///
/// 支持的分隔形态：`原文 / 翻译`、`原文 (翻译)`、`原文【翻译】`、`原文：翻译`。
///
/// 之所以独立成文件：中文歌词里冒号极常见（「他说：你好吗」），而原实现只要
/// 一侧含拉丁字母就判定双语 —— 实测「CD机：播这首歌」被误拆成
/// 原文=CD机 / 译文=播这首歌，**原文前半被当译文丢掉**。这类误拆直接改变
/// 逐行高亮的内容，用户看到的就是歌词和歌声对不上。
enum BilingualSplit {

    /// 是否含 CJK（中日韩统一表意 + 假名 + 谚文）。
    static func hasCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { scalar in
            let v = scalar.value
            return (0x4E00...0x9FFF).contains(v)
                || (0x3400...0x4DBF).contains(v)
                || (0x3040...0x309F).contains(v)
                || (0x30A0...0x30FF).contains(v)
                || (0xAC00...0xD7AF).contains(v)
        }
    }

    /// 是否含拉丁字母（ASCII A–Z / a–z）。
    ///
    /// 只用 ASCII 区间，不用 `CharacterSet.letters.subtracting(...)`：
    /// 后者会把带重音字符、希腊字母等也算进来，边界难以推理。
    static func hasLatin(_ s: String) -> Bool {
        s.unicodeScalars.contains { scalar in
            let v = scalar.value
            return (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v)
        }
    }

    /// 校验两侧是否确为「不同语言的对照」。
    ///
    /// 关键约束：**至少一侧必须是以 CJK 为主体**。这样「CD机：播这首歌」
    /// （原侧 CJK+拉丁混合、译侧纯中文）不会被判成双语 —— 两侧都是中文，
    /// 只是前半夹了个英文词，属于同一句话而非对照翻译。
    static func validate(_ original: String, _ translated: String)
        -> (text: String, translation: String)? {
        guard !original.isEmpty, !translated.isEmpty else { return nil }
        // 两侧不能完全相同
        guard original != translated else { return nil }
        let oCJK = hasCJK(original), oLat = hasLatin(original)
        let tCJK = hasCJK(translated), tLat = hasLatin(translated)
        // 语言构成必须真的不同（一侧中文一侧拉丁）
        guard (oCJK != tCJK) || (oLat != tLat) else { return nil }
        guard (oCJK || oLat), (tCJK || tLat) else { return nil }
        // 必须有一侧是「纯中文」（含中文且不含拉丁），另一侧是「纯拉丁」。
        //
        /// 这样才能同时满足：
        /// - 「你好 / Hello」：中文侧纯中文 ✓ → 拆
        /// - 「Hello / 你好」：中文侧纯中文 ✓ → 拆
        /// - 「CD机：播这首歌」：两侧都含中文，没有纯拉丁侧 ✗ → 不拆
        ///   （这是实测误判：原文前半 CD机 被当译文丢掉）
        /// - 「他说：你好吗」：两侧都纯中文 ✗ → 不拆
        let pureChinese: (Bool, Bool) -> Bool = { cjk, latin in cjk && !latin }
        let pureLatin: (Bool, Bool) -> Bool = { cjk, latin in latin && !cjk }
        let originalPureChinese = pureChinese(oCJK, oLat)
        let translatedPureChinese = pureChinese(tCJK, tLat)
        let originalPureLatin = pureLatin(oCJK, oLat)
        let translatedPureLatin = pureLatin(tCJK, tLat)
        let isChineseLatinPair = (originalPureChinese && translatedPureLatin)
            || (originalPureLatin && translatedPureChinese)
        guard isChineseLatinPair else { return nil }
        return (original, translated)
    }
}
