import SwiftUI

final class ClaudeCodeController: ObservableObject {
    static let shared = ClaudeCodeController()

    @Published var messages: [CCMessage] = []
    @Published var inputText: String = ""
    @Published var isLoading: Bool = false
    @Published var apiKey: String = ""
    @Published var showSettings: Bool = false

    private let defaultsKey = "claude_api_key"
    private let baseURL = "https://api.anthropic.com/v1/messages"
    private let model = "claude-sonnet-4-20250514"

    struct CCMessage: Identifiable {
        let id = UUID()
        let role: Role
        let content: String
        let timestamp: Date
        /// 开场白为 UI 占位提示，不应进入发给 API 的对话历史
        var isGreeting: Bool = false

        enum Role {
            case user, assistant
        }
    }

    private init() {
        // 优先从 Keychain 读取，兼容早期存于 UserDefaults 的密钥
        apiKey = Keychain.get(defaultsKey)
               ?? UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        if !apiKey.isEmpty {
            messages.append(CCMessage(
                role: .assistant,
                content: "你好！我是 Claude Code 助手。我可以帮你写代码、调试问题、解释技术概念。请告诉我你需要什么帮助？",
                timestamp: Date(),
                isGreeting: true
            ))
        }
    }

    func saveAPIKey(_ key: String) {
        apiKey = key
        if Keychain.set(key, for: defaultsKey) {
            // 迁移：清掉旧的明文 UserDefaults 副本
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else {
            UserDefaults.standard.set(key, forKey: defaultsKey)
        }
        if messages.isEmpty {
            messages.append(CCMessage(
                role: .assistant,
                content: "API Key 已保存。你好！我是 Claude Code 助手。我可以帮你写代码、调试问题、解释技术概念。请告诉我你需要什么帮助？",
                timestamp: Date(),
                isGreeting: true
            ))
        }
    }

    func sendMessage() {
        guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !apiKey.isEmpty else {
            messages.append(CCMessage(role: .assistant, content: "请先在设置中配置你的 Anthropic API Key。", timestamp: Date()))
            return
        }

        let userMsg = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        messages.append(CCMessage(role: .user, content: userMsg, timestamp: Date()))
        inputText = ""
        isLoading = true

        // 构建发给 Anthropic 的对话历史。
        // 关键约束：Messages API 要求消息以 user 开头、user/assistant 严格交替。
        // 开场白(isGreeting)是纯 UI 提示，必须从历史中剔除，否则首条真实消息
        // 会带着一条 assistant 开场白 -> 首条即为 assistant -> API 报 400。
        let apiMessages = buildAPIMessages(currentUser: userMsg)

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "system": "你是一个专业的编程助手 Claude Code，擅长编写、调试与解释代码。回答简洁、准确，必要时给出可运行的代码示例。",
            "messages": apiMessages
        ]

        guard let url = URL(string: baseURL),
              let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            isLoading = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = jsonData

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                self?.isLoading = false
                if let error = error {
                    self?.messages.append(CCMessage(role: .assistant, content: "请求失败: \(error.localizedDescription)", timestamp: Date()))
                    return
                }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self?.messages.append(CCMessage(role: .assistant, content: "无法解析响应。", timestamp: Date()))
                    return
                }

                if let errorObj = json["error"] as? [String: Any],
                   let errMsg = errorObj["message"] as? String {
                    self?.messages.append(CCMessage(role: .assistant, content: "API 错误: \(errMsg)", timestamp: Date()))
                    return
                }

                if let content = json["content"] as? [[String: Any]],
                   let first = content.first,
                   let text = first["text"] as? String {
                    self?.messages.append(CCMessage(role: .assistant, content: text, timestamp: Date()))
                } else {
                    self?.messages.append(CCMessage(role: .assistant, content: "收到了空的响应。", timestamp: Date()))
                }
            }
        }.resume()
    }

    func clearChat() {
        messages.removeAll()
    }

    /// 将本地消息历史整理为符合 Anthropic 约束的 messages 数组：
    /// - 剔除开场白(isGreeting)
    /// - 确保以 user 开头
    /// - 合并连续同角色，保证 user/assistant 严格交替
    private func buildAPIMessages(currentUser: String) -> [[String: Any]] {
        var turns: [(role: String, content: String)] = []
        for m in messages where !m.isGreeting {
            turns.append((m.role == .user ? "user" : "assistant", m.content))
        }
        // 去掉开头多余的 assistant（若有）
        while let first = turns.first, first.role == "assistant" {
            turns.removeFirst()
        }
        // 合并连续同角色，保证交替
        var cleaned: [(role: String, content: String)] = []
        for t in turns {
            if let last = cleaned.last, last.role == t.role {
                cleaned[cleaned.count - 1].content += "\n" + t.content
            } else {
                cleaned.append(t)
            }
        }
        var result: [[String: Any]] = cleaned.map { ["role": $0.role, "content": $0.content] }
        result.append(["role": "user", "content": currentUser])
        return result
    }
}
