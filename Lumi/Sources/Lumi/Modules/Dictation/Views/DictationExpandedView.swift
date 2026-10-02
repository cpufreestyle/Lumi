import AppKit
import SwiftUI

/// 语音听写面板：录音 → whisper-cli 转写 → 剪贴板。
///
/// 布局（一屏按完 + 滚动兜底）：录音按钮在最上面（最高频操作），转写结果其次，
/// 模型下载指引与识别设置收在底部——模型没装好时用户也能直接看到怎么办。
struct DictationExpandedView: View {
    @ObservedObject private var dictation = DictationController.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                if dictation.isTranscribing { transcribingHint }
                if dictation.isPolishing { polishingHint }
                if let error = dictation.errorMessage { errorBanner(error) }
                recordSection
                transcriptSection
                polishSection
                modelSection
                settingsSection
                footer
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
        }
        .onAppear { dictation.refreshEnvironment() }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(PanelInk.pink)
            Text("语音听写")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(PanelInk.primary)
            if let feedback = dictation.feedback {
                Text(feedback)
                    .font(.system(size: 11))
                    .foregroundColor(.green.opacity(0.9))
            }
            Spacer()
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .help(statusHelp)
            Button { dictation.refreshEnvironment() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .foregroundColor(PanelInk.text(0.55))
            }
            .buttonStyle(.plain)
            .help("刷新模型状态")
        }
    }

    private var statusColor: Color {
        if dictation.isRecording { return .red }
        if dictation.isTranscribing { return .orange }
        if dictation.errorMessage != nil { return .orange }
        return dictation.isReady ? .green : .white.opacity(0.3)
    }

    private var statusHelp: String {
        if dictation.binaryMissing { return "未找到 whisper-cli" }
        if !dictation.isReady { return "模型未就绪" }
        return "就绪"
    }

    // MARK: 录音

    private var recordSection: some View {
        VStack(spacing: 10) {
            Button(action: dictation.toggleRecording) {
                ZStack {
                    Circle()
                        .fill(dictation.isRecording ? Color.red.opacity(0.22) : Color.pink.opacity(0.18))
                        .frame(width: 72, height: 72)
                    Image(systemName: dictation.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundColor(dictation.isRecording ? .red : .pink)
                }
            }
            .buttonStyle(.plain)
            .disabled(dictation.isTranscribing)

            if dictation.isRecording {
                Text("录音中 \(dictation.recordSeconds)s · 上限 \(DictationController.maxRecordSeconds)s")
                    .font(.system(size: 12))
                    .foregroundColor(.red.opacity(0.85))
                Button("放弃本次", action: dictation.cancelRecording)
                    .font(.system(size: 11))
                    .foregroundColor(PanelInk.text(0.55))
                    .buttonStyle(.plain)
            } else {
                Text("点击麦克风开始录音，停止后自动转写并复制到剪贴板")
                    .font(.system(size: 12))
                    .foregroundColor(PanelInk.text(0.6))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var transcribingHint: some View {
        HStack(spacing: 8) {
            ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
            Text("转写中…首次加载模型需要几秒")
                .font(.system(size: 11))
                .foregroundColor(PanelInk.text(0.6))
            Spacer()
            Button("中止", action: dictation.cancelTranscription)
                .font(.system(size: 11))
                .foregroundColor(PanelInk.text(0.55))
                .buttonStyle(.plain)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }

    private var polishingHint: some View {
        HStack(spacing: 8) {
            ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
            Text("本地 Ollama 润色中…完成后才写入剪贴板")
                .font(.system(size: 11))
                .foregroundColor(PanelInk.text(0.6))
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.pink.opacity(0.12)))
    }

    // MARK: 结果

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("转写结果")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(PanelInk.text(0.85))
                Spacer()
                if !dictation.transcript.isEmpty {
                    if dictation.canToggleRaw {
                        Button { dictation.toggleShowingRaw() } label: {
                            Label(dictation.showingRaw ? "看润色" : "看原文", systemImage: "text.badge.checkmark")
                                .font(.system(size: 11))
                                .foregroundColor(PanelInk.text(0.55))
                        }
                        .buttonStyle(.plain)
                        .help(dictation.showingRaw ? "切换回润色后的文本" : "查看润色前的转写原文")
                    }
                    Button { dictation.copyTranscript() } label: {
                        Label("复制", systemImage: "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundColor(PanelInk.text(0.55))
                    }
                    .buttonStyle(.plain)
                    Button { dictation.clearTranscript() } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundColor(PanelInk.text(0.55))
                    }
                    .buttonStyle(.plain)
                }
            }

            if dictation.transcript.isEmpty {
                Text("转写结果会显示在这里，并自动写入剪贴板。")
                    .font(.system(size: 12))
                    .foregroundColor(PanelInk.text(0.35))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 16)
            } else {
                ScrollView {
                    Text(dictation.displayTranscript)
                        .font(.system(size: 13))
                        .foregroundColor(PanelInk.text(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 80, maxHeight: 180)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(PanelInk.chip(0.06)))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(PanelInk.orange)
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(.orange.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { dictation.dismissError() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundColor(PanelInk.text(0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }

    // MARK: 本地润色

    private var chatModels: [OllamaProvider.Model] {
        dictation.ollamaModels.filter(\.isChatCapable)
    }

    private var polishSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("本地 AI 润色")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(PanelInk.text(0.85))
            Toggle("转写后用本机 Ollama 润色", isOn: $dictation.polishEnabled)
                .font(.system(size: 12))
                .toggleStyle(.switch)
                .foregroundColor(PanelInk.text(0.75))

            if dictation.polishEnabled {
                if chatModels.isEmpty {
                    hintRow(
                        text: dictation.ollamaAvailable
                            ? "Ollama 在运行但没有可对话模型"
                            : "未检测到本机 Ollama（127.0.0.1:11434）",
                        buttonTitle: "复制命令",
                        action: { copyToPasteboard(dictation.ollamaAvailable ? "ollama pull qwen3:4b" : "brew install ollama") }
                    )
                } else {
                    Picker(selection: polishPresetBinding) {
                        ForEach(DictationPolish.Preset.allCases) { preset in
                            Text(preset.label).tag(preset)
                        }
                    } label: {
                        Text("润色档位")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    Text(dictation.polishPreset.hint)
                        .font(.system(size: 10))
                        .foregroundColor(PanelInk.text(0.35))

                    if dictation.polishPreset == .custom {
                        TextField("例如：全部翻译成英语，保留专业术语", text: $dictation.polishCustomInstruction)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                    }

                    Picker(selection: polishModelBinding) {
                        Text("自动（推荐）").tag("")
                        ForEach(chatModels) { model in
                            Text(model.subtitle.isEmpty ? model.name : "\(model.name) · \(model.subtitle)")
                                .tag(model.name)
                        }
                    } label: {
                        Text("润色模型")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    Text("文本仅发往本机 127.0.0.1:11434，不出本机；失败自动用原文。")
                        .font(.system(size: 10))
                        .foregroundColor(PanelInk.text(0.3))
                }
            }
        }
    }

    private var polishPresetBinding: Binding<DictationPolish.Preset> {
        Binding(
            get: { dictation.polishPreset },
            set: { dictation.polishPreset = $0 }
        )
    }

    private var polishModelBinding: Binding<String> {
        Binding(
            get: { dictation.polishModel },
            set: { dictation.polishModel = $0 }
        )
    }

    // MARK: 模型

    private var completeModels: [WhisperCLI.Model] {
        dictation.models.filter(\.isComplete)
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("模型")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(PanelInk.text(0.85))

            if dictation.binaryMissing {
                hintRow(
                    text: "未找到 whisper-cli，请先安装：brew install whisper-cpp",
                    buttonTitle: "复制命令",
                    action: { copyToPasteboard("brew install whisper-cpp") }
                )
            }

            if completeModels.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("未找到完整模型。下载到 ~/Library/Application Support/Lumi/models/ 后刷新：")
                        .font(.system(size: 11))
                        .foregroundColor(PanelInk.text(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(WhisperCLI.suggestedTiers, id: \.self) { tier in
                        HStack(spacing: 6) {
                            Text("ggml-\(tier).bin")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(PanelInk.text(0.75))
                            Text(tierSizeLabel(tier))
                                .font(.system(size: 10))
                                .foregroundColor(PanelInk.text(0.4))
                            Spacer()
                            Button("下载页") {
                                if let url = WhisperCLI.downloadURL(forTier: tier) {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .font(.system(size: 11))
                            .buttonStyle(.plain)
                            .foregroundColor(PanelInk.pink)
                            Button("复制命令") {
                                copyToPasteboard(downloadCommand(forTier: tier))
                            }
                            .font(.system(size: 11))
                            .buttonStyle(.plain)
                            .foregroundColor(PanelInk.text(0.6))
                        }
                    }
                    if let incomplete = incompleteModelHint {
                        Text(incomplete)
                            .font(.system(size: 10))
                            .foregroundColor(.orange.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Picker(selection: modelBinding) {
                    ForEach(completeModels) { model in
                        Text("\(model.tier) · \(Self.formattedSize(model.sizeBytes))").tag(model.path)
                    }
                } label: {
                    Text("模型")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Text("默认自动选 base（速度/质量平衡）；小模型更快但错字更多。")
                    .font(.system(size: 10))
                    .foregroundColor(PanelInk.text(0.35))
            }
        }
    }

    private var incompleteModelHint: String? {
        let incomplete = dictation.models.filter { !$0.isComplete }
        guard !incomplete.isEmpty else { return nil }
        let names = incomplete.map { "\($0.name)（\(Self.formattedSize($0.sizeBytes))，不完整）" }
        return "检测到未下完的模型：\(names.joined(separator: "、"))"
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { dictation.selectedModel?.path ?? "" },
            set: { dictation.selectModel(path: $0) }
        )
    }

    private func hintRow(text: String, buttonTitle: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(PanelInk.text(0.6))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(buttonTitle, action: action)
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundColor(PanelInk.pink)
        }
    }

    // MARK: 识别设置

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("识别设置")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(PanelInk.text(0.85))
            HStack {
                Text("语言")
                    .font(.system(size: 12))
                    .foregroundColor(PanelInk.text(0.75))
                Spacer()
                Picker("语言", selection: $dictation.language) {
                    Text("自动检测").tag("auto")
                    Text("中文").tag("zh")
                    Text("English").tag("en")
                    Text("日本語").tag("ja")
                    Text("한국어").tag("ko")
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
            }
            Toggle("翻译成英语（whisper 内置任务）", isOn: $dictation.translateToEnglish)
                .font(.system(size: 12))
                .toggleStyle(.switch)
                .foregroundColor(PanelInk.text(0.75))
        }
    }

    // MARK: 底部

    private var footer: some View {
        Text("音频不出本机 · 调用本机 whisper.cpp（github.com/ggerganov/whisper.cpp）")
            .font(.system(size: 10))
            .foregroundColor(PanelInk.text(0.3))
    }

    // MARK: 工具

    private static func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func tierSizeLabel(_ tier: String) -> String {
        switch tier {
        case "tiny": return "约78MB · 最快"
        case "base": return "约148MB · 推荐"
        case "small": return "约488MB · 更准"
        default: return ""
        }
    }

    private func downloadCommand(forTier tier: String) -> String {
        "curl -L -o ~/Library/Application\\ Support/Lumi/models/ggml-\(tier).bin \(WhisperCLI.modelDownloadBase)/ggml-\(tier).bin"
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        dictation.flashFeedback("已复制")
    }
}
