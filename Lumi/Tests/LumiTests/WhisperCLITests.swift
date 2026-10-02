import XCTest
import Foundation
@testable import Lumi

/// whisper-cli 调用层单测（纯逻辑：路径解析 / 模型发现 / 参数拼装 / 输出提取）。
///
/// 只碰 `WhisperCLI`（Foundation-only），不实例化 `DictationController`、不起进程——
/// 遵守「测试目标只依赖 Foundation/CryptoKit，不引入 GUI 框架」的约定。
///
/// 覆盖率对应 2026-09-26 的实测行为：stdout 干净（日志走 stderr）、ggml-*.bin 命名、
/// 档位体积下限（防下载到一半的模型被判为可用）。
final class WhisperCLITests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("whispercli-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        super.tearDown()
    }

    private func makeFile(_ name: String, bytes: Int, executable: Bool = false) -> URL {
        let url = tempDir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0x41, count: bytes))
        if executable {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return url
    }

    // MARK: - 二进制解析

    func testResolveBinaryPathFindsExecutable() {
        let bin = makeFile("whisper-cli", bytes: 16, executable: true)
        XCTAssertEqual(WhisperCLI.resolveBinaryPath(candidates: [bin.path]), bin.path)
    }

    func testResolveBinaryPathSkipsNonExecutable() {
        let bin = makeFile("whisper-cli", bytes: 16) // 没有可执行位
        XCTAssertNil(WhisperCLI.resolveBinaryPath(candidates: [bin.path]))
    }

    func testResolveBinaryPathReturnsNilWhenCandidatesMissing() {
        let missing = tempDir.appendingPathComponent("nope").path
        XCTAssertNil(WhisperCLI.resolveBinaryPath(candidates: [missing]))
    }

    func testResolveBinaryPathRespectsCandidateOrder() {
        let first = makeFile("a-whisper-cli", bytes: 16, executable: true)
        let second = makeFile("b-whisper-cli", bytes: 16, executable: true)
        XCTAssertEqual(WhisperCLI.resolveBinaryPath(candidates: [first.path, second.path]), first.path)
    }

    func testExpandTildeUsesHomeDirectory() {
        XCTAssertEqual(
            WhisperCLI.expandTilde("~/Library/Application Support/Lumi/models"),
            NSHomeDirectory() + "/Library/Application Support/Lumi/models"
        )
        XCTAssertEqual(WhisperCLI.expandTilde("/opt/homebrew/bin/whisper-cli"), "/opt/homebrew/bin/whisper-cli")
    }

    // MARK: - 模型发现

    func testInstalledModelsFindsGGMLSortedBySizeDesc() throws {
        try Data(repeating: 0x42, count: 200).write(to: tempDir.appendingPathComponent("ggml-small.bin"))
        try Data(repeating: 0x43, count: 100).write(to: tempDir.appendingPathComponent("ggml-base.bin"))
        let models = WhisperCLI.installedModels(searchDirs: [tempDir.path])
        XCTAssertEqual(models.map(\.name), ["ggml-small.bin", "ggml-base.bin"])
        XCTAssertEqual(models[0].sizeBytes, 200)
    }

    func testInstalledModelsIgnoresNonGGMLFiles() throws {
        try Data(repeating: 0x44, count: 50).write(to: tempDir.appendingPathComponent("ggml-base.txt"))
        try Data(repeating: 0x45, count: 50).write(to: tempDir.appendingPathComponent("notes.md"))
        try Data(repeating: 0x46, count: 50).write(to: tempDir.appendingPathComponent("other.bin"))
        XCTAssertTrue(WhisperCLI.installedModels(searchDirs: [tempDir.path]).isEmpty)
    }

    func testInstalledModelsSkipsMissingDirs() {
        XCTAssertTrue(WhisperCLI.installedModels(searchDirs: ["/nonexistent-dir-\(UUID().uuidString)"]).isEmpty)
    }

    // MARK: - 档位与完整性

    func testTierParsing() {
        XCTAssertEqual(WhisperCLI.Model(name: "ggml-base.bin", path: "/x", sizeBytes: 1).tier, "base")
        XCTAssertEqual(WhisperCLI.Model(name: "ggml-base.en.bin", path: "/x", sizeBytes: 1).tier, "base.en")
        XCTAssertEqual(WhisperCLI.Model(name: "weird.bin", path: "/x", sizeBytes: 1).tier, "weird")
    }

    func testMinimumBytesEscalatesWithTier() {
        XCTAssertLessThan(WhisperCLI.minimumBytes(forTier: "tiny"), WhisperCLI.minimumBytes(forTier: "base"))
        XCTAssertLessThan(WhisperCLI.minimumBytes(forTier: "base"), WhisperCLI.minimumBytes(forTier: "small"))
        XCTAssertGreaterThanOrEqual(WhisperCLI.minimumBytes(forTier: "base"), 140_000_000)
    }

    func testCompletenessBoundary() {
        let exact = WhisperCLI.Model(
            name: "ggml-base.bin", path: "/x",
            sizeBytes: WhisperCLI.minimumBytes(forTier: "base")
        )
        let below = WhisperCLI.Model(
            name: "ggml-base.bin", path: "/x",
            sizeBytes: WhisperCLI.minimumBytes(forTier: "base") - 1
        )
        XCTAssertTrue(exact.isComplete)
        XCTAssertFalse(below.isComplete)
    }

    // MARK: - 自动选型

    func testPreferredModelPicksBaseOverTiny() {
        let models = [
            WhisperCLI.Model(name: "ggml-tiny.bin", path: "/t", sizeBytes: 80_000_000),
            WhisperCLI.Model(name: "ggml-base.bin", path: "/b", sizeBytes: 150_000_000),
        ]
        XCTAssertEqual(WhisperCLI.preferredModel(models)?.path, "/b")
    }

    func testPreferredModelSkipsIncomplete() {
        let models = [
            WhisperCLI.Model(name: "ggml-base.bin", path: "/b", sizeBytes: 1_000_000), // 下载中，不完整
            WhisperCLI.Model(name: "ggml-tiny.bin", path: "/t", sizeBytes: 80_000_000),
        ]
        XCTAssertEqual(WhisperCLI.preferredModel(models)?.path, "/t")
    }

    func testPreferredModelNilWhenAllIncomplete() {
        let models = [WhisperCLI.Model(name: "ggml-base.bin", path: "/b", sizeBytes: 1_000_000)]
        XCTAssertNil(WhisperCLI.preferredModel(models))
    }

    func testPreferredModelNilWhenEmpty() {
        XCTAssertNil(WhisperCLI.preferredModel([]))
    }

    // MARK: - 参数拼装

    func testBuildArgumentsOrderAndFlags() {
        let args = WhisperCLI.buildArguments(modelPath: "/m.bin", audioPath: "/a.wav", language: "zh")
        XCTAssertEqual(args, ["-m", "/m.bin", "-f", "/a.wav", "-np", "-nt", "-l", "zh"])
    }

    func testBuildArgumentsAppendsTranslateFlag() {
        let args = WhisperCLI.buildArguments(
            modelPath: "/m.bin", audioPath: "/a.wav", language: "auto", translateToEnglish: true
        )
        XCTAssertTrue(args.contains("-tr"))
    }

    func testBuildArgumentsNormalizesBadLanguage() {
        let args = WhisperCLI.buildArguments(modelPath: "/m.bin", audioPath: "/a.wav", language: "klingon")
        XCTAssertEqual(args.last, "auto")
    }

    // MARK: - 输出提取

    func testExtractTranscriptionCleanStdout() {
        XCTAssertEqual(WhisperCLI.extractTranscription(fromStdout: "Hello world\n"), "Hello world")
    }

    func testExtractTranscriptionJoinsSegmentsWithNewline() {
        XCTAssertEqual(WhisperCLI.extractTranscription(fromStdout: "你好\n世界\n"), "你好\n世界")
    }

    func testExtractTranscriptionFiltersLogLines() {
        let stdout = "system_info: ggml metal\nwhisper_print_timings: 1.2s\n真实文本\n"
        XCTAssertEqual(WhisperCLI.extractTranscription(fromStdout: stdout), "真实文本")
    }

    func testExtractTranscriptionStripsTimestampPrefix() {
        let stdout = "[00:00:00.000 --> 00:00:02.000]  第一句\n[00:00:02.000 --> 00:00:04.000] 第二句\n"
        XCTAssertEqual(WhisperCLI.extractTranscription(fromStdout: stdout), "第一句\n第二句")
    }

    func testExtractTranscriptionEmptyInput() {
        XCTAssertEqual(WhisperCLI.extractTranscription(fromStdout: ""), "")
        XCTAssertEqual(WhisperCLI.extractTranscription(fromStdout: "\n\n  \n"), "")
    }

    // MARK: - 语言归一化

    func testNormalizeLanguage() {
        XCTAssertEqual(WhisperCLI.normalizeLanguage(nil), "auto")
        XCTAssertEqual(WhisperCLI.normalizeLanguage(""), "auto")
        XCTAssertEqual(WhisperCLI.normalizeLanguage("zh"), "zh")
        XCTAssertEqual(WhisperCLI.normalizeLanguage("martian"), "auto")
    }

    // MARK: - 下载地址

    func testDownloadURL() {
        XCTAssertEqual(
            WhisperCLI.downloadURL(forTier: "base")?.absoluteString,
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin"
        )
    }
}
