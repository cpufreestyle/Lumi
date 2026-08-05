import Foundation
import Combine

/// 模块定义
enum AppModule: String, CaseIterable, Identifiable {
    case music = "音乐"
    case calendar = "日历"
    case focus = "专注"
    case clipboard = "剪贴板"
    case liveDetection = "检测"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .music:       return "music.note"
        case .calendar:    return "calendar"
        case .focus:       return "timer"
        case .clipboard:   return "doc.on.clipboard"
        case .liveDetection: return "antenna.radiowaves.left.and.right"
        }
    }

    var shortName: String {
        switch self {
        case .music:       return "music"
        case .calendar:    return "cal"
        case .focus:       return "focus"
        case .clipboard:   return "clip"
        case .liveDetection: return "live"
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

    private init() {}
}
