import XCTest

/// 打拍间隔上限的量化测试（Foundation only）。
///
/// PollingCoordinator 用单一定时器驱动所有任务。若打拍上限是 1.0s，
/// 而音乐播放进度期望 1.5s 一拍，elapsed 累到 1.5s 时实际触发会拖到 2.0s ——
/// 平均每拍迟到约 0.5s。补间虽能补足数值，但真值取样时刻与读取时刻的
/// 差距被放大，歌词整体偏移，正是「歌词和歌声差一截」的来源。
final class PollingTickTests: XCTestCase {
    /// 复刻 coordinator 的触发逻辑，返回每次触发的迟到期（秒）。
    private func lateAmounts(interval: TimeInterval, tickCeiling: TimeInterval,
                             ticks: Int) -> [TimeInterval] {
        var enabled = false
        var elapsed: TimeInterval = 0
        var lates: [TimeInterval] = []
        for _ in 1...ticks {
            if !enabled { enabled = true; elapsed = 0; continue }
            elapsed += tickCeiling
            if elapsed >= interval {
                lates.append(elapsed - interval)
                elapsed = 0
            }
        }
        return lates
    }

    func testHalfSecondCeilingKeepsMusicOnTime() {
        // 0.5s 上限：1.5s 音乐任务每拍准时，零迟到
        let lates = lateAmounts(interval: 1.5, tickCeiling: 0.5, ticks: 200)
        XCTAssertFalse(lates.isEmpty)
        for late in lates {
            XCTAssertEqual(late, 0, accuracy: 0.0001)
        }
    }

    func testOneSecondCeilingMakesMusicLate() {
        // 反证：1.0s 上限下平均每拍迟到约 0.5s，这就是歌词整体偏移的来源
        let lates = lateAmounts(interval: 1.5, tickCeiling: 1.0, ticks: 200)
        XCTAssertFalse(lates.isEmpty)
        let average = lates.reduce(0, +) / Double(lates.count)
        XCTAssertGreaterThan(average, 0.4, "1.0s 上限下迟到量应显著")
    }

    func testCoarseIntervalIsUnaffected() {
        // 8s 级任务（暂停/停止兜底）对上限不敏感
        let lates = lateAmounts(interval: 8.0, tickCeiling: 0.5, ticks: 200)
        for late in lates { XCTAssertLessThan(late, 0.5) }
    }
}
