import Foundation

/// 统一轮询调度器。
///
/// **背景**：此前各模块各自 `Timer.scheduledTimer` 且常驻不停止——
/// 即使对应面板从未被打开，也周期性执行 AppleScript / 子进程 / EventKit 查询 / 磁盘 I/O，
/// 造成持续的 CPU 与能耗开销（其中一个模块的代码注释自述单次采集可达数百毫秒）。
///
/// **设计**：把「周期」与「当前是否真的需要执行」解耦。
/// - 注册方提供 `interval()`（动态间隔；返回 `<= 0` 表示当前无需执行）；
/// - 调度器只在至少一个任务需要执行时以较短间隔打拍；全部任务都不需要时退化为 5s 空闲拍，
///   避免无任何任务时仍高频空转；
/// - 任务从「不需要」变为「需要」时**立即**执行一次，避免面板刚打开还要等满一个周期才有数据。
///
/// **线程约定**：所有闭包均在主线程调用。耗时工作请自行派发到后台队列
/// （各模块的 action 内部已各自派发到 `scriptQueue` / `workQueue` 等专用队列）。
final class PollingCoordinator {
    static let shared = PollingCoordinator()

    // MARK: - 内部任务模型

    private final class TaskBox {
        let id: String
        /// 动态间隔；<= 0 表示当前不需要执行。
        let interval: () -> TimeInterval
        let action: () -> Void
        /// 自上次执行以来累计的时间
        var elapsed: TimeInterval = 0
        /// 上一拍是否处于「需要执行」状态，用于恢复时立即补一次
        var wasEnabled = false

        init(id: String,
             interval: @escaping () -> TimeInterval,
             action: @escaping () -> Void) {
            self.id = id
            self.interval = interval
            self.action = action
        }
    }

    private var tasks: [TaskBox] = []
    private var tickTimer: Timer?
    private var lastTick: Date?

    private init() {}

    // MARK: - 注册 / 注销

    /// 注册一个周期任务。同名 id 重复注册会被忽略（幂等）。
    /// - Parameters:
    ///   - id: 任务唯一标识（用于去重与注销）
    ///   - interval: 返回期望的执行间隔（秒）；`<= 0` 表示当前不需要执行
    ///   - action: 到点执行的动作，在主线程调用
    func register(id: String,
                  interval: @escaping () -> TimeInterval,
                  action: @escaping () -> Void) {
        onMain {
            guard !self.tasks.contains(where: { $0.id == id }) else { return }
            self.tasks.append(TaskBox(id: id, interval: interval, action: action))
            self.scheduleNextTick()
        }
    }

    func unregister(id: String) {
        onMain {
            self.tasks.removeAll { $0.id == id }
            self.scheduleNextTick()
        }
    }

    // MARK: - 调度

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    /// 依据「最紧急任务」的间隔决定下一次打拍时间，并在无需执行时降到空闲拍。
    private func scheduleNextTick() {
        tickTimer?.invalidate()
        tickTimer = nil

        let active = tasks.map { $0.interval() }.filter { $0 > 0 }
        let delay: TimeInterval
        if let minInterval = active.min() {
            // 打拍取最紧急间隔的一半，保证不会错过窗口；夹在 0.25s~1s 之间避免过度唤醒。
            delay = min(max(minInterval / 2, 0.25), 1.0)
        } else {
            // 没有任务需要执行：空闲拍，仅用于检测是否有任务恢复需要。
            delay = 5.0
        }

        // 用 .common 模式，避免滚动/拖拽等事件让定时器暂停。
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.tick()
            self?.scheduleNextTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func tick() {
        let now = Date()
        let delta = lastTick.map { now.timeIntervalSince($0) } ?? 0
        lastTick = now

        for task in tasks {
            let interval = task.interval()
            guard interval > 0 else {
                // 当前不需要执行：清零计时并标记为未启用，
                // 这样下次恢复需要时会立即补一次，而不是等满一个周期。
                task.elapsed = 0
                task.wasEnabled = false
                continue
            }
            if !task.wasEnabled {
                task.wasEnabled = true
                task.elapsed = 0
                task.action()
                continue
            }
            task.elapsed += delta
            if task.elapsed >= interval {
                task.elapsed = 0
                task.action()
            }
        }
    }
}
