import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 视频下载模块控制器
final class VideoDownloadController: ObservableObject {
    static let shared = VideoDownloadController()

    @Published var urlInput: String = ""
    @Published var selectedFormat: DownloadFormat = .mp4
    @Published var isDownloading: Bool = false
    @Published var progress: Double = 0
    @Published var statusMessage: String = ""
    @Published var downloads: [DownloadItem] = []
    @Published var ytdlpAvailable: Bool = false

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

    private init() {
        let dlDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        downloadsDir = dlDir.appendingPathComponent("Lumi Downloads")
        try? FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        checkYtDlp()
    }

    /// 检查 yt-dlp 是否已安装
    private func checkYtDlp() {
        let task = Process()
        task.launchPath = "/usr/bin/env"
        task.arguments = ["which", "yt-dlp"]

        // 也尝试检查 brew 安装路径
        let possiblePaths = [
            "/usr/local/bin/yt-dlp",
            "/opt/homebrew/bin/yt-dlp",
            "/usr/bin/yt-dlp"
        ]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            DispatchQueue.main.async { [weak self] in
                self?.ytdlpAvailable = !path.isEmpty || possiblePaths.contains(where: {
                    FileManager.default.isExecutableFile(atPath: $0)
                })
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.ytdlpAvailable = possiblePaths.contains(where: {
                    FileManager.default.isExecutableFile(atPath: $0)
                })
            }
        }
    }

    /// 获取 yt-dlp 可执行路径
    private func ytdlpPath() -> String? {
        let paths = [
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
            "/usr/bin/yt-dlp"
        ]
        for p in paths where FileManager.default.isExecutableFile(atPath: p) {
            return p
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
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            self?.parseProgress(line)
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

                    // 更新下载项状态
                    if let idx = self?.downloads.firstIndex(where: { $0.id == item.id }) {
                        self?.downloads[idx].isCompleted = true
                        self?.downloads[idx].progress = 1.0

                        // 查找实际文件
                        let ext = format == .mp4 ? "mp4" : "mp3"
                        let expectedFile = self?.downloadsDir.appendingPathComponent("\(safeTitle).\(ext)")
                        if let path = expectedFile?.path, FileManager.default.fileExists(atPath: path) {
                            self?.downloads[idx].filePath = path
                            // 在 Finder 中显示
                            NSWorkspace.shared.activateFileViewerSelecting([expectedFile!])
                        }
                    }
                } else {
                    self?.statusMessage = "下载失败 (错误码: \(process.terminationStatus))"
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

// MARK: - 视频下载展开视图
struct VideoDownloadExpandedView: View {
    @ObservedObject private var vd = VideoDownloadController.shared
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("视频下载")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                Text("1800+ 站点")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.35))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // yt-dlp 状态检查
            if !vd.ytdlpAvailable {
                ytdlpInstallPrompt
            }

            // URL 输入
            VStack(alignment: .leading, spacing: 4) {
                Text("视频链接")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
                HStack(spacing: 6) {
                    TextField("粘贴视频 URL...", text: $vd.urlInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(.white)
                        .padding(10)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(8)
                        .focused($isFocused)

                    Button(action: { vd.pasteURL() }) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)

            // 格式选择
            VStack(alignment: .leading, spacing: 4) {
                Text("下载格式")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
                HStack(spacing: 8) {
                    ForEach(VideoDownloadController.DownloadFormat.allCases) { fmt in
                        Button(action: { vd.selectedFormat = fmt }) {
                            HStack(spacing: 5) {
                                Image(systemName: fmt.icon)
                                    .font(.system(size: 11))
                                Text(fmt.rawValue)
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundColor(vd.selectedFormat == fmt ? .white : .white.opacity(0.5))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                vd.selectedFormat == fmt
                                    ? AnyShapeStyle(LinearGradient(colors: [Color.pink, Color.purple], startPoint: .leading, endPoint: .trailing))
                                    : AnyShapeStyle(Color.white.opacity(0.08))
                            )
                            .cornerRadius(10)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            // 进度条
            if vd.isDownloading || vd.progress > 0 {
                VStack(spacing: 6) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.white.opacity(0.1))
                                .frame(height: 6)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(
                                    LinearGradient(colors: [Color.pink, Color.purple], startPoint: .leading, endPoint: .trailing)
                                )
                                .frame(width: geo.size.width * vd.progress, height: 6)
                                .animation(.easeInOut(duration: 0.3), value: vd.progress)
                        }
                    }
                    .frame(height: 6)

                    HStack {
                        Text(vd.statusMessage)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.5))
                            .lineLimit(1)
                        Spacer()
                        Text("\(Int(vd.progress * 100))%")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.pink)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }

            // 下载/取消按钮
            HStack(spacing: 10) {
                if vd.isDownloading {
                    Button(action: { vd.cancelDownload() }) {
                        HStack {
                            Image(systemName: "xmark.circle")
                                .font(.system(size: 12))
                            Text("取消下载")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.red.opacity(0.4))
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                }

                Button(action: { vd.startDownload() }) {
                    HStack {
                        Image(systemName: vd.isDownloading ? "arrow.down.circle" : "arrow.down.to.line")
                            .font(.system(size: 12))
                        Text(vd.isDownloading ? "下载中..." : "开始下载")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        vd.urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vd.isDownloading
                            ? AnyShapeStyle(Color.white.opacity(0.1))
                            : AnyShapeStyle(LinearGradient(colors: [Color.pink, Color.purple], startPoint: .leading, endPoint: .trailing))
                    )
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .disabled(vd.urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vd.isDownloading)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // 下载历史
            if !vd.downloads.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("下载历史")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                        .padding(.horizontal, 16)
                        .padding(.top, 12)

                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(vd.downloads) { item in
                                DownloadHistoryRow(item: item)
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                    .frame(maxHeight: 150)
                }
            }

            Spacer(minLength: 0)
        }
    }

    var ytdlpInstallPrompt: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                Text("需要安装 yt-dlp 以支持视频下载")
                    .font(.system(size: 11))
                    .foregroundColor(.orange.opacity(0.8))
            }
            Text("在终端运行: brew install yt-dlp")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.4))
                .padding(6)
                .background(Color.white.opacity(0.06))
                .cornerRadius(6)
        }
        .padding(10)
        .background(Color.orange.opacity(0.08))
        .cornerRadius(10)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

// MARK: - 下载历史行
struct DownloadHistoryRow: View {
    let item: VideoDownloadController.DownloadItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.isCompleted
                  ? "checkmark.circle.fill"
                  : "arrow.down.circle")
                .font(.system(size: 12))
                .foregroundColor(item.isCompleted ? .green : .white.opacity(0.4))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 11))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(item.format.rawValue)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.35))
            }

            Spacer()

            if item.isCompleted, let path = item.filePath {
                Button(action: {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }) {
                    Image(systemName: "folder")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Color.white.opacity(0.03))
        .cornerRadius(6)
    }
}
