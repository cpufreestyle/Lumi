import Foundation

/// 歌词时间轴一键对齐（纯逻辑，Foundation only，可进 LumiTests）。
///
/// 当前行匹配规则是 `adjustedTime = currentTime - offset`，要让被点击的行
/// 恰好成为当前行，必须满足 `line.time == adjustedTime`，解得：
/// `offset = currentTime - line.time = -delta`。
/// 这个符号非常容易写反（历史 bug：直接赋 delta，越点越歪），必须单测锁住。
enum LyricsAlignment {
    /// `delta = line.time - currentTime`。
    /// 返回值即应写入的 `lyricsOffset`：夹在 ±10s、四舍五入到 0.01s。
    static func offset(fromLineDelta delta: TimeInterval,
                       limit: ClosedRange<TimeInterval> = -10...10) -> TimeInterval {
        let clamped = min(max(delta, limit.lowerBound), limit.upperBound)
        return (-clamped * 100).rounded() / 100
    }
}
