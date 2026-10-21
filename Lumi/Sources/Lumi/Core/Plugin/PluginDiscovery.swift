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

    /// 上一次扫描的目录签名（各目录的 mtime + .app 条目数），用于跳过无变化的重复扫描。
    /// 装/卸插件会触发 refreshInstalled → scan，若每次都全量读 manifest，
    /// 在 /Applications 有上百个 app 的机器上会明显卡顿灵动岛 UI。
    /// 目录签名：mtime 与条目数分别存，不做任何压缩。
    /// 早先的实现把两者位运算压成一个 Int，同一秒内增删各一个 app 会撞签名，
    /// 虽然实际概率极低，但没必要为省一个结构体引入这种边界。
    private struct DirSignature: Equatable {
        let mtime: TimeInterval
        let count: Int
    }

    private var lastSignature: [String: DirSignature] = [:]

    /// 计算当前扫描目录的签名（目录 mtime 与条目数，足够便宜且能覆盖增删）。
    private func directorySignature() -> [String: DirSignature] {
        var sig: [String: DirSignature] = [:]
        let fm = FileManager.default
        for dir in scanDirs {
            let attrs = try? fm.attributesOfItem(atPath: dir)
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let count = (try? fm.contentsOfDirectory(atPath: dir))?.count ?? 0
            sig[dir] = DirSignature(mtime: mtime, count: count)
        }
        return sig
    }

    /// 执行一次扫描。目录签名未变化时直接返回，不重复读盘。
    func scan() {
        let sig = directorySignature()
        if sig == lastSignature, !plugins.isEmpty { return }
        lastSignature = sig
        scanAll()
    }

    /// 强制全量扫描（跳过签名缓存），供用户手动刷新使用。
    func rescan() {
        lastSignature = [:]
        scanAll()
    }

    private func scanAll() {
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

        // 诊断：打印扫描到的插件（临时，便于排查标签栏不显示插件的问题）
        PluginLog.info("扫描完成 发现 " + String(found.count) + " 个插件："
            + found.map { $0.id + (($0.panel) ? "(panel)" : "") }.joined(separator: ", ")
            + " 扫描目录=" + scanDirs.joined(separator: " | "))

        // L3：把带 panel 标志的插件交给 PluginPanelBridge 轮询其面板数据
        let panelIDs = found.filter { $0.panel }.map { $0.id }
        if !panelIDs.isEmpty { PluginLog.info("注册面板监听 " + String(panelIDs.count) + " 个") }
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

    /// 唤起插件。返回 false 表示「没有任何可用入口」——scheme、bundlePath、appName 全缺。
    ///
    /// 注意：NSWorkspace.open 成功只说明请求已被系统接受，不代表目标 app 真的起来了
    /// （scheme 未注册会返回 false；注册了 scheme 但 app 不在位这类情况仍可能返回 true）。
    /// 所以这里只把「无入口可走」当失败，open 的结果仅记录到日志供排查。
    @discardableResult
    func launch(_ plugin: PluginManifest) -> Bool {
        if let scheme = plugin.urlScheme, !scheme.isEmpty,
           let url = URL(string: scheme + "://") {
            let ok = NSWorkspace.shared.open(url)
            PluginLog.info("唤起 " + plugin.id + " via scheme=" + scheme + ":// open()=" + String(ok))
            if !ok { PluginLog.warn("open() 返回 false，scheme 可能未被注册：" + scheme) }
            return true
        }
        if let path = plugin.bundlePath, !path.isEmpty {
            let ok = NSWorkspace.shared.open(URL(fileURLWithPath: path))
            PluginLog.info("唤起 " + plugin.id + " via bundlePath=" + path + " open()=" + String(ok))
            return true
        }
        if let app = plugin.appName, !app.isEmpty {
            let target = "/Applications/" + app
            let cfg = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: target),
                                              configuration: cfg) { _, _ in }
            PluginLog.info("唤起 " + plugin.id + " via appName=" + target)
            return true
        }
        PluginLog.warn("无法唤起 " + plugin.id + "：无 urlScheme / bundlePath / appName")
        return false
    }
}
