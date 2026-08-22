import AppKit

// MARK: - 动态岛窗口控制器：屏幕 / 刘海几何逻辑
// 刘海检测、热区计算、窗口 frame 计算等纯几何逻辑，以 extension 形式
// 与控制器本体（IslandWindowController.swift）分离，行为不变。
extension IslandWindowController {

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

    func invalidateScreenCache() {
        cachedBuiltInScreen = nil
        cachedHotZone = nil
    }

    /// 返回（可能缓存的）内置屏与其刘海热区，避免每次鼠标移动都重算。
    func activeScreenAndZone() -> (screen: NSScreen, zone: CGRect)? {
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
}
