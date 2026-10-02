import Foundation

/// 划词 AI 快驾的预设动作。固定集合（不做自定义 prompt），控制半径、便于单测。
struct AIAction: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let icon: String
    let systemPrompt: String

    static let builtins: [AIAction] = [
        AIAction(
            id: "translate",
            title: "翻译",
            icon: "character.book.closed.fill",
            systemPrompt: "你是专业翻译。将用户提供的文本翻译为中文；若原文已是中文，则翻译为英文。只输出译文本身，不要解释、不要加引号。"
        ),
        AIAction(
            id: "summarize",
            title: "总结",
            icon: "list.bullet.rectangle.fill",
            systemPrompt: "将用户提供的文本浓缩为不超过 5 条要点的有序列表，每条一行、以「- 」开头，中文输出。不要复述原文，不要多余解释。"
        ),
        AIAction(
            id: "explain",
            title: "解释",
            icon: "lightbulb.fill",
            systemPrompt: "用通俗易懂的中文解释这段文字在讲什么，3-5 句话，面向非专业读者。不要逐句翻译，不要多余客套。"
        ),
        AIAction(
            id: "polish",
            title: "改写",
            icon: "pencil.line",
            systemPrompt: "把用户提供的文字改写得更专业、简洁、通顺，保持原意与事实不变，中文输出。只输出改写后的文字，不要说明改了什么。"
        ),
    ]

    static func action(id: String) -> AIAction? {
        builtins.first { $0.id == id }
    }
}
