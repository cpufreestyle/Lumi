import Foundation

/// 跳转位置写入 AppleScript 前的取值与格式化（纯逻辑，Foundation only，可测）。
///
/// 历史缺陷：seek/skip 都用 `Int()` 取整。拖进度条到 30.7s 实际跳到 30s，
/// 歌词锚点同步差最多 1 秒 —— 用户感知就是「歌词和歌声差一截」。
/// AppleScript 的 `set player position` 支持小数，没有理由丢精度。
enum MusicSeekFormat {
    /// 把目标位置夹到合法范围（负值传给 AppleScript 会静默失败）。
    static func clampedTarget(_ time: TimeInterval, duration: TimeInterval) -> TimeInterval {
        let upper = duration > 0 ? duration : .greatestFiniteMagnitude
        return min(max(time, 0), upper)
    }

    /// 格式化成 AppleScript 字面量。
    ///
    /// 必须固定 en_US_POSIX locale：在逗号小数分隔符的地区（德/法/西语等），
    /// `"\(30.7)"` 会插值成 `30,7`，直接破坏 AppleScript 语法导致跳转静默失败。
    static func scriptLiteral(_ time: TimeInterval) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), time)
    }
}
