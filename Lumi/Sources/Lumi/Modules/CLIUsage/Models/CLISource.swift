import Foundation

/// 本地 AI CLI 日志来源。全部本机解析，不联网、不上报。
enum CLISource: String, CaseIterable, Sendable, Codable {
    case codex = "Codex"
    case claudeCode = "Claude Code"

    var logPathHint: String {
        switch self {
        case .codex:      return "~/.codex/sessions"
        case .claudeCode: return "~/.claude/projects"
        }
    }
}
