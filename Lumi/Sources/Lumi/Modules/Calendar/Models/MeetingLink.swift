import Foundation

/// 从日历事件中解析出的会议入口。
struct MeetingLink: Equatable, Sendable {
    let url: URL
    let kind: MeetingKind
}
