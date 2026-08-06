import SwiftUI

// MARK: - Codex 模块控制器
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
        apiKey = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
    }

    func saveAPIKey(_ key: String) {
        apiKey = key
        UserDefaults.standard.set(key, forKey: defaultsKey)
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
                    self?.outputCode = "请求失败: \(error.localizedDescription)"
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

// MARK: - Codex 展开视图
struct CodexExpandedView: View {
    @ObservedObject private var codex = CodexController.shared
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // 顶部栏
            HStack {
                Text("Codex")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                Button(action: { codex.showSettings.toggle() }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // API Key 设置
            if codex.showSettings {
                VStack(spacing: 8) {
                    Text("OpenAI API Key")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                    HStack {
                        SecureField("sk-...", text: $codex.apiKey)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(6)
                        Button("保存") {
                            codex.saveAPIKey(codex.apiKey)
                            codex.showSettings = false
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.pink)
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
                .background(Color.white.opacity(0.04))
                .cornerRadius(10)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }

            // 操作选择
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(CodexController.CodexAction.allCases) { action in
                        Button(action: { codex.selectedAction = action }) {
                            HStack(spacing: 4) {
                                Image(systemName: action.icon)
                                    .font(.system(size: 9))
                                Text(action.rawValue)
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundColor(codex.selectedAction == action ? .white : .white.opacity(0.5))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                codex.selectedAction == action
                                    ? AnyShapeStyle(LinearGradient(colors: [Color.pink, Color.purple], startPoint: .leading, endPoint: .trailing))
                                    : AnyShapeStyle(Color.white.opacity(0.08))
                            )
                            .cornerRadius(12)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 8)

            // 输入区域
            VStack(alignment: .leading, spacing: 4) {
                Text("输入代码")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.horizontal, 2)
                TextEditor(text: $codex.inputCode)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 100)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(8)
                    .focused($isInputFocused)
            }
            .padding(.horizontal, 16)

            // 执行按钮
            Button(action: { codex.executeAction() }) {
                HStack {
                    if codex.isLoading {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 16, height: 16)
                    }
                    Text(codex.isLoading ? "处理中..." : codex.selectedAction.rawValue)
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    LinearGradient(
                        colors: [Color.pink, Color.purple],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .disabled(codex.inputCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || codex.isLoading)

            // 输出区域
            if !codex.outputCode.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("结果")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                        .padding(.horizontal, 2)
                    ScrollView {
                        Text(codex.outputCode)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(8)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }

            Spacer(minLength: 0)
        }
    }
}
