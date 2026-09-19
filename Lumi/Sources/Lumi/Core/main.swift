import AppKit
import SwiftUI

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

    /// 胶囊上的空闲鼠标手势回调（由 IslandWindowController 注入）。
    /// 左键位已被占满（单击展开 / 双击重置歌词 / 长按微调），故用右键、中键、滚轮承载播控。
    /// 注意：这些回调只能由 contentView（CapsuleHostingView）触发一次；不要在本面板重写
    /// 同名鼠标方法，否则同一次点击会经响应链触发两次，toggle 类动作相互抵消等于没反应。
    var onAuxClick: (() -> Void)?        // 右键短按 → 播放/暂停
    var onAuxLongPress: (() -> Void)?    // 右键长按 → 快捷菜单
    var onMiddleClick: (() -> Void)?     // 中键 → 下一首（仅三键鼠标可用）
    var onRightShiftClick: (() -> Void)? // Shift+右键 → 下一首（通用键位）
    var onRightOptionClick: (() -> Void)?// Option+右键 → 上一首（通用键位）
    var onScroll: ((CGFloat) -> Void)?   // 滚轮 → 音量
}

/// 胶囊内容承载视图。AppKit 会把内容区的鼠标事件先派发给命中的视图（NSHostingView），
/// 因此在这一层重写各鼠标方法最可靠（NSWindow 的 rightMouseDown 在内容区反而不会被调用）。
final class CapsuleHostingView<Content: View>: NSHostingView<Content> {
    /// 右键长按判定阈值：按住超过该时长即弹快捷菜单，短按则播放/暂停。
    private let longPressDelay: TimeInterval = 0.45
    private var rightHoldWork: DispatchWorkItem?
    private var rightLongPressed = false
    /// 带修饰键的右键已在按下时处理，抬起时不要再当成短按播控。
    private var suppressAuxClick = false

    override func rightMouseDown(with event: NSEvent) {
        let panel = window as? IslandPanel
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // 修饰键变体（触控板/Magic Mouse 也能用，不依赖中键）
        if flags.contains(.shift) {
            suppressAuxClick = true
            panel?.onRightShiftClick?()
            super.rightMouseDown(with: event)
            return
        }
        if flags.contains(.option) {
            suppressAuxClick = true
            panel?.onRightOptionClick?()
            super.rightMouseDown(with: event)
            return
        }

        suppressAuxClick = false
        rightLongPressed = false
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.rightLongPressed = true
            (self.window as? IslandPanel)?.onAuxLongPress?()
        }
        rightHoldWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + longPressDelay, execute: work)
        super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        rightHoldWork?.cancel()
        rightHoldWork = nil
        // 短按（长按未触发、且非修饰键变体）才视为「播放/暂停」。
        if !rightLongPressed && !suppressAuxClick {
            (window as? IslandPanel)?.onAuxClick?()
        }
        rightLongPressed = false
        suppressAuxClick = false
        super.rightMouseUp(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        // 注：触控板 / Magic Mouse 不会产生中键事件，本方法不会触发；
        // 切歌请用 ⇧/⌥ + 右键（见 IslandWindowController 的键位说明）。
        (window as? IslandPanel)?.onMiddleClick?()
        super.otherMouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        (window as? IslandPanel)?.onScroll?(event.scrollingDeltaY)
        super.scrollWheel(with: event)
    }
}



// MARK: - main
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
