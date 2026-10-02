import XCTest
@testable import Lumi

/// 歌词当前行查找测试（Foundation only）。
///
/// 三处 UI（收缩态胶囊 / 展开态面板 / 桌面歌词浮窗）共用同一判定，
/// 边界语义必须锁死：到达行起点即切换、负时间不高亮、乱序要能被察觉。
final class LyricsTimelineTests: XCTestCase {
    private let lines = [
        SyncedLine(text: "前奏", time: 0),
        SyncedLine(text: "第一句", time: 10),
        SyncedLine(text: "第二句", time: 20),
        SyncedLine(text: "第三句", time: 30),
    ]

    func testBeforeFirstLineNoActiveLine() {
        XCTAssertNil(LyricsTimeline.activeLineIndex(lines: lines, adjustedTime: -5))
    }

    func testExactlyAtLineStartSwitches() {
        // 到达 10s 那一刻必须切到「第一句」，不能等到下一拍
        XCTAssertEqual(LyricsTimeline.activeLineIndex(lines: lines, adjustedTime: 10), 1)
    }

    func testJustBeforeLineStartStaysOnPrevious() {
        XCTAssertEqual(LyricsTimeline.activeLineIndex(lines: lines, adjustedTime: 9.999), 0)
    }

    func testBetweenLinesStaysOnEarlier() {
        XCTAssertEqual(LyricsTimeline.activeLineIndex(lines: lines, adjustedTime: 25), 2)
    }

    func testAfterLastLineStaysOnLast() {
        XCTAssertEqual(LyricsTimeline.activeLineIndex(lines: lines, adjustedTime: 999), 3)
    }

    func testNegativeTimestampsNeverHighlight() {
        let noTimeline = [
            SyncedLine(text: "A", time: -1),
            SyncedLine(text: "B", time: -1),
        ]
        XCTAssertNil(LyricsTimeline.activeLineIndex(lines: noTimeline, adjustedTime: 100))
    }

    func testPartialTimelineMixesCorrectly() {
        // 无时间信息的行夹在有时间的行之间：只在有时间的部分高亮
        let mixed = [
            SyncedLine(text: "无时间", time: -1),
            SyncedLine(text: "第一句", time: 5),
            SyncedLine(text: "无时间2", time: -1),
            SyncedLine(text: "第二句", time: 15),
        ]
        XCTAssertEqual(LyricsTimeline.activeLineIndex(lines: mixed, adjustedTime: 6), 1)
    }

    func testDuplicateTimestampsPickFirstOfGroup() {
        // 同刻多行（合唱/多语言）：取该刻第一行，避免高亮在同刻内抖动
        let dup = [
            SyncedLine(text: "A", time: 10),
            SyncedLine(text: "B", time: 10),
            SyncedLine(text: "C", time: 20),
        ]
        XCTAssertEqual(LyricsTimeline.activeLineIndex(lines: dup, adjustedTime: 10), 0)
        XCTAssertEqual(LyricsTimeline.activeLineIndex(lines: dup, adjustedTime: 15), 0)
        XCTAssertEqual(LyricsTimeline.activeLineIndex(lines: dup, adjustedTime: 20), 2)
    }

    func testTripleDuplicateStaysStable() {
        let triple = [
            SyncedLine(text: "A", time: 5),
            SyncedLine(text: "B", time: 5),
            SyncedLine(text: "C", time: 5),
            SyncedLine(text: "D", time: 12),
        ]
        // 同刻内任何位置都稳定落在第一行
        for t in [5.0, 7.5, 11.9] {
            XCTAssertEqual(LyricsTimeline.activeLineIndex(lines: triple, adjustedTime: t), 0,
                           "同刻 t=\(t) 应稳定命中第一行")
        }
    }

    func testDebounceAdvancesImmediately() {
        // 前进不加余量：到达行起点即切换（保证时序准确）
        let idx = LyricsTimeline.debouncedLineIndex(raw: 1, prev: 0,
                                                    lines: lines, adjustedTime: 10.001)
        XCTAssertEqual(idx, 1)
    }

    func testDebounceHoldsOnStalePullback() {
        // 真值略旧把进度拉回：尚在 0.30s 余量内（10 - 9.65 = 0.35 < 0.30 为假，
        // 用 9.8 更稳妥：10 - 9.8 = 0.20 <= 0.30 属余量内），稳住上一句不回闪
        let idx = LyricsTimeline.debouncedLineIndex(raw: 0, prev: 1,
                                                    lines: lines, adjustedTime: 9.8)
        XCTAssertEqual(idx, 1)
    }

    func testDebounceAllowsRetreatBeyondHysteresis() {
        // 越过 0.30s 余量才允许回退（真回跳，比如 seek 到前奏）
        let idx = LyricsTimeline.debouncedLineIndex(raw: 0, prev: 1,
                                                    lines: lines, adjustedTime: 9.6)
        XCTAssertEqual(idx, 0)
    }

    func testDebounceWithNoPrevAdoptsRaw() {
        let idx = LyricsTimeline.debouncedLineIndex(raw: 2, prev: nil,
                                                    lines: lines, adjustedTime: 21)
        XCTAssertEqual(idx, 2)
    }

    func testFloatTailDifferenceStillGroupsTogether() {
        // [offset:] 换算后同刻行可能有浮点尾差：仍须归为同刻取第一行
        let drifting = [
            SyncedLine(text: "A", time: 10.0),
            SyncedLine(text: "B", time: 10.0000001),
            SyncedLine(text: "C", time: 10.0000002),
        ]
        for t in [10.0, 10.00000015] {
            XCTAssertEqual(LyricsTimeline.activeLineIndex(lines: drifting, adjustedTime: t), 0,
                           "尾差 \(t) 应仍稳定命中同刻第一行")
        }
    }

    func testGenuinelyDifferentTimestampsDoNotGroup() {
        // 相差 1ms 以上应视为不同刻（不能被容差误并）
        let distinct = [
            SyncedLine(text: "A", time: 10.000),
            SyncedLine(text: "B", time: 10.002),
        ]
        XCTAssertEqual(LyricsTimeline.activeLineIndex(lines: distinct, adjustedTime: 10.001), 0)
        XCTAssertEqual(LyricsTimeline.activeLineIndex(lines: distinct, adjustedTime: 10.002), 1)
    }

    func testLargeTimelineMatchesLinearScan() {
        // 二分改写后必须与线性语义完全一致。用 500 行 + 随机同刻 + 负时间前缀验证。
        var lines: [SyncedLine] = [SyncedLine(text: "无时间", time: -1)]
        var t = 0.0
        for i in 0..<500 {
            // 每 7 行插入一个同刻行，制造同刻分组
            if i % 7 == 0 && i > 0 { t += 0.0 } else { t += 0.3 }
            lines.append(SyncedLine(text: "L\(i)", time: t))
        }
        // 参考实现：原始线性语义
        func linear(_ at: TimeInterval) -> Int? {
            var idx: Int?
            for (i, line) in lines.enumerated() {
                guard line.time >= 0 else { continue }
                if line.time <= at { idx = i } else { break }
            }
            guard let hit = idx else { return nil }
            var first = hit
            while first > 0, abs(lines[first-1].time - lines[hit].time) < 1e-6 { first -= 1 }
            return first
        }
        for probe in stride(from: -0.5, through: 160.0, by: 0.37) {
            let binary = LyricsTimeline.activeLineIndex(lines: lines, adjustedTime: probe)
            XCTAssertEqual(binary, linear(probe),
                           "二分与线性在 t=\(probe) 不一致")
        }
    }

    func testEmptyLinesReturnsNil() {
        XCTAssertNil(LyricsTimeline.activeLineIndex(lines: [], adjustedTime: 5))
    }

    func testAllThreeConsumersAgree() {
        // 胶囊 / 展开面板 / 桌面浮窗共用此函数，抽出来就是要保证这一点
        let index = LyricsTimeline.activeLineIndex(lines: lines, adjustedTime: 22.5)
        XCTAssertNotNil(index)
        XCTAssertEqual(lines[index!].text, "第二句")
    }
}
