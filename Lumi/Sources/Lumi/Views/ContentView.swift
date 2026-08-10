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
        // 内容严格填满窗口，不留额外边距，避免圆角外露出多余的透明矩形外框
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 命中区域裁剪为圆角形状：透明的四个直角不再响应 hover / 点击。
        // 只改命中区域、不用 clipShape，以免把内容自带的 .shadow 一并裁掉。
        // 注意：hover 命中只挂在收缩态胶囊(CollapsedView)上，不挂在整个窗口，
        // 否则鼠标只是靠近顶部热区、尚未碰到岛本身就会展开预览。
        .contentShape(RoundedRectangle(cornerRadius: state.isExpanded ? 22 : 21))
        .background(WindowAccessor())
    }
}

// MARK: - 悬停预览态：胶囊紧贴动态岛 + 预览内容向下延伸
struct PeekView: View {
    @ObservedObject private var state = AppState.shared

    var body: some View {
        VStack(spacing: 0) {
            // 胶囊紧贴动态岛（顶部），作为从动态岛延伸出去的起点
            CollapsedView()
            // 预览内容从胶囊向下延伸出去，不分离
            PeekPreviewContent()
                .frame(maxHeight: .infinity)
        }
        // 鼠标在预览面板（132 高）内移动时，即便离开内部胶囊条也不要收起；
        // 由这里统一维持 isHovering=true，离开整个面板才切回收缩态。
        .contentShape(RoundedRectangle(cornerRadius: 21))
        .onHover { inside in
            AppState.shared.isHovering = inside
        }
    }
}

struct PeekPreviewContent: View {
    @ObservedObject private var state = AppState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch state.activeModule {
            case .music:          MusicPeekView()
            case .calendar:       Text("今日日程预览").font(.system(size: 11)).foregroundColor(.white.opacity(0.55))
            case .focus:          Text("专注计时").font(.system(size: 11)).foregroundColor(.white.opacity(0.55))
            case .clipboard:      Text("最近复制内容").font(.system(size: 11)).foregroundColor(.white.opacity(0.55))
            case .liveDetection:  Text("环境连接检测").font(.system(size: 11)).foregroundColor(.white.opacity(0.55))
            case .claudeCode:     Text("AI 编程助手 · 问答/解释/调试").font(.system(size: 11)).foregroundColor(.white.opacity(0.55))
            case .codex:          Text("代码解释 · 优化 · Bug 查找 · 测试生成").font(.system(size: 11)).foregroundColor(.white.opacity(0.55))
            case .videoDownload:  Text("支持 1800+ 站点 · MP4/MP3 下载").font(.system(size: 11)).foregroundColor(.white.opacity(0.55))
            case .game:           Text("TapTap H5 小游戏").font(.system(size: 11)).foregroundColor(.white.opacity(0.55))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - 音乐悬停预览
struct MusicPeekView: View {
    @ObservedObject private var music = MusicController.shared

    var body: some View {
        VStack(alignment: .center, spacing: 5) {
            Text(music.title.isEmpty ? "未在播放" : music.title)
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(.red)
                .shadow(color: .black.opacity(0.7), radius: 3, x: 0, y: 1)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)
            Text(music.artist.isEmpty ? "打开音乐 App" : music.artist)
                .font(.system(size: 18))
                .foregroundColor(.red)
                .shadow(color: .black.opacity(0.7), radius: 3, x: 0, y: 1)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)
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
    @ObservedObject private var music = MusicController.shared

    /// 胶囊固定高度，跟随 AppState.capsuleSize.height（可由用户调节）。
    static var capsuleHeight: CGFloat { AppState.shared.capsuleSize.height }

    var body: some View {
        // 双语上下并排：原文（上，红） + 译文（下，青）。无译文时只显示一行原文。
        // 高度完全由内容决定：单行就单行高，双行就双行高，绝不浪费空间、绝不裁切译文。
        // 用户设定的 capsuleSize.height 仅作单行时的最小高度兜底。
        VStack(alignment: .center, spacing: AppState.shared.lyricLineSpacing) {
            if state.activeModule == .music, music.playbackState == .playing {
                MarqueeText(
                    text: lyricLine,
                    font: .system(size: 22, weight: .medium),
                    textColor: .red,
                    speed: 40,
                    pause: 1.2
                )
                .frame(maxWidth: .infinity, alignment: .center)
                // 双语模式且译文就绪：紧贴下方追加青色译文行（上下并排成组）
                if music.bilingualMode != .off {
                    let tr = music.currentTranslationText
                    if !tr.isEmpty {
                        MarqueeText(
                            text: tr,
                            font: .system(size: 16, weight: .regular),
                            textColor: .cyan,
                            speed: 36,
                            pause: 1.2
                        )
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .offset(state.lyricOffset)
        .frame(maxWidth: .infinity)
        // 单行时高度回落到用户设定下限（避免歌名过扁）；双行时内容自然撑高，不裁切。
        // 高度由内容居中填充整个胶囊：无论 capsuleSize.height 怎么调，歌词都垂直居中，
        // 底部不留固定空白（移除原 .padding(.bottom,14)，否则胶囊越高底部越空）。
        .frame(minHeight: Self.capsuleHeight, alignment: .center)
        // 拖拽缩放胶囊宽/高时，用轻量弹簧让内容与窗口平滑跟手（更丝滑）。
        .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.85), value: state.capsuleSize)
        // 收缩态黑岛：纯黑无缝矩形（圆角），与真刘海同宽同高，
        // 不画描边/阴影（否则会在刘海接缝处露出"双层黑"，破坏融为一体的观感）。
        .background(
            RoundedRectangle(cornerRadius: 18).fill(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0.0),
                        .init(color: .black, location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        )
        // 只有鼠标真正进入收缩黑岛（物理岛高度那条）才标记 isHovering，
        // 从而展开预览；整窗 onHover 会在靠近顶部热区时误触发，所以不挂在那里。
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onHover { inside in
            AppState.shared.isHovering = inside
        }
        // 双击重置歌词偏移（长按拖移调节后一键归位）
        .onTapGesture(count: 2) {
            AppState.shared.resetLyricOffset()
        }
        // 单击展开面板（调节态下不触发，避免误触）
        .onTapGesture(count: 1) {
            if AppState.shared.isTuningLyric { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                AppState.shared.isExpanded = true
            }
        }
        // 长按进入「歌词微调」态，之后拖移实时改变歌词位置；松手退出并保存。
        .gesture(
            LongPressGesture(minimumDuration: 0.35)
                .onEnded { _ in
                    tuneBase = AppState.shared.lyricOffset
                    AppState.shared.isTuningLyric = true
                }
                .simultaneously(with: DragGesture()
                    .onChanged { v in
                        guard AppState.shared.isTuningLyric else { return }
                        let raw = CGSize(
                            width: tuneBase.width + v.translation.width,
                            height: tuneBase.height + v.translation.height
                        )
                        // 钳制偏移，确保歌词始终落在胶囊内部
                        AppState.shared.lyricOffset = AppState.shared.clampLyricOffset(raw)
                    }
                    .onEnded { _ in
                        AppState.shared.isTuningLyric = false
                    }
                )
        )
        // 调节态提示条：让用户知道当前在拖移微调，双击可重置。
        .overlay(alignment: .top) {
            if state.isTuningLyric {
                Text("拖移调整歌词位置 · 双击重置")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.6)))
                    .padding(.top, 6)
            }
        }
        // 右下角：尺寸拖拽手柄 + （常驻时）取消固定按钮，水平并排，互不冲突、不影响居中歌词。
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 2) {
                if state.islandPinned {
                    Button(action: {
                        AppState.shared.islandPinned = false
                    }) {
                        Image(systemName: "pin.slash.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("取消固定（鼠标移开即收起）")
                }
                CapsuleResizeHandle()
            }
            .padding(5)
        }
    }

    /// 拖移微调时的偏移基准（长按进入时记录，拖动在此基础上累加）。
    @State private var tuneBase: CGSize = .zero

    /// 胶囊岛内展示的歌词行：优先同步歌词当前行，缺失时回退到歌名。
    private var lyricLine: String {
        music.currentLineText.isEmpty ? music.title : music.currentLineText
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
        case .game:
            GameBriefView()
        }
    }

}

// MARK: - 展开态：完整面板
struct ExpandedView: View {
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var updater = Updater.shared
    // 插件面板数据在 PluginPanelBridge.shared 上，需直接观察才能随轮询刷新
    @ObservedObject private var pluginPanels = PluginPanelBridge.shared
    @State private var dragOffset: CGFloat = 0
    /// 展开爆开动画：从刘海（顶部）缩放弹入，模仿 NotchAI「砰」地长出来的感觉
    @State private var appear = false

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // 顶部标签栏
                TabBarView()

                // 更新状态/操作已收敛到收缩态刘海黑岛，
                // 展开态面板顶部不再保留黑色状态条，保持面板顶部简洁。

                // 模块内容占满剩余高度（不整体包 ScrollView，否则音乐/游戏等
                // 依赖撑满高度的视图在 ScrollView 内会塌缩为 0 高度导致空白）。
                // 插件区放在模块下方，固定高度上限、内部自行滚动。
                moduleContentView
                    .frame(maxHeight: .infinity)

                // 底部拖拽指示器
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 32, height: 3)
                    .padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 22)
                    .fill(.ultraThinMaterial)
                    .overlay(Color.black.opacity(0.85))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22)
                            .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 22))
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

            // 右下角手动缩放手柄：拖拽调整展开面板大小（尺寸持久化记忆）
            ResizeHandle()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(6)

            // 许可证管理面板
            if state.showLicensePanel {
                licensePanelOverlay
            }

            // 歌词与胶囊设置弹层
            if state.showLyricTuning {
                LyricTuningPanel()
            }
        }
        .offset(y: dragOffset)
        // 展开爆开动画：从刘海（顶部中心）缩放弹入 + 淡入，
        // 与窗口「从刘海顶边向四周扩散」的定位配合，形成「从岛里长出来」的感觉。
        .scaleEffect(appear ? 1 : 0.9, anchor: .top)
        .opacity(appear ? 1 : 0)
        .animation(.spring(response: 0.45, dampingFraction: 0.72), value: appear)
        .animation(.easeInOut(duration: 0.25), value: state.showLicensePanel)
        .animation(.easeInOut(duration: 0.25), value: state.showLyricTuning)
        .onAppear {
            appear = false
            // 下一帧触发弹入，确保初始态(0.9/透明)已布局
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.72)) {
                    appear = true
                }
            }
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

            // 内容超高时内部滚动，圆角背景始终贴合可视区域，
            // 既不会被容器裁掉，也不会撑出多余外框
            ScrollView(.vertical, showsIndicators: false) {
                LicensePanelView()
            }
                // fixedSize 让 ScrollView 按内容真实高度收缩（内容少时不撑出空白外框），
                // frame 再把它的高度上限压在容器内（内容多时转为滚动）
                .fixedSize(horizontal: true, vertical: true)
                .frame(maxHeight: 456)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
                .padding(.vertical, 12)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
    }

    @ViewBuilder
    var moduleContentView: some View {
        // 常驻「插件市场」页：作为顶部独立「插件」标签，优先于模块/插件面板
        if state.showPluginMarket {
            PluginMarketplaceView()
        } else if let pid = state.selectedPluginPanelID,
           let panel = pluginPanels.panels[pid] {
            // L3：选中带 panel 的第三方插件时，整个内容区替换为该插件的独立页面，
            // 完全覆盖底层原生模块（不再与音乐/游戏等原生页面叠加），
            // 不同插件之间各自独立、互不重叠。
            PluginPanelView(panel: panel)
        } else {
            // 原生模块页面
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
            case .game:
                GameExpandedView()
            }

            // 付费功能锁定遮罩（仅原生付费模块）
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
    // 插件列表在 PluginDiscovery.shared 上，AppState 不会转发其变化，
    // 故此处需直接观察，否则 scan() 更新后标签栏的插件标签不会刷新。
    @ObservedObject private var plugins = PluginDiscovery.shared

    var body: some View {
        // 标签栏改为两行布局：
        // 第一行是模块/插件标签（横向滚动，不再被按钮遮挡）；
        // 第二行是右上角的工具按钮（右对齐），避免与标签行重叠。
        VStack(spacing: 6) {
            // 第一行：标签栏（允许横向滚动）
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(AppModule.allCases) { mod in
                        Button(action: {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                                state.activeModule = mod
                                state.selectedPluginPanelID = nil
                                state.showPluginMarket = false
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
                            .foregroundColor(state.activeModule == mod && state.selectedPluginPanelID == nil ? .pink : .white.opacity(0.5))
                            .frame(minWidth: 38, maxWidth: .infinity)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                    }

                    // 常驻「插件市场」标签：始终可见，点开即见市场与已安装列表，
                    // 不依赖先安装任何插件，是插件系统的统一入口。
                    let marketSel = state.showPluginMarket
                    Button(action: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                            state.showPluginMarket = true
                            state.selectedPluginPanelID = nil
                        }
                    }) {
                        VStack(spacing: 3) {
                            ZStack {
                                Image(systemName: "puzzlepiece.fill")
                                    .font(.system(size: 15))
                                // 有可用更新时角标提示
                                if !PluginMarketplace.shared.updatesAvailable.isEmpty {
                                    Circle()
                                        .fill(Color.pink)
                                        .frame(width: 7, height: 7)
                                        .offset(x: 7, y: -6)
                                }
                            }
                            Text("插件")
                                .font(.system(size: 9, weight: .medium))
                        }
                        .foregroundColor(marketSel ? .pink : .white.opacity(0.5))
                        .frame(minWidth: 38, maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)

                    // L3 动态插件模块标签：带 panel 的插件以独立标签出现
                    ForEach(plugins.plugins.filter { $0.panel }, id: \.id) { plugin in
                        let isSel = state.selectedPluginPanelID == plugin.id
                        Button(action: {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                                state.selectedPluginPanelID = plugin.id
                                state.showPluginMarket = false
                            }
                        }) {
                            VStack(spacing: 3) {
                                Image(systemName: plugin.resolvedIconName)
                                    .font(.system(size: 15))
                                Text(plugin.resolvedName)
                                    .font(.system(size: 9, weight: .medium))
                                    .lineLimit(1)
                            }
                            .foregroundColor(isSel ? .pink : .white.opacity(0.5))
                            .frame(minWidth: 38, maxWidth: .infinity)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 12)
                .padding(.trailing, 8)
                .padding(.top, 4)
            }

            // 第二行：工具按钮（右对齐，不再遮挡标签）
            HStack(spacing: 6) {
                Spacer()
                // 歌词与胶囊设置
                Button(action: {
                    AppState.shared.showLyricTuning.toggle()
                }) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                        .padding(7)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("歌词与胶囊设置")
                // 检查更新已收敛到顶部黑色岛，此处仅保留隐藏/退出
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
                // 退出 Lumi
                Button(action: {
                    NSApplication.shared.terminate(nil)
                }) {
                    Image(systemName: "power")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.red.opacity(0.85))
                        .padding(7)
                        .background(Circle().fill(Color.red.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("退出 Lumi")
            }
            .padding(.horizontal, 8)

            // 底部分隔线
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(height: 0.5)
                .padding(.horizontal, 16)
        }
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
            RoundedRectangle(cornerRadius: 16)
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

    // 旧版激活码换发（自助迁移）
    @State private var showRedeem = false
    @State private var oldKeyInput: String = ""
    @State private var orderInput: String = ""
    @State private var endpointOverride: String = ""
    @State private var redeemLoading = false
    @State private var redeemError: String?
    @State private var redeemMessage: String?
    @State private var showDiagnostics = false

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
            .onAppear { license.refreshRevocations() }

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

            // 旧版激活码自助换发入口
            VStack(spacing: 8) {
                Button(action: { withAnimation { showRedeem.toggle() } }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11))
                        Text(showRedeem ? "收起换发" : "我有旧版激活码？免费换发新码")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.pink.opacity(0.9))
                }
                .buttonStyle(.plain)

                if showRedeem {
                    VStack(spacing: 8) {
                        TextField("旧版激活码 LUMI-XXXX-XXXX-XXXX-XXXX", text: $oldKeyInput)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(8)
                            .onChange(of: oldKeyInput) { v in
                                let up = v.uppercased(); if up != v { oldKeyInput = up }
                            }
                        TextField("购买订单号（凭证）", text: $orderInput)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(8)
                        TextField("后端地址（可选，留空用默认）", text: $endpointOverride)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.7))
                            .padding(8)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(8)

                        if let msg = redeemMessage {
                            Text(msg).font(.system(size: 10)).foregroundColor(.green.opacity(0.9))
                                .padding(.horizontal, 4)
                        }
                        if let err = redeemError {
                            Text(err).font(.system(size: 10)).foregroundColor(.red.opacity(0.85))
                                .padding(.horizontal, 4)
                        }

                        Button(action: performRedeem) {
                            HStack(spacing: 6) {
                                if redeemLoading {
                                    ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                                }
                                Text(redeemLoading ? "换发中…" : "换发并激活本机")
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(
                                canRedeem
                                ? AnyShapeStyle(LinearGradient(colors: [Color.pink, Color.purple], startPoint: .leading, endPoint: .trailing))
                                : AnyShapeStyle(Color.white.opacity(0.1))
                            )
                            .cornerRadius(9)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canRedeem || redeemLoading)

                        Text("换发后新码将绑定本机设备，不可转借他人。")
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.35))
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.top, 8)

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

            // 本地诊断数据（可观测性，仅本机 UserDefaults，不上报）
            DisclosureGroup("本地诊断数据", isExpanded: $showDiagnostics) {
                let snap = Telemetry.shared.snapshot()
                VStack(alignment: .leading, spacing: 4) {
                    Text("激活次数：\(snap.activations)（其中设备绑定 \(snap.deviceBoundActivations)）")
                        .font(.system(size: 10))
                    Text("换码尝试：\(snap.redeemAttempts)　成功：\(snap.redeemSuccesses)　失败：\(snap.redeemFailures)")
                        .font(.system(size: 10))
                    if !snap.failureBreakdown.isEmpty {
                        Text("失败原因分布：")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.4))
                        ForEach(snap.failureBreakdown.indices, id: \.self) { i in
                            let item = snap.failureBreakdown[i]
                            Text("  • \(item.reason)：\(item.count)")
                                .font(.system(size: 10))
                        }
                    }
                }
                .foregroundColor(.white.opacity(0.5))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .padding(.bottom, 14)
        // 比展开面板(360)窄一圈，配合外层垂直 padding 使浮层四周留白均匀，
        // 不会顶到容器边缘产生"多余外框"观感
        .frame(width: 336)
    }

    private var canRedeem: Bool {
        !oldKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !orderInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func performRedeem() {
        let oldKey = oldKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let order = orderInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oldKey.isEmpty, !order.isEmpty else {
            redeemError = "请填写旧激活码与订单号"
            return
        }
        redeemLoading = true
        redeemError = nil
        redeemMessage = nil
        Telemetry.shared.record(.redeemAttempt)

        let resolved: URL
        let override = endpointOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty, let u = URL(string: override), u.scheme != nil {
            resolved = u
        } else {
            resolved = RedemptionService().endpoint
        }

        // 调用后端换发：私钥仅在服务端，本机只收到已签名的 LUMI2- 新码
        RedemptionService(endpoint: resolved).redeem(oldKey: oldKey, order: order, deviceId: DeviceId.current) { result in
            DispatchQueue.main.async {
                self.redeemLoading = false
                switch result {
                case .success(let newCode):
                    Telemetry.shared.record(.redeemSuccess)
                    // 新码已绑定本机 DeviceId，直接激活
                    self.license.activate(with: newCode)
                    self.redeemMessage = "✅ 换发成功，已自动激活本机。"
                    self.oldKeyInput = ""
                    self.orderInput = ""
                case .failure(let err):
                    Telemetry.shared.recordRedeemFailure(reason: Self.redeemFailureReason(err))
                    self.redeemError = RedemptionService.errorMessage(err)
                }
            }
        }
    }

    private static func redeemFailureReason(_ err: RedemptionService.RedemptionError) -> String {
        switch err {
        case .network:
            return "网络错误"
        case .invalidResponse:
            return "响应异常"
        case .server(let code, _):
            switch code {
            case 400: return "业务拒绝"
            default:  return "服务端错误(\(code))"
            }
        }
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

            Button(action: { license.refreshRevocations() }) {
                Text("重新检查")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
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
        case .revoked:    return "xmark.shield.fill"
        }
    }

    private var isExpiringSoon: Bool {
        if case .licensed(let expiry) = license.status, let date = expiry {
            let remaining = date.timeIntervalSinceNow
            return remaining > 0 && remaining < 7 * 24 * 3600
        }
        return false
    }

    var statusColor: Color {
        switch license.status {
        case .unlicensed: return .orange
        case .trial:      return .blue
        case .licensed:   return isExpiringSoon ? .orange : .green
        case .lifetime:   return .yellow
        case .revoked:    return .red
        }
    }

    var statusTitle: String {
        switch license.status {
        case .unlicensed:                    return "未激活"
        case .trial(let days):               return "试用中"
        case .licensed(let expiry):          return "已激活"
        case .lifetime:                      return "永久许可"
        case .revoked:                       return "已吊销"
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
                let base = "有效期至 \(f.string(from: date))"
                return isExpiringSoon ? base + "（即将到期，请尽快续费）" : base
            }
            return "已激活"
        case .lifetime:
            return "永久有效，畅享全部功能"
        case .revoked:
            return "激活码已被吊销，请重新激活或联系 support@lumi.app"
        }
    }
}

// MARK: - 右下角手动缩放手柄
/// 拖拽即可调整展开面板大小，尺寸上限/下限由窗口控制器夹紧，
/// 松手后尺寸持久化，下次展开沿用。手柄手势挂在自身，不会被
/// 面板的"下拉收起"全局手势误触发。
struct ResizeHandle: View {
    @State private var lastTranslation: CGSize = .zero
    @State private var dragging = false

    var body: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.white.opacity(dragging ? 0.65 : 0.3))
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { v in
                        let delta = CGSize(
                            width: v.translation.width - lastTranslation.width,
                            height: v.translation.height - lastTranslation.height
                        )
                        SharedIslandController.controller?.resizeBy(delta)
                        lastTranslation = v.translation
                        dragging = true
                        AppState.shared.isResizing = true
                    }
                    .onEnded { _ in
                        SharedIslandController.controller?.saveUserSize()
                        lastTranslation = .zero
                        dragging = false
                        AppState.shared.isResizing = false
                    }
            )
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() }
                else { NSCursor.pop() }
            }
    }
}

// MARK: - 手动检查反馈条（已是最新 / 失败原因，几秒后自动消失）
// 注：更新状态与操作已统一收敛到顶部黑色岛（DynamicIslandStatusView），
// 以下 UpdateFeedbackBanner / UpdateAvailableBanner 两个独立横幅不再渲染，保留定义供后续复用。
struct UpdateFeedbackBanner: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        // 仅当存在手动检查反馈时显示；与 showUpdateBanner 解耦，
        // 即使 status == .upToDate（图标变绿）也能看到明确提示。
        if let feedback = updater.manualCheckFeedback {
            HStack(spacing: 8) {
                Image(systemName: feedbackIcon)
                    .font(.system(size: 14))
                    .foregroundColor(feedbackColor)
                Text(feedback)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                Spacer()
                Button(action: { updater.manualCheckFeedback = nil }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                        .padding(5)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(feedbackColor.opacity(0.3), lineWidth: 0.5))
            )
            .padding(.horizontal, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.25), value: updater.manualCheckFeedback)
        }
    }

    private var feedbackIcon: String {
        if (updater.manualCheckFeedback ?? "").contains("失败") { return "exclamationmark.circle" }
        if (updater.manualCheckFeedback ?? "").contains("新版本") { return "arrow.down.circle.fill" }
        return "checkmark.circle"
    }
    private var feedbackColor: Color {
        if (updater.manualCheckFeedback ?? "").contains("失败") { return .orange }
        if (updater.manualCheckFeedback ?? "").contains("新版本") { return .green }
        return .green
    }
}

// MARK: - 新版本可用浮层（发现更新时提示）
struct UpdateAvailableBanner: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        // 仅在有新版本 / 下载中 / 失败等需要常驻提示时渲染原浮层；
        // 手动检查的短暂反馈（已是最新等）由独立的 UpdateFeedbackBanner 负责。
        if shouldShow {
            VStack(alignment: .leading, spacing: 8) {
                // 头部：图标 + 标题/副标题 + 关闭按钮（始终右上角）
                HStack(spacing: 10) {
                    Image(systemName: iconName)
                        .font(.system(size: 18))
                        .foregroundColor(accentTint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(titleText)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                        Text(subtitleText)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    Spacer()
                    Button(action: { updater.dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))
                            .padding(6)
                    }
                    .buttonStyle(.plain)
                    .help("关闭提示")
                }
                // 操作按钮行（独立一行，避免与标题挤压重叠）
                actionRow
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(accentTint.opacity(0.3), lineWidth: 0.5))
            )
            .padding(.horizontal, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.25), value: updater.status)
        }
    }

    /// 操作按钮独立成一行（HStack 自适应宽度，防止与标题行重叠）
    @ViewBuilder
    private var actionRow: some View {
        switch updater.status {
        case .available:
            HStack(spacing: 8) {
                Button(action: { updater.downloadAndInstall() }) {
                    Text("更新并重启")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(LinearGradient(colors: [Color.pink, Color.purple], startPoint: .leading, endPoint: .trailing))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .help("自动下载并安装此更新")
                Button(action: { updater.ignoreCurrent() }) {
                    Text("忽略")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.2)))
                }
                .buttonStyle(.plain)
                .help("不再提示此版本")
            }
        case .downloading:
            HStack(spacing: 8) {
                Text("下载中…")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.6))
                Spacer()
                Button(action: { updater.cancelDownload() }) {
                    Text("取消")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.2)))
                }
                .buttonStyle(.plain)
                .help("取消下载")
            }
        case .failed:
            HStack(spacing: 8) {
                Button(action: { updater.openRelease() }) {
                    Text("前往下载")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(LinearGradient(colors: [Color.pink, Color.purple], startPoint: .leading, endPoint: .trailing))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .help("打开下载页面")
            }
        default:
            EmptyView()
        }
    }

    private var shouldShow: Bool {
        switch updater.status {
        case .available, .downloading, .readyToInstall, .failed:
            // 失败也可能展示（提示回退到网页）；忽略/稍后的版本不展示
            if let latest = updater.latestVersion,
               (latest == updater.ignoredVersion || latest == updater.skippedVersion) {
                return false
            }
            return true
        default:
            return false
        }
    }

    private var iconName: String {
        if case .downloading = updater.status { return "arrow.down.circle" }
        if case .readyToInstall = updater.status { return "checkmark.circle.fill" }
        if case .failed = updater.status { return "exclamationmark.circle" }
        return "arrow.down.circle.fill"
    }

    /// 手动检查反馈的图标（按文字内容判断成功/失败）
    private var feedbackIcon: String {
        if (updater.manualCheckFeedback ?? "").contains("失败") { return "exclamationmark.circle" }
        if (updater.manualCheckFeedback ?? "").contains("新版本") { return "arrow.down.circle.fill" }
        return "checkmark.circle"
    }
    private var feedbackColor: Color {
        if (updater.manualCheckFeedback ?? "").contains("失败") { return .orange }
        if (updater.manualCheckFeedback ?? "").contains("新版本") { return .green }
        return .green
    }

    private var titleText: String {
        switch updater.status {
        case .available:      return "新版本 v\(updater.latestVersion ?? "") 可用"
        case .downloading:   return "正在下载更新…"
        case .readyToInstall:return "更新已就绪，即将重启"
        case .failed(let m): return "更新失败：\(m)"
        default:             return "更新"
        }
    }

    private var subtitleText: String {
        switch updater.status {
        case .downloading(let p): return "\(Int(p * 100))% · 当前 v\(updater.currentVersion)"
        case .failed:            return "可前往网页手动下载"
        default:                 return "当前 v\(updater.currentVersion)"
        }
    }

    private var accentTint: Color {
        switch updater.status {
        case .available:  return .green
        case .failed:     return .orange
        case .upToDate:   return .white.opacity(0.5)
        default:          return .white.opacity(0.5)
        }
    }

}

// MARK: - 歌词与胶囊设置弹层
/// 展开面板内点「slider.horizontal.3」打开，提供行间距 / 胶囊宽 / 胶囊高 三个滑块，
/// 实时生效并持久化（值存于 AppState，已写 UserDefaults）。
struct LyricTuningPanel: View {
    @ObservedObject private var state = AppState.shared

    var body: some View {
        ZStack {
            // 半透明遮罩，点击空白处关闭
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { state.showLyricTuning = false }

            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("歌词与胶囊")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()
                    Button(action: { state.showLyricTuning = false }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }

                // 行间距
                tuningRow(
                    title: "歌词行间距",
                    value: state.lyricLineSpacing,
                    range: 0...20,
                    step: 1,
                    format: "%.0f pt"
                ) { state.lyricLineSpacing = $0 }

                // 胶囊宽度
                tuningRow(
                    title: "胶囊宽度",
                    value: state.capsuleSize.width,
                    range: 280...900,
                    step: 10,
                    format: "%.0f pt"
                ) { state.capsuleSize.width = $0 }

                // 胶囊高度
                tuningRow(
                    title: "胶囊高度",
                    value: state.capsuleSize.height,
                    range: 60...260,
                    step: 5,
                    format: "%.0f pt"
                ) { state.capsuleSize.height = $0 }

                // 重置
                HStack {
                    Spacer()
                    Button(action: { state.resetLyricTuning() }) {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.counterclockwise")
                            Text("恢复默认")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.pink.opacity(0.85)))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            }
            .padding(20)
            .frame(width: 320)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
                    .overlay(Color.black.opacity(0.9))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.12), lineWidth: 0.5))
            )
            .shadow(color: .black.opacity(0.5), radius: 25, y: 10)
        }
    }

    private func tuningRow(
        title: String,
        value: CGFloat,
        range: ClosedRange<CGFloat>,
        step: CGFloat,
        format: String,
        onChanged: @escaping (CGFloat) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
                Spacer()
                Text(String(format: format, value))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(width: 56, alignment: .trailing)
            }
            Slider(value: Binding(
                get: { value },
                set: { onChanged($0) }
            ), in: range, step: step)
            .tint(.pink)
        }
    }
}

// MARK: - 胶囊尺寸拖拽手柄
/// 收缩态胶囊右下角的缩放手柄：拖拽实时改变 AppState.capsuleSize（宽/高），
/// 窗口控制器已订阅 capsuleSize 变化并即时重排窗口 frame；松手即持久化。
/// 手柄手势挂在自身，不与「长按拖移歌词」整胶囊手势冲突。
struct CapsuleResizeHandle: View {
    @ObservedObject private var state = AppState.shared
    @State private var lastTranslation: CGSize = .zero
    @State private var dragging = false

    private let minW: CGFloat = 280, maxW: CGFloat = 900
    private let minH: CGFloat = 60,  maxH: CGFloat = 260

    var body: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.white.opacity(dragging ? 0.75 : 0.35))
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { v in
                        let delta = CGSize(
                            width: v.translation.width - lastTranslation.width,
                            height: v.translation.height - lastTranslation.height
                        )
                        lastTranslation = v.translation
                        dragging = true
                        // 右下角手柄：向右下拖 = 增大。宽度随 dx，高度随 -dy（向下 dy 为正，增大高度）。
                        let newW = min(maxW, max(minW, state.capsuleSize.width + delta.width))
                        let newH = min(maxH, max(minH, state.capsuleSize.height + delta.height))
                        state.capsuleSize = CGSize(width: newW, height: newH)
                        // 胶囊缩小后，若歌词偏移已越界则同步钳制，保证歌词仍在胶囊内
                        state.lyricOffset = state.clampLyricOffset(state.lyricOffset)
                    }
                    .onEnded { _ in
                        lastTranslation = .zero
                        dragging = false
                    }
            )
    }
}
