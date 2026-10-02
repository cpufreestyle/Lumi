import XCTest
@testable import Lumi

/// 翻译代次机制测试（Foundation only）。
///
/// 代次要解决的问题：切双语模式 / 换歌 / 换时间轴都会重开一轮翻译，
/// 而旧轮次的批次可能仍在途。没有代次时旧轮的译文会写进新一代的
/// 歌词行 —— 原文相同但时间轴不同，译文就错行了（用户看到的正是
/// 「歌词和歌声不一致」：中文英文对不上）。
final class TranslationGenerationTests: XCTestCase {

    /// 复刻「代次相等才写回」的判定。
    private func shouldApply(captured: UInt64, current: UInt64) -> Bool {
        captured == current
    }

    func testSameGenerationApplies() {
        XCTAssertTrue(shouldApply(captured: 3, current: 3))
    }

    func testStaleGenerationIsDropped() {
        XCTAssertFalse(shouldApply(captured: 2, current: 3))
        XCTAssertFalse(shouldApply(captured: 1, current: 5))
    }

    func testGenerationNeverReusedAfterBump() {
        // 代次只增不减：bump 之后旧捕获值永远不可能再等于当前值
        var current: UInt64 = 10
        let captured = current
        current &+= 1
        XCTAssertNotEqual(captured, current)
        XCTAssertFalse(shouldApply(captured: captured, current: current))
    }

    func testOverflowWrapsButStaysDistinct() {
        // &+= 在 UInt64.max 处回绕到 0，也不会与常见旧值碰撞
        var g: UInt64 = .max
        g &+= 1
        XCTAssertEqual(g, 0)
        XCTAssertFalse(shouldApply(captured: .max, current: g))
    }

    func testSequentialGenerationsAreDistinct() {
        // 连续 bump 出的每一代都必须互不相同
        var seen: Set<UInt64> = []
        var g: UInt64 = 0
        for _ in 0..<1000 {
            g &+= 1
            XCTAssertTrue(seen.insert(g).inserted, "代次 \(g) 重复出现")
        }
    }
}
