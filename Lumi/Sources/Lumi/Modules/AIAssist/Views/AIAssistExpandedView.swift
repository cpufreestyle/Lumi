import AppKit
import SwiftUI

struct AIAssistExpandedView: View {
    @ObservedObject private var ai = AIAssistController.shared
    @State private var apiKeyDraft: String = ""
    @State private var showKeyField = false
    /// Keychain 是否有已存 Key（保存/更换后刷新，驱动文案）。
    @State private var hasAPIKey: Bool = AIAssistSettings.apiKey()?.isEmpty == false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                headerRow

                if ai.settings.isConfigured {
                    clipPreviewCard
                    actionGrid
                    resultArea
                    // 保存之后仍可随时改端点/模型/Key：编辑即保存，不需要「删除配置」重来
                    endpointSettingsSection
                } else {
                    setupGuide
                }

                settingsSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
        }
        .onAppear { ai.refreshOllamaModels() }
    }

    // MARK: 标题行
    private var headerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(PanelInk.pink)
            Text("划词 AI 快驾")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(PanelInk.primary)
            Spacer()
            if ai.settings.watchClipboard {
                HStack(spacing: 4) {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                    Text("监听中")
                        .font(.system(size: 10))
                        .foregroundColor(PanelInk.text(0.6))
                }
            }
        }
    }

    // MARK: 未配置：接入向导
    private var setupGuide: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("填入一个 OpenAI 兼容端点即可使用", systemImage: "gearshape.arrow.triangle.2.circlepath")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(PanelInk.text(0.85))

            VStack(alignment: .leading, spacing: 4) {
                fieldLabel("API 地址")
                TextField("http://127.0.0.1:15721/v1", text: textBinding(\.endpoint))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                fieldHint("填主机:端口、/v1 或完整 chat/completions 地址均可")
            }

            VStack(alignment: .leading, spacing: 4) {
                fieldLabel("模型名")
                TextField("如 Qwen3.6-27B-NVFP4 / gpt-4o-mini", text: textBinding(\.model))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
            }

            apiKeyRow
            probeRow
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(PanelInk.chip(0.04)))
    }

    // MARK: 配置完成后的「端点设置」（保存后仍可编辑）

    private var endpointSettingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().background(PanelInk.chip(0.1))

            Text("端点设置")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(PanelInk.text(0.55))

            VStack(alignment: .leading, spacing: 4) {
                fieldLabel("API 地址")
                TextField("http://127.0.0.1:15721/v1", text: textBinding(\.endpoint))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
            }

            VStack(alignment: .leading, spacing: 4) {
                fieldLabel("模型名")
                TextField("如 Qwen3.6-27B-NVFP4 / step-5-preview", text: textBinding(\.model))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
            }

            apiKeyRow
            probeRow

            Text("修改即时生效；API Key 保存在 Keychain，不写入偏好文件。")
                .font(.system(size: 9))
                .foregroundColor(PanelInk.text(0.3))
        }
    }

    // MARK: - API Key 行（首次设置与设置后共用，随时可更换）

    private var apiKeyRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            fieldLabel("API Key（可选）")
            if showKeyField {
                HStack(spacing: 6) {
                    SecureField("sk-…", text: $apiKeyDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .frame(width: 150)
                    Button("保存") {
                        AIAssistSettings.setAPIKey(apiKeyDraft)
                        apiKeyDraft = ""
                        showKeyField = false
                        hasAPIKey = AIAssistSettings.apiKey()?.isEmpty == false
                    }
                    .font(.system(size: 11))
                    Button("取消") {
                        apiKeyDraft = ""
                        showKeyField = false
                    }
                    .font(.system(size: 11))
                    .foregroundColor(PanelInk.text(0.5))
                }
            } else {
                HStack {
                    Text(hasAPIKey ? "已保存在 Keychain" : "未设置（本地代理可留空）")
                        .font(.system(size: 10))
                        .foregroundColor(PanelInk.text(0.45))
                    Spacer()
                    Button(hasAPIKey ? "更换" : "设置") {
                        apiKeyDraft = ""
                        showKeyField = true
                    }
                    .font(.system(size: 11))
                }
            }
        }
    }

    // MARK: 剪贴板预览
    @ViewBuilder
    private var clipPreviewCard: some View {
        if let clip = ai.pendingText {
            VStack(alignment: .leading, spacing: 4) {
                Text("已捕获剪贴板")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.pink.opacity(0.8))
                Text(clip.prefix(120) + (clip.count > 120 ? "…" : ""))
                    .font(.system(size: 11))
                    .foregroundColor(PanelInk.text(0.6))
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.pink.opacity(0.08)))
        }
    }

    // MARK: 动作按钮
    private var actionGrid: some View {
        HStack(spacing: 8) {
            ForEach(AIAction.builtins) { action in
                Button {
                    if ai.pendingText != nil {
                        ai.runAction(action)
                    } else {
                        ai.runOnCurrentPasteboard(action)
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: action.icon)
                            .font(.system(size: 14, weight: .semibold))
                        Text(action.title)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(PanelInk.text(0.9))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(LinearGradient(
                                colors: [Color.pink.opacity(0.25), Color.purple.opacity(0.25)],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                    )
                }
                .buttonStyle(.plain)
                .disabled(ai.isStreaming)
                .opacity(ai.isStreaming ? 0.5 : 1)
            }
        }
    }

    // MARK: 结果区
    @ViewBuilder
    private var resultArea: some View {
        if ai.isStreaming || !ai.resultText.isEmpty || ai.errorMessage != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(ai.runningAction.map { "\($0.title)结果" } ?? "结果")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(PanelInk.text(0.7))
                    if ai.isStreaming {
                        ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                    }
                    Spacer()
                    if !ai.resultText.isEmpty {
                        Button {
                            copyToPasteboard(ai.resultText)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 11))
                                .foregroundColor(PanelInk.text(0.6))
                        }
                        .buttonStyle(.plain)
                        .help("复制结果")
                    }
                    if ai.isStreaming {
                        Button("停止") { ai.stopStreaming() }
                            .font(.system(size: 10))
                            .foregroundColor(.pink.opacity(0.9))
                    } else {
                        Button("清除") { ai.clearResult() }
                            .font(.system(size: 10))
                            .foregroundColor(PanelInk.text(0.45))
                    }
                }

                if let error = ai.errorMessage {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundColor(.orange.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(ai.resultText.isEmpty ? (ai.isStreaming ? "正在生成…" : "") : ai.resultText)
                    .font(.system(size: 12))
                    .foregroundColor(PanelInk.text(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(PanelInk.chip(0.04)))
        }
    }

    // MARK: 底部设置
    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().background(PanelInk.chip(0.1))

            Toggle("监听剪贴板：复制一段文字后弹出动作条", isOn: Binding(
                get: { ai.settings.watchClipboard },
                set: { ai.setWatchClipboard($0) }
            ))
            .toggleStyle(.switch)
            .tint(.pink)
            .font(.system(size: 11))
            .foregroundColor(PanelInk.text(0.75))

            Text("文本只发送到你上方配置的端点；Key 保存在 Keychain；剪贴板原文不落盘。少于 12 字的片段不触发。")
                .font(.system(size: 9))
                .foregroundColor(PanelInk.text(0.3))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 辅助
    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(PanelInk.text(0.55))
    }

    // MARK: 端点自检行（未配置与已配置共用）

    private var probeRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    ai.probeEndpoint()
                } label: {
                    HStack(spacing: 4) {
                        if ai.probe.isRunning {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 10, height: 10)
                        }
                        Text(ai.probe.isRunning ? "检测中…" : "检测连接")
                    }
                    .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .tint(.pink.opacity(0.4))
                .controlSize(.small)
                .disabled(ai.probe.isRunning)

                Button("填入本机中继") {
                    ai.useLocalRelayEndpoint()
                }
                .font(.system(size: 10))
                .foregroundColor(PanelInk.text(0.6))

                if ai.ollamaState.isReady {
                    Button("启用本机 Ollama") { ai.useOllama() }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.green.opacity(0.9))
                }

                Spacer()
            }

            if let message = ai.probe.message {
                Text(message)
                    .font(.system(size: 9))
                    .foregroundColor(ai.probe.isFailure ? .orange : .green.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }

            ollamaStatusLine
        }
    }


    @ViewBuilder
    private var ollamaStatusLine: some View {
        switch ai.ollamaState {
        case .idle:
            EmptyView()
        case .unavailable:
            Text("未检测到本机 Ollama（127.0.0.1:11434）")
                .font(.system(size: 9))
                .foregroundColor(PanelInk.text(0.3))
        case .ready(let models):
            Text("本机 Ollama：\(models.count) 个模型可用 · 免费 · 离线")
                .font(.system(size: 9))
                .foregroundColor(.green.opacity(0.8))
        }
    }
    private func fieldHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9))
            .foregroundColor(PanelInk.text(0.3))
    }

    private func textBinding(_ keyPath: WritableKeyPath<AIAssistSettings, String>) -> Binding<String> {
        Binding(
            get: { ai.settings[keyPath: keyPath] },
            set: { newValue in
                ai.updateSettings { $0[keyPath: keyPath] = newValue }
            }
        )
    }

    private func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
