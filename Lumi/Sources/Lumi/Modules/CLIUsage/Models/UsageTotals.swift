import Foundation

struct UsageTotals: Equatable, Sendable {
    var inputTokens = 0
    var outputTokens = 0
    var cachedTokens = 0
    /// 未计入 input、需独立累加的缓存（Claude 口径）。
    private(set) var extraCachedTokens = 0

    var totalTokens: Int { inputTokens + outputTokens + extraCachedTokens }

    mutating func add(_ entry: UsageEntry) {
        inputTokens += entry.inputTokens
        outputTokens += entry.outputTokens
        cachedTokens += entry.cachedTokens
        if !entry.cachedIncludedInInput {
            extraCachedTokens += entry.cachedTokens
        }
    }

    static func + (lhs: UsageTotals, rhs: UsageTotals) -> UsageTotals {
        var out = lhs
        out.inputTokens += rhs.inputTokens
        out.outputTokens += rhs.outputTokens
        out.cachedTokens += rhs.cachedTokens
        out.extraCachedTokens += rhs.extraCachedTokens
        return out
    }
}

extension UsageTotals {
    static let empty = UsageTotals()
}
