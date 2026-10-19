import XCTest
@testable import Lumi

/// PluginPanelEntry / PluginPanelStatus(面板健康状态机)纯逻辑测试。
/// 覆盖本轮加入的错误隔离：区分「无数据 / 数据陈旧 / 解码失败」，
/// 让 UI 能给出可操作的反馈，而不是让面板静默消失。
final class PluginPanelStatusTests: XCTestCase {

    // MARK: - 状态机构建

    private func panel(updatedAt: TimeInterval, id: String = "com.x") -> PluginPanelData {
        PluginPanelData(id: id, title: "T", iconName: "star",
                        subtitle: nil, lines: [], updatedAt: updatedAt)
    }

    func testFreshPanelIsLive() {
        let e = PluginPanelEntry(data: panel(updatedAt: Date().timeIntervalSince1970), status: .live)
        XCTAssertEqual(e.status, .live)
        XCTAssertTrue(e.status.isUsable)
    }

    func testStalePanelKeepsLastData() {
        // 陈旧时保留最后一帧数据：UI 能继续渲染内容，同时提示「可能已退出」
        let old = panel(updatedAt: Date().timeIntervalSince1970 - 120)
        let e = PluginPanelEntry(data: old, status: .stale)
        XCTAssertEqual(e.status, .stale)
        XCTAssertNotNil(e.data, "陈旧不应丢数据")
        XCTAssertFalse(e.status.isUsable)
    }

    func testMalformedCarriesReason() {
        let e = PluginPanelEntry(data: nil, status: .malformed("面板 JSON 解码失败（格式不符）"))
        XCTAssertFalse(e.status.isUsable)
        XCTAssertNil(e.data)
        if case .malformed(let r) = e.status {
            XCTAssertFalse(r.isEmpty, "失败原因必须非空，否则 UI 无从提示")
        } else {
            XCTFail("应为 malformed")
        }
    }

    func testEmptyEntryIsNoData() {
        XCTAssertEqual(PluginPanelEntry.empty.status, .noData)
        XCTAssertNil(PluginPanelEntry.empty.data)
        XCTAssertFalse(PluginPanelEntry.empty.status.isUsable)
    }

    func testStatusEqualityDistinguishesMalformedReasons() {
        // malformed 带关联值，Equatable 必须按原因区分，否则 UI 不会重绘
        XCTAssertNotEqual(PluginPanelStatus.malformed("a"), PluginPanelStatus.malformed("b"))
        XCTAssertEqual(PluginPanelStatus.malformed("a"), PluginPanelStatus.malformed("a"))
    }

    // MARK: - isStale 阈值

    func testIsStaleThreshold() {
        XCTAssertFalse(panel(updatedAt: Date().timeIntervalSince1970).isStale)
        XCTAssertFalse(panel(updatedAt: Date().timeIntervalSince1970 - 29).isStale)
        XCTAssertTrue(panel(updatedAt: Date().timeIntervalSince1970 - 31).isStale)
    }

    // MARK: - entries 字典语义

    func testUnhealthyCountCountsNonLive() {
        // 仅验证计数口径：live 不计，其余都计
        let now = Date().timeIntervalSince1970
        let dict: [String: PluginPanelEntry] = [
            "a": PluginPanelEntry(data: panel(updatedAt: now), status: .live),
            "b": PluginPanelEntry(data: nil, status: .noData),
            "c": PluginPanelEntry(data: nil, status: .malformed("x")),
            "d": PluginPanelEntry(data: panel(updatedAt: now - 999), status: .stale),
        ]
        XCTAssertEqual(dict.values.filter { !$0.status.isUsable }.count, 3)
    }
}

