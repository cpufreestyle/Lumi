import SwiftUI

// MARK: - 主内容视图（收缩/展开/悬停预览）
struct ContentView: View {
    @ObservedObject private var state = AppState.shared

    var body: some View {
        Group {
            if state.isExpanded {
                ExpandedView()
            } else if state.isHovering {
                PeekView()
            } else {
                CollapsedView()
            }
        }
        .background(WindowAccessor())
        .onHover { inside in
            AppState.shared.isHovering = inside
        }
    }
}

// MARK: - 悬停预览态：胶囊 + 模块预览
struct PeekView: View {
    @ObservedObject private var state = AppState.shared

    var body: some View {
        VStack(spacing: 0) {
            PeekPreviewContent()
                .frame(maxHeight: .infinity)
            CollapsedView()
                .padding(.bottom, 6)
        }
    }
}

struct PeekPreviewContent: View {
    @ObservedObject private var state = AppState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(state.activeModule.rawValue, systemImage: state.activeModule.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))

            switch state.activeModule {
            case .music:          MusicPeekView()
            case .calendar:       Text("今日日程预览").font(.system(size: 11)).foregroundColor(.white.opacity(0.55))
            case .focus:          Text("专注计时").font(.system(size: 11)).foregroundColor(.white.opacity(0.55))
            case .clipboard:      Text("最近复制内容").font(.system(size: 11)).foregroundColor(.white.opacity(0.55))
            case .liveDetection:  Text("环境连接检测").font(.system(size: 11)).foregroundColor(.white.opacity(0.55))
            case .claudeCode:     Text("AI 编程助手 · 问答/解释/调试").font(.system(size: 11)).foregroundColor(.white.opacity(0.55))
            case .codex:          Text("代码解释 · 优化 · Bug 查找 · 测试生成").font(.system(size: 11)).foregroundColor(.white.opacity(0.55))
            case .videoDownload:  Text("支持 1800+ 站点 · MP4/MP3 下载").font(.system(size: 11)).foregroundColor(.white.opacity(0.55))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }
}

// MARK: - 音乐悬停预览
struct MusicPeekView: View {
    @ObservedObject private var music = MusicController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(music.title.isEmpty ? "未在播放" : music.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
            Text(music.artist.isEmpty ? "打开音乐 App" : music.artist)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.55))
                .lineLimit(1)
            if music.duration > 0 {
                ProgressView(value: min(1, music.currentTime / music.duration))
                    .progressViewStyle(LinearProgressViewStyle(tint: Color.pink))
                    .frame(height: 4)
            }
        }
    }
}

// MARK: - 收缩态：胶囊条
struct CollapsedView: View {
    @ObservedObject private var state = AppState.shared

    var body: some View {
        HStack(spacing: 0) {
            // 左侧：当前模块图标
            moduleIconView
                .padding(.leading, 14)

            Spacer()

            // 中间：简要信息
            moduleBriefView
                .padding(.horizontal, 8)

            Spacer()

            // 右侧：模块切换小点
            moduleDotsView
                .padding(.trailing, 14)
        }
        .frame(height: 42)
        .background(
            RoundedRectangle(cornerRadius: 21)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 21)
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                )
        )
        .shadow(color: .black.opacity(0.3), radius: 15, y: 5)
        .onTapGesture {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                AppState.shared.isExpanded = true
            }
        }
    }

    var moduleIconView: some View {
        Image(systemName: state.activeModule.icon)
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.white)
            .frame(width: 26, height: 26)
            .background(
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.pink, Color.purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
    }

    @ViewBuilder
    var moduleBriefView: some View {
        switch state.activeModule {
        case .music:
            MusicBriefView()
        case .calendar:
            CalendarBriefView()
        case .focus:
            FocusBriefView()
        case .clipboard:
            ClipboardBriefView()
        case .liveDetection:
            LiveDetectionBriefView()
        case .claudeCode:
            Text("🧠 问 Claude 任何编程问题").font(.system(size: 12)).foregroundColor(.white.opacity(0.7))
        case .codex:
            Text("✨ 代码解释 · 优化 · 补全").font(.system(size: 12)).foregroundColor(.white.opacity(0.7))
        case .videoDownload:
            Text("⬇ 视频下载 MP4/MP3").font(.system(size: 12)).foregroundColor(.white.opacity(0.7))
        }
    }

    var moduleDotsView: some View {
        HStack(spacing: 5) {
            ForEach(AppModule.allCases) { mod in
                Circle()
                    .fill(
                        state.activeModule == mod
                            ? Color.pink
                            : Color.white.opacity(0.25)
                    )
                    .frame(
                        width: state.activeModule == mod ? 8 : 5,
                        height: state.activeModule == mod ? 8 : 5
                    )
                    .animation(.spring(), value: state.activeModule)
            }
        }
    }
}

// MARK: - 展开态：完整面板
struct ExpandedView: View {
    @ObservedObject private var state = AppState.shared
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // 顶部标签栏
                TabBarView()

                // 模块内容
                moduleContentView
                    .frame(maxHeight: .infinity)

                // 底部拖拽指示器
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 32, height: 3)
                    .padding(.bottom, 8)
            }
            .frame(width: 360, height: 480)
            .background(
                RoundedRectangle(cornerRadius: 22)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22)
                            .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                    )
            )
            .shadow(color: .black.opacity(0.4), radius: 25, y: 8)
            .gesture(
                DragGesture()
                    .onChanged { v in
                        if v.translation.height > 30 {
                            dragOffset = v.translation.height
                        }
                    }
                    .onEnded { v in
                        if v.translation.height > 60 {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                                AppState.shared.isExpanded = false
                            }
                            // 收缩后通知窗口收回尺寸
                            NotificationCenter.default.post(name: .islandDidCollapse, object: nil)
                        }
                        dragOffset = 0
                    }
            )

            // 许可证管理面板
            if state.showLicensePanel {
                licensePanelOverlay
            }
        }
        .offset(y: dragOffset)
        .animation(.easeInOut(duration: 0.25), value: state.showLicensePanel)
        .onAppear {
            // 展开时通知窗口调整大小
            NotificationCenter.default.post(name: .islandDidExpand, object: nil)
        }
    }

    // 许可证面板浮层
    var licensePanelOverlay: some View {
        ZStack {
            Color.black.opacity(0.5)
                .cornerRadius(22)
                .onTapGesture {
                    state.showLicensePanel = false
                }

            LicensePanelView()
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                        )
                )
                .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
    }

    @ViewBuilder
    var moduleContentView: some View {
        ZStack {
            switch state.activeModule {
            case .music:
                MusicExpandedView()
            case .calendar:
                CalendarExpandedView()
            case .focus:
                FocusExpandedView()
            case .clipboard:
                ClipboardExpandedView()
            case .liveDetection:
                LiveDetectionExpandedView()
            case .claudeCode:
                ClaudeCodeExpandedView()
            case .codex:
                CodexExpandedView()
            case .videoDownload:
                VideoDownloadExpandedView()
            }

            // 付费功能锁定遮罩
            if state.activeModule.isPremium && !state.canAccessActiveModule {
                PremiumLockOverlay(module: state.activeModule)
            }
        }
    }
}

// MARK: - 顶部标签栏
struct TabBarView: View {
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var license = LicenseManager.shared

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppModule.allCases) { mod in
                Button(action: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                        state.activeModule = mod
                    }
                    // 点击付费模块时弹出许可证面板
                    if mod.isPremium,
                       let feature = mod.premiumFeature,
                       !license.isUnlocked(feature) {
                        state.showLicensePanel = true
                    }
                }) {
                    VStack(spacing: 3) {
                        ZStack {
                            Image(systemName: mod.icon)
                                .font(.system(size: 15))
                            if mod.isPremium, let feature = mod.premiumFeature, !license.isUnlocked(feature) {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 7))
                                    .foregroundColor(.orange)
                                    .offset(x: 7, y: -6)
                            }
                        }
                        Text(mod.shortName)
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundColor(state.activeModule == mod ? .pink : .white.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }

            // 右侧：隐藏整个界面（鼠标移到顶部可重新出现入口）
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    AppState.shared.islandEnabled = false
                }
            }) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                    .padding(7)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("隐藏界面（鼠标移到顶部可重新出现入口）")
            .padding(.trailing, 4)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)

        // 底部分隔线
        Rectangle()
            .fill(Color.white.opacity(0.1))
            .frame(height: 0.5)
            .padding(.horizontal, 16)
    }
}

// MARK: - 各模块收缩态简要视图（占位）
struct MusicBriefView: View { var body: some View { MusicBriefContent() } }
struct CalendarBriefView: View { var body: some View { Text("📅 今日 3 项日程").font(.system(size: 12)).foregroundColor(.white.opacity(0.7)) } }
struct FocusBriefView: View { var body: some View { FocusBriefContent() } }
struct ClipboardBriefView: View { var body: some View { Text("📋 12 条记录").font(.system(size: 12)).foregroundColor(.white.opacity(0.7)) } }
struct LiveDetectionBriefView: View { var body: some View { LiveDetectionBriefContent() } }

// MARK: - 窗口大小通知辅助
extension Notification.Name {
    static let islandDidExpand = Notification.Name("islandDidExpand")
    static let islandDidCollapse = Notification.Name("islandDidCollapse")
}

/// 获取窗口引用
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            _ = view.window
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - 付费功能锁定遮罩
struct PremiumLockOverlay: View {
    let module: AppModule
    @ObservedObject private var license = LicenseManager.shared
    @ObservedObject private var state = AppState.shared

    var body: some View {
        ZStack {
            // 毛玻璃效果背景
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.6))

            VStack(spacing: 16) {
                // 锁图标
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(
                        LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )

                VStack(spacing: 6) {
                    Text("此功能需要激活")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)

                    if let feature = module.premiumFeature {
                        Text(feature.description)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.55))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30)
                    }
                }

                VStack(spacing: 10) {
                    // 试用按钮
                    Button(action: {
                        license.startTrial()
                    }) {
                        Text("免费试用 7 天")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 180)
                            .padding(.vertical, 10)
                            .background(
                                LinearGradient(colors: [Color.pink, Color.purple], startPoint: .leading, endPoint: .trailing)
                            )
                            .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                    .disabled(license.status != .unlicensed)

                    // 激活按钮
                    Button(action: {
                        state.showLicensePanel = true
                    }) {
                        Text("输入激活码")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                            .frame(width: 180)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                }

                // 试用状态提示
                if case .trial(let days) = license.status {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 10))
                        Text("试用剩余 \(days) 天")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                }
            }
        }
        .cornerRadius(22)
    }
}

// MARK: - 许可证管理面板
struct LicensePanelView: View {
    @ObservedObject private var license = LicenseManager.shared
    @ObservedObject private var state = AppState.shared
    @State private var activationKey: String = ""
    @FocusState private var isKeyFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // 标题
            HStack {
                Text("激活 Lumi")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                Spacer()
                Button(action: { state.showLicensePanel = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)

            // 当前状态
            licenseStatusCard
                .padding(.horizontal, 16)

            Divider()
                .background(Color.white.opacity(0.1))
                .padding(.vertical, 12)

            // 功能列表
            VStack(alignment: .leading, spacing: 8) {
                Text("付费功能")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.horizontal, 16)

                ForEach(PremiumFeature.allCases) { feature in
                    HStack(spacing: 10) {
                        Image(systemName: feature.icon)
                            .font(.system(size: 12))
                            .foregroundColor(license.isUnlocked(feature) ? .green : .white.opacity(0.35))
                            .frame(width: 18)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(feature.rawValue)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white)
                            Text(feature.description)
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.4))
                        }

                        Spacer()

                        if license.isUnlocked(feature) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.green)
                        } else {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.orange)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            Divider()
                .background(Color.white.opacity(0.1))
                .padding(.vertical, 12)

            // 激活码输入
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    TextField("LUMI-XXXX-XXXX-XXXX-XXXX", text: $activationKey)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(10)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(8)
                        .focused($isKeyFocused)
                        .onChange(of: activationKey) { newVal in
                            // 自动格式化
                            let uppered = newVal.uppercased()
                            if uppered != newVal {
                                activationKey = uppered
                            }
                        }

                    if license.isActivating {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 20, height: 20)
                    }
                }
                .padding(.horizontal, 16)

                if let error = license.activationError {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundColor(.red.opacity(0.8))
                        .padding(.horizontal, 16)
                }

                Button(action: {
                    license.activate(with: activationKey)
                }) {
                    Text("验证激活码")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            activationKey.count >= 19
                                ? AnyShapeStyle(LinearGradient(colors: [Color.pink, Color.purple], startPoint: .leading, endPoint: .trailing))
                                : AnyShapeStyle(Color.white.opacity(0.1))
                        )
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .disabled(activationKey.count < 19 || license.isActivating)
            }

            // 试用按钮
            if case .unlicensed = license.status {
                Button(action: { license.startTrial() }) {
                    Text("开始 7 天免费试用")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.pink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.pink.opacity(0.1))
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        }
        .padding(.bottom, 14)
        .frame(width: 360)
    }

    @ViewBuilder
    var licenseStatusCard: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon)
                .font(.system(size: 24))
                .foregroundColor(statusColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Text(statusSubtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
            }

            Spacer()
        }
        .padding(12)
        .background(Color.white.opacity(0.04))
        .cornerRadius(12)
    }

    var statusIcon: String {
        switch license.status {
        case .unlicensed: return "lock.shield"
        case .trial:      return "clock.badge.checkmark"
        case .licensed:   return "checkmark.shield"
        case .lifetime:   return "crown.fill"
        }
    }

    var statusColor: Color {
        switch license.status {
        case .unlicensed: return .orange
        case .trial:      return .blue
        case .licensed:   return .green
        case .lifetime:   return .yellow
        }
    }

    var statusTitle: String {
        switch license.status {
        case .unlicensed:                    return "未激活"
        case .trial(let days):               return "试用中"
        case .licensed(let expiry):          return "已激活"
        case .lifetime:                      return "永久许可"
        }
    }

    var statusSubtitle: String {
        switch license.status {
        case .unlicensed:
            return "激活后解锁全部高级功能"
        case .trial(let days):
            return "试用剩余 \(days) 天，到期后需激活继续使用"
        case .licensed(let expiry):
            if let date = expiry {
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd"
                return "有效期至 \(f.string(from: date))"
            }
            return "已激活"
        case .lifetime:
            return "永久有效，畅享全部功能"
        }
    }
}
