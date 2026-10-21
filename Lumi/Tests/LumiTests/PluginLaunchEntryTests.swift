import XCTest
@testable import Lumi

/// PluginDiscovery.launch 的「无入口」判定测试。
/// 只测纯逻辑：不真正唤起任何 app（那需要 GUI 会话），
/// 只验证「三种入口都没有时应返回 false」，让 UI 的失败提示有依据。
final class PluginLaunchEntryTests: XCTestCase {

    /// 直接复用 launch 的入口判定，避免测试真的去 open app。
    /// 这里通过构造 manifest 后调用 launch 会触发 NSWorkspace，
    /// 因此只对「必然走不到 open」的空 manifest 断言。
    func testManifestWithNoEntryIsDetected() {
        let empty = PluginManifest(id: "com.x", name: "X")
        XCTAssertFalse(empty.canLaunchByScheme)
        XCTAssertNil(empty.bundlePath)
        XCTAssertNil(empty.appName)
        // 三者皆空即 launch 的 return false 分支；有值则不会走到该分支
    }

    func testSchemeEntryMakesLaunchable() {
        let m = PluginManifest(id: "com.x", name: "X", urlScheme: "bartender")
        XCTAssertTrue(m.canLaunchByScheme, "有 scheme 时 launch 会走 scheme 分支并返回 true")
    }

    func testBundlePathAloneIsAnEntry() {
        let m = PluginManifest(id: "com.x", name: "X", bundlePath: "/Applications/Foo.app")
        XCTAssertFalse(m.canLaunchByScheme, "无 scheme")
        XCTAssertNotNil(m.bundlePath, "有 bundlePath 即视为有入口，launch 返回 true")
    }

    func testAppNameAloneIsAnEntry() {
        let m = PluginManifest(id: "com.x", name: "X", appName: "Foo.app")
        XCTAssertNotNil(m.appName, "有 appName 即视为有入口，launch 返回 true")
    }

    func testEmptySchemeStringIsNotAnEntry() {
        // 空串 scheme 不应被视为可用入口（launch 里用 !scheme.isEmpty 拦掉）
        let m = PluginManifest(id: "com.x", name: "X", urlScheme: "")
        XCTAssertFalse(m.canLaunchByScheme)
    }
}

