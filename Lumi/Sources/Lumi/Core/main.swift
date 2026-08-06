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

    /// 动态岛触发热区：屏幕顶部中央的一条不可见横带
    private let hotZoneHeight: CGFloat = 28
    /// 热区宽度（内置屏：与刘海/胶囊同宽区域）
    private let hotZoneWidth: CGFloat = 320

    /// 合盖回退到外接屏时的热区尺寸。
    /// 外接屏顶部是普通菜单栏（右侧状态栏图标、左侧应用菜单都在此），
    /// 沿用内置屏的 28×320 会频繁误触发，故显著收窄收薄。
    private let externalHotZoneHeight: CGFloat = 4
    private let externalHotZoneWidth: CGFloat = 160

    /// 鼠标移出后延迟隐藏，避免抖动
    private let hideDelay: TimeInterval = 0.25

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

    /// 判断鼠标是否进入"动态岛"热区（顶部中央横带），据此弹出/收起
    private func evaluateHotZone() {
        guard !AppState.shared.isExpanded else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = builtInScreen else { return }

        // 仅内置屏参与判定：鼠标在外接显示器上时一律视为离开热区，
        // 立即收起，避免在其他屏顶部误触发面板。
        guard screen.frame.contains(mouse) else {
            wasInZone = false
            if AppState.shared.islandEnabled { hideIsland() }
            return
        }

        let f = screen.visibleFrame
        // 热区：顶部一条水平居中的横带。
        // 内置屏用 28×320（贴合刘海区域）；合盖回退到外接屏时改用 4×160，
        // 因为外接屏顶部是普通菜单栏，大热区会频繁误触发。
        let builtIn = isBuiltIn(screen)
        let zoneH = builtIn ? hotZoneHeight : externalHotZoneHeight
        let zoneW = builtIn ? hotZoneWidth : externalHotZoneWidth
        let zoneX = f.midX - zoneW / 2
        let inZone = mouse.y >= f.maxY - zoneH
                   && mouse.x >= zoneX && mouse.x <= zoneX + zoneW

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
        let w: CGFloat = expanded ? 360 : 320
        // 窗口高度精确等于内容高度，避免窗口比圆角内容大而露出多余的透明外框：
        // 收缩态 CollapsedView 高 42；peek 态 = 预览区 + 胶囊 42 + 底部 6；展开态 480。
        let h: CGFloat = expanded ? 480 : (peeking ? 132 : 42)
        // 居中于目标屏幕顶部，紧贴菜单栏下方，避开刘海
        let x = screenFrame.midX - w / 2
        let y = screenFrame.maxY - h - 6

        window?.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true, animate: true)
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
