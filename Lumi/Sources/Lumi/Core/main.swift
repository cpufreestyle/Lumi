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

// MARK: - 动态岛窗口控制器
final class IslandWindowController: NSObject {
    private var window: NSPanel!
    private var cancellables = Set<AnyCancellable>()
    private var mouseMonitor: Any?
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

    /// 鼠标移出后延迟隐藏，避免抖动
    private let hideDelay: TimeInterval = 0.25

    /// 用户手动调整的展开态窗口尺寸；为 nil 时回退到默认 360×480。
    /// 持久化保存，下次展开沿用，避免每次都重新拖。
    private var userSize: NSSize?

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

        let panel = NSPanel(
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
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.evaluateHotZone()
        }
        // 局部监控：指针已在本应用窗口内时也持续跟踪
        NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] ev in
            self?.evaluateHotZone()
            return ev
        }

        // 屏幕拓扑变化（开合盖、插拔显示器、分辨率变更）：
        // 目标屏可能已消失或改变，立即按新的 builtInScreen 重新定位，
        // 否则窗口会滞留在旧屏坐标上直到下次鼠标移动。
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
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
            }
            .store(in: &cancellables)

        AppState.shared.$isHovering
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyState(expanded: AppState.shared.isExpanded)
            }
            .store(in: &cancellables)

        // 播放状态变化：播放时自动切到音乐模块，胶囊内容随之刷新
        MusicController.shared.$playbackState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
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
    }

    /// 计算某块屏幕的"动态岛"热区矩形。
    /// - 带刘海的内置屏：热区精确贴合刘海实际区域——
    ///   高度取 `safeAreaInsets.top`（刘海顶部到菜单栏/安全区的距离），
    ///   宽度取 `2 * safeAreaInsets.left`（刘海左右安全区之和，即刘海真实宽度），
    ///   水平居中于整屏（`screen.frame` 中心，而非 visibleFrame，因刘海在整屏中线）。
    ///   这样不同 MacBook 型号（14"/16"，不同显示缩放）都会对齐到真实刘海，
    ///   而不是写死的一条横带，避免"还没碰到岛就触发"。
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
        // 刘海宽度：左右安全区之和（刘海真实宽度）；太窄时兜底到 320
        let notchW = max(inset.left + inset.right, 240)
        let zoneX = frame.midX - notchW / 2
        // y：从屏幕顶边往下 notchH（刘海占据整条顶部）
        let zoneY = frame.maxY - notchH
        return CGRect(x: zoneX, y: zoneY, width: notchW, height: notchH)
    }

    /// 判断鼠标是否进入"动态岛"热区（顶部中央横带），据此弹出/收起
    private func evaluateHotZone() {
        guard !AppState.shared.isExpanded else { return }
        // 锁定常驻：不根据热区变化收起/弹出，保持显示
        guard !AppState.shared.islandPinned else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = builtInScreen else { return }

        // 仅内置屏参与判定：鼠标在外接显示器上时一律视为离开热区，
        // 立即收起，避免在其他屏顶部误触发面板。
        guard screen.frame.contains(mouse) else {
            wasInZone = false
            if AppState.shared.islandEnabled { hideIsland() }
            return
        }

        // 热区按当前屏幕（机型）的刘海实际度量计算，精确贴合。
        let zone = notchHotZone(for: screen)
        let inZone = zone.contains(mouse)

        if !AppState.shared.islandEnabled {
            // 已隐藏：只有"离开热区后重新进入"才会重新显示（触碰动态岛即显示）
            if inZone, !wasInZone {
                AppState.shared.islandEnabled = true
                showIsland()
            }
            wasInZone = inZone
            return
        }

        wasInZone = inZone
        if inZone {
            hideTimer?.invalidate(); hideTimer = nil
            showIsland()
        } else {
            scheduleHide()
        }
    }

    private func scheduleHide() {
        guard AppState.shared.isExpanded == false else { return }
        // 锁定常驻：已钉住则不安排收起，胶囊保持显示
        guard !AppState.shared.islandPinned else {
            hideTimer?.invalidate(); hideTimer = nil
            return
        }
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: hideDelay, repeats: false) { [weak self] _ in
            self?.hideIsland()
        }
    }

    private func showIsland() {
        guard let panel = window else { return }
        updateWindowFrame(expanded: false)
        if !panel.isVisible { panel.orderFront(nil) }
    }

    private func hideIsland() {
        window?.orderOut(nil)
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

    func updateWindowFrame(expanded: Bool) {
        // 固定定位到内置屏（带刘海那块）：动态岛只属于主屏，
        // 不跟随鼠标跑到外接显示器上。
        guard let screen = builtInScreen else { return }
        let screenFrame = screen.visibleFrame

        let peeking = AppState.shared.isHovering && !expanded
        // 展开态尺寸优先用用户手动调整后的尺寸，否则默认 360×480
        let w: CGFloat = expanded ? (userSize?.width ?? 360) : 320
        // 窗口高度精确等于内容高度，避免窗口比圆角内容大而露出多余的透明外框：
        // 收缩态 CollapsedView 高 42；peek 态 = 预览区 + 胶囊 42 + 底部 6；展开态 480。
        // 收缩/peek 态高度固定，不受手动调整影响。
        let h: CGFloat = expanded ? (userSize?.height ?? 480) : (peeking ? 132 : 42)
        // 居中于目标屏幕顶部，紧贴菜单栏下方，避开刘海
        let x = screenFrame.midX - w / 2
        let y = screenFrame.maxY - h - 6

        window?.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true, animate: true)
    }

    /// 手动缩放：基于当前窗口 frame，按拖拽增量调整展开态宽高。
    /// dx 向右为正（增宽）；dy 向下为正（增高）。顶部锚定（origin.y 随高度变化）。
    func resizeBy(_ delta: NSSize) {
        guard let panel = window else { return }
        var f = panel.frame
        let top = f.origin.y + f.size.height
        var newW = f.size.width + delta.width
        var newH = f.size.height + delta.height
        newW = min(max(newW, minExpandedW), maxExpandedW)
        newH = min(max(newH, minExpandedH), maxExpandedH)
        f.size = NSSize(width: newW, height: newH)
        f.origin.y = top - newH
        panel.setFrame(f, display: true, animate: false)
    }

    /// 拖拽结束后，把当前展开态尺寸持久化为用户尺寸，下次展开沿用。
    func saveUserSize() {
        guard let panel = window else { return }
        let s = panel.frame.size
        userSize = s
        UserDefaults.standard.set([s.width, s.height], forKey: userSizeKey)
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
