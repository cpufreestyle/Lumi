import AppKit

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

// MARK: - main
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
