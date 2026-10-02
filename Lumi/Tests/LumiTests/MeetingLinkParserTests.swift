import XCTest
import Foundation
@testable import Lumi

/// 会议链接解析的纯逻辑测试（无 EventKit/AppKit 依赖）。
final class MeetingLinkParserTests: XCTestCase {

    // MARK: - 各商家识别

    func testZoomWebLinks() {
        for text in [
            "https://zoom.us/j/123456789?pwd=abc",
            "https://us02web.zoom.us/j/987654321",
            "https://zoomgov.com/j/111",
            "https://company.zoom.com.cn/j/222",
        ] {
            let link = MeetingLinkParser.firstMeetingLink(in: text)
            XCTAssertEqual(link?.kind, .zoom, text)
        }
    }

    func testZoomSchemeLink() {
        let link = MeetingLinkParser.firstMeetingLink(in: "zoommtg://zoom.us/join?confno=123&pwd=xyz")
        XCTAssertEqual(link?.kind, .zoom)
        XCTAssertEqual(link?.url.scheme, "zoommtg")
    }

    func testTeamsLinks() {
        XCTAssertEqual(
            MeetingLinkParser.firstMeetingLink(in: "https://teams.microsoft.com/l/meetup-join/19%3Aabc")?.kind,
            .teams
        )
        XCTAssertEqual(
            MeetingLinkParser.firstMeetingLink(in: "msteams://teams.microsoft.com/l/meetup-join/x")?.kind,
            .teams
        )
    }

    func testTencentMeeting() {
        let link = MeetingLinkParser.firstMeetingLink(in: " https://meeting.tencent.com/dm/abcDEF123 ")
        XCTAssertEqual(link?.kind, .tencent)
    }

    func testGoogleMeet() {
        XCTAssertEqual(
            MeetingLinkParser.firstMeetingLink(in: "https://meet.google.com/abc-defg-hij")?.kind,
            .googleMeet
        )
    }

    func testWebexAndFeishu() {
        XCTAssertEqual(
            MeetingLinkParser.firstMeetingLink(in: "https://company.webex.com/company/j.php?MTID=x")?.kind,
            .webex
        )
        XCTAssertEqual(
            MeetingLinkParser.firstMeetingLink(in: "https://vc.feishu.cn/j/123456789")?.kind,
            .feishu
        )
    }

    // MARK: - 负例

    func testNonMeetingLinksRejected() {
        for text in [
            "https://jira.company.com/browse/LUMI-123",
            "https://docs.google.com/document/d/abc",
            "https://example.com",
            "notaurl",
            "ftp://zoom.us/should-not-match-ftp",
        ] {
            XCTAssertNil(MeetingLinkParser.firstMeetingLink(in: text), text)
        }
    }

    func testEmptyAndNilInputs() {
        XCTAssertNil(MeetingLinkParser.firstMeetingLink(in: nil))
        XCTAssertNil(MeetingLinkParser.firstMeetingLink(in: ""))
        XCTAssertNil(MeetingLinkParser.firstMeetingLink(in: "   \n  "))
    }

    // MARK: - 混合文本与字段优先级

    func testMeetingLinkInsideNotesText() {
        let notes = "议题：Q3 复盘\n请先看文档 https://docs.google.com/document/d/abc\n会议入口：https://zoom.us/j/555?pwd=zzz"
        let link = MeetingLinkParser.firstMeetingLink(in: notes)
        XCTAssertEqual(link?.kind, .zoom)
        XCTAssertEqual(link?.url.absoluteString, "https://zoom.us/j/555?pwd=zzz")
    }

    func testFieldPriorityURLBeatsNotes() {
        // url 字段优先于备注：备注里的非会议文档链接不应抢跑
        let link = MeetingLinkParser.extract(
            urlText: "https://teams.microsoft.com/l/meetup-join/19%3Aabc",
            notes: "参考资料 https://docs.google.com/document/d/abc",
            location: nil,
            title: nil
        )
        XCTAssertEqual(link?.kind, .teams)
    }

    func testLocationFieldFallback() {
        let link = MeetingLinkParser.extract(
            urlText: nil,
            notes: nil,
            location: "腾讯会议 https://meeting.tencent.com/dm/abcDEF123",
            title: nil
        )
        XCTAssertEqual(link?.kind, .tencent)
    }

    func testNoMeetingAnywhere() {
        XCTAssertNil(
            MeetingLinkParser.extract(
                urlText: "https://example.com",
                notes: "周日见",
                location: "会议室 A",
                title: "周会"
            )
        )
    }

    // MARK: - 大小写与子域名

    func testHostIsCaseInsensitive() {
        let link = MeetingLinkParser.firstMeetingLink(in: "HTTPS://US02WEB.ZOOM.US/j/123")
        XCTAssertEqual(link?.kind, .zoom)
    }

    func testPrefixImpostorRejected() {
        // host 必须是整串相等或真子域名：notzoom.us 不得命中 zoom.us 规则
        XCTAssertNil(MeetingLinkParser.firstMeetingLink(in: "https://notzoom.us/j/1"))
        XCTAssertNil(MeetingLinkParser.firstMeetingLink(in: "https://zoom.us.evil.com/j/1"))
    }
}
