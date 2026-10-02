import XCTest
@testable import Lumi

/// 歌词版本标记识别测试（Foundation only）。
///
/// 同一首歌的 Live / Remastered / 伴奏版时间轴差数秒到数十秒，
/// 只看歌名会把所有版本都当命中——选错版本就是“歌词和歌声不一致”。
final class LyricsVersionTagTests: XCTestCase {

    func testDetectsLiveTagInBrackets() {
        XCTAssertEqual(LyricsVersionTag.tags(in: "稻香 (Live)"), ["live"])
    }

    func testDetectsChineseTags() {
        XCTAssertEqual(LyricsVersionTag.tags(in: "稻香 (伴奏)"), ["instrumental"])
        XCTAssertEqual(LyricsVersionTag.tags(in: "稻香 (现场)"), ["live"])
    }

    func testDetectsRemasterAfterDash() {
        XCTAssertEqual(LyricsVersionTag.tags(in: "七里香 - Remastered"), ["remaster"])
    }

    func testBareTitleHasNoTag() {
        XCTAssertTrue(LyricsVersionTag.tags(in: "稻香").isEmpty)
        XCTAssertFalse(LyricsVersionTag.hasTag("稻香"))
    }

    func testTagWordInTitleBodyIsNotAVersionTag() {
        // 歌名正文里出现 live 不算版本标记，否则 《Live & Learn》 会被误判
        XCTAssertFalse(LyricsVersionTag.hasTag("Live & Learn"))
    }

    func testSameTagsAcrossSources() {
        // 同一版本的不同标注形态应视为一致
        XCTAssertTrue(LyricsVersionTag.sameTags("稻香", "稻香"))
        XCTAssertTrue(LyricsVersionTag.sameTags("稻香 (Live)", "稻香 - Live"))
    }

    func testMismatchStudioVsLive() {
        XCTAssertFalse(LyricsVersionTag.sameTags("稻香", "稻香 (Live)"))
        XCTAssertFalse(LyricsVersionTag.sameTags("稻香 (Remastered)", "稻香 (伴奏)"))
    }

    func testSameTagFamilyMatches() {
        // Live 与 现场 属同族，不应互相冲突（都由 tags 集合为空判定）
        XCTAssertTrue(LyricsVersionTag.sameTags("七里香 (Live)", "七里香 (现场)"))
    }

    func testMultipleTagsDetected() {
        let tags = LyricsVersionTag.tags(in: "稻香 (Live) - Remastered")
        XCTAssertTrue(tags.contains("live"))
        XCTAssertTrue(tags.contains("remaster"))
    }
}

// MARK: - feat./括号后缀不应阻止歌名匹配

/// 实测《一个吻的时间 (feat. 冰球乐团)》：Music 的 trackName 带 feat. 后缀，
/// 歌词库收录的是干净名。只清洗搜索词不清洗校验词，会导致四个源全部走完
/// 却取不到歌词。
final class TrackTitleNormalizationTests: XCTestCase {
    private func scorePair(_ got: String, _ expect: String) -> Int {
        MusicController.testableTitleArtistScore(
            trackName: got, artistName: "温岚",
            expectTitle: expect, expectArtist: "温岚")
    }

    func testFeaturingSuffixDoesNotBlockMatch() {
        // 干净名 vs 带 feat. 后缀：必须判同一首歌
        XCTAssertGreaterThan(scorePair("一个吻的时间", "一个吻的时间 (feat. 冰球乐团)"), 0)
    }

    func testBracketSuffixDoesNotBlockMatch() {
        XCTAssertGreaterThan(scorePair("明明就", "明明就 (Bonus Track)"), 0)
    }

    func testLiveSuffixStillDetectedAsVersion() {
        // 版本标记仍要能被识别（用于 versionTag 重罚）
        XCTAssertTrue(LyricsVersionTag.hasTag("稻香 (Live)"))
        XCTAssertFalse(LyricsVersionTag.hasTag("稻香"))
    }

    func testCrossSongPrefixStillSeparated() {
        // 跨歌曲前缀由 ArtworkScoring.isSameSongTitle 在**歌名层**挡住
        //（testableTitleArtistScore 是更底层的计分入口，不含该判定——
        // 生产链路在 matchScore 之前就会先过 isSameSongTitle）。
        XCTAssertFalse(ArtworkScoring.isSameSongTitle(ArtworkScoring.norm("后来的我们"),
                                                       ArtworkScoring.norm("后来")))
    }
}
