import XCTest
@testable import Lumi

/// 同曲重播判定测试（Foundation only）。
///
/// 曲目标识不变时切歌分支不触发，若不识别「从头重播」，歌词/防抖/偏移
/// 会沿用上一轮状态，重播时歌词与歌声不一致。
final class PlaybackRestartTests: XCTestCase {
    func testDetectsReplayAfterLatePosition() {
        // 上一拍在 120s，本轮回到 0.5s —— 典型重播
        XCTAssertTrue(PlaybackRestart.isRestartFromBeginning(
            trackChanged: false, title: "稻香",
            previousPosition: 120, sampledPosition: 0.5, isPlaying: true))
    }

    func testNormalPlaybackIsNotRestart() {
        // 正常播放中：位置持续小幅前进
        XCTAssertFalse(PlaybackRestart.isRestartFromBeginning(
            trackChanged: false, title: "稻香",
            previousPosition: 120, sampledPosition: 121.5, isPlaying: true))
    }

    func testEarlyPositionDriftIsNotRestart() {
        // 前奏附近的正常抖动：上一拍才 3s，不算「明显靠后」
        XCTAssertFalse(PlaybackRestart.isRestartFromBeginning(
            trackChanged: false, title: "稻香",
            previousPosition: 3, sampledPosition: 0.4, isPlaying: true))
    }

    func testTrackChangeIsHandledElsewhere() {
        // 已判定切歌：不该由重播判定接管
        XCTAssertFalse(PlaybackRestart.isRestartFromBeginning(
            trackChanged: true, title: "稻香",
            previousPosition: 120, sampledPosition: 0, isPlaying: true))
    }

    func testStoppedStateIsNotRestart() {
        // Music 停止时 AppleScript 返回空标题 + position 0
        XCTAssertFalse(PlaybackRestart.isRestartFromBeginning(
            trackChanged: false, title: "",
            previousPosition: 120, sampledPosition: 0, isPlaying: false))
    }

    func testEmptyTitleIsNotRestart() {
        XCTAssertFalse(PlaybackRestart.isRestartFromBeginning(
            trackChanged: false, title: "",
            previousPosition: 120, sampledPosition: 0, isPlaying: true))
    }

    func testNoPreviousPositionIsNotRestart() {
        // 首次采样：没有历史位置可比
        XCTAssertFalse(PlaybackRestart.isRestartFromBeginning(
            trackChanged: false, title: "稻香",
            previousPosition: nil, sampledPosition: 0, isPlaying: true))
    }

    func testMidSongSeekIsNotRestart() {
        // 用户拖进度条回到 8s：超过 beginningThreshold，算 seek 不算重播
        XCTAssertFalse(PlaybackRestart.isRestartFromBeginning(
            trackChanged: false, title: "稻香",
            previousPosition: 120, sampledPosition: 8, isPlaying: true))
    }
}
