import XCTest
@testable import Lumi

/// PluginLog 诊断日志的纯逻辑测试（仅 Foundation）。
final class PluginLogTests: XCTestCase {

    func testPathIsUnderLogsLumi() {
        XCTAssertTrue(PluginLog.path.hasSuffix("Logs/Lumi/plugin.log"),
                      "日志必须落在 ~/Library/Logs/Lumi/plugin.log，与 music.log 同目录")
    }

    func testWriteDoesNotThrowAndCreatesFile() throws {
        PluginLog.info("单元测试写入 probe=\(UUID().uuidString)")
        // 写入是异步的（专用串行队列），轮询等待文件出现
        let expectation = expectation(description: "log file appears")
        var seen = false
        for _ in 0..<50 {
            if FileManager.default.fileExists(atPath: PluginLog.path) {
                if let txt = try? String(contentsOf: URL(fileURLWithPath: PluginLog.path),
                                         encoding: .utf8),
                   txt.contains("单元测试写入") {
                    seen = true
                    break
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(seen, "日志内容应已落盘")
        expectation.fulfill()
        wait(for: [expectation], timeout: 1)
    }

    func testClearRemovesFile() {
        PluginLog.info("清理前写入")
        PluginLog.clear()
        let expectation = expectation(description: "file removed")
        var gone = false
        for _ in 0..<50 {
            if !FileManager.default.fileExists(atPath: PluginLog.path) { gone = true; break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(gone, "clear 后文件应不存在")
        expectation.fulfill()
        wait(for: [expectation], timeout: 1)
    }

    func testLevelsAreAccepted() {
        // 三个级别都应可调用且不抛异常（真正校验落盘内容由上面两例覆盖）
        PluginLog.info("info level")
        PluginLog.warn("warn level")
        PluginLog.error("error level")
        XCTAssertTrue(PluginLog.path.contains("plugin.log"))
    }
}

