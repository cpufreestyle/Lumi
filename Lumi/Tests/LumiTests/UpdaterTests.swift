import XCTest
@testable import Lumi

/// Updater 纯逻辑测试:语义化版本比较、Release URL 版本号提取。
/// 不触发 Updater.shared(其 init 有网络/UserDefaults 副作用)。
final class UpdaterTests: XCTestCase {

    // MARK: - 版本比较(更新可用性判断)

    func testNewerNumericComparison() {
        XCTAssertTrue(Updater.isNewer("1.1.10", than: "1.1.9"), "逐段数字比较,1.1.10 应比 1.1.9 新")
        XCTAssertTrue(Updater.isNewer("2.0", than: "1.99.99"))
        XCTAssertTrue(Updater.isNewer("1.2", than: "1.1.9"))
    }

    func testNewerEqualAndOlder() {
        XCTAssertFalse(Updater.isNewer("1.1.9", than: "1.1.9"))
        XCTAssertFalse(Updater.isNewer("1.1.9", than: "1.1.10"))
        // 缺段按 0 补齐,1.1 与 1.1.0 等价
        XCTAssertFalse(Updater.isNewer("1.1", than: "1.1.0"))
    }

    func testNewerUnparseableIsFalse() {
        XCTAssertFalse(Updater.isNewer("abc", than: "1.0.0"))
        XCTAssertFalse(Updater.isNewer("1.0.0", than: "abc"))
    }

    // MARK: - Release URL 版本号提取

    func testVersionFromReleasesURL() throws {
        let url = try XCTUnwrap(URL(string: "https://github.com/cpufreestyle/Lumi/releases/tag/v1.1.19"))
        XCTAssertEqual(Updater.versionFromReleasesURL(url), "1.1.19", "应去掉 v 前缀")
    }

    func testVersionFromReleasesURLWithoutVPrefix() throws {
        let url = try XCTUnwrap(URL(string: "https://github.com/cpufreestyle/Lumi/releases/tag/1.2.0"))
        XCTAssertEqual(Updater.versionFromReleasesURL(url), "1.2.0")
    }

    func testVersionFromReleasesURLNoTagComponentReturnsNil() throws {
        let url = try XCTUnwrap(URL(string: "https://github.com/cpufreestyle/Lumi/releases/latest"))
        XCTAssertNil(Updater.versionFromReleasesURL(url))
    }
}
