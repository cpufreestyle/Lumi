import AppKit
import Foundation

/// TV 遥控控制器：把用户操作转成 ATV Remote 开源服务的 HTTP 调用。
///
/// 为什么是「调用」而不是「重写」：Apple TV 的遥控协议是 MediaRemote / Companion
/// 私有协议（iOS「遥控器」App 同款），自己实现要处理配对凭据、加密、广播发现，
/// 工作量以千行计且无法在本机验证。`~/atv-remote` 已用 `pyatv` 把这些做成本机 HTTP
/// 服务（LaunchAgent 常驻 `127.0.0.1:8300`），Lumi 只做它的一层 UI——这正是「调用开源
/// 项目」的收益：协议层零成本，且上游更新（新键、新宏、新机型）Lumi 自动跟上。
///
/// 轮询档位（遵循 `PollingCoordinator` 约定，不手写常驻 Timer）：
/// - 展开且停在「电视」页：3s 刷一次状态（切歌/重连要跟着变）；
/// - 其他情况：60s 兜底，让收缩态副标题反映真实连接态；
/// - 服务没起来时把状态间隔放长到 15s，避免每 3s 空转一次；
/// - 画面（artwork）：仅 Apple TV 已连接且面板可见时 8s 拉一次，其余 0（不执行）。
final class TVController: ObservableObject {
    static let shared = TVController()

    /// 默认服务地址：ATV Remote 的 LaunchAgent 固定监听 127.0.0.1:8300。
    static let defaultBaseURL = "http://127.0.0.1:8300"
    private static let baseURLKey = "lumi_tv_base_url_v1"

    // MARK: - 可观察状态

    @Published private(set) var status: TVStatus = TVRemoteParser.unreachableStatus()
    @Published private(set) var presets: [TVPresetMacro] = []
    @Published private(set) var apps: [TVApp] = []
    /// 最近一次扫描到的设备（设备切换面板用）。
    @Published private(set) var scanResults: [TVDevice] = []
    /// 电视正在播放的画面（`GET /api/screenshot`，仅 Apple TV 有）。
    @Published private(set) var artwork: NSImage?
    @Published private(set) var isBusy = false
    /// 面板里的一句话反馈（命令结果 / 错误），4 秒后自动清空。
    @Published private(set) var feedback: String?
    /// 是否展开「服务地址」设置区（齿轮按钮切换）。
    @Published var showSettings: Bool = false
    @Published private(set) var lastRefreshDate: Date?

    /// 服务地址（可改：有人在别的端口跑 ATV Remote）。空值回落默认地址。
    var baseURLString: String {
        get {
            let stored = UserDefaults.standard.string(forKey: Self.baseURLKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return stored.isEmpty ? Self.defaultBaseURL : stored
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == Self.defaultBaseURL {
                UserDefaults.standard.removeObject(forKey: Self.baseURLKey)
            } else {
                UserDefaults.standard.set(trimmed, forKey: Self.baseURLKey)
            }
            // 地址变了，旧地址的状态/画面全部作废，立刻重探
            status = TVRemoteParser.unreachableStatus()
            artwork = nil
            appsLoaded = false
            refreshStatus()
        }
    }

    // MARK: - 内部

    private let queue = DispatchQueue(label: "com.lumi.tv", qos: .userInitiated)
    private var feedbackWork: DispatchWorkItem?
    private var appsLoaded = false

    private init() {
        PollingCoordinator.shared.register(
            id: "tv.status",
            interval: { [weak self] in self?.statusInterval() ?? 0 },
            action: { [weak self] in self?.refreshStatus() }
        )
        PollingCoordinator.shared.register(
            id: "tv.artwork",
            interval: { [weak self] in self?.artworkInterval() ?? 0 },
            action: { [weak self] in self?.refreshArtwork() }
        )
        refreshStatus()
    }

    // MARK: - 轮询档位

    private func isTVPanelVisible() -> Bool {
        let state = AppState.shared
        return state.isExpanded && state.activeModule == .tv
    }

    private func statusInterval() -> TimeInterval {
        guard isTVPanelVisible() else { return 60 }
        return status.serviceReachable ? 3 : 15
    }

    private func artworkInterval() -> TimeInterval {
        guard isTVPanelVisible() else { return 0 }
        guard status.serviceReachable, status.isAppleTV, status.connected else { return 0 }
        return 8
    }

    // MARK: - 面板入口

    /// 面板出现时调用；补齐「状态 + 预设宏 + 应用列表」。
    func activate() {
        refreshStatus()
        refreshPresets()
        if !appsLoaded { refreshApps() }
    }

    // MARK: - 状态 / 列表

    func refreshStatus() {
        request(.get, "/api/status") { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let data):
                if let parsed = TVRemoteParser.status(from: data) {
                    self.status = parsed
                    self.lastRefreshDate = Date()
                    // 刚连上 Apple TV 时把应用列表补上
                    if !self.appsLoaded, parsed.isAppleTV, parsed.connected {
                        self.refreshApps()
                    }
                } else {
                    self.status = TVRemoteParser.unreachableStatus()
                    self.showFeedback("无法解析服务返回的状态")
                }
            case .failure(let failure):
                let wasReachable = self.status.serviceReachable
                self.status = TVRemoteParser.unreachableStatus()
                self.artwork = nil
                // 从没连上过时不弹提示（面板里的「服务未连接」已经说清了），
                // 只有「刚才还好好的突然断了」才值得打扰。
                if wasReachable {
                    self.showFeedback(failure.message)
                }
            }
        }
    }

    func refreshPresets() {
        request(.get, "/api/macros") { [weak self] result in
            guard let self = self else { return }
            if case .success(let data) = result {
                let parsed = TVRemoteParser.presets(from: data)
                if !parsed.isEmpty { self.presets = parsed }
            }
        }
    }

    func refreshApps() {
        request(.get, "/api/atv/apps") { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let data):
                self.apps = TVRemoteParser.apps(from: data)
                self.appsLoaded = true
            case .failure(let failure):
                // 未连接电视时上游会 400「未连接 Apple TV」，这不是需要弹反馈的故障
                if self.status.connected {
                    self.showFeedback(failure.message)
                }
            }
        }
    }

    func refreshArtwork() {
        request(.get, "/api/screenshot") { [weak self] result in
            guard let self = self else { return }
            if case .success(let data) = result {
                self.artwork = NSImage(data: data)
            }
        }
    }

    // MARK: - 遥控命令

    /// 统一的命令出口。所有遥控动作都走这里，方便统一收口错误反馈。
    /// 方法名带 `Command` 后缀是为了避开 Darwin 的全局 `send(2)`——
    /// 同名时 Swift 会优先解析到 C 函数，报一堆难以理解的错误。
    func sendCommand(_ payload: TVCommandPayload, successMessage: String? = nil) {
        isBusy = true
        request(.post, "/api/cmd", body: payload) { [weak self] result in
            guard let self = self else { return }
            self.isBusy = false
            switch result {
            case .success:
                if let successMessage = successMessage {
                    self.showFeedback(successMessage)
                }
            case .failure(let failure):
                self.showFeedback(failure.message)
            }
        }
    }

    func sendKey(_ code: TVKeyCode) {
        sendCommand(.key(code))
    }

    func sendKeys(_ codes: [TVKeyCode]) {
        guard !codes.isEmpty else { return }
        sendCommand(.keys(codes))
    }

    func tap() {
        sendCommand(.tap())
    }

    func launchApp(_ bundleID: String) {
        let name = apps.first { $0.id == bundleID }?.displayName ?? bundleID
        sendCommand(.app(bundleID), successMessage: "已启动 \(name)")
    }

    func sendText(_ text: String, enter: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showFeedback("请输入要发送到电视的文字")
            return
        }
        sendCommand(.text(trimmed, enter: enter), successMessage: "已发送 \(trimmed.count) 字")
    }

    func runPreset(_ macro: TVPresetMacro) {
        guard !macro.steps.isEmpty else {
            showFeedback("宏「\(macro.displayName)」没有步骤")
            return
        }
        sendCommand(.macro(name: macro.displayName, steps: macro.steps),
                    successMessage: "已执行宏「\(macro.displayName)」")
    }

    func cancelMacro() {
        sendCommand(.cancelMacro(), successMessage: "已取消宏")
    }

    func setSleepTimer(minutes: Int) {
        sendCommand(.sleepTimer(minutes: minutes), successMessage: "睡眠定时 \(minutes) 分钟")
    }

    func cancelSleepTimer() {
        sendCommand(.cancelSleepTimer(), successMessage: "已取消睡眠定时")
    }

    // MARK: - 设备管理

    func scanAppleTVs() {
        isBusy = true
        request(.post, "/api/atv/scan", body: TVCommandPayload(type: "scan")) { [weak self] result in
            guard let self = self else { return }
            self.isBusy = false
            switch result {
            case .success(let data):
                let found = TVRemoteParser.devices(from: data)
                self.scanResults = found
                self.showFeedback(found.isEmpty ? "局域网内没扫到 Apple TV" : "扫到 \(found.count) 台 Apple TV")
            case .failure(let failure):
                self.showFeedback(failure.message)
            }
        }
    }

    func connectAppleTV(id: String) {
        isBusy = true
        // /api/atv/connect 按 id 在已保存列表里找设备，id 缺失时上游直接 KeyError 500，
        // 所以这里必须发真 id（不能用别的字段捎带）。
        request(.post, "/api/atv/connect",
                body: TVCommandPayload(type: "connect", id: id)) { [weak self] result in
            guard let self = self else { return }
            self.isBusy = false
            switch result {
            case .success:
                self.showFeedback("已连接")
                self.refreshStatus()
            case .failure(let failure):
                self.showFeedback(failure.message)
            }
        }
    }

    func disconnect() {
        request(.post, "/api/atv/disconnect", body: TVCommandPayload(type: "disconnect")) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                self.showFeedback("已断开")
                self.refreshStatus()
            case .failure(let failure):
                self.showFeedback(failure.message)
            }
        }
    }

    // MARK: - 反馈

    func showFeedback(_ message: String) {
        feedbackWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.feedback = nil
        }
        feedbackWork = work
        DispatchQueue.main.async { [weak self] in
            self?.feedback = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    // MARK: - HTTP

    private enum Method {
        case get, post
    }

    /// 统一请求入口。所有网络副作用都收在这里，便于统一处理两种失败形态：
    /// 传输层失败（服务没起/超时）与上游「HTTP 200 但 body 带 error」。
    private func request(_ method: Method, _ path: String,
                         body: TVCommandPayload? = nil,
                         completion: ((Result<Data, TVRequestFailure>) -> Void)? = nil) {
        let base = baseURLString
        guard !base.isEmpty, let baseURL = URL(string: base),
              let url = URL(string: path, relativeTo: baseURL) else {
            completion?(.failure(TVRequestFailure(message: "服务地址无效：\(base)")))
            return
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        if method == .post {
            req.httpMethod = "POST"
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            if let body = body {
                // 提前校验：body 编码不出来就没必要发出去
                guard body.jsonData() != nil else {
                    completion?(.failure(TVRequestFailure(message: "请求体构造失败")))
                    return
                }
            }
            req.httpBody = body?.jsonData() ?? Data("{}".utf8)
        }

        queue.async {
            URLSession.shared.dataTask(with: req) { data, response, error in
                if let error = error {
                    let message = TVRemoteParser.transportMessage(for: error)
                    DispatchQueue.main.async { completion?(.failure(TVRequestFailure(message: message))) }
                    return
                }
                if let message = TVRemoteParser.errorMessage(data: data, response: response) {
                    DispatchQueue.main.async { completion?(.failure(TVRequestFailure(message: message))) }
                    return
                }
                DispatchQueue.main.async { completion?(.success(data ?? Data())) }
            }.resume()
        }
    }
}
