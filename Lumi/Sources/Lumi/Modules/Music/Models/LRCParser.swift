import Foundation

/// LRC 歌词解析器（纯逻辑，Foundation only，可进 LumiTests）。
///
/// 之所以独立于 MusicController：解析规则决定逐行高亮是否生效——时间戳解析错
/// 一位小数/丢 [offset:] 元数据，歌词就会整体错位。必须有回归测试锁住。
enum LRCParser {
    // MARK: - 预编译正则

    /// 整行结构：行首一个或多个 [mm:ss.xx] 时间戳 + 正文。
    /// 第 5 组是正文（第 2/3/4 组是首个时间戳的分/秒/小数，兼容旧调用）。
    private static let lineRegex = try? NSRegularExpression(
        pattern: #"^(\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?\])+(.*)$"#
    )

    /// 行首的时间戳前缀（可能多个，用于确定「哪些字符属于时间轴区域」）。
    private static let prefixRegex = try? NSRegularExpression(
        pattern: #"^(?:\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?\])+"#
    )

    /// 单个时间戳，仅在前缀范围内枚举——正文里的「10:15」不是时间轴。
    private static let timestampRegex = try? NSRegularExpression(
        pattern: #"\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?\]"#
    )

    /// 把 LRC 文本解析为 (秒, 文本) 行。`[offset:]` 元数据按 LRC 约定应用到每行。
    ///
    /// 三个正则都是预编译的静态属性：每行都要跑一遍，现场编译会让一首 60 行的
    /// 歌做 180 次 NSRegularExpression 构造，而这发生在**写回主线程**的路径上
    /// （用户切歌后歌词出现的延迟组成部分）。
    static func parse(_ raw: String) -> [(time: TimeInterval, text: String)] {
        let lrcOffset = LRCMetadata.globalOffsetSeconds(raw)
        var out: [(time: TimeInterval, text: String)] = []
        for line in raw.components(separatedBy: .newlines) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let regex = lineRegex else { continue }
            let ns = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, range: ns),
                  let bodyRange = Range(match.range(at: 5), in: text) else { continue }
            let body = String(text[bodyRange]).trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { continue }

            // LRC 允许一行挂多个时间戳（[00:01][00:05]副歌），
            // 同一段文本要在两个时间点各出现一次，否则第二个时间点会缺行。
            // 只在行首的 LRC 前缀里找时间戳：正文里「10:15」「3.14」这类时间/数字
            // 不是时间轴，把正文数字当时间戳会插入错行并扰乱逐行高亮。
            guard let prefixRegex,
                  let timestampRegex,
                  let prefixMatch = prefixRegex.firstMatch(in: text,
                                                           range: NSRange(text.startIndex..., in: text)),
                  prefixMatch.range.location == 0,
                  prefixMatch.range.length > 0 else { continue }
            timestampRegex.enumerateMatches(in: text, range: prefixMatch.range) { m, _, _ in
                guard let m,
                      let minuteRange = Range(m.range(at: 1), in: text),
                      let secondRange = Range(m.range(at: 2), in: text),
                      let minute = Int(text[minuteRange]),
                      let second = Int(text[secondRange]) else { return }
                let msText = Range(m.range(at: 3), in: text).map { String(text[$0]) } ?? ""
                let divisor = pow(10.0, Double(msText.count))
                let ms = (Double(msText) ?? 0) / (divisor > 1 ? divisor : 1000)
                // 整数秒与小数分开组装：先把整个整数部分算成 Double，
                // 再一次加上小数、减去全局偏移。串行的
                //（秒 + 小数 - 偏移）在大量行上会累积浮点尾差，
                // 而同一首歌里这些尾差足以让相邻行的高亮边界抖动几十微秒。
                let wholeSeconds = Double(minute * 60 + second)
                out.append(((wholeSeconds + ms) - lrcOffset, body))
            }
        }
        // 按时间排序。必须用**稳定排序**：同一歌曲的多行常有相同时间戳
        // （同刻多语言行、合唱行），若用不稳定排序，相同 time 的行相对顺序
        // 会随输入变化而乱 —— 直接破坏「同刻取第一行」的稳定性，
        // 表现为同一首歌不同次加载高亮行不一样。
        // Swift 标准库的 sorted(by:) 本身即稳定排序，此处显式
        // 用 (time, 原始序号) 双键，语义更明确也防止未来改成不稳定实现。
        return out.enumerated()
            .sorted { lhs, rhs in
                lhs.element.time == rhs.element.time
                    ? lhs.offset < rhs.offset
                    : lhs.element.time < rhs.element.time
            }
            .map { $0.element }
    }
}
