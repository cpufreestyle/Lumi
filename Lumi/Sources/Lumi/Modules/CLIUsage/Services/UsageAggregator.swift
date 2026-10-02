import Foundation

enum UsageAggregator {
    /// 汇总记录。Codex 按「会话 + 当天」去重（日增量只留最大的一条）。
    static func summarize(
        _ entries: [UsageEntry],
        now: Date = Date(),
        calendar: Calendar = .current,
        dayCount: Int = 7
    ) -> UsageSummary {
        // Codex 去重：同会话同一天只保留 totalTokens 最大的一条（日增量的高水位）
        var codexBySessionDay: [String: UsageEntry] = [:]
        for entry in entries where entry.source == .codex {
            let key = entry.sessionKey + "|" + String(calendar.startOfDay(for: entry.timestamp).timeIntervalSince1970)
            if let existing = codexBySessionDay[key] {
                if entry.totalTokens > existing.totalTokens {
                    codexBySessionDay[key] = entry
                }
            } else {
                codexBySessionDay[key] = entry
 }
        }

        let finalEntries = codexBySessionDay.values + entries.filter { $0.source == .claudeCode }
        let sessionCount = Set(finalEntries.map(\.sessionKey)).count

        // 分桶
        var buckets: [Date: UsageTotals] = [:]
        var perModel: [String: UsageModelRow] = [:]
        var totals30 = UsageTotals.empty
        let todayStart = calendar.startOfDay(for: now)

        for entry in finalEntries {
            buckets[calendar.startOfDay(for: entry.timestamp), default: .empty].add(entry)
            totals30.add(entry)
            let modelKey = "\(entry.source.rawValue)|\(entry.model ?? "?")"
            if var row = perModel[modelKey] {
                row.totals = row.totals + totals(of: entry)
                perModel[modelKey] = row
            } else {
                var totals = UsageTotals.empty
                totals.add(entry)
                perModel[modelKey] = UsageModelRow(source: entry.source, model: entry.model, totals: totals)
            }
        }

        // 组装柱状图数据（缺日照零）
        var days: [UsageDay] = []
        for offset in (0..<dayCount).reversed() {
            guard let dayStart = calendar.date(byAdding: .day, value: -offset, to: todayStart) else { continue }
            days.append(UsageDay(dayStart: dayStart, totals: buckets[dayStart] ?? .empty))
        }

        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart)

        return UsageSummary(
            today: buckets[todayStart] ?? .empty,
            yesterday: flatMap0(yesterdayStart, buckets),
            days: days,
            models: perModel.values.sorted { $0.totals.totalTokens > $1.totals.totalTokens },
            sessionCount: sessionCount,
            last30Days: totals30
        )
    }

    private static func totals(of entry: UsageEntry) -> UsageTotals {
        var totals = UsageTotals.empty
        totals.add(entry)
        return totals
    }

    private static func flatMap0(_ key: Date?, _ map: [Date: UsageTotals]) -> UsageTotals {
        guard let key else { return .empty }
        return map[key] ?? .empty
    }
}
