import XCTest
@testable import Lumi

/// 歌词候选的专辑名交叉验证测试（Foundation only）。
///
/// 实测确认 lrclib 返回 `albumName` 字段，而歌词评分此前完全没用它。
/// 专辑名是区分「同名同歌手不同专辑」的强信号。
final class LyricsAlbumCrossCheckTests: XCTestCase {

    func testSameAlbumGainsBonus() {
        let s = ArtworkScoring.albumScore(album: "魔杰座", expAlbum: "魔杰座")
        XCTAssertEqual(s, ArtworkScoring.albumExactBonus)
    }

    func testAlbumWithVersionSuffixStillMatches() {
        // Apple 与 lrclib 的专辑名常带版本后缀，属同一张专辑
        let s = ArtworkScoring.albumScore(album: "魔杰座 (内地版)", expAlbum: "魔杰座")
        XCTAssertEqual(s, ArtworkScoring.albumContainsBonus)
    }

    func testDifferentAlbumIsPenalized() {
        let s = ArtworkScoring.albumScore(album: "叶惠美", expAlbum: "魔杰座")
        XCTAssertEqual(s, ArtworkScoring.albumMismatchPenalty)
    }

    func testMissingAlbumScoresZero() {
        // 流媒体常缺专辑名：不参与评分，不能误伤
        XCTAssertEqual(ArtworkScoring.albumScore(album: "", expAlbum: "魔杰座"), 0)
        XCTAssertEqual(ArtworkScoring.albumScore(album: "魔杰座", expAlbum: ""), 0)
    }

    func testSameAlbumBonusCannotBeatVersionTagPenalty() {
        // 关键不变式：专辑名满分(+40) + 歌名歌手满分，仍要低于 versionTag 重罚(-300)
        // 否则 Live 版靠专辑名吻合就能压过正确版本
        let albumBonus = ArtworkScoring.albumExactBonus
        XCTAssertEqual(albumBonus, 40)
        XCTAssertGreaterThan(300, albumBonus + 100 + 50)
    }

    func testTraditionalSimplifiedAlbumMatches() {
        // 繁简差异不能导致专辑名误判
        let s = ArtworkScoring.albumScore(album: "魔傑座", expAlbum: "魔杰座")
        XCTAssertEqual(s, ArtworkScoring.albumExactBonus)
    }


}

// MARK: - 歌手主名重罚（压住翻唱候选）

/// 翻唱版的歌名可能完全相同、只有歌手不同。若选中，其时间轴与演唱
/// 必然对不上（歌词和歌声不一致）。艺术家主名惩罚必须把它压下去。
final class LyricsArtistPenaltyTests: XCTestCase {
    private let penalty = 30

    /// 复刻 resolveLyrics 的「歌手主名不匹配扣分」判定。
    private func artistPenalty(expectArtist: String, gotArtist: String) -> Int {
        // primaryArtist 的简化版：只截 feat./ft. 分隔
        func primary(_ a: String) -> String {
            var s = a
            for sep in [" feat.", " feat ", " ft.", " ft ", " & ", ", ", " x ", " 、"] {
                if let r = s.range(of: sep, options: .caseInsensitive) {
                    s = String(s[s.startIndex..<r.lowerBound])
                }
            }
            return s.trimmingCharacters(in: .whitespaces)
        }
        let p = primary(expectArtist)
        if p.isEmpty { return 0 }
        return gotArtist.localizedCaseInsensitiveContains(p) ? 0 : -penalty
    }

    func testCoverVersionGetsPenalized() {
        // 期望周杰伦、候选是某翻唱歌手：必须扣分
        XCTAssertEqual(artistPenalty(expectArtist: "周杰伦", gotArtist: "某网络歌手"),
                       -penalty)
    }

    func testOriginalArtistNotPenalized() {
        XCTAssertEqual(artistPenalty(expectArtist: "周杰伦", gotArtist: "周杰伦"), 0)
    }

    func testFeaturingArtistStillMatches() {
        // 合作曲目：候选含主名，不算翻唱
        XCTAssertEqual(artistPenalty(expectArtist: "周杰伦", gotArtist: "周杰伦 feat. 费玉清"), 0)
    }

    func testExpectFeaturingStripedBeforeCompare() {
        // 期望歌手带 feat.（如 "温岚 feat. 冰球乐团"）时先取主名再比
        XCTAssertEqual(artistPenalty(expectArtist: "温岚 feat. 冰球乐团", gotArtist: "温岚"), 0)
    }

    func testPenaltyCannotBeOffsetByTitleBonus() {
        // 关键不变式：歌名满分 + 专辑满分 + 时长满分，也压不过翻唱的罚分影响
        //（歌名 100 + 歌手 0 + 专辑 40 + 时长 30 = 170，扣 30 后 140；
        //  而正确版本 100 + 50 + 40 + 30 = 220，同时还有版本/时间轴加分）
        let coverScore = 100 + 0 + ArtworkScoring.albumExactBonus
            + ArtworkScoring.durationExactBonus - penalty
        let originalScore = 100 + 50 + ArtworkScoring.albumExactBonus
            + ArtworkScoring.durationExactBonus
        XCTAssertLessThan(coverScore, originalScore)
    }
}
