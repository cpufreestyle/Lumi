import Foundation
import Combine

/// 模块定义
enum AppModule: String, CaseIterable, Identifiable {
    case music = "音乐"
    case calendar = "日历"
    case focus = "专注"
    case clipboard = "剪贴板"
    case liveDetection = "检测"
    case claudeCode = "Claude"
    case codex = "Codex"
    case videoDownload = "下载"
    case game = "游戏"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .music:       return "music.note"
        case .calendar:    return "calendar"
        case .focus:       return "timer"
        case .clipboard:   return "doc.on.clipboard"
        case .liveDetection: return "antenna.radiowaves.left.and.right"
        case .claudeCode:  return "brain.head.profile"
        case .codex:       return "wand.and.stars"
        case .videoDownload: return "arrow.down.to.line"
        case .game:        return "gamecontroller.fill"
        }
    }

    var shortName: String {
        switch self {
        case .music:       return "music"
        case .calendar:    return "cal"
        case .focus:       return "focus"
        case .clipboard:   return "clip"
        case .liveDetection: return "live"
        case .claudeCode:  return "claude"
        case .codex:       return "codex"
        case .videoDownload: return "dl"
        case .game:        return "game"
        }
    }

    /// 是否为付费功能模块
    var isPremium: Bool {
        switch self {
        case .claudeCode, .codex, .videoDownload:
            return true
        default:
            return false
        }
    }

    /// 对应的付费功能类型
    var premiumFeature: PremiumFeature? {
        switch self {
        case .claudeCode:  return .claudeCode
        case .codex:       return .codex
        case .videoDownload: return .videoDownload
        default:           return nil
        }
    }
}

/// 全局应用状态
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var activeModule: AppModule = .music
    @Published var isExpanded: Bool = false

    /// 动态岛是否悬浮显示（鼠标悬停时展开）
    @Published var isHovering: Bool = false

    /// 是否显示许可证管理面板
    @Published var showLicensePanel: Bool = false

    /// 是否显示动态岛界面（总开关：关闭后整个胶囊不再出现）
    @Published var islandEnabled: Bool = true {
        didSet { UserDefaults.standard.set(islandEnabled, forKey: islandEnabledKey) }
    }
    private let islandEnabledKey = "lumi_island_enabled"

    /// 是否将动态岛（小胶囊）锁定为常驻：开启后即使鼠标离开热区也不会自动收起，
    /// 便于稳定查看歌词等内容。音乐模块常用。
    @Published var islandPinned: Bool = false {
        didSet { UserDefaults.standard.set(islandPinned, forKey: islandPinnedKey) }
    }
    private let islandPinnedKey = "lumi_island_pinned"

    /// 展开面板是否正在被手动缩放（拖拽右下角手柄中）。
    /// 用于缩放期间冻结歌词区字号/尺寸的重排，避免每帧重建几十行歌词导致卡顿。
    @Published var isResizing: Bool = false

    /// 轻量自研检查更新单例（GitHub Release 比对）
    let updater = Updater.shared

    /// 插件发现管理器（Phase 0 插件市场骨架）
    let plugins = PluginDiscovery.shared

    /// L3 面板桥接（Phase 2：第三方插件向内嵌面板回写结构化内容）
    let pluginPanels = PluginPanelBridge.shared

    /// 当前选中的 L3 插件模块 id（nil = 未选中插件模块，显示原生模块）。
    /// 标签栏里带 panel 的插件会作为独立标签，点击即设置此值并显示其内嵌面板。
    @Published var selectedPluginPanelID: String? = nil

    private init() {
        islandEnabled = UserDefaults.standard.object(forKey: islandEnabledKey) as? Bool ?? true
        islandPinned = UserDefaults.standard.object(forKey: islandPinnedKey) as? Bool ?? false
        // 启动后静默检查一次更新（后台，不弹窗，除非发现新版本）
        updater.autoCheckOnLaunch()
        // 启动后扫描本地已安装的第三方插件（带 lumi-plugin.json 的 .app）。
        // PluginDiscovery 为 @MainActor，init 非 isolated，故用 Task 切回主线程。
        Task { @MainActor in
            plugins.scan()
        }
    }

    /// 检查当前选中的模块是否可用（付费模块需已激活）
    var canAccessActiveModule: Bool {
        guard activeModule.isPremium else { return true }
        guard let feature = activeModule.premiumFeature else { return true }
        return LicenseManager.shared.isUnlocked(feature)
    }
}
