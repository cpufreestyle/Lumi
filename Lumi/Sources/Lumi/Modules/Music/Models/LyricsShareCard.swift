import Foundation

/// 歌词分享卡片的数据模型与文本格式化（纯逻辑，Foundation only，可进 LumiTests）。
///
/// 复刻自 Musixmatch / Apple Music 的付费功能「歌词分享卡片」：把当前播放行的
/// 原文 / 译文 / 歌名 / 歌手 / 封面色组合成一张可分享的图片。本类型只负责
/// 「数据怎么组织、文本怎么截断」，不做图像渲染（渲染在 SwiftUI 侧 ImageRenderer）。
///
/// 纯逻辑放这里的原因：截断规则（按字符数 vs 按显示宽度）、换行策略、
/// 空值兜底这些细节容易写错，必须由 LumiTests 锁住，UI 改版才不会悄悄改坏。
struct LyricsShareCard {
    /// 歌名（空串时 UI 显示占位文案）。
    var title: String
    /// 歌手（可空）。
    var artist: String
    /// 当前播放行原文。
    var original: String
    /// 当前播放行译文（可空；双语模式关闭时为 nil）。
    var translation: String?
    /// 卡片角标：Lumi 品牌小字（可选）。
    var branding: String = "Lumi"

    // MARK: - 截断规则

    /// 单行文本在卡片上的最大字符数（超出截断加省略号）。
    /// 中英混排时该值偏保守：SwiftUI Text 会按实际宽度再自动换行，
    /// 这里只做「防止极端长行撑爆卡片」的上限保护。
    static let maxLineLength = 60
    static let ellipsis = "…"

    /// 文本按最大长度截断；超出加省略号。空串返回空串。
    static func truncated(_ text: String, maxLength: Int = maxLineLength) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else { return trimmed }
        let prefix = String(trimmed.prefix(maxLength - 1))
        return prefix + ellipsis
    }

    // MARK: - 输出结构

    /// 返回卡片上应显示的完整字段组（全部已截断、空值兜底）。
    /// UI 层按顺序渲染：title / artist / original / translation。
    var displayFields: (title: String, artist: String, original: String, translation: String?) {
        let t = title.isEmpty ? "正在播放" : title
        let a = artist.isEmpty ? "" : artist
        let o = Self.truncated(original)
        let trRaw = translation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let tr = trRaw.isEmpty ? nil : Self.truncated(trRaw)
        return (t, a, o, tr)
    }

    /// 是否有可分享的内容（原文或译文至少一个非空）。
    /// 空态（未在播放 / 纯音乐）时 UI 应禁用分享按钮。
    var hasShareableContent: Bool {
        !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 分享文件的建议名（不含扩展名）；非法文件名字符替换为下划线。
    var suggestedFileName: String {
        let raw = title.isEmpty ? "Lumi-Lyrics" : title
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = raw.components(separatedBy: illegal).joined(separator: "_")
        let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Lumi-Lyrics" : trimmed
    }
}
