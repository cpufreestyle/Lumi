import SwiftUI
import EventKit

// MARK: - 日历模块控制器
final class CalendarController: ObservableObject {
    static let shared = CalendarController()

    @Published var upcomingEvents: [EKEvent] = []
    @Published var todayDate: Date = Date()

    private let store = EKEventStore()
    private var timer: Timer?

    private init() {
        requestAccess()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.todayDate = Date()
            self?.fetchEvents()
        }
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
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
        DispatchQueue.main.async {
            self.upcomingEvents = Array(events.prefix(10))
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

// MARK: - 日历模块视图
struct CalendarExpandedView: View {
    @ObservedObject private var cal = CalendarController.shared
    @State private var selectedDate: Date = Date()

    var body: some View {
        VStack(spacing: 0) {
            // 月导航
            monthHeader
                .padding(.horizontal, 20)
                .padding(.top, 12)

            // 迷你日历格子
            miniCalendarGrid
                .padding(.horizontal, 16)
                .padding(.top, 8)

            Divider()
                .background(Color.white.opacity(0.1))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

            // 今日日程列表
            Text("\(cal.weekdayName(for: Date())) · 共 \(cal.todayCount) 项")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.45))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 6)

            if cal.todayEvents.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "calendar.badge.plus")
                        .font(.system(size: 28))
                        .foregroundColor(.white.opacity(0.25))
                    Text("今天没有日程")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.35))
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(cal.todayEvents, id: \.eventIdentifier) { event in
                            eventRow(event)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
        .onAppear { cal.fetchEvents() }
    }

    // MARK: 月导航
    var monthHeader: some View {
        HStack {
            Button(action: { shiftMonth(-1) }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
            }
            .buttonStyle(.plain)

            Spacer()

            Text(monthYearString(selectedDate))
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)

            Spacer()

            Button(action: { shiftMonth(1) }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: 迷你日历格子
    var miniCalendarGrid: some View {
        let days = generateDays()
        return VStack(spacing: 4) {
            // 星期头
            HStack(spacing: 0) {
                ForEach(["日","一","二","三","四","五","六"], id: \.self) { d in
                    Text(d)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.35))
                        .frame(maxWidth: .infinity)
                }
            }

            // 日期格子
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                ForEach(days) { item in
                    if item.day == 0 {
                        Text("").frame(height: 26)
                    } else {
                        Text("\(item.day)")
                            .font(.system(size: 11, weight: item.isToday ? .bold : .regular))
                            .foregroundColor(item.isToday ? .white : .white.opacity(0.7))
                            .frame(height: 26)
                            .frame(maxWidth: .infinity)
                            .background(
                                item.isToday
                                    ? Circle().fill(
                                        LinearGradient(
                                            colors: [Color.pink, Color.purple],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                      ).frame(width: 24, height: 24)
                                    : nil
                            )
                            .overlay(
                                item.hasEvent
                                    ? Circle().fill(Color.pink.opacity(0.8))
                                        .frame(width: 3.5, height: 3.5)
                                        .offset(y: 10)
                                    : nil
                            )
                    }
                }
            }
        }
    }

    // MARK: 日程行
    func eventRow(_ event: EKEvent) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(
                    event.calendar?.color != nil
                        ? Color(event.calendar!.color!)
                        : Color.pink
                )
                .frame(width: 3, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text("\(cal.timeString(for: event.startDate)) — \(cal.timeString(for: event.endDate))")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.45))
            }

            Spacer()
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 4)
        .background(Color.white.opacity(0.03))
        .cornerRadius(6)
        .padding(.bottom, 2)
    }

    // MARK: 辅助
    func monthYearString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy 年 M 月"
        return f.string(from: d)
    }

    func shiftMonth(_ by: Int) {
        if let d = Calendar.current.date(byAdding: .month, value: by, to: selectedDate) {
            selectedDate = d
        }
    }

    struct DayItem: Identifiable {
        let id = UUID()
        let day: Int
        let isToday: Bool
        let hasEvent: Bool
    }

    func generateDays() -> [DayItem] {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: selectedDate)
        guard let firstDay = cal.date(from: comps),
              let range = cal.range(of: .day, in: .month, for: firstDay) else {
            return []
        }
        let weekday = cal.component(.weekday, from: firstDay) - 1
        let today = cal.component(.day, from: Date())
        let thisMonth = cal.component(.month, from: Date()) == comps.month
        let thisYear = cal.component(.year, from: Date()) == comps.year

        var items: [DayItem] = []
        for _ in 0..<weekday { items.append(DayItem(day: 0, isToday: false, hasEvent: false)) }
        for d in 1...range.count {
            let isToday = thisMonth && thisYear && d == today
            items.append(DayItem(day: d, isToday: isToday, hasEvent: false))
        }
        return items
    }
}
