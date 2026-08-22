import Foundation
import Combine

/// L3 深度集成桥接层（Phase 2）。
///
/// 设计原则：**零签名阻力、任何第三方 macOS app 都能接入**。
/// 不依赖 XPC / App Group（需要签名授权文件，对 ad-hoc/免费账号不友好），
/// 改用宿主管理的共享目录 `~/Library/Application Support/Lumi/PluginPanels/`：
/// 第三方插件进程把结构化面板数据写成 `<pluginID>.json`，Lumi 周期性读取并渲染，
/// 像原生模块一样出现在标签栏与展开面板中。
///
/// 第三方只需：
/// 1. 在 `lumi-plugin.json` 声明 `"panel": true`（启用 L3）；
/// 2. 周期性写入 `~/Library/Application Support/Lumi/PluginPanels/<id>.json`，
///    格式见 `PluginPanelData`。Lumi 自动发现、轮询、渲染。

// MARK: - 面板数据模型

/// 单行面板内容（键值 / 文本 / 进度 / 按钮）。
///
/// 用「带 `kind` 字段的 struct」而非关联值 enum，使第三方插件写出的 JSON
/// 直观可读、易对接（见 README L3 章节的示例）。对应 JSON 形态：
/// ```json
/// { "kind": "kv",      "key": "天气", "value": "晴 24°C" }
/// { "kind": "progress","p": 0.5 }
/// { "kind": "button",  "title": "刷新天气" }
/// { "kind": "text",    "value": "一行说明" }
/// ```
struct PluginPanelLine: Codable, Hashable {
    enum Kind: String, Codable { case text, kv, progress, button }
    let kind: Kind
    var key: String?
    var value: String?
    var p: Double?
    var title: String?

    static func text(_ v: String) -> PluginPanelLine {
        PluginPanelLine(kind: .text, value: v)
    }
    static func kv(_ k: String, _ v: String) -> PluginPanelLine {
        PluginPanelLine(kind: .kv, key: k, value: v)
    }
    static func progress(_ v: Double) -> PluginPanelLine {
        PluginPanelLine(kind: .progress, p: v)
    }
    static func button(_ t: String) -> PluginPanelLine {
        PluginPanelLine(kind: .button, title: t)
    }
}

/// 插件要展示在灵动岛面板里的内容。
struct PluginPanelData: Codable, Identifiable, Hashable {
    /// 插件 id（与 manifest 一致，用作文件名与去重键）
    let id: String
    /// 面板标题（默认取 manifest.name）
    var title: String
    /// SF Symbol 图标名（默认取 manifest.iconName）
    var iconName: String
    /// 副标题 / 状态行（可选）
    var subtitle: String?
    /// 结构化行
    var lines: [PluginPanelLine]
    /// 最后更新时间戳（Unix 秒），用于判断陈旧数据
    var updatedAt: TimeInterval

    var isStale: Bool {
        Date().timeIntervalSince1970 - updatedAt > 30
    }
}

// MARK: - 桥接管理

@MainActor
final class PluginPanelBridge: ObservableObject {
    static let shared = PluginPanelBridge()

    /// 已加载的插件面板数据，key = plugin id
    @Published private(set) var panels: [String: PluginPanelData] = [:]

    /// 共享目录（宿主管理，插件可写）
    nonisolated static let panelsDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return base.appendingPathComponent("Lumi/PluginPanels", isDirectory: true)
    }()

    private var timer: Timer?
    /// 面板文件轮询专用后台队列:磁盘读取与 JSON 解码不占主线程,消除每秒一次的主线程 I/O。
    private let pollQueue = DispatchQueue(label: "com.lumi.pluginpanels.poll", qos: .utility)
    /// 当前需要轮询的插件 id 集合（由 PluginDiscovery 扫描带 panel 的插件后设置）
    private var watchedIDs: Set<String> = []

    /// 第三方插件应写入的目录（供文档/示例脚本引用）
    static var panelsDirectoryPath: String { panelsDir.path }

    /// 由 PluginDiscovery 在扫描完成后调用：登记需要轮询的插件 id 集合。
    func watch(_ ids: [String]) {
        watchedIDs = Set(ids)
        // 确保目录存在
        try? FileManager.default.createDirectory(at: Self.panelsDir,
                                                 withIntermediateDirectories: true)
        refreshAll()
        startPollingIfNeeded()
    }

    /// 后台读取并解码单个面板文件（纯函数，可在任意队列调用）。
    /// 文件缺失/无法解码返回 nil（调用方据此移除对应面板条目）。
    nonisolated private static func readPanelFile(_ id: String) -> PluginPanelData? {
        let url = panelsDir.appendingPathComponent("\(id).json")
        guard let data = try? Data(contentsOf: url),
              var p = try? JSONDecoder().decode(PluginPanelData.self, from: data) else { return nil }
        // 文件名即 id，补强一致性
        if p.id != id { p = PluginPanelData(id: id, title: p.title, iconName: p.iconName,
                                            subtitle: p.subtitle, lines: p.lines, updatedAt: p.updatedAt) }
        return p
    }

    /// 手动读一次某个插件的面板文件（供首个版本未轮询时立即生效）
    func refresh(_ id: String) {
        if let p = Self.readPanelFile(id) {
            panels[id] = p
        } else {
            panels.removeValue(forKey: id)
        }
    }

    func refreshAll() {
        for id in watchedIDs { refresh(id) }
    }

    private func startPollingIfNeeded() {
        guard !watchedIDs.isEmpty else { timer?.invalidate(); timer = nil; return }
        guard timer == nil else { return }
        // 1s 轮询：轻量、对第三方 app 无反向调用压力，也避免 XPC 连接管理复杂度。
        // 读取/解码在后台队列进行，主线程仅在数据变化时合并写回——
        // 原实现每秒在主线程同步读文件、且无条件写 @Published 字典，
        // 会造成常驻 1Hz 的主线程 I/O 与 SwiftUI 重渲染。
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, !self.watchedIDs.isEmpty else { return }
                let ids = Array(self.watchedIDs)
                self.pollQueue.async {
                    let results = ids.map { (id: $0, panel: Self.readPanelFile($0)) }
                    Task { @MainActor in
                        for r in results {
                            if let p = r.panel {
                                if self.panels[r.id] != p { self.panels[r.id] = p }
                            } else if self.panels[r.id] != nil {
                                self.panels[r.id] = nil
                            }
                        }
                    }
                }
            }
        }
    }

    /// 第三方插件调用入口（同进程帮助函数，可选）：直接更新内存 + 落盘。
    /// 真实第三方为独立进程，只需写文件即可，无需调用此函数。
    static func write(_ panel: PluginPanelData) throws {
        try FileManager.default.createDirectory(at: panelsDir,
                                                withIntermediateDirectories: true)
        let url = panelsDir.appendingPathComponent("\(panel.id).json")
        let data = try JSONEncoder().encode(panel)
        try data.write(to: url, options: .atomic)
    }
}
