import XCTest
import Foundation
@testable import Lumi

/// 划词 AI 快驾的纯逻辑测试：端点规整 / 请求体 / SSE 解析 / 设置持久化。
final class AIAssistSettingsTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        defaults = UserDefaults(suiteName: "AIAssistTests.\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let defaults { defaults.removePersistentDomain(forName: defaults.description) }
        defaults = nil
    }

    private let action = AIAction.action(id: "translate")!

    // MARK: - 端点规整

    func testChatCompletionsURLVariants() {
        func url(_ s: String) -> String? {
            var settings = AIAssistSettings()
            settings.endpoint = s
            return settings.chatCompletionsURL()?.absoluteString
        }
        XCTAssertEqual(url("http://127.0.0.1:4002"), "http://127.0.0.1:4002/v1/chat/completions")
        XCTAssertEqual(url("http://127.0.0.1:4002/"), "http://127.0.0.1:4002/v1/chat/completions")
        XCTAssertEqual(url("http://127.0.0.1:4002/v1"), "http://127.0.0.1:4002/v1/chat/completions")
        XCTAssertEqual(url("https://api.example.com/v1/chat/completions"), "https://api.example.com/v1/chat/completions")
        XCTAssertNil(url(""))
        XCTAssertNil(url("   "))
    }

    // MARK: - 不做字数截断（用户要求：复制的整段原文直送）

    func testShortTextPassesThrough() throws {
        var settings = AIAssistSettings()
        settings.model = "m"
        let body = try JSONObject(settings.buildRequestBody(action: action, text: "短文本"))
        XCTAssertEqual(lastUserMessage(body), "短文本")
    }

    func testLongTextNotTruncated() throws {
        var settings = AIAssistSettings()
        settings.model = "m"
        let long = String(repeating: "a", count: 10_000)
        let body = try JSONObject(settings.buildRequestBody(action: action, text: long))
        let sent = lastUserMessage(body) ?? ""
        // 必须一字不改地原样发送，不得出现截断提示
        XCTAssertEqual(sent, long)
        XCTAssertEqual(sent.count, 10_000)
        XCTAssertFalse(sent.contains("已截断"))
    }

    /// 取 JSON 里最后一条 user 消息，附带可读失败信息。
    private func lastUserMessage(_ json: [String: Any]) -> String? {
        guard let messages = json["messages"] as? [[String: Any]] else { return nil }
        return messages.last(where: { $0["role"] as? String == "user" })?["content"] as? String
    }

    private func JSONObject(_ data: Data?) throws -> [String: Any] {
        guard let data = data else {
            XCTFail("body nil")
            return [:]
        }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    // MARK: - 请求体

    func testRequestBodyShape() throws {
        var settings = AIAssistSettings()
        settings.model = "test-model"
        guard let data = settings.buildRequestBody(action: action, text: "hello") else {
            return XCTFail("body nil")
        }
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["model"] as? String, "test-model")
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["max_tokens"] as? Int, AIAssistSettings.maxOutputTokens)
        let messages = json["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.count, 2)
        XCTAssertEqual(messages?.first?["role"] as? String, "system")
        XCTAssertEqual(messages?.first?["content"] as? String, action.systemPrompt)
        XCTAssertEqual(messages?.last?["role"] as? String, "user")
        XCTAssertEqual(messages?.last?["content"] as? String, "hello")
    }

    // MARK: - 连接检测请求体

    func testProbeBodyShape() throws {
        var settings = AIAssistSettings()
        settings.model = "test-model"
        guard let data = settings.buildProbeBody() else {
            return XCTFail("probe body nil")
        }
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["model"] as? String, "test-model")
        // 检测必须非流式且请求极小，否则会消耗用户额度
        XCTAssertEqual(json["stream"] as? Bool, false)
        XCTAssertEqual(json["max_tokens"] as? Int, 64)
        let messages = json["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.count, 1)
        XCTAssertEqual(messages?.first?["role"] as? String, "user")
    }

    func testLocalRelayEndpointResolves() {
        // 一键填入的本机中继必须能规整出合法 chat/completions 地址
        var settings = AIAssistSettings()
        settings.endpoint = AIAssistSettings.localRelayEndpoint
        settings.model = "m"
        XCTAssertEqual(settings.chatCompletionsURL()?.absoluteString,
                       "http://127.0.0.1:15721/v1/chat/completions")
        XCTAssertTrue(settings.isConfigured)
    }

    // MARK: - SSE 解析

    func testSSENormalDelta() {
        let line = #"data: {"choices":[{"delta":{"content":"你好"}}]}"#
        XCTAssertEqual(OpenAIStreamParser.deltaText(fromLine: line), "你好")
    }

    func testSSEMultipleFramesAndDone() {
        let frames = [
            #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#,      // 无 content
            #"data: {"choices":[{"delta":{"content":"第一"}}]}"#,
            #"data: {"choices":[{"delta":{"content":"段"}}]}"#,
            "data: [DONE]",
        ]
        var out = ""
        for f in frames {
            if let d = OpenAIStreamParser.deltaText(fromLine: f) { out += d }
        }
        XCTAssertEqual(out, "第一段")
    }

    func testSSEEdgeCases() {
        XCTAssertNil(OpenAIStreamParser.deltaText(fromLine: ""))
        XCTAssertNil(OpenAIStreamParser.deltaText(fromLine: "   "))
        XCTAssertNil(OpenAIStreamParser.deltaText(fromLine: "data: [DONE]"))
        XCTAssertNil(OpenAIStreamParser.deltaText(fromLine: "data:"))
        XCTAssertNil(OpenAIStreamParser.deltaText(fromLine: "not json at all"))
        // content 为 null（部分实现的 role 首发帧）
        XCTAssertNil(OpenAIStreamParser.deltaText(fromLine: #"data: {"choices":[{"delta":{"content":null}}]}"#))
        // 空 content 是合法增量
        XCTAssertEqual(OpenAIStreamParser.deltaText(fromLine: #"data: {"choices":[{"delta":{"content":""}}]}"#), "")
    }

    func testNonStreamFallback() {
        let json = #"{"choices":[{"message":{"content":"非流式结果"}}]}"#
        XCTAssertEqual(OpenAIStreamParser.messageText(fromJSON: json), "非流式结果")
        XCTAssertNil(OpenAIStreamParser.messageText(fromJSON: "garbage"))
    }

    // MARK: - 设置持久化

    func testSettingsDefaults() {
        let settings = AIAssistSettings.load(from: defaults)
        XCTAssertFalse(settings.watchClipboard)   // 隐私：默认不监听剪贴板
        XCTAssertTrue(settings.endpoint.isEmpty)
        XCTAssertTrue(settings.model.isEmpty)
        XCTAssertFalse(settings.isConfigured)
    }

    func testSettingsRoundTrip() {
        var settings = AIAssistSettings.load(from: defaults)
        settings.watchClipboard = true
        settings.endpoint = "http://127.0.0.1:4002"
        settings.model = "local-model"
        settings.save(to: defaults)
        XCTAssertEqual(AIAssistSettings.load(from: defaults), settings)
        XCTAssertTrue(settings.isConfigured)
    }

    func testConfiguredRequiresEndpointAndModel() {
        var settings = AIAssistSettings.load(from: defaults)
        settings.endpoint = "http://127.0.0.1:4002"
        XCTAssertFalse(settings.isConfigured)   // 有端点没模型
        settings.model = "m"
        XCTAssertTrue(settings.isConfigured)
    }

    // MARK: - 错误文案

    func testFriendlyError() {
        let connectErr = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)
        XCTAssertTrue(AIAssistController.friendlyError(connectErr).contains("连不上端点"))
        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        XCTAssertEqual(AIAssistController.friendlyError(timeout), "请求超时，请重试")
    }
}
