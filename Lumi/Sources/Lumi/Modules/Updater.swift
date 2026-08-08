import Foundation
import Combine
import AppKit

/// 轻量自研「检查更新」：直接读取 GitHub 仓库最新 Release，
/// 与本地 Info.plist 的 CFBundleShortVersionString 比较，发现新版本时提示用户更新。
/// 支持「自动下载并安装」：后台拉取 Release 的 .app zip，解压后由一次性脚本在旧进程退出后
/// 替换并重启，全程无需用户手动去网页下载；同时保留「稍后 / 忽略此版本」等取消选项（非强制）。
/// 未签名 App 无法用 Sparkle，这是最务实的自动更新方案（后续可做公证后平滑升级到 Sparkle）。
final class Updater: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = Updater()

    /// 仓库坐标（与发布脚本 release_v1.1.x.sh 中 gh release 对应）
    private let repo = "cpufreestyle/Lumi"

    @Published var status: UpdateStatus = .idle
    /// 最新 Release 的版本字符串（不含 v，如 "1.1.5"）
    @Published var latestVersion: String?
    /// 最新 Release 的下载/说明页
    @Published var releaseURL: URL?
    /// 最新 Release 中 .app 压缩包的下载地址（用于自动下载安装）
    @Published var downloadURL: URL?
    /// 用户已选择忽略的版本（跨会话记忆在 UserDefaults，不再提示）
    @Published var ignoredVersion: String?
    /// 用户选择「稍后」的版本（仅本次会话内不自动提示，重启后仍会提示）
    @Published var skippedVersion: String?
    /// 手动检查后的明确反馈文字（无论结果如何都短暂显示，让用户确认点击生效）。
    /// 为 nil 时不显示；由 checkForUpdates 在完成时赋值，几秒后自动清空。
    @Published var manualCheckFeedback: String?

    private let ignoredKey = "lumi_updater_ignored_version"
    private var checkTask: URLSessionDataTask?
    private var downloadTask: URLSessionDownloadTask?
    /// 自带 session 并以 self 为 delegate，才能收到下载进度/完成回调
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    enum UpdateStatus: Equatable {
        case idle            // 未检查
        case checking        // 检查中
        case upToDate        // 已是最新
        case available       // 有新版本（待用户选择）
        case downloading(Double) // 自动下载中，参数为进度 0~1
        case readyToInstall  // 下载完成，即将替换重启
        case failed(String)  // 检查/下载失败（网络/解析/安装）

        static func == (lhs: UpdateStatus, rhs: UpdateStatus) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle),
                 (.checking, .checking),
                 (.upToDate, .upToDate),
                 (.available, .available),
                 (.readyToInstall, .readyToInstall):
                return true
            case (.downloading(let a), .downloading(let b)):
                return a == b
            case (.failed(let a), .failed(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    private override init() {
        super.init()
        self.ignoredVersion = UserDefaults.standard.string(forKey: ignoredKey)
    }

    /// 当前安装版本（来自 Info.plist），如 "1.1.5"
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// 两次自动检查之间的最小间隔（秒）：1 小时内不重复请求 GitHub，复用上次结果，
    /// 避免匿名 API 的 60 次/小时限流被频繁触发。
    private let autoCheckMinInterval: TimeInterval = 3600
    /// 上次成功/失败检查的时间戳（持久化）
    private let lastCheckKey = "lumi_updater_last_check"
    private var lastCheckTime: Date {
        get { UserDefaults.standard.object(forKey: lastCheckKey) as? Date ?? .distantPast }
        set { UserDefaults.standard.set(newValue, forKey: lastCheckKey) }
    }

    /// 启动时静默自动检查一次（受时间间隔与限流保护）。
    /// 任何失败都静默降级为「已是最新」，不弹红色浮层。
    func autoCheckOnLaunch() {
        // 距上次检查不足间隔：直接沿用既有结果（不发起网络请求）
        if Date().timeIntervalSince(lastCheckTime) < autoCheckMinInterval {
            return
        }
        fetchLatest(silent: true) { [weak self] in
            guard let self = self else { return }
            self.lastCheckTime = Date()
            self.suppressIfHandled()
        }
    }

    /// 手动触发检查（按钮调用）。如需强制忽略提示，传 force=true。
    /// 手动检查不静默：失败会显示红字提示，便于用户感知。
    func checkForUpdates(force: Bool = false) {
        if case .checking = status { return }
        if case .downloading = status { return }
        log("手动检查开始 (force=\(force), 当前版本=\(currentVersion))")
        fetchLatest(silent: false) { [weak self] in
            guard let self = self else { return }
            self.lastCheckTime = Date()
            if !force { self.suppressIfHandled() }
            // 手动检查一定给出明确反馈：有新版本走 available 浮层；
            // 已是最新/失败也用 manualCheckFeedback 短暂提示，避免「点了没反应」。
            switch self.status {
            case .available:
                self.manualCheckFeedback = "发现新版本 v\(self.latestVersion ?? "")"
                self.log("手动检查：发现新版本 v\(self.latestVersion ?? "")")
            case .upToDate:
                self.manualCheckFeedback = "已是最新版本 v\(self.currentVersion)"
                self.log("手动检查：已是最新 v\(self.currentVersion)")
            case .failed(let m):
                self.manualCheckFeedback = "检查失败：\(m)"
                self.log("手动检查：失败 \(m)")
            default:
                break
            }
            // 3 秒后清空反馈（不阻塞浮层；available/failed 浮层由 status 继续驱动）
            if self.manualCheckFeedback != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    self.manualCheckFeedback = nil
                }
            }
        }
    }

    /// 若当前版本已被忽略或本次会话已「稍后」，则把 available 降级为 upToDate（不弹窗）。
    private func suppressIfHandled() {
        guard case .available = status, let latest = latestVersion else { return }
        if latest == ignoredVersion || latest == skippedVersion {
            status = .upToDate
        }
    }

    /// 忽略当前检测到的版本（跨会话记忆，不再弹窗）
    func ignoreCurrent() {
        if let v = latestVersion {
            ignoredVersion = v
            UserDefaults.standard.set(v, forKey: ignoredKey)
        }
        // 无论是否有版本号，点「忽略」都应隐藏当前提示（含失败态）
        if case .available = status { status = .upToDate }
        if case .failed = status { status = .upToDate }
    }

    /// 本次会话「稍后」：不再自动提示，但重启后仍会提示该版本
    func skipCurrent() {
        if let v = latestVersion { skippedVersion = v }
        // 失败/可用状态下点「关闭」都应隐藏提示。
        // 注意：即使 latestVersion 为 nil（如解析/网络失败）也要能关闭，
        // 否则失败提示会永远卡住无法消除。
        if case .available = status { status = .upToDate }
        if case .failed = status { status = .upToDate }
    }

    /// 直接关闭更新提示浮层（无论当前处于 available / failed / downloading 等状态）。
    /// 用于浮层上的「×」关闭按钮，确保一定能关掉，不会卡死。
    func dismiss() {
        status = .upToDate
    }

    /// 打开最新 Release 下载/说明页（自动安装失败时的兜底入口）
    func openRelease() {
        guard let url = releaseURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// 取消当前下载（保留会话，状态回到 available 供用户重新选择）
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        if case .downloading = status { status = .available }
    }

    /// 自动下载并安装最新版本：后台拉取 .app 压缩包，解压后由一次性脚本在旧进程退出后
    /// 替换并重启。整个流程对用户透明，无需手动下载；失败则回退到「前往下载」网页。
    /// 若 downloadURL 尚未就绪（HTML 路径异步抓取可能未完成），会先补抓一次，
    /// 拿到地址后再开始下载，而不是直接跳网页，避免「点了更新却打开 GitHub」。
    func downloadAndInstall() {
        guard case .available = status else { return }
        // 已有可用下载地址：直接开始下载
        if let url = downloadURL {
            startDownload(from: url)
            return
        }
        // 没有下载地址：先尝试从当前 Release 页面解析 zip 链接，拿到后再下载
        status = .downloading(0)
        log("更新并重启：downloadURL 缺失，先解析压缩包地址（tag=\(latestVersion ?? "?")，releaseURL=\(releaseURL?.absoluteString ?? "nil")）")
        guard let htmlURL = releaseURL,
              let tag = latestVersion else {
            log("更新并重启：缺少 releaseURL 或版本号，回退网页")
            status = .available
            openRelease()
            return
        }
        let assetsURLString = "https://github.com/\(repo)/releases/expanded_assets/\(tag)"
        guard let assetsURL = URL(string: assetsURLString) else {
            status = .available
            openRelease()
            return
        }
        var req = URLRequest(url: assetsURL, timeoutInterval: 15)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self else { return }
            if let html = data, let dl = self.extractZipURL(from: html, tag: tag) {
                DispatchQueue.main.async {
                    self.downloadURL = dl
                    self.log("更新并重启：解析到下载地址 \(dl.absoluteString)，开始下载")
                    self.startDownload(from: dl)
                }
            } else {
                self.log("更新并重启：解析压缩包地址失败，回退网页")
                DispatchQueue.main.async {
                    self.status = .available
                    self.openRelease()
                }
            }
        }.resume()
    }

    /// 真正发起下载任务
    private func startDownload(from url: URL) {
        guard case .available = status else { return }
        status = .downloading(0)
        let task = session.downloadTask(with: url)
        downloadTask = task
        task.resume()
    }

    // MARK: - 网络

    /// 拉取最新版本信息。
    /// - 优先请求 GitHub Release 的 HTML 页面（github.com/.../releases/latest），
    ///   该页面会 302 重定向到带版本号的 URL，不受 api.github.com 匿名 60 次/小时限流约束。
    /// - HTML 解析失败（如无网络）再回退到 api.github.com JSON（仍可能被限流）。
    /// - silent=true 时，任何失败都静默降级（不弹红字），用于启动自动检查。
    private func fetchLatest(silent: Bool, completion: @escaping () -> Void) {
        status = .checking
        // 1) 优先走 HTML 页面（重定向暴露版本号）
        let htmlURLString = "https://github.com/\(repo)/releases/latest"
        guard let htmlURL = URL(string: htmlURLString) else {
            status = .failed("无效的更新地址")
            completion()
            return
        }
        var htmlReq = URLRequest(url: htmlURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // 用 delegate 拦截重定向：不自动跟随，从而保留 302 Location 头取版本号
        let htmlSession = URLSession(configuration: config, delegate: RedirectCapturingDelegate(), delegateQueue: nil)

        log("HTML 检查：请求 \(htmlURLString)")
        htmlSession.dataTask(with: htmlReq) { [weak self] _, resp, err in
            guard let self = self else { return }
            if let error = err {
                self.log("HTML 检查失败：\(error.localizedDescription)，回退 API")
            }
            if let http = resp as? HTTPURLResponse {
                // 302 -> Location 形如 .../releases/tag/v1.1.7
                if let loc = http.allHeaderFields["Location"] as? String,
                   let url = URL(string: loc),
                   let tag = self.versionFromReleasesURL(url) {
                    self.log("HTML 302 重定向 → \(loc)，版本=\(tag)")
                    DispatchQueue.main.async {
                        self.applyLatest(tag: tag, htmlURL: url)
                        completion()
                    }
                    return
                }
                // 200 且无重定向：可能直接返回了页面（无新版本或解析不到），尝试从页面抓版本
                if let finalURL = http.url, let tag = self.versionFromReleasesURL(finalURL) {
                    self.log("HTML 200 直接解析版本=\(tag)（\(finalURL)）")
                    DispatchQueue.main.async {
                        self.applyLatest(tag: tag, htmlURL: finalURL)
                        completion()
                    }
                    return
                }
                self.log("HTML 检查未解析到版本（HTTP \(http.statusCode)），回退 API")
            }
            // HTML 路径失败：回退到 API（仅当非静默，或无论如何都试一次）
            self.fetchLatestViaAPI(silent: silent, completion: completion)
        }.resume()
    }

    /// 从 github.com/.../releases/tag/vX.Y.Z 这类 URL 取出版本号（去掉前缀 v）。
    private func versionFromReleasesURL(_ url: URL) -> String? {
        let comps = url.pathComponents
        guard let idx = comps.firstIndex(of: "tag"), idx + 1 < comps.count else { return nil }
        let raw = comps[idx + 1]
        return raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
    }

    /// 拿到版本号后统一设置状态与下载地址（下载地址仍取自 Release 资源页，需再请求一次 HTML 拿 zip 链接）。
    private func applyLatest(tag: String, htmlURL: URL) {
        let latest = tag
        latestVersion = latest
        releaseURL = htmlURL
        // Release 资源里的 .app 压缩包下载地址：从 .../releases/tag/vX 拼出 /expanded_assets/vX
        // 这里简单粗暴：用 tag 页的 expanded_assets 路径抓 zip（解析 HTML 中的 .zip 链接）
        let assetsURLString = "https://github.com/\(repo)/releases/expanded_assets/\(tag)"
        if let assetsURL = URL(string: assetsURLString) {
            var req = URLRequest(url: assetsURL, timeoutInterval: 15)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
                guard let self = self else { return }
                if let html = data, let dl = self.extractZipURL(from: html, tag: tag) {
                    DispatchQueue.main.async { self.downloadURL = dl }
                }
            }.resume()
        }
        if isNewer(latest, than: currentVersion) {
            status = .available
        } else {
            status = .upToDate
        }
    }

    /// 从 expanded_assets 页面 HTML 中提取 .zip 资源的浏览器下载链接
    private func extractZipURL(from html: Data, tag: String) -> URL? {
        guard let s = String(data: html, encoding: .utf8) else { return nil }
        // 形如 href="/cpufreestyle/Lumi/releases/download/v1.1.7/Lumi-v1.1.7.zip"
        let pattern = #"href="(/[^"]*releases/download/[^"]*\.zip)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            let rel = ns.substring(with: m.range(at: 1))
            if let u = URL(string: "https://github.com" + rel) { return u }
        }
        return nil
    }

    /// 回退方案：api.github.com JSON。仍可能触发匿名限流，故仅在 HTML 失败时调用。
    private func fetchLatestViaAPI(silent: Bool, completion: @escaping () -> Void) {
        let urlString = "https://api.github.com/repos/\(repo)/releases/latest"
        guard let url = URL(string: urlString) else {
            self.failOrSilent(silent: silent, message: "无效的更新地址", completion: completion)
            return
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        checkTask?.cancel()
        log("API 检查：请求 \(urlString)")
        let task = URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            guard let self = self else { return }
            DispatchQueue.main.async {
                defer { completion() }
                if let err = err {
                    // 用户取消不视为失败
                    if (err as NSError).domain == NSURLErrorDomain,
                       (err as NSError).code == NSURLErrorCancelled { return }
                    self.log("API 检查网络错误：\(err.localizedDescription)")
                    self.failOrSilent(silent: silent, message: "网络错误：\(err.localizedDescription)")
                    return
                }
                if let http = resp as? HTTPURLResponse {
                    self.log("API 响应 HTTP \(http.statusCode)")
                }
                guard let data = data else {
                    self.failOrSilent(silent: silent, message: "无更新数据")
                    return
                }
                self.parse(data: data, silent: silent)
            }
        }
        checkTask = task
        task.resume()
    }

    /// 根据 silent 决定失败是弹红字还是静默降级为「已是最新」
    private func failOrSilent(silent: Bool, message: String, completion: (() -> Void)? = nil) {
        if silent {
            status = .upToDate
        } else {
            status = .failed(message)
        }
        log("检查失败/静默：\(message)（silent=\(silent)）")
        completion?()
    }

    private func parse(data: Data, silent: Bool = false) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            failOrSilent(silent: silent, message: "更新信息解析失败")
            return
        }
        // GitHub 在未发布任何 Release 或鉴权问题时可能返回 message 字段（含限流提示）
        if let message = obj["message"] as? String {
            failOrSilent(silent: silent, message: "GitHub：\(message)")
            return
        }
        guard let tag = obj["tag_name"] as? String else {
            failOrSilent(silent: silent, message: "缺少版本号")
            return
        }
        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        latestVersion = latest
        if let html = obj["html_url"] as? String, let u = URL(string: html) {
            releaseURL = u
        }
        // 抓取 Release 资源里的 .app 压缩包（自动下载安装用）
        downloadURL = nil
        if let assets = obj["assets"] as? [[String: Any]] {
            for a in assets {
                guard let name = a["name"] as? String, name.hasSuffix(".zip"),
                      let dl = a["browser_download_url"] as? String,
                      let u = URL(string: dl) else { continue }
                downloadURL = u
                break
            }
        }
        if isNewer(latest, than: currentVersion) {
            status = .available
        } else {
            status = .upToDate
        }
    }

    // MARK: - 下载与安装（URLSessionDownloadDelegate）

    /// 下载进度回调
    func urlSession(_ session: URLSession, downloadTask task: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { [weak self] in
            if case .downloading = self?.status {
                self?.status = .downloading(p)
            }
        }
    }

    /// 下载完成：解压、去隔离标记、生成一次性替换脚本、退出并由脚本完成替换重启
    func urlSession(_ session: URLSession, downloadTask task: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let fm = FileManager.default
        let tmpDir = FileManager.default.temporaryDirectory
        let workDir = tmpDir.appendingPathComponent("lumi_update_\(ProcessInfo.processInfo.processIdentifier)")
        do {
            try? fm.removeItem(at: workDir)
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
            let zipURL = workDir.appendingPathComponent("Lumi.zip")
            try fm.moveItem(at: location, to: zipURL)
            // 解压（-x 解压，--keepParent 保留 Lumi.app 目录）
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            proc.arguments = ["-x", "-k", zipURL.path, workDir.path]
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else {
                throw NSError(domain: "Updater", code: 1, userInfo: [NSLocalizedDescriptionKey: "解压失败"])
            }
            // 定位解压出的 Lumi.app（ditto --keepParent 会保留顶层 Lumi.app）
            let newApp = workDir.appendingPathComponent("Lumi.app")
            guard fm.fileExists(atPath: newApp.path) else {
                throw NSError(domain: "Updater", code: 2, userInfo: [NSLocalizedDescriptionKey: "压缩包内未找到 Lumi.app"])
            }
            // 去除 Gatekeeper 隔离标记，避免未公证 App 替换后无法打开
            let xattr = Process()
            xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            xattr.arguments = ["-dr", "com.apple.quarantine", newApp.path]
            try? xattr.run()
            xattr.waitUntilExit()

            // 生成一次性替换脚本：等旧进程退出后覆盖并重启
            let oldApp = Bundle.main.bundleURL
            let script = Self.replaceScript(oldApp: oldApp.path, newApp: newApp.path)
            let scriptURL = workDir.appendingPathComponent("install.sh")
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

            DispatchQueue.main.async { [weak self] in
                self?.status = .readyToInstall
            }
            // 启动替换脚本（异步，不等待），随后终止当前 App
            let install = Process()
            install.executableURL = URL(fileURLWithPath: "/bin/bash")
            install.arguments = [scriptURL.path]
            try install.run()
            // 给脚本一点时间启动，再退出
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApplication.shared.terminate(nil)
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.status = .failed("安装失败：\(error.localizedDescription)")
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error else { return }
        // 用户取消不视为失败
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return }
        DispatchQueue.main.async { [weak self] in
            self?.status = .failed("下载失败：\(error.localizedDescription)")
        }
    }

    /// 构造一次性替换脚本：轮询等待旧 App 进程退出后，覆盖并重新打开。
    private static func replaceScript(oldApp: String, newApp: String) -> String {
        return """
        #!/bin/bash
        # 等待旧 Lumi 进程退出（最多约 10 秒）
        for i in $(seq 1 50); do
            if ! pgrep -f "\(oldApp)/Contents/MacOS/Lumi" >/dev/null 2>&1; then
                break
            fi
            sleep 0.2
        done
        rm -rf "\(oldApp)"
        mv "\(newApp)" "\(oldApp)"
        xattr -dr com.apple.quarantine "\(oldApp)" 2>/dev/null
        open "\(oldApp)"
        """
    }

    // MARK: - 诊断日志（写入 ~/Library/Logs/Lumi/updater.log，便于排查「检查无反应」）

    private func log(_ msg: String) {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Lumi")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("updater.log")
            let ts = ISO8601DateFormatter().string(from: Date())
            let line = "[\(ts)] \(msg)\n"
            if let handle = try? FileHandle(forWritingTo: file) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                handle.closeFile()
            } else {
                try line.write(to: file, atomically: true, encoding: .utf8)
            }
        } catch { /* 诊断日志写入失败不影响主流程 */ }
    }

    /// 语义化比较：返回 lhs 是否比 rhs 新（按 a.b.c 数字逐段比较）
    private func isNewer(_ lhs: String, than rhs: String) -> Bool {
        let l = lhs.split(separator: ".").compactMap { Int($0) }
        let r = rhs.split(separator: ".").compactMap { Int($0) }
        let count = max(l.count, r.count)
        for i in 0..<count {
            let lv = l.count > i ? l[i] : 0
            let rv = r.count > i ? r[i] : 0
            if lv > rv { return true }
            if lv < rv { return false }
        }
        return false
    }
}

/// 拦截 HTTP 重定向的轻量 delegate：不自动跟随 302，
/// 从而让上层能从响应头读取 Location（含最新版本号），避开 api.github.com 限流。
private final class RedirectCapturingDelegate: NSObject, URLSessionDataDelegate {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // 返回 nil = 不跟随重定向，response 仍会照常回调给 dataTask 的 completion
        completionHandler(nil)
    }
}
