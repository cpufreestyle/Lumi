import Foundation

/// 会议链接识别规则。只认已知商家域名/scheme，避免把普通 http 链接（JIRA、文档等）
/// 误判成会议；scheme 类（zoommtg:// / msteams://）优先于域名类。
enum MeetingLinkParser {
    private static let hostRules: [(suffix: String, kind: MeetingKind)] = [
        ("zoom.us", .zoom),
        ("zoom.com", .zoom),
        ("zoom.com.cn", .zoom),
        ("zoomgov.com", .zoom),
        ("teams.microsoft.com", .teams),
        ("teams.live.com", .teams),
        ("teams.office.com", .teams),
        ("meeting.tencent.com", .tencent),
        ("meet.google.com", .googleMeet),
        ("webex.com", .webex),
        ("vc.feishu.cn", .feishu),
    ]

    private static let schemeRules: [(scheme: String, kind: MeetingKind)] = [
        ("zoommtg", .zoom),
        ("msteams", .teams),
    ]

    /// host 命中规则：整串相等，或为其子域名（如 us02web.zoom.us）。
    private static func matchHost(_ host: String) -> MeetingKind? {
        for rule in hostRules
        where host == rule.suffix || host.hasSuffix("." + rule.suffix) {
            return rule.kind
        }
        return nil
    }

    /// 识别单个 URL 是否（已知商家的）会议链接。
    static func detectKind(of url: URL) -> MeetingKind? {
        let scheme = url.scheme?.lowercased() ?? ""
        if let hit = schemeRules.first(where: { $0.scheme == scheme }) {
            return hit.kind
        }
        // 域名规则只对 http(s) 生效：ftp://zoom.us 之类不应被当成会议
        guard scheme == "http" || scheme == "https" else { return nil }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return matchHost(host)
    }

    /// 从一段文本中找出第一个会议链接。
    /// 文本整体是 URL 时直接判定；否则用 NSDataDetector 扫描内嵌链接
    /// （纯 Foundation，命令行/测试环境可用）。
    static func firstMeetingLink(in text: String?) -> MeetingLink? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), let kind = detectKind(of: url) {
            return MeetingLink(url: url, kind: kind)
        }
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        var found: MeetingLink?
        detector.enumerateMatches(in: trimmed, options: [], range: range) { match, _, stop in
            guard let match, let url = match.url else { return }
            if let kind = detectKind(of: url) {
                found = MeetingLink(url: url, kind: kind)
                stop.pointee = true
            }
        }
        return found
    }

    /// 按日历字段优先级提取：url > notes(备注) > location(位置) > title(标题)。
    /// 只解析链接，不落盘任何备注原文（隐私）。
    static func extract(urlText: String?, notes: String?, location: String?, title: String? = nil) -> MeetingLink? {
        for source in [urlText, notes, location, title] {
            if let link = firstMeetingLink(in: source) { return link }
        }
        return nil
    }
}
