import Foundation

/// 逐行解析两个 CLI 的 JSONL 日志。纯函数，可单测（fixture 用真实日志样本）。
enum CLIUsageParser {
    /// Codex：event_msg / token_count 行，取 total_token_usage。**这是会话累计值，
    /// 不是增量**；落盘前必须经 codexDayDeltas 折算成按天增量，否则跨天会话会把
    /// 整个累计值倒进最后一天。
    static func parseCodexLine(_ line: String) -> (timestamp: Date, inputTokens: Int, cachedTokens: Int, outputTokens: Int)? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "event_msg",
              let payload = obj["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let usage = info["total_token_usage"] as? [String: Any],
              let timestamp = UsageDate.parse(obj["timestamp"] as? String)
        else { return nil }
        let cached = (usage["cached_input_tokens"] as? Int ?? 0)
            + (usage["cache_write_input_tokens"] as? Int ?? 0)
        return (
            timestamp,
            usage["input_tokens"] as? Int ?? 0,
            cached,
            usage["output_tokens"] as? Int ?? 0
        )
    }

    /// Claude Code：assistant 行，usage 全零的行（如 synthetic 占位）跳过。
    static func parseClaudeCodeLine(_ line: String, sessionKey: String) -> UsageEntry? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "assistant",
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let timestamp = UsageDate.parse(obj["timestamp"] as? String)
        else { return nil }

        let input = usage["input_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? 0
        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
        let cacheCreation = usage["cache_creation_input_tokens"] as? Int ?? 0
        let cached = cacheRead + cacheCreation
        guard input + output + cached > 0 else { return nil }

        let rawModel = message["model"] as? String
        let model = (rawModel == nil || rawModel == "<synthetic>") ? nil : rawModel
        return UsageEntry(
            source: .claudeCode,
            sessionKey: sessionKey,
            model: model,
            timestamp: timestamp,
            inputTokens: input,
            outputTokens: output,
            cachedTokens: cached,
            cachedIncludedInInput: false
        )
    }

    /// 单行原始条目（累计值口径）。仅测试 / 调试直接使用；落盘口径是
    /// codexDayDeltas 产出的「按天增量」条目。
    static func codexEntry(from line: String, sessionKey: String) -> UsageEntry? {
        guard let parsed = parseCodexLine(line) else { return nil }
        return UsageEntry(
            source: .codex,
            sessionKey: sessionKey,
            model: nil,
            timestamp: parsed.timestamp,
            inputTokens: parsed.inputTokens,
            outputTokens: parsed.outputTokens,
            cachedTokens: parsed.cachedTokens,
            cachedIncludedInInput: true
        )
    }

    // MARK: - Codex 按天增量折算

    /// 把一段区间内的累计读数（按出现顺序）折算成「本地日增量」。
    ///
    /// 相邻读数之差才是该区间真实用量。Codex 会话跨天时若直接把会话累计值记到最后
    /// 一次事件的那天，历史天数会被清零、当天虚高数倍（用户报的「历史数据丢失」）。
    /// 读数回退（计数器复位，如会话恢复）时该次增量记 0，基准跟随新值。
    ///
    /// - Returns: days 按本地日分桶（时间戳取当天最后一次读数）；cumulative 是最后
    ///   一次读数，作为下一段的增量基准随扫描状态落盘。
    static func codexDayDeltas(
        _ readings: [CodexReading],
        base: CodexTotals,
        calendar: Calendar = .current
    ) -> (days: [CodexDayDelta], cumulative: CodexTotals) {
        var previous = base
        var buckets: [Date: CodexDayDelta] = [:]
        for reading in readings {
            let deltaInput = max(0, reading.inputTokens - previous.input)
            let deltaOutput = max(0, reading.outputTokens - previous.output)
            let deltaCached = max(0, reading.cachedTokens - previous.cached)
            previous = CodexTotals(
                input: reading.inputTokens,
                output: reading.outputTokens,
                cached: reading.cachedTokens
            )

            let day = calendar.startOfDay(for: reading.timestamp)
            var bucket = buckets[day] ?? CodexDayDelta(
                dayStart: day,
                timestamp: reading.timestamp,
                inputTokens: 0,
                outputTokens: 0,
                cachedTokens: 0
            )
            bucket.timestamp = reading.timestamp
            bucket.inputTokens += deltaInput
            bucket.outputTokens += deltaOutput
            bucket.cachedTokens += deltaCached
            buckets[day] = bucket
        }
        return (buckets.values.sorted { $0.dayStart < $1.dayStart }, previous)
    }
}

/// Codex 累计读数：一个 token_count 事件的总量。
typealias CodexReading = (timestamp: Date, inputTokens: Int, cachedTokens: Int, outputTokens: Int)

/// 累计基准 / 折算结果：三个单调计数器。随文件扫描状态一起落盘。
struct CodexTotals: Equatable, Sendable, Codable {
    var input: Int
    var output: Int
    var cached: Int

    static let zero = CodexTotals(input: 0, output: 0, cached: 0)
}

/// 一天的 Codex 增量。timestamp 取当天最后一次读数（分桶 / 展示 / 合并用）。
struct CodexDayDelta: Equatable, Sendable {
    var dayStart: Date
    var timestamp: Date
    var inputTokens: Int
    var outputTokens: Int
    var cachedTokens: Int
}
