import Foundation
import AppKit

/// 本地插件发现管理器（Phase 0）。
///
/// 扫描以下位置，读取每个 .app 内的 `Contents/Resources/lumi-plugin.json`，
/// 自动将第三方 macOS 应用挂载为 Lumi 插件（L1 URL Scheme 唤起）：
/// - /Applications
/// - /System/Applications（跳过，系统应用一般不带 manifest）
/// - ~/Applications
/// - ~/Library/Application Support/Lumi/Plugins（市场下载目录）
///
/// 同时支持"仅声明 scheme 的内置白名单"，方便无 manifest 的 app 也能一键唤起。
@MainActor
final class PluginDiscovery: ObservableObject {
    static let shared = PluginDiscovery()

    @Published private(set) var plugins: [PluginManifest] = []

    /// 扫描目录（按要求顺序）
    private let scanDirs: [String] = {
        var dirs = ["/Applications", NSHomeDirectory() + "/Applications"]
        if let support = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory,
                                                             .userDomainMask, true).first {
            dirs.append((support as NSString).appendingPathComponent("Lumi/Plugins"))
        }
        return dirs
    }()

    /// 无 manifest 也可接入的内置 scheme 白名单（L1 极简）。
    /// 开发者无需写 json，只要 app 注册了 URL Scheme 即可在此登记入口。
    private let schemeWhitelist: [PluginManifest] = [
        // 示例：如果有 Bartender 并注册了 bartender:// scheme，可在此启用
        // PluginManifest(id: "com.surtees-studios.bartender", name: "Bartender",
        //               iconName: "menubar.dock.rectangle", urlScheme: "bartender", appName: "Bartender.app"),
    ]

    /// 执行一次扫描
    func scan() {
        var found: [PluginManifest] = []
        var seen = Set<String>()

        for dir in scanDirs {
            let url = URL(fileURLWithPath: dir)
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }

            for appURL in contents where appURL.pathExtension == "app" {
                guard let manifest = PluginDiscovery.manifest(in: appURL.path),
                      !seen.contains(manifest.id) else { continue }
                seen.insert(manifest.id)
                var m = manifest
                m.bundlePath = appURL.path
                m.source = .local(appPath: appURL.path)
                found.append(m)
            }
        }

        // 合并白名单（未重复时补充）
        for w in schemeWhitelist where !seen.contains(w.id) {
            seen.insert(w.id)
            found.append(w)
        }

        found.sort { $0.resolvedName.localizedCaseInsensitiveCompare($1.resolvedName) == .orderedAscending }
        self.plugins = found

        // L3：把带 panel 标志的插件交给 PluginPanelBridge 轮询其面板数据
        let panelIDs = found.filter { $0.panel }.map { $0.id }
        PluginPanelBridge.shared.watch(panelIDs)
    }

    /// 从 .app 包内读取 lumi-plugin.json
    static func manifest(in appPath: String) -> PluginManifest? {
        let resDir = (appPath as NSString).appendingPathComponent("Contents/Resources")
        let jsonPath = (resDir as NSString).appendingPathComponent("lumi-plugin.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: jsonPath)) else { return nil }
        guard let m = try? JSONDecoder().decode(PluginManifest.self, from: data) else { return nil }
        return m
    }

    /// 唤起插件（L1：URL Scheme；若 .app 存在可直接 open）
    @discardableResult
    func launch(_ plugin: PluginManifest) -> Bool {
        // 优先 URL Scheme
        if let scheme = plugin.urlScheme, !scheme.isEmpty,
           let url = URL(string: "\(scheme)://") {
            NSWorkspace.shared.open(url)
            return true
        }
        // 回退：直接 open .app
        if let path = plugin.bundlePath, !path.isEmpty {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return true
        }
        if let app = plugin.appName, !app.isEmpty {
            let cfg = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/\(app)"),
                                              configuration: cfg) { _, _ in }
            return true
        }
        return false
    }
}
