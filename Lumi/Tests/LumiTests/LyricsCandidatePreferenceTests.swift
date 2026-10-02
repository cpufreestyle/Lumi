import XCTest
@testable import Lumi

/// 歌词候选选择偏好测试（Foundation only）。
///
/// 「有带时间轴的歌词」必须是决定性优势：否则一个只有纯文本、但时长精确
/// 吻合的候选会压过有时间轴却缺 duration 字段的候选 —— 结果是整段歌词
/// 不滚动，正是用户最能直接感知的不同步。
final class LyricsCandidatePreferenceTests: XCTestCase {
    private let lines = [SyncedLine(text: "第一句", time: 0),
                         SyncedLine(text: "第二句", time: 10)]

    /// 复刻 resolveLyrics 的打分与择优逻辑（不含网络解析部分）。
    private func bestCandidate(candidates: [(title: String, artist: String,
                                             album: String, duration: Double,
                                             synced: [SyncedLine], plain: String)])
        -> (hasTimeline: Bool, index: Int)? {
        var best: (score: Int, hasTimeline: Bool, index: Int)?
        for (i, c) in candidates.enumerated() {
            if c.synced.isEmpty, c.plain.isEmpty { continue }
            var score = MusicController.testableMatchScore(
                trackName: c.title, artistName: c.artist,
                albumName: c.album,
                expectTitle: c.title, expectArtist: c.artist,
                expectAlbum: c.album, expectDuration: c.duration)
            if score < 0 { continue }
            score += ArtworkScoring.durationScore(candidate: c.duration, expected: c.duration)
            if !c.synced.isEmpty { score += 200 }
            if best.map({ score > $0.score }) ?? true {
                best = (score, !c.synced.isEmpty, i)
            }
        }
        return best.map { ($0.hasTimeline, $0.index) }
    }

    func testTimelineBeatsPlainTextEvenWithPerfectDuration() {
        let winner = bestCandidate(candidates: [
            (title: "稻香", artist: "周杰伦", album: "魔杰座", duration: 200.0,
             synced: [], plain: "整段纯文本歌词没有时间轴"),
            (title: "稻香", artist: "周杰伦", album: "魔杰座", duration: 0,
             synced: lines, plain: ""),
        ])
        XCTAssertNotNil(winner)
        XCTAssertTrue(winner!.hasTimeline, "有时间轴的候选必须胜出，否则歌词不滚动")
        XCTAssertEqual(winner!.index, 1)
    }

    func testPlainTextWinsWhenNoCandidateHasTimeline() {
        let winner = bestCandidate(candidates: [
            (title: "稻香", artist: "周杰伦", album: "魔杰座", duration: 200.0,
             synced: [], plain: "纯文本 A"),
            (title: "稻香", artist: "周杰伦", album: "魔杰座", duration: 201.0,
             synced: [], plain: "纯文本 B"),
        ])
        XCTAssertNotNil(winner)
        XCTAssertFalse(winner!.hasTimeline)
    }

    func testEmptyCandidatesYieldNil() {
        XCTAssertNil(bestCandidate(candidates: []))
    }

    func testBothEmptyLyricsAreSkipped() {
        let winner = bestCandidate(candidates: [
            (title: "稻香", artist: "周杰伦", album: "魔杰座", duration: 200,
             synced: [], plain: ""),
        ])
        XCTAssertNil(winner)
    }
}
