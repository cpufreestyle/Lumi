import Foundation

struct UsageDay: Identifiable, Equatable, Sendable {
    let dayStart: Date
    let totals: UsageTotals
    var id: Date { dayStart }
}
