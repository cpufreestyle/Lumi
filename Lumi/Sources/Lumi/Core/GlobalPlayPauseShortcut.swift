import AppKit

/// 全局播放/暂停快捷键（方案 A，`docs/播放暂停快捷键方案.md` 的主路径）。
///
/// 用户诉求：任意 app 前台按一下就能切换 Music 播放，不必先把鼠标挪到刘海。
///
/// 三条实现约束（来自方案文档，均为既定交互，不可违反）：
/// 1. **按 keyCode 而非 characters 匹配** —— 中文输入法下 `characters` 会变成拼音字母，
///    keyCode 与键盘布局无关；这点是全局快捷键在中文环境能否可用的分水岭。
/// 2. **不弹胶囊** —— 用户明确要求「鼠标没碰到刘海时不要出现胶囊」，所以触发后
///    不 showIsland()，只播放 + 菜单栏图标短暂反馈。
/// 3. **全局+局部双监听** —— `addGlobalMonitorForEvents` 需要辅助功能权限且只在
///    别的 app 在前台时生效；`addLocalMonitorForEvents` 覆盖 Lumi 自身前台，
///    权限失效时至少本 app 内可用（与 hover 检测同一套降级思路）。
final class GlobalPlayPauseShortcut {
    static let shared = GlobalPlayPauseShortcut()

    /// UserDefaults 键：开关与键位。键位存 UInt（CGKeyCode）而非字符串，
    /// 与「按 keyCode 匹配」一致，也避免字符在输入法下的二义性。
    private enum DefaultsKey {
        static let enabled = "lumi_global_playpause_enabled"
        static let keyCode = "lumi_global_playpause_keycode"
        static let modifiers = "lumi_global_playpause_modifiers"
    }

    /// 默认键位：⌘⌥P（方案文档给的候选之一，冲突最少，且 P = Play 易记）。
    /// 已避开 ⌥Space — Alfred/Raycast 常占用它。
    static let defaultKeyCode: UInt16 = 35   // P
    static let defaultModifiers: UInt = UInt(NSEvent.ModifierFlags([.command, .option]).rawValue)

    /// 开关。持久化，读取时若从未设置过则为关闭（新增功能默认不抢占键位）。
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: DefaultsKey.enabled) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKey.enabled) }
    }

    private var keyCode: UInt16 {
        // UserDefaults 里整型以 Int 存取最稳；读出来再转 NSEvent.keyCode 原生的 UInt16。
        let stored = UserDefaults.standard.object(forKey: DefaultsKey.keyCode) as? Int
        guard let stored else { return Self.defaultKeyCode }
        return UInt16(truncatingIfNeeded: stored)
    }

    private var modifiers: NSEvent.ModifierFlags {
        let raw = UserDefaults.standard.object(forKey: DefaultsKey.modifiers) as? UInt ?? Self.defaultModifiers
        return NSEvent.ModifierFlags(rawValue: raw)
    }

    /// 已注册的监听 token：必须保存，否则无法在 deinit 注销。
    private var globalMonitor: Any?
    private var localMonitor: Any?

    private init() {}

    /// 注册监听。仅在开关打开时调用；幂等（重复调用只注册一次）。
    func register() {
        guard isEnabled else { return }
        guard globalMonitor == nil, localMonitor == nil else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            // 不吞事件：只有匹配键位才播控，其他键照常透传给系统/输入法。
            return event
        }
    }

    /// 注销监听。开关关闭或 App 退出时调用。
    func unregister() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    /// 切换开关：注册/注销监听。
    func setEnabled(_ on: Bool) {
        isEnabled = on
        if on { register() } else { unregister() }
    }

    /// 匹配键位则播控。
    private func handle(_ event: NSEvent) {
        guard Self.matches(keyCode: event.keyCode,
                           modifiers: event.modifierFlags,
                           expectedKeyCode: keyCode,
                           expectedModifiers: modifiers) else { return }

        MusicController.shared.togglePlayPause()
        // fetchInfo 与反馈都要放进 main.async，且反馈排在前面。
        //
        // 两条原因决定这个顺序：
        // 1. 必须放进 main.async。togglePlayPause 的乐观状态切换本身就是
        //    main.async 入队的；在这里同步读 isPlaying 只会拿到切换前的旧状态 ——
        //    按快捷键去暂停时反馈图标会错显成「播放中」，与事实正好相反。
        //    入队后本闭包排在那个切换之后执行，读到的才是新状态。
        // 2. 反馈要在 fetchInfo 之前。fetchInfoSync 会拿 AppleScript 返回的真实
        //    状态回写 playbackState（MusicController 的 stateStr 分支），那次
        //    往返比 UI 慢得多；排在后面会让反馈读到不确定的中间值。取乐观切换后
        //    的状态最贴近「用户刚按下那一瞬间的意图」。
        DispatchQueue.main.async {
            self.reportFeedback()
            MusicController.shared.fetchInfo()
        }
    }

    /// 快捷键触发后在菜单栏图标短暂叠加 play/pause 符号作为确认
    ///（方案 3.3 / 3.4：有确认感，又不违反「不弹胶囊」）。
    /// 真正的图标切换由 IslandWindowController 订阅后完成（改 image 不动 title），
    /// 这里只负责把「切换后的播放态」广播出去。
    private func reportFeedback() {
        // 诊断：把读到的播放态打进 unified logging，用于验证「反馈读到的
        // 是切换后的新状态而非旧状态」这一时序结论。稳定后移除。
        NSLog("[LumiDiag] feedback isPlaying=%d", MusicController.shared.isPlaying ? 1 : 0)
        NotificationCenter.default.post(
            name: .globalPlayPauseTriggered,
            object: MusicController.shared.isPlaying
        )
    }

    deinit {
        unregister()
    }

    // MARK: - 匹配逻辑（纯函数，便于 LumiTests 覆盖）

    /// 按键是否命中目标键位。
    ///
    /// 三条规则，每条都对应一个真实失败场景：
    /// - 按 keyCode 比：中文输入法下 characters 是拼音字母而非字母本身，
    ///   用字符匹配会让快捷键在中文环境下随机失灵；keyCode 与键盘布局无关。
    /// - 修饰键只比用到的四位（cmd / option / shift / control）：modifierFlags 里
    ///   还混着 CapsLock、Function、NumericPad 等状态位，直接全等比较会让
    ///   开着 CapsLock 时快捷键莫名失效。
    /// - 空修饰键时要求一个修饰键都没有：否则只想按 P 也会命中，打字被打断。
    static func matches(keyCode: UInt16,
                        modifiers: NSEvent.ModifierFlags,
                        expectedKeyCode: UInt16,
                        expectedModifiers: NSEvent.ModifierFlags) -> Bool {
        guard keyCode == expectedKeyCode else { return false }
        let relevant: NSEvent.ModifierFlags = [.command, .option, .shift, .control]
        return modifiers.intersection(relevant) == expectedModifiers.intersection(relevant)
    }
}

extension Notification.Name {
    /// 全局播放快捷键触发：object 为切换后的 `isPlaying`（Bool）。
    /// IslandWindowController 订阅它在菜单栏图标上做短暂反馈。
    static let globalPlayPauseTriggered = Notification.Name("lumi.globalPlayPauseTriggered")
}
