import Foundation

/// 听写后处理：把 whisper-cli 的原始转写交给本机 Ollama 润色（去口癖 / 书面化 / 要点化 / 自定义）。
///
/// 「调用」而非「重写」（与 whisper.cpp 集成同一原则）：Ollama（github.com/ollama/ollama）
/// 的 HTTP `/api/generate` 接口朝上复用——模型下载、量化、Metal 推理全由 Ollama 负责，
/// Lumi 只拼请求、读 `response` 字段。全程只走 `127.0.0.1:11434`，文本不出本机。
///
/// 失败哲学：任何一步失败（Ollama 没起、超时、返回不可解析）都静默回退原文，
/// 润色永远只是「增强」，绝不允许它弄丢转写结果或阻塞剪贴板流程。
enum DictationPolish {
    /// 本机默认监听地址（与 `OllamaProvider.defaultHost` 一致）。
    static let defaultHost = "http://127.0.0.1:11434"
    /// `/api/generate` 全址（原生非 OpenAI 兼容接口：单 prompt、非流式即完整 JSON）。
    static var generateURL: URL? { URL(string: defaultHost + "/api/generate") }
    /// 单次润色超时（秒）。本地小模型首字通常 <2s；超时即回退原文。
    static let timeoutSeconds: TimeInterval = 10
    /// 输出上限（token）。转写一般几十到几百字，留足余量即可，防模型发散写长文。
    static let maxOutputTokens = 1024
    /// 输入截断（字符）。超长转写（粘贴的整段文字）润色性价比低，直接原文。
    static let maxInputChars = 4000

    /// 润色档位。系统提示词即产品行为定义（纯数据，可单测）。
    enum Preset: String, CaseIterable, Identifiable {
        case cleanup = "cleanup"
        case formal = "formal"
        case bullets = "bullets"
        case custom = "custom"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .cleanup: return "去口癖加标点"
            case .formal: return "书面化整理"
            case .bullets: return "要点化"
            case .custom: return "自定义"
            }
        }

        /// 一句话说明（面板 hint 用）。
        var hint: String {
            switch self {
            case .cleanup: return "删口水词、补标点，保留口语感"
            case .formal: return "改写成通顺书面语，信息不丢"
            case .bullets: return "提炼为要点列表，一行一条"
            case .custom: return "按你自己的指令处理"
            }
        }

        /// 系统提示词（拼进 prompt 头部）。custom 档运行时被用户指令替换。
        var systemPrompt: String {
            switch self {
            case .cleanup:
                return "你是语音转写润色助手。用户会给你一段语音识别文本。请在不改变原意和信息的前提下：删除语气词和口癖（嗯、啊、呃、那个、就是说），补充标点符号，修正明显的同音错别字。保持口语自然度，不要改写措辞，不要添加原文没有的内容。不要任何解释，直接输出处理后的文本。"
            case .formal:
                return "你是文字整理助手。用户会给你一段语音识别文本。请改写成通顺的书面语：去除口语和语气词，理顺句子结构，保留全部信息点。不要添加原文没有的信息。不要任何解释，直接输出整理后的文本。"
            case .bullets:
                return "你是要点提炼助手。用户会给你一段语音识别文本。请提炼为简洁要点列表：每条一个要点、一行一条，用「- 」开头，保留关键信息，合并重复内容。不要输出列表以外的任何文字。"
            case .custom:
                return "你是语音转写处理助手。用户会通过指令描述处理要求并给你一段语音识别文本，请严格按指令处理。不要解释处理过程，直接输出结果。"
            }
        }
    }

    // MARK: - 请求构造

    /// 构造 `/api/generate` 请求体（非流式：`stream:false` 让 Ollama 一次性返回完整 JSON）。
    /// custom 档且用户指令非空时，用用户指令整体替换系统提示词；指令为空回落档位默认提示词。
    static func buildRequest(model: String, text: String, preset: Preset, customInstruction: String) -> [String: Any] {
        var system = preset.systemPrompt
        if preset == .custom {
            let instruction = customInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
            if !instruction.isEmpty {
                system = instruction + "。不要任何解释，直接输出结果。"
            } else {
                // 自定义档但没写指令：退回去口癖档的行为，好过拿空指令瞎跑
                system = Preset.cleanup.systemPrompt
            }
        }
        let prompt = system + "\n\n待处理文本：\n" + text
        return [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "keep_alive": "5m",
            "options": [
                "temperature": 0.2,
                "num_predict": maxOutputTokens
            ]
        ]
    }

    // MARK: - 响应解析

    /// 解析 `/api/generate` 非流式返回：取 `response` 字段并清洗。
    /// 结构不对 / 字段缺失 / 内容为空 → 返回 nil（调用方据此回退原文）。
    static func parseResponse(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"] as? String
        else { return nil }
        let cleaned = sanitize(response)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// 清洗模型输出：去首尾空白；剥掉模型偶发整体套上的成对引号；压掉 3+ 连续换行。
    static func sanitize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pairs: [(Character, Character)] = [("\"", "\""), ("\u{201C}", "\u{201D}"), ("\u{300C}", "\u{300D}")]
        if text.count >= 2 {
            for (open, close) in pairs where text.first == open && text.last == close {
                text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        while text.contains("\n\n\n") {
            text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return text
    }

    // MARK: - 策略

    /// 是否值得跑润色（纯策略，可单测）。四缺一即回退原文：开关没开 / 环境不就绪 /
    /// 文本为空 / 文本超长（性价比低且可能挤爆模型上下文）。
    static func shouldPolish(enabled: Bool, environmentReady: Bool, transcript: String) -> Bool {
        guard enabled, environmentReady else { return false }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= maxInputChars
    }
}
