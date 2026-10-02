import Foundation

enum UsageFormatter {
    static func tokensString(_ value: Int) -> String {
        switch value {
        case 1_000_000...: return String(format: "%.2fM", Double(value) / 1_000_000)
        case 10_000...:    return String(format: "%.1fk", Double(value) / 1_000)
        case 1_000...:     return String(format: "%.2fk", Double(value) / 1_000)
        default:           return "\(value)"
        }
    }

    static func costString(_ usd: Double) -> String {
        if usd <= 0 { return "$0.00" }
        if usd < 0.01 { return String(format: "$%.4f", usd) }
        return String(format: "$%.2f", usd)
    }
}
