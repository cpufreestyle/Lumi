import SwiftUI

final class CodexController: ObservableObject {
    static let shared = CodexController()

    @Published var inputCode: String = ""
    @Published var outputCode: String = ""
    @Published var isLoading: Bool = false
    @Published var apiKey: String = ""
    @Published var showSettings: Bool = false
    @Published var selectedAction: CodexAction = .explain

    enum CodexAction: String, CaseIterable, Identifiable {
        case explain    = "解释代码"
        case improve    = "优化代码"
        case debug      = "查找 Bug"
        case complete   = "补全代码"
        case translate  = "翻译为 Swift"
        case test       = "生成测试"

        var id: String { rawValue }

        var prompt: String {
            switch self {
            case .explain:   return "请详细解释以下代码的功能和逻辑："
            case .improve:   return "请优化以下代码，使其更高效、更易读，并解释你的改进："
            case .debug:     return "请找出以下代码中的 bug 或潜在问题，并给出修复方案："
            case .complete:  return "请补全以下代码片段："
            case .translate: return "请将以下代码翻译为 Swift 语言："
            case .test:      return "请为以下代码生成全面的单元测试："
            }
        }

        var icon: String {
            switch self {
            case .explain:   return "text.magnifyingglass"
            case .improve:   return "sparkles"
            case .debug:     return "ant"
            case .complete:  return "pencil.and.outline"
            case .translate: return "arrow.triangle.swap"
            case .test:      return "checkmark.seal"
            }
        }
    }

    private let defaultsKey = "codex_api_key"

    private init() {
        // 优先从 Keychain 读取，兼容早期存于 UserDefaults 的密钥
        apiKey = Keychain.get(defaultsKey)
               ?? UserDefaults.standard.string(forKey: defaultsKey) ?? ""
    }

    func saveAPIKey(_ key: String) {
        apiKey = key
        if Keychain.set(key, for: defaultsKey) {
            // 迁移：清掉旧的明文 UserDefaults 副本
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else {
            UserDefaults.standard.set(key, forKey: defaultsKey)
        }
    }

    func executeAction() {
        guard !inputCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !apiKey.isEmpty else {
            outputCode = "请先在设置中配置你的 OpenAI API Key。"
            return
        }

        isLoading = true
        outputCode = ""

        let fullPrompt = selectedAction.prompt + "\n\n```\n" + inputCode + "\n```"

        let body: [String: Any] = [
            "model": "gpt-4o",
            "messages": [
                ["role": "system", "content": "你是一个专业的编程助手。请用中文回答，代码块使用 markdown 格式。给出清晰、实用的建议。"],
                ["role": "user", "content": fullPrompt]
            ],
            "temperature": 0.3,
            "max_tokens": 4096
        ]

        guard let url = URL(string: "https://api.openai.com/v1/chat/completions"),
              let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            isLoading = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = jsonData

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                self?.isLoading = false
                if let error = error {
                    self?.outputCode = "请求失败: \(NetworkErrorText.describe(error))"
                    return
                }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self?.outputCode = "无法解析响应。"
                    return
                }
                if let errorObj = json["error"] as? [String: Any],
                   let errMsg = errorObj["message"] as? String {
                    self?.outputCode = "API 错误: \(errMsg)"
                    return
                }
                if let choices = json["choices"] as? [[String: Any]],
                   let first = choices.first,
                   let message = first["message"] as? [String: Any],
                   let content = message["content"] as? String {
                    self?.outputCode = content
                } else {
                    self?.outputCode = "收到了空的响应。"
                }
            }
        }.resume()
    }
}
