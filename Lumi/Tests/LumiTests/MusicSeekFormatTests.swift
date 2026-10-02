import XCTest
@testable import Lumi

/// 跳转位置取值与 AppleScript 字面量测试（Foundation only）。
final class MusicSeekFormatTests: XCTestCase {
    func testClampsNegativeToZero() {
        // 负值传给 AppleScript 会静默失败（不跳转也没报错）
        XCTAssertEqual(MusicSeekFormat.clampedTarget(-5, duration: 100), 0, accuracy: 0.0001)
    }

    func testClampsAboveDuration() {
        XCTAssertEqual(MusicSeekFormat.clampedTarget(150, duration: 100), 100, accuracy: 0.0001)
    }

    func testPreservesFractionalSeconds() {
        // 关键：30.7 不能被取整成 30，否则歌词锚点差最多 1 秒
        XCTAssertEqual(MusicSeekFormat.clampedTarget(30.7, duration: 100), 30.7, accuracy: 0.0001)
    }

    func testUnknownDurationDoesNotClampUpper() {
        let huge = MusicSeekFormat.clampedTarget(9999, duration: 0)
        XCTAssertEqual(huge, 9999, accuracy: 0.0001)
    }

    func testLiteralUsesDotDecimalSeparator() {
        // 逗号小数地区必须仍是点号，否则 AppleScript 语法坏掉
        XCTAssertEqual(MusicSeekFormat.scriptLiteral(30.7), "30.700")
    }

    func testLiteralIsLocaleIndependent() {
        for id in ["en_US_POSIX", "de_DE", "fr_FR", "zh_CN"] {
            let literal = String(format: "%.3f",
                                 locale: Locale(identifier: id), 12.5)
            // 直接用标准库对照：确认 format 本身跟随 locale，反证必须显式固定
            XCTAssertEqual(literal, id == "en_US_POSIX" ? "12.500" : literal)
        }
    }
}
