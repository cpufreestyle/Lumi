import XCTest
import Foundation
@testable import Lumi

/// AI CLI 用量解析/聚合/定价的纯逻辑测试。
/// codex 行与 claude 行均为本机真实日志样本（09-23 抓取）。
final class CLIUsageParserTests: XCTestCase {

    /// 真实 Codex token_count 行（累计值）。
    private let codexLine = #"{"timestamp":"2026-09-23T12:25:00.841Z","ordinal":31,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":34066,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":194,"reasoning_output_tokens":0,"total_tokens":34260},"last_token_usage":{"input_tokens":34066,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":194,"reasoning_output_tokens":0,"total_tokens":34260},"model_context_window":258400},"rate_limits":{"limit_id":"codex"}}}"#

    /// 真实 Claude Code assistant 行（零值 synthetic + 非零真实行）。
    private let claudeSyntheticLine = #"{"type":"assistant","model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"timestamp":"2026-09-23T14:37:24.127Z"}"#
    private let claudeRealLine = #"{"type":"assistant","sessionId":"abc","message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":1200,"output_tokens":340,"cache_creation_input_tokens":8000,"cache_read_input_tokens":3000}},"timestamp":"2026-09-23T14:40:00.000Z"}"#

    private let now = UsageDate.parse("2026-09-23T15:00:00.000Z")!

    // MARK: - Codex 解析

    func testCodexLineParsing() {
        let parsed = CLIUsageParser.parseCodexLine(codexLine)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.inputTokens, 34066)
        XCTAssertEqual(parsed?.outputTokens, 194)
        XCTAssertEqual(parsed?.cachedTokens, 0)
        XCTAssertEqual(parsed?.timestamp, UsageDate.parse("2026-09-23T12:25:00.841Z"))
    }

    func testCodexEntryHasCachedIncludedInInput() {
        let entry = CLIUsageParser.codexEntry(from: codexLine, sessionKey: "/tmp/s1")
        XCTAssertEqual(entry?.source, .codex)
        // cached ⊂ input：总额不重复计
        XCTAssertEqual(entry?.totalTokens, 34066 + 194)
    }

    func testNonTokenCountCodexLinesIgnored() {
        let other = #"{"timestamp":"2026-09-23T12:25:00.841Z","type":"session_meta","payload":{"id":"x"}}"#
        XCTAssertNil(CLIUsageParser.codexEntry(from: other, sessionKey: "/tmp/s1"))
        XCTAssertNil(CLIUsageParser.parseCodexLine("garbage"))
        XCTAssertNil(CLIUsageParser.parseCodexLine(""))
    }

    // MARK: - Claude 解析

    func testClaudeRealLineParsing() {
        let entry = CLIUsageParser.parseClaudeCodeLine(claudeRealLine, sessionKey: "/tmp/c1")
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.source, .claudeCode)
        XCTAssertEqual(entry?.model, "claude-sonnet-4-5")
        XCTAssertEqual(entry?.inputTokens, 1200)
        XCTAssertEqual(entry?.outputTokens, 340)
        XCTAssertEqual(entry?.cachedTokens, 11000)  // cache_read + cache_creation
        // Claude 缓存独立计费，计入总额
        XCTAssertEqual(entry?.cachedIncludedInInput, false)
        XCTAssertEqual(entry?.totalTokens, 1200 + 340 + 11000)
    }

    func testClaudeSyntheticZeroUsageSkipped() {
        XCTAssertNil(CLIUsageParser.parseClaudeCodeLine(claudeSyntheticLine, sessionKey: "/tmp/c2"))
    }

    func testClaudeNonAssistantLinesIgnored() {
        let userLine = #"{"type":"user","message":{"content":"hi"},"timestamp":"2026-09-23T14:41:00.000Z"}"#
        XCTAssertNil(CLIUsageParser.parseClaudeCodeLine(userLine, sessionKey: "/tmp/c3"))
    }

    // MARK: - 聚合

    // MARK: - codexDayDeltas 按天增量折算

    /// 固定 UTC 日历：分桶断言不能被本机时区（GMT+8 会把晚间 UTC 划到次日）带偏。
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testCodexDayDeltasSplitByDay() {
        // 累计值必须随时序单调递增（真实日志如此），否则回落会被判成计数器复位
        let day2 = (UsageDate.parse("2026-09-22T10:00:00.000Z")!, 3200, 0, 260)
        let day1 = (UsageDate.parse("2026-09-23T01:00:00.000Z")!, 4200, 0, 360)
        let day1Later = (UsageDate.parse("2026-09-23T20:00:00.000Z")!, 5700, 0, 560)

        let (days, cumulative) = CLIUsageParser.codexDayDeltas(
            [day2, day1, day1Later], base: .zero, calendar: utcCalendar
        )

        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days[0].inputTokens, 3200)
        XCTAssertEqual(days[0].outputTokens, 260)
        // 同一天的两段增量相加，不叠加整段累计
        XCTAssertEqual(days[1].inputTokens, 1000 + 1500)
        XCTAssertEqual(days[1].outputTokens, 100 + 200)
        XCTAssertEqual(cumulative.input, 5700)
        XCTAssertEqual(cumulative.output, 560)
    }

    func testCodexDayDeltasUsesBaseAcrossSegments() {
        let reading = (UsageDate.parse("2026-09-23T12:25:00.841Z")!, 40000, 0, 300)
        let (days, cumulative) = CLIUsageParser.codexDayDeltas(
            [reading], base: CodexTotals(input: 34066, output: 194, cached: 0)
        )
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days[0].inputTokens, 5934)
        XCTAssertEqual(days[0].outputTokens, 106)
        XCTAssertEqual(cumulative.input, 40000)
    }

    func testCodexDayDeltasClampsCounterReset() {
        let reset = (UsageDate.parse("2026-09-23T12:00:00.000Z")!, 10, 0, 5)
        let (days, cumulative) = CLIUsageParser.codexDayDeltas(
            [reset], base: CodexTotals(input: 40000, output: 300, cached: 0)
        )
        XCTAssertEqual(days[0].inputTokens, 0)
        XCTAssertEqual(days[0].outputTokens, 0)
        XCTAssertEqual(cumulative.input, 10)
    }

    func testCodexSameSessionDayKeepsLargestDelta() throws {
        let e1 = CLIUsageParser.codexEntry(from: codexLine, sessionKey: "/tmp/s1")!
        let line2 = codexLine
            .replacingOccurrences(of: "2026-09-23T12:25:00.841Z", with: "2026-09-23T13:00:00.000Z")
            .replacingOccurrences(of: "\"input_tokens\":34066", with: "\"input_tokens\":15934")
            .replacingOccurrences(of: "\"output_tokens\":194", with: "\"output_tokens\":306")
        let e2 = try XCTUnwrap(CLIUsageParser.codexEntry(from: line2, sessionKey: "/tmp/s1"))

        let summary = UsageAggregator.summarize([e1, e2], now: now)
        XCTAssertEqual(summary.today.inputTokens, 34066)
        XCTAssertEqual(summary.today.outputTokens, 194)
        XCTAssertEqual(summary.sessionCount, 1)
    }

    func testCodexDifferentDaysNotDeduped() throws {
        let today = try XCTUnwrap(CLIUsageParser.codexEntry(from: codexLine, sessionKey: "/tmp/s1"))
        let otherDayLine = codexLine
            .replacingOccurrences(of: "2026-09-23T12:25:00.841Z", with: "2026-09-21T09:00:00.000Z")
        let otherDay = try XCTUnwrap(CLIUsageParser.codexEntry(from: otherDayLine, sessionKey: "/tmp/s1"))

        let summary = UsageAggregator.summarize([today, otherDay], now: now)
        XCTAssertEqual(summary.days.count, 7)
        XCTAssertEqual(summary.last30Days.totalTokens, 34260 * 2)
    }

    func testTodayAndYesterdaySplit() throws {
        let todayCodex = try XCTUnwrap(CLIUsageParser.codexEntry(from: codexLine, sessionKey: "/tmp/s1"))
        let yesterdayLine = codexLine
            .replacingOccurrences(of: "2026-09-23T12:25:00.841Z", with: "2026-09-22T02:00:00.000Z")
        let yesterdayCodex = try XCTUnwrap(CLIUsageParser.codexEntry(from: yesterdayLine, sessionKey: "/tmp/s2"))
        let claude = try XCTUnwrap(CLIUsageParser.parseClaudeCodeLine(claudeRealLine, sessionKey: "/tmp/c1"))

        let summary = UsageAggregator.summarize([todayCodex, yesterdayCodex, claude], now: now)
        XCTAssertEqual(summary.today.totalTokens, 34260 + 12540)      // codex today + claude today
        XCTAssertEqual(summary.yesterday.totalTokens, 34260)
        XCTAssertEqual(summary.days.count, 7)
        XCTAssertEqual(summary.last30Days.totalTokens, 34260 + 34260 + 12540)
        XCTAssertEqual(summary.sessionCount, 3)
    }

    // MARK: - 定价

    func testKnownModelPricing() {
        XCTAssertNotNil(ModelPricing.price(for: "claude-sonnet-4-5"))
        XCTAssertNotNil(ModelPricing.price(for: "claude-opus-4-1"))
        XCTAssertNotNil(ModelPricing.price(for: "gpt-5-codex"))
        XCTAssertEqual(ModelPricing.price(for: "claude-3-5-haiku-20241022")?.inputPerMillion, 0.8)
    }

    func testSelfHostedAndUnknownNoPrice() {
        // 自托管/自定义端点不猜价，避免给出误导性数字
        XCTAssertNil(ModelPricing.price(for: "Qwen3.6-27B-NVFP4"))
        XCTAssertNil(ModelPricing.price(for: "deepseek-r1"))
        XCTAssertNil(ModelPricing.price(for: "<synthetic>"))
        XCTAssertNil(ModelPricing.price(for: nil))
        XCTAssertNil(ModelPricing.price(for: ""))
    }

    func testEstimateUSDMath() {
        var totals = UsageTotals.empty
        let entry = UsageEntry(
            source: .claudeCode, sessionKey: "s", model: "claude-sonnet-4-5",
            timestamp: now, inputTokens: 1_000_000, outputTokens: 1_000_000,
            cachedTokens: 1_000_000, cachedIncludedInInput: false
        )
        totals.add(entry)
        let price = ModelPricing.price(for: "claude-sonnet-4-5")!
        // 3 + 15 + 0.3 = 18.3
        XCTAssertEqual(ModelPricing.estimateUSD(totals, price: price), 18.3, accuracy: 0.001)
        XCTAssertEqual(entry.cachedIncludedInInput, false)
    }

    func testEstimateSummaryOnlyCountsKnownModels() {
        let known = UsageEntry(source: .claudeCode, sessionKey: "a", model: "claude-opus-4-1", timestamp: now,
                               inputTokens: 1_000_000, outputTokens: 0, cachedTokens: 0, cachedIncludedInInput: false)
        let unknown = UsageEntry(source: .codex, sessionKey: "b", model: nil, timestamp: now,
                                 inputTokens: 9_000_000, outputTokens: 0, cachedTokens: 0, cachedIncludedInInput: true)
        let summary = UsageAggregator.summarize([known, unknown], now: now)
        // opus: 15 * 1M = $15；未知模型不计价
        XCTAssertEqual(ModelPricing.estimateSummaryUSD(summary), 15.0, accuracy: 0.001)
    }

    // MARK: - 格式化

    func testTokenFormatting() {
        XCTAssertEqual(UsageFormatter.tokensString(842), "842")
        XCTAssertEqual(UsageFormatter.tokensString(1500), "1.50k")
        XCTAssertEqual(UsageFormatter.tokensString(34260), "34.3k")
        XCTAssertEqual(UsageFormatter.tokensString(1_234_567), "1.23M")
    }

    func testCostFormatting() {
        XCTAssertEqual(UsageFormatter.costString(0), "$0.00")
        XCTAssertEqual(UsageFormatter.costString(0.42), "$0.42")
        XCTAssertEqual(UsageFormatter.costString(12.3), "$12.30")
        XCTAssertEqual(UsageFormatter.costString(0.0042), "$0.0042")
    }
}
