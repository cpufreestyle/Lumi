import Foundation
import Combine
import AppKit

/// 轻量自研「检查更新」：直接读取 GitHub 仓库最新 Release，
/// 与本地 Info.plist 的 CFBundleShortVersionString 比较，发现新版本时提示用户前往下载。
/// 未签名 App 无法用 Sparkle，这是最务实的自动更新方案（后续可做公证后平滑升级到 Sparkle）。
final class Updater: ObservableObject {
    static let shared = Updater()

    /// 仓库坐标（与发布脚本 release_v1.1.x.sh 中 gh release 对应）
    private let repo = "cpufreestyle/Lumi"

    @Published var status: UpdateStatus = .idle
    /// 最新 Release 的版本字符串（不含 v，如 "1.1.5"）
    @Published var latestVersion: String?
    /// 最新 Release 的下载/说明页
    @Published var releaseURL: URL?
    /// 用户已选择忽略的版本（本次会话内不再弹窗；跨会话记忆在 UserDefaults）
    @Published var ignoredVersion: String?

    private let ignoredKey = "lumi_updater_ignored_version"
    private var checkTask: URLSessionDataTask?

    enum UpdateStatus: Equatable {
        case idle          // 未检查
        case checking      // 检查中
        case upToDate      // 已是最新
        case available     // 有新版本
        case failed(String)// 检查失败（网络/解析）
    }

    private init() {
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
            // 仅当确实发现新版本且未被忽略时才把状态置为 available（供弹窗使用）
            if case .available = self.status, self.latestVersion == self.ignoredVersion {
                self.status = .upToDate
            }
        }
    }

    /// 手动触发检查（按钮调用）。如需强制忽略提示，传 force=true。
    func checkForUpdates(force: Bool = false) {
        if case .checking = status { return }
        fetchLatest { [weak self] in
            guard let self = self else { return }
            if !force, case .available = self.status, self.latestVersion == self.ignoredVersion {
                self.status = .upToDate
            }
        }
    }

    /// 忽略当前检测到的版本（不再弹窗提示）
    func ignoreCurrent() {
        guard let v = latestVersion else { return }
        ignoredVersion = v
        UserDefaults.standard.set(v, forKey: ignoredKey)
        if case .available = status { status = .upToDate }
    }

    /// 打开最新 Release 下载/说明页
    func openRelease() {
        guard let url = releaseURL else { return }
        NSWorkspace.shared.open(url)
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
        if isNewer(latest, than: currentVersion) {
            status = .available
        } else {
            status = .upToDate
        }
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
