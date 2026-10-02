import Foundation

/// TV 遥控协议层（纯逻辑，可单测；不引入 SwiftUI/AppKit）。
///
/// 对端是本机 **ATV Remote** 开源服务的 HTTP API（默认 `http://127.0.0.1:8300`）。
/// 那一边用 `pyatv` 走 MediaRemote / Companion 协议控 Apple TV、用 `adb` 控 Android TV，
/// 因此 Lumi 完全不必自己实现电视协议，只需把遥控命令转成它的 JSON 请求体。
///
/// 三条关键约定（读上游源码得出，改动前先对照 `~/atv-remote/server.py`）：
/// 1. 键码统一用 **Android `keyevent` 编号**（19=上 20=下 21=左 22=右 23=OK…），
///    服务端内部映射到 pyatv 指令；对端是 Apple TV 还是 Android TV 由服务端分发，Lumi 无感。
/// 2. 所有控制命令都走 `POST /api/cmd`，请求体是**扁平 JSON**（`type` + 该类型自己的字段），
///    没有的字段不要发——服务端按 key 是否存在做判断（`body.get("enter")` 取不到即为假）。
/// 3. 错误一律是 HTTP 200 + `{"error": "人类可读原因"}`；只有未匹配路由才是 404。
///    所以「失败」不能只看 `error == nil`，必须解析 body 里的 `error` 字段。
///
/// 分层理由：请求体编码 / 响应解码 / 错误提取都是可单测的纯函数，
/// 网络与并发副作用全部集中在 `TVController`，避免把 URLSession 混进协议层。

// MARK: - 失败载体

/// 请求失败的载体。
///
/// `Result` 的 `Failure` 必须 conform to `Error`，直接把 `String` 当失败类型编译不过；
/// 包一层最小结构即可，调用方统一读 `message` 展示给用户。
struct TVRequestFailure: Error, Equatable {
    let message: String
}

// MARK: - 键码

/// 遥控键码（Android `keyevent` 编号，与 ATV Remote 的前端/服务端共用同一套）。
///
/// 注意 tvOS 16+ 走 Companion、tvOS ≤15 走 MRP，同一键码在两端语义不同
/// （如 82：Companion 下是控制中心，MRP 下才是主屏），因此 `home` 用 3 ——
/// 3 在 Companion 与 MRP 下都指向主屏，是最稳的「回主页」键。
enum TVKeyCode: Int, CaseIterable {
    case up = 19
    case down = 20
    case left = 21
    case right = 22
    case select = 23
    case menu = 4
    case home = 3
    case controlCenter = 82
    case playPause = 85
    case play = 126
    case pause = 127
    case next = 87
    case previous = 88
    case volumeUp = 24
    case volumeDown = 25
    /// 睡眠/息屏键（幂等，不像电源键会翻转状态）
    case sleep = 223
    case powerTurnOff = 26
    case powerTurnOn = 224

    /// 面板按钮上的 SF Symbol。
    var symbol: String {
        switch self {
        case .up:           return "chevron.up"
        case .down:         return "chevron.down"
        case .left:         return "chevron.left"
        case .right:        return "chevron.right"
        case .select:       return "circle.fill"
        case .menu:         return "ellipsis.circle"
        case .home:         return "house.fill"
        case .controlCenter: return "switch.2"
        case .playPause:    return "playpause.fill"
        case .play:         return "play.fill"
        case .pause:        return "pause.fill"
        case .next:         return "forward.fill"
        case .previous:     return "backward.fill"
        case .volumeUp:     return "speaker.wave.3.fill"
        case .volumeDown:   return "speaker.wave.1.fill"
        case .sleep:        return "moon.fill"
        case .powerTurnOff: return "power"
        case .powerTurnOn:  return "power.circle"
        }
    }

    /// 鼠标悬停提示。
    var title: String {
        switch self {
        case .up:           return "上"
        case .down:         return "下"
        case .left:         return "左"
        case .right:        return "右"
        case .select:       return "OK"
        case .menu:         return "菜单"
        case .home:         return "主屏"
        case .controlCenter: return "控制中心"
        case .playPause:    return "播放/暂停"
        case .play:         return "播放"
        case .pause:        return "暂停"
        case .next:         return "下一个"
        case .previous:     return "上一个"
        case .volumeUp:     return "音量加"
        case .volumeDown:   return "音量减"
        case .sleep:        return "睡眠"
        case .powerTurnOff: return "关闭"
        case .powerTurnOn:  return "唤醒"
        }
    }
}

// MARK: - 宏步骤

/// 宏步骤：与上游 `MACRO_STEP_TYPES` 对齐（`key` / `text` / `app`，外加纯延时步）。
/// 纯延时步**不能带 `type`**——上游靠 `step.get("type") or "delay"` 识别，发 `type:"delay"` 会 400。
struct TVMacroStep: Codable, Equatable {
    var type: String?
    /// 键码列表。上游同时接受复数 `codes` 与单数 `code`（预设宏里两种都出现过），
    /// 解码时统一归一成 `codes`，否则单数写法的宏步骤转发回去会变成空步骤、被上游 400。
    var codes: [Int]?
    /// 仅解码用：上游预设宏的单数键码写法。编码时已归一进 `codes`，不会单独发出。
    private var singularCode: Int?
    var text: String?
    var enter: Bool?
    var pkg: String?
    var pkgs: [String]?
    var delay: Int?

    private enum CodingKeys: String, CodingKey {
        case type, code, codes, text, enter, pkg, pkgs, delay
    }

    init(type: String? = nil, codes: [Int]? = nil, text: String? = nil,
         enter: Bool? = nil, pkg: String? = nil, pkgs: [String]? = nil, delay: Int? = nil) {
        self.type = type
        self.codes = codes
        self.text = text
        self.enter = enter
        self.pkg = pkg
        self.pkgs = pkgs
        self.delay = delay
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        codes = try c.decodeIfPresent([Int].self, forKey: .codes)
        singularCode = try c.decodeIfPresent(Int.self, forKey: .code)
        // 单数归一：缺 codes 时才用，避免两种写法同时出现时互相覆盖
        if codes == nil, let singularCode = singularCode { codes = [singularCode] }
        text = try c.decodeIfPresent(String.self, forKey: .text)
        enter = try c.decodeIfPresent(Bool.self, forKey: .enter)
        pkg = try c.decodeIfPresent(String.self, forKey: .pkg)
        pkgs = try c.decodeIfPresent([String].self, forKey: .pkgs)
        delay = try c.decodeIfPresent(Int.self, forKey: .delay)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(type, forKey: .type)
        try c.encodeIfPresent(codes, forKey: .codes)
        try c.encodeIfPresent(text, forKey: .text)
        try c.encodeIfPresent(enter, forKey: .enter)
        try c.encodeIfPresent(pkg, forKey: .pkg)
        try c.encodeIfPresent(pkgs, forKey: .pkgs)
        try c.encodeIfPresent(delay, forKey: .delay)
    }

    /// 该步的类型：纯延时步显式归为 `delay`。
    var effectiveType: String { type ?? "delay" }
}

// MARK: - 命令请求体

/// `POST /api/cmd` 与 `POST /api/macro` 用的扁平请求体。
///
/// `nil` 字段一律不编码：上游对同一 `type` 只读自己那几 个 key，
/// 多发 `codes: null` 之类反而可能被 `list(body.get("codes") or [])` 之外的严格分支绊倒。
struct TVCommandPayload: Codable, Equatable {
    var type: String
    /// 设备 id。`/api/atv/connect` 靠它在已保存列表里找设备（缺失时上游会 500，
    /// 因为这个字段不是可选的）。
    var id: String?
    var codes: [Int]?
    var text: String?
    var enter: Bool?
    var pkg: String?
    var x1: Double?
    var y1: Double?
    var x2: Double?
    var y2: Double?
    var duration: Int?
    var action: String?
    var name: String?
    var minutes: Int?
    var steps: [TVMacroStep]?

    private enum CodingKeys: String, CodingKey {
        case type, id, codes, text, enter, pkg, x1, y1, x2, y2,
             duration, action, name, minutes, steps
    }

    init(type: String, id: String? = nil, codes: [Int]? = nil, text: String? = nil,
         enter: Bool? = nil, pkg: String? = nil, x1: Double? = nil, y1: Double? = nil,
         x2: Double? = nil, y2: Double? = nil, duration: Int? = nil, action: String? = nil,
         name: String? = nil, minutes: Int? = nil, steps: [TVMacroStep]? = nil) {
        self.type = type
        self.id = id
        self.codes = codes
        self.text = text
        self.enter = enter
        self.pkg = pkg
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
        self.duration = duration
        self.action = action
        self.name = name
        self.minutes = minutes
        self.steps = steps
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        codes = try c.decodeIfPresent([Int].self, forKey: .codes)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        enter = try c.decodeIfPresent(Bool.self, forKey: .enter)
        pkg = try c.decodeIfPresent(String.self, forKey: .pkg)
        x1 = try c.decodeIfPresent(Double.self, forKey: .x1)
        y1 = try c.decodeIfPresent(Double.self, forKey: .y1)
        x2 = try c.decodeIfPresent(Double.self, forKey: .x2)
        y2 = try c.decodeIfPresent(Double.self, forKey: .y2)
        duration = try c.decodeIfPresent(Int.self, forKey: .duration)
        action = try c.decodeIfPresent(String.self, forKey: .action)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        minutes = try c.decodeIfPresent(Int.self, forKey: .minutes)
        steps = try c.decodeIfPresent([TVMacroStep].self, forKey: .steps)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encodeIfPresent(codes, forKey: .codes)
        try c.encodeIfPresent(text, forKey: .text)
        try c.encodeIfPresent(enter, forKey: .enter)
        try c.encodeIfPresent(pkg, forKey: .pkg)
        try c.encodeIfPresent(x1, forKey: .x1)
        try c.encodeIfPresent(y1, forKey: .y1)
        try c.encodeIfPresent(x2, forKey: .x2)
        try c.encodeIfPresent(y2, forKey: .y2)
        try c.encodeIfPresent(duration, forKey: .duration)
        try c.encodeIfPresent(action, forKey: .action)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(minutes, forKey: .minutes)
        try c.encodeIfPresent(steps, forKey: .steps)
    }

    /// 序列化为请求体字节；`type` 为空时返回 nil（调用方可以直接放弃这次请求）。
    func jsonData() -> Data? {
        guard !type.isEmpty else { return nil }
        return try? JSONEncoder().encode(self)
    }
}

// MARK: - 命令构造

extension TVCommandPayload {
    /// 单键。上游对不支持的键码会抛「Apple TV 不支持键码 N」，所以这里只放已确认在
    /// `KEY_MAP_MRP` / `KEY_MAP_COMPANION` 里都存在的键。
    static func key(_ code: TVKeyCode) -> TVCommandPayload {
        TVCommandPayload(type: "key", codes: [code.rawValue])
    }

    /// 连发多个键码（如音量连降 3 格）。
    static func keys(_ codes: [TVKeyCode]) -> TVCommandPayload {
        TVCommandPayload(type: "key", codes: codes.map(\.rawValue))
    }

    /// 文本输入。`enter = true` 时上游发完文本会补一次 select（搜索框场景）。
    static func text(_ text: String, enter: Bool) -> TVCommandPayload {
        TVCommandPayload(type: "text", text: text, enter: enter)
    }

    /// 轻点（Apple TV 无坐标概念，等价 OK；Android TV 才会用坐标）。
    static func tap() -> TVCommandPayload { TVCommandPayload(type: "tap") }

    /// 滑动手势，坐标用 0.0~1.0 归一化（上游自己 clamp）。
    static func swipe(x1: Double, y1: Double, x2: Double, y2: Double,
                     duration: Int = 300) -> TVCommandPayload {
        TVCommandPayload(type: "swipe", x1: x1, y1: y1, x2: x2, y2: y2, duration: duration)
    }

    /// 启动应用。`pkg` 同时接受 tvOS bundle id 与 Android 包名，由对端自行识别。
    static func app(_ bundleID: String) -> TVCommandPayload {
        TVCommandPayload(type: "app", pkg: bundleID)
    }

    /// 跑一条宏。宏步骤由服务端串行执行，单步失败不中断（所以「观影模式」里 Netflix
    /// 没装时，后面的音量调整照跑）。
    static func macro(name: String, steps: [TVMacroStep]) -> TVCommandPayload {
        TVCommandPayload(type: "macro", action: "run", name: name, steps: steps)
    }

    /// 取消正在执行的宏。
    static func cancelMacro() -> TVCommandPayload {
        TVCommandPayload(type: "macro", action: "cancel")
    }

    /// 睡眠定时：到点服务端自动发睡眠键（Apple TV 走电源关闭）。
    static func sleepTimer(minutes: Int) -> TVCommandPayload {
        TVCommandPayload(type: "timer", action: "set", minutes: minutes)
    }

    static func cancelSleepTimer() -> TVCommandPayload {
        TVCommandPayload(type: "timer", action: "cancel")
    }
}

// MARK: - 预设宏

/// `GET /api/macros` 返回的预设宏。直接透传上游 `PRESET_MACROS`，不自行维护一份清单——
/// 上游加宏 Lumi 立刻就有，不会出现「上游有、Lumi 没有」的漂移。
struct TVPresetMacro: Identifiable, Codable, Equatable {
    let id: String
    let icon: String
    let name: String
    let steps: [TVMacroStep]

    /// 未命名预设的兜底文案。
    var displayName: String { name.isEmpty ? id : name }
}

// MARK: - 设备

/// 一个可遥控的电视。`/api/status` 的 `appletv.devices[]` 与 `/api/atv/scan` 的
/// `devices[]` 字段一致（id/name/ip/proto），同一份 Decodable 两处复用。
struct TVDevice: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let ip: String
    let proto: String
    /// 仅扫描结果带：是否已配对过。
    var paired: Bool?

    var idText: String { id }

    var displayName: String { name.isEmpty ? ip : name }
}

/// `GET /api/atv/apps` 返回的对端已安装应用。
struct TVApp: Identifiable, Codable, Equatable {
    let id: String
    let name: String

    var idText: String { id }
    var displayName: String { name.isEmpty ? id : name }
}

// MARK: - 状态

/// `/api/status` 的解码结果 + 派生展示字段。
///
/// 上游把 Android 与 Apple TV 的状态塞在同一个 JSON 里但结构不同
/// （Android 在顶层 `devices`/`recent`，Apple TV 在 `appletv` 下），这里统一收敛成
/// 「当前是什么设备、连没连上、有没有在跑宏」，UI 不用再分支。
struct TVStatus: Equatable {
    /// 服务本身可达（拿到 200 且解析成功）。
    var serviceReachable: Bool = false
    /// 对端类型：`appletv` / `android` / nil（未选设备）。
    var currentType: String?
    /// 当前设备 id（Apple TV 是 MAC，Android 是 `ip:port`）。
    var currentID: String?
    /// 当前设备显示名。
    var deviceName: String?
    /// 对端是否已连接（Apple TV 看 `appletv.connected`，Android 看设备 state）。
    var connected: Bool = false
    /// 服务端是否装了 pyatv（没装则 Apple TV 不可用，只能控 Android TV）。
    var appleTVAvailable: Bool = false
    /// 电视端输入框聚焦状态：Focused / Unfocused / Unknown。
    var keyboardFocus: String?
    var sleepTimerActive: Bool = false
    var sleepTimerRemaining: Int = 0
    var macroRunning: Bool = false
    /// 已配对/已保存的 Apple TV 列表（可切换）。
    var appleTVs: [TVDevice] = []
    var serviceVersion: String?

    var hasDevice: Bool { currentID != nil && !(currentID ?? "").isEmpty }
    var isAppleTV: Bool { currentType == "appletv" }
    var isAndroidTV: Bool { currentType == "android" }

    /// 面板副标题：一句说清「连的什么、连没连上」。
    var summaryLine: String {
        guard serviceReachable else { return "服务未连接" }
        guard let type = currentType else { return "未选择设备" }
        let name = deviceName ?? currentID ?? "未知设备"
        switch type {
        case "appletv":
            return connected ? "\(name) · 已连接" : "\(name) · 连接中"
        case "android":
            return connected ? "\(name) · 已连接" : "\(name) · 离线"
        default:
            return name
        }
    }
}

// MARK: - 解析（纯函数）

enum TVRemoteParser {
    /// 上游错误响应体：`{"error": "..."}`。
    struct ErrorEnvelope: Decodable { let error: String? }

    /// 解析 `/api/status`。
    ///
    /// 容错策略：字段缺失按「不可用」处理而不是抛错——服务未启动时 Lumi 拿到的是
    /// 连接错误（走 `status(from:)` 的失败分支），能拿到 200 就说明服务活着，
    /// 此时个别字段缺失只影响展示，不该让整个面板崩掉。
    static func status(from data: Data) -> TVStatus? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var s = TVStatus()
        s.serviceReachable = true
        s.currentType = root["cur_type"] as? String
        s.currentID = root["current"] as? String
        s.serviceVersion = root["version"] as? String
        s.keyboardFocus = (root["appletv"] as? [String: Any])?["kb_focus"] as? String
        s.appleTVAvailable = (root["appletv"] as? [String: Any])?["available"] as? Bool ?? false
        s.appleTVs = decodeArray(root["appletv"], key: "devices")

        if let sleep = root["sleep_timer"] as? [String: Any] {
            s.sleepTimerActive = sleep["active"] as? Bool ?? false
            s.sleepTimerRemaining = sleep["remaining"] as? Int ?? 0
        }
        if let macro = root["macro"] as? [String: Any] {
            s.macroRunning = macro["running"] as? Bool ?? false
        }

        // 设备名：优先按 id 在已保存 Apple TV 里找（`info.model` 在切到 Android 后
        // 不会清干净，不能单独作为依据），找不到再退回 info.model。
        if let id = s.currentID, !id.isEmpty {
            if let known = s.appleTVs.first(where: { $0.id == id }) {
                s.deviceName = known.displayName
            } else if let model = (root["info"] as? [String: Any])?["model"] as? String,
                      !model.isEmpty {
                s.deviceName = model
            } else {
                s.deviceName = id
            }
        } else if let model = (root["info"] as? [String: Any])?["model"] as? String,
                  !model.isEmpty {
            s.deviceName = model
        }

        // 连接态：Apple TV 看 atv_mgr.connected；Android 看当前 serial 在不在
        // adb devices 里且 state 为 device。
        if s.currentType == "appletv" {
            s.connected = (root["appletv"] as? [String: Any])?["connected"] as? Bool ?? false
        } else if s.currentType == "android" {
            let devices = root["devices"] as? [[String: Any]] ?? []
            s.connected = devices.contains {
                ($0["serial"] as? String) == s.currentID
                    && ($0["state"] as? String) == "device"
            }
        }
        return s
    }

    /// 用失败信息构造一个「服务不可达」状态，避免 UI 读到半空状态。
    static func unreachableStatus() -> TVStatus {
        TVStatus(serviceReachable: false)
    }

    /// 解析 `/api/macros`。
    static func presets(from data: Data) -> [TVPresetMacro] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["presets"] as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            let steps = (item["steps"] as? [[String: Any]])?.compactMap(decodeStep) ?? []
            return TVPresetMacro(
                id: id,
                icon: item["icon"] as? String ?? "▶️",
                name: item["name"] as? String ?? "",
                steps: steps
            )
        }
    }

    /// 解析 `/api/atv/scan` / `/api/atv/apps`。
    static func devices(from data: Data) -> [TVDevice] {
        decodeArray(try? JSONSerialization.jsonObject(with: data), key: "devices")
    }

    static func apps(from data: Data) -> [TVApp] {
        decodeArray(try? JSONSerialization.jsonObject(with: data), key: "apps")
    }

    /// 提取上游错误文案。成功响应返回 nil。
    ///
    /// 上游把业务错误放在 200 body 里，所以「HTTP 200 但 body 有 error」才是真失败；
    /// 只判断 `error == nil` 会把「未连接电视」当成成功，界面毫无反应。
    static func errorMessage(data: Data?, response: URLResponse?) -> String? {
        if let response = response as? HTTPURLResponse,
           response.statusCode == 404 {
            return "服务没有该接口（可能是 ATV Remote 版本过旧）"
        }
        guard let data = data, !data.isEmpty,
              let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
              let message = envelope.error, !message.isEmpty else {
            return nil
        }
        return message
    }

    /// 传输层错误 → 人类可读原因。服务没起时最常见，文案要直接给出下一步动作。
    static func transportMessage(for error: Error?) -> String {
        guard let error = error else { return "未知错误" }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return NetworkErrorText.describe(error) }
        switch nsError.code {
        case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
            return "连不上 ATV Remote 服务（127.0.0.1:8300 未启动？）"
        case NSURLErrorTimedOut:
            return "ATV Remote 服务响应超时"
        case NSURLErrorNetworkConnectionLost:
            return "与 ATV Remote 服务的连接中断"
        default:
            // 其余走统一文案：证书类（本机代理解密 HTTPS）必须翻成可操作的中文，
            // 否则界面会直接显示 unknown certificate verification error 这类英文原串。
            return NetworkErrorText.describe(error)
        }
    }

    // MARK: 内部工具

    /// 把 `{"<key>": [ {...}, ... ]}` 里的数组解码成 `[T]`。
    ///
    /// 走 `JSONSerialization` 中转而不是手写字段提取：`TVDevice` 与 `TVApp`
    /// 字段集不同但形状相同（都有 `id`），共用一个泛型入口即可，
    /// 上游加字段时 `Codable` 自动忽略、不会漏解析。
    private static func decodeArray<T: Decodable>(_ root: Any?, key: String) -> [T] {
        guard let root = root as? [String: Any],
              let list = root[key] as? [[String: Any]],
              let data = try? JSONSerialization.data(withJSONObject: list) else { return [] }
        return (try? JSONDecoder().decode([T].self, from: data)) ?? []
    }

    /// 手工解析宏步骤（预设宏来自 `JSONSerialization` 中转，不经过 `Codable`）。
    /// 这里同样要做单数 `code` → `codes` 的归一，否则「静音 / 取消」这类用单数写法的
    /// 预设宏转发回服务端时会缺键码，被 400「缺少键码」。
    private static func decodeStep(_ item: [String: Any]) -> TVMacroStep? {
        var codes = item["codes"] as? [Int]
        if codes == nil, let singular = item["code"] as? Int {
            codes = [singular]
        }
        return TVMacroStep(
            type: item["type"] as? String,
            codes: codes,
            text: item["text"] as? String,
            enter: item["enter"] as? Bool,
            pkg: item["pkg"] as? String,
            pkgs: item["pkgs"] as? [String],
            delay: item["delay"] as? Int
        )
    }
}
