import Foundation

/// 桌面歌词浮窗的布局纯逻辑：文本宽度估算、窗口尺寸、屏幕边界钳制、位置持久化编解码。
/// 与 AppKit 解耦（钳制目标 visibleFrame 由调用方传入），便于 LumiTests 直接单测。
enum DesktopLyricsLayout {
    // MARK: - UserDefaults 键（与 MusicController 中的键常量保持一致）
    static let enabledKey   = "music_desktop_lyrics_enabled"
    static let lockedKey    = "music_desktop_lyrics_locked"
    static let originKey    = "music_desktop_lyrics_origin"
    static let sizeScaleKey = "music_desktop_lyrics_size"

    // MARK: - 尺寸常量
    static let minWidth: CGFloat = 200
    static let maxWidth: CGFloat = 760
    static let originalHeight: CGFloat = 26   // 原文行高（字号 20，收紧后更贴合文字）
    static let translationHeight: CGFloat = 18 // 译文行高（字号 13）
    static let horizontalPadding: CGFloat = 32 // 左右内边距合计（含描边余量）
    static let verticalPadding: CGFloat = 8    // 上下内边距合计：从 14 收紧，消掉明显空隙
    static let edgeMargin: CGFloat = 8         // 钳制时距屏幕边缘的最小间距
    /// 拖拽与松手共用的「松钳制」下，每轴至少要保留多少在屏内。
    /// 比 edgeMargin 宽，保证窗口即使探出屏幕也随时抓得回来。
    static let onScreenMinimum: CGFloat = 40
    static let defaultBottomOffset: CGFloat = 110 // 默认停靠在可见区域底部上方

    /// 估算一行文本的渲染宽度：CJK/全角按 1.0 em，ASCII 按 0.58 em，其余按 0.7 em。
    /// 经验值宁可略宽（避免估窄导致窗口比文字短被截断）。
    static func textWidth(_ text: String, fontSize: CGFloat) -> CGFloat {
        var units: CGFloat = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x4E00...0x9FFF).contains(v)     // CJK 统一表意
                || (0x3000...0x303F).contains(v) // CJK 标点
                || (0xFF00...0xFFEF).contains(v) // 全角/半角形式
                || (0x2018...0x201D).contains(v) // 中英文智能引号
            {
                // 1.06 em：CJK 字形在 .rounded design 下常略宽于 1.0 em，
                // 估窄会导致窗口窄于真实文字宽度、右侧被裁切（minimumScaleFactor
                // 缩放后仍可能溢出）。留 6% 余量宁可略宽。
                units += 1.06
            } else if (0x20...0x7E).contains(v) { // ASCII 可打印
                units += 0.60
            } else {
                units += 0.75
            }
        }
        return units * fontSize
    }

    /// 判断字符串是否包含 CJK 字符（中日韩统一表意文字、平/片假名、韩文）。
    static func hasCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { scalar in
            let v = scalar.value
            return (0x4E00...0x9FFF).contains(v)   // CJK 统一表意
                || (0x3400...0x4DBF).contains(v)   // CJK 扩展 A
                || (0x20000...0x2A6DF).contains(v) // CJK 扩展 B
                || (0xF900...0xFAFF).contains(v)   // CJK 兼容表意
                || (0x3040...0x309F).contains(v)   // 日文平假名
                || (0x30A0...0x30FF).contains(v)   // 日文片假名
                || (0xAC00...0xD7AF).contains(v)   // 韩文音节
                || (0x1100...0x11FF).contains(v)   // 韩文字母
        }
    }

    /// 判断字符串是否包含拉丁字母（含带重音字符、扩展拉丁）。
    static func hasLatin(_ s: String) -> Bool {
        s.unicodeScalars.contains { scalar in
            let v = scalar.value
            return (0x0041...0x005A).contains(v)   // A-Z
                || (0x0061...0x007A).contains(v)   // a-z
                || (0x00C0...0x024F).contains(v)   // 拉丁文补充与扩展
                || (0x1E00...0x1EFF).contains(v)   // 拉丁文扩充附加
        }
    }

    /// 判断是否为纯拉丁文歌词（含拉丁字母且不含 CJK）。
    static func isPureLatin(_ s: String) -> Bool {
        hasLatin(s) && !hasCJK(s)
    }

    /// 纯拉丁文歌词的字号放大倍率（与 MusicExpandedView 保持一致）。
    /// 1.18：英文字形 x-height 小于汉字，同样 pt 下视觉明显偏小；
    /// 用户反馈「英文要比中文大一点」，比原先 1.15 再提一档。
    static let latinScale: CGFloat = 1.18

    /// 原文行高对应的字号（窗口控制器与 UI 共用同一份常量，避免两处漂移）。
    static let originalFontSize: CGFloat = 20
    static let translationFontSize: CGFloat = 13

    /// 当前档位下的原文行字号：基准字号乘档位倍率（窗口与 UI 共用，避免两处漂移）。
    /// 当 line 为纯拉丁文（不含 CJK）时，额外乘以 latinScale（当前 1.18），
    /// 让英文歌词在相同档位下显著大于中文歌词，提升可读性。
    static func scaledOriginalFontSize(_ preset: DesktopLyricsSizePreset, line: String = "") -> CGFloat {
        languageAdjusted(originalFontSize * preset.scale, line: line)
    }

    /// 任意基准字号按语言放大：纯拉丁文乘 latinScale（英文字形 x-height 小于汉字，
    /// 同 pt 下视觉偏小，用户要求「英文要比中文大一点」）；含 CJK 的行保持原字号
    /// （等于中文）。档位字号、胶囊固定字号、展开面板自适应字号全部走这一个入口，
    /// 避免每个界面各写一套判断、时间一长互相漂移。
    static func languageAdjusted(_ base: CGFloat, line: String) -> CGFloat {
        isPureLatin(line) ? base * latinScale : base
    }

    /// 当前档位下的译文行字号：基准字号乘档位倍率。
    /// 译文为纯拉丁文时同样乘 latinScale —— 英文字形视觉偏小，
    /// 只放大原文会让「中英行」一大一小看着失衡。
    static func scaledTranslationFontSize(_ preset: DesktopLyricsSizePreset,
                                          line: String = "") -> CGFloat {
        languageAdjusted(translationFontSize * preset.scale, line: line)
    }

    /// 双语行的字号对：原文各自按语言放大；**译文为纯拉丁文（英文）时不低于原文行字号**。
    /// 用户要求「英文歌词的大小要大于中文或者等于中文」—— 中英双语对里英文那行
    /// 不能再比中文那行小（此前英文译文固定 13pt 基准，视觉明显小于中文原文）。
    /// - Parameters:
    ///   - wantsTranslation: 关闭双语时译文不参与放大，也不抬升。
    static func bilingualSizes(originalBase: CGFloat,
                               translationBase: CGFloat,
                               original: String,
                               translation: String,
                               wantsTranslation: Bool) -> (original: CGFloat, translation: CGFloat) {
        let originalSize = languageAdjusted(originalBase, line: original)
        var translationSize = languageAdjusted(translationBase, line: translation)
        if wantsTranslation, isPureLatin(translation) {
            translationSize = max(translationSize, originalSize)
        }
        return (originalSize, translationSize)
    }

    /// 根据当前行与译文计算浮窗内容尺寸；宽度不足保底 minWidth、超过夹到 maxWidth。
    /// sizeScale 是字号档位倍率（1.0 = 中档，与升级前一致）：调用方按档位同步放大
    /// 传入字号与倍率，宽高随之等比放大，放大档才不会把歌词挤断；
    /// 横向 padding 与 min/maxWidth 钳制阈值与档位无关，始终保持同一套边界。
    /// 注意：`originalFontSize` / `translationFontSize` 传「档位缩放后的**基准**字号」
    /// （= 常量 × preset.scale），不要再传已按语言放大的字号 —— 语言放大只在本函数内
    /// 做一次，二次放大会让窗口过宽、行高虚高。
    static func contentSize(line: String,
                            translation: String,
                            showTranslation: Bool,
                            originalFontSize: CGFloat = DesktopLyricsLayout.originalFontSize,
                            translationFontSize: CGFloat = DesktopLyricsLayout.translationFontSize,
                            sizeScale: CGFloat = 1.0,
                            trailingReserve: CGFloat = 0)
        -> CGSize {
        let wantTranslation = showTranslation && !translation.isEmpty
        // 实际渲染字号（含语言放大 + 英文译文不低于中文原文）只在这里算一次
        let sizes = bilingualSizes(originalBase: originalFontSize,
                                   translationBase: translationFontSize,
                                   original: line,
                                   translation: translation,
                                   wantsTranslation: wantTranslation)
        let effectiveOriginalFontSize = sizes.original
        let effectiveTranslationFontSize = sizes.translation
        var width = textWidth(line, fontSize: effectiveOriginalFontSize)
        if wantTranslation {
            width = max(width, textWidth(translation, fontSize: effectiveTranslationFontSize))
        }
        // trailingReserve：右上角悬停控制条（小/中/大 + ×）的让位宽度。
        // 浮窗与胶囊都把它钉在右上角（DesktopLyricsControlsMetrics），歌词行不能伸到
        // 按钮下方；窗口按「文字预算 + 让位」加宽：maxWidth 只夹文字预算，让位加在
        // 夹制之外 —— 超长行的可见字数与无让位时逐字节一致，不会因让位被吃掉一截。
        // 歌词文本右缘的收尾用同一个值（DesktopLyricsContentView 的 trailing padding），
        // 只加宽窗口而不收尾，文字仍会从按钮下方穿过。
        // 胶囊侧同一意图见 IslandViews.lyricTrailingReserve，两边按同一套常量反算。
        let textBudget = ceil(width + horizontalPadding)
        let finalWidth = max(minWidth, min(maxWidth, textBudget)) + trailingReserve
        // 行高必须随实际字号等比放大：语言放大后行高仍按旧常量算，第二行会被窗口
        // 底边裁掉（用户反馈「歌词出错」/ 显示不全）。
        let originalRatio = effectiveOriginalFontSize / max(originalFontSize, 0.001)
        let translationRatio = wantTranslation
            ? effectiveTranslationFontSize / max(translationFontSize, 0.001)
            : 1
        var height = originalHeight * sizeScale * originalRatio + verticalPadding
        if wantTranslation {
            height += translationHeight * sizeScale * translationRatio
        }
        return CGSize(width: finalWidth, height: height)
    }

    /// 把窗口原点钳制进可见区域：任何情况下至少保留 edgeMargin 在屏内，
    /// 保证用户拖动失误后仍能把窗口拖回来（不会遗落在屏幕外）。
    static func clamp(origin: CGPoint, size: CGSize, visibleFrame: CGRect) -> CGPoint {
        let minX = visibleFrame.minX + edgeMargin
        let maxX = visibleFrame.maxX - size.width - edgeMargin
        let minY = visibleFrame.minY + edgeMargin
        let maxY = visibleFrame.maxY - size.height - edgeMargin
        // 窗口比可见区域还大时（极端小屏/超长译文），退化为贴左上角，避免 min>max 取到反值。
        let x = maxX < minX ? minX : min(max(origin.x, minX), maxX)
        let y = maxY < minY ? minY : min(max(origin.y, minY), maxY)
        return CGPoint(x: x, y: y)
    }

    /// 取某个点落在哪块屏（按全屏 frame 匹配）；没有屏包含该点时回退第一块。
    /// 恢复位置（保存点）与拖动中（光标点）共用同一套选屏规则，避免两处漂移。
    /// 纯函数（screens 由调用方从 NSScreen.screens.map(\.frame) 传入），便于单测。
    static func screenFrame(containing point: CGPoint, screens: [CGRect]) -> CGRect {
        if let hit = screens.first(where: { $0.contains(point) }) { return hit }
        return screens.first ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
    }

    /// 恢复位置时该用哪块屏：优先「保存点落在其中」的那块，避免跨屏布局变化后
    /// 用 NSScreen.main 钳制把浮窗甩到另一块屏上；没有屏包含该点时回退第一块。
    /// 纯函数（screens 由调用方从 NSScreen.screens.map(\.frame) 传入），便于单测。
    static func visibleFrame(forSavedPoint point: CGPoint, screens: [CGRect]) -> CGRect {
        screenFrame(containing: point, screens: screens)
    }

    /// 拖拽 / 松手共用的松钳制：允许窗口探出屏幕，但水平、垂直各至少保留
    /// onScreenMinimum 在屏内。与 clamp 的「必须完整落屏」相比，跨屏拖动时不会在
    /// 屏缘硬停，也不会因为按 A 屏钳制而把窗口瞬移到 B 屏；松手用同一套规则，
    /// 因此不存在「拖的时候能出去、一松手又被拽回来」的跳变。
    /// 纯函数，便于 LumiTests 直接单测。
    static func clampAllowingOverhang(origin: CGPoint, size: CGSize, visibleFrame: CGRect) -> CGPoint {
        let keepX = min(onScreenMinimum, size.width)
        let keepY = min(onScreenMinimum, size.height)
        let minX = visibleFrame.minX + keepX - size.width
        let maxX = visibleFrame.maxX - keepX
        let minY = visibleFrame.minY + keepY - size.height
        let maxY = visibleFrame.maxY - keepY
        return CGPoint(x: min(max(origin.x, minX), maxX), y: min(max(origin.y, minY), maxY))
    }

    /// 默认位置：可见区域水平居中、底部上方 defaultBottomOffset 处（避开 Dock 区）。
    static func defaultOrigin(size: CGSize, visibleFrame: CGRect) -> CGPoint {
        CGPoint(x: visibleFrame.midX - size.width / 2,
                y: visibleFrame.minY + defaultBottomOffset)
    }

    /// 位置持久化编码："x,y"（取整，避免每次拖动都产生新字符串写入 UserDefaults）。
    static func encode(origin: CGPoint) -> String {
        String(format: "%.0f,%.0f", origin.x, origin.y)
    }

    /// 位置持久化解码；格式非法（旧版本脏数据/手改）返回 nil，由调用方回退默认位置。
    static func decode(origin: String) -> CGPoint? {
        let parts = origin.split(separator: ",")
        guard parts.count == 2,
              let x = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let y = Double(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// 位置变化是否值得写盘：位移超过 1pt 才持久化，过滤拖拽中的亚像素抖动。
    static func shouldPersist(from old: CGPoint, to new: CGPoint) -> Bool {
        abs(old.x - new.x) > 1 || abs(old.y - new.y) > 1
    }

    /// 浮窗空态文案：没有可显示的歌词行时给出有信息量的提示，替代无意义的占位符，
    /// 让用户能直接从浮窗看出「是没在放、还没取到词、还是这首歌本来就没歌词」。
    /// 纯函数（仅 Foundation），便于 LumiTests 单测。
    /// - Parameters:
    ///   - state: 播放态字符串，"playing" / "paused" / "stopped"（由调用方从枚举转换）。
    ///   - title: 当前曲目名，空/纯空白表示尚未拿到歌曲信息。
    ///   - note: 取词结论（如「纯音乐 · 无歌词」），非空时优先展示。
    static func placeholder(state: String, title: String, note: String) -> String {
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNote.isEmpty { return trimmedNote }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty { return "♪ 等待歌曲信息" }
        switch state {
        case "stopped": return "♪ 未在播放"
        case "paused":  return "♪ 已暂停"
        default:        return "♪ 正在获取歌词…"
    }
}

}

/// 桌面歌词浮窗字号档位：小/中/大三档，供悬停控制条、滚轮、设置区药丸按钮共用。
/// 顶层枚举（不嵌在 DesktopLyricsLayout 里）便于其他模块直接引用；
/// rawValue 落 UserDefaults，脏数据回退 medium，保证老用户升级后字号不会归零。
enum DesktopLyricsSizePreset: String, CaseIterable {
    case small, medium, large

    /// 相对中档的字号倍率；medium 恒为 1，行为与升级前完全一致。
    var scale: CGFloat {
        switch self {
        case .small:  return 0.72
        case .medium: return 1.0
        case .large:  return 1.4
        }
    }

    /// 控制条与设置区按钮显示的档位名。
    var label: String {
        switch self {
        case .small:  return "小"
        case .medium: return "中"
        case .large:  return "大"
        }
    }

    /// 滚轮向上 / 点击「下一档」：small -> medium -> large -> small 三档循环。
    var next: DesktopLyricsSizePreset {
        switch self {
        case .small:  return .medium
        case .medium: return .large
        case .large:  return .small
        }
    }

    /// 滚轮向下 / 上一档：next 的反向，同样循环。
    var previous: DesktopLyricsSizePreset {
        switch self {
        case .small:  return .large
        case .medium: return .small
        case .large:  return .medium
        }
    }

    /// 从持久化原始值恢复档位；nil / 未知字符串（旧版本或手改）回退 medium。
    static func stored(_ raw: String?) -> DesktopLyricsSizePreset {
        guard let raw, let preset = DesktopLyricsSizePreset(rawValue: raw) else {
            return .medium
        }
        return preset
    }
}
