import AppKit
import SwiftUI

// MARK: - 应用入口
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var islandController: IslandWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 隐藏 Dock 图标（纯动态岛应用）
        // 单实例护栏必须排在最前：MusicController.shared 会立刻起 AppleScript 轮询、
        // IslandWindowController 会抢同一个刘海面板的位置，都得先确认「只有我这个实例」。
        guard LumiInstanceGuard.ensureSingleInstance() else {
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return
        }

        NSApp.setActivationPolicy(.accessory)

        // 提前初始化音乐控制器：使其在后台持续轮询播放状态，
        // 即使胶囊窗口处于隐藏(orderOut)状态也能实时更新，
        // 避免弹出时才发现状态停留在初始的"未在播放"。
        _ = MusicController.shared

        // AI CLI 用量扫描同样要在启动时预热。CLIUsageController 是懒加载单例，
        // 只有面板视图创建时才初始化；岛屿隐藏/关闭时没人触碰它，日志扫描和
        // 条目落盘都不会发生，用户看到的就是「历史数据丢失」。启动即注册轮询
        // （面板可见 30s、隐藏 15min 兜底），保持后台增量扫描与条目落盘。
        _ = CLIUsageController.shared

        // 实例启动留痕：排障手册「歌词链路静默失效」判定前，先排除双实例互相打断
        MusicController.shared.logInstanceLaunch()

        // 提前加载许可证状态，检测付费功能是否可用
        _ = LicenseManager.shared

        // 提前装配会议提醒调度器：注册通知分类与 delegate，
        // 确保日历刷新排下的会前 1 分钟提醒能带「加入会议」动作。
        _ = MeetingReminderScheduler.shared

        // 装配下载完成通报：链式级联前级 delegate（会议提醒），前后台都能收到完成横幅
        _ = DownloadNotifier.shared

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

/// 单实例护栏。本机既装有 /Applications/Lumi.app（旧构建），开发时又常跑 .build/Lumi.app，
/// 双开时两个实例各建一个刘海面板、各起一份 AppleScript 轮询；旧实例一旦卡死，就会用一份
/// 「不再刷新」的歌词面板盖住正常实例，用户看到的现象正是「无法获取歌词」。
///
/// 实现：Application Support 下 lumi.instance.lock 上 flock(LOCK_EX | LOCK_NB)。后启动者不
/// 直接退出，而是先请先启动者退出（3 秒内接管），这样用户从启动台点旧版图标也能自动收敛到
/// 唯一实例。动手杀之前用 proc_pidpath 校验目标确实是 Lumi，避免锁文件里的陈旧 pid 被系统
/// 回收后误杀无关进程。
enum LumiInstanceGuard {
    private static let lockFileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Lumi/lumi.instance.lock")
    }()

   /// 持锁方是否已订阅 didLaunch 通知（ensureSingleInstance 只会成功执行一次，防御重复注册）。
    /// 持锁期间的自检定时器：必须强引用，否则 DispatchSource 被释放后不再触发。
    private static var ownershipWatchdog: DispatchSourceTimer?

    /// 返回 false 表示本实例应立即退出（已由先启动者接管）。
    static func ensureSingleInstance() -> Bool {
        let url = lockFileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else {
            NSLog("[Lumi/Instance] 锁文件打开失败，按单实例继续启动: " + url.path)
            return true
        }
        if tryLock(fd) {
            assumeOwnership(fd)
            return true
        }
        let holder = readHolder(fd)
        takeover(holder: holder, fd: fd)
        let deadline = Date().timeIntervalSince1970 + 3
        while Date().timeIntervalSince1970 < deadline {
            if tryLock(fd) {
                NSLog("[Lumi/Instance] 已接管单实例锁，旧实例 pid=" + String(holder) + " 已退出")
                assumeOwnership(fd)
                return true
            }
            usleep(50_000)
        }
        close(fd)
        NSLog("[Lumi/Instance] 拿不到单实例锁（旧实例 pid=" + String(holder) + " 未退出），本实例退出以免出现两份界面")
        // 退出前把锁文件恢复成旧实例的 pid：自检定时器读到非自己的 pid 会一直让位，
        // 不恢复的话旧实例此后再也不清扫异类实例了。
        becomeOwner(fd)
        return false
    }

    private static func tryLock(_ fd: Int32) -> Bool {
        flock(fd, LOCK_EX | LOCK_NB) == 0
    }

    /// 把 pid 写进锁文件：进程退出后内核会自动释放 flock，锁 fd 无需显式 close。
    private static func becomeOwner(_ fd: Int32) {
        let pid = String(ProcessInfo.processInfo.processIdentifier)
        ftruncate(fd, 0)
        lseek(fd, 0, SEEK_SET)
        _ = pid.withCString { ptr in write(fd, ptr, Int(strlen(ptr))) }
    }

    private static func readHolder(_ fd: Int32) -> pid_t {
        lseek(fd, 0, SEEK_SET)
        var buf = [UInt8](repeating: 0, count: 32)
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { return 0 }
        let text = String(decoding: buf.prefix(n), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return pid_t(text) ?? 0
    }

    /// 校验目标进程确实是 Lumi：锁文件里的 pid 可能已被系统回收给别的进程。
    private static func isLumiProcess(_ pid: pid_t) -> Bool {
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier else { return false }
        return lumiExecutable(pid) != nil
    }

    /// 拿到锁后的统一收尾：登记自己是持有者，拉起自检定时器，再清扫已在场的其他实例。
    private static func assumeOwnership(_ fd: Int32) {
        becomeOwner(fd)
        startOwnershipWatchdog()
        terminateOtherLumiInstances()
    }

    /// 持锁期间的自检：NSWorkspace didLaunch 通知在本机实测收不到（macOS 26.5，
    /// 独立脚本进程与真机 App 双双复现），兜底只能靠轮询。每 2 秒扫一遍全进程，
    /// 发现异类 Lumi 实例就请走——用户点启动台旧图标拉起 8 月旧构建时，下一拍即可收敛，
    /// 双实例盖面板导致「无法获取歌词」的路径才堵得死。
    private static func startOwnershipWatchdog() {
        guard ownershipWatchdog == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 2, repeating: 2.0, leeway: .milliseconds(500))
        timer.setEventHandler {
            enforceOwnership()
        }
        ownershipWatchdog = timer
        timer.resume()
    }

    /// 自检单拍：锁文件里登记的是自己才动手。接管者会先把自己写进锁文件「挂号」，
    /// 此时读到非自己的 pid 应让位，避免把正常的换锁反杀。
  private static func enforceOwnership() {
        let url = lockFileURL
        let fd = open(url.path, O_RDWR)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let holder = readHolder(fd)
        guard holder == ProcessInfo.processInfo.processIdentifier else { return }
        terminateOtherLumiInstances()
    }

    /// 锁已经拿到手，但先启动者可能是 8 月那份没装护栏的旧构建（本机 /Applications/Lumi.app）。
    /// 只做「后启动者接管」不够：用户从启动台点旧图标时旧版并无护栏，照样双开，正是
    /// 「无法获取歌词」的复发路径。所以持锁后反向扫一遍，把其他 Lumi.app 实例请走。
    private static func terminateOtherLumiInstances() {
        let selfPid = ProcessInfo.processInfo.processIdentifier
        var victims: [pid_t] = []
        for pid in allPids() {
            guard pid > 0, pid != selfPid, lumiExecutable(pid) != nil else { continue }
            victims.append(pid)
        }
        guard !victims.isEmpty else { return }
        for pid in victims {
            NSLog("[Lumi/Instance] 已持锁但发现其他 Lumi 实例 pid=" + String(pid) + "，SIGTERM 请其退出")
            kill(pid, SIGTERM)
        }
        usleep(300_000)
        for pid in victims where kill(pid, 0) == 0 {
            NSLog("[Lumi/Instance] 其他实例 pid=" + String(pid) + " 未响应 SIGTERM，改用 SIGKILL")
            kill(pid, SIGKILL)
        }
        usleep(200_000)
    }

    private static func allPids() -> [pid_t] {
        let needed = proc_listallpids(nil, 0)
        guard needed > 0 else { return [] }
        var buf = [pid_t](repeating: 0, count: Int(needed))
        let n = proc_listallpids(&buf, Int32(MemoryLayout<pid_t>.size * buf.count))
        guard n > 0 else { return [] }
        return Array(buf.prefix(Int(n)))
    }

    /// 只认 Lumi.app 里的可执行文件：既避免误杀同名进程，也复用同一套路径判断校验锁里的陈旧 pid。
    private static func lumiExecutable(_ pid: pid_t) -> String? {
        var buf = [Int8](repeating: 0, count: 2048)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return buf.withUnsafeBufferPointer { raw -> String? in
            guard let base = raw.baseAddress else { return nil }
            let path = String(cString: base)
            return path.contains("/Lumi.app/Contents/MacOS/Lumi") ? path : nil
        }
    }


    private static func takeover(holder: pid_t, fd: Int32) {
        guard isLumiProcess(holder) else {
            NSLog("[Lumi/Instance] 锁文件里的 pid=" + String(holder) + " 已不是 Lumi 进程，视为陈旧 pid，直接接管")
            return
        }
        // 先把自己写进锁文件「挂号」再请旧实例退出：持锁方的自检定时器读到非自己的 pid，
        // 就明白这是正常换锁，不会反手把接管者杀掉。
        becomeOwner(fd)
        NSLog("[Lumi/Instance] 检测到另一实例 pid=" + String(holder) + "，先 SIGTERM 请其退出")
        kill(holder, SIGTERM)
        usleep(300_000)
        if kill(holder, 0) == 0 {
            NSLog("[Lumi/Instance] 实例 pid=" + String(holder) + " 未响应 SIGTERM，改用 SIGKILL")
            kill(holder, SIGKILL)
            usleep(200_000)
        }
    }
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
