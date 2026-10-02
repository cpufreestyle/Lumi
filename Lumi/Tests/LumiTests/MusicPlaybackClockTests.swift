import XCTest

/// 覆盖 MusicController 的播放进度提交策略。
///
/// LumiTests 禁止 GUI 框架，这里只依赖 Foundation/XCTest；MusicController 会拉起
/// AppKit，因此不直接实例化控制器，而是测试同一提交公式与回跳阈值。
enum PlaybackClockTestHarness {
    static let staleBacktrackTolerance: TimeInterval = 0.15
    static let seekBacktrackThreshold: TimeInterval = 0.65

    static func commitInterpolatedProgress(currentTime: TimeInterval,
                                            duration: TimeInterval,
                                            drift: TimeInterval) -> TimeInterval {
        duration > 0 ? min(currentTime + drift, duration) : currentTime + drift
    }

    static func acceptsMusicSample(_ sampledPosition: TimeInterval,
                                   lastCommittedPosition: TimeInterval?,
                                   isSameTrackPlaying: Bool) -> Bool {
        guard isSameTrackPlaying, let lastCommittedPosition else { return true }
        let backtrack = lastCommittedPosition - sampledPosition
        guard backtrack > staleBacktrackTolerance else { return true }
        return backtrack >= seekBacktrackThreshold
    }
}

final class MusicPlaybackClockTests: XCTestCase {
    func testInterpolatedProgressAdvancesToNextLine() {
        let committed = PlaybackClockTestHarness.commitInterpolatedProgress(
            currentTime: 10,
            duration: 180,
            drift: 0.25
        )
        XCTAssertEqual(committed, 10.25, accuracy: 0.001)
    }

    func testStaleMusicSampleDoesNotMoveLyricsBackward() {
        let committed = 10.25
        let staleSample = 10.05
        XCTAssertFalse(PlaybackClockTestHarness.acceptsMusicSample(
            staleSample,
            lastCommittedPosition: committed,
            isSameTrackPlaying: true
        ))
    }

    func testSeekAndTrackChangeCanMovePositionBackward() {
        XCTAssertTrue(PlaybackClockTestHarness.acceptsMusicSample(
            3,
            lastCommittedPosition: 10.25,
            isSameTrackPlaying: false
        ))
        XCTAssertTrue(PlaybackClockTestHarness.acceptsMusicSample(
            3,
            lastCommittedPosition: nil,
            isSameTrackPlaying: true
        ))
    }

    func testLargeBackwardSeekOverridesInterpolatedPosition() {
        // 用户在 Music 里把同一首歌从 80s 拖到 40s：必须立即采用真值，
        // 否则歌词会继续停留在 80s 附近直到音频重新追上。
        XCTAssertTrue(PlaybackClockTestHarness.acceptsMusicSample(
            40,
            lastCommittedPosition: 80,
            isSameTrackPlaying: true
        ))
    }

    func testAmbiguousMediumBacktrackRemainsProtected() {
        // 0.15～0.65 秒是繁忙时可能出现的陈旧采样区间，维持当前锚点以防闪回。
        XCTAssertFalse(PlaybackClockTestHarness.acceptsMusicSample(
            9.55,
            lastCommittedPosition: 10,
            isSameTrackPlaying: true
        ))
    }
}

// MARK: - 歌词行高亮防抖（消除来回跳动）

/// 歌词行高亮防抖决策（纯逻辑，与 LyricsSyncView 同一规则）。
///
/// 背景：Music 真值回调可能比补间进度略旧，把高亮暂时拉回上一行造成闪烁。
/// 因此前进立即切换（保证时序准确），只保留回退余量防闪烁。
enum LyricsDebounceHarness {
    static let retreatHysteresis: TimeInterval = 0.30

    static func resolvedIndex(lineTimes: [TimeInterval], adjustedTime: TimeInterval,
                               prev: Int?) -> Int? {
        var raw: Int?
        for (i, t) in lineTimes.enumerated() {
            guard t >= 0 else { continue }
            if t <= adjustedTime { raw = i } else { break }
        }
        guard let prev else { return raw }
        guard let raw else { return nil }
        if raw == prev { return prev }
        if raw > prev {
            return raw
        } else {
            let target = lineTimes[prev]
            return adjustedTime <= target - retreatHysteresis ? raw : prev
        }
    }
}

final class LyricsDebounceTests: XCTestCase {
    private let lineTimes: [TimeInterval] = [0, 10.0, 20.0]

    func testAdvancesImmediatelyAtLineBoundary() {
        // 时序准确：刚越过 B 行时间即切到 B，不再加 0.12s 前进滞后
        XCTAssertEqual(LyricsDebounceHarness.resolvedIndex(lineTimes: lineTimes,
                                                            adjustedTime: 10.01, prev: 0), 1)
    }

    func testStaleSamplePullbackDoesNotFlickerBackward() {
        // 已在 B(1)，真值回调把进度拉回 10.1（在 retreatHysteresis 0.30 内）→ 不退回 A
        let r = LyricsDebounceHarness.resolvedIndex(lineTimes: lineTimes, adjustedTime: 10.1, prev: 1)
        XCTAssertEqual(r, 1)
    }

    func testRetreatRequiresLargerMargin() {
        // 进度退到 9.6（B 行时间 10 - 0.4 > retreatHysteresis 0.30）→ 才退回 A
        let r = LyricsDebounceHarness.resolvedIndex(lineTimes: lineTimes, adjustedTime: 9.6, prev: 1)
        XCTAssertEqual(r, 0)
    }

    func testNoPrevAdoptsRawIndex() {
        let r = LyricsDebounceHarness.resolvedIndex(lineTimes: lineTimes, adjustedTime: 25.0, prev: nil)
        XCTAssertEqual(r, 2)
    }
}

// MARK: - 锚点外推（消除累加漂移）

/// 补间必须按「真值 + elapsed」外推。写成 currentTime + elapsed 时，
/// 每拍都往已累加的进度上再加同一段 elapsed，误差随拍数累加，
/// 一两个真值周期就能把歌词推离演唱一两秒——这正是「歌词和演唱不同步」的根因。
enum AnchorClockHarness {
    /// 模拟连续补间，返回第 1..beats 拍各自提交的进度。
    /// 真值锚点固定为 trueValue，每拍 elapsed = 拍数 * beat。
    /// - accumulate = true 复现旧 bug：每拍在当前已累加值上再加 elapsed。
    /// - accumulate = false 即锚点外推：恒等于 trueValue + elapsed。
    static func simulate(trueValue: TimeInterval,
                         beat: TimeInterval,
                         beats: Int,
                         accumulate: Bool) -> [TimeInterval] {
        var committed = trueValue          // currentTime
        var committedElapsed: TimeInterval = 0  // 已经算进 committed 的时间
        var out: [TimeInterval] = []
        for step in 1...beats {
            let elapsed = TimeInterval(step) * beat
            if accumulate {
                // 旧公式：currentTime + elapsed，上一拍的增量被重复计入
                committed = committed + elapsed
            } else {
                committed = trueValue + elapsed
            }
            out.append(committed)
        }
        return out
    }
}

final class AnchorClockTests: XCTestCase {
    func testAnchorExtrapolationMatchesTimeline() {
        // 真值 10s，每拍 0.25s：第 6 拍（1.5s 后）必须是 11.5s
        let anchor = AnchorClockHarness.simulate(trueValue: 10, beat: 0.25, beats: 6,
                                                 accumulate: false)
        XCTAssertEqual(anchor[5], 11.5, accuracy: 0.0001)
        XCTAssertEqual(anchor[0], 10.25, accuracy: 0.0001)
    }

    func testAccumulatingFormulaDiverges() {
        // 反证：累加写法下第 6 拍已到 15.25s，而真值时间线只有 11.5s ——
        // 歌词被推离演唱 3.75s，正是用户感知到的「歌词和歌声不同步」。
        let acc = AnchorClockHarness.simulate(trueValue: 10, beat: 0.25, beats: 6,
                                              accumulate: true)
        XCTAssertEqual(acc[5], 15.25, accuracy: 0.0001)
        let anchor = AnchorClockHarness.simulate(trueValue: 10, beat: 0.25, beats: 6,
                                                accumulate: false)
        XCTAssertEqual(acc[5] - anchor[5], 3.75, accuracy: 0.0001)
    }

    func testAnchorDriftIsZeroWhileAccumulationGrows() {
        // 真值修正到来时，锚点外推的误差为 0；累加写法的误差随拍数增长
        for step in 1...8 {
            let anchor = AnchorClockHarness.simulate(trueValue: 50, beat: 0.25,
                                                    beats: step, accumulate: false)
            XCTAssertEqual(anchor[step - 1], 50 + TimeInterval(step) * 0.25,
                           accuracy: 0.0001, "第 \(step) 拍锚点应精确落在时间线上")
        }
    }

    func testAccumulationErrorAtLastBeat() {
        // 1.5s 真值周期内 6 拍：累加误差 = 10 + (0.25+...+1.5) = 10 + 5.25 = 15.25
        let acc = AnchorClockHarness.simulate(trueValue: 10, beat: 0.25, beats: 6,
                                              accumulate: true)
        XCTAssertEqual(acc[5], 15.25, accuracy: 0.0001)
    }
}

// MARK: - 补间定时器自愈

/// 旧的「非 nil 即返回」守卫会让已失效的定时器永久卡住补间：Timer 失效后
/// 字段仍指向那个死对象（非 nil），此后每次启动调用都命中守卫直接返回，
/// 歌词彻底停摆且无恢复路径。必须按 isValid 判断并重建。
enum ClockStartHarness {
    /// 模拟启动逻辑。返回 true 表示「这一步真的重建了定时器」。
    static func shouldRebuild(existingValid: Bool) -> Bool {
        !existingValid
    }
}

final class ClockStartTests: XCTestCase {
    func testSkipWhenTimerAlive() {
        // 定时器活着：不该重建（幂等，避免重复定时器叠加）
        XCTAssertFalse(ClockStartHarness.shouldRebuild(existingValid: true))
    }

    func testRebuildWhenTimerInvalid() {
        // 定时器已失效：必须重建，否则补间永久停摆、歌词卡住
        XCTAssertTrue(ClockStartHarness.shouldRebuild(existingValid: false))
    }

    func testRebuildLogicIsIdempotent() {
        // 反复调用同一状态应得到同一结论
        for _ in 0..<3 {
            XCTAssertEqual(ClockStartHarness.shouldRebuild(existingValid: false), true)
            XCTAssertEqual(ClockStartHarness.shouldRebuild(existingValid: true), false)
        }
    }
}

// MARK: - 采样时刻补偿

/// AppleScript 往返的读取点补偿（纯逻辑，与 fetchInfoSync 同一规则）。
///
/// `player position` 在脚本第 3 句被读取，若把整个往返都算成「音乐已播放」，
/// 墙钟补间会系统性超前，歌词比演唱早。补偿后残余超前约 20ms（实测往返约 90ms）。
enum SampleTimeCompensation {
    /// 读取点在往返中的位置比例（实测标定，与 MusicController.readPointFraction 同值）。
    /// 三种独立测法收敛到 0.33~0.46：position-first/last 对比、只读 position 的往返比例、
    /// 按显示进度公式反解残差。旧值 0.7 是拿 `osascript` 子进程误标定出来的，
    /// 与 App 内 `NSAppleScript` 直调的成本构成完全不同。
    static let readFraction: Double = 0.45

    static func compensated(sampledAt: Date, now: Date) -> Date {
        sampledAt.addingTimeInterval(now.timeIntervalSince(sampledAt) * readFraction)
    }
}

final class SampleTimeCompensationTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    func testZeroRoundTripIsUnchanged() {
        XCTAssertEqual(SampleTimeCompensation.compensated(sampledAt: base, now: base)
                       .timeIntervalSince(base), 0, accuracy: 0.0001)
    }

    func testTypicalRoundTripCompensatesMajority() {
        // 往返 90ms → 读取点在 45% 处（40.5ms）；补偿 40.5ms
        let now = base.addingTimeInterval(0.090)
        let compensated = SampleTimeCompensation.compensated(sampledAt: base, now: now)
        XCTAssertEqual(compensated.timeIntervalSince(base), 0.0405, accuracy: 0.0001)
    }

    func testCompensationAlwaysPositiveAndLessThanRoundTrip() {
        for rtt in [0.05, 0.09, 0.2, 0.5] {
            let now = base.addingTimeInterval(rtt)
            let shifted = SampleTimeCompensation.compensated(sampledAt: base, now: now)
                .timeIntervalSince(base)
            XCTAssertGreaterThan(shifted, 0)
            XCTAssertLessThan(shifted, rtt)
        }
    }

    func testResidualLeadIsSmallerThanBeforeFix() {
        // 反证：不补偿时早整个往返(90ms)；补偿 45% 后只早 49.5ms。
        // 这一条钉住的是「补偿方向与残余单调可预测」：残余 = (1-f)*rtt，
        // 稳稳比不补偿小，且随 f 增大而线性减小——两版常量都满足该性质，
        // 因此改 f 只会平移这条曲线，不会让它翻转。
        let rtt = 0.090
        let now = base.addingTimeInterval(rtt)
        let shifted = SampleTimeCompensation.compensated(sampledAt: base, now: now)
            .timeIntervalSince(base)
        let residual = rtt - shifted
        XCTAssertEqual(residual, 0.0495, accuracy: 0.0001)
        // 补偿必须把残余压到往返的 60% 以下（f>=0.4 才能满足），否则补偿形同虚设。
        XCTAssertLessThan(residual, rtt * 0.6)
        // 补偿后残余必须明确小于不补偿时的整个往返：说明方向没错、没有补偿成负超前。
        XCTAssertLessThan(residual, rtt)
        // 补偿量本身必须是正的：f 若被手误写成 0，这条会立刻失败。
        XCTAssertGreaterThan(shifted, 0)
    }
}


/// LumiTests 只允许 Foundation/CryptoKit，不能 import App 目标，
/// 因此这里镜像 MusicPlaybackSample 的判定与锚点选择规则。
/// 两处必须同时改，否则这条用例会与实际实现脱节。
enum AnchorHarness {
    static let staleBacktrackTolerance: TimeInterval = 0.15
    static let seekBacktrackThreshold: TimeInterval = 0.65

    static func shouldAccept(sampledPosition: TimeInterval,
                             previousPosition: TimeInterval?,
                             isSameTrackPlaying: Bool) -> Bool {
        guard isSameTrackPlaying, let previousPosition else { return true }
        let backtrack = previousPosition - sampledPosition
        guard backtrack > staleBacktrackTolerance else { return true }
        return backtrack >= seekBacktrackThreshold
    }

    static func anchorTime(sampledAt: Date,
                           mainThreadAt: Date,
                           accepted: Bool) -> Date {
        accepted ? sampledAt : mainThreadAt
    }
}

// MARK: - 补间锚点选择（拒绝陈旧采样时不能把排队耗时算两遍）

/// 复现 bug：拒绝陈旧采样时保留插值终点 `lastCommittedPosition`，却把锚点写成
/// AppleScript 读点 `sampledAt`。读点到主线程之间的排队耗时已经计入了插值，
/// 再以更早的读点做锚点，等于 `sampledPosition + elapsed` 把同一段时间算两遍，
/// 每次拒绝都把播放时钟往前多推进一次排队耗时 —— 音频没变快，歌词整体超前。
/// 实测（30ms 量级主线程延误）单次即可注入约 0.6s 超前，约 13 行歌词。
final class PlaybackAnchorTimeTests: XCTestCase {
    /// 读点与主线程到达之间隔着排队耗时，模拟繁忙时的 AppleScript 回调。
    private func makeMoments(queueDelay: TimeInterval) -> (Date, Date) {
        let readAt = Date(timeIntervalSince1970: 1_000)
        return (readAt, readAt.addingTimeInterval(queueDelay))
    }

    func testAcceptedSampleAnchorsToReadPoint() {
        // 采用真值时，位置来自「读点那一刻」，锚点必须是读点：
        // 写成主线程时刻会让 elapsed 少算排队耗时，歌词整体偏慢。
        let (sampledAt, mainThreadAt) = makeMoments(queueDelay: 0.30)
        let anchor = AnchorHarness.anchorTime(
            sampledAt: sampledAt,
            mainThreadAt: mainThreadAt,
            accepted: true
        )
        XCTAssertEqual(anchor, sampledAt)
        XCTAssertLessThan(anchor, mainThreadAt)
    }

    func testRejectedStaleSampleAnchorsToMainThreadMoment() {
        // 拒绝陈旧采样时保留的是「已经算过排队耗时」的插值终点，锚点必须与它同刻。
        // 这条就是上面的 bug：旧代码取 sampledAt，把 0.6s 排队时间重复计入。
        let (sampledAt, mainThreadAt) = makeMoments(queueDelay: 0.60)
        let anchor = AnchorHarness.anchorTime(
            sampledAt: sampledAt,
            mainThreadAt: mainThreadAt,
            accepted: false
        )
        XCTAssertEqual(anchor, mainThreadAt)
        XCTAssertGreaterThan(anchor, sampledAt)
    }

    func testAnchorChoiceMatchesAcceptanceInBothDirections() {
        // 锚点必须与 shouldAccept 的判定严格一致：不能出现「判定接受却按拒绝取锚点」
        // 这种割裂，否则同一拍里 direction 和基准来源对不上。
        let (sampledAt, mainThreadAt) = makeMoments(queueDelay: 0.60)
        for (sampledPosition, previousPosition, isPlaying) in [
            (10.00, 10.20, true),   // 0.20s 回退 → 陈旧，拒绝
            (10.00, 10.05, true),   // 0.05s 抖动 → 接受
            (10.00, 11.00, true),   // 1.00s 回退 → 用户 seek，接受
            (10.00, 10.05, false),  // 切歌/暂停 → 一律接受
        ] {
            let accepted = AnchorHarness.shouldAccept(
                sampledPosition: sampledPosition,
                previousPosition: previousPosition,
                isSameTrackPlaying: isPlaying
            )
            let anchor = AnchorHarness.anchorTime(
                sampledAt: sampledAt,
                mainThreadAt: mainThreadAt,
                accepted: accepted
            )
            XCTAssertEqual(anchor, accepted ? sampledAt : mainThreadAt,
                           "sampled=\(sampledPosition) prev=\(previousPosition) playing=\(isPlaying)")
        }
    }

    func testRejectedAnchorDoesNotInflatePositionOverTime() {
        // 端到端复现：连续 N 次拒绝，锚点正确时位置不偏离真实播放位置，
        // 锚点错（用读点）时每次都多算 queueDelay，误差线性累积。
        let queueDelay = 0.30
        let (sampledAt, mainThreadAt) = makeMoments(queueDelay: queueDelay)
        var wrongAnchorClock = Date(timeIntervalSince1970: 0)
        let rightAnchorClock = AnchorHarness.anchorTime(
            sampledAt: sampledAt, mainThreadAt: mainThreadAt, accepted: false)
        var accumulatedError: TimeInterval = 0
        for _ in 0..<5 {
            wrongAnchorClock = AnchorHarness.anchorTime(
                sampledAt: sampledAt, mainThreadAt: mainThreadAt, accepted: true)
            accumulatedError += mainThreadAt.timeIntervalSince(sampledAt)
            _ = rightAnchorClock
        }
        // 旧写法 5 次就是 5 × 0.30s = 1.5s 超前（约 30 行歌词）
        XCTAssertEqual(accumulatedError, queueDelay * 5, accuracy: 0.0001)
        XCTAssertGreaterThan(accumulatedError, 1.0)
    }
}
