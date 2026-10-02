import XCTest
@testable import Lumi

/// 歌词时间轴的关键不变量（Foundation only）。
///
/// 这些是「歌词和歌声一致」的底线性质：一旦被破坏，用户立刻能看出问题。
/// 逐轮修复都收尾到这几个函数上，用测试把它们钉住。
final class LyricsTimelineInvariantsTests: XCTestCase {

    // MARK: - 单调性

    func testActiveLineNeverMovesBackwardOnAdvancingTime() {
        // 播放中 adjustedTime 只会前进（补间锚点单调外推），
        // 对应的高亮行也必须单调不减 —— 否则就是歌词回跳。
        var lines: [SyncedLine] = []
        for i in 0..<60 {
            lines.append(SyncedLine(text: "L\\(i)", time: Double(i) * 2))
        }
        var previous = -1
        var t = 0.0
        while t <= 130 {
            let idx = LyricsTimeline.activeLineIndex(lines: lines, adjustedTime: t) ?? -1
            XCTAssertGreaterThanOrEqual(idx, previous,
                                        "t=\\(t) 高亮行 \\(idx) 回退到 \\(previous) 之前")
            previous = idx
            t += 0.25   // 与补间节拍同频
        }
    }

    // MARK: - 行切换时刻

    func testSwitchHappensExactlyAtLineStart() {
        // 到达行起点那一刻必须切换：早一拍晚一拍都能听出来
        let lines = [SyncedLine(text: "A", time: 0),
                     SyncedLine(text: "B", time: 10)]
        XCTAssertEqual(LyricsTimeline.activeLineIndex(lines: lines, adjustedTime: 9.999), 0)
        XCTAssertEqual(LyricsTimeline.activeLineIndex(lines: lines, adjustedTime: 10.0), 1)
    }

    // MARK: - 防抖不破坏单调性

    func testDebounceKeepsMonotonicOnAdvancing() {
        var lines: [SyncedLine] = []
        for i in 0..<40 {
            lines.append(SyncedLine(text: "L\\(i)", time: Double(i) * 3))
        }
        var prev: Int?
        var previous = -1
        var t = 0.0
        while t <= 120 {
            let raw = LyricsTimeline.activeLineIndex(lines: lines, adjustedTime: t)
            let settled = LyricsTimeline.debouncedLineIndex(raw: raw, prev: prev,
                                                            lines: lines, adjustedTime: t)
            prev = settled
            XCTAssertGreaterThanOrEqual(settled ?? -1, previous,
                                        "t=\\(t) 防抖后 \\(String(describing: settled)) 回退")
            previous = settled ?? -1
            t += 0.25
        }
    }

    // MARK: - 偏移符号

    func testOffsetShiftsSelectionLateward() {
        // 正值 offset 让匹配基准后移：同一 currentTime 下选到更早的行
        // （歌词时间轴比播放慢，需要往后推才对齐）
        let lines = [SyncedLine(text: "A", time: 0),
                     SyncedLine(text: "B", time: 10),
                     SyncedLine(text: "C", time: 20)]
        let current: TimeInterval = 15
        // offset=0：adjustedTime=15，最后一行 time<=15 是 B(time=10) -> 索引 1
        let noOffset = LyricsTimeline.activeLineIndex(lines: lines,
                                                      adjustedTime: current)
        // offset=5：adjustedTime=10，B(time=10) 仍命中 -> 索引 1；
        // 但 offset=6 时 adjustedTime=9，只能命中 A(time=0) -> 索引 0。
        let withOffset = LyricsTimeline.activeLineIndex(lines: lines,
                                                        adjustedTime: current - 6)
        XCTAssertEqual(noOffset, 1)
        XCTAssertEqual(withOffset, 0)
        XCTAssertLessThan(withOffset!, noOffset!)
    }
}
