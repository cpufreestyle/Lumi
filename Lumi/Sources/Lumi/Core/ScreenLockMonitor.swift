import AppKit

// MARK: - 锁屏 / 离开工位检测
/// 纯事件驱动的「用户离开工位」检测，用于在锁屏、屏保、显示器睡眠、系统睡眠时
/// 自动暂停音乐。**不做任何轮询**（符合项目约定：外部状态优先用通知而非提高频率）。
///
/// 事件源：
/// - `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked`：
///   macOS 未公开但长期稳定的分布式通知（loginwindow 发出），是唯一能可靠捕获
///   「主动锁屏」（⌃⌘Q / 菜单锁定）的途径；屏保与睡眠不靠它。
/// - `NSWorkspace.screensDidSleepNotification`：屏保触发 / 显示器进入睡眠。
/// - `NSWorkspace.willSleepNotification`：系统整体睡眠（合盖等）。
final class ScreenLockMonitor {
    static let shared = ScreenLockMonitor()

    private var observers: [NSObjectProtocol] = []
    private var started = false

    private init() {}

    /// 幂等启动。重复调用无副作用（AppState 单例生命周期内只需一次）。
    func start() {
        guard !started else { return }
        started = true

        let center = DistributedNotificationCenter.default()
        let names = ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"]
        for name in names {
            let locked = name.hasSuffix("screenIsLocked")
            observers.append(center.addObserver(
                forName: NSNotification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in
                self?.handle(away: locked)
            })
        }

        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.handle(away: true) })
        observers.append(ws.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.handle(away: true) })
    }

    /// `away = true` 表示用户刚离开；`false` 表示刚回来。
    /// 回来时**不自动恢复播放**：解锁瞬间突然出声是明确负体验，
    /// 且用户离开期间可能已切到别的音源。恢复交给用户自己点一次。
    private func handle(away: Bool) {
        guard away else { return }
        guard AppState.shared.pauseOnScreenLock else { return }
        MusicController.shared.pauseIfPlaying()
    }
}
