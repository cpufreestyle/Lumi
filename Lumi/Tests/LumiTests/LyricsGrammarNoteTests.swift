import XCTest
@testable import Lumi

/// 歌词语法注解的 prompt 构造与响应解析测试（Foundation only，符合 LumiTests 约束）。
///
/// 复刻 Musixmatch 语言学习付费档。解析逻辑必须容忍：AI 返回带 Markdown 代码块、
/// AI 返回单个对象而非数组、keyPhrase/example 缺失、point 为空白等真实世界抖动。
final class LyricsGrammarNoteTests: XCTestCase {

    // MARK: - Prompt 构造

    func testSystemPromptContainsLyricLine() {
        let prompt = LyricsGrammarNote.systemPrompt(for: "I have been waiting")
        XCTAssertTrue(prompt.contains("I have been waiting"))
        XCTAssertTrue(prompt.contains("JSON"))
    }

    func testSystemPromptTrimsWhitespace() {
        let prompt = LyricsGrammarNote.systemPrompt(for: "   hello world   ")
        XCTAssertTrue(prompt.contains("hello world"))
        XCTAssertFalse(prompt.contains("   hello"))
    }

    // MARK: - Markdown 剥壳

    func testStripMarkdownFenceRemovesJsonWrapper() {
        let raw = "```json\n[{\"point\":\"test\"}]\n```"
        let cleaned = LyricsGrammarNote.stripMarkdownFence(raw)
        XCTAssertFalse(cleaned.contains("```"))
        XCTAssertTrue(cleaned.contains("\"point\""))
    }

    func testStripMarkdownFenceHandlesNoFence() {
        let raw = "[{\"point\":\"test\"}]"
        XCTAssertEqual(LyricsGrammarNote.stripMarkdownFence(raw), raw)
    }

    // MARK: - 响应解析

    func testParseArrayResponse() {
        let raw = """
        [
          {"point":"现在完成时表示对现在的影响","keyPhrase":"have been","example":"I have been there"},
          {"point":"waiting 是现在分词作状语"}
        ]
        """
        let notes = LyricsGrammarNote.parseResponse(raw)
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes[0].point, "现在完成时表示对现在的影响")
        XCTAssertEqual(notes[0].keyPhrase, "have been")
        XCTAssertEqual(notes[0].example, "I have been there")
        XCTAssertNil(notes[1].keyPhrase)
    }

    func testParseSingleObjectResponse() {
        // AI 有时不守指令返回单个对象；容忍并包装成单元素数组。
        let raw = "{\"point\":\"一般过去时\"}"
        let notes = LyricsGrammarNote.parseResponse(raw)
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].point, "一般过去时")
    }

    func testParseResponseStripsMarkdownFence() {
        let raw = "```json\n[{\"point\":\"test\"}]\n```"
        let notes = LyricsGrammarNote.parseResponse(raw)
        XCTAssertEqual(notes.count, 1)
    }

    func testParseResponseSkipsEntriesWithoutPoint() {
        let raw = """
        [
          {"point":"  ", "keyPhrase":"x"},
          {"keyPhrase":"orphan"},
          {"point":"valid"}
        ]
        """
        let notes = LyricsGrammarNote.parseResponse(raw)
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].point, "valid")
    }

    func testParseResponseEmptyReturnsEmptyArray() {
        XCTAssertEqual(LyricsGrammarNote.parseResponse(""), [])
        XCTAssertEqual(LyricsGrammarNote.parseResponse("   "), [])
    }

    func testParseResponseInvalidJsonReturnsEmptyArray() {
        XCTAssertEqual(LyricsGrammarNote.parseResponse("not json at all"), [])
        XCTAssertEqual(LyricsGrammarNote.parseResponse("[{broken"), [])
    }

    func testParseResponseNormalizesEmptyKeyPhraseToNil() {
        let raw = "[{\"point\":\"p\",\"keyPhrase\":\"  \",\"example\":\"\"}]"
        let notes = LyricsGrammarNote.parseResponse(raw)
        XCTAssertEqual(notes.count, 1)
        XCTAssertNil(notes[0].keyPhrase)
        XCTAssertNil(notes[0].example)
    }
}
