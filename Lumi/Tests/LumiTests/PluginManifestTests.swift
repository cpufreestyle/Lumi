import XCTest
@testable import Lumi

/// PluginManifest(插件清单)纯逻辑测试:语义化版本比较、宽松解码、展示回退。
final class PluginManifestTests: XCTestCase {

    // MARK: - 版本比较(市场「可更新」判断的核心)

    func testVersionComparisonNumericNotLexicographic() {
        // 逐段按数字比较:1.10.0 > 1.9.0(字符串比较会得出相反的错误结论)
        XCTAssertTrue(PluginManifest.isVersion("1.10.0", newerThan: "1.9.0"))
        XCTAssertTrue(PluginManifest.isVersion("1.2.0", newerThan: "1.1.9"))
        XCTAssertTrue(PluginManifest.isVersion("2.0.0", newerThan: "1.99.99"))
    }

    func testVersionComparisonEqualAndOlder() {
        XCTAssertFalse(PluginManifest.isVersion("1.1.9", newerThan: "1.1.9"))
        XCTAssertFalse(PluginManifest.isVersion("1.1.9", newerThan: "1.1.10"))
        XCTAssertFalse(PluginManifest.isVersion("2.0.0", newerThan: "2.0.1"))
    }

    func testVersionComparisonDifferentSegmentCounts() {
        // 缺段按 0 补齐:1.1 与 1.1.0 等价
        XCTAssertFalse(PluginManifest.isVersion("1.1", newerThan: "1.1.0"))
        XCTAssertTrue(PluginManifest.isVersion("1.1.1", newerThan: "1.1"))
    }

    func testVersionComparisonUnparseableIsConservative() {
        // 无法解析时返回 false,不误报更新
        XCTAssertFalse(PluginManifest.isVersion("abc", newerThan: "1.0.0"))
        XCTAssertFalse(PluginManifest.isVersion("1.0.0", newerThan: "abc"))
        XCTAssertFalse(PluginManifest.isVersion("", newerThan: "1.0.0"))
    }

    // MARK: - 宽松解码(第三方清单质量参差,缺字段不能崩)

    func testDecodingMinimalJSONDefaults() throws {
        let data = Data(#"{"id": "com.example.min"}"#.utf8)
        let m = try JSONDecoder().decode(PluginManifest.self, from: data)
        XCTAssertEqual(m.id, "com.example.min")
        XCTAssertEqual(m.name, "", "缺 name 应回退空串")
        XCTAssertFalse(m.panel, "缺 panel 应默认 false")
        XCTAssertNil(m.version)
        XCTAssertNil(m.permissions)
    }

    func testDecodingFullJSONRoundTrip() throws {
        let json = """
        {"id": "com.example.x", "name": "示例", "iconName": "star",
         "urlScheme": "example", "appName": "Example.app",
         "panel": true, "version": "1.2.0", "category": "工具", "summary": "简介"}
        """
        let m = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        XCTAssertEqual(m.name, "示例")
        XCTAssertTrue(m.panel)
        XCTAssertEqual(m.version, "1.2.0")
        XCTAssertTrue(m.canLaunchByScheme)
    }

    // MARK: - 展示回退

    func testResolvedNameFallbackChain() {
        // name 非空 → 用 name;name 空 → appName;再空 → id
        XCTAssertEqual(PluginManifest(id: "a.b.c", name: "N").resolvedName, "N")
        XCTAssertEqual(PluginManifest(id: "a.b.c", name: "", appName: "X.app").resolvedName, "X.app")
        XCTAssertEqual(PluginManifest(id: "a.b.c", name: "").resolvedName, "a.b.c")
    }

    func testResolvedIconNameDefault() {
        XCTAssertEqual(PluginManifest(id: "a", name: "").resolvedIconName, "puzzlepiece")
        XCTAssertEqual(PluginManifest(id: "a", name: "", iconName: "star.fill").resolvedIconName, "star.fill")
    }

    func testCanLaunchByScheme() {
        XCTAssertFalse(PluginManifest(id: "a", name: "").canLaunchByScheme, "无 scheme 不可唤起")
        XCTAssertFalse(PluginManifest(id: "a", name: "", urlScheme: "").canLaunchByScheme, "空 scheme 不可唤起")
        XCTAssertTrue(PluginManifest(id: "a", name: "", urlScheme: "bartender").canLaunchByScheme)
    }
}
