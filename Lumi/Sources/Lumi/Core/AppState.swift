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

    private init() {
        islandEnabled = UserDefaults.standard.object(forKey: islandEnabledKey) as? Bool ?? true
        islandPinned = UserDefaults.standard.object(forKey: islandPinnedKey) as? Bool ?? false
    }

    /// 检查当前选中的模块是否可用（付费模块需已激活）
    var canAccessActiveModule: Bool {
        guard activeModule.isPremium else { return true }
        guard let feature = activeModule.premiumFeature else { return true }
        return LicenseManager.shared.isUnlocked(feature)
    }
}
