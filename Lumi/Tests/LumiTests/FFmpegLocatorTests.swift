import XCTest
import Foundation
@testable import Lumi

/// ffmpeg 探测与失败归因纯逻辑测试：PATH 优先 / 回退顺序 / symlink 目标 / 输出分类。
final class FFmpegLocatorTests: XCTestCase {

    /// 构造一个全 stub 探针：exists/isExecutable 由集合驱动，symlinkTarget 由字典驱动。
    private func stubProbe(
        existing: Set<String> = [],
        executables: Set<String> = [],
        symlinks: [String: String] = [:]
    ) -> FFmpegLocator.Probe {
        FFmpegLocator.Probe(
            exists: { existing.contains($0) },
            isExecutable: { executables.contains($0) },
            symlinkTarget: { symlinks[$0] }
        )
    }

    // MARK: - 路径解析

    func testResolvePrefersWhichResult() {
        let probe = stubProbe(existing: ["/custom/ffmpeg"], executables: ["/custom/ffmpeg"])
        let resolved = FFmpegLocator.resolve(which: { _ in "/custom/ffmpeg" }, probe: probe)
        XCTAssertEqual(resolved, "/custom/ffmpeg")
    }

    func testResolveIgnoresUnusableWhichResultAndFallsBack() {
        // which 命中了但文件不存在 / 不可执行 → 继续走回退路径（Homebrew arm 优先于 Intel）
        let probe = stubProbe(
            existing: ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"],
            executables: ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        )
        let resolved = FFmpegLocator.resolve(which: { _ in "/opt/homebrew/bin/ffmpeg" }, probe: probe)
        XCTAssertEqual(resolved, "/opt/homebrew/bin/ffmpeg")

        let withoutArm = stubProbe(existing: ["/usr/local/bin/ffmpeg"], executables: ["/usr/local/bin/ffmpeg"])
        let fallback = FFmpegLocator.resolve(which: { _ in "/does/not/exist" }, probe: withoutArm)
        XCTAssertEqual(fallback, "/usr/local/bin/ffmpeg")
    }

    func testResolveReturnsNilWhenNothingUsable() {
        let resolved = FFmpegLocator.resolve(which: { _ in nil }, probe: stubProbe())
        XCTAssertNil(resolved)
    }

   func testIsUsableRejectsDirectoryAndMissingFile() {
        XCTAssertFalse(FFmpegLocator.isUsable("/opt/homebrew/bin/ffmpeg", probe: stubProbe()))

        let directory = stubProbe(existing: ["/opt/homebrew/bin"], executables: ["/opt/homebrew/bin"])
        XCTAssertFalse(FFmpegLocator.isUsable("/opt/homebrew/bin/nope", probe: directory))
    }

    func testIsUsableFollowsSymlinkToExecutableTarget() {
        let probe = stubProbe(
            existing: ["/opt/homebrew/bin/ffmpeg"],
            executables: ["/usr/bin/env"],
            symlinks: ["/opt/homebrew/bin/ffmpeg": "/usr/bin/env"]
        )
        // brew 装的就是 symlink，isExecutableFile 对 symlink 返回 false，必须解析真实目标
        XCTAssertTrue(FFmpegLocator.isUsable("/opt/homebrew/bin/ffmpeg", probe: probe))
    }

    func testAbsoluteDestinationHandlesRelativeTarget() {
        let absolute = FFmpegLocator.absoluteDestination(
            of: "/opt/homebrew/bin/ffmpeg",
            target: "../Cellar/ffmpeg/8.1.2_2/bin/ffmpeg"
        )
        XCTAssertEqual(absolute, "/opt/homebrew/Cellar/ffmpeg/8.1.2_2/bin/ffmpeg")
    }

    func testAbsoluteDestinationKeepsAbsoluteTarget() {
        let absolute = FFmpegLocator.absoluteDestination(
            of: "/opt/homebrew/bin/ffmpeg",
            target: "/usr/local/bin/ffmpeg"
        )
        XCTAssertEqual(absolute, "/usr/local/bin/ffmpeg")
    }

    func testAbsoluteDestinationRejectsEmptyTarget() {
        XCTAssertNil(FFmpegLocator.absoluteDestination(of: "/opt/homebrew/bin/ffmpeg", target: ""))
    }

    func testFallbackPathsOrderPrefersBrewArm() {
        XCTAssertEqual(FFmpegLocator.fallbackPaths.first, "/opt/homebrew/bin/ffmpeg")
        XCTAssertTrue(FFmpegLocator.fallbackPaths.contains("/usr/bin/ffmpeg"))
        XCTAssertEqual(Set(FFmpegLocator.fallbackPaths).count, FFmpegLocator.fallbackPaths.count)
    }

    // MARK: - 失败归因

    func testClassifyFFmpegMissingFromYtDlpOutput() {
        let output = "ERROR: ffmpeg is not installed. Please install ffmpeg to merge formats."
        XCTAssertEqual(FFmpegLocator.Failure.classify(output: output), .ffmpegMissing)
    }

    func testClassifyNetworkErrors() {
        let samples = [
            "ERROR: Unable to download webpage: Connection reset by peer (caused by ConnectionResetError)",
            "ERROR: unable to download video data: The read operation timed out",
            "ERROR: HTTP Error 429: Too Many Requests",
            "ERROR: unable to download video data: Temporary failure in name resolution"
        ]
        for sample in samples {
            XCTAssertEqual(FFmpegLocator.Failure.classify(output: sample), .network, sample)
        }
    }

    func testClassifyUnknown() {
        XCTAssertEqual(FFmpegLocator.Failure.classify(output: "[download]  17.0% of ~50.00MiB"), .unknown)
        XCTAssertEqual(FFmpegLocator.Failure.classify(output: ""), .unknown)
    }

    func testMessageCarriesActionableHint() {
        XCTAssertTrue(FFmpegLocator.message(for: .ffmpegMissing).contains("brew install ffmpeg"))
        XCTAssertTrue(FFmpegLocator.message(for: .network).contains("代理"))
    }

    func testMissingDependencyMessageIncludesInstallCommand() {
        XCTAssertTrue(FFmpegLocator.missingDependencyMessage.contains(FFmpegLocator.installCommand))
        XCTAssertEqual(FFmpegLocator.installCommand, "brew install ffmpeg")
    }

    // MARK: - 探针注入

   func testLiveProbeResolvesRealFFmpegOnThisMachine() {
        // 开发机装有 Homebrew ffmpeg：解析结果必须落在回退路径内且自校验可用
        let resolved = FFmpegLocator.resolve(which: { _ in nil })
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved, FFmpegLocator.fallbackPaths.first)
        XCTAssertTrue(FFmpegLocator.isUsable(resolved ?? ""))
    }

    func testLiveProbeIsExecutableCheckIsStable() {
        XCTAssertTrue(FFmpegLocator.isUsable("/usr/bin/env"))
    }
}
