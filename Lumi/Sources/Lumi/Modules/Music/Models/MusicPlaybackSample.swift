import Foundation

/// 判定 Music 返回的播放位置能否覆盖本地补间位置。
///
/// AppleScript 的回调偶尔会比主线程上的补间位置晚几十毫秒，直接采用会让歌词
/// 闪回上一行；但用户在 Music 中手动往回拖动时，位置会明显回退，必须立即采用。
/// 两种情况不能共用“所有回退都忽略”的策略，否则歌词会一直停在拖动前的位置。
enum MusicPlaybackSample {
    /// 小于此值的回退视为异步采样滞后，而非用户跳转。
    static let staleBacktrackTolerance: TimeInterval = 0.15

    /// 超过此值的回退视为明确的用户 seek，立即重置歌词时间轴。
    /// 留出 0.5 秒的中间带，避免繁忙时的偶发排队延迟被误判为跳转。
    static let seekBacktrackThreshold: TimeInterval = 0.65

    static func shouldAccept(sampledPosition: TimeInterval,
                             previousPosition: TimeInterval?,
                             isSameTrackPlaying: Bool) -> Bool {
        guard isSameTrackPlaying, let previousPosition else { return true }
        let backtrack = previousPosition - sampledPosition
        guard backtrack > staleBacktrackTolerance else { return true }
        return backtrack >= seekBacktrackThreshold
    }

    /// 补间锚点该用哪个时刻。
    ///
    /// 采用真值时锚点必须取 `sampledAt`（AppleScript 里 `player position` 真正被读到的
    /// 那一刻）；拒绝陈旧采样时锚点必须取 `mainThreadAt`（结果到达主线程的时刻）。
    ///
    /// 为什么拒绝分支不能用 `sampledAt`：那一刻保留的是插值终点
    /// `lastCommittedPosition`（已经含读点到主线程之间的排队耗时），而 `sampledAt`
    /// 是更早就过去的读点。若仍用 `sampledAt` 作锚点，排队时间会被
    /// `sampledPosition + elapsed` 再算一次 —— 每次拒绝都把时钟多推进一次排队耗时，
    /// 音频没变快，歌词却整体超前。以本仓库实测为例：排队 30ms 量级时，单次拒绝
    /// 即可注入约 0.6s 超前（约 13 行歌词）。
    ///
    /// 函数化是为了进 LumiTests：这条「锚点必须和保留的位置同刻」的规则肉眼几乎看不出来
    /// （歌词只是整体偏快，不像抖动那样一眼可辨），必须有用例锁住。
    static func anchorTime(sampledAt: Date,
                           mainThreadAt: Date,
                           accepted: Bool) -> Date {
        accepted ? sampledAt : mainThreadAt
    }
}
