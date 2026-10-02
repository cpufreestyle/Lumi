import Foundation

/// LRC 元数据解析（纯逻辑，Foundation only，可进 LumiTests）。
///
/// 社区 LRC 常带 `[offset:]` 全局时间轴偏移。LRC 约定：
/// - **正值表示歌词时间轴整体提前**（如 `[offset:500]` 提前 0.5s）
/// - 负值表示整体延后
///
/// 关于符号方向（极易搞反，务必按此理解）：
/// - 返回值本身保留原始符号：`[offset:500]` → `+0.5`，`[offset:-250]` → `-0.25`
/// - 消费方 `LRCParser` 对每行做 `time -= offset`：正值让每行时间变小 = 提前
/// - 因此「正值提前」在解析端体现为**减**，不要看到减号就以为是反的
///
/// 解析器如果丢弃该标签，整首歌都会与演唱错位——这正是“歌词和演唱不同步”的根因之一。
enum LRCMetadata {
    /// 提取 `[offset:]` 值并换算为秒（保留原始符号）。缺失 / 脏数据返回 0。
    /// 注意：这里**不做**符号翻转——翻转会让「正值提前」的含义消失。
    static func globalOffsetSeconds(_ raw: String) -> TimeInterval {
        let re = try? NSRegularExpression(
            pattern: #"\[offset:\s*([+-]?\d+(?:\.\d+)?)\s*\]"#,
            options: [.caseInsensitive]
        )
        guard let re else { return 0 }
        for line in raw.components(separatedBy: .newlines) {
            let text = line.trimmingCharacters(in: .whitespaces)
            let ns = NSRange(text.startIndex..., in: text)
            if let match = re.firstMatch(in: text, range: ns),
               let range = Range(match.range(at: 1), in: text),
               let milliseconds = Double(text[range]) {
                return milliseconds / 1000
            }
        }
        return 0
    }
}
