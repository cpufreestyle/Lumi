import XCTest
import Foundation
@testable import Lumi

/// 端点错误 → 中文可操作提示的翻译测试。
final class AIAssistErrorTranslatorTests: XCTestCase {

    func testStepFunQuotaError() {
        // 本机真实样本（StepFun quota_exceeded）
        let body = #"{"error":{"message":"You exceeded your current quota, please check your plan and billing details","type":"quota_exceeded"}}"#
        let msg = AIAssistErrorTranslator.friendlyMessage(statusCode: 400, body: body)
        XCTAssertTrue(msg.contains("额度不足"), msg)
        XCTAssertTrue(msg.contains("充值"), msg)
        XCTAssertFalse(msg.contains("HTTP"), msg)  // 已知错误不裸露状态码
    }

    func testOpenAIInsufficientQuota() {
        let body = #"{"error":{"message":"You exceeded your current quota","type":"insufficient_quota","code":"insufficient_quota"}}"#
        XCTAssertTrue(AIAssistErrorTranslator.friendlyMessage(statusCode: 429, body: body).contains("额度不足"))
    }

    func testInvalidAPIKey() {
        let body = #"{"error":{"message":"Incorrect API key provided","type":"invalid_api_key"}}"#
        XCTAssertTrue(AIAssistErrorTranslator.friendlyMessage(statusCode: 401, body: body).contains("API Key"))
    }

    func testModelNotFound() {
        let body = #"{"error":{"message":"The model `x-1` does not exist","type":"invalid_request_error","code":"model_not_found"}}"#
        XCTAssertTrue(AIAssistErrorTranslator.friendlyMessage(statusCode: 400, body: body).contains("模型不存在"))
    }

    func testRateLimit() {
        let body = #"{"error":{"message":"Rate limit reached for gpt","type":"requests","code":"rate_limit_exceeded"}}"#
        XCTAssertTrue(AIAssistErrorTranslator.friendlyMessage(statusCode: 429, body: body).contains("频繁"))
        // 无错误体的 429 也应识别为限流
        XCTAssertTrue(AIAssistErrorTranslator.friendlyMessage(statusCode: 429, body: nil).contains("频繁"))
    }

    func testContextLengthExceeded() {
        let body = #"{"error":{"message":"This model's maximum context length is 8192 tokens","type":"invalid_request_error"}}"#
        XCTAssertTrue(AIAssistErrorTranslator.friendlyMessage(statusCode: 400, body: body).contains("上下文"))
    }

    func testNotFoundAndAuthStatusCodes() {
        XCTAssertTrue(AIAssistErrorTranslator.friendlyMessage(statusCode: 404, body: "not found").contains("端点不存在"))
        XCTAssertTrue(AIAssistErrorTranslator.friendlyMessage(statusCode: 401, body: "").contains("API Key"))
    }

    func testUnknownErrorFallsBackToMessageOrBody() {
        let withJSON = #"{"error":{"message":"Something odd happened","type":"server_error"}}"#
        XCTAssertTrue(AIAssistErrorTranslator.friendlyMessage(statusCode: 503, body: withJSON).contains("Something odd"))
        let nonJSON = "Bad Gateway"
        XCTAssertTrue(AIAssistErrorTranslator.friendlyMessage(statusCode: 502, body: nonJSON).contains("Bad Gateway"))
        XCTAssertEqual(AIAssistErrorTranslator.friendlyMessage(statusCode: 500, body: nil), "服务端错误（HTTP 500）")
    }

    func testExtractors() {
        let body = #"{"error":{"message":"m","type":"t"}}"#
        XCTAssertEqual(AIAssistErrorTranslator.extractMessage(from: body), "m")
        XCTAssertEqual(AIAssistErrorTranslator.extractType(from: body), "t")
        XCTAssertNil(AIAssistErrorTranslator.extractMessage(from: "not json"))
        XCTAssertNil(AIAssistErrorTranslator.extractType(from: ""))
    }
}
