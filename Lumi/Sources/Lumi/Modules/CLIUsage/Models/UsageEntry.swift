import Foundation

/// 一条归一化后的用量记录。
/// Codable：条目要整体落盘（UserDefaults），否则重启即丢历史。
struct UsageEntry: Equatable, Sendable, Codable {
    let source: CLISource
    /// 会话标识（取日志文件路径）：Codex 的累计值需按此去重。
    let sessionKey: String
    /// 模型名；nil = 未知或自托管端点。
    let model: String?
    let timestamp: Date
    let inputTokens: Int
    let outputTokens: Int
    let cachedTokens: Int
    /// Codex 的 cached 是 input 的子集（命中缓存部分），不重复计入总额；
    /// Claude 的 cache_read/cache_creation 独立计费，需计入。
    let cachedIncludedInInput: Bool

    var totalTokens: Int {
        inputTokens + outputTokens + (cachedIncludedInInput ? 0 : cachedTokens)
    }
}

/// Codex 条目身份：会话 + 当天。语义 B 下条目内是“当天增量”，
/// 同一会话同一天的多条需合并而非去重。
struct CodexDayKey: Hashable, Sendable {
    let sessionKey: String
    let dayStart: Date
}
