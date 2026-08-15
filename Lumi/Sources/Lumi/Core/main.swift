import AppKit
import SwiftUI
import Combine

// MARK: - 应用入口
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var islandController: IslandWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 隐藏 Dock 图标（纯动态岛应用）
        NSApp.setActivationPolicy(.accessory)

        // 提前初始化音乐控制器：使其在后台持续轮询播放状态，
        // 即使胶囊窗口处于隐藏(orderOut)状态也能实时更新，
        // 避免弹出时才发现状态停留在初始的"未在播放"。
        _ = MusicController.shared

        // 提前加载许可证状态，检测付费功能是否可用
        _ = LicenseManager.shared

        // 请求 Apple Music 授权（媒体与 Apple Music），用于读取官方歌词（带时间轴）。
        // 必须在主线程调用，首次会弹出系统授权窗。用户拒绝也不影响其他功能。
        Task { @MainActor in
            _ = await MusicKitLyricsProvider.ensureAuthorized()
        }

        islandController = IslandWindowController()
        islandController?.show()

        // 暴露全局引用，供模块调用
        SharedIslandController.controller = islandController
    }
}

/// 全局可访问的窗口控制器
final class SharedIslandController {
    static var controller: IslandWindowController?
}

/// 动态岛面板：默认是 nonactivating（不抢焦点、不成为 key window）。
/// 游戏模块需要接收键盘时，临时把 `wantsKeyboardCapture` 置 true，
/// 使其能成为 key window 并把键盘事件交给内嵌的 WKWebView；切走即恢复。
final class IslandPanel: NSPanel {
    var wantsKeyboardCapture: Bool = false
    override var canBecomeKey: Bool { wantsKeyboardCapture }
}

// MARK: - 动态岛窗口控制器
final class IslandWindowController: NSObject {
    private var window: NSPanel!
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var mouseMonitor: Any?
    private var mouseDownMonitor: Any?
    private var hideTimer: Timer?
    /// 记录上一次鼠标是否处于热区，用于区分"重新进入"与"停留在热区"
    private var wasInZone: Bool = false

    /// 动态岛触发热区：屏幕顶部中央的一条不可见横带。
    /// 注意：内置屏（带刘海）的热区不再写死为固定 28×320，而是根据
    /// 当前 MacBook 型号的刘海实际度量（safeAreaInsets）精确计算，
    /// 以贴合不同机型（14"/16"，不同缩放比）的真实刘海尺寸与位置。
    /// 下面这两个值仅作为「无刘海机型 / 合盖外接屏」的兜底热区尺寸。
    private let fallbackHotZoneHeight: CGFloat = 20
    private let fallbackHotZoneWidth: CGFloat = 320

    /// 合盖回退到外接屏时的热区尺寸。
    /// 外接屏顶部是普通菜单栏（右侧状态栏图标、左侧应用菜单都在此），
    /// 沿用内置屏的刘海热区会频繁误触发，故显著收窄收薄。
    private let externalHotZoneHeight: CGFloat = 4
    private let externalHotZoneWidth: CGFloat = 160

    /// 内置屏（带刘海）刘海的真实宽度（pt）。
    /// 注意：macOS 的 `safeAreaInsets.left/right` 在带刘海屏上恒为 0
    /// （刘海只居于顶部中央，不会把安全区左右撑开），因此不能用
    /// `frame.width - left - right` 推导——那会得到整屏宽，使热区横跨整个顶部，
    /// 鼠标还没碰到刘海就误触发。真实刘海宽度约 250pt 且始终水平居中，
    /// 故这里用固定的近似值并居中定位，确保只有鼠标真正进入凹槽才触发胶囊。
    private let builtInNotchWidth: CGFloat = 250

    /// 收缩态黑岛宽度/高度上限：跟随 AppState.capsuleSize（用户可在设置中调节），
    /// 不再写死常量，让胶囊尺寸真正由用户自定义。
    /// 高度同时取物理刘海高度与该值的较大值，保证歌词不被裁切。

    /// 鼠标移出刘海后立即隐藏（秒）。设为 0 即离开热区下一轮事件就收起，做到「移出刘海立即隐藏」。
    /// 仍保留「鼠标已落在胶囊窗口内则不收起」的守卫，故从刘海移到胶囊（如点固定）不会消失。
    private let hideDelay: TimeInterval = 0
    /// 音乐播放时收缩态小胶囊（含歌词）也遵循「立即隐藏」：离开刘海即收起，不再额外停留。
    private let musicLyricsHideDelay: TimeInterval = 0

    /// 用户手动调整的展开态窗口尺寸；为 nil 时回退到默认 360×480。
    /// 持久化保存，下次展开沿用，避免每次都重新拖。
    private var userSize: NSSize?

    /// 拖拽缩放进行中：期间屏蔽 updateWindowFrame 的"重置回 userSize"逻辑，
    /// 否则面板内鼠标移动触发 isHovering 变化 → applyState → updateWindowFrame
    /// 会用旧 userSize 把窗口拽回原尺寸，导致右下角手柄"拖了等于没拖"。
    private var isResizing: Bool = false

    /// 展开态尺寸可调范围（夹紧用），防止拖到过小无法用或过大飞出屏幕。
    private let minExpandedW: CGFloat = 320
    private let maxExpandedW: CGFloat = 720
    private let minExpandedH: CGFloat = 200
    private let maxExpandedH: CGFloat = 820
    private let userSizeKey = "island_user_size"

    /// 内置屏（MacBook 自带、带刘海的那块）。动态岛只在这块屏上出现，
    /// 外接显示器顶部不触发、也不展示面板。
    /// 判定优先级：safeAreaInsets.top > 0（有刘海）→ 内置显示器类型 → 主屏兜底。
    private var builtInScreen: NSScreen? {
        let screens = NSScreen.screens
        if #available(macOS 12.0, *) {
            if let notched = screens.first(where: { $0.safeAreaInsets.top > 0 }) {
                return notched
            }
        }
        if let builtIn = screens.first(where: { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? CGDirectDisplayID else { return false }
            return CGDisplayIsBuiltin(number) != 0
        }) {
            return builtIn
        }
        // 合盖：内置屏已从 screens 中移除，回退到主屏（外接显示器）
        return NSScreen.main ?? screens.first
    }

    /// 热区与屏幕拓扑相关的缓存。鼠标移动事件每秒触发上百次，
    /// 而 `builtInScreen`/`notchHotZone` 每次都要枚举 NSScreen 并调用 CoreGraphics
    /// （CGDisplayIsBuiltin），重复计算极浪费。缓存一次，仅在屏幕拓扑变化时失效。
    private var cachedBuiltInScreen: NSScreen?
    private var cachedHotZone: CGRect?
    private func invalidateScreenCache() {
        cachedBuiltInScreen = nil
        cachedHotZone = nil
    }
    /// 返回（可能缓存的）内置屏与其刘海热区，避免每次鼠标移动都重算。
    private func activeScreenAndZone() -> (screen: NSScreen, zone: CGRect)? {
        if let s = cachedBuiltInScreen, let z = cachedHotZone { return (s, z) }
        guard let s = builtInScreen else { return nil }
        let z = notchHotZone(for: s)
        cachedBuiltInScreen = s
        let zone = z
        cachedHotZone = zone
        return (s, z)
    }

    /// 给定屏幕是否为真正的内置屏（带刘海 / 内置面板）。
    /// 合盖时 `builtInScreen` 会回退到外接屏，此时返回 false，
    /// 用于切换到更保守的热区尺寸，避免和菜单栏抢鼠标。
    private func isBuiltIn(_ screen: NSScreen) -> Bool {
        if #available(macOS 12.0, *), screen.safeAreaInsets.top > 0 {
            return true
        }
        guard let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? CGDirectDisplayID else { return false }
        return CGDisplayIsBuiltin(number) != 0
    }

    func show() {
        // 载入上次手动调整的窗口尺寸
        if let s = UserDefaults.standard.array(forKey: userSizeKey) as? [CGFloat],
           s.count == 2, s[0] > 0, s[1] > 0 {
            userSize = NSSize(width: s[0], height: s[1])
        }

        let panel = IslandPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .statusBar + 1
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // 关闭窗口级方形阴影：否则会沿整个矩形边缘生成一圈透明直角光晕边框，
        // 与圆角胶囊/面板不贴合。阴影改由 SwiftUI 内容的 .shadow 提供（沿圆角形状）。
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false

        // 关键：让 SwiftUI 内容填满整个窗口
        let hosting = NSHostingView(rootView: ContentView())
        hosting.autoresizingMask = [.width, .height]
        // 让 hosting layer 完全透明，圆角形状由 SwiftUI 内容的 RoundedRectangle 承载；
        // 面板级阴影已关闭，故不会再有沿矩形边缘的透明直角光晕。
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hosting

        self.window = panel

        // 平时完全隐藏，仅鼠标碰触顶部动态岛热区时才弹出
        panel.orderOut(nil)

        // 全局鼠标移动监控：判断指针是否进入动态岛热区
        // 注意：addGlobalMonitorForEvents 需要「辅助功能」权限才能收到事件。
        // 若未授权（如 ad-hoc 签名每次 cdhash 变化导致授权失效），热区不会触发，
        // 此时可改用菜单栏图标手动唤出（见 setupStatusItem）。
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.evaluateHotZone()
        }
        // 局部监控：指针已在本应用窗口内时也持续跟踪
        NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] ev in
            self?.evaluateHotZone()
            return ev
        }

        // 全局/局部鼠标按下监控：在刘海（顶部中央热区）双击可切换胶囊固定状态，
        // 提供不依赖胶囊按钮的快捷固定方式。需「辅助功能」权限（与 hover 一致）。
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] ev in
            self?.handleNotchDoubleClick(event: ev)
        }
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] ev in
            self?.handleNotchDoubleClick(event: ev)
            return ev
        }

        // 菜单栏图标：即使没有辅助功能权限，也能看到应用并手动唤出动态岛
        setupStatusItem()

        // 屏幕拓扑变化（开合盖、插拔显示器、分辨率变更）：
        // 目标屏可能已消失或改变，立即按新的 builtInScreen 重新定位，
        // 否则窗口会滞留在旧屏坐标上直到下次鼠标移动。
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            // 屏幕拓扑变化：内置屏/热区缓存失效，下一次鼠标事件重新计算。
            self.invalidateScreenCache()
            self.updateWindowFrame(expanded: AppState.shared.isExpanded)
            if !AppState.shared.isExpanded {
                self.evaluateHotZone()
            }
        }

        // 订阅展开/收缩状态，自动调整窗口大小与显隐
        AppState.shared.$isExpanded
            .receive(on: RunLoop.main)
            .sink { [weak self] expanded in
                self?.applyState(expanded: expanded)
                self?.updateGameKeyboardCapture()
            }
            .store(in: &cancellables)

        AppState.shared.$isHovering
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyState(expanded: AppState.shared.isExpanded)
            }
            .store(in: &cancellables)

        // 展开态下切换模块时重新计算窗口尺寸：游戏模块自动放大到更适合直接玩的
        // 尺寸，切回其他模块恢复默认；用户手动缩放过的尺寸（userSize）始终优先。
        AppState.shared.$activeModule
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self, AppState.shared.isExpanded else { return }
                self.updateWindowFrame(expanded: true)
                self.updateGameKeyboardCapture()
            }
            .store(in: &cancellables)

        // 播放状态变化：播放时自动切到音乐模块，胶囊内容随之刷新
        MusicController.shared.$playbackState
            .receive(on: RunLoop.main)
            .sink { state in
                if state == .playing, !AppState.shared.isExpanded {
                    AppState.shared.activeModule = .music
                }
            }
            .store(in: &cancellables)

        // 显示开关：关闭=立即隐藏；打开=按当前鼠标位置决定是否弹出
        AppState.shared.$islandEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                AppState.shared.isExpanded = false
                self?.statusToggleItem?.title = enabled ? "隐藏动态岛" : "显示动态岛"
                if enabled {
                    self?.evaluateHotZone()
                } else {
                    // 手动隐藏：立即收起，并标记当前仍在热区内，
                    // 避免鼠标未移动时立刻重新弹出（需离开再触碰才会显示）
                    self?.wasInZone = true
                    self?.hideIsland()
                }
            }
            .store(in: &cancellables)

        // 更新浮层显隐变化：展开态下需要重排窗口高度（给浮层腾出独立空间）
        Updater.shared.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.updateWindowFrame(expanded: AppState.shared.isExpanded)
            }
            .store(in: &cancellables)

        // 胶囊尺寸被用户调节时，立即重排收缩态窗口 frame。
        AppState.shared.$capsuleSize
            .receive(on: RunLoop.main)
            .sink(receiveValue: { [weak self] _ in
                guard let self = self else { return }
                self.updateWindowFrame(expanded: AppState.shared.isExpanded)
            })
            .store(in: &cancellables)
    }

    /// 计算某块屏幕的"动态岛"热区矩形。
    /// - 带刘海的内置屏：热区精确贴合刘海实际区域——
    ///   高度取 `safeAreaInsets.top`（刘海顶部到菜单栏/安全区的距离），
    ///   宽度取固定的刘海真实宽度 `builtInNotchWidth`（macOS 不暴露刘海宽度，
    /// 其 `safeAreaInsets.left/right` 恒为 0，无法由此推导），水平居中于整屏
    /// （`screen.frame` 中心，而非 visibleFrame，因刘海在整屏中线）。
    ///   这样只有鼠标真正进入顶部中央的凹槽才会触发胶囊，
    ///   而不是写死的一条横带或整屏宽的误触发区，避免"还没碰到岛就触发"。
    /// - 无刘海 / 外接屏（合盖场景）：回退到收窄的外部热区。
    private func notchHotZone(for screen: NSScreen) -> CGRect {
        // 合盖 / 外接屏：用保守的小热区
        guard isBuiltIn(screen) else {
            let f = screen.visibleFrame
            let w = externalHotZoneWidth
            let h = externalHotZoneHeight
            return CGRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h)
        }

        let hasNotch = if #available(macOS 12.0, *), screen.safeAreaInsets.top > 0 {
            true
        } else { false }

        guard hasNotch else {
            // 内置屏但无刘海（如旧款 Air/Pro）：用兜底热区
            let f = screen.visibleFrame
            let w = fallbackHotZoneWidth
            let h = fallbackHotZoneHeight
            return CGRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h)
        }

        let frame = screen.frame
        let inset = screen.safeAreaInsets
        // 刘海高度：顶边到安全区顶部的距离
        let notchH = max(inset.top, 18)
        // 刘海宽度：macOS 不暴露刘海真实宽度（safeAreaInsets.left/right 恒为 0），
        // 用固定的居中近似值 `builtInNotchWidth`，避免退化成整屏宽导致整条顶部误触发。
        let notchW = min(builtInNotchWidth, frame.width)
        let zoneX = frame.midX - notchW / 2
        // y：从屏幕顶边往下 notchH（刘海占据整条顶部）
        let zoneY = frame.maxY - notchH
        return CGRect(x: zoneX, y: zoneY, width: notchW, height: notchH)
    }

    /// 判断鼠标是否进入"动态岛"热区（顶部中央横带），据此弹出/收起
    private func evaluateHotZone() {
        guard !AppState.shared.isExpanded else { return }
        let mouse = NSEvent.mouseLocation
        // 复用缓存的屏幕与热区（屏幕拓扑变化时才重算），避免高频鼠标事件下重复枚举屏幕。
        guard let (screen, zone) = activeScreenAndZone() else { return }

        // 仅内置屏参与判定：鼠标在外接显示器上时一律视为离开热区，
        // 立即收起，避免在其他屏顶部误触发面板。
        guard screen.frame.contains(mouse) else {
            wasInZone = false
            if AppState.shared.islandEnabled, !AppState.shared.islandPinned { hideIsland() }
            return
        }

        // 热区按当前屏幕（机型）的刘海实际度量计算，精确贴合。
        // 鼠标落在当前胶囊/面板窗口内也算"在热区"：胶囊显示后，
        // 鼠标从刘海顶往下移到胶囊上这段时间仍判定为在热区，不会被提前收起，
        // 从而能从容单击展开总面板（否则热区只有刘海顶部窄带，极易收起、点不出来）。
        let inZone = zone.contains(mouse) || (window?.isVisible == true && window?.frame.contains(mouse) == true)

        if !AppState.shared.islandEnabled {
            // 主开关已关闭：仍允许 hover "瞥一眼"预览，但【不要把主开关翻成开】——
            // 否则用户在菜单栏手动隐藏后，鼠标一碰刘海又被唤醒，等于隐藏不生效。
            // 离开热区后同样自动收起（与开启态一致），即"鼠标移出刘海后胶囊消失"。
            if inZone, !wasInZone {
                showIsland()
            } else if !inZone {
                scheduleHide()
            }
            wasInZone = inZone
            return
        }

        // 锁定常驻：鼠标离开热区不自动收起，但进入热区（从其他区域移回）仍自动显示
        guard !AppState.shared.islandPinned else {
            wasInZone = inZone
            if inZone {
                hideTimer?.invalidate(); hideTimer = nil
                if !window.isVisible { showIsland() }
            }
            return
        }

        wasInZone = inZone
        if inZone {
            hideTimer?.invalidate(); hideTimer = nil
            // 已在显示则跳过：mouseMoved 每秒触发上百次，重复 orderFront+淡入会卡顿/闪抖。
            if window?.isVisible != true { showIsland() }
        } else {
            scheduleHide()
        }
    }

    /// 双击刘海（顶部中央热区）切换胶囊固定状态。
    /// 双击判定依赖 `NSEvent.clickCount == 2`；热区复用 `notchHotZone(for:)`，
    /// 仅当鼠标落在刘海/外接热区内才触发，避免在菜单栏其它区域双击误触。
    private func handleNotchDoubleClick(event: NSEvent) {
        guard event.clickCount == 2 else { return }
        let point = NSEvent.mouseLocation
        // 复用缓存的屏幕与热区，避免每次点击都枚举屏幕。
        guard let (_, zone) = activeScreenAndZone() else { return }
        guard zone.contains(point) else { return }
        // 切换固定：未固定→钉住常驻并立即弹出胶囊（视觉反馈），
        // 已固定→取消固定并收起。
        togglePin()
    }

    private func scheduleHide() {
        guard AppState.shared.isExpanded == false else { return }
        // 锁定常驻：已钉住则不安排收起，胶囊保持显示
        guard !AppState.shared.islandPinned else {
            hideTimer?.invalidate(); hideTimer = nil
            return
        }
        // 鼠标仍在胶囊（窗口）内时绝不安排自动收起，避免"还没离开胶囊就消失"。
        if window?.isVisible == true, window?.frame.contains(NSEvent.mouseLocation) == true {
            hideTimer?.invalidate(); hideTimer = nil
            return
        }
        // 仅当「音乐模块 + 正在播放」时给较长停留（让歌词多停一会儿），
        // 其他场景维持基础短延迟，避免影响面板下方其他交互与歌词显示。
        let isMusicPlaying = AppState.shared.activeModule == .music &&
            MusicController.shared.playbackState == .playing
        let delay = isMusicPlaying ? musicLyricsHideDelay : hideDelay
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            // 收起前的最后校验：若定时到点时鼠标已回到胶囊内，则取消本次隐藏。
            guard let self = self else { return }
            if self.window?.isVisible == true,
               self.window?.frame.contains(NSEvent.mouseLocation) == true {
                self.hideTimer?.invalidate(); self.hideTimer = nil
                return
            }
            self.hideIsland()
        }
    }

    private func showIsland() {
        guard let panel = window else { return }
        updateWindowFrame(expanded: false)
        panel.alphaValue = 0
        // orderFrontRegardless 不受应用激活状态/窗口层级限制，确保一定能显示
        panel.orderFrontRegardless()
        panel.makeKey()
        // 一比一模仿 NotchAI：靠近刘海时淡入，而非硬弹出
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func hideIsland() {
        guard let panel = window else { return }
        // 淡出后再从屏幕移除，避免硬消失穿帮
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
            panel.alphaValue = 1
        })
    }

    // MARK: - 菜单栏图标（不依赖辅助功能权限的常驻入口）
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = item.button {
            // 模板图（template）+ 单一来源，避免 image/title 互相重叠
            // 优先级：SF Symbol（月亮）> bundle AppIcon > emoji 回退
            // 用 SF Symbol 永远有稳定清晰的月牙图标，不再出现 "dl" 这种 emoji 被裁切的情况
            let symbol = NSImage(
                systemSymbolName: "moon.stars.fill",
                accessibilityDescription: "Lumi"
            )
            if let symbol = symbol {
                symbol.isTemplate = true
                symbol.size = NSSize(width: 16, height: 16)
                btn.image = symbol
                btn.imagePosition = .imageOnly
                btn.title = ""
            } else if let img = NSImage(named: "AppIcon") {
                img.size = NSSize(width: 16, height: 16)
                btn.image = img
                btn.imagePosition = .imageOnly
                btn.title = ""
            } else {
                btn.image = nil
                btn.imagePosition = .noImage
                btn.title = "🌙"
            }
            btn.toolTip = "Lumi 动态岛"
        }
        let menu = NSMenu()
        let toggle = NSMenuItem(title: "显示动态岛", action: #selector(statusToggle), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Lumi", action: #selector(statusQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        self.statusItem = item
        self.statusToggleItem = toggle
    }

    private var statusToggleItem: NSMenuItem?

    @objc private func statusToggle() {
        toggleIsland()
    }

    @objc private func statusQuit() {
        NSApp.terminate(nil)
    }

    /// 由菜单栏图标调用：切换动态岛显隐
    func toggleIsland() {
        if AppState.shared.islandEnabled {
            AppState.shared.islandEnabled = false
            hideIsland()
            statusToggleItem?.title = "显示动态岛"
        } else {
            AppState.shared.islandEnabled = true
            AppState.shared.islandPinned = true   // 锁定常驻，避免鼠标移开即收起
            showIsland()
            statusToggleItem?.title = "隐藏动态岛"
        }
    }

    /// 取消固定：解除常驻锁定并立即收起胶囊，符合"取消固定即消失"的预期。
    /// 之后鼠标移到刘海热区可再次唤出（普通 hover 态），单击即可展开总面板。
    func unpinIsland() {
        AppState.shared.islandPinned = false
        hideIsland()
    }

    /// 固定：常驻显示胶囊（鼠标移开不再收起）。若当前已隐藏则立即唤出。
    func pinIsland() {
        AppState.shared.islandPinned = true
        showIsland()
    }

    /// 切换固定状态：未固定时点击即可固定常驻，已固定时取消固定。
    func togglePin() {
        if AppState.shared.islandPinned {
            unpinIsland()
        } else {
            pinIsland()
        }
    }

    /// 根据当前状态决定窗口尺寸、位置与显隐
    func applyState(expanded: Bool) {
        guard let panel = window else { return }
        if expanded {
            hideTimer?.invalidate(); hideTimer = nil
            updateWindowFrame(expanded: true)
            if !panel.isVisible { panel.orderFront(nil) }
        } else {
            // 收起态：若鼠标仍在热区则保持显示，否则隐藏
            updateWindowFrame(expanded: false)
            evaluateHotZone()
        }
    }

    // 是否正在展示更新浮层（与 UpdateAvailableBanner.shouldShow 条件保持一致）
    private var updaterBannerVisible: Bool {
        switch Updater.shared.status {
        case .available, .downloading, .readyToInstall, .failed:
            if let latest = Updater.shared.latestVersion,
               (latest == Updater.shared.ignoredVersion || latest == Updater.shared.skippedVersion) {
                return false
            }
            return true
        default:
            return false
        }
    }

    func updateWindowFrame(expanded: Bool) {
        // 拖拽缩放进行中：用轻量弹簧动画平滑跟手，避免硬跳变；
        // 但仍保持当前窗口 frame 不被 userSize 重置（否则会被 isHovering 触发覆盖）。
        if isResizing {
            guard let screen = builtInScreen else { return }
            let target = self.frameFor(expanded: expanded, screen: screen)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.window?.animator().setFrame(target, display: true)
            })
            return
        }
        // 固定定位到内置屏（带刘海那块）：动态岛只属于主屏，
        // 不跟随鼠标跑到外接显示器上。
        guard let screen = builtInScreen else { return }
        let frame = frameFor(expanded: expanded, screen: screen)
        // 收缩/预览态（胶囊变形）瞬间定位、不做动画，避免胶囊在宽度/高度变化中
        // 一边重绘一边形变而闪烁；展开态保留平滑动画。
        let animate = expanded
        window?.setFrame(frame, display: true, animate: animate)
    }

    /// 根据展开状态与屏幕计算窗口目标 frame（含刘海贴合、用户尺寸、预览态等逻辑）。
    /// 拖拽缩放期间也复用同一计算，保证缩放后的窗口位置/对齐一致。
    private func frameFor(expanded: Bool, screen: NSScreen) -> NSRect {
        let screenFrame = screen.frame

        // 游戏模块需要更大面板才能直接玩 H5 小游戏，使用专属默认尺寸 480×600；
        // 其他模块维持默认 360×480。用户手动缩放后一律以 userSize 为准。
        let isGame = AppState.shared.activeModule == .game
        let defaultW: CGFloat = isGame ? 480 : 360
        let defaultH: CGFloat = isGame ? 600 : 480
        // 展开态尺寸优先用用户手动调整后的尺寸，否则用模块专属默认值
        // 收缩态尺寸：1:1 贴合物理岛（刘海）本体——
        // 宽取刘海真实宽度（左右安全区之和 = inset.left + inset.right），
        // 高取刘海高度（inset.top）。不额外兜底放大，否则会和真刘海尺寸不一致。
        // 让黑岛与真刘海做到像素级 1:1 重合；无刘海回退为顶部一条 320×42 横条。
        let collapsedW: CGFloat
        let collapsedH: CGFloat
        let inset = screen.safeAreaInsets
        let hasNotch = if #available(macOS 12.0, *), inset.top > 0 { true } else { false }
        if hasNotch {
            // 刘海宽度 = 整屏宽 - 左右安全区（刘海两侧留白），而非安全区之和；
            // 刘海高度 = 安全区顶部距离（inset.top）。
            // 但收缩态黑岛不取满刘海全宽——过宽会挤压其他软件的菜单栏 UI，
            // 因此限制一个最大宽度（默认 360pt），居中贴合刘海底，
            // 既保留「黑岛」观感，又不占满刘海两侧。
            let fullNotchW = max(0, screenFrame.width - inset.left - inset.right)
            collapsedW = min(fullNotchW, AppState.shared.capsuleSize.width)
            // 高度取物理刘海高度与用户设定胶囊高度的较大值，
            // 保证双语歌词完整显示、不被窗口裁切。
            collapsedH = max(inset.top, AppState.shared.capsuleSize.height)
        } else {
            collapsedW = 320
            collapsedH = 42
        }

        let w: CGFloat = expanded ? (userSize?.width ?? defaultW) : collapsedW
        // 更新可用浮层出现时，给展开面板额外增加高度，把浮层放在顶部独立区域，
        // 避免它与下方模块内容（如下载卡片）重叠。
        let updateBannerExtra: CGFloat = (expanded && updaterBannerVisible) ? 96 : 0
        // 窗口高度精确等于内容高度，避免窗口比圆角内容大而露出多余的透明外框：
        // 收缩态贴合物理岛（collapsedH）；hover 预览态与收缩态保持同一体积（不二次放大），
        // 仅显示小胶囊本身；展开态由 userSize/defaultH 决定。
        let h: CGFloat = expanded ? ((userSize?.height ?? defaultH) + updateBannerExtra)
                                  : collapsedH

        let x = screenFrame.midX - w / 2
        let y: CGFloat
        if hasNotch {
            // 所有 UI 都「避开刘海像素区」：窗口从刘海底边（safeAreaInsets.top 之下）
            // 开始向下延伸，绝不覆盖刘海本身。
            // - 收缩态：黑岛紧贴刘海底，宽度=刘海宽，像刘海的延伸；
            // - 展开/预览态：从同一刘海底边向下 + 左右长开，形状与位置都基于刘海。
            // 隐藏时收回到刘海边界之后（由 scheduleHide 淡出），不占用刘海区域。
            y = screenFrame.maxY - inset.top - h
        } else {
            // 无刘海（旧款机型或外接屏）：回退到原逻辑，距顶部 6px
            y = screenFrame.maxY - h - 6
        }

        return NSRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - 游戏键盘捕获

    /// 根据当前状态决定是否让面板接收键盘：
    /// 仅当「展开态 + 当前模块是游戏」时临时成为 key window，把键盘交给 WKWebView；
    /// 其余情况恢复 nonactivating 行为（不抢焦点）。
    private func updateGameKeyboardCapture() {
        let enabled = AppState.shared.isExpanded && AppState.shared.activeModule == .game
        setGameKeyboardCapture(enabled)
    }

    /// 开启/关闭游戏键盘捕获。
    /// - 开启：让面板可成为 key window 并使其成为 key，再把 WKWebView 设为 first responder，
    ///   这样网页内的 keydown 监听即可收到方向键/字母键等输入。
    /// - 关闭：退出 key window，交还焦点。
    private func setGameKeyboardCapture(_ enabled: Bool) {
        guard let panel = window as? IslandPanel else { return }
        panel.wantsKeyboardCapture = enabled
        if enabled {
            panel.makeKey()
            // WKWebView 成为 first responder 后才能稳定接收键盘事件；
            // 稍微延迟以确保窗口/视图层级已就绪。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                GameController.shared.webView?.becomeFirstResponder()
            }
        } else {
            panel.resignKey()
        }
    }

    /// 手动缩放：基于当前窗口 frame，按拖拽增量调整展开态宽高。
    /// dx 向右为正（增宽）；dy 向下为正（增高）。顶部锚定（origin.y 随高度变化）。
    /// 拖拽中实时把最新尺寸记到 userSize，确保即便 updateWindowFrame 被触发
    /// 也只会沿用最新尺寸，不会把面板拽回拖拽前的旧大小。
    func resizeBy(_ delta: NSSize) {
        guard let panel = window else { return }
        isResizing = true
        var f = panel.frame
        let top = f.origin.y + f.size.height
        var newW = f.size.width + delta.width
        var newH = f.size.height + delta.height
        newW = min(max(newW, minExpandedW), maxExpandedW)
        newH = min(max(newH, minExpandedH), maxExpandedH)
        f.size = NSSize(width: newW, height: newH)
        f.origin.y = top - newH
        panel.setFrame(f, display: true, animate: false)
        // 实时更新内存中的用户尺寸，使 updateWindowFrame 与拖拽保持一致
        userSize = f.size
    }

    /// 拖拽结束后，把当前展开态尺寸持久化为用户尺寸，下次展开沿用。
    func saveUserSize() {
        guard let panel = window else { return }
        let s = panel.frame.size
        userSize = s
        isResizing = false
        UserDefaults.standard.set([s.width, s.height], forKey: userSizeKey)
        // 释放缩放锁，允许后续状态变化正常重排窗口
        isResizing = false
    }

    func toggleExpand() {
        AppState.shared.isExpanded.toggle()
    }

    func collapse() {
        AppState.shared.isExpanded = false
    }

    func expand() {
        AppState.shared.isExpanded = true
    }
}

// MARK: - main
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
