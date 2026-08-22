import SwiftUI

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
                // 静态显示主歌词（不再跑马灯滚动）。
                Text(lyricLine)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(.red)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .center)
                // 双语模式且译文就绪：紧贴下方追加青色译文行（上下并排成组）
                if music.bilingualMode != .off {
                    let tr = music.currentTranslationText
                    if !tr.isEmpty {
                        // 静态显示译文（不再跑马灯滚动）。
                        Text(tr)
                            .font(.system(size: 16, weight: .regular))
                            .foregroundColor(.cyan)
                            .lineLimit(1)
                            .truncationMode(.middle)
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
        // 右下角：尺寸拖拽手柄。固定/取消固定已改为「双击刘海」触发，故此处移除固定按钮。
        .overlay(alignment: .bottomTrailing) {
            CapsuleResizeHandle()
                .padding(5)
        }
        // 右侧竖直居中：只拉宽手柄，高度不变。独立于右下角缩放手柄，互不冲突。
        .overlay(alignment: .trailing) {
            CapsuleWidthHandle()
                .padding(.trailing, 4)
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
    // 插件清单（占位面板需要从 manifest 取名称/图标）
    @ObservedObject private var plugins = PluginDiscovery.shared
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
        } else if let pid = state.selectedPluginPanelID {
            // L3：选中带 panel 的第三方插件时，整个内容区替换为该插件的独立页面。
            // 插件未运行/尚未写入面板数据时，按清单合成占位面板，
            // 绝不回退到原生模块（否则点插件标签却显示音乐，观感是"跳错页"）。
            let manifest = plugins.plugins.first { $0.id == pid }
            let panel = pluginPanels.panels[pid] ?? PluginPanelData(
                id: pid,
                title: manifest?.resolvedName ?? "插件",
                iconName: manifest?.resolvedIconName ?? "puzzlepiece",
                subtitle: "插件未运行或暂无数据",
                lines: [
                    .text("启动插件主程序后，这里会显示它的实时内容。"),
                    .button("启动插件主程序")
                ],
                updatedAt: Date().timeIntervalSince1970
            )
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
struct LiveDetectionBriefView: View { var body: some View { LiveDetectionBriefContent() } }
