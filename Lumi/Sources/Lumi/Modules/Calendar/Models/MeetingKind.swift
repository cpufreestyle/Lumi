import Foundation

/// 会议提供商。
enum MeetingKind: String, CaseIterable, Sendable {
    case zoom, teams, tencent, googleMeet, webex, feishu

    /// 面板内展示的商家名。
    var displayName: String {
        switch self {
        case .zoom:       return "Zoom"
        case .teams:      return "Teams"
        case .tencent:    return "腾讯会议"
        case .googleMeet: return "Google Meet"
        case .webex:      return "Webex"
        case .feishu:     return "飞书"
        }
    }

    /// 面板内展示的 SF Symbol。
    var iconName: String {
        switch self {
        case .teams: return "person.2.fill"
        default:     return "video.fill"
        }
    }
}
