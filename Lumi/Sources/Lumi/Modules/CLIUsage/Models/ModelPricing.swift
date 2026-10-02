import Foundation

/// 与 CLI 用量关联的成本估算。命中已知模型才估算；未知/自托管（如本机 vLLM/Qwen）
/// 返回 nil，面板显示「—」，不硬编一个可能错误的价格。
enum ModelPricing {
    struct Price: Equatable, Sendable {
        let inputPerMillion: Double
        let outputPerMillion: Double
        let cachedPerMillion: Double
    }

    /// 模糊匹配（模型名含关键词即可）。价格为公开列表价量级，仅作参考估算。
    static func price(for model: String?) -> Price? {
        guard let model = model?.lowercased(), !model.isEmpty else { return nil }
        if model.contains("opus") { return Price(inputPerMillion: 15, outputPerMillion: 75, cachedPerMillion: 1.5) }
        if model.contains("sonnet") { return Price(inputPerMillion: 3, outputPerMillion: 15, cachedPerMillion: 0.3) }
        if model.contains("haiku") { return Price(inputPerMillion: 0.8, outputPerMillion: 4, cachedPerMillion: 0.08) }
        if model.contains("gpt-5") || model.contains("codex") { return Price(inputPerMillion: 1.25, outputPerMillion: 10, cachedPerMillion: 0.125) }
        if model.contains("gpt-4.1") { return Price(inputPerMillion: 2, outputPerMillion: 8, cachedPerMillion: 0.5) }
        if model.contains("gpt-4o") { return Price(inputPerMillion: 2.5, outputPerMillion: 10, cachedPerMillion: 1.25) }
        if model.contains("o4-mini") { return Price(inputPerMillion: 1.1, outputPerMillion: 4.4, cachedPerMillion: 0.275) }
        if model.contains("o3") { return Price(inputPerMillion: 2, outputPerMillion: 8, cachedPerMillion: 0.5) }
        // 自托管/本地端点（Qwen、DeepSeek、llama 等）不猜价
        return nil
    }

    static func estimateUSD(_ totals: UsageTotals, price: Price) -> Double {
        Double(totals.inputTokens) / 1_000_000 * price.inputPerMillion
            + Double(totals.outputTokens) / 1_000_000 * price.outputPerMillion
            + Double(totals.extraCachedTokens) / 1_000_000 * price.cachedPerMillion
    }

    /// 整个 summary 的估算费用（仅已知模型部分；无人识别的部分不计）。
    static func estimateSummaryUSD(_ summary: UsageSummary) -> Double {
        summary.models.reduce(0) { partial, row in
            guard let price = price(for: row.model) else { return partial }
            return partial + estimateUSD(row.totals, price: price)
        }
    }
}
