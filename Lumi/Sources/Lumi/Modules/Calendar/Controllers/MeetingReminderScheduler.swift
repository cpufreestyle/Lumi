import AppKit
import UserNotifications

/// 会议开始前本地提醒调度。
///
/// 设计要点：
/// - 事件驱动：日历每次刷新（`CalendarController.fetchEvents`）后幂等重排，不新增轮询；
/// - 去重靠 `UNNotificationRequest(identifier:)` 天然幂等（同一事件 ID 重复 add 即替换），
///   因此无需持久化「已提醒」集合；
/// - 只给未来 48 小时内的会议排提醒，控制打扰面；
/// - 前台时也走横幅（accessory 应用默认不弹）， delegate 在 `willPresent` 显式放行。
final class MeetingReminderScheduler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MeetingReminderScheduler()

    private let center = UNUserNotificationCenter.current()
    private let categoryID = "LUMI_MEETING"
    private let joinActionID = "LUMI_MEETING_JOIN"

    /// 会前多久提醒（60 秒）。
    private let lead: TimeInterval = 60
    /// 排提醒的最远未来（48 小时）。
    private let horizon: TimeInterval = 48 * 3600

    private override init() {
        super.init()
        center.delegate = self
        let join = UNNotificationAction(identifier: joinActionID, title: "加入会议", options: [])
        let category = UNNotificationCategory(identifier: categoryID, actions: [join], intentIdentifiers: [])
        center.setNotificationCategories([category])
    }

    /// 为一批会议幂等重排提醒。`now` 可注入，便于测试。
    func schedule(for meetings: [MeetingReminderItem], now: Date = Date()) {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            // 授权结果不关心：用户拒绝则静默跳过，日历面板内的一键入会不受影响。
        }
        for meeting in meetings {
            let fireAt = meeting.startDate.addingTimeInterval(-lead)
            guard fireAt > now, meeting.startDate <= now.addingTimeInterval(horizon) else { continue }

            let content = UNMutableNotificationContent()
            content.title = "会议即将开始"
            let title = meeting.title.isEmpty ? "未命名会议" : meeting.title
            content.body = "「\(title)」1 分钟后开始 · \(meeting.link.kind.displayName)"
            content.sound = .default
            content.categoryIdentifier = categoryID
            content.userInfo = ["meetingURL": meeting.link.url.absoluteString]

            let comps = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: fireAt
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let request = UNNotificationRequest(
                identifier: requestIdentifier(meeting.identifier),
                content: content,
                trigger: trigger
            )
            center.add(request)
        }
    }

    private func requestIdentifier(_ eventID: String) -> String {
        "lumi.meeting.\(eventID)"
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// 前台也弹横幅：Lumi 是 accessory 应用，默认前台不展示通知。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// 点击横幅 / 点「加入会议」：直接唤起会议客户端。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let urlString = response.notification.request.content.userInfo["meetingURL"] as? String,
           let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }
}
