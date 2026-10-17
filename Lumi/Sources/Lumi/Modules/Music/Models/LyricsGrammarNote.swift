import Foundation

/// 歌词逐行语法注解请求构建与结果解析（纯逻辑，Foundation only，可进 LumiTests）。
///
/// 复刻 Musixmatch 语言学习付费档：用户点某行歌词的「注解」按钮，把该行原文
/// 发给 AIAssist 已配置的 OpenAI 兼容端点，拿到结构化的语法要点（主谓 / 时态 /
/// 固定搭配 / 生词）。本类型只负责 **buildPrompt** 与 **parseResponse**，
/// 网络请求复用 AIAssistController 的既有链路。
///
/// 纯逻辑独立成 enum 的原因：prompt 拼错一个字、解析漏一个字段，注解就会
/// 变成纯翻译（与已有双语功能重复）或直接空白，必须有测试锁住。
enum LyricsGrammarNote {

    /// 一条语法注解的结构化字段（解析 AI 回复的产物）。
    struct Note: Equatable {
        /// 语法要点（如「现在完成时表示对现在的影响」）。
        var point: String
        /// 关键词 / 短语（如「has been」「used to」），可为空。
        var keyPhrase: String?
        /// 简要例句（可选，AI 可能省略）。
        var example: String?
    }

    /// 为某行歌词构造 AI 请求的 system prompt。
    /// 要求 AI 只输出 JSON 数组（便于 parseResponse 严格解析）。
    static func systemPrompt(for line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        你是英语语法老师。对下面这句英文歌词给出 1-3 条语法注解，帮助中文学习者理解。
        只输出 JSON 数组，每条形如 {"point":"...","keyPhrase":"...","example":"..."}，
        keyPhrase 和 example 可省略。不要输出其他文字、不要 Markdown 代码块标记。
        歌词内容：\(trimmed)
        """
    }

    /// 从 AI 回复文本解析出注解列表；容忍 Markdown 代码块包裹、前后多余文字。
    /// 解析失败（完全非法 JSON）返回空数组。
    static func parseResponse(_ raw: String) -> [Note] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        // 剥掉 ```json ... ``` 或 ``` ... ``` 包裹
        let cleaned = stripMarkdownFence(text)
        guard let data = cleaned.data(using: .utf8) else { return [] }
        // 容忍 AI 输出单个对象（非数组）
        if let single = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let note = note(from: single) {
            return [note]
        }
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { note(from: $0) }
    }

    /// 从字典构造 Note；point 缺失视为整条无效（没有注解内容的空壳不值得显示）。
    private static func note(from dict: [String: Any]) -> Note? {
        guard let pointRaw = dict["point"] as? String,
              !pointRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let phrase = (dict["keyPhrase"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let example = (dict["example"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Note(
            point: pointRaw.trimmingCharacters(in: .whitespacesAndNewlines),
            keyPhrase: (phrase?.isEmpty == false) ? phrase : nil,
            example: (example?.isEmpty == false) ? example : nil
        )
    }

    /// 剥掉 Markdown 代码块包裹（```json ... ``` / ``` ... ```）。
    static func stripMarkdownFence(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            // 去掉首行（可能是 ```json 或 ```）
            if let firstNl = t.firstIndex(of: "\n") {
                t = String(t[t.index(after: firstNl)...])
            } else {
                return t
            }
        }
        if t.hasSuffix("```") {
            t = String(t.dropLast(3))
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
