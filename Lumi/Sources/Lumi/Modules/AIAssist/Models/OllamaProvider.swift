import Foundation

/// 本机 Ollama（默认 http://127.0.0.1:11434）运行时的只读探测与描述。
///
/// 职责边界：只读探测「装了哪些模型、什么规格」，并把本机 Ollama 以 OpenAI 兼容端点
/// （/v1）形式喂给划词 AI，实现零配置、免费、离线。不复制 Ollama 任何实现——
/// 走它自己暴露的 HTTP 接口（接口朝上复用，与 atv-remote 集成为同一原则）。
enum OllamaProvider {
    /// 本机默认监听地址。
    static let defaultHost = "http://127.0.0.1:11434"
    /// Ollama 的 OpenAI 兼容入口（chat/completions 的宿主）。
    static let openAICompatBase = defaultHost + "/v1"
    /// 原生模型清单路径（含体积 / 规格 / capabilities，信息最全）。
    static let tagsPath = "/api/tags"
    static var tagsURL: URL? { URL(string: defaultHost + tagsPath) }
    /// OpenAI 兼容 chat/completions 全址（与 AIAssistSettings 规整结果一致）。
    static var chatCompletionsURL: URL? { URL(string: openAICompatBase + "/chat/completions") }

    /// 一个本机模型的最小描述。
    struct Model: Identifiable, Equatable, Sendable {
        let name: String
        let sizeBytes: Int64?
        let parameterSize: String?
        let family: String?
        let capabilities: [String]

        var id: String { name }

        init(name: String,
             sizeBytes: Int64? = nil,
             parameterSize: String? = nil,
             family: String? = nil,
             capabilities: [String] = []) {
            self.name = name
            self.sizeBytes = sizeBytes
            self.parameterSize = parameterSize
            self.family = family
            self.capabilities = capabilities
        }

        /// 是否能对话。有 capabilities 时精确判定；老版本 Ollama 无此字段则按名字兜底，
        /// 排除 embedding / rerank 这类「只做向量或重排」的非对话模型。
        var isChatCapable: Bool {
            if !capabilities.isEmpty { return capabilities.contains("completion") }
            let lower = name.lowercased()
            return !lower.contains("embed") && !lower.contains("rerank")
        }

        var isVisionCapable: Bool { capabilities.contains("vision") }

        /// 一行规格摘要，如「10.7B · 7.8 GB · 视觉」。缺字段不产生空片段。
        var subtitle: String {
            var parts: [String] = []
            if let p = parameterSize, !p.isEmpty { parts.append(p) }
            if let b = sizeBytes { parts.append(formatBytes(b)) }
            if isVisionCapable { parts.append("视觉") }
            return parts.joined(separator: " · ")
        }
    }

    // MARK: - 解析

    /// 解析原生 /api/tags：读 models[]，逐条 parseEntry。
    static func parseTags(_ json: String) -> [Model] {
        guard let root = dictionary(json), let list = root["models"] as? [[String: Any]] else { return [] }
        return list.compactMap(parseEntry)
    }

    /// 解析 OpenAI 兼容 /v1/models：只读 data[].id，其余规格留空。
    static func parseOpenAIModels(_ json: String) -> [Model] {
        guard let root = dictionary(json), let list = root["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { entry -> Model? in
            guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
            return Model(name: id)
        }
    }

    private static func dictionary(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any]
        else { return nil }
        return dict
    }

    private static func parseEntry(_ entry: [String: Any]) -> Model? {
        guard let name = entry["name"] as? String, !name.isEmpty else { return nil }
        // size 理论是 Int，容错浮点脏数据：统一按 NSNumber 取整数值。
        let size = (entry["size"] as? NSNumber)?.int64Value
        var parameterSize: String?
        var family: String?
        if let details = entry["details"] as? [String: Any] {
            parameterSize = details["parameter_size"] as? String
            family = details["family"] as? String
        }
        let capabilities = entry["capabilities"] as? [String] ?? []
        return Model(name: name, sizeBytes: size, parameterSize: parameterSize,
                     family: family, capabilities: capabilities)
    }

    // MARK: - 选择与度量

    /// 默认推荐：可对话模型里取规模最大者。全为 embedding / rerank 时返回 nil。
    static func recommendedChatModel(from models: [Model]) -> Model? {
        models.filter { $0.isChatCapable }.max(by: { scale($0) < scale($1) })
    }

    /// 规模度量（单位：十亿参数）。优先 parameter_size，回退文件体积。
    static func scale(_ model: Model) -> Double {
        if let p = model.parameterSize, let v = parseParameterSize(p) { return v }
        return Double(model.sizeBytes ?? 0) / 1_000_000_000
    }

    /// "10.7B"→10.7、"137M"→0.137（单位十亿）。无法解析返回 nil。
    static func parseParameterSize(_ raw: String) -> Double? {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !token.isEmpty else { return nil }
        var multiplier = 1.0
        var numberPart = token
        if let last = token.last {
            switch last {
            case "B": multiplier = 1.0; numberPart = String(token.dropLast())
            case "M": multiplier = 0.001; numberPart = String(token.dropLast())
            case "K": multiplier = 0.000001; numberPart = String(token.dropLast())
            default: break
            }
        }
        let number = numberPart.trimmingCharacters(in: .whitespaces)
        guard let value = Double(number) else { return nil }
        return value * multiplier
    }

    /// 人可读体积：GB / MB / B（不依赖本地化，便于测试稳定断言）。
    static func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_000_000
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return "\(bytes) B"
    }
}
