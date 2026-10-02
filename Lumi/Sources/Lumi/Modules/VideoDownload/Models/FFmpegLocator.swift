import Foundation

/// yt-dlp 依赖的 ffmpeg 探测 + 失败归因（纯逻辑，测试目标零 GUI 依赖）。
///
/// 为什么必须有 ffmpeg：`VideoDownloadController.performDownload` 的两类参数都依赖它——
/// 1. 分离流合并：`-f bestvideo[ext=mp4]+bestaudio[ext=m4a]` + `--merge-output-format mp4`；
/// 2. 抽音频：`--extract-audio --audio-format mp3 --audio-quality 0`。
/// ffmpeg 缺失时 yt-dlp 非零退出并把 `ERROR: ffmpeg is not installed` 之类写进输出，
/// 旧代码只透出「下载失败 (错误码: 1)」，用户完全不知道该装什么。这里把探测前置到下载前，
/// 并把失败输出归类为可行动的中文提示。
///
/// 解析顺序与 yt-dlp 自身一致：先 PATH（`which ffmpeg`），再回退常见安装路径。
enum FFmpegLocator {

    /// 常见安装路径：Homebrew(arm/x86) → MacPorts → 系统 → Xcode 附带工具。
    static let fallbackPaths: [String] = [
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
        "/opt/local/bin/ffmpeg",
        "/usr/bin/ffmpeg",
        "/Applications/Xcode.app/Contents/Developer/usr/bin/ffmpeg"
    ]

    /// 给用户的安装命令（brew 是 macOS 上的事实标准）。
    static let installCommand = "brew install ffmpeg"

    /// ffmpeg 缺失时的一行说明（面板提示 + 下载前拦截共用）。
    static let missingDependencyMessage =
        "缺少 ffmpeg（MP4 合并流 / MP3 抽音频都需要）：\(installCommand)"

    /// 注入式 PATH 查找，便于单测替换（实现侧走 `/usr/bin/env which`）。
    typealias WhichRunner = (String) -> String?

    /// 文件系统探针：把 `FileManager` 的三次查询抽成闭包，让解析逻辑完全可测。
    struct Probe {
        var exists: (String) -> Bool
        var isExecutable: (String) -> Bool
        /// symlink 目标（非 symlink 返回 nil）。
        var symlinkTarget: (String) -> String?

        static func live(fileManager: FileManager = .default) -> Probe {
            Probe(
                exists: { fileManager.fileExists(atPath: $0) },
                isExecutable: { fileManager.isExecutableFile(atPath: $0) },
                symlinkTarget: { path in
                    guard let target = try? fileManager.destinationOfSymbolicLink(atPath: path) else { return nil }
                    return target
                }
            )
        }
    }

    /// 解析 ffmpeg 可执行路径；找不到返回 nil。
    static func resolve(which: WhichRunner, probe: Probe = .live()) -> String? {
        if let hit = which("ffmpeg")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !hit.isEmpty,
           isUsable(hit, probe: probe) {
            return hit
        }
        for candidate in fallbackPaths where isUsable(candidate, probe: probe) {
            return candidate
        }
        return nil
    }

    /// 判断路径是否可用作可执行文件。brew 装的都是 symlink，
    /// `isExecutableFile` 对 symlink 返回 false，因此 symlink 走「解析真实目标后再判」。
    static func isUsable(_ path: String, probe: Probe = .live()) -> Bool {
        guard probe.exists(path) else { return false }
        if let target = probe.symlinkTarget(path),
           let absolute = absoluteDestination(of: path, target: target),
           probe.isExecutable(absolute) {
            return true
        }
        return probe.isExecutable(path)
    }

    /// 把 symlink 目标补成绝对路径：brew 的目标常是相对形式（`../Cellar/ffmpeg/.../bin/ffmpeg`）。
    static func absoluteDestination(of path: String, target: String) -> String? {
        if target.isEmpty { return nil }
        if target.hasPrefix("/") { return target }
        let base = (path as NSString).deletingLastPathComponent
        if base.isEmpty { return nil }
        return URL(fileURLWithPath: base)
            .appendingPathComponent(target)
            .standardizedFileURL
            .path
    }

    // MARK: - 失败归因

    /// yt-dlp 失败原因分类（用于把错误码翻成用户能行动的话）。
    enum Failure: Equatable {
        case ffmpegMissing
        case network
        case unknown

        static func classify(output: String) -> Failure {
            let text = output.lowercased()
            if text.contains("ffmpeg") { return .ffmpegMissing }
            if text.contains("timed out")
                || text.contains("connection")
                || text.contains("network")
                || text.contains("temporary failure in name resolution")
                || text.contains("unable to download webpage")
                || text.contains("http error 4")
                || text.contains("http error 5")
                || text.contains("429") {
                return .network
            }
            return .unknown
        }
    }

    /// 面向用户的一句话提示（不含原始输出，避免把视频地址/用户路径刷到面板上）。
    static func message(for failure: Failure) -> String {
        switch failure {
        case .ffmpegMissing:
            return "下载失败：缺少 ffmpeg（合并 / 转码必需）。\(installCommand)"
        case .network:
            return "下载失败：网络错误，请检查代理或 VPN 后重试"
        case .unknown:
            return "下载失败，请重试或更换格式"
        }
    }
}

