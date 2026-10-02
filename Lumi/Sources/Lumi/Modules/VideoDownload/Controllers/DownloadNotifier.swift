import Foundation
import UserNotifications

/// 视频下载完成的系统通报。
///
/// delegate 链式前级联（关键设计）：构造时先保存 UNUserNotificationCenter 既有的 delegate
/// （会议提醒调度器），自身 willPresent / didReceive 一律透传给前级，且在前级缺失时才兜底。
/// 这样后注册的下载通报不会顶掉会议提醒的 delegate，避免「装了这个功能后会议提醒
/// 前台不再弹横幅」的回归。
///
/// 装配顺序依赖：必须在 MeetingReminderScheduler.shared 之后构造（见 main.swift），
/// 否则 previousDelegate 捕获不到会议提醒。
final class DownloadNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = DownloadNotifier()

    private let center = UNUserNotificationCenter.current()
    private weak var previousDelegate: UNUserNotificationCenterDelegate?

    private override init() {
        super.init()
        previousDelegate = center.delegate
        center.delegate = self
    }

    /// 发送「下载完成」通报。授权被拒则静默跳过，不影响下载本身。
    func postCompletion(title: String) {
        let body = title.isEmpty ? "视频已保存到 Lumi Downloads" : title
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            guard granted, let self else { return }
            let content = UNMutableNotificationContent()
            content.title = "下载完成"
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "lumi.download.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            self.center.add(request)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate（透传给前级 delegate）

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if let previousDelegate {
            previousDelegate.userNotificationCenter?(center, willPresent: notification, withCompletionHandler: completionHandler)
        } else {
            completionHandler([.banner, .sound])
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let previousDelegate {
            previousDelegate.userNotificationCenter?(center, didReceive: response, withCompletionHandler: completionHandler)
        } else {
            completionHandler()
        }
    }
}
