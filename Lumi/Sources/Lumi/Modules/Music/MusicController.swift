import SwiftUI
import AppKit

// MARK: - 音乐模块控制器（macOS 通过 AppleScript 控制 Apple Music）
final class MusicController: ObservableObject {
    static let shared = MusicController()

    @Published var title: String = ""
    @Published var artist: String = ""
    @Published var album: String = ""
    @Published var playbackState: PlaybackState = .stopped
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var artwork: NSImage? = nil
    @Published var lyrics: String = ""

    enum PlaybackState { case playing, paused, stopped }

    private var timer: Timer?
    private var lastTrackKey: String = ""

    private init() {
        startTimer()
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.fetchInfo()
        }
        fetchInfo()
    }

    // MARK: - AppleScript 执行
    private func runScript(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result: NSAppleEventDescriptor? = script.executeAndReturnError(&error)
        if let error = error {
            // 常见错误：Music 未运行 / 未授权 -> 忽略
            print("[Music] AppleScript: \(error)")
        }
        return result
    }

    // MARK: - 获取当前播放信息
    func fetchInfo() {
        let src = """
        tell application "Music"
            try
                set pState to (player state) as text
                if pState is "playing" or pState is "paused" then
                    set tName to (name of current track) as text
                    set tArtist to (artist of current track) as text
                    set tAlbum to (album of current track) as text
                    set tDur to (duration of current track) as text
                    set tPos to (player position) as text
                    set artFlag to ""
                    try
                        if exists artwork 1 of current track then set artFlag to "ART"
                    end try
                    return pState & "|" & tName & "|" & tArtist & "|" & tAlbum & "|" & tDur & "|" & tPos & "|" & artFlag
                else
                    return "stopped|||||0|0|"
                end if
            on error
                return "stopped|||||0|0|"
            end try
        end tell
        """

        guard let desc = runScript(src),
              let raw = desc.stringValue else { return }

        let parts = raw.components(separatedBy: "|")
        guard parts.count >= 7 else { return }

        let stateStr = parts[0]
        let newTitle = parts[1]
        let newArtist = parts[2]
        let newAlbum = parts[3]
        let newDuration = Double(parts[4]) ?? 0
        let newPosition = Double(parts[5]) ?? 0
        let hasArt = parts[6] == "ART"

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.title = newTitle
            self.artist = newArtist
            self.album = newAlbum
            self.duration = newDuration
            self.currentTime = newPosition
            switch stateStr {
            case "playing": self.playbackState = .playing
            case "paused":  self.playbackState = .paused
            default:        self.playbackState = .stopped
            }

            // 封面与歌词：仅在曲目变化时重新获取
            let artKey = "\(newTitle)-\(newArtist)"
            if artKey != self.lastTrackKey {
                self.lastTrackKey = artKey
                if hasArt {
                    self.fetchArtwork()
                } else {
                    self.artwork = nil
                }
                self.fetchLyrics()
            }
        }
    }

    private func fetchArtwork() {
        let src = """
        tell application "Music"
            try
                if exists artwork 1 of current track then
                    return data of artwork 1 of current track
                end if
            end try
            return ""
        end tell
        """
        guard let desc = runScript(src) else { return }
        let data = desc.data
        if !data.isEmpty, let img = NSImage(data: data) {
            DispatchQueue.main.async { [weak self] in self?.artwork = img }
        }
    }

    // MARK: - 歌词获取
    func fetchLyrics() {
        let src = """
        tell application "Music"
            try
                if (player state is playing) or (player state is paused) then
                    return lyrics of current track
                end if
            end try
            return ""
        end tell
        """
        guard let desc = runScript(src), let raw = desc.stringValue else { return }
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.main.async { [weak self] in self?.lyrics = cleaned }
    }

    // MARK: - 控制
    var isPlaying: Bool { playbackState == .playing }

    func togglePlayPause() {
        runScript("tell application \"Music\"\nplaypause\nend tell")
    }

    func nextTrack() {
        runScript("tell application \"Music\"\nnext track\nend tell")
        lastTrackKey = ""; artwork = nil
    }

    func previousTrack() {
        runScript("tell application \"Music\"\nprevious track\nend tell")
        lastTrackKey = ""; artwork = nil
    }

    func seek(to time: TimeInterval) {
        let t = Int(time)
        runScript("tell application \"Music\"\nset player position to \(t)\nend tell")
    }
}
