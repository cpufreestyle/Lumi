import AppKit
import UserNotifications

/// 一条待提醒的会议（纯值类型，避免把 EKEvent 泄漏进通知层）。
struct MeetingReminderItem: Equatable {
    let identifier: String
    let title: String
    let link: MeetingLink
    let startDate: Date
}
