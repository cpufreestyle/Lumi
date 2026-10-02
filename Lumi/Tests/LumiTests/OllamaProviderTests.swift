import XCTest
import Foundation
@testable import Lumi

/// 本机 Ollama 探测的纯逻辑测试：/api/tags 与 /v1/models 解析、模型筛选、规格度量。
/// 样本取自本机 curl -s http://127.0.0.1:11434/api/tags 的真实返回结构。
final class OllamaProviderTests: XCTestCase {

    private let tagsJSON = #"""
    {
      "models": [
        {
          "name": "llama3.2-vision:latest",
          "size": 7816589186,
          "details": { "family": "mllama", "parameter_size": "10.7B", "quantization_level": "Q4_K_M" },
          "capabilities": ["tools", "completion", "vision"]
        },
        {
          "name": "gemma4:latest",
          "size": 9608350718,
          "details": { "family": "gemma4", "parameter_size": "8.0B", "quantization_level": "Q4_K_M" },
          "capabilities": ["completion", "vision", "audio", "tools", "thinking"]
        },
        {
          "name": "Qwen3.5-4B:latest",
          "size": 2740938334,
          "details": { "family": "qwen35", "parameter_size": "4.2B", "quantization_level": "Q4_K_M" },
          "capabilities": ["completion", "tools", "thinking"]
        },
        {
          "name": "nomic-embed-text:latest",
          "size": 274302450,
          "details": { "family": "nomic-bert", "parameter_size": "137M", "quantization_level": "F16" },
          "capabilities": ["embedding"]
        }
      ]
    }
    """#

    // MARK: - /api/tags 解析

    func testParseTagsExtractsAllModels() {
        let models = OllamaProvider.parseTags(tagsJSON)
        XCTAssertEqual(models.map(\.name), [
            "llama3.2-vision:latest",
            "gemma4:latest",
            "Qwen3.5-4B:latest",
            "nomic-embed-text:latest",
        ])
    }

    func testParseTagsFieldMapping() {
        let models = OllamaProvider.parseTags(tagsJSON)
        let llama = models.first { $0.name == "llama3.2-vision:latest" }
        XCTAssertEqual(llama?.sizeBytes, 7816589186)
        XCTAssertEqual(llama?.parameterSize, "10.7B")
        XCTAssertEqual(llama?.family, "mllama")
        XCTAssertTrue(llama?.capabilities.contains("vision") == true)

        let embed = models.first { $0.name == "nomic-embed-text:latest" }
        XCTAssertEqual(embed?.sizeBytes, 274302450)
        XCTAssertEqual(embed?.parameterSize, "137M")
    }

    func testParseTagsRobustness() {
        XCTAssertTrue(OllamaProvider.parseTags("").isEmpty)
        XCTAssertTrue(OllamaProvider.parseTags("not json at all").isEmpty)
        XCTAssertTrue(OllamaProvider.parseTags("{}").isEmpty)
        XCTAssertTrue(OllamaProvider.parseTags(#"{"models":[]}"#).isEmpty)
    }

    func testParseTagsSkipsEmptyNameAndToleratesFloatSize() {
        let json = #"{"models":[{"name":"","size":1},{"name":"m","size":123.0,"capabilities":["completion"]}]}"#
        let models = OllamaProvider.parseTags(json)
        XCTAssertEqual(models.map(\.name), ["m"])
        XCTAssertEqual(models[0].sizeBytes, 123)
    }

    // MARK: - /v1/models 解析

    func testParseOpenAIModelsNamesOnly() {
        let json = #"{"object":"list","data":[{"id":"llama3.2-vision:latest","object":"model"},{"id":"nomic-embed-text:latest","object":"model"}]}"#
        let models = OllamaProvider.parseOpenAIModels(json)
        XCTAssertEqual(models.map(\.name), ["llama3.2-vision:latest", "nomic-embed-text:latest"])
        for m in models {
            XCTAssertNil(m.sizeBytes)
            XCTAssertNil(m.parameterSize)
            XCTAssertNil(m.family)
            XCTAssertTrue(m.capabilities.isEmpty)
        }
        XCTAssertTrue(models[0].isChatCapable)
        XCTAssertFalse(models[1].isChatCapable)
    }

    // MARK: - 选择

    func testRecommendedChatModelIsLargestChatCapable() {
        let models = OllamaProvider.parseTags(tagsJSON)
        let chosen = OllamaProvider.recommendedChatModel(from: models)
        XCTAssertEqual(chosen?.name, "llama3.2-vision:latest")
        XCTAssertNotEqual(chosen?.name, "gemma4:latest")
    }

    func testEmbeddingOnlyReturnsNil() {
        let models = OllamaProvider.parseTags(tagsJSON)
        let embedOnly = models.filter { !$0.isChatCapable }
        XCTAssertFalse(embedOnly.isEmpty)
        XCTAssertNil(OllamaProvider.recommendedChatModel(from: embedOnly))
    }

    // MARK: - 规格度量

    func testParseParameterSize() {
        XCTAssertEqual(OllamaProvider.parseParameterSize("10.7B") ?? 0, 10.7, accuracy: 0.001)
        XCTAssertEqual(OllamaProvider.parseParameterSize("8.0B") ?? 0, 8.0, accuracy: 0.001)
        XCTAssertEqual(OllamaProvider.parseParameterSize("4.2B") ?? 0, 4.2, accuracy: 0.001)
        XCTAssertEqual(OllamaProvider.parseParameterSize("137M") ?? 0, 0.137, accuracy: 0.0001)
        XCTAssertEqual(OllamaProvider.parseParameterSize("137m") ?? 0, 0.137, accuracy: 0.0001)
        XCTAssertNil(OllamaProvider.parseParameterSize(""))
        XCTAssertNil(OllamaProvider.parseParameterSize("abc"))
    }

    func testScalePrefersParameterThenFallsBackToSize() {
        XCTAssertEqual(OllamaProvider.scale(OllamaProvider.Model(name: "m", parameterSize: "8B")), 8.0, accuracy: 0.001)
        XCTAssertEqual(OllamaProvider.scale(OllamaProvider.Model(name: "m", sizeBytes: 5_000_000_000)), 5.0, accuracy: 0.001)
        XCTAssertEqual(OllamaProvider.scale(OllamaProvider.Model(name: "m")), 0.0, accuracy: 0.0001)
    }

    func testFormatBytes() {
        XCTAssertTrue(OllamaProvider.formatBytes(7816589186).contains("GB"))
        XCTAssertTrue(OllamaProvider.formatBytes(274302450).contains("MB"))
        XCTAssertTrue(OllamaProvider.formatBytes(512).contains("B"))
        XCTAssertFalse(OllamaProvider.formatBytes(512).contains("GB"))
    }

    // MARK: - 展示与身份

    func testSubtitleSkipsMissingFields() {
        XCTAssertEqual(OllamaProvider.Model(name: "m").subtitle, "")
        let models = OllamaProvider.parseTags(tagsJSON)
        let llama = models.first { $0.name.hasPrefix("llama") }!
        XCTAssertEqual(llama.subtitle, "10.7B · 7.8 GB · 视觉")
        let qwen = models.first { $0.name.hasPrefix("Qwen") }!
        XCTAssertEqual(qwen.subtitle, "4.2B · 2.7 GB")
    }

    func testVisionCapability() {
        let models = OllamaProvider.parseTags(tagsJSON)
        XCTAssertTrue(models.first { $0.name.hasPrefix("llama") }!.isVisionCapable)
        XCTAssertFalse(models.first { $0.name.hasPrefix("Qwen") }!.isVisionCapable)
    }

    func testModelIdentityAndEquatable() {
        let a = OllamaProvider.Model(name: "x", sizeBytes: 1)
        let b = OllamaProvider.Model(name: "x", sizeBytes: 1)
        let c = OllamaProvider.Model(name: "y", sizeBytes: 1)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(a.id, "x")
    }
}
