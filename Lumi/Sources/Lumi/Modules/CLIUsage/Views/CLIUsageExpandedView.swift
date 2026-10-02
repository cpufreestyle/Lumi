import Foundation
import SwiftUI

struct CLIUsageExpandedView: View {
    @ObservedObject private var usage = CLIUsageController.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header

                if usage.summary.hasData {
                    todayCard
                    weekChart
                    modelBreakdown
                } else {
                    emptyHint
                }

                footer
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
        }
        .onAppear { usage.scan() }
    }

    // MARK: 头部
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(PanelInk.pink)
            Text("AI CLI 用量")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(PanelInk.primary)
            Spacer()
            if usage.isScanning {
                ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
            }
            Button {
                usage.scan()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .foregroundColor(PanelInk.text(0.55))
            }
            .buttonStyle(.plain)
            .help("重新扫描")
        }
    }

    // MARK: 今日卡片
    private var todayCard: some View {
        let s = usage.summary
        return VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(UsageFormatter.tokensString(s.today.totalTokens))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundColor(PanelInk.primary)
                Text("tokens 今日")
                    .font(.system(size: 11))
                    .foregroundColor(PanelInk.text(0.45))
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(UsageFormatter.costString(ModelPricing.estimateSummaryUSD(s)))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundColor(PanelInk.pink)
                    Text(hasKnownPrice(s) ? "估算费用（今日）" : "估算费用 · 仅已知模型")
                        .font(.system(size: 9))
                        .foregroundColor(PanelInk.text(0.35))
                }
            }
            HStack(spacing: 12) {
                statChip(title: "输入", value: UsageFormatter.tokensString(s.today.inputTokens))
                statChip(title: "输出", value: UsageFormatter.tokensString(s.today.outputTokens))
                statChip(title: "缓存", value: UsageFormatter.tokensString(s.today.cachedTokens))
                Spacer()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12).fill(
                LinearGradient(
                    colors: [Color.pink.opacity(0.14), Color.purple.opacity(0.10)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
        )
    }

    private func hasKnownPrice(_ s: UsageSummary) -> Bool {
        s.models.contains { ModelPricing.price(for: $0.model) != nil }
    }

    private func statChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(PanelInk.text(0.9))
            Text(title)
                .font(.system(size: 9))
                .foregroundColor(PanelInk.text(0.4))
        }
    }

    // MARK: - 7 日柱状图
    private var weekChart: some View {
        let days = usage.summary.days
        let maxValue = days.map(\.totals.totalTokens).max() ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            Text("最近 7 天")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(PanelInk.text(0.6))
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(days) { day in
                    VStack(spacing: 4) {
                        // 柱体
                        RoundedRectangle(cornerRadius: 3)
                            .fill(
                                LinearGradient(
                                    colors: [Color.pink.opacity(0.9), Color.purple.opacity(0.7)],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                            .frame(height: barHeight(value: day.totals.totalTokens, ceiling: maxValue))
                            .frame(maxWidth: .infinity)
                        Text(dayLabel(day.dayStart))
                            .font(.system(size: 9))
                            .foregroundColor(PanelInk.text(0.35))
                    }
                }
            }
            .frame(height: 84)
        }
    }

    private func barHeight(value: Int, ceiling: Int) -> CGFloat {
        guard ceiling > 0, value > 0 else { return 3 }
        let ratio = CGFloat(value) / CGFloat(ceiling)
        return max(4, 56 * ratio)
    }

    private func dayLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "今天" }
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return f.string(from: date)
    }

    // MARK: - 来源 / 模型明细
    private var modelBreakdown: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("按来源 / 模型（近 45 天）")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(PanelInk.text(0.6))
            ForEach(usage.summary.models) { row in
                HStack(spacing: 8) {
                    Image(systemName: row.source == .codex ? "terminal.fill" : "brain.head.profile")
                        .font(.system(size: 10))
                        .foregroundColor(PanelInk.text(0.5))
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.model ?? row.source.rawValue + "（自托管/自定义）")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(PanelInk.text(0.85))
                            .lineLimit(1)
                        Text("入 \(UsageFormatter.tokensString(row.totals.inputTokens)) · 出 \(UsageFormatter.tokensString(row.totals.outputTokens))")
                            .font(.system(size: 9))
                            .foregroundColor(PanelInk.text(0.4))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(UsageFormatter.tokensString(row.totals.totalTokens))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(PanelInk.text(0.85))
                        if let price = ModelPricing.price(for: row.model) {
                            Text(UsageFormatter.costString(ModelPricing.estimateUSD(row.totals, price: price)))
                                .font(.system(size: 9))
                                .foregroundColor(PanelInk.text(0.4))
                        } else {
                            Text("无定价")
                                .font(.system(size: 9))
                                .foregroundColor(PanelInk.text(0.25))
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - 空态
    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("暂未发现本地 CLI 用量记录", systemImage: "clock.arrow.circlepath")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(PanelInk.text(0.85))
            Text("扫描路径（只读）：")
                .font(.system(size: 10))
                .foregroundColor(PanelInk.text(0.5))
            ForEach(CLISource.allCases, id: \.rawValue) { source in
                Text(source.logPathHint)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(PanelInk.text(0.35))
            }
            Text("用过 Codex / Claude Code 后，这里会自动汇总本机会话的 token 消耗与费用估算。")
                .font(.system(size: 10))
                .foregroundColor(PanelInk.text(0.35))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(PanelInk.chip(0.04)))
    }

    // MARK: - 底部说明
    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().background(PanelInk.chip(0.1))
            HStack {
                Text("\(usage.scannedFileCount) 个日志文件 · 只在本机解析，不联网")
                    .font(.system(size: 9))
                    .foregroundColor(PanelInk.text(0.3))
                Spacer()
                if let last = usage.lastScanDate {
                    Text("更新于 " + timeString(last))
                        .font(.system(size: 9))
                        .foregroundColor(PanelInk.text(0.3))
                }
            }
        }
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
