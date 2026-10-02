import XCTest
@testable import Lumi

/// 批量译文拆分测试（Foundation only）。
///
/// 旧实现严格行数相等，否则整批丢弃 —— 翻译 API 常见的几种返回偏差
/// （尾部多换行 / 行内插换行 / 合并短行）都会让 8 行译文全丢，
/// 双语歌词出现成片空缺。现在必须容错对齐。
final class SplitBatchTests: XCTestCase {
    private let eight = (1...8).map { "line\($0)" }.joined(separator: "\n")

    func testExactCountPassesThrough() {
        XCTAssertEqual(MusicController.testableSplitBatch(eight, expected: 8)?.count, 8)
    }

    func testTrailingNewlineIsTolerated() {
        // API 在结尾多送一个换行：旧实现整批丢弃
        let result = MusicController.testableSplitBatch(eight + "\n", expected: 8)
        XCTAssertEqual(result?.count, 8)
        XCTAssertEqual(result?.last, "line8")
    }

    func testCRLFIsNormalized() {
        let crlf = eight.replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertEqual(MusicController.testableSplitBatch(crlf, expected: 8)?.count, 8)
    }

    func testExtraLinesAreMergedProportionally() {
        // 某一行被拆成两行：必须凑回 8 行，且不丢内容
        let split = "line1\nline2\nli\nne3\nline4\nline5\nline6\nline7\nline8"
        let result = MusicController.testableSplitBatch(split, expected: 8)
        XCTAssertEqual(result?.count, 8)
        // 按比例合并：被拆开的两半要紧邻合并，内容不丢
        XCTAssertEqual(result?.last, "line8")
        let joined = result?.joined(separator: " ") ?? ""
        XCTAssertTrue(joined.contains("ne3"), "被拆开的行必须被并回，不能丢")
        XCTAssertTrue(joined.contains("line1"))
    }

    func testMissingLinesArePaddedNotDropped() {
        // 只有 5 行译文：补 3 个空串，而不是整批作废
        let short = (1...5).map { "line\($0)" }.joined(separator: "\n")
        let result = MusicController.testableSplitBatch(short, expected: 8)
        XCTAssertEqual(result?.count, 8)
        XCTAssertEqual(result?.first, "line1")
        XCTAssertEqual(result?[5], "")
    }

    func testResultAlwaysMatchesExpectedCount() {
        // 属性：不论输入多乱，返回行数必须等于 expected
        for raw in [eight, eight + "\n", "single", "", "\n\n\n", eight + "\n\nextra"] {
            let r = MusicController.testableSplitBatch(raw, expected: 8)
            if let r { XCTAssertEqual(r.count, 8, "raw=\\(raw.prefix(20))") }
        }
    }

    func testEmptyInputReturnsNil() {
        XCTAssertNil(MusicController.testableSplitBatch("", expected: 8))
        XCTAssertNil(MusicController.testableSplitBatch(nil, expected: 8))
    }

    func testZeroExpectedReturnsNil() {
        XCTAssertNil(MusicController.testableSplitBatch(eight, expected: 0))
    }
}
