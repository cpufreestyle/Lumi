import XCTest
@testable import Lumi

/// 字号档位与语言放大倍率测试（Foundation only）。
final class DesktopLyricsFontScaleTests: XCTestCase {

    func testMediumPresetMatchesBaseSizes() {
        XCTAssertEqual(DesktopLyricsLayout.scaledOriginalFontSize(.medium, line: "你好"),
                       DesktopLyricsLayout.originalFontSize, accuracy: 0.001)
    }

    func testLatinScalesAboveChinese() {
        let en = DesktopLyricsLayout.scaledOriginalFontSize(.medium, line: "Hello world")
        let zh = DesktopLyricsLayout.scaledOriginalFontSize(.medium, line: "你好世界")
        XCTAssertEqual(en / zh, DesktopLyricsLayout.latinScale, accuracy: 0.0001)
    }

    func testLanguageAdjustedEnglishAtLeastChinese() {
        // 用户要求：英文歌词字号必须「大于中文或等于中文」。
        // languageAdjusted 是胶囊 / 展开面板 / 逐行歌词的统一入口。
        let en = DesktopLyricsLayout.languageAdjusted(22, line: "I still believe in you")
        let zh = DesktopLyricsLayout.languageAdjusted(22, line: "我依然相信你")
        XCTAssertGreaterThanOrEqual(en, zh)
        XCTAssertEqual(en / zh, DesktopLyricsLayout.latinScale, accuracy: 0.0001)
        // 中英混排（含 CJK）不算纯拉丁文：保持中文基准，即「等于中文」
        let mixed = DesktopLyricsLayout.languageAdjusted(22, line: "I love you 我爱你")
        XCTAssertEqual(mixed, zh, accuracy: 0.0001)
    }

    func testLanguageAdjustedTranslationLine() {
        let en = DesktopLyricsLayout.languageAdjusted(16, line: "Never gonna give you up")
        let zh = DesktopLyricsLayout.languageAdjusted(16, line: "永远不会放弃你")
        XCTAssertGreaterThanOrEqual(en, zh)
    }

    func testLatinScaleAppliesToTranslationToo() {
        let en = DesktopLyricsLayout.scaledTranslationFontSize(.medium, line: "Hello")
        let zh = DesktopLyricsLayout.scaledTranslationFontSize(.medium, line: "你好")
        XCTAssertEqual(en / zh, DesktopLyricsLayout.latinScale, accuracy: 0.0001)
    }

    func testPresetScaleIsMonotonic() {
        XCTAssertLessThan(DesktopLyricsSizePreset.small.scale,
                          DesktopLyricsSizePreset.medium.scale)
        XCTAssertLessThan(DesktopLyricsSizePreset.medium.scale,
                          DesktopLyricsSizePreset.large.scale)
    }

    func testScaledSizesGrowWithPreset() {
        let small = DesktopLyricsLayout.scaledOriginalFontSize(.small, line: "你好")
        let medium = DesktopLyricsLayout.scaledOriginalFontSize(.medium, line: "你好")
        let large = DesktopLyricsLayout.scaledOriginalFontSize(.large, line: "你好")
        XCTAssertLessThan(small, medium)
        XCTAssertLessThan(medium, large)
    }

    func testPresetCyclingReturnsToStart() {
        // 三档循环：small -> medium -> large -> small
        let afterThree = DesktopLyricsSizePreset.small.next.next.next
        XCTAssertEqual(afterThree, .small)
    }

    func testStoredFallsBackOnGarbage() {
        XCTAssertEqual(DesktopLyricsSizePreset.stored(nil), .medium)
        XCTAssertEqual(DesktopLyricsSizePreset.stored("not-a-preset"), .medium)
        XCTAssertEqual(DesktopLyricsSizePreset.stored("large"), .large)
    }

    func testWindowWidthFollowsFontScale() {
        // 长行时窗口必须够宽，否则英文被裁
        // 用刚好低于 maxWidth 的文本：两端都不触顶才能看出宽度差
        let text = "Hello world my friend"
        let en = DesktopLyricsLayout.contentSize(line: text, translation: "",
                                                 showTranslation: false, sizeScale: 1.0)
        let asCjk = DesktopLyricsLayout.contentSize(
            line: text, translation: "", showTranslation: false,
            originalFontSize: DesktopLyricsLayout.originalFontSize / DesktopLyricsLayout.latinScale,
            translationFontSize: DesktopLyricsLayout.translationFontSize,
            sizeScale: 1.0)
        XCTAssertGreaterThan(en.width, asCjk.width)
    }
}
