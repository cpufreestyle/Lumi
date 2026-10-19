import XCTest
@testable import Lumi

/// PluginPanelView.actionURL(按钮回调 URL 构造)的纯逻辑测试。
/// 关键约束：标题里的 `&` 不能被当成 query 分隔符，否则回调内容被静默截断。
final class PluginActionURLTests: XCTestCase {

    /// 从回调 URL 里取出 name 参数（模拟第三方插件的解析方式）。
    private func nameFrom(_ url: URL?) -> String? {
        guard let url = url,
              let comp = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return comp.queryItems?.first(where: { $0.name == "name" })?.value
    }

    func testPlainTitleRoundTrips() {
        let url = PluginPanelView.actionURL(scheme: "lumi-sample", title: "刷新天气")
        XCTAssertEqual(nameFrom(url), "刷新天气")
        XCTAssertEqual(url?.scheme, "lumi-sample")
        XCTAssertEqual(url?.host, "action")
    }

    func testAmpersandInTitleIsNotTruncated() {
        // 回归：A&B 曾因 .urlQueryAllowed 不编码 & 而被截断成 A
        let url = PluginPanelView.actionURL(scheme: "s", title: "A&B")
        XCTAssertEqual(nameFrom(url), "A&B", "& 必须被编码，不能当作参数分隔符")
    }

    func testPercentInTitleRoundTrips() {
        XCTAssertEqual(nameFrom(PluginPanelView.actionURL(scheme: "s", title: "100%")), "100%")
    }

    func testPlusInTitleRoundTrips() {
        XCTAssertEqual(nameFrom(PluginPanelView.actionURL(scheme: "s", title: "a+b")), "a+b")
    }

    func testQuestionMarkAndHashRoundTrip() {
        // ? 与 # 在 URL 里有特殊含义，必须被编码掉
        XCTAssertEqual(nameFrom(PluginPanelView.actionURL(scheme: "s", title: "问号?")), "问号?")
        XCTAssertEqual(nameFrom(PluginPanelView.actionURL(scheme: "s", title: "a#b")), "a#b")
    }

    func testMultiParamSeparatorInTitleRoundTrips() {
        XCTAssertEqual(nameFrom(PluginPanelView.actionURL(scheme: "s", title: "x=1&y=2")), "x=1&y=2")
    }

    // MARK: - 入参保护

    func testNilOrEmptyInputsReturnNil() {
        XCTAssertNil(PluginPanelView.actionURL(scheme: nil, title: "t"))
        XCTAssertNil(PluginPanelView.actionURL(scheme: "", title: "t"))
        XCTAssertNil(PluginPanelView.actionURL(scheme: "s", title: nil))
    }

    func testEmptyTitleStillBuildsURL() {
        // 空标题仍应产出合法 URL（插件侧收到空 name 自行处理）
        let url = PluginPanelView.actionURL(scheme: "s", title: "")
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.host, "action")
    }
}

