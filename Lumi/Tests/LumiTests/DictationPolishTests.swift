import XCTest
import Foundation
@testable import Lumi

/// 听写后处理（whisper.cpp 转写 → 本机 Ollama 润色）的纯逻辑测试：
/// 请求构造（prompt 拼装 / 非流式 / 低温低发散）、响应解析、输出清洗、润色策略矩阵。
/// 全部不触网、不起进程——GUI 与网络边界在 Controllers 侧，测试目标只锁纯逻辑。
final class DictationPolishTests: XCTestCase {

    // MARK: - 请求构造

    func testBuildRequest_basicShape() {
        let body = DictationPolish.buildRequest(
            model: "qwen3:8b",
            text: "嗯那个今天天气不错啊",
            preset: .cleanup,
            customInstruction: ""
        )
        XCTAssertEqual(body["model"] as? String, "qwen3:8b")
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual(body["keep_alive"] as? String, "5m")
        let options = body["options"] as? [String: Any]
        XCTAssertEqual(options?["temperature"] as? Double, 0.2)
        XCTAssertEqual(options?["num_predict"] as? Int, DictationPolish.maxOutputTokens)
        let prompt = body["prompt"] as? String ?? ""
        XCTAssertTrue(prompt.contains(DictationPolish.Preset.cleanup.systemPrompt))
        XCTAssertTrue(prompt.contains("\u{5f85}\u{5904}\u{7406}\u{6587}\u{672c}\u{ff1a}"))
        XCTAssertTrue(prompt.contains("\u{55ef}"))
        // 请求体必须可 JSON 序列化（否则 URLSession 发不出去）
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: body))
    }

    func testBuildRequest_customUsesInstruction() {
        let body = DictationPolish.buildRequest(
            model: "gemma4",
            text: "随便说点什么",
            preset: .custom,
            customInstruction: " 全部翻译成英语 "
        )
        let prompt = body["prompt"] as? String ?? ""
        XCTAssertTrue(prompt.contains("\u{5168}\u{90e8}\u{7ffb}\u{8bd1}\u{6210}\u{82f1}\u{8bed}"), "自定义指令应进入 prompt")
        XCTAssertFalse(prompt.contains(DictationPolish.Preset.cleanup.systemPrompt),
                       "自定义档有指令时不应回落默认提示词")
    }

    func testBuildRequest_customEmptyInstructionFallsBackToCleanup() {
        let body = DictationPolish.buildRequest(
            model: "gemma4",
            text: "测试",
            preset: .custom,
            customInstruction: "   \n "
        )
        let prompt = body["prompt"] as? String ?? ""
        XCTAssertTrue(prompt.contains(DictationPolish.Preset.cleanup.systemPrompt),
                      "自定义档指令为空时应退回去口癖档提示词，好过空指令")
    }

    // MARK: - 响应解析与清洗

    func testParseResponse_valid() {
        let json = """
        {"model":"qwen3","response":"今天天气不错。","done":true}
        """
        XCTAssertEqual(DictationPolish.parseResponse(json), "\u{4eca}\u{5929}\u{5929}\u{6c14}\u{4e0d}\u{9519}\u{3002}")
    }

    func testParseResponse_missingResponseField() {
        let json = """
        {"model":"qwen3","done":true}
        """
        XCTAssertNil(DictationPolish.parseResponse(json))
    }

    func testParseResponse_garbage() {
        XCTAssertNil(DictationPolish.parseResponse("not json at all"))
        XCTAssertNil(DictationPolish.parseResponse(""))
    }

    func testParseResponse_emptyResponse() {
        let json = """
        {"response":"   \n "}
        """
        XCTAssertNil(DictationPolish.parseResponse(json), "清洗后为空应判失败，调用方据此回退原文")
    }

    func testParseResponse_stripsWrappedQuotes() {
        let json = """
        {"response":"\\"已经润色好了\\""}
        """
        XCTAssertEqual(DictationPolish.parseResponse(json), "\u{5df2}\u{7ecf}\u{6da6}\u{8272}\u{597d}\u{4e86}")
    }

    func testSanitize_straightQuotePair() {
        XCTAssertEqual(DictationPolish.sanitize("\"\""), "")
        XCTAssertEqual(DictationPolish.sanitize("\"\u{4f60}\u{597d}\""), "\u{4f60}\u{597d}")
    }

    func testSanitize_curlyQuotePair() {
        XCTAssertEqual(DictationPolish.sanitize("\u{201C}\u{4f60}\u{597d}\u{201D}"), "\u{4f60}\u{597d}")
        XCTAssertEqual(DictationPolish.sanitize("\u{300C}\u{4f60}\u{597d}\u{300D}"), "\u{4f60}\u{597d}")
    }

    func testSanitize_collapsesExcessiveNewlines() {
        let raw = "\u{7b2c}\u{4e00}\u{6761}\n\n\n\n\u{7b2c}\u{4e8c}\u{6761}"
        XCTAssertEqual(DictationPolish.sanitize(raw), "\u{7b2c}\u{4e00}\u{6761}\n\n\u{7b2c}\u{4e8c}\u{6761}")
    }

    func testSanitize_trimsWhitespace() {
        XCTAssertEqual(DictationPolish.sanitize("  \n \u{6587}\u{672c} \n "), "\u{6587}\u{672c}")
    }

    func testSanitize_unpairedQuoteKept() {
        // 引号不在首尾成对出现时不能剥，否则会吃掉内容
        XCTAssertEqual(DictationPolish.sanitize("\u{4ed6}\u{8bf4}\"\u{4f60}\u{597d}\"\u{7136}\u{540e}\u{8d70}\u{4e86}"),
                       "\u{4ed6}\u{8bf4}\"\u{4f60}\u{597d}\"\u{7136}\u{540e}\u{8d70}\u{4e86}")
    }

    // MARK: - 策略矩阵

    func testShouldPolish_matrix() {
        XCTAssertFalse(DictationPolish.shouldPolish(enabled: false, environmentReady: true, transcript: "\u{6587}\u{672c}"))
        XCTAssertFalse(DictationPolish.shouldPolish(enabled: true, environmentReady: false, transcript: "\u{6587}\u{672c}"))
        XCTAssertFalse(DictationPolish.shouldPolish(enabled: true, environmentReady: true, transcript: ""))
        XCTAssertFalse(DictationPolish.shouldPolish(enabled: true, environmentReady: true, transcript: "   \n  "))
        XCTAssertTrue(DictationPolish.shouldPolish(enabled: true, environmentReady: true, transcript: "\u{4f60}\u{597d}"))
    }

    func testShouldPolish_inputLengthBoundary() {
        let atLimit = String(repeating: "\u{5b57}", count: DictationPolish.maxInputChars)
        let overLimit = String(repeating: "\u{5b57}", count: DictationPolish.maxInputChars + 1)
        XCTAssertTrue(DictationPolish.shouldPolish(enabled: true, environmentReady: true, transcript: atLimit))
        XCTAssertFalse(DictationPolish.shouldPolish(enabled: true, environmentReady: true, transcript: overLimit))
    }

    // MARK: - 档位元数据

    func testPreset_metadataComplete() {
        XCTAssertEqual(DictationPolish.Preset.allCases.count, 4)
        for preset in DictationPolish.Preset.allCases {
            XCTAssertFalse(preset.label.isEmpty, preset.rawValue)
            XCTAssertFalse(preset.hint.isEmpty, preset.rawValue)
            XCTAssertFalse(preset.systemPrompt.isEmpty, preset.rawValue)
        }
        // rawValue 唯一（UserDefaults 持久化键，撞车即串档）
        let ids = Set(DictationPolish.Preset.allCases.map(\.rawValue))
        XCTAssertEqual(ids.count, DictationPolish.Preset.allCases.count)
    }

    func testGenerateURL() {
        XCTAssertEqual(DictationPolish.generateURL?.absoluteString,
                       "http://127.0.0.1:11434/api/generate")
    }
}
