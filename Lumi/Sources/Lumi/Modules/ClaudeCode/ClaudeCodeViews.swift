import SwiftUI

// MARK: - Claude Code 模块控制器
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
        var apiMessages = buildAPIMessages(currentUser: userMsg)

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

// MARK: - Claude Code 展开视图
struct ClaudeCodeExpandedView: View {
    @ObservedObject private var cc = ClaudeCodeController.shared
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // 顶部操作栏
            HStack {
                Text("Claude Code")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))

                Spacer()

                Button(action: { cc.showSettings.toggle() }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)

                Button(action: { cc.clearChat() }) {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // API Key 设置弹窗
            if cc.showSettings {
                VStack(spacing: 8) {
                    Text("Anthropic API Key")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                    HStack {
                        SecureField("sk-ant-api03-...", text: $cc.apiKey)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(6)
                        Button("保存") {
                            cc.saveAPIKey(cc.apiKey)
                            cc.showSettings = false
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.pink)
                        .buttonStyle(.plain)
                    }
                    Text("API Key 将安全地存储在你的本地钥匙串中")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.3))
                }
                .padding(12)
                .background(Color.white.opacity(0.04))
                .cornerRadius(10)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }

            // 消息列表
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if cc.messages.isEmpty {
                            emptyStateView
                        }
                        ForEach(cc.messages) { msg in
                            CCMessageBubble(message: msg)
                                .id(msg.id)
                        }
                        if cc.isLoading {
                            CCLoadingBubble()
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: cc.messages.count) { _ in
                    if let last = cc.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            // 输入区域
            HStack(spacing: 8) {
                TextField("问 Claude 任何编程问题...", text: $cc.inputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .padding(10)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(10)
                    .focused($isFocused)
                    .onSubmit { cc.sendMessage() }

                Button(action: { cc.sendMessage() }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(
                            cc.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? .white.opacity(0.2) : .pink
                        )
                }
                .buttonStyle(.plain)
                .disabled(cc.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || cc.isLoading)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            .padding(.top, 4)
        }
    }

    var emptyStateView: some View {
        VStack(spacing: 10) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 36))
                .foregroundColor(.white.opacity(0.15))
            Text("Claude Code 编程助手")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.35))
            Text("随时问我代码问题、调试建议、架构设计...")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.25))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }
}

// MARK: - 消息气泡
struct CCMessageBubble: View {
    let message: ClaudeCodeController.CCMessage

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .assistant {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 11))
                    .foregroundColor(.purple.opacity(0.7))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.purple.opacity(0.15)))
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 2) {
                Text(message.content)
                    .font(.system(size: 11))
                    .foregroundColor(.white)
                    .padding(10)
                    .background(
                        message.role == .user
                            ? Color.pink.opacity(0.25)
                            : Color.white.opacity(0.08)
                    )
                    .cornerRadius(10)
            }
            .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)

            if message.role == .user {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.pink.opacity(0.7))
                    .frame(width: 22, height: 22)
            }
        }
    }
}

// MARK: - 加载气泡
struct CCLoadingBubble: View {
    @State private var dotCount: Int = 0

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 11))
                .foregroundColor(.purple.opacity(0.7))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.purple.opacity(0.15)))
            Text(String(repeating: ".", count: (dotCount % 3) + 1))
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))
                .padding(10)
                .background(Color.white.opacity(0.06))
                .cornerRadius(10)
        }
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { t in
                dotCount += 1
                if dotCount > 100 { t.invalidate() }
            }
        }
    }
}
