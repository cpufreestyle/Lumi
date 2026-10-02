import XCTest
@testable import Lumi

/// 封面候选消歧评分测试（Foundation only，符合 LumiTests 不引入 GUI 框架的约束）。
///
/// 这组测试锁的是「图片有时候会不对」的判定规则：同名同歌手的歌存在多个版本时，
/// 必须靠专辑名与时长把它们区分开。真实案例来自实机排查 —— 《神预言》袁娅维的
/// 录音室版（191.6s）与《为歌而赞》Live 版（268.7s）歌名歌手一字不差。
final class ArtworkScoringTests: XCTestCase {

    // MARK: - 专辑名比对

    func testAlbumExactMatchGainsMost() {
        XCTAssertEqual(ArtworkScoring.albumScore(album: "月亮失眠了", expAlbum: "月亮失眠了"),
                       ArtworkScoring.albumExactBonus)
    }

    func testAlbumContainsGainsLess() {
        // Apple 目录常在专辑名后挂版本后缀，属同一张专辑。
        XCTAssertEqual(
            ArtworkScoring.albumScore(album: "月亮失眠了 (DELUXE EDITION)", expAlbum: "月亮失眠了"),
            ArtworkScoring.albumContainsBonus
        )
    }

    func testAlbumMismatchIsHeavilyPenalized() {
        // 完全不同专辑 -> 极可能是另一张封面图。
        XCTAssertEqual(ArtworkScoring.albumScore(album: "为歌而赞第二季 第12期", expAlbum: "月亮失眠了"),
                       ArtworkScoring.albumMismatchPenalty)
    }

    func testAlbumMissingOnEitherSideScoresZero() {
        // 缺信息不等于不匹配，不能用「没专辑名」误伤本该命中的候选。
        XCTAssertEqual(ArtworkScoring.albumScore(album: "", expAlbum: "月亮失眠了"), 0)
        XCTAssertEqual(ArtworkScoring.albumScore(album: "月亮失眠了", expAlbum: ""), 0)
    }

    func testAlbumScoringIgnoresCaseAndPunctuation() {
        XCTAssertEqual(ArtworkScoring.albumScore(album: "God, I'm Going Crazy", expAlbum: "god im going crazy"),
                       ArtworkScoring.albumExactBonus)
    }

    // MARK: - 时长比对

    func testDurationWithinToleranceGainsMost() {
        // 实测 Apple 目录与 Music 报的时长差为 0.0s。
        XCTAssertEqual(ArtworkScoring.durationScore(candidate: 191.635, expected: 191.6),
                       ArtworkScoring.durationExactBonus)
    }

    func testDurationNearStillPositive() {
        XCTAssertEqual(ArtworkScoring.durationScore(candidate: 195.0, expected: 191.6),
                       ArtworkScoring.durationNearBonus)
    }

    func testDurationLooseDifferencePenalized() {
        XCTAssertEqual(ArtworkScoring.durationScore(candidate: 200.0, expected: 191.6),
                       ArtworkScoring.durationLoosePenalty)
    }

    func testDurationLargeDifferenceHeavilyPenalized() {
        // 191.6s 录音室版 vs 268.7s Live 版：靠这一项就能判为不同版本。
        XCTAssertEqual(ArtworkScoring.durationScore(candidate: 268.713, expected: 191.6),
                       ArtworkScoring.durationMismatchPenalty)
    }

    func testDurationZeroOnEitherSideScoresZero() {
        XCTAssertEqual(ArtworkScoring.durationScore(candidate: 0, expected: 191.6), 0)
        XCTAssertEqual(ArtworkScoring.durationScore(candidate: 191.6, expected: 0), 0)
    }

    // MARK: - 组合评分

    func testCorrectVersionScoresFarAboveLiveVersion() {
        // 同一首歌的两个版本，歌名歌手全同，只有专辑与时长不同。
        let studio = ArtworkScoring.score(album: "月亮失眠了 (DELUXE EDITION)", durSec: 191.635,
                                          expAlbum: "月亮失眠了", expDur: 191.6)
        let live = ArtworkScoring.score(album: "为歌而赞第二季 第12期", durSec: 268.713,
                                        expAlbum: "月亮失眠了", expDur: 191.6)
        XCTAssertGreaterThan(studio, live)
        // 差值必须足以越过 115 分线的判断空间，否则「取错版本」仍会发生。
        XCTAssertGreaterThanOrEqual(studio - live, 100)
    }

    func testScoreWithoutAnyMetadataIsZero() {
        // 两侧都没有专辑与时长：不加分也不扣分，退回纯歌名歌手匹配。
        XCTAssertEqual(ArtworkScoring.score(album: "", durSec: 0, expAlbum: "", expDur: 0), 0)
    }

    // MARK: - 归一化（繁简与标点）

    func testNormUnifiesTraditionalAndSimplified() {
        // Apple 的 tw/hk 店铺返回繁体「神預言 袁婭維」，Music 报简体。
        // 不统一字形，歌名会直接判不匹配（这是接入 Apple 目录后新增的必要处理）。
        XCTAssertEqual(ArtworkScoring.norm("神預言"), ArtworkScoring.norm("神预言"))
        XCTAssertEqual(ArtworkScoring.norm("袁婭維"), ArtworkScoring.norm("袁娅维"))
    }

    func testNormStripsWhitespacePunctuationAndSlashes() {
        XCTAssertEqual(ArtworkScoring.norm("A-Lin"), ArtworkScoring.norm("a lin"))
        XCTAssertEqual(ArtworkScoring.norm("Jay Chou"), ArtworkScoring.norm("jay/ chou"))
        XCTAssertEqual(ArtworkScoring.norm("Don't Stop"), ArtworkScoring.norm("dontstop"))
    }

    func testAlbumScoreMatchesAcrossTraditionalAndSimplified() {
        // 繁体专辑名与简体专辑名应判为同一专辑。
        XCTAssertEqual(ArtworkScoring.albumScore(album: "愛回來 精選2015", expAlbum: "爱回来 精选2015"),
                       ArtworkScoring.albumExactBonus)
    }

    // MARK: - 磁盘缓存键

    func testCacheKeyNormalizesCaseAndPunctuation() {
        // 同一首歌在不同店铺/不同次读取里大小写与标点可能不同，必须落到同一缓存文件。
        XCTAssertEqual(ArtworkScoring.cacheKey(title: "Don't Stop", artist: "Jay Chou", album: "Ye Hui Mei"),
                       ArtworkScoring.cacheKey(title: "dont stop", artist: "JAY CHOU", album: "ye hui mei"))
    }

    func testCacheKeyIsStableAcrossTraditionalAndSimplified() {
        // tw/hk 店铺报繁体、Music 报简体，若不统一则同一首歌会缓存两份，
        // 每次切歌都重新走一遍在线链路 —— 缓存等于没生效。
        XCTAssertEqual(ArtworkScoring.cacheKey(title: "神预言", artist: "袁娅维", album: "月亮失眠了"),
                       ArtworkScoring.cacheKey(title: "神預言", artist: "袁婭維", album: "月亮失眠了"))
    }

    func testCacheKeyDistinguishesDifferentVersions() {
        // 录音室版与 Live 版歌名歌手全同，键必须不同，
        // 否则两个版本会互相覆盖同一个缓存文件 —— 正是本轮要修的错图根因。
        let studio = ArtworkScoring.cacheKey(title: "神预言", artist: "袁娅维", album: "月亮失眠了")
        let live = ArtworkScoring.cacheKey(title: "神预言", artist: "袁娅维", album: "为歌而赞第二季 第12期")
        XCTAssertNotEqual(studio, live)
    }

    func testCacheKeyDistinguishesDifferentArtists() {
        // 同名不同歌手是常见情况（翻唱），不能撞同一个键。
        let a = ArtworkScoring.cacheKey(title: "后来", artist: "刘若英", album: "我等你")
        let b = ArtworkScoring.cacheKey(title: "后来", artist: "杨宗纬", album: "原色")
        XCTAssertNotEqual(a, b)
    }

    func testCacheKeyIsEmptyWhenAllFieldsEmpty() {
        // 空键必须可识别（调用侧 guard 拒绝空键），避免全部曲目共用一个文件。
        XCTAssertEqual(ArtworkScoring.cacheKey(title: "", artist: "", album: ""), "||")
    }
}

    // MARK: - 歌名 + 歌手打分

    func testTrackArtistExactBothReachesTopScore() {
        let s = ArtworkScoring.trackArtistScore(rTitle: "稻香", rArtist: "周杰伦",
                                                 eTitle: "稻香", eArtist: "周杰伦")
        XCTAssertEqual(s, ArtworkScoring.titleExactBonus + ArtworkScoring.artistExactBonus)
    }

    func testTrackArtistContainsPair() {
        // 歌名互含（Apple 目录常带后缀）、歌手互含（合作曲目）。
        let s = ArtworkScoring.trackArtistScore(rTitle: "稻香 (Live)", rArtist: "周杰伦/费玉清",
                                                 eTitle: "稻香", eArtist: "周杰伦")
        XCTAssertEqual(s, ArtworkScoring.titleContainsBonus + ArtworkScoring.artistContainsBonus)
    }

    func testTrackArtistTitleMismatchRejected() {
        XCTAssertEqual(ArtworkScoring.trackArtistScore(rTitle: "七里香", rArtist: "周杰伦",
                                                       eTitle: "稻香", eArtist: "周杰伦"), -1)
    }

    // MARK: - 整合评分（封面防串曲核心）

    func testIntegratedSingerMismatchStaysBelowThreshold() {
        // 歌名精确但歌手完全不同 → 翻唱版，必须低于 115 线被拒（防贴错封面）。
        let s = ArtworkScoring.integratedScore(rTitle: "稻香", rArtist: "某翻唱歌手",
                                               rAlbum: "翻唱合集", rDurSec: 230,
                                               eTitle: "稻香", eArtist: "周杰伦",
                                               eAlbum: "魔杰座", eDurSec: 230)
        XCTAssertLessThan(s, 115)
    }

    func testIntegratedSameNameSingerDiffVersionSeparatedByDuration() {
        // 同名同歌手的 Live 版靠时长差异被压低（《神预言》实机案例）。
        let studio = ArtworkScoring.integratedScore(rTitle: "神预言", rArtist: "袁娅维",
                                                    rAlbum: "神预言", rDurSec: 191.6,
                                                    eTitle: "神预言", eArtist: "袁娅维",
                                                    eAlbum: "神预言", eDurSec: 191.6)
        let live = ArtworkScoring.integratedScore(rTitle: "神预言", rArtist: "袁娅维",
                                                  rAlbum: "为歌而赞", rDurSec: 268.7,
                                                  eTitle: "神预言", eArtist: "袁娅维",
                                                  eAlbum: "神预言", eDurSec: 191.6)
        XCTAssertGreaterThanOrEqual(studio, 115)
        XCTAssertLessThan(live, studio)
    }

    func testIntegratedAlbumMismatchHeavilyPenalized() {
        // 同名同歌手同时长但专辑名完全不同 → 极可能另一张封面图。
        let s = ArtworkScoring.integratedScore(rTitle: "月亮失眠了", rArtist: "A",
                                               rAlbum: "为歌而赞第二季", rDurSec: 200,
                                               eTitle: "月亮失眠了", eArtist: "A",
                                               eAlbum: "月亮失眠了", eDurSec: 200)
        XCTAssertLessThan(s, 115)
    }

    // MARK: - 歌手主名拆分

    func testPrimaryArtistStripsFeaturings() {
        XCTAssertEqual(ArtworkScoring.primaryArtist("周杰伦 feat. 费玉清"), "周杰伦")
        XCTAssertEqual(ArtworkScoring.primaryArtist("A & B"), "A")
        XCTAssertEqual(ArtworkScoring.primaryArtist("张三、李四"), "张三")
        XCTAssertEqual(ArtworkScoring.primaryArtist("独立歌手"), "独立歌手")
    }

// MARK: - 歌名「包含」的长度差约束

/// 纯 contains 会把跨歌曲前缀判成命中（「后来」/「后来的我们」）。
/// 这些是不同歌曲，歌词时间轴毫无关系，选中就是整首别人的词。
final class TitleContainsLengthGateTests: XCTestCase {
    private func score(_ rTitle: String, _ eTitle: String, artist: String = "周杰伦") -> Int {
        ArtworkScoring.trackArtistScore(rTitle: rTitle, rArtist: artist,
                                       eTitle: eTitle, eArtist: artist)
    }

    func testCrossSongPrefixIsRejected() {
        // 完全不同的歌：必须判不匹配（-1）
        XCTAssertEqual(score("后来的我们", "后来"), -1)
        XCTAssertEqual(score("遇见你", "遇见"), -1)
        XCTAssertEqual(score("童话镇", "童话"), -1)
        XCTAssertEqual(score("匆匆那年", "匆匆"), -1)
        XCTAssertEqual(score("心动起来", "心动"), -1)
    }

    func testSameSongWithVersionTagStillMatches() {
        // 同一首歌 + 版本标记：归一化后长度差很小，必须仍然命中
        XCTAssertEqual(score("稻香 (Live)", "稻香"),
                       ArtworkScoring.titleContainsBonus + ArtworkScoring.artistExactBonus)
        XCTAssertEqual(score("稻香 (伴奏)", "稻香"),
                       ArtworkScoring.titleContainsBonus + ArtworkScoring.artistExactBonus)
    }

    func testExactMatchUnaffected() {
        XCTAssertEqual(score("稻香", "稻香"),
                       ArtworkScoring.titleExactBonus + ArtworkScoring.artistExactBonus)
    }

    func testExtraSegmentMustBeAVersionTag() {
        // 多出的部分必须是版本标记词，随便加字不算同一首歌
        let base = "稻香"
        XCTAssertGreaterThan(score(base + "live", base), 0)
        XCTAssertEqual(score(base + "啊", base), -1)
        XCTAssertEqual(score(base + "的我们", base), -1)
    }

    func testSuffixTagAlsoAccepted() {
        // 版本标记在后缀位（少见但存在）同样成立
        XCTAssertGreaterThan(score("伴奏稻香", "稻香"), 0)
    }
}

// MARK: - 时长容差与真实元数据差异

/// 容差太紧会把同一版本的另一个上传误罚：实测《So Crazy》Music 报 290.99s，
/// lrclib 上同版本的多个上传是 291.0 / 293.0 / 291.4 / 298.7s。
final class DurationToleranceRealWorldTests: XCTestCase {
    func testSameVersionMetadataVarianceIsNotPenalized() {
        // Music 290.99 vs lrclib 291.0：本质同一录音
        XCTAssertEqual(ArtworkScoring.durationScore(candidate: 291.0, expected: 290.99),
                       ArtworkScoring.durationExactBonus)
    }

    func testFadeInOutVarianceWithinTolerance() {
        // 差 2.9s（淡入淡出/剪辑）在 3s 容差内，不该被罚
        XCTAssertEqual(ArtworkScoring.durationScore(candidate: 293.9, expected: 290.99),
                       ArtworkScoring.durationExactBonus)
    }

    func testToleranceBoundaryIsInclusive() {
        // 恰好 3s 算命中（容差含边界）
        XCTAssertEqual(ArtworkScoring.durationScore(candidate: 293.0, expected: 290.0),
                       ArtworkScoring.durationExactBonus)
    }

    func testLiveVersionStillHeavilyPenalized() {
        // 真正的版本差异（Live 版差 40s+）必须仍被重罚
        let live = ArtworkScoring.durationScore(candidate: 331.6, expected: 290.99)
        XCTAssertEqual(live, ArtworkScoring.durationMismatchPenalty)
    }

    func testModerateVersionDifferenceStillPenalized() {
        // 差 7.7s 仍是版本差异，应落在惩罚档（不是满分）
        let other = ArtworkScoring.durationScore(candidate: 298.7, expected: 290.99)
        XCTAssertLessThan(other, 0)
    }

    func testMissingDurationContributesNothing() {
        // 任何一侧为 0：不参与评分，避免用信息缺失误伤
        XCTAssertEqual(ArtworkScoring.durationScore(candidate: 0, expected: 290), 0)
        XCTAssertEqual(ArtworkScoring.durationScore(candidate: 291, expected: 0), 0)
    }
}
