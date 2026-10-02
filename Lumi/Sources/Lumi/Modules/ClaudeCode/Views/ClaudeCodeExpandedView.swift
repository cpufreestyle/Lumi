import SwiftUI

struct ClaudeCodeExpandedView: View {
    @ObservedObject private var cc = ClaudeCodeController.shared
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // 顶部操作栏
            HStack {
                Text("Claude Code")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(PanelInk.text(0.7))

                Spacer()

                Button(action: { cc.showSettings.toggle() }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                        .foregroundColor(PanelInk.text(0.5))
                }
                .buttonStyle(.plain)

                Button(action: { cc.clearChat() }) {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundColor(PanelInk.text(0.5))
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
                        .foregroundColor(PanelInk.text(0.6))
                    HStack {
                        SecureField("sk-ant-api03-...", text: $cc.apiKey)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundColor(PanelInk.primary)
                            .padding(8)
                            .background(PanelInk.chip(0.08))
                            .cornerRadius(6)
                        Button("保存") {
                            cc.saveAPIKey(cc.apiKey)
                            cc.showSettings = false
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(PanelInk.pink)
                        .buttonStyle(.plain)
                    }
                    Text("API Key 将安全地存储在你的本地钥匙串中")
                        .font(.system(size: 9))
                        .foregroundColor(PanelInk.text(0.3))
                }
                .padding(12)
                .background(PanelInk.chip(0.04))
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
                // macOS 14 起 onChange(of:perform:) 已废弃，改用零参数闭包形式
                .onChange(of: cc.messages.count) {
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
                    .foregroundColor(PanelInk.primary)
                    .padding(10)
                    .background(PanelInk.chip(0.08))
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
                .foregroundColor(PanelInk.text(0.15))
            Text("Claude Code 编程助手")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(PanelInk.text(0.35))
            Text("随时问我代码问题、调试建议、架构设计...")
                .font(.system(size: 11))
                .foregroundColor(PanelInk.text(0.25))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }
}
