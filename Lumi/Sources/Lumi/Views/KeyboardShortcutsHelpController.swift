import AppKit
import SwiftUI

/// 快捷键说明面板的承载控制器。
///
/// 用户要求「快捷键的提示要让用户有办法找到」，同时明确「不要每次启动就跳出来」。
/// 因此这里的约束是：只在用户显式点击菜单栏 / 胶囊右键菜单的那一刻出现，
/// 启动、切 Space 都不会自动呈现。
///
/// 「不自己跳出来」的三个保证：
/// 1. collectionBehavior 不放 canJoinAllSpaces —— 否则面板跟着所有 Space 常驻，
///    用户切到别的桌面又看到它，观感就是「又弹出来了」；
/// 2. show() 没有任何启动期调用：applicationDidFinishLaunching / init /
///    viewDidAppear 都不碰它，唯一入口是 NSMenuItem 的 selector；
/// 3. 用户点了面板以外的桌面位置就关掉（globalMouseMonitor），
///    下一次出现必须再点一次菜单项。
///
/// 为什么用「点了别的窗口就关」而不是 hidesOnDeactivate / windowDidResignKey：
/// Lumi 是 .accessory 激活策略（main.swift），永远不会成为 active app，
/// 这两个回调在本机实测都不触发，面板会一直赖在屏幕上。
final class KeyboardShortcutsHelpController {
    static let shared = KeyboardShortcutsHelpController()

    private var panel: NSPanel?
    /// 全局左键监听 token：必须保存，否则无法在 deinit 移除。
    /// 只监听「点落在别处」，不用 addLocalMonitorForEvents —— 面板自身
    /// 的点击由窗口系统正常处理，本地监听会把它也吃掉。
    private var outsideClickMonitor: Any?

    private init() {}

    /// 打开（或提起已有）说明面板。仅在用户点击菜单项时被调用。
    func show() {
        if let panel, panel.isVisible {
            panel.orderFrontRegardless()
            return
        }
        // 上一次的面板已关：丢弃旧对象重新建一个，
        // 别把已 orderOut 的窗口重新 orderFront——那会让用户没点也看到它。
        if panel != nil { forgetPanel() }

        let root = KeyboardShortcutsHelpView(onClose: { [weak self] in self?.hide() })
        let hosting = NSHostingView(rootView: root)
        // 关掉「按内容自适应」：视图内宽度已用 .frame 固定，自适应会把窗口
        // 撑成 ScrollView 的 fitting 高度，出现两条滚动条。
        hosting.sizingOptions = []

        // 首帧尺寸与视图 .frame(width: 468, maxHeight: 540) 对齐，避免先小后跳。
        let contentRect = NSRect(x: 0, y: 0, width: 468, height: 540)
        let panel = NSPanel(contentRect: contentRect,
                            styleMask: [.titled, .closable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.titleVisibility = .visible
        panel.titlebarAppearsTransparent = true
        panel.title = "快捷键与手势"
        panel.isFloatingPanel = true
        panel.level = .floating
        // 关掉时释放：下次打开按当前外观重新建，保证深浅色切换后立刻跟上。
        panel.isReleasedWhenClosed = true
        // 不放 .canJoinAllSpaces / .fullScreenAuxiliary：面板只属于当前 Space。
        panel.collectionBehavior = []
        self.panel = panel
        installOutsideClickMonitor()

        // 居中在主屏可见区，用户在菜单栏点完立刻能看到，不用去找窗口。
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let size = panel.frame.size
            let origin = CGPoint(
                x: screen.visibleFrame.midX - size.width / 2,
                y: screen.visibleFrame.midY - size.height / 2
            )
            panel.setFrameOrigin(origin)
        }

        // 标题栏右侧关窗钮：标准 close 行为。
        let closeButton = panel.standardWindowButton(.closeButton)
        closeButton?.target = self
        closeButton?.action = #selector(closeFromTitlebar)
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
    }

    /// 关闭面板并清理（视图内按钮、标题栏关窗钮、点到外面都会走到这里）。
    func hide() {
        forgetPanel()
    }

    @objc private func closeFromTitlebar() {
        hide()
    }

    /// 装全局左键监听：落在面板外的点击立刻关掉面板。
    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown)
        { [weak self] _ in
            guard let self, let panel = self.panel else { return }
            let point = NSEvent.mouseLocation
            // 点在自己身上不关：关闭只应由「外面点一下」或显式关窗钮触发。
            if panel.frame.contains(point) { return }
            self.hide()
        }
    }

    /// 先移除全局监听再 close、清引用，避免监听回调打到已释放的面板。
    private func forgetPanel() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
        panel?.close()
        panel = nil
    }

    deinit {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
