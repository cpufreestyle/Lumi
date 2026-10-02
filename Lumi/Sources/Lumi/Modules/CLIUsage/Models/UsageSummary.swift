import Foundation

struct UsageSummary: Equatable, Sendable {
    var today: UsageTotals = .empty
    var yesterday: UsageTotals = .empty
    /// 按时间正序（昨天 → 今天），缺日照填零，供柱状图直接使用。
    var days: [UsageDay] = []
    var models: [UsageModelRow] = []
    var sessionCount = 0
    var last30Days: UsageTotals = .empty

    var hasData: Bool { last30Days.totalTokens > 0 }
}
