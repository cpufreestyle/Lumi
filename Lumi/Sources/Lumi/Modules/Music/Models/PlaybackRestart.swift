import Foundation

/// 「同一首歌从头重播」的判定（纯逻辑，Foundation only，可进 LumiTests）。
///
/// 为什么需要它：切歌判定用的是 `title-artist` 组合。用户点重播、或一首歌
/// 播放完自动回到开头时，曲目标识**不变**，于是切歌分支不触发 —— 歌词、
/// 防抖状态、校准偏移全都停留在上一轮，直接从旧位置接着渲染，观感就是
/// 「重播时歌词和歌声不一致」。
enum PlaybackRestart {
    /// 上一拍位置至少要这么靠后，才算「明显在播后面」而不是前奏抖动。
    static let previousPositionThreshold: TimeInterval = 5
    /// 本轮位置要落到这个时刻之前，才算「回到了开头」。
    static let beginningThreshold: TimeInterval = 2

    static func isRestartFromBeginning(trackChanged: Bool,
                                       title: String,
                                       previousPosition: TimeInterval?,
                                       sampledPosition: TimeInterval,
                                       isPlaying: Bool) -> Bool {
        // 已经判定为切歌：交给切歌分支，不需要重播判定
        guard !trackChanged else { return false }
        // 空标题说明 Music 停了（AppleScript 返回 stopped|||||0|0）
        guard !title.isEmpty else { return false }
        guard isPlaying else { return false }
        guard let previous = previousPosition else { return false }
        // 上一拍明显靠后，本轮却回到开头：这才是「重播」而不是正常播放微抖动
        return previous > previousPositionThreshold
            && sampledPosition < beginningThreshold
    }
}
