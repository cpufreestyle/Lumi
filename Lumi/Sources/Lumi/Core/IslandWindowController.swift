import AppKit
import SwiftUI
import Combine

// MARK: - 动态岛窗口控制器
final class IslandWindowController: NSObject {
    // 注：部分成员的 private 已放宽为默认访问级别，供 IslandScreenGeometry.swift
    // 中的同类型 extension 跨文件访问（单 executable 目标，不构成对外 API 暴露）。
    var window: NSPanel!
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var mouseMonitor: Any?
    private var mouseDownMonitor: Any?
    /// 局部事件监听 token：必须保存，否则无法在 deinit 移除（NSEvent.addLocalMonitorForEvents 返回的 token 即移除凭据）。
    private var localMouseMoveMonitor: Any?
    private var localMouseDownMonitor: Any?
    /// 屏幕拓扑变化通知的观察者 token，供 deinit 注销。
    private var screenChangeObserver: NSObjectProtocol?
    /// 前台应用切换 / 空间切换（进出全屏）观察者 token，供 deinit 注销。
    private var wsAppObserver: NSObjectProtocol?
    private var wsSpaceObserver: NSObjectProtocol?
    private var hideTimer: Timer?
    /// 滚轮调音量的状态：
    /// - scrollVolume：本次连续滚动累积的「意图音量」，仅存内存，避免每格都写 UserDefaults；
    ///   为 -1 表示尚未开始，下次以 MusicController 的真实音量为准。
    /// - lastVolumeApply / volumeApplyWork：AppleScript 下发节流（前导 + 尾随）。
    private var scrollVolume: Int = -1
    private var lastVolumeApply: Date = .distantPast
    private var volumeApplyWork: DispatchWorkItem?
    /// 停止滚动一段时间后让 scrollVolume 失效，重新对齐真实音量（防止外部改音量后基准漂移）。
    private var scrollResetWork: DispatchWorkItem?
    /// 记录上一次鼠标是否处于热区，用于区分"重新进入"与"停留在热区"
    private var wasInZone: Bool = false

    /// 动态岛触发热区：屏幕顶部中央的一条不可见横带。
    /// 注意：内置屏（带刘海）的热区不再写死为固定 28×320，而是根据
    /// 当前 MacBook 型号的刘海实际度量（safeAreaInsets）精确计算，
    /// 以贴合不同机型（14"/16"，不同缩放比）的真实刘海尺寸与位置。
    /// 下面这两个值仅作为「无刘海机型 / 合盖外接屏」的兜底热区尺寸。
    let fallbackHotZoneHeight: CGFloat = 20
    let fallbackHotZoneWidth: CGFloat = 320

    /// 合盖回退到外接屏时的热区尺寸。
    /// 外接屏顶部是普通菜单栏（右侧状态栏图标、左侧应用菜单都在此），
    /// 沿用内置屏的刘海热区会频繁误触发，故显著收窄收薄。
    let externalHotZoneHeight: CGFloat = 4
    let externalHotZoneWidth: CGFloat = 160

    /// 内置屏（带刘海）刘海的真实宽度（pt）。
    /// 注意：macOS 的 `safeAreaInsets.left/right` 在带刘海屏上恒为 0
    /// （刘海只居于顶部中央，不会把安全区左右撑开），因此不能用
    /// `frame.width - left - right` 推导——那会得到整屏宽，使热区横跨整个顶部，
    /// 鼠标还没碰到刘海就误触发。真实刘海宽度约 250pt 且始终水平居中，
    /// 故这里用固定的近似值并居中定位，确保只有鼠标真正进入凹槽才触发胶囊。
    let builtInNotchWidth: CGFloat = 250

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
    var userSize: NSSize?

    /// 拖拽缩放进行中：期间屏蔽 updateWindowFrame 的"重置回 userSize"逻辑，
    /// 否则面板内鼠标移动触发 isHovering 变化 → applyState → updateWindowFrame
    /// 会用旧 userSize 把窗口拽回原尺寸，导致右下角手柄"拖了等于没拖"。
    var isResizing: Bool = false

    /// 展开态尺寸可调范围（夹紧用），防止拖到过小无法用或过大飞出屏幕。
    private let minExpandedW: CGFloat = 320
    private let maxExpandedW: CGFloat = 720
    private let minExpandedH: CGFloat = 200
    private let maxExpandedH: CGFloat = 820
    private let userSizeKey = "island_user_size"

    /// 热区与屏幕拓扑相关的缓存。鼠标移动事件每秒触发上百次，
    /// 而 `builtInScreen`/`notchHotZone` 每次都要枚举 NSScreen 并调用 CoreGraphics
    /// （CGDisplayIsBuiltin），重复计算极浪费。缓存一次，仅在屏幕拓扑变化时失效。
    var cachedBuiltInScreen: NSScreen?
    var cachedHotZone: CGRect?

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
        let hosting = CapsuleHostingView(rootView: ContentView())
        hosting.autoresizingMask = [.width, .height]
        // 让 hosting layer 完全透明，圆角形状由 SwiftUI 内容的 RoundedRectangle 承载；
        // 面板级阴影已关闭，故不会再有沿矩形边缘的透明直角光晕。
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hosting

        self.window = panel

        // 胶囊空闲鼠标手势（左键位已占满，见 CapsuleHostingView）：
        //   右键短按 → 播放/暂停；右键长按 → 快捷菜单；中键 → 下一首；滚轮 → 音量。
        panel.onAuxClick = { [weak self] in
            self?.handleCapsuleAuxClick()
        }
        panel.onAuxLongPress = { [weak self] in
            self?.showCapsuleMenu()
        }
        panel.onMiddleClick = { [weak self] in
            self?.handleCapsuleNextTrack()
        }
        panel.onRightShiftClick = { [weak self] in
            self?.handleCapsuleNextTrack()
        }
        panel.onRightOptionClick = { [weak self] in
            self?.handleCapsulePrevTrack()
        }
        panel.onScroll = { [weak self] deltaY in
            self?.handleCapsuleScroll(deltaY)
        }

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
        localMouseMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] ev in
            self?.evaluateHotZone()
            return ev
        }

        // 全局/局部鼠标按下监控：在刘海（顶部中央热区）双击可切换胶囊固定状态，
        // 提供不依赖胶囊按钮的快捷固定方式。需「辅助功能」权限（与 hover 一致）。
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] ev in
            self?.handleNotchDoubleClick(event: ev)
        }
        localMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] ev in
            self?.handleNotchDoubleClick(event: ev)
            return ev
        }

        // 菜单栏图标：即使没有辅助功能权限，也能看到应用并手动唤出动态岛
        setupStatusItem()

        // 前台应用切换 / 空间切换（进出全屏）时立即重估热区：
        // 否则进入全屏后要等下一次鼠标移动才会收起胶囊（全屏检测结果有 1s 缓存）。
        let wsCenter = NSWorkspace.shared.notificationCenter
        wsAppObserver = wsCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.evaluateHotZone() }
        wsSpaceObserver = wsCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.evaluateHotZone() }

        // 屏幕拓扑变化（开合盖、插拔显示器、分辨率变更）：
        // 目标屏可能已消失或改变，立即按新的 builtInScreen 重新定位，
        // 否则窗口会滞留在旧屏坐标上直到下次鼠标移动。
        screenChangeObserver = NotificationCenter.default.addObserver(
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

        // 全屏应用避让：有 App 正在全屏（视频/游戏/演示）时，不再因 hover 弹出胶囊，
        // 已显示的也立即收起，避免遮挡全屏内容。
        // 锁定常驻（islandPinned）视为用户明确要求常驻，优先级更高，不避让。
        if AppState.shared.hideInFullscreen, !AppState.shared.islandPinned,
           isFullScreenAppActive(on: screen) {
            wasInZone = false
            if window?.isVisible == true { hideIsland() }
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

        // 固定常驻：鼠标离开热区不自动收起，但进入热区（从其他区域移回）仍自动显示。
        // 默认 islandPinned=false（仅 hover 才出现），由「双击刘海」开启。
        guard !AppState.shared.islandPinned else {
            wasInZone = inZone
            if inZone {
                hideTimer?.invalidate(); hideTimer = nil
                if window?.isVisible != true { showIsland() }
            }
            return
        }

        // 普通 hover 态：鼠标在刘海热区（含已显示的胶囊窗口内）才显示，
        // 离开即安排收起——保证「未固定时鼠标没碰到刘海绝不出现胶囊」。
        wasInZone = inZone
        if inZone {
            hideTimer?.invalidate(); hideTimer = nil
            // 已在显示则跳过：mouseMoved 每秒触发上百次，重复 orderFront+淡入会卡顿/闪抖。
            if window?.isVisible != true { showIsland() }
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
            // 仅启用 hover 触发（鼠标碰触刘海才弹出），不强制显示、不常驻，
            // 符合「鼠标没有碰到刘海时胶囊不出现」。
            AppState.shared.islandEnabled = true
            wasInZone = false
            evaluateHotZone()
            statusToggleItem?.title = "隐藏动态岛"
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

    /// 右键/中键点击胶囊 → 播放/暂停。由 CapsuleHostingView 捕获后回调触发。
    ///
    /// 左键位已被占满（单击展开面板、双击重置歌词偏移、长按进入歌词微调），
    /// 因此用空闲的右键/中键承载最常用的「一键播控」，不改动任何既有手势语义。
    /// 注意：不能用 islandEnabled（总开关）做门禁——关闭总开关后 hover 仍会弹出
    /// 预览胶囊，此时用户点它却毫无反应。
    private func handleCapsuleAuxClick() {
        // 仅收缩态（胶囊）生效：展开态已有完整播放控件，
        // 在此拦截会与输入框、插件面板等内容交互冲突。
        guard !AppState.shared.isExpanded else { return }

        MusicController.shared.togglePlayPause()
        // 立即拉一次状态，避免等最长 1.5s 的轮询才刷新 UI
        MusicController.shared.fetchInfo()
    }

    /// 中键点击 / Shift+右键 → 下一首。
    private func handleCapsuleNextTrack() {
        guard !AppState.shared.isExpanded else { return }
        MusicController.shared.nextTrack()
        MusicController.shared.fetchInfo()
    }

    /// Option+右键 → 上一首。
    private func handleCapsulePrevTrack() {
        guard !AppState.shared.isExpanded else { return }
        MusicController.shared.previousTrack()
        MusicController.shared.fetchInfo()
    }

    /// 滚轮滑过胶囊 → 音量增减（每次 ±5）。
    ///
    /// 两点优化：
    /// 1. 累积值只存在内存里的 `scrollVolume`，**不直接写 `MusicController.volume`**——
    ///    该属性 didSet 会持久化到 UserDefaults，一次滑动手势可达数十格，直接写会疯狂落盘；
    ///    这里只把「意图值」累积，真正下发时才由 setVolume 统一写一次。
    /// 2. 对 AppleScript 下发做「前导 + 尾随」节流，避免一次滑动排队几十条脚本。
    private func handleCapsuleScroll(_ deltaY: CGFloat) {
        guard !AppState.shared.isExpanded else { return }
        guard deltaY != 0 else { return }

        let music = MusicController.shared
        // 基准：连续滚动以内积累积值为准；尚未滚动过则对齐真实音量（-1 未初始化时用 50 兜底）。
        if scrollVolume < 0 { scrollVolume = music.volume >= 0 ? music.volume : 50 }
        let next = max(0, min(100, scrollVolume + (deltaY > 0 ? 5 : -5)))
        guard next != scrollVolume else { return }
        scrollVolume = next
        // 胶囊上浮出音量 HUD，给出即时反馈（1.2s 后自动隐藏）。
        AppState.shared.flashVolumeHUD(next)

        let now = Date()
        if now.timeIntervalSince(lastVolumeApply) > 0.1 {
            // 前导：距上次下发已超过 100ms，立即施加，跟手
            lastVolumeApply = now
            volumeApplyWork?.cancel()
            music.setVolume(next)
        } else {
            // 尾随：高频滚动时只累积，稍后合并成一次脚本调用
            volumeApplyWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.lastVolumeApply = Date()
                MusicController.shared.setVolume(self.scrollVolume)
            }
            volumeApplyWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
        }

        // 停止滚动 1s 后作废累积值，下次滚动重新以真实音量为准（防基准漂移）。
        scrollResetWork?.cancel()
        let reset = DispatchWorkItem { [weak self] in self?.scrollVolume = -1 }
        scrollResetWork = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: reset)
    }

    // MARK: - 生命周期

    /// 全屏检测结果缓存：CGWindowList 枚举有开销，mouseMoved 高频触发下用 1s 缓存节流。
    private var fsCheckAt: Date = .distantPast
    private var fsCheckResult = false

    /// 判断是否有 App 正在 `screen` 上全屏显示。
    /// 原理：全屏 App 会创建一个与屏幕等大的 layer-0 窗口，据此做几何判定
    /// （普通最大化窗口高度不含菜单栏区，不会误判）。
    /// 注意 CGWindowBounds 用全局坐标（原点左上、y 向下），需与 NSScreen 坐标换算对齐。
    private func isFullScreenAppActive(on screen: NSScreen) -> Bool {
        let now = Date()
        if now.timeIntervalSince(fsCheckAt) < 1.0 { return fsCheckResult }
        fsCheckAt = now

        var result = false
        defer { fsCheckResult = result }

        guard let primary = NSScreen.screens.first else { return false }
        // 屏幕左上角换算到 CG 全局坐标：cgY = 主屏高度 - 屏幕底边（NSScreen 原点在左下）。
        let cgX = screen.frame.minX
        let cgY = primary.frame.maxY - screen.frame.maxY
        let tw = screen.frame.width
        let th = screen.frame.height

        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let b = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"] else { continue }
            // 与屏幕几乎完全重合（容差 2pt）即视为全屏窗口
            if abs(x - cgX) < 2, abs(y - cgY) < 2, abs(w - tw) < 2, abs(h - th) < 2 {
                result = true
                break
            }
        }
        return result
    }

    /// 注销所有事件监听与通知观察者。
    /// 本控制器通常随 App 存活至退出，但显式成对释放是正确姿势：
    /// 将来若改为可重建（如多屏热插拔重建控制器），不做这一步会残留监听导致重复响应。
    deinit {
        if let m = mouseMonitor { NSEvent.removeMonitor(m) }
        if let m = mouseDownMonitor { NSEvent.removeMonitor(m) }
        if let m = localMouseMoveMonitor { NSEvent.removeMonitor(m) }
        if let m = localMouseDownMonitor { NSEvent.removeMonitor(m) }
        if let o = screenChangeObserver { NotificationCenter.default.removeObserver(o) }
        let wsCenter = NSWorkspace.shared.notificationCenter
        if let o = wsAppObserver { wsCenter.removeObserver(o) }
        if let o = wsSpaceObserver { wsCenter.removeObserver(o) }
        hideTimer?.invalidate()
        volumeApplyWork?.cancel()
        scrollResetWork?.cancel()
    }

    // MARK: - 胶囊右键长按菜单

    /// 右键长按胶囊 → 快捷菜单（播控 + 常驻锁定 + 打开 Apple Music）。
    private func showCapsuleMenu() {
        guard !AppState.shared.isExpanded else { return }
        guard let view = window?.contentView else { return }

        let menu = NSMenu()
        // 首项做「禁用标题」缓冲：长按后松手时指针正落在首项上，禁用项可避免误触发动作。
        let title = MusicController.shared.title.isEmpty ? "Lumi 播放控制" : MusicController.shared.title
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        // 项名带上对应手势，让「右键短按/⇧右键/⌥右键/滚轮」这套键位可被发现。
        menu.addItem(menuItem(MusicController.shared.playbackState == .playing ? "暂停　（右键）" : "播放　（右键）",
                              #selector(menuTogglePlay)))
        menu.addItem(menuItem("上一首　（⌥ + 右键）", #selector(menuPreviousTrack)))
        menu.addItem(menuItem("下一首　（⇧ + 右键）", #selector(menuNextTrack)))
        // 音量项仅作「键位说明」，本身不可点（滚轮直接调）。
        let volumeHint = NSMenuItem(title: "音量 ±5　（滚轮）", action: nil, keyEquivalent: "")
        volumeHint.isEnabled = false
        menu.addItem(volumeHint)
        menu.addItem(.separator())
        menu.addItem(menuItem(AppState.shared.islandPinned ? "取消常驻" : "锁定常驻",
                              #selector(menuTogglePin)))
        menu.addItem(menuItem("打开 Apple Music", #selector(menuOpenMusic)))

        // 在鼠标当前位置弹出（屏幕坐标 → 窗口坐标 → 视图坐标）
        let windowPoint = window?.convertPoint(fromScreen: NSEvent.mouseLocation) ?? .zero
        _ = menu.popUp(positioning: nil, at: view.convert(windowPoint, from: nil), in: view)
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func menuTogglePlay() {
        MusicController.shared.togglePlayPause()
        MusicController.shared.fetchInfo()
    }

    @objc private func menuPreviousTrack() {
        MusicController.shared.previousTrack()
        MusicController.shared.fetchInfo()
    }

    @objc private func menuNextTrack() {
        MusicController.shared.nextTrack()
        MusicController.shared.fetchInfo()
    }

    @objc private func menuTogglePin() {
        togglePin()
    }

    @objc private func menuOpenMusic() {
        if let url = URL(string: "music://") {
            NSWorkspace.shared.open(url)
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
