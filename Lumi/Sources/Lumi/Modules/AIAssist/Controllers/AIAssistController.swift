import AppKit
import Combine
import Foundation

/// 划词 AI 快驾控制器。
///
/// 隐私边界（务必保留）：
/// - 剪贴板监听默认关闭，只有用户在助手面板显式打开后才启动；
/// - 只在检测到「新复制且长度达标」的文本时弹出动作条，不落盘剪贴板原文；
/// - 文本仅发往用户自己配置的 OpenAI 兼容端点；API Key 存 Keychain，不进 UserDefaults。
final class AIAssistController: ObservableObject {
    static let shared = AIAssistController()

    @Published private(set) var settings: AIAssistSettings = .load()
    @Published private(set) var isWatching: Bool = false

    /// 当前待处理的剪贴板文本（nil = 动作条不显示）。
    @Published private(set) var pendingText: String?
    /// 动作条自动隐藏的延迟时间。
    private let actionBarLifetime: TimeInterval = 8

    /// 进行中的请求状态。
    @Published private(set) var isStreaming = false
    @Published private(set) var runningAction: AIAction?
    @Published private(set) var resultText = ""
    @Published private(set) var errorMessage: String?

    private var streamTask: Task<Void, Never>?
    private var hideBarWork: DispatchWorkItem?
    private var lastChangeCount = NSPasteboard.general.changeCount

    private init() {
        // isWatching 是「监听剪贴板」的运行时镜像：PollingCoordinator 的 interval
        // 闭包读它决定是否占拍（返回 1 才会周期性调 checkPasteboard，0 = 空闲）。
        // 这个属性过去从未被赋值，interval 恒为 0，复制文本永远不弹动作条。
        // 用户在设置里显式打开过监听是持久化状态，重启后必须恢复，故在注册
        // 轮询前先用持久化开关初始化（剪贴板高敏，默认仍然关）。
        isWatching = settings.watchClipboard
        // 监听开关打开时才占拍（interval 0 = 空闲，PollingCoordinator 不唤醒）。
        PollingCoordinator.shared.register(
            id: "aiAssist.clipboard",
            interval: { [weak self] in
                guard let self else { return 0 }
                return self.settings.watchClipboard && self.isWatching ? 1 : 0
            },
            action: { [weak self] in self?.checkPasteboard() }
        )

        // 低频探测本机 Ollama（:11434）：面板展开时占拍，空闲返回 0 不常驻。
        PollingCoordinator.shared.register(
            id: "aiAssist.ollamaProbe",
            interval: {
                let state = AppState.shared
                return (state.isExpanded && state.activeModule == .aiAssist) ? 30 : 0
            },
            action: { [weak self] in self?.refreshOllamaModels() }
        )
    }

    // MARK: - 设置

    func updateSettings(_ mutate: (inout AIAssistSettings) -> Void) {
        var next = settings
        mutate(&next)
        next.save()
        settings = next
    }

    func setWatchClipboard(_ on: Bool) {
        updateSettings { $0.watchClipboard = on }
        // 运行时镜像随开关同步：开 = 开始监听，关 = 立即退出占拍（interval 归 0）。
        // UI 的 Toggle set 路径统一走这里，是运行时唯一的写入口。
        isWatching = on
        if on {
            // 打开瞬间先同步一次计数，避免把「开启前就在剪贴板里的内容」当成新复制
            lastChangeCount = NSPasteboard.general.changeCount
        } else {
            dismissActionBar()
        }
    }

    // MARK: - 剪贴板监听

    /// 最小可处理长度：太短的片段（单词、路径）执行 AI 动作没有意义。
    private let minClipLength = 12

    private func checkPasteboard() {
        guard settings.watchClipboard else { return }
        let pasteboard = NSPasteboard.general
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count

        // 正在进行生成时不再弹新动作条，避免打断当前结果
        guard !isStreaming else { return }
        guard let text = pasteboard.string(forType: .string),
              text.trimmingCharacters(in: .whitespacesAndNewlines).count >= minClipLength
        else { return }

        pendingText = text
        scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        hideBarWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingText = nil
        }
        hideBarWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + actionBarLifetime, execute: work)
    }

    func dismissActionBar() {
        hideBarWork?.cancel()
        hideBarWork = nil
        pendingText = nil
    }

    /// 手动用剪贴板当前内容跑一个动作（面板内按钮；不依赖监听）。
    @discardableResult
    func runOnCurrentPasteboard(_ action: AIAction) -> Bool {
        guard let text = NSPasteboard.general.string(forType: .string),
              text.trimmingCharacters(in: .whitespacesAndNewlines).count >= minClipLength
        else {
            errorMessage = "剪贴板里没有可处理的文本"
            return false
        }
        pendingText = text
        runAction(action)
        return true
    }

    // MARK: - 请求

    /// 对指定文本执行动作，流式渲染。自动展开面板并切到助手模块。
    func runAction(_ action: AIAction, text: String? = nil) {
        let source = text ?? pendingText
        guard let source, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "没有可处理的文本"
            return
        }
        guard let url = settings.chatCompletionsURL() else {
            errorMessage = "端点无效：请检查设置里的地址"
            return
        }
        guard let body = settings.buildRequestBody(action: action, text: source) else {
            errorMessage = "请求构造失败"
            return
        }

        streamTask?.cancel()
        errorMessage = nil
        resultText = ""
        runningAction = action
        isStreaming = true
        dismissActionBar()

        // 结果需要版面：展开面板并切到助手模块（@Published 统一主线程写）
        Task { @MainActor in
            AppState.shared.activeModule = .aiAssist
            AppState.shared.isExpanded = true
        }

        streamTask = Task { [weak self] in
            await self?.perform(action: action, url: url, body: body)
        }
    }

    func stopStreaming() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        runningAction = nil
    }

    private func perform(action: AIAction, url: URL, body: Data) async {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let key = AIAssistSettings.apiKey(), !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        request.timeoutInterval = 120

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                // 读取错误体（通常很短），给出服务端原文便于排查
                var errorBody = ""
                for try await line in bytes.lines { errorBody += line }
                let trimmed = errorBody.trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run {
                    self.finishStreaming()
                    // 错误体翻译成可行动的中文（额度/Key/模型/限流各有指引）
                    self.errorMessage = AIAssistErrorTranslator.friendlyMessage(
                        statusCode: http.statusCode,
                        body: trimmed
                    )
                }
                return
            }
            var accumulated = ""
            for try await line in bytes.lines {
                try Task.checkCancellation()
                if let delta = OpenAIStreamParser.deltaText(fromLine: line) {
                    accumulated += delta
                    // 闭包跨执行域捕获 var 是 Swift 6 错误：先取 let 快照再交给主线程
                    let snapshot = accumulated
                    await MainActor.run { self.resultText = snapshot }
                }
            }
            let snapshot = accumulated
            await MainActor.run {
                self.finishStreaming()
                if snapshot.isEmpty {
                    self.errorMessage = "模型没有返回内容（流为空）"
                }
            }
        } catch is CancellationError {
            await MainActor.run { self.finishStreaming() }
        } catch {
            await MainActor.run {
                self.finishStreaming()
                self.errorMessage = Self.friendlyError(error)
            }
        }
    }

    /// 收尾：清流式状态。@Published 写操作一律主线程（perform 内通过 MainActor.run 调用）。
    private func finishStreaming() {
        isStreaming = false
        runningAction = nil
        streamTask = nil
    }

    /// 把网络错误翻译成用户能行动的话（本地代理没起/端点写错是最常见两种）。
    static func friendlyError(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
                return "连不上端点：\(nsError.localizedDescription)"
            case NSURLErrorTimedOut:
                return "请求超时，请重试"
            case NSURLErrorCancelled:
                return "已取消"
            default:
                break
            }
        }
        // 证书校验失败时系统原文是 "unknown certificate verification error" 这类英文串，
        // 直接抛到界面上用户无从下手；统一换成可行动的中文提示。
        return NetworkErrorText.describe(error)
    }

    func clearResult() {
        stopStreaming()
        resultText = ""
        errorMessage = nil
    }

    // MARK: - 端点连接检测

    /// 检测状态。idle 不显示；ok/failed 带中文结论，避免用户盲猜端点填对没。
    enum ProbeState: Equatable {
        case idle
        case running
        case ok(String)
        case failed(String)

        var isRunning: Bool { if case .running = self { return true }; return false }

        var isFailure: Bool { if case .failed = self { return true }; return false }

        var message: String? {
            switch self {
            case .ok(let text), .failed(let text): return text
            case .idle, .running: return nil
            }
        }
    }

    @Published private(set) var probe: ProbeState = .idle
    private var probeTask: Task<Void, Never>?

    /// 用最小请求自检当前端点：填完地址/模型后点一下，立刻知道通不通、错在哪。
    func probeEndpoint() {
        guard settings.isConfigured else {
            probe = .failed("请先填写 API 地址和模型名")
            return
        }
        guard settings.chatCompletionsURL() != nil else {
            probe = .failed("端点无效：请检查 API 地址")
            return
        }

        probeTask?.cancel()
        probe = .running
        probeTask = Task { [weak self] in
            await self?.runProbe()
        }
    }

    /// 一键填入本机中继端点（改完可立刻再点「检测连接」验证）。
    func useLocalRelayEndpoint() {
        updateSettings {
            $0.endpoint = AIAssistSettings.localRelayEndpoint
        }
        probe = .idle
    }

    private func runProbe() async {
        guard let url = settings.chatCompletionsURL(),
              let body = settings.buildProbeBody()
        else {
            await MainActor.run { self.probe = .failed("端点无效：请检查 API 地址") }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key = AIAssistSettings.apiKey(), !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        request.timeoutInterval = 60

        let started = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let latency = Int(Date().timeIntervalSince(started) * 1000)
            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                let raw = String(data: data, encoding: .utf8)
                let message = AIAssistErrorTranslator.friendlyMessage(
                    statusCode: http.statusCode,
                    body: raw
                )
                await MainActor.run { self.probe = .failed(message) }
                return
            }
            let raw = String(data: data, encoding: .utf8) ?? ""
            let reply = OpenAIStreamParser.messageText(fromJSON: raw)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var text = "连接正常（\(latency) ms）"
            if let reply, !reply.isEmpty {
                text += " · 模型回复：\(reply)"
            }
            // 闭包跨执行域捕获 var 是 Swift 6 错误：先取 let 快照再交给主线程
            let snapshot = text
            await MainActor.run { self.probe = .ok(snapshot) }
        } catch is CancellationError {
            // 用户改了端点导致重新检测，保持 running 由新任务接管
        } catch {
            let message = Self.friendlyError(error)
            await MainActor.run { self.probe = .failed(message) }
        }
    }

    // MARK: - 本机 Ollama

    enum OllamaState: Equatable {
        case idle
        case unavailable
        case ready([OllamaProvider.Model])

        var models: [OllamaProvider.Model] {
            if case .ready(let list) = self { return list }
            return []
        }

        var isReady: Bool { if case .ready = self { return true }; return false }
    }

    @Published private(set) var ollamaState: OllamaState = .idle
    private var ollamaProbeTask: Task<Void, Never>?

    func refreshOllamaModels() {
        ollamaProbeTask?.cancel()
        ollamaProbeTask = Task { [weak self] in await self?.fetchOllamaModels() }
    }

    private func fetchOllamaModels() async {
        guard let url = OllamaProvider.tagsURL else {
            await MainActor.run { self.ollamaState = .unavailable }
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let models = OllamaProvider.parseTags(String(data: data, encoding: .utf8) ?? "")
            await MainActor.run { self.ollamaState = models.isEmpty ? .unavailable : .ready(models) }
        } catch is CancellationError {
        } catch {
            await MainActor.run { self.ollamaState = .unavailable }
        }
    }

    /// 一键启用：写入 OpenAI 兼容端点 + 推荐（最大可对话）模型，并清掉可能残留的远端 Key。
    func useOllama() {
        guard case .ready(let models) = ollamaState,
              let chosen = OllamaProvider.recommendedChatModel(from: models)?.name,
              !chosen.isEmpty
        else { return }
        updateSettings {
            $0.endpoint = OllamaProvider.openAICompatBase
            $0.model = chosen
        }
        AIAssistSettings.setAPIKey("")
    }
}
