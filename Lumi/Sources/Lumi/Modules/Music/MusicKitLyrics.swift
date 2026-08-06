import Foundation
import MusicKit

/// 一条带时间轴的歌词行（来自 Apple Music 同步歌词 / lrclib 的 syncedLyrics）。
struct SyncedLine {
    let text: String
    /// 该行起始时间（秒）。无时间信息时留 -1，UI 退化为纯文本展示。
    let time: TimeInterval
}

/// Apple Music 授权探测工具。
///
/// 重要现实约束：macOS 的 MusicKit（含 macOS 26 SDK）**并不暴露逐行/带时间轴的歌词数据**
/// —— `Song` 仅有 `hasLyrics: Bool`，没有 `lyrics` 属性，也没有 `Lyrics`/`LyricLine` 类型。
/// 真正的「Apple Music 风格带时间轴歌词」来自 lrclib 的 `syncedLyrics` 字段
/// （社区从 Apple Music 扒取的逐行时间轴歌词），由 `MusicController` 解析后交给 UI 高亮。
///
/// 本文件仅负责在启动时请求「媒体与 Apple Music」授权（用于探测用户是否拥有 Apple Music，
/// 以及满足系统隐私合规），歌词内容本身走 lrclib 同步歌词。
enum MusicKitLyricsProvider {

    /// 当前授权状态（macOS 上为 `MusicAuthorization.currentStatus`）。
    static var currentStatus: MusicAuthorization.Status {
        MusicAuthorization.currentStatus
    }

    /// 请求 Apple Music 授权（需在 UI 主线程调用，会弹出系统授权窗）。
    /// 已授权或已决定过时直接返回当前状态。
    @MainActor
    static func ensureAuthorized() async -> MusicAuthorization.Status {
        if currentStatus == .notDetermined {
            return await MusicAuthorization.request()
        }
        return currentStatus
    }
}
