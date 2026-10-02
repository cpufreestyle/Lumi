import Foundation

/// 把 OpenAI 兼容端点的错误响应翻译成用户可行动的中文提示（纯函数，可单测）。
///
/// 兼容两种错误体形状：
/// - OpenAI：`{"error":{"message":"...","type":"insufficient_quota","code":"..."}}`
/// - StepFun 等：`{"error":{"message":"...","type":"quota_exceeded"}}`
enum AIAssistErrorTranslator {
    /// 生成展示文案。`body` 为服务端原始响应体（可为空/非 JSON）。
    static func friendlyMessage(statusCode: Int, body: String?) -> String {
        let trimmed = (body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let message = extractMessage(from: trimmed)
        let type = extractType(from: trimmed)
        let haystack = "\(type ?? "") \(message ?? "")".lowercased()

        // 常见错误类型 → 可直接操作的指引（按特征串匹配，兼容不同服务商用词）
        if containsAny(haystack, ["quota_exceeded", "insufficient_quota", "quota", "billing"]) {
            return "账号额度不足：请到服务商控制台充值或检查套餐，到账后重试"
        }
        if containsAny(haystack, ["invalid_api_key", "incorrect api key", "invalid api key", "unauthorized"]) || statusCode == 401 {
            return "API Key 无效：请在「端点设置」里更换后重试"
        }
        if containsAny(haystack, ["model_not_found", "model not found", "does not exist", "doesn't exist", "unknown model"]) {
            return "模型不存在：请检查「模型名」是否与服务商提供的一致"
        }
        if statusCode == 429 || containsAny(haystack, ["rate limit", "too many requests", "rate_limit"]) {
            return "请求过于频繁：稍等几秒再试"
        }
        if containsAny(haystack, ["context_length_exceeded", "context length", "too many tokens", "maximum context"]) {
            return "文本超出模型上下文或输出上限：缩短片段，或换用上下文更大的模型"
        }
        if statusCode == 404 {
            return "端点不存在：请检查 API 地址（形如 https://host:port/v1）"
        }
        if let message, !message.isEmpty {
            return "服务端错误（HTTP \(statusCode)）：\(message)"
        }
        if !trimmed.isEmpty {
            return "服务端错误（HTTP \(statusCode)）：\(String(trimmed.prefix(200)))"
        }
        return "服务端错误（HTTP \(statusCode)）"
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    /// 从 `{"error":{"message":"…"}}` 或 `{"message":"…"}` 提 message。
    static func extractMessage(from body: String) -> String? {
        guard let json = parseJSON(body) else { return nil }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        if let error = json["error"] as? String {
            return error
        }
        return json["message"] as? String
    }

    /// 从错误体提 type（如 quota_exceeded / invalid_api_key）。
    static func extractType(from body: String) -> String? {
        guard let json = parseJSON(body) else { return nil }
        if let error = json["error"] as? [String: Any] {
            return error["type"] as? String ?? error["code"] as? String
        }
        return json["type"] as? String
    }

    private static func parseJSON(_ body: String) -> [String: Any]? {
        guard !body.isEmpty, let data = body.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
