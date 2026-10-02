import XCTest
import Foundation
@testable import Lumi

/// 剪贴板视频链接嗅探纯逻辑测试：链接提取 / 站点白名单 / 归一化去重 / 设置持久化。
final class VideoLinkDetectorTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        defaults = UserDefaults(suiteName: "VideoLinkDetectorTests.\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let defaults { defaults.removePersistentDomain(forName: defaults.description) }
        defaults = nil
    }

    private func url(_ s: String) -> URL { URL(string: s)! }

    // MARK: - 链接提取

    func testDetectLinksExtractsSingleURL() {
        let links = VideoLinkDetector.detectLinks(in: "看看这个 https://www.bilibili.com/video/BV1xx411c7m5 好看")
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.host, "www.bilibili.com")
    }

    func testDetectLinksPreservesOrderAndDedupes() {
        let links = VideoLinkDetector.detectLinks(in: "a https://b23.tv/aaa b https://youtu.be/bbb c https://b23.tv/aaa")
        XCTAssertEqual(links.map { $0.absoluteString }, ["https://b23.tv/aaa", "https://youtu.be/bbb"])
    }

    func testDetectLinksEmptyInputs() {
        XCTAssertTrue(VideoLinkDetector.detectLinks(in: nil).isEmpty)
        XCTAssertTrue(VideoLinkDetector.detectLinks(in: "").isEmpty)
        XCTAssertTrue(VideoLinkDetector.detectLinks(in: "   \n ").isEmpty)
    }

    func testDetectLinksPlainText() {
        XCTAssertTrue(VideoLinkDetector.detectLinks(in: "今天天气不错，改天一起吃饭吗").isEmpty)
    }

    // MARK: - 站点判定

    func testIsSupportedDefaultHosts() {
        XCTAssertTrue(VideoLinkDetector.isSupported(url: url("https://www.bilibili.com/video/BV1xx")))
        XCTAssertTrue(VideoLinkDetector.isSupported(url: url("https://b23.tv/abc")))
        XCTAssertTrue(VideoLinkDetector.isSupported(url: url("https://www.youtube.com/watch?v=abc")))
        XCTAssertTrue(VideoLinkDetector.isSupported(url: url("https://v.qq.com/x/cover/abc.html")))
    }

    func testIsSupportedRejectsNonHTTPOrSchemeless() {
        XCTAssertFalse(VideoLinkDetector.isSupported(url: url("ftp://bilibili.com/x")))
        XCTAssertFalse(VideoLinkDetector.isSupported(url: url("mailto:a@b.com")))
        XCTAssertFalse(VideoLinkDetector.isSupported(url: url("bilibili.com/video/BV1")))
    }

    func testIsSupportedHostCaseInsensitive() {
        XCTAssertTrue(VideoLinkDetector.isSupported(url: url("https://YouTube.com/watch?v=x")))
    }

    func testIsSupportedExtraHosts() {
        let target = url("https://v.anime-example.org/ep/1")
        XCTAssertFalse(VideoLinkDetector.isSupported(url: target))
        XCTAssertTrue(VideoLinkDetector.isSupported(url: target, extraHosts: ["v.anime-example.org"]))
    }

    func testDefaultHostsContainKeySites() {
        for host in ["bilibili.com", "b23.tv", "youtube.com", "youtu.be", "v.qq.com", "douyin.com", "x.com"] {
            XCTAssertTrue(VideoLinkDetector.defaultHosts.contains(host), host)
        }
    }
    func testIsSupportedWwwEquivalentToBareDomain() {
        XCTAssertTrue(VideoLinkDetector.isSupported(url: url("https://www.bilibili.com/video/BV1xx")))
        XCTAssertTrue(VideoLinkDetector.isSupported(url: url("https://www.youtube.com/watch?v=abc")))
        XCTAssertFalse(VideoLinkDetector.isSupported(url: url("https://www.example.com/")))
    }

    // MARK: - 归一化

    func testCanonicalKeyStripsTrackingParams() {
        let key = VideoLinkDetector.canonicalKey(url("https://www.bilibili.com/video/BV1xx/?spm_id_from=333.999&vd_source=abcdef"))
        XCTAssertEqual(key, "bilibili.com/video/BV1xx")
    }

    func testCanonicalKeyKeepsVideoParamsSorted() {
        let key = VideoLinkDetector.canonicalKey(url("https://youtube.com/watch?v=abc123&list=PL9&utm_source=copy"))
        XCTAssertEqual(key, "youtube.com/watch?list=PL9&v=abc123")
    }

    func testCanonicalKeyLowercasesHostStripsWwwAndTrailingSlash() {
        let key = VideoLinkDetector.canonicalKey(url("https://WWW.B23.tv/AbC/"))
        XCTAssertEqual(key, "b23.tv/AbC")
    }

    func testCanonicalKeySameVideoDifferentTrackingEqual() {
        let a = VideoLinkDetector.canonicalKey(url("https://b23.tv/abc"))
        let b = VideoLinkDetector.canonicalKey(url("https://b23.tv/abc?utm_source=weixin&share_plat=ios"))
        XCTAssertEqual(a, b)
    }

    func testNormalizedHostsParsesProtocolPathCase() {
        let hosts = VideoLinkDetector.normalizedHosts([
            "HTTPS://Example.com/watch/1",
            "  m.Test.cn  ",
            "douyin.com."
        ])
        XCTAssertEqual(hosts, ["example.com", "m.test.cn", "douyin.com"])
    }

    func testNormalizedHostsDropsGarbage() {
        let hosts = VideoLinkDetector.normalizedHosts(["localhost", "no spaces.com", "", "   ", "ftp://x"])
        XCTAssertTrue(hosts.isEmpty)
    }

    // MARK: - 综合决策

    func testPickReturnsFirstSupportedLink() {
        let link = VideoLinkDetector.pick(
            text: "普通文字 https://www.bilibili.com/video/BV1xx 更多文字",
            enabled: true
        )
        XCTAssertEqual(link?.host, "www.bilibili.com")
        XCTAssertEqual(link?.key, "bilibili.com/video/BV1xx")
    }

    func testPickSkipsUnsupportedThenFindsSupported() {
        let link = VideoLinkDetector.pick(text: "https://example.com/page https://b23.tv/xyz", enabled: true)
        XCTAssertEqual(link?.host, "b23.tv")
    }

    func testPickDisabledReturnsNil() {
        XCTAssertNil(VideoLinkDetector.pick(text: "https://b23.tv/xyz", enabled: false))
    }

    func testPickEmptyText() {
        XCTAssertNil(VideoLinkDetector.pick(text: nil, enabled: true))
        XCTAssertNil(VideoLinkDetector.pick(text: "没有链接", enabled: true))
    }

    func testPickExcludesQueuedKeys() {
        let link = VideoLinkDetector.pick(
            text: "https://b23.tv/xyz?utm_source=copy",
            enabled: true,
            excluding: ["b23.tv/xyz"]
        )
        XCTAssertNil(link)
    }

    func testPickExtraHostsAllowsCustomDomain() {
        let link = VideoLinkDetector.pick(
            text: "https://v.anime-example.org/ep/12",
            enabled: true,
            extraHosts: ["v.anime-example.org"]
        )
        XCTAssertEqual(link?.host, "v.anime-example.org")
    }

    func testPickQueuedKeyMatchesCanonicalOfRawDownloadURL() {
        let queued = Set([VideoLinkDetector.canonicalKey(url("https://b23.tv/xyz?spm_id_from=1"))])
        XCTAssertNil(VideoLinkDetector.pick(text: "https://b23.tv/xyz", enabled: true, excluding: queued))
    }

    func testDetectedLinkHostDisplayStripsWww() {
        let link = VideoLinkDetector.pick(text: "https://www.bilibili.com/video/BV1", enabled: true)
        XCTAssertEqual(link?.hostDisplay, "bilibili.com")
    }

    // MARK: - 设置持久化

    func testSettingsDefaultOff() {
        XCTAssertEqual(ClipboardSniffSettings.load(from: defaults), .defaults)
        XCTAssertFalse(ClipboardSniffSettings.defaults.enabled)
        XCTAssertTrue(ClipboardSniffSettings.defaults.extraHosts.isEmpty)
    }

    func testSettingsRoundTrip() {
        var settings = ClipboardSniffSettings(enabled: true, extraHosts: ["example.com", "  HTTPS://m.test.cn/x "])
        XCTAssertEqual(settings.normalizedExtraHosts, ["example.com", "m.test.cn"])
        settings.save(to: defaults)
        XCTAssertEqual(ClipboardSniffSettings.load(from: defaults), settings)
    }

    func testSettingsRoundTripDefaults() {
        ClipboardSniffSettings.defaults.save(to: defaults)
        XCTAssertEqual(ClipboardSniffSettings.load(from: defaults), .defaults)
    }

    func testSettingsWithEnabledPreservesExtraHosts() {
        let base = ClipboardSniffSettings(enabled: false, extraHosts: ["a.com"])
        let next = base.withEnabled(true)
        XCTAssertTrue(next.enabled)
        XCTAssertEqual(next.extraHosts, ["a.com"])
    }

    func testSettingsWithExtraHostsPreservesEnabled() {
        let base = ClipboardSniffSettings(enabled: true, extraHosts: [])
        let next = base.withExtraHosts(["b.com"])
        XCTAssertTrue(next.enabled)
        XCTAssertEqual(next.extraHosts, ["b.com"])
    }

    func testSettingsLoadFromOtherSuiteFallsBackToDefault() {
        ClipboardSniffSettings(enabled: true, extraHosts: ["x.com"]).save(to: defaults)
        let other = UserDefaults(suiteName: "VideoLinkDetectorTests.\(UUID().uuidString)")!
        XCTAssertEqual(ClipboardSniffSettings.load(from: other), .defaults)
    }
}
