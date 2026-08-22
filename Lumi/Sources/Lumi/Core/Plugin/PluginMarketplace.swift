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

    /// 官方源清单地址（可由维护者更新）。市场源设置页需展示，故非 private。
    let officialFeedURL = URL(string:
        "https://raw.githubusercontent.com/cpufreestyle/Lumi/main/Lumi/plugin-feed.json")

    /// 市场分类（用于 UI 分段筛选）
    static let categories = ["全部", "工具", "效率", "娱乐", "其它"]

    /// 已安装插件（来自 PluginDiscovery，便于判断「已装/未装」）
    @Published var installed: [PluginManifest] = []
    /// 市场可安装清单（合并所有启用源；按 id 去重，后加载的源优先）
    @Published var available: [PluginManifest] = []
    /// 拉取状态
    @Published var feedStatus: FeedStatus = .idle
    /// 每个插件 id 的安装进度（0~1），nil 表示未在安装
    @Published var installProgress: [String: Double] = [:]
    /// 每个插件 id 的安装状态
    @Published var installState: [String: InstallState] = [:]
    /// 有可用更新的插件（feed 版本比本地已安装更新），id -> feed 中的最新清单
    @Published var updatesAvailable: [String: PluginManifest] = [:]
    /// 社区源（用户自定义 feed URL），官方源恒启用，不在该列表内
    @Published var customSources: [URL] = []
    /// 是否启用社区源总开关（关闭则只拉官方源）
    @Published var communitySourcesEnabled: Bool = false

    private let customSourcesKey = "lumi_plugin_custom_sources"
    private let communityEnabledKey = "lumi_plugin_community_enabled"

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
        // 读取持久化的社区源设置
        if let arr = UserDefaults.standard.array(forKey: customSourcesKey) as? [String] {
            customSources = arr.compactMap { URL(string: $0) }
        }
        communitySourcesEnabled = UserDefaults.standard.bool(forKey: communityEnabledKey)
        // 同步已安装列表
        super.init()
        refreshInstalled()
    }

    /// 持久化社区源设置
    func persistSources() {
        UserDefaults.standard.set(customSources.map { $0.absoluteString },
                                  forKey: customSourcesKey)
        UserDefaults.standard.set(communitySourcesEnabled, forKey: communityEnabledKey)
    }

    /// 启用/关闭社区源总开关
    func setCommunitySourcesEnabled(_ on: Bool) {
        communitySourcesEnabled = on
        persistSources()
        loadFeed()
    }

    /// 添加自定义社区源
    func addCustomSource(_ url: URL) {
        guard !customSources.contains(url) else { return }
        customSources.append(url)
        persistSources()
        loadFeed()
    }

    /// 移除自定义社区源
    func removeCustomSource(_ url: URL) {
        customSources.removeAll { $0 == url }
        persistSources()
        loadFeed()
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

    /// 当前应拉取的所有源（官方源恒在；社区源开启时追加自定义源）
    private var activeSources: [URL] {
        var src = [URL]()
        if let official = officialFeedURL { src.append(official) }
        if communitySourcesEnabled { src.append(contentsOf: customSources) }
        return src
    }

    func loadFeed(silent: Bool = false) {
        if !silent { feedStatus = .loading }

        let sources = activeSources
        guard !sources.isEmpty else {
            loadLocalFeed()
            return
        }

        // 并发拉取所有启用源，合并去重（后加载的源优先级更高，覆盖同 id）
        let group = DispatchGroup()
        // URLSession 回调各自在后台线程执行，多源并发返回时 collected 的
        // append 必须加锁保护，否则是无锁并发写数组（数据竞争）。
        let collectLock = NSLock()
        var collected: [[PluginManifest]] = []
        for url in sources {
            group.enter()
            let task = session.dataTask(with: url) { data, _, _ in
                defer { group.leave() }
                if let data = data,
                   let feed = try? JSONDecoder().decode(PluginFeed.self, from: data) {
                    collectLock.lock()
                    collected.append(feed.plugins)
                    collectLock.unlock()
                }
            }
            task.resume()
        }
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            var merged: [String: PluginManifest] = [:]
            for list in collected {
                for p in list { merged[p.id] = p }
            }
            if merged.isEmpty {
                // 所有远程源都失败 → 回退内置离线清单
                self.loadLocalFeed()
                return
            }
            self.available = Array(merged.values).sorted { $0.name < $1.name }
            self.feedStatus = .ready
            self.refreshInstalled()
            self.checkUpdates()
        }
    }

    /// 比对已安装插件与市场的版本，标记可更新的项
    func checkUpdates() {
        var updates: [String: PluginManifest] = [:]
        for item in available {
            if let local = installed.first(where: { $0.id == item.id }),
               let lv = local.version, let fv = item.version,
               PluginManifest.isVersion(fv, newerThan: lv) {
                updates[item.id] = item
            }
        }
        updatesAvailable = updates
    }

    /// 内置清单可能位于三处：SwiftPM 资源包（Bundle.module）、
    /// .app/Contents/Resources 平铺副本、或 Resources 子目录。逐一尝试。
    private var builtinFeedURL: URL? {
        if let u = Bundle.module.url(forResource: "plugin-feed", withExtension: "json") {
            return u
        }
        if let u = Bundle.main.url(forResource: "plugin-feed", withExtension: "json") {
            return u
        }
        return Bundle.main.url(forResource: "plugin-feed", withExtension: "json",
                               subdirectory: "Resources")
    }

    /// 回退：从 App 包内 plugin-feed.json 读取（保证离线可演示）
    private func loadLocalFeed() {
        guard let url = builtinFeedURL,
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
                installState[plugin.id] = InstallState.none
                refreshInstalled()
                return
            }
            if let name = plugin.appName, appURL.lastPathComponent == name {
                try? fm.removeItem(at: appURL)
                installState[plugin.id] = InstallState.none
                refreshInstalled()
                return
            }
        }
    }

    // MARK: - 内部：完成下载后处理

    private func finishInstall(pluginID: String, manifest: PluginManifest?, location: URL) {
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

            // 找到解压出的 .app（兼容坏包：zip 根为 Contents/ 时按清单 appName 补外壳）
            let newApp = try PluginArchive.locateOrWrapApp(
                in: workDir, fallbackAppName: manifest?.appName)

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

// 注意：URLSessionDownloadDelegate 的方法在 URLSession 的后台线程回调，
// 必须 `nonisolated` 才能满足协议（不允许被 @MainActor 隔离）。
// 方法体整体切回主线程（用 @MainActor 闭包）后再访问主线程隔离的属性/方法，
// 保证并发隔离正确，同时消除原 Swift 6 下的跨隔离警告。
extension PluginMarketplace: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask task: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let totalExpected = totalBytesExpectedToWrite
        let written = totalBytesWritten
        Task { @MainActor in
            guard totalExpected > 0,
                  let pid = progressObservers[task] else { return }
            let p = Double(written) / Double(totalExpected)
            installProgress[pid] = p
            if case .downloading = installState[pid] {
                installState[pid] = .downloading(p)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask task: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // URLSession 只保证下载临时文件（CFNetworkDownload_*.tmp）存活到本方法返回；
        // finishInstall 需经 Task 切回主线程执行，届时临时文件已被系统回收，
        // 会报「前者不存在」。必须先同步挪到自有临时路径，再异步处理。
        let safeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi_plugin_dl_\(UUID().uuidString).zip")
        do {
            try FileManager.default.moveItem(at: location, to: safeURL)
        } catch {
            do { try FileManager.default.copyItem(at: location, to: safeURL) }
            catch { return } // 文件已丢失，无法挽救
        }
        Task { @MainActor in
            guard let pid = progressObservers[task] else {
                try? FileManager.default.removeItem(at: safeURL)
                return
            }
            progressObservers[task] = nil
            // 坏包自愈需要清单里的 appName 作为 .app 外壳名
            let manifest = available.first { $0.id == pid }
                ?? installed.first { $0.id == pid }
            finishInstall(pluginID: pid, manifest: manifest, location: safeURL)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        // 由 downloadTask 的完成回调处理成功路径；此处仅处理真实错误
        Task { @MainActor in
            guard let pid = progressObservers.first(where: { $0.key == task })?.value,
                  let error = error else { return }
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return }
            installState[pid] = .failed(error.localizedDescription)
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
