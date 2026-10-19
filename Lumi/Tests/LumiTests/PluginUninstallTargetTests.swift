import XCTest
@testable import Lumi

/// PluginMarketplace.uninstallTarget 的卸载边界测试。
/// 核心约束：宿主只能删自己装进 Plugins/ 的副本，
/// /Applications 里的同名 app 是用户自己放的，删它属于越权。
final class PluginUninstallTargetTests: XCTestCase {

    private func manifest(id: String, appName: String?, bundlePath: String?) -> PluginManifest {
        PluginManifest(id: id, name: id, appName: appName, bundlePath: bundlePath)
    }

    // MARK: - Plugins/ 内的副本：允许删除

    func testTargetInsidePluginsDirIsAllowed() {
        let inside = PluginMarketplace.pluginsDirURL
            .appendingPathComponent("Foo.app").path
        let m = manifest(id: "com.x", appName: "Foo.app", bundlePath: inside)
        let target = PluginMarketplace.uninstallTarget(for: m)
        XCTAssertNotNil(target, "Plugins/ 内的副本必须允许卸载")
        XCTAssertEqual(target?.lastPathComponent, "Foo.app")
    }

    // MARK: - Plugins/ 之外：一律拒绝

    func testTargetInApplicationsIsRefused() {
        // /Applications 里的 app 是用户自己放的，宿主无权删
        let outside = "/Applications/Foo.app"
        let m = manifest(id: "com.x", appName: "Foo.app", bundlePath: outside)
        XCTAssertNil(PluginMarketplace.uninstallTarget(for: m),
                    "Plugins/ 之外的路径必须拒绝卸载")
    }

    func testTargetInHomeApplicationsIsRefused() {
        let outside = NSHomeDirectory() + "/Applications/Foo.app"
        let m = manifest(id: "com.x", appName: "Foo.app", bundlePath: outside)
        XCTAssertNil(PluginMarketplace.uninstallTarget(for: m))
    }

    func testTargetOutsideIsRefusedEvenWhenPathLooksSimilar() {
        // 前缀近似但不等于安装目录（少一级），不能误判为「在目录内」
        let base = PluginMarketplace.pluginsDirURL.path
        let sibling = base + "-evil/Foo.app"
        let m = manifest(id: "com.x", appName: "Foo.app", bundlePath: sibling)
        XCTAssertNil(PluginMarketplace.uninstallTarget(for: m),
                    "前缀近似路径必须拒绝")
    }

    // MARK: - bundlePath 缺失时的回退

    func testMissingBundlePathFallsBackToNil() {
        // 没有 bundlePath 且目录里没有对应 appName 时返回 nil（由 UI 给出解释）
        let m = manifest(id: "com.x", appName: "DefinitelyNotInstalled.app", bundlePath: nil)
        XCTAssertNil(PluginMarketplace.uninstallTarget(for: m))
    }

    func testMissingBundlePathAndAppNameIsNil() {
        let m = manifest(id: "com.x", appName: nil, bundlePath: nil)
        XCTAssertNil(PluginMarketplace.uninstallTarget(for: m))
    }

    // MARK: - 安装目录本身

    func testPluginsDirURLIsUnderApplicationSupport() {
        XCTAssertTrue(PluginMarketplace.pluginsDirURL.path.hasSuffix("Lumi/Plugins"))
    }
}

