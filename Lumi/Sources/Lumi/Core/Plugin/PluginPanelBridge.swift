import Foundation
import Combine
import Darwin

/// 文件监听事件转发队列（定义在文件作用域，避免 @MainActor 隔离导致的跨线程访问问题）
private let pluginWatchQueue = DispatchQueue(label: "com.lumi.pluginpanels.watch", qos: .utility)

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

/// 单个插件面板的运行状态（供 UI 展示与诊断）。
enum PluginPanelStatus: Equatable {
    /// 正常：已读到面板数据且未陈旧
    case live
    /// 数据陈旧：超过 30 秒未更新，插件可能已退出
    case stale
    /// 无数据：manifest 声明了 panel，但从未写出过面板文件
    case noData
    /// 读取失败：文件存在但解码失败（插件写畸形 JSON）
    case malformed(String)

    var isUsable: Bool { self == .live }
}

/// 单个插件的面板状态快照（数据 + 状态）。
struct PluginPanelEntry: Equatable {
    var data: PluginPanelData?
    var status: PluginPanelStatus

    static let empty = PluginPanelEntry(data: nil, status: .noData)
}

// MARK: - 桥接管理

@MainActor
final class PluginPanelBridge: ObservableObject {
    static let shared = PluginPanelBridge()

    /// 已加载的插件面板数据，key = plugin id
    @Published private(set) var entries: [String: PluginPanelEntry] = [:]

    /// 兼容读取：仅返回有可用数据的插件面板（供 UI 直接渲染）
    var panels: [String: PluginPanelData] {
        entries.compactMapValues { $0.data }
    }

    /// 诊断计数：有多少插件当前处于非 live 状态（供市场页展示）
    var unhealthyCount: Int {
        entries.values.filter { !$0.status.isUsable }.count
    }

    /// 共享目录（宿主管理，插件可写）
    nonisolated static let panelsDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                 .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Lumi/PluginPanels", isDirectory: true)
    }()

    /// 面板文件轮询专用后台队列:磁盘读取与 JSON 解码不占主线程,消除每秒一次的主线程 I/O。
    private let pollQueue = DispatchQueue(label: "com.lumi.pluginpanels.poll", qos: .utility)
    /// 当前需要监听的插件 id 集合（由 PluginDiscovery 扫描带 panel 的插件后设置）
    private var watchedIDs: Set<String> = []
    /// 每个插件 json 的监听源（key = plugin id）
    private var fileSources: [String: DispatchSourceFileSystemObject] = [:]
    /// 目录监听源：捕获「插件首次创建 json」与原子写入引发的 rename
    private var dirSource: DispatchSourceFileSystemObject?
    /// 文件事件防抖（第三方可能一次写多个文件，或高频连续写）
    private var debounceItem: DispatchWorkItem?

    /// 第三方插件应写入的目录（供文档/示例脚本引用）
    static var panelsDirectoryPath: String { panelsDir.path }

    /// 由 PluginDiscovery 在扫描完成后调用：登记需要轮询的插件 id 集合。
    func watch(_ ids: [String]) {
        watchedIDs = Set(ids)
        // 确保目录存在
        try? FileManager.default.createDirectory(at: Self.panelsDir,
                                                 withIntermediateDirectories: true)
        refreshAll()
        if !ids.isEmpty { PluginLog.info("开始监听 " + String(ids.count) + " 个面板文件") }
        startWatching()
        startPollingIfNeeded()
    }

    /// 面板读取结果：区分「读到数据 / 文件不存在 / 文件存在但解码失败」。
    /// 返回失败原因而非简单 nil，UI 才能告诉用户「插件写了坏数据」，
    /// 而不是让面板静默消失、让人以为是 Lumi 的 bug。
    nonisolated private enum PanelReadResult {
        case ok(PluginPanelData)
        case missing
        case malformed(String)
    }

    nonisolated private static func readPanelFile(_ id: String) -> PanelReadResult {
        let url = panelsDir.appendingPathComponent("\(id).json")
        guard let data = try? Data(contentsOf: url) else { return .missing }
        guard var p = try? JSONDecoder().decode(PluginPanelData.self, from: data) else {
            return .malformed("面板 JSON 解码失败（格式不符）")
        }
        // 文件名即 id，补强一致性
        if p.id != id { p = PluginPanelData(id: id, title: p.title, iconName: p.iconName,
                                            subtitle: p.subtitle, lines: p.lines, updatedAt: p.updatedAt) }
        return .ok(p)
    }

    /// 手动读一次某个插件的面板文件（供首个版本未轮询时立即生效）
    func refresh(_ id: String) {
        entries[id] = Self.entry(id: id, from: Self.readPanelFile(id))
    }

    /// 把读取结果转成 UI 条目。数据存在但陈旧时保留数据并标记 stale，
    /// 让 UI 可以继续渲染最后一帧内容，同时给出「可能已退出」的提示。
    nonisolated private static func entry(id: String, from result: PanelReadResult) -> PluginPanelEntry {
        switch result {
        case .ok(let p):
        if p.isStale { PluginLog.warn("面板数据陈旧 id=" + id) }
        return PluginPanelEntry(data: p, status: p.isStale ? .stale : .live)
        case .missing:
            return .empty
        case .malformed(let reason):
            PluginLog.error("面板数据解码失败 id=" + id + " " + reason)
            return PluginPanelEntry(data: nil, status: .malformed(reason))
        }
    }

    func refreshAll() {
        for id in watchedIDs { refresh(id) }
    }

    private func startPollingIfNeeded() {
        guard !watchedIDs.isEmpty else {
            stopWatching()
            PollingCoordinator.shared.unregister(id: "pluginPanels.poll")
            return
        }
        // 主更新路径已改为 DispatchSource 文件监听（插件一写入即刻刷新），
        // 这里只保留 60s 兜底轮询，防止极端情况下漏事件导致面板长期陈旧。
        PollingCoordinator.shared.register(
            id: "pluginPanels.poll",
            interval: { 60 },
            action: { [weak self] in
                Task { @MainActor in self?.pollOnce() }
            }
        )
    }

    // MARK: - 文件监听（DispatchSource）

    /// 挂载目录 + 各插件 json 的监听源。每次都会释放旧 fd 并按当前 inode 重新打开。
    private func startWatching() {
        stopWatching()
        guard !watchedIDs.isEmpty else { return }
        attachDirectoryWatcher()
        for id in watchedIDs { attachFileWatcher(for: id) }
    }

    private func stopWatching() {
        for (_, source) in fileSources { source.cancel() }
        fileSources.removeAll()
        dirSource?.cancel()
        dirSource = nil
        debounceItem?.cancel()
        debounceItem = nil
    }

    /// 目录监听：捕获插件「首次创建」json，以及原子写入产生的 rename。
    private func attachDirectoryWatcher() {
        try? FileManager.default.createDirectory(at: Self.panelsDir, withIntermediateDirectories: true)
        let fd = open(Self.panelsDir.path, O_EVTONLY)
        guard fd >= 0 else {
            // 插件还没写过文件：等目录监听在文件创建时触发重新挂载。
            // 这里不记日志——启动时多数插件尚未写入，会刷一屏噪音。
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: pluginWatchQueue)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.handleFileSystemEvent() }
        }
        source.setCancelHandler { close(fd) }
        dirSource = source
        source.resume()
    }

    /// 单个插件 json 的监听。**必须逐文件监听**：
    /// 目录级 `.write` 事件只反映条目增删，捕获不到「已有文件的内容改写」。
    private func attachFileWatcher(for id: String) {
        let path = Self.panelsDir.appendingPathComponent("\(id).json").path
        let fd = open(path, O_EVTONLY)
        // 插件还没写过文件：跳过，等目录监听在文件创建时触发重新挂载
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: pluginWatchQueue)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.handleFileSystemEvent() }
        }
        source.setCancelHandler { close(fd) }
        fileSources[id] = source
        source.resume()
    }

    /// 文件事件到达：防抖 0.3s 后读取一次，并重新挂载监听。
    /// 重新挂载是必需的——第三方普遍用 `.atomic` 写入（临时文件 rename 覆盖原文件），
    /// 会让手里的 fd 指向已被替换的旧 inode，此后不再收到任何事件。
    ///
    /// 只重挂「事件涉及的那个文件」而不是全部 source：cancel 掉全部再重开，
    /// 在插件高频连续写入时会反复关闭/打开同一批 fd，既浪费又可能丢事件。
    private func handleFileSystemEvent() {
        debounceItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.pollOnce()
                self?.remountWatchers()
            }
        }
        debounceItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    /// 重挂所有监听源。与 startWatching 的区别是不重建目录监听（目录本身没被替换），
    /// 只重建各插件文件的监听（它们的 inode 可能已被 atomic rename 换掉）。
    private func remountWatchers() {
        for (_, source) in fileSources { source.cancel() }
        fileSources.removeAll()
        for id in watchedIDs { attachFileWatcher(for: id) }
    }

    /// 读一轮面板文件：后台队列解码，主线程仅在数据变化时写回。
    private func pollOnce() {
        guard !watchedIDs.isEmpty else { return }
        let ids = Array(watchedIDs)
        pollQueue.async { [weak self] in
            let results = ids.map { (id: $0, entry: Self.entry(id: $0, from: Self.readPanelFile($0))) }
            Task { @MainActor in
                guard let self = self else { return }
                for r in results where self.entries[r.id] != r.entry {
                    self.entries[r.id] = r.entry
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
