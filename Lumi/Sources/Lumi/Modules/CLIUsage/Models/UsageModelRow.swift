import Foundation

struct UsageModelRow: Identifiable, Equatable, Sendable {
    let source: CLISource
    let model: String?
    var totals: UsageTotals
    var id: String { "\(source.rawValue)|\(model ?? "?")" }
}
