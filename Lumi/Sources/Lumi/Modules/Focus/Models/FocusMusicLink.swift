import Foundation

/// 专注 × 音乐联动（番茄钟开始自动播放背景音并压低音量，结束恢复）。
///
/// 拆成两层：本文件只做纯逻辑与持久化（可单测）；
/// 副作用（AppleScript 控制 Music）在 `FocusController` / `MusicController`。
struct FocusMusicLink: Equatable {
    /// 是否开启联动。
    var enabled: Bool
    /// 专注时要播放的歌单名（空 = 不切歌单，仅在已在播放时压低音量）。
    var playlist: String
    /// 专注音量 0...100，比常用音量低，避免盖过思路。
    var focusVolume: Int

    static let defaultEnabled = true
    static let defaultPlaylist = ""
    static let defaultFocusVolume = 35

    static let `default` = FocusMusicLink(
        enabled: Self.defaultEnabled,
        playlist: Self.defaultPlaylist,
        focusVolume: Self.defaultFocusVolume
    )

    /// 最新鲜的坑：`UserDefaults.integer` 取不到键时返回 0，
    /// 与「用户真的把音量设为 0」无法区分，必须先查 object。
    private enum Key {
        static let enabled  = "lumi_focus_music_enabled"
        static let playlist = "lumi_focus_playlist"
        static let volume   = "lumi_focus_music_volume"
    }

    static func load(from defaults: UserDefaults = .standard) -> FocusMusicLink {
        FocusMusicLink(
            enabled: defaults.object(forKey: Key.enabled) as? Bool ?? Self.defaultEnabled,
            playlist: (defaults.string(forKey: Key.playlist) ?? Self.defaultPlaylist)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            focusVolume: defaults.object(forKey: Key.volume) as? Int ?? Self.defaultFocusVolume
        )
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Key.enabled)
        defaults.set(playlist.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.playlist)
        defaults.set(Self.clampVolume(focusVolume), forKey: Key.volume)
    }

    /// 音量钳制到 Music.app 的 0...100。
    static func clampVolume(_ value: Int) -> Int {
        min(max(value, 0), 100)
    }

    /// 专注结束时的恢复决策：
    /// - 专注前本就没在播（音乐是我们为专注开起来的）→ 停掉，不擅自继续出声；
    /// - 原本在播 → 保持播放并恢复原音量（歌单可能已切换走，无法可靠还原原曲目，
    ///   这是已知取舍：宁可错在曲目，不可错在「结束时突然没声」或「突然出声」）。
    static func restorePlayback(wasPlayingBeforeFocus: Bool) -> RestorePlayback {
        wasPlayingBeforeFocus ? .resume : .pause
    }

    enum RestorePlayback: Equatable {
        case resume
        case pause
    }
}
