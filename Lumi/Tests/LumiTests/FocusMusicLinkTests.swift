import XCTest
import Foundation
@testable import Lumi

/// 专注 × 音乐联动的纯逻辑测试（设置持久化 / 音量钳制 / 恢复决策）。
/// 用独立 UserDefaults suite，不碰标准域。
final class FocusMusicLinkTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        defaults = UserDefaults(suiteName: "FocusMusicLinkTests.\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: defaults.description)
        defaults = nil
    }

    // MARK: - 钳制

    func testClampVolume() {
        XCTAssertEqual(FocusMusicLink.clampVolume(150), 100)
        XCTAssertEqual(FocusMusicLink.clampVolume(-5), 0)
        XCTAssertEqual(FocusMusicLink.clampVolume(35), 35)
        XCTAssertEqual(FocusMusicLink.clampVolume(0), 0)
    }

    // MARK: - 持久化

    func testDefaultsWhenNoKeys() {
        let link = FocusMusicLink.load(from: defaults)
        XCTAssertEqual(link, .default)
        XCTAssertTrue(link.enabled)
        XCTAssertEqual(link.focusVolume, 35)
        XCTAssertEqual(link.playlist, "")
    }

    func testSaveLoadRoundTrip() {
        var link = FocusMusicLink.default
        link.enabled = false
        link.playlist = "专注白噪音"
        link.focusVolume = 20
        link.save(to: defaults)
        XCTAssertEqual(FocusMusicLink.load(from: defaults), link)
    }

    func testZeroVolumePersistsAsZeroNotDefault() {
        // 回归坑：UserDefaults.integer 取不到键返回 0，会把「用户设 0」与「未设置」混淆
        var link = FocusMusicLink.default
        link.focusVolume = 0
        link.save(to: defaults)
        let loaded = FocusMusicLink.load(from: defaults)
        XCTAssertEqual(loaded.focusVolume, 0)
    }

    func testPlaylistTrimmedOnLoadAndSave() {
        var link = FocusMusicLink.default
        link.playlist = "  白噪音  "
        link.save(to: defaults)
        XCTAssertEqual(FocusMusicLink.load(from: defaults).playlist, "白噪音")

        defaults.set("  雨声  ", forKey: "lumi_focus_playlist")
        XCTAssertEqual(FocusMusicLink.load(from: defaults).playlist, "雨声")
    }

    func testSaveClampsVolume() {
        var link = FocusMusicLink.default
        link.focusVolume = 999
        link.save(to: defaults)
        XCTAssertEqual(FocusMusicLink.load(from: defaults).focusVolume, 100)
    }

    // MARK: - 恢复决策

    func testRestoreDecision() {
        // 专注前在播 → 保持播放（由调用方恢复音量）
        XCTAssertEqual(FocusMusicLink.restorePlayback(wasPlayingBeforeFocus: true), .resume)
        // 专注前没播 → 停掉为专注开起来的声音，不擅自继续
        XCTAssertEqual(FocusMusicLink.restorePlayback(wasPlayingBeforeFocus: false), .pause)
    }
}
