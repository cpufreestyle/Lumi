import XCTest
@testable import Lumi

/// URL 查询参数编码测试（Foundation only）。
final class QueryEncodingTests: XCTestCase {

    func testPlusSignIsEncoded() {
        // `+` 在查询串里等价空格：不编码会让「A+B」被搜成「A B」
        XCTAssertEqual(QueryEncoding.encode("A+B"), "A%2BB")
    }

    func testAmpersandIsEncoded() {
        // `&` 是参数分隔符：歌名里的 & 必须编码，否则破坏查询结构
        XCTAssertEqual(QueryEncoding.encode("a&b"), "a%26b")
    }

    func testEqualsIsEncoded() {
        XCTAssertEqual(QueryEncoding.encode("a=b"), "a%3Db")
    }

    func testSlashIsEncoded() {
        XCTAssertEqual(QueryEncoding.encode("AC/DC"), "AC%2FDC")
    }

    func testSpaceIsEncoded() {
        XCTAssertEqual(QueryEncoding.encode("a b"), "a%20b")
    }

    func testUnreservedCharactersPassThrough() {
        XCTAssertEqual(QueryEncoding.encode("abcXYZ019-._~"), "abcXYZ019-._~")
    }

    func testChineseIsUTF8Encoded() {
        // 中文需按 UTF-8 逐字节编码（「你」= E4 BD A0）
        XCTAssertEqual(QueryEncoding.encode("你"), "%E4%BD%A0")
    }

    func testPercentIsEncoded() {
        // 百分号自身必须编码，否则会与转义序列混淆
        XCTAssertEqual(QueryEncoding.encode("100%"), "100%25")
    }

    func testEmptyStringStaysEmpty() {
        XCTAssertEqual(QueryEncoding.encode(""), "")
    }

    func testRoundTripThroughURLComponents() {
        // 端到端：编码后的值能被标准解码还原
        for original in ["A+B", "a&b=c", "稻香 (Live)", "AC/DC", "100% done"] {
            let encoded = QueryEncoding.encode(original)
            let decoded = encoded.replacingOccurrences(of: "+", with: " ")
            let restored = decoded.removingPercentEncoding
            XCTAssertEqual(restored, original, "round-trip failed for \(original)")
        }
    }
}
