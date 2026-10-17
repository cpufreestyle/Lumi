import Foundation

/// 播放进度的墙钟补间。
///
/// 为什么要它：歌词高亮完全按 `currentTime` 选行，而 `currentTime` 只能从 Music 的
/// AppleScript 轮询里取，播放中每 1.5s 才有一个真值。于是每一句歌词最多要晚 1.5 秒
/// 才切换行，听感就是「歌词总是慢半拍」——歌词越短越明显。Music 的 position 没有别的
/// 读取通道（Apple event 是唯一入口），所以这里在两拍之间用墙钟线性补间，把量化误差
/// 从 1.5s 压到 0.05s；下一个真值到达时自动校正（偏差通常只有几十毫秒，肉眼不可见）。
///
/// 边界处理：
/// - 只有 `playing` 状态才推进，暂停/停止不推进，避免暂停后进度自己往前跑；
/// - 真值间隔过大（> playbackClockMaxDrift，说明刚切歌/刚恢复/偶发慢拍）时
//   不补间，防止把旧采样一路推走；上限见下方常量（8s，兼顾慢拍不卡顿）；
// - 用 RunLoop Timer + .common 模式：拖动滑块 / 滚动歌词 / 面板交互期间
//   仍能派发，不会因 RunLoop 切模式而停摆（本 App 是菜单栏 accessory，
//   RunLoop 常停留在非 default 模式，.common 是必要的）；
/// - 补间值只在「大于当前值」时写入，配合下一拍真值回落，不会出现倒跳。
extension MusicController {

    /// 补间节拍间隔（秒）。0.05s = 20Hz。
    ///
    /// 原为 0.25s，注释写「人眼已无法分辨台阶」—— 实测不成立：快照只在 tick
    /// 时刻更新，UI 在两次 tick 之间读到的是旧值，平均滞后 124ms、最坏 250ms。
    /// 这才是「歌词慢半拍」的主因，比任何校准误差大一个数量级。
    ///
    /// 收紧到 20Hz 后，快照滞后均值约 25ms、最坏 50ms，与 `livePosition` 的帧级
    /// 外推叠加后人耳不可辨。代价是每秒多 8 次主线程唤醒，每次仅一次加法加一次
    /// SwiftUI diff，远轻于同一模块 1.5s 一次的跨进程 AppleScript 轮询。
    private static let playbackClockInterval: TimeInterval = 0.05
    /// 真值间隔超过该秒数才放弃补间：本轮采样已经过期，补出来的值不可信。
    /// 播放中轮询是 1.5s，但 AppleScript + scriptQueue 排队偶发会把单拍拖到 2~3s。
    /// 上限若只比轮询间隔高一点（曾为 3s），慢一拍就整拍停跳——歌词明显卡一下。
    /// 放宽到 8s：锚点外推本身单调安全（sampledPosition + elapsed），
    /// 下一拍真值到达时会自动校正，不会无限漂移；却能让偶发慢拍不再掉歌词。
    private static let playbackClockMaxDrift: TimeInterval = 8

    /// 启动墙钟补间（主线程）。重复调用安全（幂等，但会自愈）。
    ///
    /// 原来用 `guard playbackClockTimer == nil` 提前返回。问题：Timer 被失效后
    /// 字段仍是那个死对象（非 nil），此后每次调用都命中守卫直接返回 ——
    /// 补间永久停摆，歌词卡住不动，且没有任何恢复路径。
    /// 改为校验 `isValid`：已失效就重建，调用方无需关心内部是否曾失效。
    func startPlaybackClock() {
        if let existing = playbackClockTimer, existing.isValid { return }
        playbackClockTimer?.invalidate()
        playbackClockTimer = nil
        let timer = Timer(timeInterval: Self.playbackClockInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Timer 的 block 是 @Sendable（非隔离），编译器无从证明它跑在主线程，
            // 直接调 @MainActor 方法会告警，Swift 6 语言模式下升级为编译错误。
            // 定时器由 RunLoop.main 持有，闭包必然在主线程执行；assumeIsolated 把这个
            // 事实显式告诉编译器：同步调用、零额外跳转——20Hz 下若改走
            // DispatchQueue.main.async 会每拍多一次 RunLoop 轮转，白白加一拍延迟。
            // 误改到非主线程 RunLoop 时 debug 下立即崩，而不是静默地跨线程写 UI 状态。
            MainActor.assumeIsolated {
                self.advanceInterpolatedProgress()
            }
        }
        // .common：拖动滑块 / 滚动歌词区时 RunLoop 仍会派发，避免补间在交互期间停摆。
        RunLoop.main.add(timer, forMode: .common)
        playbackClockTimer = timer
    }

    /// 推进一拍的插值进度。保留为 internal 以便未来做纯逻辑测试与手动触发。
    ///
    /// `@MainActor` 是必要的：`currentTime` / `lastCommittedPosition` 都是
    /// `@Published` UI 状态，只能主线程读写。补间定时器本身在主线程，但
    /// 手动触发 / 测试调用的线程不受约束 —— 标注后由编译器保证，
    /// 而不是靠「调用方记得派发主线程」这种口头约定。
    @MainActor
    func advanceInterpolatedProgress() {
        guard playbackState == .playing else { return }
        let elapsed = Date().timeIntervalSince(positionSampledAt)
        // elapsed 太小说明刚采样过（不必再动）；太大说明采样过期，本轮不猜。
        guard elapsed >= Self.playbackClockInterval,
              elapsed <= Self.playbackClockMaxDrift else { return }
        // 锚点外推：真值 + 已经过去的时间。绝不能写成 currentTime + drift ——
        // 每拍都往已经累加过的进度上再加同一段 drift，误差会随拍数累加，
        // 一两个真值周期内就能把歌词推离演唱整整一两秒。
        let advanced = sampledPosition + elapsed
        guard advanced > currentTime else { return }
        commitProgress(advanced)
    }

    /// 统一提交进度：记录最近写入值，供真值覆盖前判断是否需要防回跳。
    /// 同 `advanceInterpolatedProgress`：写 `@Published` 状态，必须主线程。
    @MainActor
    func commitProgress(_ value: TimeInterval) {
        let clamped = duration > 0 ? min(value, duration) : value
        currentTime = clamped
        lastCommittedPosition = clamped
    }
}
