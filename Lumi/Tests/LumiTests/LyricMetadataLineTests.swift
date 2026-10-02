import XCTest
@testable import Lumi

/// LRC 制作信息行识别测试（Foundation only）。
final class LyricMetadataLineTests: XCTestCase {

    // MARK: - 必须过滤

    func testChineseLabelsFiltered() {
        XCTAssertTrue(LyricMetadataLine.isMetadata("作词：张三"))
        XCTAssertTrue(LyricMetadataLine.isMetadata("混音：李四"))
        XCTAssertTrue(LyricMetadataLine.isMetadata("编曲: 王五"))
    }

    func testEnglishLabelsFiltered() {
        XCTAssertTrue(LyricMetadataLine.isMetadata("Written by: John Lennon"))
        XCTAssertTrue(LyricMetadataLine.isMetadata("Composer: Paul McCartney"))
        XCTAssertTrue(LyricMetadataLine.isMetadata("Producer: George Martin"))
        XCTAssertTrue(LyricMetadataLine.isMetadata("Lyrics by: Bob Dylan"))
    }

    func testLRCTagsFiltered() {
        XCTAssertTrue(LyricMetadataLine.isMetadata("[by:署名]"))
        XCTAssertTrue(LyricMetadataLine.isMetadata("[ti:标题]"))
        XCTAssertTrue(LyricMetadataLine.isMetadata("[offset:500]"))
    }

    func testLowercaseEnglishLabelsFiltered() {
        XCTAssertTrue(LyricMetadataLine.isMetadata("producer: someone"))
    }

    // MARK: - 必须保留（不能误伤歌词）

    func testNormalLyricLinesKept() {
        XCTAssertFalse(LyricMetadataLine.isMetadata("他说：你好吗"))
        XCTAssertFalse(LyricMetadataLine.isMetadata("妈妈：回家吃饭了"))
        XCTAssertFalse(LyricMetadataLine.isMetadata("CD机：播这首歌"))
    }

    func testPlainLyricsWithoutColonKept() {
        XCTAssertFalse(LyricMetadataLine.isMetadata("我怀念的 是一条河"))
        XCTAssertFalse(LyricMetadataLine.isMetadata("Hello world"))
    }

    func testEmptyAndWhitespace() {
        XCTAssertFalse(LyricMetadataLine.isMetadata(""))
        XCTAssertFalse(LyricMetadataLine.isMetadata("   "))
    }

    func testColonOnlyIsNotMetadata() {
        XCTAssertFalse(LyricMetadataLine.isMetadata("：你好"))
    }

    func testColonAtStartKeepsLine() {
        // 行首即冒号：没有标签段，属正常内容
        XCTAssertFalse(LyricMetadataLine.isMetadata(":something"))
    }

    // MARK: - 网易云曲末追加的完整制作名单

    /// 实测《如初之光》/ 莫文蔚（网易云 id=531040038）的 LRC 曲末有 11 行制作名单，
    /// 其中「和声编写」「混音室」两个标签原表里没有，漏掉会作为歌词行高亮 ——
    /// 用户看到「和声编写」被当成正在唱的一句，就是「歌词和歌声对不上」的一种形态。
    func testNeteaseCreditsAtTrackEndAreFiltered() {
        let credits = [
            "作词 : 姚谦",
            "作曲 : 李偲菘",
            "编曲 : Terence Teo",
            "制作人 : 李偲菘",
            "弦乐 : 国际首席爱乐乐团",
            "和声编写 : Lisa Djaati",
            "和声 : Lisa Djaati",
            "录音师 : 李杨",
            "录音室 : 55Tec Studio (北京)",
            "混音师 : Leonard Fong",
            "混音室 : Horus Studio (Singapore)",
        ]
        for line in credits {
            XCTAssertTrue(LyricMetadataLine.isMetadata(line), "漏掉了制作名单行：\(line)")
        }
    }

    /// 同期的真实歌词行必须**不**被过滤：名单标签不能扩到把歌词也吞掉。
    func testRealLyricsOfSameTrackAreKept() {
        let lyrics = [
            "点燃过 就会有过光的闪烁",
            "温暖过 每个昨天心中的我",
            "时间花园 还有很多等待和发现",
            "生如夏花 静如秋叶 如初",
            "微微传递眼眸",
            "推开四面孤单",
        ]
        for line in lyrics {
            XCTAssertFalse(LyricMetadataLine.isMetadata(line), "误把歌词当制作信息：\(line)")
        }

        // 歌词里出现冒号时，前段是完整句子（超过 20 字或不在标签表里），必须保留。
        XCTAssertFalse(LyricMetadataLine.isMetadata("他说：你好吗"))
    }
}
