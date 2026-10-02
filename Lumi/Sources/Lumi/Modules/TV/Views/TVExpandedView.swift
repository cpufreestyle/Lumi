import SwiftUI

/// 电视遥控面板：调用本机 ATV Remote 开源服务（`http://127.0.0.1:8300`）。
///
/// 布局刻意做成「一屏能按完」：面板默认 360×480，方向键、播放、音量、输入、宏、应用
/// 都在一个纵向滚动区里，常用操作不必翻页。画面（artwork）只在 Apple TV 已连接时出现，
/// 未连接/未选设备时把版面让给扫描与连接引导，避免大片空白。
struct TVExpandedView: View {
    @ObservedObject private var tv = TVController.shared
    @State private var draftText: String = ""
    @State private var sendWithEnter: Bool = true
    @State private var showSettings: Bool = false
    @State private var draftBaseURL: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header

                if !tv.status.serviceReachable {
                    serviceDownHint
                } else if !tv.status.hasDevice {
                    devicePicker
                } else {
                    if let artwork = tv.artwork {
                        artworkCard(artwork)
                    }
                    dpadSection
                    playbackSection
                    volumeSection
                    textSection
                    if !tv.presets.isEmpty { macrosSection }
                    if !tv.apps.isEmpty { appsSection }
                    timerSection
                    deviceFooter
                }

                if tv.showSettings { settingsSection }

                footer
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
        }
        .onAppear { tv.activate() }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "tv.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(PanelInk.pink)
            Text("电视遥控")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(PanelInk.primary)
            Spacer()
            if tv.isBusy {
                ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
            }
            Button {
                tv.showSettings.toggle()
            } label: {
                Image(systemName: "gear")
                    .font(.system(size: 12))
                    .foregroundColor(PanelInk.text(tv.showSettings ? 0.9 : 0.55))
            }
            .buttonStyle(.plain)
            .help("服务地址")
            Button {
                tv.activate()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .foregroundColor(PanelInk.text(0.55))
            }
            .buttonStyle(.plain)
            .help("刷新状态")
        }
    }

    // MARK: 服务未启动

    private var serviceDownHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("连不上 ATV Remote 服务", systemImage: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(PanelInk.text(0.85))
            Text("本模块通过调用本机开源的 ATV Remote 服务来遥控电视（Lumi 不自己实现电视协议）。启动方式：")
                .font(.system(size: 10))
                .foregroundColor(PanelInk.text(0.5))
                .fixedSize(horizontal: false, vertical: true)
            Text("cd ~/atv-remote && bash start.sh")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(PanelInk.text(0.35))
            Text("装过 LaunchAgent 的话它应开机自启；若改了端口，点右上角齿轮把地址改成实际值。")
                .font(.system(size: 10))
                .foregroundColor(PanelInk.text(0.35))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(PanelInk.chip(0.04)))
    }

    // MARK: 设备选择

    private var devicePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("还没有选择设备")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(PanelInk.text(0.85))

            if !tv.status.appleTVs.isEmpty {
                Text("已保存的 Apple TV")
                    .font(.system(size: 10))
                    .foregroundColor(PanelInk.text(0.45))
                ForEach(tv.status.appleTVs) { device in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(device.displayName)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(PanelInk.text(0.9))
                            Text(device.ip)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(PanelInk.text(0.35))
                        }
                        Spacer()
                        Button("连接") { tv.connectAppleTV(id: device.id) }
                            .buttonStyle(TVCompactButtonStyle(tint: .pink))
                    }
                    .padding(.vertical, 3)
                }
            }

            HStack(spacing: 8) {
                Button {
                    tv.scanAppleTVs()
                } label: {
                    Label("扫描局域网", systemImage: "dot.radiowaves.left.and.right")
                }
                .buttonStyle(TVCompactButtonStyle(tint: .purple))
                Spacer()
            }

            if !tv.scanResults.isEmpty {
                Text("扫描结果")
                    .font(.system(size: 10))
                    .foregroundColor(PanelInk.text(0.45))
                ForEach(tv.scanResults) { device in
                    HStack(spacing: 8) {
                        Text(device.displayName)
                            .font(.system(size: 12))
                            .foregroundColor(PanelInk.text(0.85))
                        Text(device.paired == true ? "已配对" : "未配对")
                            .font(.system(size: 9))
                            .foregroundColor(device.paired == true ? .green.opacity(0.8) : .orange.opacity(0.8))
                        Spacer()
                        Button("连接") { tv.connectAppleTV(id: device.id) }
                            .buttonStyle(TVCompactButtonStyle(tint: .pink))
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(PanelInk.chip(0.04)))
    }

    // MARK: 画面

    private func artworkCard(_ image: NSImage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .frame(height: 150)
                .clipped()
                .cornerRadius(10)
            HStack {
                Text(tv.status.keyboardFocus == "Focused" ? "电视端输入框已聚焦" : "Apple TV 当前画面")
                    .font(.system(size: 9))
                    .foregroundColor(PanelInk.text(0.3))
                Spacer()
            }
        }
    }

    // MARK: 方向键

    private var dpadSection: some View {
        HStack(spacing: 14) {
            dpad
            VStack(spacing: 8) {
                remoteButton(.menu)
                remoteButton(.home)
                remoteButton(.controlCenter)
                remoteButton(.powerTurnOff)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// 3×3 方向键：上下左右在四边中央，正中间是 OK。
    /// 用 Grid 而不是绝对定位，改按钮尺寸时不必重算偏移。
    private var dpad: some View {
        Grid {
            GridRow {
                Color.clear.frame(width: 40, height: 40)
                remoteButton(.up)
                Color.clear.frame(width: 40, height: 40)
            }
            GridRow {
                remoteButton(.left)
                remoteButton(.select)
                remoteButton(.right)
            }
            GridRow {
                Color.clear.frame(width: 40, height: 40)
                remoteButton(.down)
                Color.clear.frame(width: 40, height: 40)
            }
        }
        .fixedSize()
    }

    private func remoteButton(_ code: TVKeyCode) -> some View {
        Button {
            tv.sendKey(code)
        } label: {
            Image(systemName: code.symbol)
                .font(.system(size: code == .select ? 20 : 15, weight: .semibold))
                .foregroundColor(PanelInk.text(code == .select ? 0.95 : 0.8))
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: code == .select ? 20 : 10)
                        .fill(code == .select ? Color.pink.opacity(0.28) : PanelInk.chip(0.08))
                )
        }
        .buttonStyle(.plain)
        .help(code.title)
    }

    // MARK: 播放控制

    private var playbackSection: some View {
        HStack(spacing: 10) {
            wideButton(.previous)
            wideButton(.playPause, tint: .pink)
            wideButton(.next)
        }
        .frame(maxWidth: .infinity)
    }

    private var volumeSection: some View {
        HStack(spacing: 10) {
            wideButton(.volumeDown)
            wideButton(.volumeUp)
            wideButton(.sleep)
        }
        .frame(maxWidth: .infinity)
    }

    private func wideButton(_ code: TVKeyCode, tint: Color = .white) -> some View {
        Button {
            tv.sendKey(code)
        } label: {
            Image(systemName: code.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(code == .playPause ? .white : tint.opacity(0.85))
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 9).fill(
                        code == .playPause ? Color.pink.opacity(0.55) : PanelInk.chip(0.07)
                    )
                )
        }
        .buttonStyle(.plain)
        .help(code.title)
    }

    // MARK: 文本输入

    private var textSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("发送文字到电视")
                .font(.system(size: 10))
                .foregroundColor(PanelInk.text(0.45))
            HStack(spacing: 8) {
                TextField("搜索词 / 密码", text: $draftText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(PanelInk.primary)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 8).fill(PanelInk.chip(0.07)))
                    .onSubmit { tv.sendText(draftText, enter: sendWithEnter) }
                Toggle("回车", isOn: $sendWithEnter)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .fixedSize()
                Button {
                    tv.sendText(draftText, enter: sendWithEnter)
                    draftText = ""
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 12))
                        .foregroundColor(PanelInk.text(0.85))
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.pink.opacity(0.5)))
                }
                .buttonStyle(.plain)
                .help("发送")
            }
        }
    }

    // MARK: 宏

    private var macrosSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("一键宏")
                    .font(.system(size: 10))
                    .foregroundColor(PanelInk.text(0.45))
                Spacer()
                if tv.status.macroRunning {
                    Button("停止") { tv.cancelMacro() }
                        .buttonStyle(TVCompactButtonStyle(tint: .red))
                }
            }
            // 预设宏直接来自服务端（`GET /api/macros`），上游加宏这里立刻有
            TVFlowLayout(spacing: 6) {
                ForEach(tv.presets) { macro in
                    Button {
                        tv.runPreset(macro)
                    } label: {
                        Text("\(macro.icon) \(macro.displayName)")
                            .font(.system(size: 11))
                            .foregroundColor(PanelInk.text(0.85))
                            .padding(.horizontal, 8)
                            .frame(height: 26)
                            .background(
                                RoundedRectangle(cornerRadius: 8).fill(PanelInk.chip(0.07))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: 应用

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("电视上的应用")
                    .font(.system(size: 10))
                    .foregroundColor(PanelInk.text(0.45))
                Spacer()
                Button {
                    tv.refreshApps()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundColor(PanelInk.text(0.45))
                }
                .buttonStyle(.plain)
                .help("刷新应用列表")
            }
            TVFlowLayout(spacing: 6) {
                ForEach(tv.apps) { app in
                    Button {
                        tv.launchApp(app.id)
                    } label: {
                        Text(app.displayName)
                            .font(.system(size: 11))
                            .foregroundColor(PanelInk.text(0.8))
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .frame(height: 26)
                            .background(
                                RoundedRectangle(cornerRadius: 8).fill(PanelInk.chip(0.06))
                            )
                    }
                    .buttonStyle(.plain)
                    .help(app.id)
                }
            }
        }
    }

    // MARK: 睡眠定时 / 设备

    private var timerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("睡眠定时")
                .font(.system(size: 10))
                .foregroundColor(PanelInk.text(0.45))
            HStack(spacing: 6) {
                ForEach([15, 30, 60], id: \.self) { minutes in
                    Button("\(minutes) 分") { tv.setSleepTimer(minutes: minutes) }
                        .buttonStyle(TVCompactButtonStyle(tint: .purple))
                }
                if tv.status.sleepTimerActive {
                    Text("剩 \(tv.status.sleepTimerRemaining / 60) 分 \(tv.status.sleepTimerRemaining % 60) 秒")
                        .font(.system(size: 10))
                        .foregroundColor(.pink.opacity(0.9))
                    Button("取消") { tv.cancelSleepTimer() }
                        .buttonStyle(TVCompactButtonStyle(tint: .red))
                }
            }
        }
    }

    private var deviceFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().background(PanelInk.chip(0.1))
            HStack(spacing: 8) {
                Text(tv.status.summaryLine)
                    .font(.system(size: 10))
                    .foregroundColor(PanelInk.text(0.45))
                Spacer()
                Button("断开") { tv.disconnect() }
                    .buttonStyle(TVCompactButtonStyle(tint: .white))
            }
        }
    }

    // MARK: 设置

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ATV Remote 服务地址")
                .font(.system(size: 10))
                .foregroundColor(PanelInk.text(0.45))
            HStack(spacing: 6) {
                TextField(TVController.defaultBaseURL, text: $draftBaseURL)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(PanelInk.primary)
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 8).fill(PanelInk.chip(0.07)))
                Button("保存") {
                    tv.baseURLString = draftBaseURL
                }
                .buttonStyle(TVCompactButtonStyle(tint: .pink))
                Button("默认") {
                    draftBaseURL = TVController.defaultBaseURL
                    tv.baseURLString = ""
                }
                .buttonStyle(TVCompactButtonStyle(tint: .white))
            }
            Text("只有本机访问（127.0.0.1）时该服务免令牌；换端口或换机器部署才需要改这里。")
                .font(.system(size: 9))
                .foregroundColor(PanelInk.text(0.3))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(PanelInk.chip(0.04)))
        .onAppear { draftBaseURL = tv.baseURLString }
    }

    // MARK: 底部

    private var footer: some View {
        HStack {
            Text("由本机 ATV Remote 服务驱动 · 指令不离开本机")
                .font(.system(size: 9))
                .foregroundColor(PanelInk.text(0.3))
            Spacer()
            if let last = tv.lastRefreshDate {
                Text(timeString(last))
                    .font(.system(size: 9))
                    .foregroundColor(PanelInk.text(0.3))
            }
        }
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}

// MARK: - 小按钮样式

/// 面板里的次级按钮（连接 / 扫描 / 定时）：等比缩放、不抢主操作视觉。
struct TVCompactButtonStyle: ButtonStyle {
    var tint: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(tint.opacity(configuration.isPressed ? 0.6 : 0.9))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 7).fill(
                    tint.opacity(configuration.isPressed ? 0.18 : 0.10)
                )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

// MARK: - 流式布局

/// 简单流式布局：子视图放不下时自动换行。
///
/// SwiftUI 没有内置的 FlowRow，`Layout` 协议（macOS 13+）自己实现一个够用的版本即可。
/// 只按「子视图自身理想尺寸」横向堆叠、行高取该行最大值——正是一排等高按钮
/// （宏 / 应用）需要的语义，不需要处理对齐基线。
struct TVFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let dims = subview.dimensions(in: .unspecified)
            let size = CGSize(width: dims.width, height: dims.height)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                        subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let dims = subview.dimensions(in: .unspecified)
            let size = CGSize(width: dims.width, height: dims.height)
            // 行首不留间距：否则每行会比上一行缩进一个 spacing
            if x > bounds.minX, x + size.width > bounds.minX + bounds.width {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
