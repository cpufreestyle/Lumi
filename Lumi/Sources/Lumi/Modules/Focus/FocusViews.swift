import SwiftUI

// MARK: - 番茄钟专注模块
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

    func startStop() {
        if isRunning {
            stopTimer()
        } else {
            isRunning = true
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

    /// 停止计时并清空结束时刻基准。
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        deadline = nil
        isRunning = false
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

// MARK: - 番茄钟视图
struct FocusExpandedView: View {
    @ObservedObject private var focus = FocusController.shared

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // 计时器圆环
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.1), lineWidth: 8)
                    .frame(width: 180, height: 180)

                Circle()
                    .trim(from: 0, to: focus.progress)
                    .stroke(
                        focus.isBreak
                            ? AnyShapeStyle(Color.green)
                            : AnyShapeStyle(AngularGradient(
                                colors: [Color.pink, Color.purple, Color.pink],
                                center: .center,
                                startAngle: .degrees(-90),
                                endAngle: .degrees(270)
                              )),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .frame(width: 180, height: 180)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.3), value: focus.progress)

                VStack(spacing: 4) {
                    Text(focus.timeString())
                        .font(.system(size: 38, weight: .thin, design: .monospaced))
                        .foregroundColor(.white)

                    Text(focus.modeLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(focus.isBreak ? .green.opacity(0.8) : .pink.opacity(0.8))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill((focus.isBreak ? Color.green : Color.pink).opacity(0.15))
                        )
                }
            }

            // 完成统计
            HStack(spacing: 20) {
                statItem(label: "已完成", value: "\(focus.completedSessions)")
                statItem(label: "今日专注", value: "\(focus.completedSessions * 25) 分钟")
            }
            .padding(.top, 24)

            // 控制按钮
            HStack(spacing: 24) {
                Button(action: { FocusController.shared.reset() }) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 16))
                        .foregroundColor(.white.opacity(0.6))
                }
                .buttonStyle(.plain)

                Button(action: { FocusController.shared.startStop() }) {
                    Image(systemName: focus.isRunning ? "pause.fill" : "play.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.white)
                        .frame(width: 56, height: 56)
                        .background(
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: focus.isBreak
                                            ? [Color.green, Color.mint]
                                            : [Color.pink, Color.purple],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        )
                }
                .buttonStyle(.plain)

                // 占位保持对称
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 16))
                    .foregroundColor(.clear)
            }
            .padding(.top, 16)

            Spacer()
        }
    }

    func statItem(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.45))
        }
    }
}

// MARK: - 专注收缩态
struct FocusBriefContent: View {
    @ObservedObject private var focus = FocusController.shared

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: focus.isRunning ? "timer" : "timer.circle")
                .font(.system(size: 12))
                .foregroundColor(focus.isRunning ? .pink : .white.opacity(0.5))
            Text(focus.isRunning ? "\(focus.timeString()) \(focus.modeLabel)" : "番茄钟 · 25 分钟")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.7))
        }
    }
}
