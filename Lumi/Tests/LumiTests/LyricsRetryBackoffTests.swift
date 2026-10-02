import XCTest

/// 取词重试退避序列测试（Foundation only）。
///
/// 旧行为是固定 60s 冷却：网络只抖一下，歌词却要等一分钟以上才回来 ——
/// 用户感知就是「歌词卡住不出」。新行为按连续失败轮次指数增长，
/// 首次只等 6s，网络快速恢复时几乎无感。
final class LyricsRetryBackoffTests: XCTestCase {
    private let base: TimeInterval = 6
    private let ceiling: TimeInterval = 48

    /// 复刻 fetchLyricsSync 里的退避计算。
    private func cooldown(afterFailures attempts: Int) -> TimeInterval {
        let rounds = attempts / 3   // attempts 是累计次数，每 3 次算一轮
        let factor = pow(2.0, Double(max(rounds - 1, 0)))
        return min(base * factor, ceiling)
    }

    func testFirstCooldownIsShort() {
        // 刚失败 3 次（一轮）：只等 6 秒，网络快速恢复时几乎无感
        XCTAssertEqual(cooldown(afterFailures: 3), 6, accuracy: 0.001)
    }

    func testCooldownDoublesWithRounds() {
        XCTAssertEqual(cooldown(afterFailures: 6), 12, accuracy: 0.001)
        XCTAssertEqual(cooldown(afterFailures: 9), 24, accuracy: 0.001)
    }

    func testCooldownCapsAtMaximum() {
        // 反复失败（网络真的不可达）时封顶，避免指数爆炸
        XCTAssertEqual(cooldown(afterFailures: 15), 48, accuracy: 0.001)
        XCTAssertEqual(cooldown(afterFailures: 30), 48, accuracy: 0.001)
        XCTAssertEqual(cooldown(afterFailures: 99), 48, accuracy: 0.001)
    }

    func testEarlyRetryFasterThanOldFixedCooldown() {
        // 反证旧行为：同样是第一轮失败，旧代码固定等 60s，现在只等 6s
        XCTAssertLessThan(cooldown(afterFailures: 3), 60)
        XCTAssertEqual(cooldown(afterFailures: 3) * 10, 60, accuracy: 0.001)
    }

    func testBackoffSequenceIsMonotonic() {
        var previous: TimeInterval = 0
        for attempts in stride(from: 3, through: 60, by: 3) {
            let c = cooldown(afterFailures: attempts)
            XCTAssertGreaterThanOrEqual(c, previous)
            previous = c
        }
    }
}
