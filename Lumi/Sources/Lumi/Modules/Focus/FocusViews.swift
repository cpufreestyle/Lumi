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
            timer?.invalidate()
            isRunning = false
        } else {
            isRunning = true
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                if self.remainingTime > 0 {
                    self.remainingTime -= 1
                } else {
                    self.sessionComplete()
                }
            }
        }
    }

    func reset() {
        timer?.invalidate()
        isRunning = false
        if isBreak {
            remainingTime = shortBreakDuration
            totalTime = shortBreakDuration
        } else {
            remainingTime = workDuration
            totalTime = workDuration
        }
    }

    private func sessionComplete() {
        timer?.invalidate()
        isRunning = false

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
