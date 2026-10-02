import XCTest
@testable import Lumi

/// 行内双语拆分测试（Foundation only）。
final class BilingualSplitTests: XCTestCase {

    // MARK: - 正常双语必须保留

    func testChineseSlashEnglishSplits() {
        let r = BilingualSplit.validate("你好", "Hello")
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.translation, "Hello")
    }

    func testEnglishSlashChineseSplits() {
        let r = BilingualSplit.validate("Hello", "你好")
        XCTAssertNotNil(r)
    }

    func testPhraseBilingualSplits() {
        let r = BilingualSplit.validate("谢谢你的爱", "Thank you for your love")
        XCTAssertNotNil(r)
    }

    // MARK: - 同句误拆必须挡住

    func testColonInsideOneSentenceIsNotBilingual() {
        // 实测误判案例：原文前半被当译文丢掉
        XCTAssertNil(BilingualSplit.validate("CD机", "播这首歌"))
    }

    func testTwoChineseHalvesAreNotBilingual() {
        XCTAssertNil(BilingualSplit.validate("他说", "你好吗"))
        XCTAssertNil(BilingualSplit.validate("妈妈", "回家吃饭了"))
    }

    func testIdenticalSidesAreNotBilingual() {
        XCTAssertNil(BilingualSplit.validate("你好", "你好"))
    }

    func testEmptySidesAreNotBilingual() {
        XCTAssertNil(BilingualSplit.validate("", "Hello"))
        XCTAssertNil(BilingualSplit.validate("你好", ""))
    }

    func testTwoEnglishHalvesAreNotBilingual() {
        // 两侧都纯拉丁：不是「中英对照」
        XCTAssertNil(BilingualSplit.validate("Hello world", "Goodbye moon"))
    }

    // MARK: - 语言探测

    func testLanguageDetection() {
        XCTAssertTrue(BilingualSplit.hasCJK("你好"))
        XCTAssertFalse(BilingualSplit.hasCJK("hello"))
        XCTAssertTrue(BilingualSplit.hasLatin("hello"))
        XCTAssertFalse(BilingualSplit.hasLatin("你好"))
        XCTAssertTrue(BilingualSplit.hasCJK("CD机"))
        XCTAssertTrue(BilingualSplit.hasLatin("CD机"))
    }
}
