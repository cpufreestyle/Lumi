import Foundation

/// 只读本机日志，区间扫描增量字节，不联网。
///
/// - Codex：~/.codex/sessions 下的 rollout-*.jsonl。日志里的 token_count 是**会话
///   累计值**，先折算成「相邻事件差值、按本地日分桶」再落盘（一天一条 (会话, 当天)
///   条目）。否则跨数天的会话会把整个累计值倒进它最后一次事件的那天：历史天数为
///   0、当天虚高数倍（用户报的「历史数据丢失」）。
/// - Claude Code：~/.claude/projects 下的 jsonl。本身就是逐行增量，全留。
///
/// 轮询档位（沿用 LiveDetection 的按需档）：面板可见 30s 刷新，不可见 15min 兜底。
///
/// 落盘：**条目与扫描状态打进同一个快照键**（单次写入）。偏移记录「读到这里」，
/// 累计基准记录「上次读数到哪」。两者分键落盘时，若重启恰插在两次写入之间，下次
/// 增量读会翻倍或丢数。旧版还只落偏移不落条目：App 重启后内存条目清零、偏移之后
/// 的历史永远不会再被读进来，柱状图重启即丢。现在单键快照，加上 main.swift 启动
/// 时预热单例（懒加载单例若没有视图引用就永不初始化，岛屿关闭时扫描/落盘根本不会
/// 发生——这是之前「重启即丢」的真正原因）。
final class CLIUsageController: ObservableObject {
    static let shared = CLIUsageController()

    @Published private(set) var summary: UsageSummary = UsageSummary()
    @Published private(set) var lastScanDate: Date?
    @Published private(set) var isScanning = false
    @Published private(set) var scannedFileCount: Int = 0

    private var entries: [UsageEntry] = []
    private var scanStates: [String: FileScanState] = [:]

    private let workQueue = DispatchQueue(label: "com.lumi.cliusage", qos: .utility)
    /// v2 快照：条目 + 扫描状态整体落盘（Codex 按天增量口径）。
    private let snapshotKey = "lumi_cli_usage_snapshot_v2"
    /// 旧版（按会话累计口径）遗留键，升级首启清掉，别在 plist 里躺着误导数据。
    private let legacyOffsetsKey = "lumi_cli_usage_offsets_v1"
    private let legacyEntriesKey = "lumi_cli_usage_entries_v1"
    private let maxFilesPerSource = 300
    /// 超过该天数的条目丢弃（看板只看近期）。
    private let retentionDays = 45

    private var codexRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }
    private var claudeRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    private init() {
        if let snapshot = Self.loadSnapshot(key: snapshotKey) {
            entries = snapshot.entries
            scanStates = snapshot.states
        } else {
            // 无 v2 快照（首启或旧版升级）：旧口径只剩每个会话的末值，没有逐日过程，
            // 无法折算成按天增量，只能清空状态全量重读，从日志把历史补回来。
            Self.removeLegacyKeys(legacyOffsetsKey, legacyEntriesKey)
        }
        PollingCoordinator.shared.register(
            id: "cliUsage.scan",
            interval: {
                let state = AppState.shared
                return (state.isExpanded && state.activeModule == .cliUsage) ? 30 : 900
            },
            action: { [weak self] in self?.scan() }
        )
        scan()
    }

    // MARK: - 扫描

    func scan() {
        guard !isScanning else { return }
        isScanning = true

        workQueue.async { [weak self] in
            guard let self else { return }
            let (newEntries, newStates, fileCount) = self.performScan(currentStates: self.scanStates)

            self.scanStates = newStates
            self.entries = Self.merge(self.entries, newEntries)
                .filter { Date().timeIntervalSince($0.timestamp) < TimeInterval(self.retentionDays * 86400) }
            let summary = UsageAggregator.summarize(self.entries)

            DispatchQueue.main.async {
                self.isScanning = false
                self.lastScanDate = Date()
                self.scannedFileCount = fileCount
                self.summary = summary
                self.persistSnapshot()
            }
        }
    }

    /// 后台线程执行。返回（新条目, 全量扫描状态, 命中文件数）。
    private func performScan(currentStates: [String: FileScanState]) -> ([UsageEntry], [String: FileScanState], Int) {
        var newEntries: [UsageEntry] = []
        var nextStates = currentStates
        var fileCount = 0

        let roots: [(CLISource, URL)] = [(.codex, codexRoot), (.claudeCode, claudeRoot)]
        for (source, root) in roots {
            for file in recentJSONLFiles(in: root, cap: maxFilesPerSource) {
                fileCount += 1
                let key = file.path
                let state = currentStates[key] ?? .zero

                guard let handle = FileHandle(forReadingAtPath: key) else { continue }
                defer { try? handle.close() }
                let fileSize = handle.seekToEndOfFile()
                if fileSize > state.offset {
                    // 增量：只读新增字节
                    try? handle.seek(toOffset: UInt64(state.offset))
                    let chunk = handle.readDataToEndOfFile()
                    let read = readEntries(from: chunk, source: source, key: key, state: state)
                    newEntries.append(contentsOf: read.entries)
                    nextStates[key] = read.state
                } else if fileSize < state.offset {
                    // 文件被截断/轮换（变小了）：该文件所有历史条目作废，从头重读替换
                    try? handle.seek(toOffset: 0)
                    let reset = readEntries(handle: handle, source: source, key: key)
                    entries.removeAll { $0.sessionKey == key && $0.source == source }
                    newEntries.append(contentsOf: reset.entries)
                    nextStates[key] = reset.state
                }
            }
        }
        return (newEntries, nextStates, fileCount)
    }

    /// 读一段字节中的完整行；尾部跨段不完整的行留给下次（消耗字节数只算到最后一个
    /// 换行）。Codex 的增量基准只从**已消费**的事件累计，尾部残行下次重读不会漏。
    private func readEntries(
        from chunk: Data,
        source: CLISource,
        key: String,
        state: FileScanState
    ) -> (entries: [UsageEntry], consumedBytes: Int, state: FileScanState) {
        var entries: [UsageEntry] = []
        // 先以裸指针扫换行切行范围：GB 级全量重建时比 Data 下标逐字节快一个量级
        var lineRanges: [Range<Data.Index>] = []
        var lastNewline: Data.Index?
        chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let count = raw.count
            var lineStart = 0
            var index = 0
            while index < count {
                if raw[index] == 0x0A {
                    if index > lineStart { lineRanges.append(lineStart..<index) }
                    lineStart = index + 1
                    lastNewline = index
                }
                index += 1
            }
        }
        guard let lastNewline else { return (entries, 0, state) }
        let consumedBytes = lastNewline + 1

        var codexReadings: [CodexReading] = []
        for range in lineRanges {
            guard let text = String(data: chunk[range], encoding: .utf8) else { continue }
            switch source {
            case .codex:
                // Codex 会话里 token_count 行只占一小部分，先做一次廉价子串预筛
                // 再进 JSON 解析：全量重建（日志合计 GB 级）时差一个数量级。
                if !text.contains("token_count") { continue }
                if let reading = CLIUsageParser.parseCodexLine(text) { codexReadings.append(reading) }
            case .claudeCode:
                if let entry = CLIUsageParser.parseClaudeCodeLine(text, sessionKey: key) {
                    entries.append(entry)
                }
            }
        }

        var nextState = state
        nextState.offset = state.offset + consumedBytes
        if source == .codex {
            let (days, cumulative) = CLIUsageParser.codexDayDeltas(codexReadings, base: state.cumulative)
            nextState.cumulative = cumulative
            for day in days where day.inputTokens + day.outputTokens + day.cachedTokens > 0 {
                entries.append(UsageEntry(
                    source: .codex,
                    sessionKey: key,
                    model: nil,
                    timestamp: day.timestamp,
                    inputTokens: day.inputTokens,
                    outputTokens: day.outputTokens,
                    cachedTokens: day.cachedTokens,
                    cachedIncludedInInput: true
                ))
            }
        }
        return (entries, consumedBytes, nextState)
    }

    /// FileHandle 从头读完整文件（文件被截断/轮换时用）。
    private func readEntries(handle: FileHandle, source: CLISource, key: String)
        -> (entries: [UsageEntry], state: FileScanState) {
        let data = handle.readDataToEndOfFile()
        let read = readEntries(from: data, source: source, key: key, state: .zero)
        return (read.entries, read.state)
    }

    /// 递归列出最近修改的 .jsonl（按 mtime 倒序取前 cap 个）。
    /// 保留期外的文件不可能贡献保留期内的条目，直接跳过：一次性全量重建时
    /// 不必再把几个月前的旧会话完整读一遍。
    private func recentJSONLFiles(in root: URL, cap: Int) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        let cutoff = Date().addingTimeInterval(-TimeInterval(retentionDays * 86400))
        var candidates: [(url: URL, mtime: Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            // macOS 会话 JSONL 无扩展名/或就是 .jsonl，两种都放行
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            let mtime = values?.contentModificationDate ?? .distantPast
            if mtime < cutoff { continue }
            candidates.append((url, mtime))
        }
        candidates.sort { $0.mtime > $1.mtime }
        return Array(candidates.prefix(cap).map { $0.url })
    }

    // MARK: - 持久化

    /// 条目 + 扫描状态整体归档（单键一次写入，避免两者不一致导致重启翻倍或丢数）。
    private func persistSnapshot() {
        let snapshot = UsageSnapshot(entries: entries, states: scanStates)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: snapshotKey)
    }

    private static func loadSnapshot(key: String) -> UsageSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(UsageSnapshot.self, from: data) else { return nil }
        return decoded
    }

    /// 清掉旧版遗留键（按会话累计口径的偏移/条目）。
    private static func removeLegacyKeys(_ offsetsKey: String, _ entriesKey: String) {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: offsetsKey) != nil { defaults.removeObject(forKey: offsetsKey) }
        if defaults.object(forKey: entriesKey) != nil { defaults.removeObject(forKey: entriesKey) }
    }

    // MARK: - 合并

    /// 合并新读到的条目：Codex 按「会话 + 当天」累加增量（同一天常被多次分段读入）；
    /// Claude 按身份去重。文件截断重读 / 快照缺失全量重读都不会翻倍。
    static func merge(_ existing: [UsageEntry], _ incoming: [UsageEntry]) -> [UsageEntry] {
        var out = existing
        var seenClaude = Set(out.filter { $0.source == .claudeCode }.map(Self.identity))
        var codexIndex: [CodexDayKey: Int] = [:]
        for (index, entry) in out.enumerated() where entry.source == .codex {
            codexIndex[Self.codexDayKey(entry)] = index
        }
        for entry in incoming {
            switch entry.source {
            case .codex:
                let key = Self.codexDayKey(entry)
                if let index = codexIndex[key] {
                    let old = out[index]
                    out[index] = UsageEntry(
                        source: .codex,
                        sessionKey: old.sessionKey,
                        model: old.model,
                        timestamp: max(old.timestamp, entry.timestamp),
                        inputTokens: old.inputTokens + entry.inputTokens,
                        outputTokens: old.outputTokens + entry.outputTokens,
                        cachedTokens: old.cachedTokens + entry.cachedTokens,
                        cachedIncludedInInput: old.cachedIncludedInInput
                    )
                } else {
                    codexIndex[key] = out.count
                    out.append(entry)
                }
            case .claudeCode:
                if seenClaude.insert(Self.identity(entry)).inserted { out.append(entry) }
            }
        }
        return out
    }

    /// Codex 条目身份：同会话、同一天（条目内是增量，相遇时相加）。
    static func codexDayKey(_ entry: UsageEntry) -> CodexDayKey {
        CodexDayKey(
            sessionKey: entry.sessionKey,
            dayStart: Calendar.current.startOfDay(for: entry.timestamp)
        )
    }

    /// Claude 条目身份：同文件、同秒、同用量的行视为同一条（日志行无 ID）。
    private static func identity(_ entry: UsageEntry) -> String {
        [
            entry.sessionKey,
            String(entry.timestamp.timeIntervalSince1970),
            String(entry.inputTokens),
            String(entry.outputTokens),
            String(entry.cachedTokens),
        ].joined(separator: "|")
    }
}

/// 单文件扫描状态：读到的偏移 + 上次累计读数（Codex 增量基准；Claude 不跟踪，恒零）。
struct FileScanState: Codable {
    var offset: Int
    var cumulative: CodexTotals

    init(offset: Int, cumulative: CodexTotals = .zero) {
        self.offset = offset
        self.cumulative = cumulative
    }

    static let zero = FileScanState(offset: 0, cumulative: .zero)
}

/// 落盘快照：条目与扫描状态必须同生同灭（见 CLIUsageController 头注释）。
private struct UsageSnapshot: Codable {
    var entries: [UsageEntry]
    var states: [String: FileScanState]
}
