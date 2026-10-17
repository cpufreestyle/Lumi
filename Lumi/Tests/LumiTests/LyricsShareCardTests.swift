import XCTest
@testable import Lumi

/// 歌词分享卡片的数据组织测试（Foundation only，符合 LumiTests 不引入 GUI 框架的约束）。
///
/// 复刻 Musixmatch / Apple Music 付费功能「歌词分享卡片」——本组测试锁住文本
/// 截断 / 空值兜底 / 文件名清洗这三条纯逻辑规则，防止 UI 改版时悄悄改坏。
final class LyricsShareCardTests: XCTestCase {

    // MARK: - 截断规则

    func testTruncatedReturnsOriginalWhenWithinLimit() {
        let short = "短短一句"
        XCTAssertEqual(LyricsShareCard.truncated(short), short)
    }

    func testTruncatedAddsEllipsisWhenTooLong() {
        let long = String(repeating: "字", count: 80)
        let result = LyricsShareCard.truncated(long)
        XCTAssertEqual(result.count, LyricsShareCard.maxLineLength)
        XCTAssertTrue(result.hasSuffix(LyricsShareCard.ellipsis))
    }

    func testTruncatedTrimsWhitespaceBeforeChecking() {
        let padded = "   " + String(repeating: "a", count: 30) + "   "
        XCTAssertEqual(LyricsShareCard.truncated(padded), String(repeating: "a", count: 30))
    }

    func testTruncatedEmptyReturnsEmpty() {
        XCTAssertEqual(LyricsShareCard.truncated(""), "")
        XCTAssertEqual(LyricsShareCard.truncated("   "), "")
    }

    // MARK: - 字段组装

    func testDisplayFieldsUsesPlaceholderForEmptyTitle() {
        let card = LyricsShareCard(title: "", artist: "",
                                    original: "hello", translation: nil)
        let fields = card.displayFields
        XCTAssertEqual(fields.title, "正在播放")
        XCTAssertEqual(fields.artist, "")
        XCTAssertEqual(fields.original, "hello")
        XCTAssertNil(fields.translation)
    }

    func testDisplayFieldsDropsEmptyTranslation() {
        let card = LyricsShareCard(title: "T", artist: "A",
                                    original: "hi", translation: "   ")
        XCTAssertNil(card.displayFields.translation)
    }

    func testDisplayFieldsTruncatesLongLines() {
        let card = LyricsShareCard(title: "T", artist: "A",
                                    original: String(repeating: "x", count: 100),
                                    translation: nil)
        XCTAssertEqual(card.displayFields.original.count, LyricsShareCard.maxLineLength)
    }

    func testHasShareableContentFalseWhenOriginalEmpty() {
        let card = LyricsShareCard(title: "T", artist: "A",
                                    original: "   ", translation: "有译文")
        XCTAssertFalse(card.hasShareableContent)
    }

    func testHasShareableContentTrueWhenOriginalPresent() {
        let card = LyricsShareCard(title: "T", artist: "A",
                                    original: "hello", translation: nil)
        XCTAssertTrue(card.hasShareableContent)
    }

    // MARK: - 文件名清洗

    func testSuggestedFileNameKeepsNormalTitle() {
        let card = LyricsShareCard(title: "晴天", artist: "周杰伦",
                                    original: "x", translation: nil)
        XCTAssertEqual(card.suggestedFileName, "晴天")
    }

    func testSuggestedFileNameReplacesIllegalCharacters() {
        let card = LyricsShareCard(title: "a/b\\c:d?e", artist: "",
                                    original: "x", translation: nil)
        XCTAssertEqual(card.suggestedFileName, "a_b_c_d_e")
    }

    func testSuggestedFileNameFallsBackWhenEmpty() {
        let card = LyricsShareCard(title: "   ", artist: "",
                                    original: "x", translation: nil)
        XCTAssertEqual(card.suggestedFileName, "Lumi-Lyrics")
    }
}
