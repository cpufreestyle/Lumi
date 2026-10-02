import Foundation
import SwiftUI

struct CLIUsageBriefView: View {
    @ObservedObject private var usage = CLIUsageController.shared

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 12))
                .foregroundColor(PanelInk.pink)
            if usage.summary.hasData {
                let cost = ModelPricing.estimateSummaryUSD(usage.summary)
                Text("今日 \(UsageFormatter.tokensString(usage.summary.today.totalTokens)) tokens · \(UsageFormatter.costString(cost))")
                    .font(.system(size: 12))
                    .foregroundColor(PanelInk.text(0.7))
            } else {
                Text("AI CLI 用量 · 本机统计")
                    .font(.system(size: 12))
                    .foregroundColor(PanelInk.text(0.7))
            }
        }
    }
}
