import Foundation

/// ISO8601（含毫秒）解析。Codex/Claude 时间戳均为 `2026-09-23T12:25:00.841Z`。
enum UsageDate {
    static let parser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// 容错：先按毫秒格式尝试，失败再回退无毫秒格式。
    static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        if let date = parser.date(from: string) { return date }
        let fallback = ISO8601DateFormatter()
        return fallback.date(from: string)
    }
}
