import Foundation

/// 解析 `text/event-stream` 增量。只依赖 Foundation，可单测。
enum OpenAIStreamParser {
    /// 从一行原始 SSE 数据中取增量文本。`data: [DONE]`、空行、无文本增量的帧均返回 nil。
    static func deltaText(fromLine raw: String) -> String? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { return nil }
        var payload = line
        if payload.hasPrefix("data:") {
            payload = String(payload.dropFirst(5))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if payload.isEmpty || payload == "[DONE]" { return nil }
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any],
              let content = delta["content"] as? String
        else { return nil }
        return content
    }

    /// 非流式响应的兜底解析：`choices[0].message.content`。
    static func messageText(fromJSON raw: String) -> String? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String
        else { return nil }
        return content
    }
}
