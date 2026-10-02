import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class VideoDownloadController: ObservableObject {
    static let shared = VideoDownloadController()

    @Published var urlInput: String = ""
    @Published var selectedFormat: DownloadFormat = .mp4
    @Published var isDownloading: Bool = false
    @Published var progress: Double = 0
    @Published var statusMessage: String = ""
    @Published var downloads: [DownloadItem] = []
    @Published var ytdlpAvailable: Bool = false
    /// ffmpeg 是否可用（MP4 合并流 / MP3 抽音频都依赖它，缺失时下载必然失败）。
    @Published var ffmpegAvailable: Bool = true
    /// 下载完成瞬间的胶囊提示（4 秒后自动清除），收缩态 brief 优先展示。
    @Published var completionFlash: String?

    enum DownloadFormat: String, CaseIterable, Identifiable {
        case mp4 = "MP4 视频"
        case mp3 = "MP3 音频"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .mp4: return "film"
            case .mp3: return "music.note"
            }
        }
    }

    struct DownloadItem: Identifiable {
        let id = UUID()
        let url: String
        var title: String
        let format: DownloadFormat
        let timestamp: Date
        var progress: Double = 0
        var isCompleted: Bool = false
        var filePath: String?
    }

    private let downloadsDir: URL
    private var currentProcess: Process?
    private var outputPipe: Pipe?
    private var flashWorkItem: DispatchWorkItem?
    /// 最近若干行 yt-dlp 输出，仅用于失败归因（不展示原文，避免把地址/路径刷到面板上）。
    private var outputTail: [String] = []

    private init() {
        // 下载目录理论上必然存在，但仍回退到用户主目录，避免强制解包崩溃
        let dlDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        downloadsDir = dlDir.appendingPathComponent("Lumi Downloads")
        try? FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        checkYtDlp()
        // ffmpeg 探测是纯路径查询（+ 一次 which），同步做可避免面板闪一下假警告
        ffmpegAvailable = FFmpegLocator.resolve(which: { VideoDownloadController.which($0) }) != nil
    }

    /// 检查 yt-dlp 是否已安装。优先从 PATH 查找，再回退到常见绝对路径（包括 brew 安装的 symlink）。
    private func checkYtDlp() {
        let path = Self.resolveYtDlpPath()
        DispatchQueue.main.async { [weak self] in
            self?.ytdlpAvailable = path != nil
        }
    }

    /// 重新探测外部依赖：用户在面板打开前刚 `brew install` 过 yt-dlp / ffmpeg 时，
    /// 无需重启 App 即可解除拦截。
    func refreshDependencies() {
        ffmpegAvailable = FFmpegLocator.resolve(which: { VideoDownloadController.which($0) }) != nil
        checkYtDlp()
    }

    /// 获取 yt-dlp 可执行路径
    private func ytdlpPath() -> String? {
        Self.resolveYtDlpPath()
    }

    /// 走 PATH 查找可执行文件，返回绝对路径；找不到返回 nil（yt-dlp / ffmpeg 共用）。
    private static func which(_ name: String) -> String? {
        let whichTask = Process()
        whichTask.launchPath = "/usr/bin/env"
        whichTask.arguments = ["which", name]
        whichTask.environment = ProcessInfo.processInfo.environment

        let pipe = Pipe()
        whichTask.standardOutput = pipe
        whichTask.standardError = FileHandle.nullDevice

        do {
            try whichTask.run()
            whichTask.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty,
               FileManager.default.fileExists(atPath: path) {
                return path
            }
        } catch {
            // 忽略 PATH 查找失败
        }
        return nil
    }

    /// 统一解析 yt-dlp 路径：先 PATH，再常见绝对路径；支持 symlink。
    private static func resolveYtDlpPath() -> String? {
        if let path = which("yt-dlp") {
            return path
        }

        // 2) 回退到常见绝对路径。brew 安装的是 symlink，isExecutableFile 对 symlink 返回 false，
        //    因此这里用 fileExists + 可选的 destIsExecutable 校验真实目标。
        let possiblePaths = [
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
            "/usr/bin/yt-dlp"
        ]
        let fm = FileManager.default
        for p in possiblePaths where fm.fileExists(atPath: p) {
            if let resolved = try? fm.destinationOfSymbolicLink(atPath: p),
               fm.isExecutableFile(atPath: resolved) {
                return p
            }
            if fm.isExecutableFile(atPath: p) {
                return p
            }
        }
        return nil
    }

    // MARK: - 开始下载

    func startDownload() {
        guard !urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "请输入视频链接"
            return
        }

        guard ytdlpAvailable else {
            statusMessage = "yt-dlp 未安装。请运行: brew install yt-dlp"
            return
        }

        // ffmpeg 缺失时 yt-dlp 必然非零退出（合并流 / 抽音频都需要它），前置拦截并给出安装命令
        guard ffmpegAvailable else {
            statusMessage = FFmpegLocator.missingDependencyMessage
            return
        }

        guard let ytdlp = ytdlpPath() else {
            statusMessage = "找不到 yt-dlp，请确认已安装"
            return
        }

        let url = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = DownloadItem(url: url, title: "解析中...", format: selectedFormat, timestamp: Date())

        isDownloading = true
        progress = 0
        statusMessage = "正在解析视频信息..."

        // 先获取视频标题
        getTitle(ytdlp: ytdlp, url: url) { [weak self] title in
            guard let self = self else { return }
            var downloadItem = item
            downloadItem.title = title
            self.downloads.insert(downloadItem, at: 0)

            DispatchQueue.main.async {
                self.statusMessage = "正在下载: \(title)"
            }
            self.performDownload(ytdlp: ytdlp, url: url, format: self.selectedFormat, title: title, item: downloadItem)
        }
    }

    /// 剪贴板嗅探一键入队：填入链接后立即开始下载。
    func startDownload(url: String) {
        urlInput = url
        startDownload()
    }

    /// 完成闪烁：写入 completionFlash 并在 4 秒后自动清除（重复触发时重置计时）。
    func flashCompletion(_ title: String) {
        flashWorkItem?.cancel()
        completionFlash = title
        let work = DispatchWorkItem { [weak self] in
            self?.completionFlash = nil
        }
        flashWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    private func getTitle(ytdlp: String, url: String, completion: @escaping (String) -> Void) {
        let task = Process()
        task.launchPath = ytdlp
        task.arguments = ["--get-title", "--no-playlist", url]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let title = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-") ?? "Unknown"

            DispatchQueue.main.async { completion(title) }
        } catch {
            DispatchQueue.main.async { completion("Unknown Video") }
        }
    }

    private func performDownload(ytdlp: String, url: String, format: DownloadFormat, title: String, item: DownloadItem) {
        let task = Process()
        task.launchPath = ytdlp
        outputTail = []

        let safeTitle = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "\"", with: "'")

        let template = downloadsDir.appendingPathComponent("%(title)s.%(ext)s").path

        var args: [String] = [
            "--no-playlist",
            "--newline",
            "--no-colors",
            "-o", template
        ]

        switch format {
        case .mp4:
            args.append(contentsOf: [
                "-f", "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best",
                "--merge-output-format", "mp4"
            ])
        case .mp3:
            args.append(contentsOf: [
                "-f", "bestaudio",
                "--extract-audio",
                "--audio-format", "mp3",
                "--audio-quality", "0"
            ])
        }

        args.append(url)

        task.arguments = args

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            self?.recordOutput(chunk)
            self?.parseProgress(chunk)
        }

        currentProcess = task
        outputPipe = pipe

        task.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                self?.isDownloading = false
                self?.currentProcess = nil

                if process.terminationStatus == 0 {
                    self?.statusMessage = "下载完成: \(title)"
                    self?.progress = 1.0
                    self?.flashCompletion(title)
                    DownloadNotifier.shared.postCompletion(title: title)

                    // 更新下载项状态
                    if let idx = self?.downloads.firstIndex(where: { $0.id == item.id }) {
                        self?.downloads[idx].isCompleted = true
                        self?.downloads[idx].progress = 1.0

                        // 查找实际文件
                        let ext = format == .mp4 ? "mp4" : "mp3"
                        let expectedFile = self?.downloadsDir.appendingPathComponent("\(safeTitle).\(ext)")
                        if let file = expectedFile, FileManager.default.fileExists(atPath: file.path) {
                            self?.downloads[idx].filePath = file.path
                            // 在 Finder 中显示
                            NSWorkspace.shared.activateFileViewerSelecting([file])
                        }
                    }
                } else {
                    let tail = self?.outputTail.joined(separator: "\n") ?? ""
                    self?.statusMessage = FFmpegLocator.message(
                        for: FFmpegLocator.Failure.classify(output: tail)
                    )
                    self?.outputTail = []
                }

                try? handle.close()
            }
        }

        do {
            try task.run()
        } catch {
            DispatchQueue.main.async {
                self.isDownloading = false
                self.statusMessage = "启动下载失败: \(error.localizedDescription)"
            }
        }
    }

    private func parseProgress(_ line: String) {
        // yt-dlp 进度格式: [download]   5.0% of ~100.00MiB at 2.5MiB/s ETA 00:38
        let pattern = try? NSRegularExpression(pattern: #"\[download\]\s+([\d.]+)%"#)
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        if let match = pattern?.firstMatch(in: line, range: range),
            let pRange = Range(match.range(at: 1), in: line),
            let p = Double(line[pRange]) {
            DispatchQueue.main.async { [weak self] in
                self?.progress = p / 100.0
            }
        }
    }

    /// 记录最近若干行输出，失败时据此归因（yt-dlp 把「ffmpeg 没装 / 网络错误」都写在这里）。
    private func recordOutput(_ chunk: String) {
        for raw in chunk.split(separator: "\n", omittingEmptySubsequences: true) {
            outputTail.append(String(raw.prefix(300)))
        }
        if outputTail.count > 8 {
            outputTail.removeFirst(outputTail.count - 8)
        }
    }

    func cancelDownload() {
        currentProcess?.terminate()
        currentProcess = nil
        isDownloading = false
        statusMessage = "已取消下载"
    }

    func pasteURL() {
        if let text = NSPasteboard.general.string(forType: .string) {
            urlInput = text
        }
    }
}
