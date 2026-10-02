import SwiftUI

struct FocusExpandedView: View {
    @ObservedObject private var focus = FocusController.shared

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // 计时器圆环
            ZStack {
                Circle()
                    .stroke(PanelInk.chip(0.1), lineWidth: 8)
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
                        .foregroundColor(PanelInk.primary)

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
                        .foregroundColor(PanelInk.text(0.6))
                }
                .buttonStyle(.plain)

                Button(action: { FocusController.shared.startStop() }) {
                    Image(systemName: focus.isRunning ? "pause.fill" : "play.fill")
                        .font(.system(size: 24))
                        .foregroundColor(PanelInk.control)
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

            // 专注音乐联动设置
            musicLinkSection
                .padding(.top, 20)

            Spacer()
        }
    }

    // MARK: 专注音乐联动设置区
    var musicLinkSection: some View {
        VStack(spacing: 8) {
            Toggle("专注时播放背景音乐", isOn: Binding(
                get: { focus.musicLink.enabled },
                set: { focus.musicLink.enabled = $0 }
            ))
            .toggleStyle(.switch)
            .tint(.pink)
            .font(.system(size: 11))
            .foregroundColor(PanelInk.text(0.75))

            if focus.musicLink.enabled {
                TextField("歌单名（留空则不切换）", text: Binding(
                    get: { focus.musicLink.playlist },
                    set: { focus.musicLink.playlist = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .frame(width: 170)

                HStack(spacing: 8) {
                    Image(systemName: "speaker.fill")
                        .font(.system(size: 9))
                        .foregroundColor(PanelInk.text(0.4))
                    Slider(
                        value: Binding(
                            get: { Double(focus.musicLink.focusVolume) },
                            set: { focus.musicLink.focusVolume = FocusMusicLink.clampVolume(Int($0)) }
                        ),
                        in: 0...100,
                        step: 5
                    )
                    .tint(.pink)
                    .frame(width: 90)
                    Text("\(focus.musicLink.focusVolume)%")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(PanelInk.text(0.5))
                        .frame(width: 32, alignment: .trailing)
                }
                Text("开始时压低音量，结束后恢复")
                    .font(.system(size: 9))
                    .foregroundColor(PanelInk.text(0.3))
            }
        }
    }

    func statItem(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(PanelInk.primary)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(PanelInk.text(0.45))
        }
    }
}
