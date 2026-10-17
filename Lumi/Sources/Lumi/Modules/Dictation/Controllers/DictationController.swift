import AppKit
import AVFoundation
import Foundation

/// 语音听写控制器：麦克风录音 → whisper-cli 转写 → 剪贴板。
///
/// 分层（与 TV 遥控 / AI 助手同构）：本类只负责「录音 + 起进程 + 状态展示」，
/// 路径解析 / 参数拼装 / 输出提取全部在 `WhisperCLI`（纯 Foundation，可单测）。
///
/// 线程约定（项目全局）：@Published 一律主线程写。Process 的 readabilityHandler /
/// terminationHandler 跑在后台线程，回写状态前统一 DispatchQueue.main.async。
final class DictationController: ObservableObject {
    static let shared = DictationController()

    // MARK: - 持久化键

    private static let languageKey = "lumi_dictation_language"
    private static let translateKey = "lumi_dictation_translate"
    private static let modelPathKey = "lumi_dictation_model_path"
    private static let polishEnabledKey = "lumi_dictation_polish_enabled"
    private static let polishPresetKey = "lumi_dictation_polish_preset"
    private static let polishCustomKey = "lumi_dictation_polish_custom"
    private static let polishModelKey = "lumi_dictation_polish_model"

    /// 单次录音上限（秒）：忘按停止时兜底，避免临时音频无限增长。
    static let maxRecordSeconds = 120

    // MARK: - 可观察状态

    /// 正在录音。
    @Published private(set) var isRecording = false
    /// 正在转写（whisper-cli 运行中）。
    @Published private(set) var isTranscribing = false
    /// 已录音秒数（面板倒计时用）。
    @Published private(set) var recordSeconds = 0
    /// 最近一次转写结果（成功即写入剪贴板）。
    @Published private(set) var transcript = ""
    /// 持久错误（权限被拒 / 缺模型 / 进程失败），需用户处理。
    @Published private(set) var errorMessage: String?
    /// 瞬时反馈（已复制等），4 秒后自动清空。
    @Published private(set) var feedback: String?
    /// 扫描到的全部模型（含未下载完的，UI 展示状态用）。
    @Published private(set) var models: [WhisperCLI.Model] = []
    /// 是否找不到 whisper-cli 二进制。
    @Published private(set) var binaryMissing = false
    /// 是否就绪：二进制 + 完整模型都在。
    @Published private(set) var isReady = false

    /// 当前语言码（`auto` 为自动检测），持久化。
    @Published var language: String {
        didSet { UserDefaults.standard.set(language, forKey: Self.languageKey) }
    }

    /// 是否把转写结果翻译成英语（whisper 内置 `-tr`），持久化。
    @Published var translateToEnglish: Bool {
        didSet { UserDefaults.standard.set(translateToEnglish, forKey: Self.translateKey) }
    }

    /// 转写后是否调用本机 Ollama 润色（默认关：本地推理有 1-2s 延迟，先让用户知情再开）。
    @Published var polishEnabled: Bool {
        didSet { UserDefaults.standard.set(polishEnabled, forKey: Self.polishEnabledKey) }
    }

    /// 润色档位，持久化（rawValue 即 UserDefaults 值）。
    @Published var polishPreset: DictationPolish.Preset {
        didSet { UserDefaults.standard.set(polishPreset.rawValue, forKey: Self.polishPresetKey) }
    }

    /// 自定义档位的用户指令（trim 在构造请求时做）。
    @Published var polishCustomInstruction: String {
        didSet { UserDefaults.standard.set(polishCustomInstruction, forKey: Self.polishCustomKey) }
    }

    /// 润色用模型名；空 = 自动（OllamaProvider 推荐的可对话模型）。
    @Published var polishModel: String {
        didSet { UserDefaults.standard.set(polishModel, forKey: Self.polishModelKey) }
    }

    /// Ollama 探测到的本机模型（面板选择用）。
    @Published private(set) var ollamaModels: [OllamaProvider.Model] = []
    /// Ollama 是否在跑且有可对话模型。
    @Published private(set) var ollamaAvailable = false
    /// 润色在途：面板展示等待态，剪贴板等结果出来才写。
    @Published private(set) var isPolishing = false
    /// 是否正在看润色前的原文（润色成功后可切回核对）。
    @Published private(set) var showingRaw = false

    // MARK: - 内部

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var secondsTimer: Timer?
    private var transcribeProcess: Process?
    private var feedbackWork: DispatchWorkItem?
    private var rawTranscript = ""
    private var polishTask: URLSessionDataTask?
    private var ollamaProbeTask: Task<Void, Never>?

    private init() {
        language = WhisperCLI.normalizeLanguage(UserDefaults.standard.string(forKey: Self.languageKey))
        translateToEnglish = UserDefaults.standard.bool(forKey: Self.translateKey)
        polishEnabled = UserDefaults.standard.bool(forKey: Self.polishEnabledKey)
        let presetRaw = UserDefaults.standard.string(forKey: Self.polishPresetKey)
            ?? DictationPolish.Preset.cleanup.rawValue
        polishPreset = DictationPolish.Preset(rawValue: presetRaw) ?? .cleanup
        polishCustomInstruction = UserDefaults.standard.string(forKey: Self.polishCustomKey) ?? ""
        polishModel = UserDefaults.standard.string(forKey: Self.polishModelKey) ?? ""

        // 本地 Ollama 探测：仅面板展开到听写模块时占 30s 拍；空闲返回 0，PollingCoordinator 不唤醒。
        // 与 AIAssist 的探测同一界面、互不共享状态（同一时刻只有一个模块面板展开）。
        PollingCoordinator.shared.register(
            id: "dictation.ollamaProbe",
            interval: {
                let state = AppState.shared
                return (state.isExpanded && state.activeModule == .dictation) ? 30 : 0
            },
            action: { [weak self] in self?.probeOllama() }
        )
        refreshEnvironment()
    }

    // MARK: - 环境刷新

    /// 面板出现 / 每次录音前调用：重扫二进制与模型，校正就绪状态。
    func refreshEnvironment() {
        models = WhisperCLI.installedModels()
        // 之前手动选过的模型若已不存在/不完整，清除选择回落自动档
        if selectedModel == nil {
            UserDefaults.standard.removeObject(forKey: Self.modelPathKey)
        }
        binaryMissing = WhisperCLI.resolveBinaryPath() == nil
        isReady = !binaryMissing && selectedModel != nil
        probeOllama()
    }

    /// 当前使用的模型：优先用户选过的（仍存在且完整），否则按档位偏好自动挑。
    var selectedModel: WhisperCLI.Model? {
        if let stored = UserDefaults.standard.string(forKey: Self.modelPathKey),
           let chosen = models.first(where: { $0.path == stored }),
           chosen.isComplete {
            return chosen
        }
        return WhisperCLI.preferredModel(models)
    }

    /// 切换模型（面板下拉选择）。传 nil 或选到不完整的模型时清除选择，回落自动档。
    func selectModel(path: String?) {
        if let path,
           let model = models.first(where: { $0.path == path }),
           model.isComplete {
            UserDefaults.standard.set(path, forKey: Self.modelPathKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.modelPathKey)
        }
        refreshEnvironment()
    }

    // MARK: - 录音

    func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    func startRecording() {
        errorMessage = nil
        cancelPolish()
        guard !isTranscribing else {
            errorMessage = "正在转写上一次录音，请稍候。"
            return
        }
        refreshEnvironment()
        guard !binaryMissing else {
            errorMessage = "未找到 whisper-cli，请先安装：brew install whisper-cpp"
            return
        }
        guard selectedModel != nil else {
            errorMessage = "没有可用的语音模型，请在下方下载 ggml-base.bin（约148MB）。"
            return
        }
        // 麦克风授权：只对「尚未决定」调用 requestAccess。已授权直接开录，
        // 被拒给出设置路径 —— 不做状态判断的话，每次录音都会再走一次授权调用，
        // 系统设置里会反复出现「最近请求权限」提示。用户明确要求：
        // 检测到已授权就不要重复提示。
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginRecording()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard granted else {
                        self?.errorMessage = "麦克风权限被拒绝：请在 系统设置 → 隐私与安全性 → 麦克风 中允许 Lumi。"
                        return
                    }
                    self?.beginRecording()
                }
            }
        default:
            errorMessage = "麦克风权限被拒绝：请在 系统设置 → 隐私与安全性 → 麦克风 中允许 Lumi。"
        }
    }

    /// 录音格式：16kHz 单声道 16-bit PCM WAV——whisper.cpp 的原生输入格式，
    /// 免除 ffmpeg 中转（AVAudioRecorder 按 .wav 扩展名自动写 RIFF/WAVE 容器）。
    private static func recorderSettings() -> [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
    }

    private func beginRecording() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-dictation-\(UUID().uuidString).wav")
        do {
            let recorder = try AVAudioRecorder(url: url, settings: Self.recorderSettings())
            recorder.prepareToRecord()
            guard recorder.record() else {
                errorMessage = "录音启动失败：麦克风可能被其他应用独占。"
                return
            }
            self.recorder = recorder
            recordingURL = url
            recordSeconds = 0
            isRecording = true
            startSecondsTimer()
        } catch {
            errorMessage = "录音初始化失败：\(error.localizedDescription)"
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        stopSecondsTimer()
        isRecording = false
        guard let recorder, let url = recordingURL else { return }
        recorder.stop()
        self.recorder = nil
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "录音文件缺失，请重试。"
            recordingURL = nil
            return
        }
        runTranscription(audioURL: url)
    }

    /// 放弃本次录音：丢弃临时文件，不转写。
    func cancelRecording() {
        guard isRecording else { return }
        stopSecondsTimer()
        isRecording = false
        recorder?.stop()
        recorder = nil
        if let url = recordingURL { try? FileManager.default.removeItem(atPath: url.path) }
        recordingURL = nil
        recordSeconds = 0
    }

    private func startSecondsTimer() {
        secondsTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.recordSeconds += 1
            if self.recordSeconds >= Self.maxRecordSeconds { self.stopRecording() }
        }
        RunLoop.main.add(timer, forMode: .common)
        secondsTimer = timer
    }

    private func stopSecondsTimer() {
        secondsTimer?.invalidate()
        secondsTimer = nil
    }

    // MARK: - 转写

    private func runTranscription(audioURL: URL) {
        guard let binary = WhisperCLI.resolveBinaryPath(),
              let model = selectedModel else {
            errorMessage = "转写环境缺失（whisper-cli 或语音模型）。"
            try? FileManager.default.removeItem(atPath: audioURL.path)
            return
        }

        isTranscribing = true
        errorMessage = nil
        transcript = ""

        let task = Process()
        task.executableURL = URL(fileURLWithPath: binary)
        task.arguments = WhisperCLI.buildArguments(
            modelPath: model.path,
            audioPath: audioURL.path,
            language: language,
            translateToEnglish: translateToEnglish
        )

        // stdout 走管道实时读（ readabilityHandler 边到边读，防管道缓冲写满死锁）；
        // stderr 重定向到临时文件，失败时取末段做诊断（模型加载失败等原因都在这里）。
        let outputPipe = Pipe()
        task.standardOutput = outputPipe
        let stderrURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-dictation-err-\(UUID().uuidString).log")
        guard let stderrHandle = try? FileHandle(forWritingTo: stderrURL) else {
            isTranscribing = false
            errorMessage = "无法创建临时诊断文件。"
            try? FileManager.default.removeItem(atPath: audioURL.path)
            return
        }
        task.standardError = stderrHandle

        var stdoutBuffer = Data()
        let bufferLock = NSLock()
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            bufferLock.lock()
            stdoutBuffer.append(data)
            bufferLock.unlock()
        }

        task.terminationHandler = { [weak self] process in
            outputPipe.fileHandleForReading.readabilityHandler = nil
            let stdout: String = {
                bufferLock.lock()
                defer { bufferLock.unlock() }
                return String(data: stdoutBuffer, encoding: .utf8) ?? ""
            }()
            stderrHandle.closeFile()
            DispatchQueue.main.async {
                self?.handleTranscriptionEnd(
                    process: process,
                    stdout: stdout,
                    audioURL: audioURL,
                    stderrURL: stderrURL
                )
            }
        }

        transcribeProcess = task
        do {
            try task.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            stderrHandle.closeFile()
            isTranscribing = false
            errorMessage = "whisper-cli 启动失败：\(error.localizedDescription)"
            cleanupTempFiles(audioURL: audioURL, stderrURL: stderrURL)
        }
    }

    private func handleTranscriptionEnd(process: Process, stdout: String, audioURL: URL, stderrURL: URL) {
        transcribeProcess = nil
        isTranscribing = false
        defer { cleanupTempFiles(audioURL: audioURL, stderrURL: stderrURL) }

        let text = WhisperCLI.extractTranscription(fromStdout: stdout)
        guard process.terminationStatus == 0 else {
            errorMessage = "转写失败（退出码 \(process.terminationStatus)）：\(Self.stderrTail(of: stderrURL))"
            return
        }
        guard !text.isEmpty else {
            errorMessage = "没有识别到语音：可能没说话，或环境太吵。"
            return
        }
        rawTranscript = text
        transcript = text
        showingRaw = false
        // 润色开启且环境就绪时，剪贴板延迟到润色结果出来再写（成功写润色、失败写原文），
        // 避免用户抢在中间粘贴拿到半成品；未开启则维持「即转即复制」的原体验。
        if DictationPolish.shouldPolish(enabled: polishEnabled, environmentReady: polishReady, transcript: text) {
            startPolish(text)
        } else {
            writeClipboard(text)
            flashFeedback("已复制到剪贴板")
        }
    }

    /// 取 stderr 文件末 200 字符（压平换行），用于失败诊断。
    private static func stderrTail(of url: URL) -> String {
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let text = String(data: data, encoding: .utf8) else {
            return "无错误输出"
        }
        let tail = String(text.suffix(200))
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? "无错误输出" : tail
    }

    private func cleanupTempFiles(audioURL: URL, stderrURL: URL) {
        try? FileManager.default.removeItem(atPath: audioURL.path)
        try? FileManager.default.removeItem(atPath: stderrURL.path)
    }

    /// 用户主动中止转写（杀死 whisper-cli，丢弃本次临时文件）。
    func cancelTranscription() {
        transcribeProcess?.terminate()
        transcribeProcess = nil
        isTranscribing = false
    }

    // MARK: - 本地润色（调用本机 Ollama）

    /// 当前展示/复制的文本：润色成功后默认展示润色结果，用户可切回原文核对。
    var displayTranscript: String {
        showingRaw ? rawTranscript : transcript
    }

    /// 润色结果与原文不同才提供切换（相同则切换无意义）。
    var canToggleRaw: Bool {
        !rawTranscript.isEmpty && transcript != rawTranscript
    }

    func toggleShowingRaw() {
        showingRaw.toggle()
    }

    /// 润色环境是否就绪：Ollama 在跑、有可对话模型、选中的模型也解析得出来。
    private var polishReady: Bool {
        ollamaAvailable && effectivePolishModel != nil
    }

    /// 润色用模型：用户显式选过且仍在列表 → 用它；否则 OllamaProvider 推荐的可对话模型。
    private var effectivePolishModel: String? {
        if !polishModel.isEmpty, ollamaModels.contains(where: { $0.name == polishModel }) {
            return polishModel
        }
        if let recommended = OllamaProvider.recommendedChatModel(from: ollamaModels) {
            return recommended.name
        }
        return ollamaModels.first?.name
    }

    /// 探测本机 Ollama（/api/tags）：面板展开时 30s 档位由 PollingCoordinator 触发，
    /// 用户刚 pull 完新模型无需重启 App 即可选到。
    func probeOllama() {
        ollamaProbeTask?.cancel()
        ollamaProbeTask = Task { [weak self] in
            await self?.fetchOllamaModels()
        }
    }

    private func fetchOllamaModels() async {
        guard let url = OllamaProvider.tagsURL else {
            await MainActor.run { self.ollamaAvailable = false }
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let models = OllamaProvider.parseTags(String(data: data, encoding: .utf8) ?? "")
            await MainActor.run {
                self.ollamaModels = models
                self.ollamaAvailable = !models.isEmpty
            }
        } catch is CancellationError {
        } catch {
            await MainActor.run {
                self.ollamaModels = []
                self.ollamaAvailable = false
            }
        }
    }

    /// 起润色请求（非流式，10s 超时）。完成后主线程换文本、补写剪贴板；
    /// 任何失败都静默回退原文并在反馈条说明——润色只是增强，不是单点故障。
    private func startPolish(_ text: String) {
        guard let model = effectivePolishModel,
              let url = DictationPolish.generateURL,
              let body = try? JSONSerialization.data(withJSONObject: DictationPolish.buildRequest(
                model: model,
                text: text,
                preset: polishPreset,
                customInstruction: polishCustomInstruction
              ))
        else { return }

        polishTask?.cancel()
        isPolishing = true
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = DictationPolish.timeoutSeconds
        request.httpBody = body

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            if let error = error as? URLError, error.code == .cancelled { return }
            let polished: String? = {
                guard let data, let json = String(data: data, encoding: .utf8) else { return nil }
                return DictationPolish.parseResponse(json)
            }()
            DispatchQueue.main.async {
                guard let self, self.polishTask != nil else { return } // 已被取消/新一轮接管
                self.polishTask = nil
                self.isPolishing = false
                if let polished, !polished.isEmpty {
                    self.transcript = polished
                    self.showingRaw = false
                    self.writeClipboard(polished)
                    self.flashFeedback("已润色并复制")
                } else {
                    self.writeClipboard(self.rawTranscript)
                    self.flashFeedback("本地润色失败，已复制原文")
                }
            }
        }
        polishTask = task
        task.resume()
    }

    /// 取消在途润色（新一轮录音 / 清空结果时调用）。剪贴板补写原文，
    /// 兜住「延迟写剪贴板」策略：取消也不能让用户 clipboard 里空手。
    private func cancelPolish() {
        guard polishTask != nil else { return }
        polishTask?.cancel()
        polishTask = nil
        isPolishing = false
        if !rawTranscript.isEmpty {
            writeClipboard(rawTranscript)
        }
    }

    private func writeClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - 反馈

    func flashFeedback(_ message: String) {
        feedback = message
        feedbackWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.feedback = nil }
        feedbackWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    func copyTranscript() {
        let text = displayTranscript
        guard !text.isEmpty else { return }
        writeClipboard(text)
        flashFeedback("已复制到剪贴板")
    }

    func clearTranscript() {
        cancelPolish()
        transcript = ""
        rawTranscript = ""
        showingRaw = false
        errorMessage = nil
    }

    func dismissError() {
        errorMessage = nil
    }
}
