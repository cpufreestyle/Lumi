import XCTest
@testable import Lumi

/// 一键对齐公式测试（Foundation only）。
///
/// 匹配规则是 `adjustedTime = currentTime - offset`；点击行后必须反推出
/// `offset = currentTime - line.time = -delta`。历史 bug 直接用 `delta`，
/// 导致越点越歪，因此这个符号必须由单测锁死。
final class LyricsAlignmentTests: XCTestCase {
    func testLineEarlierThanPlaybackGivesPositiveOffset() {
        // currentTime=20，line.time=10 → delta=-10 → offset=+10
        // 正 offset 会把匹配基准后移，让 10s 的行在 20s 处仍可命中。
        XCTAssertEqual(LyricsAlignment.offset(fromLineDelta: -10), 10, accuracy: 0.001)
    }

    func testLineLaterThanPlaybackGivesNegativeOffset() {
        // currentTime=20，line.time=30 → delta=+10 → offset=-10
        XCTAssertEqual(LyricsAlignment.offset(fromLineDelta: 10), -10, accuracy: 0.001)
    }

    func testExactAlignmentGivesZero() {
        XCTAssertEqual(LyricsAlignment.offset(fromLineDelta: 0), 0, accuracy: 0.001)
    }

    func testCentisecondPrecisionIsPreserved() {
        XCTAssertEqual(LyricsAlignment.offset(fromLineDelta: -1.234), 1.23, accuracy: 0.001)
    }

    func testOffsetIsClampedToLimit() {
        XCTAssertEqual(LyricsAlignment.offset(fromLineDelta: 20), -10, accuracy: 0.001)
        XCTAssertEqual(LyricsAlignment.offset(fromLineDelta: -20), 10, accuracy: 0.001)
    }

    func testSolvedEquationMakesClickedLineActive() {
        let currentTime: TimeInterval = 73.456
        let lineTime: TimeInterval = 70.123
        let delta = lineTime - currentTime
        let offset = LyricsAlignment.offset(fromLineDelta: delta)
        // 把解出的 offset 代回匹配式：adjustedTime 必须等于被点击行的时间。
        XCTAssertEqual(currentTime - offset, lineTime, accuracy: 0.01)
    }
}
