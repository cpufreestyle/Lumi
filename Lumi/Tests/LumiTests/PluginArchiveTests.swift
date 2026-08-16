import XCTest
@testable import Lumi

/// PluginArchive（市场安装包 .app 定位与坏包自愈）的纯逻辑测试。
/// 仅依赖 Foundation，可在无 GUI 会话的 `swift test` 下运行。
final class PluginArchiveTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugin_archive_tests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    /// 造一个最小 .app 目录（含 Resources/lumi-plugin.json）
    private func makeApp(_ name: String, in dir: URL,
                         manifestID: String = "com.example.test") throws -> URL {
        let app = dir.appendingPathComponent(name)
        let res = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: res, withIntermediateDirectories: true)
        try """
        { "id": "\(manifestID)", "name": "T", "panel": false }
        """.write(to: res.appendingPathComponent("lumi-plugin.json"),
                  atomically: true, encoding: .utf8)
        return app
    }

    // MARK: - 标准布局

    func testLocatesTopLevelApp() throws {
        let app = try makeApp("Foo.app", in: workDir)
        try "junk".write(to: workDir.appendingPathComponent("plugin.zip"),
                         atomically: true, encoding: .utf8)
        let found = try PluginArchive.locateOrWrapApp(in: workDir)
        XCTAssertEqual(found.standardizedFileURL, app.standardizedFileURL)
    }

    // MARK: - 坏包：zip 根为 Contents/（丢 .app 外壳）

    func testWrapsBareContentsDirWithFallbackName() throws {
        // 还原历史坏包：顶层直接是 Contents/
        let contents = workDir.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try """
        { "id": "com.lumi.sample-plugin", "name": "示例插件", "panel": false }
        """.write(to: contents.appendingPathComponent("lumi-plugin.json"),
                  atomically: true, encoding: .utf8)

        let found = try PluginArchive.locateOrWrapApp(
            in: workDir, fallbackAppName: "LumiSamplePlugin.app")
        XCTAssertEqual(found.lastPathComponent, "LumiSamplePlugin.app")
        // Contents 被移入外壳内，清单可读（后续发现流程依赖）
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: found.appendingPathComponent("Contents/Resources/lumi-plugin.json").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: workDir.appendingPathComponent("LumiSamplePlugin.app/Contents").path))
    }

    func testWrapsBareContentsDirWithDefaultNameWhenNoFallback() throws {
        let contents = workDir.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let found = try PluginArchive.locateOrWrapApp(in: workDir)
        XCTAssertEqual(found.lastPathComponent, "Plugin.app")
    }

    // MARK: - 嵌套布局

    func testDigsIntoSingleWrapperDirectory() throws {
        let inner = workDir.appendingPathComponent("Payload")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let app = try makeApp("Nested.app", in: inner)
        let found = try PluginArchive.locateOrWrapApp(in: workDir)
        XCTAssertEqual(found.standardizedFileURL, app.standardizedFileURL)
    }

    // MARK: - 失败路径

    func testThrowsWhenNoAppAnywhere() throws {
        try "readme.txt".write(to: workDir.appendingPathComponent("readme.txt"),
                               atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try PluginArchive.locateOrWrapApp(in: workDir)) { error in
            guard case PluginArchive.ArchiveError.noAppFound = error else {
                return XCTFail("应抛 noAppFound，实际：\(error)")
            }
        }
    }
}
