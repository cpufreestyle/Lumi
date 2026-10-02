import XCTest
@testable import Lumi

/// LRC `[offset:]` 元数据解析测试（Foundation only）。
///
/// 该标签是歌词作者写明的全局时间轴校准；解析器丢弃它会导致整首歌
/// 与演唱错位——这正是“歌词和演唱不同步”的根因之一。
final class LRCMetadataTests: XCTestCase {
    func testPositiveOffsetMeansAdvance() {
        XCTAssertEqual(LRCMetadata.globalOffsetSeconds("[offset:500]"), 0.5, accuracy: 0.001)
    }

    func testNegativeOffsetMeansDelay() {
        XCTAssertEqual(LRCMetadata.globalOffsetSeconds("[offset:-250]"), -0.25, accuracy: 0.001)
    }

    func testDecimalMilliseconds() {
        XCTAssertEqual(LRCMetadata.globalOffsetSeconds("[offset:1234.5]"), 1.2345, accuracy: 0.001)
    }

    func testIgnoresMissingOffset() {
        XCTAssertEqual(LRCMetadata.globalOffsetSeconds("[ti:测试]\n[00:01.00]第一句"), 0)
    }

    func testIgnoresMalformedOffset() {
        XCTAssertEqual(LRCMetadata.globalOffsetSeconds("[offset:abc]"), 0)
        XCTAssertEqual(LRCMetadata.globalOffsetSeconds("[offset:]"), 0)
    }

    func testCaseInsensitiveTag() {
        XCTAssertEqual(LRCMetadata.globalOffsetSeconds("[OFFSET:750]"), 0.75, accuracy: 0.001)
    }

    func testFirstOffsetWinsWhenDuplicated() {
        let raw = "[offset:100]\n[00:01.00]第一句\n[offset:200]"
        XCTAssertEqual(LRCMetadata.globalOffsetSeconds(raw), 0.1, accuracy: 0.001)
    }

    func testOffsetLineIsWhitespaceTolerant() {
        XCTAssertEqual(LRCMetadata.globalOffsetSeconds("  [offset: 300 ]  "), 0.3, accuracy: 0.001)
    }
}
