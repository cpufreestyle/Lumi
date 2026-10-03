import AppKit
import SwiftUI
import Combine

/// 桌面歌词浮窗：置顶无边框小窗，跟随播放显示当前歌词行（双语模式带译文）。
/// 解决 hideInFullscreen 开启时胶囊隐藏、以及全屏看视频/写代码时看不到歌词的缺口。
/// 特性：拖拽移动（位置持久化）、锁定后点击穿透、尺寸随文本自适应、跟随所有工作区空间。
/// 事件驱动：订阅 MusicController 的发布属性，无常驻 Timer（符合项目 PollingCoordinator 约定）。

final class DesktopLyricsWindowController: ObservableObject {
    /// 当前歌词行（空时显示占位提示，保证窗口始终可见可拖）。
    @Published var line: String = ""
    /// 空态提示：未在播放 / 已暂停 / 等待歌曲信息 / 正在获取歌词 / 纯音乐。有歌词行时为空。
    @Published var hint: String = ""
    /// 当前行译文（双语模式且已解析/翻译出译文时非空）。
    @Published var translation: String = ""
    /// 是否展示译文行（跟随 MusicController.bilingualMode）。
    @Published var showTranslation: Bool = true
    /// 位置锁定：锁定时面板 ignoresMouseEvents，点击穿透、不可拖动。
    @Published var locked: Bool = false
    /// 当前字号档位：跟随 MusicController.desktopLyricsSizePreset（单一数据源），
    /// 悬停控制条 / 设置区药丸 / 滚轮任一处改动都会经 Combine 汇到这里。
    /// 注意不能用 private(set)：@Published 的 dynamicMember 下标会跟着降到 private，
    /// SwiftUI 侧经 @ObservedObject 读取会直接编译不过。写入只走本类与 MusicController。
    @Published var sizePreset: DesktopLyricsSizePreset = .medium

    private let music: MusicController
    private var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()
    /// 悬停控制条（字号小/中/大 + 隐藏），作为 hosting 视图子视图钉在右上角。
    private weak var controlsBar: DesktopLyricsControlsBar?
    /// 右上角控制条对歌词行的让位宽度：药丸条本体 + 两侧 edgeInset。
    /// 与胶囊 IslandViews.lyricTrailingReserve 同一套常量反算（那边额外加上自己的
    /// 水平内边距与间隙），按钮永远压在留白上、不遮歌词，控件尺寸改动时两边自动跟随。
    private var controlsTrailingReserve: CGFloat {
        DesktopLyricsControlsMetrics.trailingReserve
    }
    /// 已持久化的窗口原点；拖拽结束时更新并写 UserDefaults（防抖 1pt）。
    private var persistedOrigin: CGPoint?
    /// 拖拽进行中：为 true 时 applyLayout 整体跳过。歌词每拍刷新会按 persistedOrigin
    /// 回填原点，而拖拽时该值仍是旧位置，每拍都把窗口拽回旧位、与光标互相抢夺 ——
    /// 这是拖动抖动的主因；拖拽期间的几何交由 performDrag 全权处理。
    private var isDragging = false

    init(music: MusicController) {
        self.music = music
        sizePreset = music.desktopLyricsSizePreset
        subscribePlayback()
    }

    deinit {
        cancellables.removeAll()
    }

    // MARK: - Combine 订阅（全部回主线程；currentTime 每拍、属性变更时刷新）
    private func subscribePlayback() {
        let main: DispatchQueue = .main
        music.$currentTime
            .receive(on: main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        music.$syncedLines
            .receive(on: main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        music.$lyrics
            .receive(on: main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        music.$lyricsTranslation
            .receive(on: main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        music.$bilingualMode
            .receive(on: main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        music.$playbackState
            .receive(on: main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        // 歌名与取词结论也要驱动刷新，否则切歌后空态文案会停留在上一首的状态。
        music.$title
            .receive(on: main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        music.$lyricsNote
            .receive(on: main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        // 字号档位变化：汇到本机状态、同步控制条选中态并重排窗口尺寸（高度随倍率变）。
        music.$desktopLyricsSizePreset
            .receive(on: main)
            .sink { [weak self] preset in
                guard let self, self.sizePreset != preset else { return }
                self.sizePreset = preset
                self.applyLayout()
            }
            .store(in: &cancellables)
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func showWindow() {
        ensurePanel()
        refresh()
        // fullscreen 空间里普通 orderFront 可能被系统全屏窗口盖住，用 Regardless。
        panel?.orderFrontRegardless()
    }

    func hideWindow() {
        panel?.orderOut(nil)
    }

    func setLocked(_ locked: Bool) {
        self.locked = locked
        panel?.ignoresMouseEvents = locked
        // 锁定时鼠标穿透，悬停控制条已无意义，直接收起避免留下一点不动的残影。
        if locked { setControlsVisible(false) }
    }

    // MARK: - 面板创建（懒创建，关闭只隐藏不销毁）
    private func ensurePanel() {
        guard panel == nil else { return }
        // 首次创建时还没有 hint 可读，按同一套规则现算种子文案，
        // 保证窗口一出现就是合适尺寸（不会先闪一下再跳）。
        // 种子里带上当前字号档位倍率，避免窗口首帧按默认档算尺寸、随后又跳一次。
        // 只解析一次：判空与取值分两次调会把防抖状态写两遍
        let current = music.currentLineText
        let seed = current.isEmpty ? emptyHint() : current
        let size = DesktopLyricsLayout.contentSize(
            line: seed,
            translation: "",
            showTranslation: false,
            originalFontSize: DesktopLyricsLayout.originalFontSize * sizePreset.scale,
            translationFontSize: DesktopLyricsLayout.translationFontSize * sizePreset.scale,
            sizeScale: sizePreset.scale,
            trailingReserve: controlsTrailingReserve)
    let origin = restoredOrigin(size: size)
        let panel = DesktopLyricsPanel(contentRect: NSRect(origin: origin, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        // 跟随所有工作区 + 可叠加在全屏窗口之上（fullScreenAuxiliary）。
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let root = DesktopLyricsContentView(controller: self)
        let hosting = DesktopLyricsHostingView(rootView: root)
        // 关键：关掉 NSHostingView 的「按内容尺寸自适应」。否则 SwiftUI 会拿自己的
        // fitting size（实测高度比 applyLayout 算的小一截）把整个窗口拉回去，算出的
        // 高度被覆盖导致歌词行被压扁、底边位置还跟着上漂；窗口几何只由 applyLayout 决定。
        hosting.sizingOptions = []
        hosting.onDragBegan = { [weak self] in self?.beginDrag() }
        hosting.onDragEnd = { [weak self] origin in self?.endDrag(origin: origin) }
        // 悬停进出驱动控制条显隐；滚轮上下循环切换字号档位。
        hosting.onHoverChange = { [weak self] hovering in self?.handleHover(hovering) }
        hosting.onSizeScroll = { [weak self] delta in self?.cycleSize(delta: delta) }
        // 右键短按 → 播放/暂停（与胶囊 onAuxClick 同一套逻辑）。
        hosting.onRightClick = { [weak self] in self?.handleRightClick() }
        // 关键：contentView 不能直接用 hosting —— NSHostingView 的 hitTest 会把子视图
        // 的命中吃掉，挂在它上面的 AppKit 控件永远收不到点击。改用普通 NSView 容器做
        // contentView，hosting 与控制条当兄弟子视图，命中测试才能正常分发。
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container

        // 悬停控制条：AppKit 子视图钉在浮窗右上角，默认透明，进入浮窗时淡入。
        let controls = DesktopLyricsControlsBar(music: music)
        container.addSubview(controls)
        controlsBar = controls
        layoutControls()

        self.panel = panel
    }

    /// 恢复上次位置（UserDefaults）；按「保存点落在哪块屏」选屏钳制，跨屏布局变化后
    /// 浮窗不会因为死盯 NSScreen.main 被甩到另一块屏上。无记录则回退主屏默认底部居中。
    private func restoredOrigin(size: CGSize) -> CGPoint {
        let screens = NSScreen.screens.map(\.frame)
        let fallback = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        if let saved = UserDefaults.standard.string(forKey: DesktopLyricsLayout.originKey),
           let decoded = DesktopLyricsLayout.decode(origin: saved) {
            let visible = DesktopLyricsLayout.visibleFrame(
                forSavedPoint: decoded, screens: screens)
            return DesktopLyricsLayout.clamp(origin: decoded, size: size, visibleFrame: visible)
        }
        let visible = NSScreen.main?.visibleFrame ?? screens.first ?? fallback
        return DesktopLyricsLayout.defaultOrigin(size: size, visibleFrame: visible)
    }

    // MARK: - 内容刷新 + 自适应布局
    private func refresh() {
        // 一次取原文+译文：旧代码分别调 currentLineText 与 currentTranslationText，
        // 同一帧内把防抖状态写两遍；收敛到单一入口后只算一次。
        let pair = music.currentLyricPair
        let currentLine = pair.text
        let wantTranslation = music.bilingualMode != .off
        let tr = wantTranslation ? pair.translation : ""
        // 没有可显示的歌词行时，用有信息量的空态文案替代无意义占位符。
        let hint = currentLine.isEmpty ? emptyHint() : ""
        let changed = currentLine != line || tr != translation
            || wantTranslation != showTranslation || hint != self.hint
        line = currentLine
        translation = tr
        showTranslation = wantTranslation
        self.hint = hint
        if changed || panel == nil { applyLayout() }
    }

    /// 空态文案：由播放态 + 曲名 + 取词结论推导（纯逻辑放在 DesktopLyricsLayout，便于单测）。
    private func emptyHint() -> String {
        let state: String
        switch music.playbackState {
        case .playing: state = "playing"
        case .paused:  state = "paused"
        case .stopped: state = "stopped"
        }
        return DesktopLyricsLayout.placeholder(state: state,
                                               title: music.title,
                                               note: music.lyricsNote)
    }

    private func applyLayout() {
        // 拖拽中一律跳过：本方法按 persistedOrigin 回填原点，而拖拽时该值还是旧位置，
        // 每拍歌词刷新都会把窗口拽回旧位，与光标互相抢夺 → 严重抖动。几何交由
        // performDrag + constrainFrameRect 处理，松手后 endDrag 再补排一次。
        guard !isDragging else { return }
        // 档位可能在面板创建前就已被设置（init 从 UserDefaults 读），先同步再做空判断。
        if sizePreset != music.desktopLyricsSizePreset {
            sizePreset = music.desktopLyricsSizePreset
        }
        guard let panel = panel else { return }
        // 尺寸按「实际要显示的文案」计算：空态时用 hint，避免空窗口坍缩成不可点的细条。
        let displayLine = line.isEmpty ? hint : line
        let showTr = showTranslation && !line.isEmpty && !translation.isEmpty
        // 宽高都按当前字号档位缩放：宽度仍受 minWidth / maxWidth 夹制，高度随倍率增长。
        let size = DesktopLyricsLayout.contentSize(
            line: displayLine,
            translation: showTr ? translation : "",
            showTranslation: showTr,
            originalFontSize: DesktopLyricsLayout.originalFontSize * sizePreset.scale,
            translationFontSize: DesktopLyricsLayout.translationFontSize * sizePreset.scale,
            sizeScale: sizePreset.scale,
            trailingReserve: controlsTrailingReserve)
    let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let base = persistedOrigin
            ?? DesktopLyricsLayout.decode(
                origin: UserDefaults.standard.string(forKey: DesktopLyricsLayout.originKey) ?? "")
            ?? DesktopLyricsLayout.defaultOrigin(size: size, visibleFrame: visible)
        let origin = DesktopLyricsLayout.clamp(origin: base, size: size, visibleFrame: visible)
        persistedOrigin = origin
        let frame = panel.frame
        if abs(frame.width - size.width) > 0.5
            || abs(frame.height - size.height) > 0.5
            || abs(frame.minX - origin.x) > 0.5
            || abs(frame.minY - origin.y) > 0.5 {
            panel.setFrame(CGRect(origin: origin, size: size), display: true)
        }
    }

    // MARK: - 悬停控制条（字号小/中/大 + 隐藏）

    /// 鼠标进入/离开浮窗：锁定时鼠标穿透，控制条保持收起。
    private func handleHover(_ hovering: Bool) {
        guard !locked else { return }
        setControlsVisible(hovering)
    }

    /// 滚轮切换字号：向上 next、向下 previous，三档循环；锁定时忽略。
    /// 只改 MusicController（单一数据源），经 Combine 回流后统一重排。
    private func cycleSize(delta: CGFloat) {
        guard !locked else { return }
        let preset = delta > 0 ? sizePreset.next : sizePreset.previous
        guard preset != sizePreset else { return }
        music.desktopLyricsSizePreset = preset
    }

    /// 右键短按 → 播放/暂停。
    ///
    /// 逻辑抄胶囊 IslandWindowController.handleCapsuleAuxClick：切状态后立刻拉一次，
    /// 不等最长 1.5s 的轮询才刷新 UI。
    /// 不设 expanded 守卫：桌面歌词是独立浮窗，没有展开态；锁定时 panel 已 
    /// ignoresMouseEvents，事件根本到不了这里。
    private func handleRightClick() {
        MusicController.shared.togglePlayPause()
        MusicController.shared.fetchInfo()
    }

    private func setControlsVisible(_ visible: Bool) {
        guard let controlsBar else { return }
        let target: CGFloat = visible ? 1 : 0
        if controlsBar.alphaValue == target && controlsBar.isHidden == !visible { return }
        controlsBar.isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            controlsBar.animator().alphaValue = target
        } completionHandler: { [weak controlsBar] in
            guard !visible else { return }
            // alpha 归零后退出命中测试，否则一条看不见的控制条会吃掉右上角的拖拽。
            controlsBar?.isHidden = true
        }
    }

    /// 把控制条钉在浮窗右上角；窗口尺寸变化时靠 autoresizingMask 保持贴角。
    private func layoutControls() {
        guard let controlsBar, let hosting = controlsBar.superview else { return }
        let bounds = hosting.bounds
        // 与胶囊 IslandViews 的 .padding(edgeInset) 同一来源：右上角、5pt 内边距。
        let inset = DesktopLyricsControlsMetrics.edgeInset
        let frame = CGRect(x: bounds.width - DesktopLyricsControlsMetrics.barWidth - inset,
                           y: inset,
                           width: DesktopLyricsControlsMetrics.barWidth,
                           height: DesktopLyricsControlsMetrics.barHeight)
        controlsBar.autoresizingMask = [.minXMargin, .minYMargin]
        controlsBar.setFrameOrigin(frame.origin)
    }

    /// 拖拽开始：暂停 applyLayout 的原点回填，避免与光标抢夺导致抖动。
    private func beginDrag() {
        isDragging = true
    }

    /// 拖拽结束：先复位标志（否则下面的 applyLayout 会被 guard 挡掉），再钳制持久化，
    /// 最后补排一次拖拽期间被跳过的尺寸变化。
    private func endDrag(origin: CGPoint) {
        isDragging = false
        handleDragEnd(origin: origin)
        applyLayout()
    }

    /// 拖拽结束：钳制 + 防抖持久化。
    private func handleDragEnd(origin: CGPoint) {
        guard let panel = panel else { return }
        let size = panel.frame.size
        // 松手按「光标落在哪块屏」判定，且用与拖拽中同一套松钳制：
        // 拖的时候窗口能探出屏幕跟手，一松手又不会被拽回屏内造成跳变。
        let visible = DesktopLyricsLayout.screenFrame(
            containing: NSEvent.mouseLocation, screens: NSScreen.screens.map(\.frame))
        let clamped = DesktopLyricsLayout.clampAllowingOverhang(origin: origin,
                                                                size: size,
                                                                visibleFrame: visible)
        let previous = persistedOrigin ?? clamped
        persistedOrigin = clamped
        panel.setFrameOrigin(clamped)
        if DesktopLyricsLayout.shouldPersist(from: previous, to: clamped) {
            UserDefaults.standard.set(DesktopLyricsLayout.encode(origin: clamped),
                                      forKey: DesktopLyricsLayout.originKey)
        }
    }
}

/// 浮窗专用面板：拖动时 WindowServer 会持续回调 constrainFrameRect，AppKit 传来的
/// screen 就是光标所在屏，在这里按该屏松钳制，跨屏拖动时窗口能跟着光标过去、不会
/// 在屏缘硬停或被瞬移。
///
/// 只在「目标屏与窗口本来就有交集」时才钳制。AppKit 在面板创建、取框等阶段也会调
/// 这个方法，且那时 screen 可能给的是主屏：若无条件钳制，副屏上的浮窗会被强行搬回
/// 主屏左上角。相交判断保证跨屏恢复位置时不受干扰。
private final class DesktopLyricsPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        guard let screen, screen.frame.intersects(frameRect) else { return frameRect }
        let origin = DesktopLyricsLayout.clampAllowingOverhang(origin: frameRect.origin,
                                                              size: frameRect.size,
                                                              visibleFrame: screen.visibleFrame)
        return NSRect(origin: origin, size: frameRect.size)
    }
}

/// 浮窗内容：当前歌词行 + 译文，深色半透明圆角底。仅一行（行数由控制器尺寸撑开）。
private struct DesktopLyricsContentView: View {
    @ObservedObject var controller: DesktopLyricsWindowController

    var body: some View {
        // 0 间距：原文与译文靠各自文本框的自然行高贴合，中间不再留缝。
        // 之前 spacing: 3 + .vertical 7 + 常量 verticalPadding 14 三重叠加，
        // 浮窗比文字高出一截，观感就是「空隙太大」。
        VStack(spacing: 0) {
            let displayLine = controller.line.isEmpty ? controller.hint : controller.line
            let wantTranslation = controller.showTranslation && !controller.translation.isEmpty
            // 与窗口尺寸同一套字号算法（bilingualSizes）：英文行不低于中文行。
            // 这里若另算一套，会出现「窗口按大字算高、文字按小字画」→ 第二行被裁。
            let sizes = DesktopLyricsLayout.bilingualSizes(
                originalBase: DesktopLyricsLayout.originalFontSize * controller.sizePreset.scale,
                translationBase: DesktopLyricsLayout.translationFontSize * controller.sizePreset.scale,
                original: displayLine,
                translation: controller.translation,
                wantsTranslation: wantTranslation)
            Text(displayLine)
                .font(.system(size: sizes.original, weight: .semibold, design: .rounded))
                .lyricLine(ink: controller.line.isEmpty ? .placeholder : .original)
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if wantTranslation {
                Text(controller.translation)
                    .font(.system(size: sizes.translation, weight: .regular, design: .rounded))
                    .lyricLine(ink: .translation)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 16)
        // 右上角控制条让位：与窗口加宽量同源（DesktopLyricsControlsMetrics.trailingReserve），
        // 文字块右缘停在按钮左侧，hover 淡入药丸也不会压住歌词；
        // 与胶囊 IslandViews 的 .padding(.trailing, lyricTrailingReserve) 同一做法。
        .padding(.trailing, DesktopLyricsControlsMetrics.trailingReserve)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        // macOS 26+ 用系统 Liquid Glass 底板（浮窗是 clear 无边框面板，玻璃会正确
        // 采样后面的桌面内容）；旧系统回退「薄材质 + 暗色罩层」，观感不回退。
        .lyricsGlassBackdrop(cornerRadius: 10)
        .environment(\.colorScheme, .dark)
    }
}

/// 承载浮窗内容的 hosting 视图：整窗可拖拽（原生 performDrag，按下->拖动->松手回调）。
private final class DesktopLyricsHostingView<Content: View>: NSHostingView<Content> {
    /// 拖拽结束：回传松手时的窗口原点（控制器负责钳制 + 持久化）。
    var onDragEnd: ((CGPoint) -> Void)?
    /// 拖拽开始：通知控制器暂停 applyLayout 的原点回填。
    var onDragBegan: (() -> Void)?
    /// 鼠标进入/离开浮窗：驱动右上角控制条淡入淡出。
    var onHoverChange: ((Bool) -> Void)?
    /// 滚轮纵向滚动：上下循环切换字号档位。
    var onSizeScroll: ((CGFloat) -> Void)?
    /// 右键短按（无修饰键）→ 播放/暂停。逻辑抄胶囊 IslandPanel.onAuxClick。
    var onRightClick: (() -> Void)?
    /// 是否正在拖拽：仅供 open/closed hand 光标切换使用。
    private var dragging = false
    /// 右键按下时带了修饰键：抬起时不触发播控（与胶囊 suppressAuxClick 同义）。
    private var suppressRightClick = false
    /// 兜底手动拖拽是否已接管：performDrag 未吃下本次拖动时置 true。
    private var manualDragActive = false
    /// 兜底手动拖拽的锚点（按下瞬间的光标位置与窗口原点）。
    private var dragStartMouse: CGPoint = .zero
    private var dragStartWindowOrigin: CGPoint = .zero

    /// 非激活面板也要能「第一下就抓住」：否则首次点击只用来激活、窗口不动。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 原生拖动优先：交给 WindowServer 按显示刷新率跟踪光标，比在 mouseDragged 里
    /// 逐事件手写 setFrameOrigin 更跟手，也不受歌词变化导致的窗口宽度变化影响。
    override func mouseDown(with event: NSEvent) {
        guard event.type == .leftMouseDown else { return }
        manualDragActive = false
        dragStartMouse = event.locationInWindow
        dragStartWindowOrigin = window?.frame.origin ?? .zero
        dragging = true
        onDragBegan?()
        window?.invalidateCursorRects(for: self)
        window?.performDrag(with: event)
        // performDrag 接管时会阻塞到松手；未接管时它立即返回、窗口尚未移动，
        // 此时绝不能按旧原点收尾（否则兜底拖完的位置不会被持久化）。
        // 收尾判据：兜底已接管，或原生拖动确实改变了原点（纯单击两者都不成立，
        // 而纯单击本就无需重写位置，交给后续 mouseDragged / mouseUp 即可）。
        guard manualDragActive || window?.frame.origin != dragStartWindowOrigin else { return }
        dragging = false
        onDragEnd?(window?.frame.origin ?? .zero)
    }

    /// 兜底手动拖拽：仅当 performDrag 未接管时才会被调用。
    /// 与原生路径同样按光标所在屏松钳制，行为保持一致（可跨屏、松手不跳）。
    ///
    /// 关键：锚点必须用「实时窗口原点」而不是按下时记录的那个。locationInWindow 是
    /// 窗口局部坐标，会随窗口移动而变化；若拿启动原点相加，每步只能兑现一半位移，
    /// 表现为拖拽掉速、原地来回蹭。改用实时原点后每步都收敛到正确目标，
    /// 且与原生拖动同时生效时结果一致（幂等）。
    override func mouseDragged(with event: NSEvent) {
        guard dragging, let window else { return }
        manualDragActive = true
        let current = event.locationInWindow
        let currentOrigin = window.frame.origin
        let raw = CGPoint(x: currentOrigin.x + (current.x - dragStartMouse.x),
                          y: currentOrigin.y + (current.y - dragStartMouse.y))
        // 按光标落在哪块屏来钳制：跨屏拖动时窗口能跟着光标过去，不会在屏缘硬停，
        // 也不会因按另一块屏的边界钳制而被瞬移。用松钳制，与松手时同规则。
        let visible = DesktopLyricsLayout.screenFrame(
            containing: NSEvent.mouseLocation, screens: NSScreen.screens.map(\.frame))
        window.setFrameOrigin(DesktopLyricsLayout.clampAllowingOverhang(
            origin: raw, size: window.frame.size, visibleFrame: visible))
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        onDragEnd?(window?.frame.origin ?? .zero)
    }

    /// 右键 → 播放/暂停。结构与胶囊 CapsuleHostingView 逐行对齐：按下只记录，
    /// 抬起且未被修饰键变体占用时才动作。
    ///
    /// 为什么是右键：左键已被整窗拖拽占用（见 mouseDown 的 performDrag），
    /// 中键留给切歌、滚轮留给字号（与胶囊同一套键位观）。
    override func rightMouseDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // 修饰键组合不触发播控：桌面歌词只做「裸右键=播放/暂停」，
        // 与胶囊 onAuxClick 对齐；shift/option 等变体留给以后扩展。
        suppressRightClick = !flags.intersection([.shift, .option, .command, .control]).isEmpty
        super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        if !suppressRightClick { onRightClick?() }
        suppressRightClick = false
        super.rightMouseUp(with: event)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: dragging ? .closedHand : .openHand)
    }

    // MARK: - 悬停检测（驱动右上角控制条显隐）

    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea {
            removeTrackingArea(hoverArea)
        }
        // activeAlways：非激活面板（nonactivating）也要能感知指针进出。
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }

    /// 滚轮切换字号：向上 next、向下 previous；锁定时由控制器侧忽略。
    override func scrollWheel(with event: NSEvent) {
        onSizeScroll?(event.scrollingDeltaY)
    }
}

/// 悬停控制条：字号小/中/大三档 + 隐藏浮窗，常驻浮窗右上角，鼠标进入浮窗时淡入。
///
/// 早期用 AppKit NSView 手搓，是为了绕开「内容 hosting 视图的整窗拖拽吃掉子视图点击」。
/// 现在改用独立 `NSHostingView` 承载与胶囊**同一份** SwiftUI Liquid Glass 控件
/// （`CapsuleLyricsControls`）：命中测试按视图层级先落到控制条自己的 hosting 视图上，
/// SwiftUI 按钮正常收点击，控制条以外的区域仍由内容 hosting 视图负责整窗拖拽。
/// 控件自身 `@ObservedObject` 订阅 `MusicController`，档位选中态自动同步，无需回推。
/// 不持有控制器强引用（只回调闭包），避免 面板 -> hosting -> 控制条 -> 控制器 的循环。
private final class DesktopLyricsControlsBar: NSHostingView<CapsuleLyricsControls> {
    /// 整幅尺寸改由共享 metrics 单一来源提供（四枚 22pt 药丸 + 3 个 2pt 间隔
    /// + 上下各 3pt 留白 = 100x26），与胶囊侧彻底不分叉。
    static var barWidth: CGFloat { DesktopLyricsControlsMetrics.barWidth }
    static var barHeight: CGFloat { DesktopLyricsControlsMetrics.barHeight }

    /// 隐藏动作在构造时就写进根视图闭包：不能等 super.init 之后再改 `rootView.onHide`，
    /// 实测那样注入的回调不生效（× 点了没反应）；字号档位走的是视图内对 MusicController
    /// 的直接读写、不经闭包，所以只有 × 会静默失效。
    /// 闭包捕获 `music`（控制器强持有的单例）而非 self：既避开「self 先于 super.init
    /// 使用」的限制，也不形成 面板 -> hosting -> 控制条 -> 控制器 的环。
    init(music: MusicController) {
        super.init(rootView: CapsuleLyricsControls(music: music, visible: true) {
            music.hideDesktopLyricsWindow()
        })
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// NSHostingView 的 required 入口：补齐同样的固定几何 + 默认透明，避免漏配导致
    /// 控制条尺寸/命中测试跑偏。
    required init(rootView: CapsuleLyricsControls) {
        super.init(rootView: rootView)
        configure()
    }

    private func configure() {
        // 固定几何：关掉「按 fitting size 自适应」，否则 SwiftUI 会按自身 fitting size
        // 覆盖外层钉在右上角的 100x26 位置与尺寸。显隐由控制器的 alpha 动画负责。
        sizingOptions = []
        wantsLayer = true
        setFrameSize(NSSize(width: Self.barWidth, height: Self.barHeight))
        // 默认透明 + isHidden：不可见时不参与命中测试，不会拦住右上角的整窗拖拽；
        // 悬停进入时先 isHidden=false 再淡入（见控制器 setControlsVisible）。
        alphaValue = 0
        isHidden = true
    }

    /// 非激活面板（nonactivating）也要能「第一下就抓住」：否则首次点击只用来激活面板，
    /// 按钮不触发。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
