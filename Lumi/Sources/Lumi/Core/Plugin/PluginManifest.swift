import Foundation

/// 插件权限声明（安装前透明告知用户，类似 App Store 权限说明）。
struct PluginPermission: Codable, Hashable {
    /// 权限类型：accessibility / calendar / contacts / network / screenRecord / none
    let type: String
    /// 人类可读说明
    let reason: String
}

/// 插件清单（Plugin Manifest）。
///
/// 第三方 macOS app 只需在 `Contents/Resources/lumi-plugin.json` 放置此结构，
/// Lumi 即可发现并将其挂载到灵动岛面板。无需编译进宿主，实现"别人的 app 也能接进来"。
///
/// 集成层级：
/// - L1（极简）：仅声明 `urlScheme`，点击即 `open("scheme://")` 唤起该 app。
/// - L2（清单）：声明 `id/name/iconName/permissions/panelHint`，用于统一图标与权限提示。
struct PluginManifest: Codable, Identifiable, Hashable {
    /// 唯一标识，建议反向域名，如 `com.example.bartender`
    let id: String
    /// 展示名
    let name: String
    /// SF Symbol 名（优先）或 NSImage 系统名；缺失时回退到首字母
    let iconName: String?
    /// L1 唤起用的 URL Scheme（不含 `://`），例如 `bartender`
    let urlScheme: String?
    /// 若插件是独立 .app，可填其应用名（如 `Bartender.app`）用于本地发现
    let appName: String?
    /// 权限声明（透明告知）
    let permissions: [PluginPermission]?
    /// 面板提示语（可选）
    let panelHint: String?
    /// 最低宿主版本（语义化，可选）
    let minHostVersion: String?
    /// 市场下载地址（仅来自市场清单，本地 manifest 一般不含）
    let downloadURL: URL?
    /// 插件版本（语义化，如 "1.0.0"）。用于市场「可更新」判断。
    let version: String?
    /// 市场分类（如 "工具"/"效率"/"娱乐"/"其它"），用于市场分段筛选
    let category: String?
    /// 一句话简介（市场列表展示）
    let summary: String?
    /// L3 深度集成标志：为 true 时插件会在 `Lumi/PluginPanels/<id>.json` 写入面板数据，
    /// Lumi 将其作为原生模块一样的动态模块挂载到标签栏与展开面板。
    let panel: Bool

    // MARK: - 运行时附加字段（不来自 JSON）

    /// 插件来源：本地已安装的 .app，或市场下载
    enum Source: Hashable {
        case local(appPath: String)
        case marketplace
    }
    /// 发现该插件的来源路径（本地发现时即 .app 路径）
    var bundlePath: String?
    var source: Source = .local(appPath: "")

    var resolvedName: String { name.isEmpty ? (appName ?? id) : name }

    /// 用于列表展示的图标名，缺失回退到 "puzzlepiece"
    var resolvedIconName: String { iconName ?? "puzzlepiece" }

    /// 是否可通过 URL Scheme 唤起（L1 可用）
    var canLaunchByScheme: Bool {
        guard let s = urlScheme, !s.isEmpty else { return false }
        return NSURL(string: "\(s)://") != nil
    }

    /// 比较两个语义化版本字符串（"a.b.c"），返回 lhs 是否比 rhs 新。
    /// 无法解析时返回 false（保守，不误报更新）。
    static func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        let parse = { (v: String) -> [Int] in
            v.split(separator: ".").compactMap { Int($0.filter { $0.isNumber }) }
        }
        let a = parse(lhs), b = parse(rhs)
        guard !a.isEmpty, !b.isEmpty else { return false }
        let n = max(a.count, b.count)
        for i in 0..<n {
            let x = a.count > i ? a[i] : 0
            let y = b.count > i ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - 解码容错

    enum CodingKeys: String, CodingKey {
        case id, name, iconName, urlScheme, appName, permissions, panelHint, minHostVersion, downloadURL, panel, version, category, summary
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        iconName = try c.decodeIfPresent(String.self, forKey: .iconName)
        urlScheme = try c.decodeIfPresent(String.self, forKey: .urlScheme)
        appName = try c.decodeIfPresent(String.self, forKey: .appName)
        permissions = try c.decodeIfPresent([PluginPermission].self, forKey: .permissions)
        panelHint = try c.decodeIfPresent(String.self, forKey: .panelHint)
        minHostVersion = try c.decodeIfPresent(String.self, forKey: .minHostVersion)
        downloadURL = try c.decodeIfPresent(URL.self, forKey: .downloadURL)
        panel = try c.decodeIfPresent(Bool.self, forKey: .panel) ?? false
        version = try c.decodeIfPresent(String.self, forKey: .version)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
    }

    init(id: String, name: String, iconName: String? = nil, urlScheme: String? = nil,
         appName: String? = nil, permissions: [PluginPermission]? = nil,
         panelHint: String? = nil, minHostVersion: String? = nil,
         downloadURL: URL? = nil, panel: Bool = false,
         version: String? = nil, category: String? = nil, summary: String? = nil,
         bundlePath: String? = nil, source: Source = .local(appPath: "")) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.urlScheme = urlScheme
        self.appName = appName
        self.permissions = permissions
        self.panelHint = panelHint
        self.minHostVersion = minHostVersion
        self.downloadURL = downloadURL
        self.panel = panel
        self.version = version
        self.category = category
        self.summary = summary
        self.bundlePath = bundlePath
        self.source = source
    }
}
