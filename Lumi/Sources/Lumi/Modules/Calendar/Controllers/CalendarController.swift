import AppKit
import EventKit
import SwiftUI

final class CalendarController: ObservableObject {
    static let shared = CalendarController()

    @Published var upcomingEvents: [EKEvent] = []
    @Published var todayDate: Date = Date()

    private let store = EKEventStore()

    private init() {
        requestAccess()
        // 按需轮询：日历面板可见时 60s（跨天、日程增减能及时反映），
        // 不可见时降到 5 分钟兜底，避免 EventKit 查询常驻空转。
        PollingCoordinator.shared.register(
            id: "calendar.events",
            interval: { [weak self] in self?.pollInterval() ?? 0 },
            action: { [weak self] in
                self?.todayDate = Date()
                self?.fetchEvents()
            }
        )
    }

    /// 当前期望的轮询间隔（秒）。
    private func pollInterval() -> TimeInterval {
        let state = AppState.shared
        return (state.isExpanded && state.activeModule == .calendar) ? 60 : 300
    }

    func requestAccess() {
        store.requestFullAccessToEvents { [weak self] granted, _ in
            DispatchQueue.main.async {
                if granted { self?.fetchEvents() }
            }
        }
    }

    func fetchEvents() {
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 7, to: start)!
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        // EventKit 查询是同步且可能较慢的操作：放到后台队列，避免在轮询回调（主线程）里卡 UI。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let events = self.store.events(matching: predicate)
                .filter { !$0.isAllDay }
                .sorted { $0.startDate < $1.startDate }
            let top = Array(events.prefix(10))
            // 会议入口解析 + 会前 1 分钟提醒。EKEvent 非线程安全，统一在后台队列读数，
            // 只把纯值（链接/时刻）交给 UI 与通知层，不跨线程接触事件对象。
            let reminders: [MeetingReminderItem] = events.compactMap { event in
                guard let link = self.meetingLink(for: event) else { return nil }
                return MeetingReminderItem(
                    identifier: event.eventIdentifier,
                    title: event.title,
                    link: link,
                    startDate: event.startDate
                )
            }
            DispatchQueue.main.async {
                self.upcomingEvents = top
                // 幂等重排：同一事件 ID 的通知在系统侧天然去重，无需持久化「已排」集合。
                MeetingReminderScheduler.shared.schedule(for: reminders)
            }
        }
    }

    /// 事件中的会议入口（Zoom/Teams/腾讯会议等）。只解析链接，不落盘备注原文。
    func meetingLink(for event: EKEvent) -> MeetingLink? {
        MeetingLinkParser.extract(
            urlText: event.url?.absoluteString,
            notes: event.notes,
            location: event.location ?? event.structuredLocation?.title,
            title: event.title
        )
    }

    /// 正在进行的会议。
    var ongoingMeeting: EKEvent? {
        todayEvents.first { event in
            event.startDate <= todayDate && event.endDate > todayDate
                && meetingLink(for: event) != nil
        }
    }

    /// 60 分钟内将开始的最近一场会议。
    var upcomingMeeting: EKEvent? {
        todayEvents.first { event in
            event.startDate > todayDate
                && event.startDate <= todayDate.addingTimeInterval(3600)
                && meetingLink(for: event) != nil
        }
    }

    var todayEvents: [EKEvent] {
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        return upcomingEvents.filter { $0.startDate >= start && $0.startDate < end }
    }

    var eventCount: Int { upcomingEvents.count }
    var todayCount: Int { todayEvents.count }

    func dayString(for date: Date) -> String {
        let f = DateFormatter()
        if Calendar.current.isDateInToday(date) { return "今天" }
        if Calendar.current.isDateInTomorrow(date) { return "明天" }
        f.dateFormat = "M/d"
        return f.string(from: date)
    }

    func timeString(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    func weekdayName(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f.string(from: date)
    }
}
