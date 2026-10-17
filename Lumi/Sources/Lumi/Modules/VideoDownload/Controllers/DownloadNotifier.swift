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
        // 先查当前状态，只在「尚未决定」时向系统要权限 —— 已授权直接发通知，
        // 被拒静默放弃。无条件 requestAuthorization 会让每次下载完成都走一次
        // 授权往返（系统虽不重复弹窗，但设置里会反复出现「最近请求」提示）。
        center.getNotificationSettings { [weak self] settings in
            let send: () -> Void = {
                guard let self else { return }
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
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                send()
            case .notDetermined:
                self?.center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { send() }
                }
            default:
                break
            }
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
