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

    /// 启动时静默自动检查一次。
    func autoCheckOnLaunch() {
        fetchLatest { [weak self] in
            guard let self = self else { return }
            self.suppressIfHandled()
        }
    }

    /// 手动触发检查（按钮调用）。如需强制忽略提示，传 force=true。
    func checkForUpdates(force: Bool = false) {
        if case .checking = status { return }
        if case .downloading = status { return }
        fetchLatest { [weak self] in
            guard let self = self else { return }
            if !force { self.suppressIfHandled() }
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
        guard let v = latestVersion else { return }
        ignoredVersion = v
        UserDefaults.standard.set(v, forKey: ignoredKey)
        if case .available = status { status = .upToDate }
    }

    /// 本次会话「稍后」：不再自动提示，但重启后仍会提示该版本
    func skipCurrent() {
        guard let v = latestVersion else { return }
        skippedVersion = v
        if case .available = status { status = .upToDate }
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
    func downloadAndInstall() {
        guard let url = downloadURL else {
            // 没有可用下载地址，回退到网页
            openRelease()
            return
        }
        guard case .available = status else { return }
        status = .downloading(0)
        let task = session.downloadTask(with: url)
        downloadTask = task
        task.resume()
    }

    // MARK: - 网络

    private func fetchLatest(completion: @escaping () -> Void) {
        status = .checking
        let urlString = "https://api.github.com/repos/\(repo)/releases/latest"
        guard let url = URL(string: urlString) else {
            status = .failed("无效的更新地址")
            completion()
            return
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        checkTask?.cancel()
        let task = URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            guard let self = self else { return }
            DispatchQueue.main.async {
                defer { completion() }
                if let err = err {
                    // 用户取消不视为失败
                    if (err as NSError).domain == NSURLErrorDomain,
                       (err as NSError).code == NSURLErrorCancelled { return }
                    self.status = .failed("网络错误：\(err.localizedDescription)")
                    return
                }
                guard let data = data else {
                    self.status = .failed("无更新数据")
                    return
                }
                self.parse(data: data)
            }
        }
        checkTask = task
        task.resume()
    }

    private func parse(data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            status = .failed("更新信息解析失败")
            return
        }
        // GitHub 在未发布任何 Release 或鉴权问题时可能返回 message 字段
        if let message = obj["message"] as? String {
            status = .failed("GitHub：\(message)")
            return
        }
        guard let tag = obj["tag_name"] as? String else {
            status = .failed("缺少版本号")
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
