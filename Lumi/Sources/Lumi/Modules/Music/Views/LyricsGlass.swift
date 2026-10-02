import SwiftUI

/// 歌词模块的 Liquid Glass 皮肤（macOS 26+ / 「macOS 27」设计语言）。
///
/// 背景：桌面歌词浮窗与灵动岛胶囊历史上各写了一套「半透明材质 + 暗色罩层」的手搓玻璃，
/// 两边靠常量硬对齐、时间一长必然漂移，且罩层会干扰系统 Liquid Glass 的折射与
/// 边缘发光效果。按 build-macos-apps / liquid-glass skill 的准则：
/// 「优先使用系统提供的玻璃与自适应材质，不要手搓模糊/不透明背景去盖住系统材质」，
/// 这里把三处皮肤收敛到同一份实现：
/// - macOS 26+：系统 `glassEffect` + `GlassEffectContainer`（邻近玻璃归一化采样）；
/// - macOS 26 以下：沿用旧材质底，老系统观感与行为完全不变。
/// 尺寸常量仍由 `DesktopLyricsControlsMetrics` 单一来源提供，调用方不判可用性。
///
/// 底色适配（`Context`）：同一份皮肤坐在两种底色上——
/// - `.dark`：桌面歌词浮窗 / 灵动岛胶囊，背景是深色歌词罩层，白玻璃药丸条通透清晰；
/// - `.light`：展开面板，整块面板是浅色系统玻璃。浅底上白玻璃会糊成一层
///   「幽灵圆角矩形」（描边发白、和背景分不开，用户反馈「圆角矩形的棱角
///   没有去掉」）；且系统玻璃按钮的选中/未选中明暗整体反相：实测
///   `.clear` 子玻璃在浅底上渲染成深石墨、`.regular.tint(accent)` 的选中颗
///   反而近白，选中态文字直接糊进背景。浅底侧因此改用显式填充，不赌容器采样。
enum LyricsGlass {
    /// 控件条底板所处的背景明暗。
    enum Context {
        /// 深色底：桌面歌词浮窗与灵动岛胶囊，沿用系统玻璃药丸。
        case dark
        /// 浅色底：展开面板，药丸改显式填充（见 `lyricsGlassPill`）。
        case light
    }

    /// 控件条底板：内容外再套一颗系统玻璃胶囊（子 pill 各自带 `glassEffect`，
    /// 必须同处一个 `GlassEffectContainer` 内采样才一致，这是视觉正确性要求）。
    /// 浅色底下给玻璃叠一层轻的黑色调，让药丸条从面板里「浮」出来，
    /// 而不是一圈白描边糊在浅背景上。
    @ViewBuilder
    static func bar<Content: View>(
        spacing: CGFloat,
        context: Context = .dark,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
            .glassEffect(context == .light
                         ? .regular.tint(Color.black.opacity(0.10))
                         : .regular,
                         in: .capsule)
        } else {
            content()
                .background(
                    ZStack {
                        Capsule(style: .continuous).fill(.ultraThinMaterial)
                        Capsule(style: .continuous).fill(context == .light
                                                          ? Color.black.opacity(0.06)
                                                          : Color.black.opacity(0.55))
                    }
                )
        }
    }

    /// 浮窗/卡片底板：歌词文本外的一整块玻璃，替代旧的「薄材质 + 黑色罩层」。
    /// 与全局面板玻璃共用同一实现（`glassPanel`，回退参数沿用旧的 0.32 罩层），
    /// 避免歌词侧与面板侧各写一套手搓材质、时间一长又漂移。
    @ViewBuilder
    static func backdrop<Content: View>(
        cornerRadius: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .glassPanel(cornerRadius: cornerRadius, scrim: 0.32)
    }

    /// 歌词行取色：原文/译文/占位共用一份，桌面浮窗与胶囊不再各自调色。
    ///
    /// 歌词只坐深色底（黑岛 / 暗色玻璃罩），要的是饱和荧光色；浅色对比色归
    /// `PanelInk` 管，这里不掺和。历史上桌面写裸 `.red`、胶囊写 `PanelInk.red`
    /// （深色那侧分量偏暗），于是「桌面有荧光、胶囊没有」，就是取色分叉造成的。
    enum Ink {
        case original
        case translation
        case placeholder

        var color: Color {
            switch self {
            case .original: return Color(red: 1.00, green: 0.27, blue: 0.31)
            case .translation: return Color(red: 0.32, green: 0.91, blue: 0.98)
            case .placeholder: return .white.opacity(0.4)
            }
        }

        /// 同色柔光：原文亮一档、译文压一档，避免译文抢原文的层次。
        var glow: Color {
            switch self {
            case .original: return color.opacity(0.6)
            case .translation: return color.opacity(0.5)
            case .placeholder: return .clear
            }
        }
    }
}

extension Text {
    /// 歌词行统一样式：荧光取色 + 同色柔光 + 保证可读的黑色投影。
    ///
    /// 桌面歌词浮窗与灵动岛胶囊共用。柔光必须在黑色投影**之前**叠，反序的
    /// 话投影会把荧光边缘糊掉，等于没有发光。
    func lyricLine(ink: LyricsGlass.Ink) -> some View {
        foregroundColor(ink.color)
            .shadow(color: ink.glow, radius: 8, x: 0, y: 0)
            .shadow(color: .black.opacity(0.6), radius: 4, x: 0, y: 1)
    }
}

extension View {
    /// `LyricsGlass.backdrop` 的链式写法：给歌词底板（浮窗/卡片）套上系统玻璃。
    @ViewBuilder
    func lyricsGlassBackdrop(cornerRadius: CGFloat) -> some View {
        LyricsGlass.backdrop(cornerRadius: cornerRadius) { self }
    }

    /// 单枚药丸。两种底色两条路径：
    ///
    /// - `.dark`（浮窗/胶囊）：玻璃**长在按钮自己身上**，选中态用 tint 表状态
    ///   （语义色，非装饰），`interactive()` 才有系统玻璃的按压缩放与高光；
    ///   未选中用 `.clear`（分段控件未选中态的观感）。修饰符形态而非「包一层」：
    ///   直接挂在控件（Button）自己身上，让控件**成为**玻璃。「在按钮后面垫一块
    ///   玻璃板」是 apple-liquid-glass skill 点名的最常见错误，命中测试与高光都会错位。
    ///   修饰顺序由调用方保证：`.frame` 在前、本修饰符在后。
    ///
    /// - `.light`（展开面板）：显式填充——选中=石墨底白字、未选中=透明底
    ///   （文字由调用方着石墨色）。浅底上系统玻璃药丸的选中/未选中明暗会整
    ///   体反相，继续用 `glassEffect` 等于让选中态消失；显式填充后观感与深底
    ///   侧一致（亮底=选中），且不依赖 macOS 版本。
    @ViewBuilder
    func lyricsGlassPill(selected: Bool, context: LyricsGlass.Context = .dark) -> some View {
        if context == .light {
            background(
                Capsule(style: .continuous)
                    .fill(selected ? Color(white: 0.30) : Color.clear)
            )
        } else if #available(macOS 26.0, *) {
            let glass: Glass = selected ? .regular.tint(Color.accentColor) : .clear
            glassEffect(glass.interactive(), in: .capsule)
        } else {
            background(
                RoundedRectangle(
                    cornerRadius: DesktopLyricsControlsMetrics.pillCornerRadius,
                    style: .continuous
                )
                .fill(Color.white.opacity(selected ? 0.26 : 0.08))
            )
        }
    }
}
