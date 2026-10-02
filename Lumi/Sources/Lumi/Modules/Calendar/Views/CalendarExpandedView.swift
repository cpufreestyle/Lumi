import AppKit
import EventKit
import SwiftUI

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
                .background(PanelInk.chip(0.1))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

            // 今日日程列表
            Text("\(cal.weekdayName(for: Date())) · 共 \(cal.todayCount) 项")
                .font(.system(size: 11))
                .foregroundColor(PanelInk.text(0.45))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 6)

            // 会议横幅：进行中 / 即将开始的会议，一键唤起客户端
            if let event = cal.upcomingMeeting ?? cal.ongoingMeeting,
               let link = cal.meetingLink(for: event) {
                meetingBanner(
                    event: event,
                    link: link,
                    ongoing: cal.upcomingMeeting == nil
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }

            if cal.todayEvents.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "calendar.badge.plus")
                        .font(.system(size: 28))
                        .foregroundColor(PanelInk.text(0.25))
                    Text("今天没有日程")
                        .font(.system(size: 13))
                        .foregroundColor(PanelInk.text(0.35))
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
                    .foregroundColor(PanelInk.text(0.6))
            }
            .buttonStyle(.plain)

            Spacer()

            Text(monthYearString(selectedDate))
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(PanelInk.primary)

            Spacer()

            Button(action: { shiftMonth(1) }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(PanelInk.text(0.6))
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
                        .foregroundColor(PanelInk.text(0.35))
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
                // 日历颜色为可选值，缺失时回退到粉色，避免强制解包崩溃
                .fill(event.calendar?.color.map { Color($0) } ?? Color.pink)
                .frame(width: 3, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(PanelInk.primary)
                    .lineLimit(1)
                Text("\(cal.timeString(for: event.startDate)) — \(cal.timeString(for: event.endDate))")
                    .font(.system(size: 10))
                    .foregroundColor(PanelInk.text(0.45))
            }

            Spacer()

            // 行内一键入会：仅对已解析到会议链接且未结束的事件展示
            if event.endDate > cal.todayDate, let link = cal.meetingLink(for: event) {
                Button { NSWorkspace.shared.open(link.url) } label: {
                    Image(systemName: link.kind.iconName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(PanelInk.control)
                        .frame(width: 26, height: 22)
                        .background(Capsule().fill(PanelInk.chip(0.12)))
                }
                .buttonStyle(.plain)
                .help("通过 \(link.kind.displayName) 加入会议")
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 4)
        .background(PanelInk.chip(0.03))
        .cornerRadius(6)
        .padding(.bottom, 2)
    }

    // MARK: 会议横幅 + 倒计时
    func meetingBanner(event: EKEvent, link: MeetingLink, ongoing: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: link.kind.iconName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(PanelInk.control)
                .frame(width: 26, height: 26)
                .background(
                    Circle().fill(
                        LinearGradient(
                            colors: [Color.pink, Color.purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(
                    ongoing
                        ? "会议进行中 · \(link.kind.displayName)"
                        : meetingCountdownText(until: event.startDate, kind: link.kind)
                )
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(PanelInk.primary)
                Text(event.title)
                    .font(.system(size: 10))
                    .foregroundColor(PanelInk.text(0.45))
                    .lineLimit(1)
            }

            Spacer()

            Button { NSWorkspace.shared.open(link.url) } label: {
                Text("加入")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(
                            LinearGradient(
                                colors: [Color.pink, Color.purple],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                    )
            }
            .buttonStyle(.plain)
            .help("通过 \(link.kind.displayName) 加入会议")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(PanelInk.chip(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            LinearGradient(
                                colors: [Color.pink.opacity(0.5), Color.purple.opacity(0.5)],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            lineWidth: 1
                        )
                )
        )
    }

    /// 「12 分钟后 · Zoom」；不足 1 分钟显示「会议即将开始」。
    /// now 用轮询刷新的 todayDate，分钟粒度足够，无需秒级定时器。
    func meetingCountdownText(until date: Date, kind: MeetingKind) -> String {
        let seconds = date.timeIntervalSince(cal.todayDate)
        if seconds <= 60 { return "会议即将开始 · \(kind.displayName)" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) 分钟后 · \(kind.displayName)" }
        return "\(minutes / 60) 小时后 · \(kind.displayName)"
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
