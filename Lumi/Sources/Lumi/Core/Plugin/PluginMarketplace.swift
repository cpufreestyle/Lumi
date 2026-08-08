import Foundation
import AppKit
import Combine

/// 插件市场（Phase 1）。
///
/// 从「官方源」JSON 拉取可安装插件清单，支持一键下载安装 / 卸载。
/// 安装流程复用 Updater 的思路：下载 .zip → ditto 解压 → 去隔离标记 →
/// 放入 ~/Library/Application Support/Lumi/Plugins/ → 触发重新扫描。
///
/// 设计取舍：
/// - 官方源为可信 JSON（由 Lumi 维护者托管），不做签名校验（TODO: v1.2 加校验）。
/// - 社区源默认关闭；本 Phase 仅实现官方源，社区源接口预留 `enabledSources`。
@MainActor
final class PluginMarketplace: NSObject, ObservableObject {
    static let shared = PluginMarketplace()

    /// 官方源清单地址（可由维护者更新）。
    /// 占位为 GitHub raw，实际部署时替换为你的官方清单。
    private let officialFeedURL = URL(string:
        "https://raw.githubusercontent.com/cpufreestyle/Lumi/main/Lumi/plugin-feed.json")

    /// 已安装插件（来自 PluginDiscovery，便于判断「已装/未装」）
    @Published var installed: [PluginManifest] = []
    /// 市场可安装清单
    @Published var available: [PluginManifest] = []
    /// 拉取状态
    @Published var feedStatus: FeedStatus = .idle
    /// 每个插件 id 的安装进度（0~1），nil 表示未在安装
    @Published var installProgress: [String: Double] = [:]
    /// 每个插件 id 的安装状态
    @Published var installState: [String: InstallState] = [:]

    enum FeedStatus: Equatable {
        case idle, loading, ready, failed(String)
    }

    enum InstallState: Equatable {
        case none
        case downloading(Double)
        case installing
        case installed
        case failed(String)
    }

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    private var downloadContinuations:
        [URLSessionDownloadTask: CheckedContinuation<URL, Error>] = [:]
    private var progressObservers:
        [URLSessionDownloadTask: String] = [:]   // task -> plugin id

    private let pluginsDir: URL = {
        let base = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory,
                                                       .userDomainMask, true).first
                   ?? NSHomeDirectory() + "/Library/Application Support"
        return URL(fileURLWithPath: (base as NSString)
            .appendingPathComponent("Lumi/Plugins"))
    }()

    private override init() {
        // 同步已安装列表
        super.init()
        refreshInstalled()
    }

    // MARK: - 已安装同步

    func refreshInstalled() {
        PluginDiscovery.shared.scan()
        self.installed = PluginDiscovery.shared.plugins
        // 修正已安装插件的安装态
        for p in installed {
            if installState[p.id] == nil {
                installState[p.id] = .installed
            }
        }
    }

    /// 某插件是否已安装（按 id 匹配）
    func isInstalled(_ plugin: PluginManifest) -> Bool {
        installed.contains { $0.id == plugin.id }
    }

    // MARK: - 拉取市场清单

    func loadFeed(silent: Bool = false) {
        if !silent { feedStatus = .loading }

        // 优先远程官方源；失败/超时则回退到 App 内置的 plugin-feed.json（离线可用）
        if let url = officialFeedURL {
            let task = session.dataTask(with: url) { [weak self] data, resp, err in
                guard let self = self else { return }
                if let data = data,
                   let feed = try? JSONDecoder().decode(PluginFeed.self, from: data) {
                    DispatchQueue.main.async {
                        self.available = feed.plugins
                        self.feedStatus = .ready
                        self.refreshInstalled()
                    }
                } else {
                    self.loadLocalFeed()
                }
            }
            task.resume()
        } else {
            loadLocalFeed()
        }
    }

    /// 回退：从 App 包内 plugin-feed.json 读取（保证离线可演示）
    private func loadLocalFeed() {
        guard let url = Bundle.main.url(forResource: "plugin-feed", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let feed = try? JSONDecoder().decode(PluginFeed.self, from: data) else {
            DispatchQueue.main.async { self.feedStatus = .failed("无法读取内置插件清单") }
            return
        }
        DispatchQueue.main.async {
            self.available = feed.plugins
            self.feedStatus = .ready
            self.refreshInstalled()
        }
    }

    // MARK: - 安装

    /// 从市场一键安装插件：下载 zip → 解压 → 去隔离 → 移入 Plugins → 重新扫描
    func install(_ plugin: PluginManifest) {
        guard let url = plugin.downloadURL else {
            installState[plugin.id] = .failed("缺少下载地址")
            return
        }
        installState[plugin.id] = .downloading(0)
        installProgress[plugin.id] = 0

        let task = session.downloadTask(with: url)
        progressObservers[task] = plugin.id
        task.resume()
    }

    /// 卸载已安装插件（按 id 在 Plugins 目录定位并删除 .app）
    func uninstall(_ plugin: PluginManifest) {
        let fm = FileManager.default
        // 按 bundle id 或 appName 匹配
        let candidates = (try? fm.contentsOfDirectory(at: pluginsDir,
                includingPropertiesForKeys: nil)) ?? []
        for appURL in candidates where appURL.pathExtension == "app" {
            let info = appURL.appendingPathComponent("Contents/Info.plist")
            if let dict = NSDictionary(contentsOf: info),
               let bid = dict["CFBundleIdentifier"] as? String,
               bid == plugin.id {
                try? fm.removeItem(at: appURL)
                installState[plugin.id] = .none
                refreshInstalled()
                return
            }
            if let name = plugin.appName, appURL.lastPathComponent == name {
                try? fm.removeItem(at: appURL)
                installState[plugin.id] = .none
                refreshInstalled()
                return
            }
        }
    }

    // MARK: - 内部：完成下载后处理

    private func finishInstall(pluginID: String, location: URL) {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory
            .appendingPathComponent("lumi_plugin_install_\(pluginID)")
        do {
            try? fm.removeItem(at: workDir)
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
            let zipURL = workDir.appendingPathComponent("plugin.zip")
            try fm.moveItem(at: location, to: zipURL)

            // 解压
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            proc.arguments = ["-x", "-k", zipURL.path, workDir.path]
            try proc.run(); proc.waitUntilExit()
            guard proc.terminationStatus == 0 else {
                throw NSError(domain: "marketplace", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "解压失败"])
            }

            // 找到解压出的 .app
            let apps = (try? fm.contentsOfDirectory(at: workDir,
                    includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "app" } ?? []
            guard let newApp = apps.first else {
                throw NSError(domain: "marketplace", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "压缩包内无 .app"])
            }

            // 去隔离标记（与 Updater 一致）
            let xattr = Process()
            xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            xattr.arguments = ["-dr", "com.apple.quarantine", newApp.path]
            try? xattr.run(); xattr.waitUntilExit()

            try fm.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
            let dest = pluginsDir.appendingPathComponent(newApp.lastPathComponent)
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: newApp, to: dest)

            DispatchQueue.main.async { [weak self] in
                self?.installState[pluginID] = .installed
                self?.installProgress[pluginID] = 1
                self?.refreshInstalled()
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.installState[pluginID] = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - 下载 delegate

extension PluginMarketplace: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask task: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0,
              let pid = progressObservers[task] else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { [weak self] in
            self?.installProgress[pid] = p
            if case .downloading = self?.installState[pid] ?? .none {
                self?.installState[pid] = .downloading(p)
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask task: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let pid = progressObservers[task] else { return }
        progressObservers[task] = nil
        finishInstall(pluginID: pid, location: location)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        // 由 downloadTask 的完成回调处理成功路径；此处仅处理真实错误
        guard let pid = progressObservers.first(where: { $0.key == task })?.value,
              let error = error else { return }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return }
        DispatchQueue.main.async { [weak self] in
            self?.installState[pid] = .failed(error.localizedDescription)
        }
    }
}

// MARK: - 市场清单结构

/// 官方源 JSON 顶层结构
struct PluginFeed: Codable {
    /// 清单格式版本
    let schemaVersion: Int?
    /// 插件列表
    let plugins: [PluginManifest]
}
