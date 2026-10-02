import XCTest
import Foundation
@testable import Lumi

/// TV 遥控协议层单测（纯逻辑：请求体编码 / 响应解码 / 错误提取）。
///
/// 只碰 `TVRemoteProtocol.swift` 里的值类型，不实例化 `TVController`、
/// 不发任何网络请求——遵守「测试目标只依赖 Foundation、不引入 GUI 框架」的约定。
///
/// 样本 JSON 全部抄自 `~/atv-remote` 服务的真实响应（2026-09-25 抓取），
/// 上游改字段时这些用例会红，比线上遥控失灵才发现要好。
final class TVRemoteProtocolTests: XCTestCase {

    // MARK: - 键码

    /// Lumi 面板上所有键码必须在上游支持的集合内。
    ///
    /// 上游 `atv_backend.py` 的 `KEY_MAP_MRP` / `KEY_MAP_COMPANION` 对不在表内的键码
    /// 直接抛「Apple TV 不支持键码 N」。取两张表的并集作为允许集合：
    /// 往 Lumi 加一个新键前，先确认它在这张表里，否则按下去只会收到一条错误提示。
    func testAllKeyCodesSupportedByUpstream() {
        let upstreamSupported: Set<Int> = [
            // 两张 KEY_MAP 的并集
            19, 20, 21, 22, 23,            // 方向 / OK
            4, 3, 82, 165,                 // menu / home(top_menu) / home(control_center) / guide
            85, 126, 127, 86, 87, 88,      // 播放控制
            92, 93,                        // 快进 / 快退（仅 Companion）
            223,                           // 睡眠
            24, 25,                        // 音量
            26, 224                        // 关机 / 唤醒
        ]
        for code in TVKeyCode.allCases {
            XCTAssertTrue(
                upstreamSupported.contains(code.rawValue),
                "键码 \(code.rawValue)（\(code.title)）不在上游 KEY_MAP 里，发过去会被拒绝"
            )
        }
    }

    /// `home` 必须是 3：3 在 MRP 与 Companion 下都指向主屏，是最稳的「回主页」键。
    func testHomeKeyIsStableAcrossProtocols() {
        XCTAssertEqual(TVKeyCode.home.rawValue, 3)
    }

    // MARK: - 请求体编码

    func testKeyPayloadEncodesFlatCodes() throws {
        let payload = TVCommandPayload.key(.up)
        let object = try decodeObject(payload)
        XCTAssertEqual(object["type"] as? String, "key")
        XCTAssertEqual(object["codes"] as? [Int], [19])
        // 未用到的字段一律不出现：上游按 key 是否存在做判断，多发 null 是噪声
        XCTAssertNil(object["text"])
        XCTAssertNil(object["pkg"])
    }

    func testMultiKeyPayloadSendsAllCodesInOrder() throws {
        let payload = TVCommandPayload.keys([.volumeDown, .volumeDown, .volumeDown])
        let object = try decodeObject(payload)
        XCTAssertEqual(object["codes"] as? [Int], [25, 25, 25])
    }

    func testTextPayloadIncludesEnterOnlyWhenSet() throws {
        let withEnter = try decodeObject(TVCommandPayload.text("搜索词", enter: true))
        XCTAssertEqual(withEnter["type"] as? String, "text")
        XCTAssertEqual(withEnter["text"] as? String, "搜索词")
        XCTAssertEqual(withEnter["enter"] as? Bool, true)
        XCTAssertNil(withEnter["codes"])

        let withoutEnter = try decodeObject(TVCommandPayload.text("密码", enter: false))
        XCTAssertEqual(withoutEnter["enter"] as? Bool, false)
    }

    func testAppPayloadCarriesBundleID() throws {
        let object = try decodeObject(TVCommandPayload.app("com.apple.TVApp"))
        XCTAssertEqual(object["type"] as? String, "app")
        XCTAssertEqual(object["pkg"] as? String, "com.apple.TVApp")
    }

    func testConnectPayloadUsesRealDeviceID() throws {
        // /api/atv/connect 用 body["id"] 在已保存列表里找设备，
        // 缺失时上游 `entry["id"]` 直接 KeyError → 500。这里必须走 id 字段。
        let object = try decodeObject(TVCommandPayload(type: "connect", id: "E2:1F"))
        XCTAssertEqual(object["id"] as? String, "E2:1F")
    }

    func testSleepTimerPayloadShape() throws {
        let object = try decodeObject(TVCommandPayload.sleepTimer(minutes: 30))
        XCTAssertEqual(object["type"] as? String, "timer")
        XCTAssertEqual(object["action"] as? String, "set")
        XCTAssertEqual(object["minutes"] as? Int, 30)
    }

    func testSwipePayloadKeepsNormalizedCoordinates() throws {
        let object = try decodeObject(
            TVCommandPayload.swipe(x1: 0.5, y1: 0.8, x2: 0.5, y2: 0.2, duration: 300)
        )
        XCTAssertEqual(object["type"] as? String, "swipe")
        XCTAssertEqual(object["x1"] as? Double, 0.5)
        XCTAssertEqual(object["y2"] as? Double, 0.2)
        XCTAssertEqual(object["duration"] as? Int, 300)
    }

    // MARK: - 宏步骤

    /// 纯延时步不能带 `type`：上游靠 `step.get("type") or "delay"` 识别，
    /// 发 `type:"delay"` 会命中「类型不在 MACRO_STEP_TYPES」而 400。
    func testDelayStepOmitsTypeField() throws {
        let step = TVMacroStep(delay: 2500)
        XCTAssertEqual(step.effectiveType, "delay")
        let object = try decodeObject(step)
        XCTAssertNil(object["type"])
        XCTAssertEqual(object["delay"] as? Int, 2500)
    }

    func testKeyStepCarriesCodes() throws {
        let step = TVMacroStep(type: "key", codes: [25, 25])
        let object = try decodeObject(step)
        XCTAssertEqual(object["type"] as? String, "key")
        XCTAssertEqual(object["codes"] as? [Int], [25, 25])
    }

    func testMacroPayloadEncodesStepsArray() throws {
        let payload = TVCommandPayload.macro(
            name: "观影模式",
            steps: [TVMacroStep(type: "app", pkgs: ["com.netflix.ninja"]),
                    TVMacroStep(delay: 2500),
                    TVMacroStep(type: "key", codes: [25, 25, 25])]
        )
        let object = try decodeObject(payload)
        XCTAssertEqual(object["type"] as? String, "macro")
        XCTAssertEqual(object["action"] as? String, "run")
        XCTAssertEqual(object["name"] as? String, "观影模式")
        let steps = try XCTUnwrap(object["steps"] as? [[String: Any]])
        XCTAssertEqual(steps.count, 3)
        XCTAssertNil(steps[1]["type"], "第 2 步是纯延时步，不能带 type")
    }

    // MARK: - 状态解码

    func testStatusDecodesAppleTVCurrentDevice() throws {
        let status = try XCTUnwrap(
            TVRemoteParser.status(from: appleTVStatusJSON),
            "真实 /api/status 样本应能解析"
        )
        XCTAssertTrue(status.serviceReachable)
        XCTAssertEqual(status.currentType, "appletv")
        XCTAssertEqual(status.currentID, "E2:1F:FE:54:26:83")
        XCTAssertEqual(status.deviceName, "主卧")
        XCTAssertTrue(status.connected)
        XCTAssertTrue(status.appleTVAvailable)
        XCTAssertEqual(status.keyboardFocus, "Unfocused")
        XCTAssertEqual(status.appleTVs.count, 1)
        XCTAssertEqual(status.appleTVs.first?.ip, "192.168.1.100")
        XCTAssertTrue(status.isAppleTV)
        XCTAssertFalse(status.hasDevice == false)
        XCTAssertEqual(status.summaryLine, "主卧 · 已连接")
    }

    func testStatusDecodesAndroidDeviceAsOfflineWhenNotInAdbList() throws {
        let json = """
        {"cur_type":"android","current":"192.168.1.20:5555","current_state":null,
         "info":{"brand":"Xiaomi","model":"客厅"},
         "devices":[],"recent":["192.168.1.20:5555"],
         "appletv":{"available":true,"devices":[],"connected":false,"kb_focus":null},
         "sleep_timer":{"active":false,"until":null,"remaining":0},
         "macro":{"running":false},"version":"1.0"}
        """.data(using: .utf8)!
        let status = try XCTUnwrap(TVRemoteParser.status(from: json))
        XCTAssertEqual(status.currentType, "android")
        XCTAssertEqual(status.deviceName, "客厅")
        XCTAssertFalse(status.connected, "adb devices 里没有该 serial → 视为离线")
        XCTAssertEqual(status.summaryLine, "客厅 · 离线")
    }

    func testStatusDecodesSleepTimerAndMacroRunning() throws {
        let json = """
        {"cur_type":"appletv","current":"AA:BB","info":{},"devices":[],"recent":[],
         "appletv":{"available":true,"devices":[],"connected":true,"kb_focus":"Focused"},
         "sleep_timer":{"active":true,"until":123,"remaining":125},
         "macro":{"running":true},"version":"1.0"}
        """.data(using: .utf8)!
        let status = try XCTUnwrap(TVRemoteParser.status(from: json))
        XCTAssertTrue(status.sleepTimerActive)
        XCTAssertEqual(status.sleepTimerRemaining, 125)
        XCTAssertTrue(status.macroRunning)
        XCTAssertEqual(status.keyboardFocus, "Focused")
    }

    func testStatusWithoutDeviceReportsNoSelection() throws {
        let json = """
        {"cur_type":null,"current":null,"info":{},"devices":[],"recent":[],
         "appletv":{"available":true,"devices":[],"connected":false,"kb_focus":null},
         "sleep_timer":{"active":false,"until":null,"remaining":0},
         "macro":{"running":false},"version":"1.0"}
        """.data(using: .utf8)!
        let status = try XCTUnwrap(TVRemoteParser.status(from: json))
        XCTAssertFalse(status.hasDevice)
        XCTAssertEqual(status.summaryLine, "未选择设备")
    }

    func testStatusReturnsNilForGarbagePayload() {
        XCTAssertNil(TVRemoteParser.status(from: Data("<html>502</html>".utf8)))
        XCTAssertNil(TVRemoteParser.status(from: Data()))
    }

    func testUnreachableStatusSummary() {
        let status = TVRemoteParser.unreachableStatus()
        XCTAssertFalse(status.serviceReachable)
        XCTAssertEqual(status.summaryLine, "服务未连接")
    }

    // MARK: - 宏 / 应用解码

    func testPresetsDecodeWithStepsAndIcon() throws {
        let presets = TVRemoteParser.presets(from: macrosJSON)
        XCTAssertEqual(presets.count, 5)
        let movie = try XCTUnwrap(presets.first { $0.id == "movie" })
        XCTAssertEqual(movie.name, "观影模式")
        XCTAssertEqual(movie.steps.count, 3)
        XCTAssertEqual(movie.steps[0].effectiveType, "app")
        XCTAssertEqual(movie.steps[0].pkgs, ["com.netflix.ninja", "com.netflix.Netflix"])
        XCTAssertEqual(movie.steps[1].effectiveType, "delay")
        XCTAssertEqual(movie.steps[2].codes, [25, 25, 25])
        // 单数 code 写法的预设宏（「静音 / 取消」）也要能归一成 codes，
        // 否则转发回服务端时该步没有键码，会被 400「缺少键码」
        XCTAssertEqual(presets.first { $0.id == "mute" }?.steps.first?.codes, [164])
    }

    func testSingularCodeStepRoundTripsAsCodes() throws {
        let json = #"{"presets":[{"id":"home","icon":"x","name":"回主页","steps":[{"type":"key","code":3}]}]}"#
            .data(using: .utf8)!
        let preset = try XCTUnwrap(TVRemoteParser.presets(from: json).first)
        let object = try decodeObject(preset.steps[0])
        XCTAssertEqual(object["codes"] as? [Int], [3])
        XCTAssertNil(object["code"])
    }

    func testAppsDecodeIDAndName() throws {
        let json = """
        {"apps":[{"id":"com.apple.TVApp","name":"电视"},
                 {"id":"com.netflix.Netflix","name":"Netflix"}]}
        """.data(using: .utf8)!
        let apps = TVRemoteParser.apps(from: json)
        XCTAssertEqual(apps.count, 2)
        XCTAssertEqual(apps[0].id, "com.apple.TVApp")
        XCTAssertEqual(apps[1].displayName, "Netflix")
    }

    // MARK: - 错误提取

    /// 上游把业务错误放在 200 body 里；只判断 `error == nil` 会把「未连接电视」
    /// 当成成功，界面毫无反应。
    func testErrorExtractedFromSuccessfulHTTPResponse() throws {
        let json = #"{"error":"未连接 Apple TV：请在「Apple TV」页连接"}"#.data(using: .utf8)!
        let response = HTTPURLResponse(url: URL(string: "http://127.0.0.1:8300/api/cmd")!,
                                       statusCode: 200, httpVersion: nil, headerFields: nil)
        XCTAssertEqual(TVRemoteParser.errorMessage(data: json, response: response),
                       "未连接 Apple TV：请在「Apple TV」页连接")
    }

    func testNoErrorForSuccessfulBody() throws {
        let json = #"{"ok":true,"sent":[19]}"#.data(using: .utf8)!
        let response = HTTPURLResponse(url: URL(string: "http://127.0.0.1:8300/api/cmd")!,
                                       statusCode: 200, httpVersion: nil, headerFields: nil)
        XCTAssertNil(TVRemoteParser.errorMessage(data: json, response: response))
    }

    func testMissingRouteReportedAsVersionMismatch() throws {
        let response = HTTPURLResponse(url: URL(string: "http://127.0.0.1:8300/api/nope")!,
                                       statusCode: 404, httpVersion: nil, headerFields: nil)
        XCTAssertEqual(TVRemoteParser.errorMessage(data: Data(), response: response),
                       "服务没有该接口（可能是 ATV Remote 版本过旧）")
    }

    func testTransportMessagesAreActionable() {
        let cannotConnect = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)
        XCTAssertEqual(TVRemoteParser.transportMessage(for: cannotConnect),
                       "连不上 ATV Remote 服务（127.0.0.1:8300 未启动？）")
        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        XCTAssertEqual(TVRemoteParser.transportMessage(for: timeout),
                       "ATV Remote 服务响应超时")
        XCTAssertEqual(TVRemoteParser.transportMessage(for: nil), "未知错误")
    }

    // MARK: - 工具

    private func decodeObject<E: Encodable>(_ value: E) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "请求体应是扁平 JSON 对象"
        )
    }

    // MARK: - 真实样本（抓自 ~/atv-remote，2026-09-25）

    private let appleTVStatusJSON = """
    {"adb_found": true, "adb_path": "/opt/homebrew/bin/adb",
     "cur_type": "appletv", "current": "E2:1F:FE:54:26:83",
     "current_state": null, "info": {"brand": "Apple", "model": "主卧"},
     "devices": [], "recent": [],
     "appletv": {"available": true,
       "devices": [{"id": "E2:1F:FE:54:26:83", "name": "主卧", "ip": "192.168.1.100",
                    "proto": "companion", "companion_port": 49299, "airplay_port": 7000}],
       "connected": true, "kb_focus": "Unfocused"},
     "sleep_timer": {"active": false, "until": null, "remaining": 0},
     "macro": {"running": false}, "version": "1.0"}
    """.data(using: .utf8)!

    private let macrosJSON = """
    {"presets": [
      {"id": "movie", "icon": "🎬", "name": "观影模式",
       "steps": [{"type": "app", "pkgs": ["com.netflix.ninja", "com.netflix.Netflix"]},
                 {"delay": 2500},
                 {"type": "key", "codes": [25, 25, 25]}]},
      {"id": "youtube", "icon": "▶️", "name": "看 YouTube",
       "steps": [{"type": "app", "pkgs": ["com.google.android.youtube.tv", "com.google.ios.youtube"]},
                 {"delay": 2500}]},
      {"id": "mute", "icon": "🔇", "name": "静音 / 取消",
       "steps": [{"type": "key", "code": 164}]},
      {"id": "home", "icon": "🏠", "name": "回主页",
       "steps": [{"type": "key", "code": 3}]},
      {"id": "volume-down3", "icon": "🔉", "name": "音量降 3 格",
       "steps": [{"type": "key", "codes": [25, 25, 25]}]}]}
    """.data(using: .utf8)!
}
