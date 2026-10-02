import Foundation

/// AI 助手设置。API Key 走 Keychain，其余为普通偏好；
/// `watchClipboard` 默认关闭——剪贴板是高敏数据，必须用户显式开启。
struct AIAssistSettings: Equatable {
    var watchClipboard: Bool = false
    var endpoint: String = ""
    var model: String = ""

    /// 一键填入用的本机中继端点（cc-switch 网关，本机 LLM 流量默认走这里）。
    static let localRelayEndpoint = "http://127.0.0.1:15721/v1"

    /// 单次请求的输出上限（token）。
    /// 不对输入设字数上限——用户复制的整段文字原样发送；
    /// 上下文/输出真的超限时由服务端报错，AIAssistErrorTranslator 会给中文可行动指引。
    static let maxOutputTokens = 32768

    private enum Key {
        static let watch   = "lumi_ai_watch_clipboard"
        static let endpoint = "lumi_ai_endpoint"
        static let model   = "lumi_ai_model"
    }

    static let apiKeyKeychainKey = "lumi_ai_assist_api_key"

    static func load(from defaults: UserDefaults = .standard) -> AIAssistSettings {
        AIAssistSettings(
            watchClipboard: defaults.object(forKey: Key.watch) as? Bool ?? false,
            endpoint: (defaults.string(forKey: Key.endpoint) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            model: (defaults.string(forKey: Key.model) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(watchClipboard, forKey: Key.watch)
        defaults.set(endpoint, forKey: Key.endpoint)
        defaults.set(model, forKey: Key.model)
    }

    /// Keychain 中的 API Key。本地代理（如自建 LiteLLM/llama.cpp）可留空。
    static func apiKey() -> String? {
        Keychain.get(apiKeyKeychainKey)
    }

    static func setAPIKey(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // 空值等价于清除（本地代理场景）
            _ = Keychain.set("", for: apiKeyKeychainKey)
        } else {
            _ = Keychain.set(trimmed, for: apiKeyKeychainKey)
        }
    }

    /// 端点和模型都填了才算可用。
    var isConfigured: Bool {
        !endpoint.isEmpty && !model.isEmpty
    }

    /// 把用户填的端点规整成完整的 chat/completions URL。
    /// 容许三种写法：http://host:port、http://host:port/v1、完整 …/chat/completions。
    func chatCompletionsURL() -> URL? {
        let base = endpoint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty, let url = URL(string: base) else { return nil }
        if url.path.lowercased().hasSuffix("chat/completions") { return url }
        if !url.path.isEmpty { return URL(string: base + "/chat/completions") }
        return URL(string: base + "/v1/chat/completions")
    }

    /// 构造 OpenAI 兼容 chat/completions 请求体（JSON）。
    func buildRequestBody(action: AIAction, text: String, stream: Bool = true) -> Data? {
        let payload: [String: Any] = [
            "model": model,
            "stream": stream,
            "max_tokens": Self.maxOutputTokens,
            "temperature": 0.3,
            "messages": [
                ["role": "system", "content": action.systemPrompt],
                // 不截断：整段原文直送（含超长片段，交给服务端判定上下文上限）
                ["role": "user", "content": text],
            ],
        ]
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    /// 连接检测用的最小请求体（非流式、无 system，几秒内就该有回音）。
    func buildProbeBody() -> Data? {
        let payload: [String: Any] = [
            "model": model,
            "stream": false,
            "max_tokens": 64,
            "messages": [
                ["role": "user", "content": "只回复两个字：收到"]
            ]
        ]
        return try? JSONSerialization.data(withJSONObject: payload)
    }
}
