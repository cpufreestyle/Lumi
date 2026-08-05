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
        // 避免弹出时才发现状态停留在初始的“未在播放”。
        _ = MusicController.shared

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

    /// 动态岛触发热区：屏幕顶部中央的一条不可见横带
    private let hotZoneHeight: CGFloat = 28
    /// 鼠标移出后延迟隐藏，避免抖动
    private let hideDelay: TimeInterval = 0.25

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
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false

        // 关键：让 SwiftUI 内容填满整个窗口
        let hosting = NSHostingView(rootView: ContentView())
        hosting.autoresizingMask = [.width, .height]
        // 必须让 hosting layer 完全透明，否则窗口级阴影会沿整个矩形边缘
        // 生成一圈方形光晕（“透明外壳”），而非沿胶囊圆角形状。
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hosting

        self.window = panel

        // 平时隐藏，仅鼠标碰触顶部动态岛热区时弹出
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
    }

    /// 判断鼠标是否进入"动态岛"热区（顶部中央横带），据此弹出/收起
    private func evaluateHotZone() {
        guard !AppState.shared.isExpanded else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main) else { return }
        let f = screen.visibleFrame
        // 热区：顶部 hotZoneHeight 高度、水平居中 320 宽的范围
        let zoneX = f.midX - 160
        let inZone = mouse.y >= f.maxY - hotZoneHeight
                   && mouse.x >= zoneX && mouse.x <= zoneX + 320
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
        guard !AppState.shared.isExpanded else { return }
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
        // 优先定位到鼠标当前所在屏幕，保证胶囊出现在用户正在使用的屏幕上
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
                  ?? NSScreen.main
                  ?? NSScreen.screens.first
        guard let screen = screen else { return }
        let screenFrame = screen.visibleFrame

        let peeking = AppState.shared.isHovering && !expanded
        let w: CGFloat = expanded ? 360 : 320
        let h: CGFloat = expanded ? 480 : (peeking ? 132 : 48)
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
