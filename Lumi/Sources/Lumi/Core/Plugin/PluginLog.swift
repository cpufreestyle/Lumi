import Foundation

/// 插件子系统诊断日志（写入 ~/Library/Logs/Lumi/plugin.log）。
///
/// 落盘是必需的：`log show` 抓不到 App 的 NSLog（与 lyricLog 同一原因），
/// 而「面板不出现 / 按钮没反应 / 插件没被发现」这类问题全靠这个文件定位。
/// 对齐 MusicController.appendMusicLog 的单文件滚动策略：超过 512KB 截断重写。
enum PluginLog {

    /// 专用串行队列，避免高频面板事件在主线程或并发写同一文件。
    private static let queue = DispatchQueue(label: "com.lumi.plugin.log", qos: .utility)

    private static var fileURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Lumi")
            .appendingPathComponent("plugin.log")
    }

    /// 供 UI「打开日志」按钮使用。
    static var path: String { fileURL.path }

    /// 供「清空日志」使用。
    static func clear() {
        queue.async { try? FileManager.default.removeItem(at: fileURL) }
    }

    static func info(_ msg: String) { write("INFO", msg) }
    static func warn(_ msg: String) { write("WARN", msg) }
    static func error(_ msg: String) { write("ERROR", msg) }

    private static func write(_ level: String, _ msg: String) {
        NSLog("[Lumi/Plugin] \(msg)")
        queue.async {
            do {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                let ts = ISO8601DateFormatter().string(from: Date())
                let line = "[\(ts)] \(level) \(msg)\n"
                // 超过 512KB 截断重写，避免无限增长
                if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                   (attrs[.size] as? UInt64) ?? 0 > 512 * 1024 {
                    try line.write(to: fileURL, atomically: true, encoding: .utf8)
                    return
                }
                if let handle = try? FileHandle(forWritingTo: fileURL) {
                    handle.seekToEndOfFile()
                    handle.write(line.data(using: .utf8)!)
                    handle.closeFile()
                } else {
                    try line.write(to: fileURL, atomically: true, encoding: .utf8)
                }
            } catch { /* 诊断日志写入失败不影响主流程 */ }
        }
    }
}

