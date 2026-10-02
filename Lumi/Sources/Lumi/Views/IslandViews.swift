import SwiftUI

// MARK: - 收缩态：胶囊条
struct CollapsedView: View {
    @ObservedObject private var ai = AIAssistController.shared
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var music = MusicController.shared
    @ObservedObject private var clipboard = ClipboardLinkController.shared

    /// 胶囊固定高度，跟随 AppState.capsuleSize.height（可由用户调节）。
    static var capsuleHeight: CGFloat { AppState.shared.capsuleSize.height }

    /// 胶囊内容的水平内边距：歌词行左右留白。
    /// 同时参与 `lyricTrailingReserve` 的让位计算，两处必须同源，否则预留宽度和外边距会对不上。
    private static let capsuleHorizontalPadding: CGFloat = 14

    /// 歌词行右侧让位宽度：右上角悬停控制条（小/中/大 + ×）的占位 + 胶囊自身水平内边距 + 间隙。
    ///
    /// 控制条与桌面歌词浮窗**同一份**控件、同一套布局（`CapsuleLyricsControls` →
    /// `DesktopLyricsControlsMetrics`：右上角 + 5pt 内边距、100×26），固定钉在胶囊右上角。
    /// 若不预留这块空间，长歌词行会从按钮下方穿过、被药粒压住（用户反馈「大中小按钮挡住歌词」）。
    /// 让位量按同一套常量反算，控件尺寸或内边距改动时两边自动跟随、不会漂移。
    private var lyricTrailingReserve: CGFloat {
        guard state.activeModule == .music, music.desktopLyricsEnabled else { return 0 }
        // barWidth（药丸条本体）+ 两侧 edgeInset（贴角距离）+ 胶囊水平内边距 + 4pt 间隙
        return DesktopLyricsControlsMetrics.barWidth + DesktopLyricsControlsMetrics.edgeInset * 2
            + Self.capsuleHorizontalPadding + 4
    }

    var body: some View {
        // 歌词主体抽成 lyricContent：body 里叠加了进度线/悬停控制条/HUD/AI 条/
        // 剪贴板条等多层 overlay 与手势，表达式太复杂会让类型检查直接超时。
        lyricContent
        .padding(.horizontal, Self.capsuleHorizontalPadding)
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
            // 只负责「进入」这一个方向：悬停态的真实判定已改为「光标坐标 ∩ 窗口
            // frame」（见 IslandWindowController.syncCapsuleHover），nonactivating
            // 面板上 .onHover 的离开回调不可靠，若在这里反向清零会把按坐标算出来
            // 的悬停态擦掉，导致右上角字号控制条闪没。离开由坐标判定负责。
            if inside { AppState.shared.isHovering = true }
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
                    .foregroundColor(PanelInk.text(0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    // 提示条也是浮层 chrome：与展开态面板同一套系统玻璃，
                    // tint 压暗保证白字可读；旧系统按 legacy 参数退回深色底。
                    .glassPanel(cornerRadius: 10, tint: Color.black.opacity(0.3),
                                scrim: 0.55, stroke: 0.12)
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
        // 音乐播放时：底部一条细进度线，不展开也能一眼看到进度。
        .overlay(alignment: .bottom) {
            if state.activeModule == .music, music.playbackState == .playing, music.duration > 0 {
                capsuleProgressLine
            }
        }
        // 悬停控制条：与桌面歌词浮窗**同一份** Liquid Glass 控件（小/中/大 + ×），
        // 连定位也一致：右上角 + 5pt 内边距，只有真正悬停胶囊时才淡入
        // （state.isHovering 由 contentShape 上的 onHover 驱动，靠近顶部热区不误触发）。
        // 注意：历史上这套控件挂在 MusicBriefContent/moduleBriefView 上，而收缩态
        // 实际渲染的是 CollapsedView 自己的歌词块，moduleBriefView 无人引用 → 按钮
        // 从来没显示过。这里接到真实路径上。
        .overlay(alignment: .topTrailing) {
            if state.activeModule == .music, music.desktopLyricsEnabled {
                CapsuleLyricsControls(music: music, visible: state.isHovering) {
                    music.hideDesktopLyricsWindow()
                }
                // 与桌面浮窗控制条同一套定位：右上角、edgeInset 内边距
                // （见 DesktopLyricsWindowController.layoutControls）
                .padding(DesktopLyricsControlsMetrics.edgeInset)
            }
        }
        // 滚轮调音量：短暂浮出音量 HUD 覆盖歌词，1.2s 后自动淡出。
        .overlay {
            if let vol = state.volumeHUD {
                volumeHUDView(vol)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: state.volumeHUD)
        // 划词 AI：检测到新复制文本时浮出动作条（8s 无操作自动消失）
        .overlay {
            if ai.pendingText != nil, !ai.isStreaming {
                AIActionBar()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: ai.pendingText == nil)
        // 剪贴板嗅探：复制到视频链接时浮出快速下载条（MP4/MP3/忽略，展开态不覆盖）
        .overlay {
            if clipboard.pending != nil, !state.isExpanded {
                ClipboardLinkBar()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: clipboard.pending == nil)
    }

    /// 胶囊底部细进度线（进度取 currentTime/duration；随播放轮询刷新）。
    private var capsuleProgressLine: some View {
        GeometryReader { geo in
            let ratio = max(0, min(1, music.currentTime / max(music.duration, 1)))
            ZStack(alignment: .leading) {
                Rectangle().fill(PanelInk.chip(0.14))
                Rectangle()
                    .fill(LinearGradient(colors: [.pink, .purple],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * ratio)
            }
        }
        .frame(height: 2)
        .clipShape(Capsule())
        .padding(.horizontal, 30)
        .padding(.bottom, 2)
        .allowsHitTesting(false)
    }

    /// 音量 HUD：滚动调音量时覆盖在胶囊上（图标 + 音量条 + 百分比）。
    private func volumeHUDView(_ vol: Int) -> some View {
        let clamped = max(0, min(100, vol))
        return HStack(spacing: 10) {
            Image(systemName: clamped == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(PanelInk.text(0.85))
                .frame(width: 18)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(PanelInk.chip(0.18))
                    Capsule().fill(Color.pink)
                        .frame(width: geo.size.width * CGFloat(clamped) / 100)
                }
            }
            .frame(height: 5)
            Text("\(clamped)%")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(PanelInk.primary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 音量 HUD 同为浮层 chrome：换系统玻璃（tint+legacy scrim 保持深色可读）
        .glassPanel(cornerRadius: 18, tint: Color.black.opacity(0.4),
                    scrim: 0.8, stroke: 0.14)
        .allowsHitTesting(false)
    }

    /// 歌词主体：原文（上，红） + 译文（下，青）两行；未播放时留空（黑岛即真刘海）。
    /// 高度完全由内容决定：单行就单行高，双行就双行高，绝不浪费空间、绝不裁切译文；
    /// 用户设定的 capsuleSize.height 仅作单行时的最小高度兜底。
    ///
    /// 文字效果与桌面歌词浮窗（`DesktopLyricsContentView`）**逐项对齐**：同一份
    /// 基准字号（20/13）与档位倍率（小/中/大药丸对两边同时生效）、同一份双语字号
    /// 规则（`bilingualSizes`：英文行不低于中文行）、同一套字重/圆体/描边阴影/
    /// 截断策略。刻意保留的差异只有两处：胶囊沿用黑岛底色（与真刘海融为一体），
    /// 文字水平居中（岛在屏幕顶部中央，左对齐会歪）。
    /// 双语对字号只算一次：单一入口 currentLyricPair 取原文+译文（分别调
    /// currentLineText/currentTranslationText 会把同一帧的防抖状态写两遍）。
    @ViewBuilder
    private var lyricContent: some View {
        let pair = music.currentLyricPair
        let bilingual = lyricPairSizes(pair)
        VStack(alignment: .center, spacing: AppState.shared.lyricLineSpacing) {
            if state.activeModule == .music, music.playbackState == .playing {
                // 静态显示主歌词（不再跑马灯滚动）。
                Text(lyricLine)
                    .font(.system(size: bilingual.original, weight: .semibold, design: .rounded))
                    .lyricLine(ink: .original)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: .infinity, alignment: .center)
                // 双语模式且译文就绪：紧贴下方追加青色译文行（上下并排成组）
                if music.bilingualMode != .off, !pair.translation.isEmpty {
                    // 静态显示译文（不再跑马灯滚动）。
                Text(pair.translation)
                    .font(.system(size: bilingual.translation, weight: .regular, design: .rounded))
                    .lyricLine(ink: .translation)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .minimumScaleFactor(0.5)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        }
        // 右侧为右上角控制条让位（见 `lyricTrailingReserve`）：歌词行不伸到按钮下方。
        // 两行都让，文字块整体在剩余宽度里居中，hover 淡入按钮也不会挤压文字。
        .padding(.trailing, lyricTrailingReserve)
    }

    /// 胶囊歌词的双语字号对：**与桌面浮窗完全同一套**算法与基准
    /// （`originalFontSize`/`translationFontSize` × 同一个 `desktopLyricsSizePreset`），
    /// 英文行不低于中文行。
    private func lyricPairSizes(_ pair: (text: String, translation: String))
        -> (original: CGFloat, translation: CGFloat) {
        let preset = music.desktopLyricsSizePreset
        return DesktopLyricsLayout.bilingualSizes(
            originalBase: DesktopLyricsLayout.originalFontSize * preset.scale,
            translationBase: DesktopLyricsLayout.translationFontSize * preset.scale,
            original: pair.text.isEmpty ? music.title : pair.text,
            translation: pair.translation,
            wantsTranslation: music.bilingualMode != .off && !pair.translation.isEmpty)
    }

    /// 拖移微调时的偏移基准（长按进入时记录，拖动在此基础上累加）。
    @State private var tuneBase: CGSize = .zero

    /// 胶囊岛内展示的歌词行：优先同步歌词当前行，缺失时回退到歌名。
    ///
    /// 只解析一次：`currentLineText` 内部会推进防抖状态，判空与取值各调一次
    /// 会把同一帧的 `lastActiveLineIndex` 写两遍（纯浪费，且会让
    /// 「这次 body 求值用了哪个索引」变得不确定）。
    private var lyricLine: String {
        let line = music.currentLineText
        return line.isEmpty ? music.title : line
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
            Text("🧠 问 Claude 任何编程问题").font(.system(size: 12)).foregroundColor(PanelInk.text(0.7))
        case .codex:
            Text("✨ 代码解释 · 优化 · 补全").font(.system(size: 12)).foregroundColor(PanelInk.text(0.7))
        case .videoDownload:
            VideoDownloadBriefView()
        case .game:
            GameBriefView()
        case .aiAssist:
            AIAssistBriefView()
        case .cliUsage:
            CLIUsageBriefView()
        case .tv:
            TVBriefView()
        case .dictation:
            DictationBriefView()
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
    /// 系统真实明暗（父级传入）。body 末尾的 .environment(\.colorScheme, .dark)
    /// 只作用于它之后的子树，不会反过来改这里的值——所以这里拿到的是系统外观，
    /// 用来决定黑岛罩层强度，避免浅色外观下白字压在中灰上看不见。
    @Environment(\.colorScheme) private var systemColorScheme

    /// 黑岛罩层强度（明暗双档）：深色外观 0.6 足够压暗；浅色外观下系统 .clear
    /// 玻璃本身是亮的，同样的 0.6 只压成中灰，而子树被 .environment(\.colorScheme, .dark)
    /// 锁成白字——中灰配白字正是用户报的「面板白色的字看不见」。面板是黑岛 aesthetic，
    /// 两种外观都要保持深底，浅色侧直接加深到近黑。
    private var panelDimming: Double { systemColorScheme == .light ? 0.92 : 0.6 }

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
                    .fill(PanelInk.chip(0.3))
                    .frame(width: 32, height: 3)
                    .padding(.bottom, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 暗化层放在玻璃之前：background 落在「玻璃之后、内容之前」，把内容
            // 压在全黑罩层上，并按面板圆角一起裁——矩形黑边不被裁就会从玻璃圆角
            // 弧外侧露出四块直角（用户报的「圆角旁边的边角料」）。
            .glassDimmingLayer(panelDimming, cornerRadius: 22)
            // macOS 26+ 用 .clear 系统玻璃 + 自带暗化层：原先 regular + tint 0.78
            // 在 macOS 27 上实际渲染仍偏亮（白字糊进背景），且玻璃分支里 scrim
            // 参数根本不生效；面板暗度统一由上面的 dimming 层精确控制。旧系统
            // 回退手搓三件套（材质 + 0.6 黑罩 + 白描边）。
            .glassPanel(cornerRadius: 22, variant: .clear,
                        material: .ultraThinMaterial, scrim: 0.6, stroke: 0.12)
            // 面板子树锁定深色外观：PanelInk 的深色分支即白字，与暗化后的面板
            // 固定反差，不再随系统明暗外观翻转回浅底黑字。
            .environment(\.colorScheme, .dark)
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
                .glassPanel(cornerRadius: 16, scrim: 0, stroke: 0.15)
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
            case .aiAssist:
                AIAssistExpandedView()
            case .cliUsage:
                CLIUsageExpandedView()
            case .tv:
                TVExpandedView()
            case .dictation:
                DictationExpandedView()
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
        // 标签栏所有内容固定两行：第一行 12 个内置模块，
        // 第二行「插件市场入口 + 各带面板的插件 + 右侧三个工具按钮」。
        // 工具按钮也并入第二行网格，不另占一行（用户要求：所有内容都在两行）。
        VStack(spacing: 3) {
            // 排版约定（ Typography ）：
            // - 固定两行：用 GridItem(.flexible(), count: n) 把每个网格锁成「一行 n 列」，
            //   而不是 .adaptive(minimum:) 自适应折行 —— 后者在面板变窄时会从 2 行
            //   变成 3 行，标签区高度随面板宽度漂移（用户要求「固定就 2 行」）。
            // - 第二行的列数必须把工具按钮一起算进去，否则它们会把该行挤成两行、总计三行。
            // - 组内等宽等高，图标在上、短名在下；激活态加淡粉底色。
            // - 插件名可能很长，尾部省略，完整名放 tooltip。
            // - 行高由用户拖拽调节（AppState.tabRowHeight）并持久化。
            //
            // 历史上这里先后用过横向 ScrollView、纵向 ScrollView + .adaptive 网格：
            // 前者右侧标签「无法显示」（溢出且无滚动提示），后者会行数漂移。
            // 现在用「固定列数 + 单元格自适应宽度」一次性解决两个问题。
            VStack(spacing: 1) {
                // 第一行：内置模块
                tabGrid(columns: sharedTabColumns) {
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
                            tabLabel(
                                icon: mod.icon,
                                name: mod.shortName,
                                isActive: state.activeModule == mod && state.selectedPluginPanelID == nil,
                                locked: mod.isPremium
                                    && (mod.premiumFeature.map { !license.isUnlocked($0) } ?? false)
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    // 补齐到与第二行相同的列数：两行等宽，图标才能上下对齐。
                    ForEach(0..<builtInRowSpacers, id: \.self) { _ in spacerCell }
                }

                // 第二行：插件（市场入口 + 各带面板的插件），再补齐占位，最后是工具按钮。
                // 工具按钮放行尾（右侧），与第一行的模块列对齐；中间用透明占位撑开。
                // 关键是两行共用 sharedTabColumns，列宽一致 → 上下严格对齐。
                tabGrid(columns: sharedTabColumns) {
                    Button(action: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                            state.showPluginMarket = true
                            state.selectedPluginPanelID = nil
                        }
                    }) {
                        tabLabel(
                            icon: "puzzlepiece.fill",
                            name: "插件",
                            isActive: state.showPluginMarket,
                            badge: !PluginMarketplace.shared.updatesAvailable.isEmpty
                        )
                    }
                    .buttonStyle(.plain)

                    // L3 动态插件模块标签：带 panel 的插件以独立标签出现
                    ForEach(plugins.plugins.filter { $0.panel }, id: \.id) { plugin in
                        Button(action: {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                                state.selectedPluginPanelID = plugin.id
                                state.showPluginMarket = false
                            }
                        }) {
                            tabLabel(
                                icon: plugin.resolvedIconName,
                                name: plugin.resolvedName,
                                isActive: state.selectedPluginPanelID == plugin.id,
                                tooltip: plugin.resolvedName
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    // 中间补透明占位：把工具按钮推到行尾，同时保证本行恰好一行。
                    ForEach(0..<secondRowSpacers, id: \.self) { _ in spacerCell }

                    // 行尾三个工具按钮：与标签同网格、同行高，视觉上用圆形底区分。
                    // 它们必须计入列数（见 sharedTabColumns 的注释），否则这一行会折出第三行。
                    toolCell(icon: "slider.horizontal.3", tint: .white.opacity(0.5),
                             background: .white.opacity(0.08), help: "歌词与胶囊设置") {
                        AppState.shared.showLyricTuning.toggle()
                    }
                    // 检查更新已收敛到顶部黑色岛，此处仅保留隐藏/退出
                    toolCell(icon: "eye.slash", tint: .white.opacity(0.5),
                             background: .white.opacity(0.08), help: "隐藏界面（鼠标移到顶部可重新出现入口）") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            AppState.shared.islandEnabled = false
                        }
                    }
                    toolCell(icon: "power", tint: .red.opacity(0.85),
                             background: .red.opacity(0.08), help: "退出 Lumi") {
                        NSApplication.shared.terminate(nil)
                    }
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .padding(.vertical, 1)

            // 行高拖拽条：上下拖动即可调整标签行高，鼠标悬停显示上下箭头光标。
            rowHeightHandle
        }
    }

    // MARK: 标签网格（固定两行 + 可拖拽行高）

    /// 工具按钮个数。必须计入第二行列数，否则它们会把插件行挤成三行。
    private var toolCellCount: Int { 3 }

    /// 两行共用的列数：取两行单元数的较大者，保证上下严格对齐；
    /// 超过 12 时按 `TabBarLayout.maxColumns` 上限折行，防止单元过窄不可读。
    private var sharedTabColumns: Int {
        TabBarLayout.cellColumns(builtInCount: AppModule.allCases.count,
                                 secondRowCount: secondRowCells)
    }

    /// 第一行要在行尾补几个透明占位，才能与第二行同宽对齐。
    private var builtInRowSpacers: Int {
        TabBarLayout.spacerCount(itemCount: AppModule.allCases.count, columns: sharedTabColumns)
    }

    /// 第二行（插件市场 + 带面板插件 + 工具按钮）要在行尾补几个透明占位。
    private var secondRowSpacers: Int {
        TabBarLayout.spacerCount(itemCount: secondRowCells, columns: sharedTabColumns)
    }

    /// 第二行的全部单元数：1 个市场入口 + 带面板插件 + 3 个工具按钮。
    private var secondRowCells: Int {
        1 + plugins.plugins.filter { $0.panel }.count + toolCellCount
    }

    /// 透明占位：不画任何东西，只为撑满列数让两行等宽、图标上下对齐。
    private var spacerCell: some View {
        Color.clear.frame(maxWidth: .infinity)
    }

    /// 由标签个数推出列数：正常情况下 `count` 个标签正好排一行（两行总计）。
    /// 真正的规则在 `TabBarLayout`（有单测守着「恒为两行」），这里只是转发。
    private func tabColumns(for count: Int) -> Int {
        TabBarLayout.columns(forItemCount: count)
    }

    /// 锁列数的网格：`.flexible()` 让单元格平分可用宽度，因此列数固定 = 行数固定。
    private func tabGrid<C: View>(columns: Int, @ViewBuilder content: () -> C) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: columns),
                  spacing: 1) {
            content()
        }
    }

    /// 工具按钮单元格：与标签同网格、同行高，视觉上用圆形底与文字标签区分。
    ///
    /// 为什么不用 `HStack + Spacer` 单独占一行：那样标签栏就是三行了，
    /// 而用户要求「所有内容都在两行」。放进第二行网格后既省一行高度，
    /// 又天然右对齐（排在插件之后）。
    private func toolCell(icon: String, tint: Color, background: Color,
                          help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(tint)
                .frame(maxWidth: .infinity)
                .frame(height: state.tabRowHeight)
                .background(Circle().fill(background))
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(help)
    }

    /// 行高拖拽条：一条 8pt 高的透明抓取区，上下拖动调整标签行高。
    ///
    /// 视觉上不画任何东西（避免多一条横线破坏紧凑感），但悬停时用
    /// `resizeUpDown` 光标 + 一层极淡的高亮提示「这里可以拖」。
    private var rowHeightHandle: some View {
        Rectangle()
            .fill(PanelInk.chip(0.001))
            .frame(height: 8)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { v in
                        // 首次按下时记下基准行高，整个拖拽过程都以它为原点，
                        // 避免增量累加导致的漂移。
                        if dragStartRowHeight == nil { dragStartRowHeight = state.tabRowHeight }
                        guard let start = dragStartRowHeight else { return }
                        // 上下位移一半映射到行高：手指 46pt 对应 23pt 行高变化，手感更跟手。
                        let next = start + v.translation.height / 2
                        state.tabRowHeight = min(max(next, AppState.tabRowHeightRange.lowerBound),
                                                 AppState.tabRowHeightRange.upperBound)
                    }
                    .onEnded { _ in dragStartRowHeight = nil }
            )
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .help("上下拖动调整标签行高")
    }

    /// 拖拽开始时的基准行高（nil = 未在拖拽）。只在拖拽期间有效。
    @State private var dragStartRowHeight: CGFloat? = nil

    // MARK: 标签外观（内置模块与插件共用，保证组内等宽等高）

    /// 单个标签：图标在上、短名在下；激活态铺一层淡粉底色。
    /// 宽度交给网格（`.maxWidth: .infinity`）自适应，高度取用户可拖拽的行高。
    /// - Parameters:
    ///   - locked: 付费模块未解锁，角上挂小锁（与更新角标互斥，锁优先）。
    ///   - badge: 有可用更新，角上挂粉点。
    ///   - tooltip: 鼠标悬停提示；未传则用标签名本身。
    private func tabLabel(icon: String, name: String, isActive: Bool,
                          locked: Bool = false, badge: Bool = false,
                          tooltip: String? = nil) -> some View {
        VStack(spacing: 2) {
            ZStack {
                Image(systemName: icon)
                    .font(.system(size: 15))
                if locked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 7))
                        .foregroundColor(PanelInk.orange)
                        .offset(x: 7, y: -6)
                } else if badge {
                    Circle()
                        .fill(Color.pink)
                        .frame(width: 7, height: 7)
                        .offset(x: 7, y: -6)
                }
            }
            Text(name)
                .font(.system(size: 9, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                // 文本单独限宽，保证超长插件名在标签内部截断，不会顶大整组
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 4)
        }
        .foregroundColor(isActive ? .pink : .white.opacity(0.5))
        .frame(maxWidth: .infinity)
        .frame(height: state.tabRowHeight)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isActive ? Color.pink.opacity(0.16) : Color.clear)
        )
        .contentShape(Rectangle())
        .help(tooltip ?? name)
    }
}

// MARK: - 各模块收缩态简要视图（占位）
struct MusicBriefView: View { var body: some View { MusicBriefContent() } }
struct CalendarBriefView: View { var body: some View { Text("📅 今日 3 项日程").font(.system(size: 12)).foregroundColor(PanelInk.text(0.7)) } }
struct FocusBriefView: View { var body: some View { FocusBriefContent() } }
struct LiveDetectionBriefView: View { var body: some View { LiveDetectionBriefContent() } }
