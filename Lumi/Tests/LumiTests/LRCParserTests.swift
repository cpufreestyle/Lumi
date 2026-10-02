import XCTest
@testable import Lumi

/// LRC 时间戳解析测试（Foundation only）。
///
/// 内嵌歌词与在线 syncedLyrics 都走同一解析器；任何时间换算错误都会让整首歌
/// 与演唱错位，因此把解析规则抽成纯函数并用测试锁住。
final class LRCParserTests: XCTestCase {
    func testParsesMinuteSecondAndCentisecond() {
        let lines = LRCParser.parse("[01:02.50]第一句")
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].time, 62.5, accuracy: 0.001)
        XCTAssertEqual(lines[0].text, "第一句")
    }

    func testParsesThreeDigitMilliseconds() {
        XCTAssertEqual(LRCParser.parse("[00:01.250]A")[0].time, 1.25, accuracy: 0.001)
    }

    func testAppliesGlobalOffset() {
        let lines = LRCParser.parse("[offset:500]\n[00:10.00]A")
        XCTAssertEqual(lines[0].time, 9.5, accuracy: 0.001)
    }

    func testNegativeGlobalOffsetDelaysLyrics() {
        let lines = LRCParser.parse("[offset:-250]\n[00:10.00]A")
        XCTAssertEqual(lines[0].time, 10.25, accuracy: 0.001)
    }

    func testSkipsMetadataAndEmptyLines() {
        let raw = "[ti:测试]\n[by:作者]\n[00:01.00]A\n[00:02.00]"
        XCTAssertEqual(LRCParser.parse(raw).map(\.text), ["A"])
    }

    func testMultipleTimestampsOnOneLineProduceMultipleEntries() {
        let raw = "[00:01.00][00:05.00]副歌"
        XCTAssertEqual(LRCParser.parse(raw).count, 2)
        XCTAssertEqual(LRCParser.parse(raw)[0].time, 1, accuracy: 0.001)
        XCTAssertEqual(LRCParser.parse(raw)[1].time, 5, accuracy: 0.001)
    }

    func testBodyNumbersAreNotTimestamps() {
        let lines = LRCParser.parse("[00:01.00]遇见你是 10:15 的 3.14")
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].time, 1, accuracy: 0.001)
    }
}

// MARK: - [offset:] 端到端符号方向

/// 只断言「offset 值是多少」不够——一旦符号方向被改反，测试可能仍然通过
/// 但歌词整体错位。这里直接验证最终效果：正值让每行提前。
final class LRCOffsetDirectionTests: XCTestCase {
    func testPositiveOffsetAdvancesEveryLine() {
        // `[offset:500]` = 提前 0.5s：每行时间必须比原始值小 0.5
        let advanced = LRCParser.parse("[offset:500]\n[00:10.00]A\n[00:20.00]B")
        XCTAssertEqual(advanced[0].time, 9.5, accuracy: 0.001)
        XCTAssertEqual(advanced[1].time, 19.5, accuracy: 0.001)
    }

    func testNegativeOffsetDelaysEveryLine() {
        // `[offset:-250]` = 延后 0.25s：每行时间必须比原始值大 0.25
        let delayed = LRCParser.parse("[offset:-250]\n[00:10.00]A\n[00:20.00]B")
        XCTAssertEqual(delayed[0].time, 10.25, accuracy: 0.001)
        XCTAssertEqual(delayed[1].time, 20.25, accuracy: 0.001)
    }

    func testOffsetAppearsEarlierWithPositiveValue() {
        // 关键行为验证：加了正 offset 后，同一行在**更早**的播放时刻就该高亮
        let plain = LRCParser.parse("[00:10.00]A")
        let shifted = LRCParser.parse("[offset:500]\n[00:10.00]A")
        XCTAssertLessThan(shifted[0].time, plain[0].time)
    }

    func testZeroOffsetLeavesTimelineUnchanged() {
        let plain = LRCParser.parse("[00:10.00]A\n[00:20.00]B")
        let zeroed = LRCParser.parse("[offset:0]\n[00:10.00]A\n[00:20.00]B")
        XCTAssertEqual(zeroed.map(\.time), plain.map(\.time))
    }
}

// MARK: - 排序稳定性

/// 同一首歌不同次加载必须得到完全一致的行序。相同时间戳的多行
/// （同刻多语言、合唱）若用不稳定排序，相对顺序会乱，
/// 直接破坏「同刻取第一行」的稳定性。
final class LRCParserSortStabilityTests: XCTestCase {
    private func textOrder(_ raw: String) -> [String] {
        LRCParser.parse(raw).map(\.text)
    }

    func testDuplicateTimestampsKeepSourceOrder() {
        // 同刻三行：必须保持原始书写顺序，不能被打乱
        let raw = "[00:10.00]第一\n[00:10.00]第二\n[00:10.00]第三"
        XCTAssertEqual(textOrder(raw), ["第一", "第二", "第三"])
    }

    func testStableAcrossRepeatedParses() {
        let raw = "[00:30.00]C1\n[00:10.00]A\n[00:30.00]C2\n[00:20.00]B\n[00:30.00]C3"
        let first = LRCParser.parse(raw)
        let fingerprint = first.map { "\($0.time):\($0.text)" }.joined(separator: "|")
        for _ in 0..<5 {
            let again = LRCParser.parse(raw)
            let againPrint = again.map { "\($0.time):\($0.text)" }.joined(separator: "|")
            XCTAssertEqual(againPrint, fingerprint, "多次解析结果必须一致")
        }
    }

    func testInterleavedDuplicatesSortByTimeThenSourceOrder() {
        let raw = "[00:20.00]B1\n[00:10.00]A1\n[00:20.00]B2\n[00:10.00]A2"
        let lines = LRCParser.parse(raw)
        XCTAssertEqual(lines.map(\.time), [10, 10, 20, 20])
        XCTAssertEqual(lines.map(\.text), ["A1", "A2", "B1", "B2"])
    }

    func testSameTimestampGroupPicksFirstConsistently() {
        // 与 LyricsTimeline 联动：排序稳定 → 同刻第一行稳定 → 高亮稳定
        let lines = LRCParser.parse("[00:10.00]\u{7121}\u{95DC}1\n[00:10.00]\u{7121}\u{95DC}2")
        let idx = LyricsTimeline.activeLineIndex(
            lines: lines.map { SyncedLine(text: $0.text, time: $0.time) },
            adjustedTime: 12
        )
        XCTAssertEqual(idx, 0)
    }
}

// MARK: - 小数位自适应（厘秒 vs 毫秒）

/// LRC 时间戳小数位数不统一：社区文件有 2 位厘秒（标准）也有 3 位毫秒。
/// 解析必须按位数自适应，否则整首歌偏移几十到几百毫秒。
final class LRCMillisecondPrecisionTests: XCTestCase {
    func testTwoDigitsAreCentiseconds() {
        // 标准 LRC：2 位 = 厘秒，.05 = 0.05s
        XCTAssertEqual(LRCParser.parse("[00:01.05]A")[0].time, 1.05, accuracy: 0.0001)
    }

    func testThreeDigitsAreMilliseconds() {
        // 3 位 = 毫秒，.005 = 0.005s
        XCTAssertEqual(LRCParser.parse("[00:01.005]A")[0].time, 1.005, accuracy: 0.0001)
    }

    func testTwoAndThreeDigitsAgreeOnSameInstant() {
        // .50（厘秒）与 .500（毫秒）应解析到同一时刻
        let centi = LRCParser.parse("[00:01.50]A")[0].time
        let milli = LRCParser.parse("[00:01.500]A")[0].time
        XCTAssertEqual(centi, milli, accuracy: 0.0001)
    }

    func testOneDigitTreatedAsTenths() {
        // 非标准 1 位：按小数位自适应为十分位，.5 = 0.5s
        XCTAssertEqual(LRCParser.parse("[00:01.5]A")[0].time, 1.5, accuracy: 0.0001)
    }

    func testNoFractionIsWholeSecond() {
        XCTAssertEqual(LRCParser.parse("[00:01]A")[0].time, 1, accuracy: 0.0001)
    }

    func testMinutesBeyondSixtyStillAccumulate() {
        // 分钟字段无上限保护，必须按 min*60+sec 累加（长现场版常见）
        XCTAssertEqual(LRCParser.parse("[99:59.00]A")[0].time, 5999, accuracy: 0.0001)
    }
}

// MARK: - 浮点组装精度

/// 行时间 = 整数秒 + 小数 - 全局偏移。串行浮点运算在大量行上会累积尾差，
/// 尾差足以让相邻行的高亮边界抖动（用户听不出、但能看到歌词偶发抖动）。
final class LRCParserFloatPrecisionTests: XCTestCase {
    func testTypicalTimestampsAreExact() {
        // 常见值必须精确相等，而不是差一个 ULP
        let t = LRCParser.parse("[00:10.30]A")[0].time
        XCTAssertEqual(t, 10.3, accuracy: 0)
    }

    func testLongTrackTimestampsStayExact() {
        // 长时间戳（分钟数大）下整数部分与小数部分不串行累加
        let t = LRCParser.parse("[15:07.20]A")[0].time
        XCTAssertEqual(t, 907.2, accuracy: 0)
    }

    func testOffsetAppliedWithoutFloatDrift() {
        // 带 offset 时同样要精确
        let t = LRCParser.parse("[offset:250]\n[00:10.00]A")[0].time
        XCTAssertEqual(t, 9.75, accuracy: 0)
    }

    func testHundredsOfLinesRemainConsistent() {
        // 大量行：每一行都应与「整数 + 小数」的精确值一致
        var raw = ""
        let count = 300
        for i in 0..<count {
            raw += String(format: "[%02d:%02d.%02d]L%d\n", i / 60, i % 60, (i * 7) % 100, i)
        }
        let lines = LRCParser.parse(raw)
        XCTAssertEqual(lines.count, count)
        for (i, line) in lines.enumerated() {
            let expected = Double((i / 60) * 60 + (i % 60))
                + Double((i * 7) % 100) / 100.0
            XCTAssertEqual(line.time, expected, accuracy: 0,
                           "第 \(i) 行 t=\(line.time) expected=\(expected)")
        }
    }

    func testMonotonicIncreasingAfterParse() {
        // 浮点尾差不得破坏递增性（否则二分查找会选错行）
        let raw = (0..<200).map { String(format: "[00:%02d.%02d]L%d", $0 / 2, ($0 * 13) % 100, $0) }
            .joined(separator: "\n")
        let lines = LRCParser.parse(raw)
        for i in 1..<lines.count {
            XCTAssertGreaterThanOrEqual(lines[i].time, lines[i - 1].time)
        }
    }
}
