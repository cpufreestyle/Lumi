import SwiftUI

final class FocusController: ObservableObject {
    static let shared = FocusController()

    @Published var remainingTime: TimeInterval = 25 * 60
    @Published var totalTime: TimeInterval = 25 * 60
    @Published var isRunning: Bool = false
    @Published var isBreak: Bool = false
    @Published var completedSessions: Int = 0
    @Published var modeLabel: String = "专注"

    private var timer: Timer?
    /// 当前阶段的结束时刻。改用「结束时刻」而非每秒减 1 计算剩余，避免累计漂移。
    private var deadline: Date?
    private let workDuration: TimeInterval = 25 * 60
    private let shortBreakDuration: TimeInterval = 5 * 60
    private let longBreakDuration: TimeInterval = 15 * 60
    private let sessionsBeforeLongBreak = 4

    var progress: Double {
        guard totalTime > 0 else { return 0 }
        return 1 - (remainingTime / totalTime)
    }

    // MARK: - 专注音乐联动

    /// 联动设置（@Published 驱动 Focus 面板内的设置区）。
    @Published var musicLink: FocusMusicLink = .load() {
        didSet { musicLink.save() }
    }

    /// 进入专注前的音乐快照；nil = 本次专注没有改过音乐。
    private struct MusicSnapshot {
        let wasPlaying: Bool
        let volume: Int
    }
    private var musicBeforeFocus: MusicSnapshot?

    /// 开始专注：若联动开启且 Music 正在运行，则（可选）切到指定歌单并压低到专注音量。
    /// Music 未运行时直接跳过——不为了联动而冷启动别的 App（项目约定：AppleScript 前查运行态）。
    private func applyFocusMusic() {
        guard musicLink.enabled else { return }
        let music = MusicController.shared
        guard music.isMusicRunning() else { return }
        let wasPlaying = music.isPlaying
        if !musicLink.playlist.isEmpty {
            music.playPlaylist(musicLink.playlist)
        } else if !wasPlaying {
            return // 没在播又没配歌单：不强行开播，联动只在「已在播放」时压低音量
        }
        musicBeforeFocus = MusicSnapshot(
            wasPlaying: wasPlaying,
            // volume 为 -1 表示尚未取到真实值，用专注音量兜底
            volume: music.volume >= 0 ? music.volume : FocusMusicLink.defaultFocusVolume
        )
        music.setVolume(musicLink.focusVolume)
    }

    /// 离开专注（自然完成 / 重置 / 手动停止都走 stopTimer）后恢复音乐。
    private func restoreMusicAfterFocus() {
        guard let snapshot = musicBeforeFocus else { return }
        musicBeforeFocus = nil
        let music = MusicController.shared
        switch FocusMusicLink.restorePlayback(wasPlayingBeforeFocus: snapshot.wasPlaying) {
        case .resume:
            music.setVolume(snapshot.volume)   // 保持播放，恢复音量
        case .pause:
            music.pauseIfPlaying()             // 专注前没在播：停掉我们开起来的声音
        }
    }

    func startStop() {
        if isRunning {
            stopTimer()
        } else {
            isRunning = true
            applyFocusMusic()
            // 以「结束时刻」为基准：计时不受定时器实际触发时刻影响，
            // 也不会因系统睡眠/卡顿而走慢（恢复后直接跳到正确的剩余时间）。
            deadline = Date().addingTimeInterval(remainingTime)
            let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.refreshRemaining()
            }
            // .common 模式：滚动/拖拽等事件跟踪模式下定时器不会被暂停
            // （与 PollingCoordinator 的做法一致）。
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    /// 按结束时刻刷新剩余时间；到点则结束当前阶段。
    private func refreshRemaining() {
        guard let deadline = deadline else { return }
        let left = deadline.timeIntervalSinceNow
        if left <= 0 {
            remainingTime = 0
            sessionComplete()
        } else {
            remainingTime = left
        }
    }

    /// 停止计时并清空结束时刻基准。停止即「离开专注」：统一在这里恢复音乐，
    /// 使自然完成（sessionComplete）与手动停止（startStop/reset）行为一致。
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        deadline = nil
        isRunning = false
        restoreMusicAfterFocus()
    }

    func reset() {
        stopTimer()
        if isBreak {
            remainingTime = shortBreakDuration
            totalTime = shortBreakDuration
        } else {
            remainingTime = workDuration
            totalTime = workDuration
        }
    }

    private func sessionComplete() {
        stopTimer()

        if isBreak {
            // 休息结束，进入工作
            isBreak = false
            modeLabel = "专注"
            remainingTime = workDuration
            totalTime = workDuration
        } else {
            // 工作结束
            completedSessions += 1

            if completedSessions % sessionsBeforeLongBreak == 0 {
                isBreak = true
                modeLabel = "长休息"
                remainingTime = longBreakDuration
                totalTime = longBreakDuration
            } else {
                isBreak = true
                modeLabel = "短休息"
                remainingTime = shortBreakDuration
                totalTime = shortBreakDuration
            }
        }
    }

    func timeString() -> String {
        let m = Int(remainingTime) / 60
        let s = Int(remainingTime) % 60
        return String(format: "%02d:%02d", m, s)
    }
}
