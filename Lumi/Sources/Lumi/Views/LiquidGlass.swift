import SwiftUI

/// Liquid Glass 变体：对应系统 `Glass` 的三种取值。
///
/// 依据 apple-liquid-glass skill 的 SwiftUI 参考：
/// - `.regular` 默认值，标准控件/浮层；
/// - `.clear` 高透，只用于「浮在视觉丰富媒体之上且媒体必须保持突出」的场景，
///   并且**必须**配一层暗化层（HIG：≈35% 黑）保证可读；
/// - `.identity` 不施加玻璃，用于「条件开关玻璃」而不用 `if` 分支。
enum GlassVariant {
    case regular
    case clear
    case identity
}

/// 把变体折成系统 `Glass`。必须是 availability 方法：`Glass` 是 macOS 26+ 类型，
/// deployment target 仍是 macOS 14，不能作为普通返回类型出现在结构体层面。
@available(macOS 26.0, *)
func makeGlass(variant: GlassVariant, tint: Color?, interactive: Bool) -> Glass {
    var glass: Glass
    switch variant {
    case .regular: glass = .regular
    case .clear: glass = .clear
    case .identity: glass = .identity
    }
    if let tint { glass = glass.tint(tint) }
    // interactive 只对真正响应点击的控件开；静态徽标开它就是错的。
    if interactive { glass = glass.interactive() }
    return glass
}

/// macOS 26+ Liquid Glass 面板底（「macOS 27」设计语言）：把项目里到处手搓的
/// 「材质 + 暗色罩层 + 白色描边」三件套收敛成系统玻璃。
///
/// 依据 build-macos-apps / liquid-glass skill 的准则：
/// - 优先使用系统提供的玻璃与自适应材质，不要手搓模糊 / 不透明背景盖住系统材质；
/// - 罩层（scrim）会干扰系统 Liquid Glass 的折射与滚动边缘效果；
/// - tint 只用于保证内容可读性（深色面板压暗、锁屏罩层更暗），不做装饰。
///
/// 旧系统（< macOS 26）完全回退到手搓材质底，观感与升级前逐像素一致；
/// deployment target 仍是 macOS 14，所以每条链路都要能退回。
struct GlassPanelBackground: ViewModifier {
    /// 玻璃圆角：与内容裁剪圆角保持一致，避免边角出现两层弧。
    var cornerRadius: CGFloat
    /// 玻璃着色：仅用于可读性（如深色面板用半透明黑压暗）。
    var tint: Color?
    /// 玻璃变体：默认 `.regular`；`.clear` 需要调用方自备暗化层。
    var variant: GlassVariant = .regular
    /// 是否可交互（按压缩放/高光）。只对真控件开。
    var interactive: Bool = false
    /// 旧系统回退参数：材质 + 暗色罩层 + 描边。
    var material: Material = .ultraThinMaterial
    var scrim: Double = 0
    var stroke: Double = 0

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                // 被包裹的子树必须跟着玻璃圆角一起裁掉：glassEffect 只塑形自己那层
                // 玻璃，不裁剪子内容。截图里「圆角旁边多出来的边角料」就是压在面板
                // 圆角弧外侧的子玻璃/控件没被裁、从弧线外露出半边造成的。
               .glassEffect(
                    makeGlass(variant: variant, tint: tint, interactive: interactive),
                    in: .rect(cornerRadius: cornerRadius, style: .continuous)
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content
                .background(legacyBackground)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    /// 组装系统玻璃。单独拆一个 availability 方法：`Glass` 本身 macOS 26+ 才可用，
    /// 不能作为属性/返回值声明在结构体层面（deployment target 仍是 macOS 14）。
    private var legacyBackground: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(material)
            .overlay(Color.black.opacity(scrim))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(stroke), lineWidth: 0.5)
            )
    }
}

extension View {
    /// 给内容套上 Liquid Glass 面板底；旧系统自动回退到手搓材质底。
    func glassPanel(
        cornerRadius: CGFloat,
        tint: Color? = nil,
        variant: GlassVariant = .regular,
        interactive: Bool = false,
        material: Material = .ultraThinMaterial,
        scrim: Double = 0,
        stroke: Double = 0
    ) -> some View {
        modifier(GlassPanelBackground(
            cornerRadius: cornerRadius,
            tint: tint,
            variant: variant,
            interactive: interactive,
            material: material,
            scrim: scrim,
            stroke: stroke
        ))
    }

    /// 玻璃胶囊：浮在内容之上的单枚控件（小/中/大字号、尺寸档位、圆形工具钮等）。
    ///
    /// 修饰顺序遵循 skill 的「先定尺寸与内边距 → 再玻璃 → 最后定位」：
    /// padding 在玻璃之前会把玻璃撑大，`.frame` 放在玻璃之后就是「玻璃尺寸不对」的
    /// 常见根因，所以这里只做玻璃，尺寸交给调用方在前一步给定。
    @ViewBuilder
    func glassCapsule(
        tint: Color? = nil,
        variant: GlassVariant = .regular,
        interactive: Bool = false
    ) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(
                makeGlass(variant: variant, tint: tint, interactive: interactive),
                in: .capsule
            )
        } else {
            // 旧系统：标准材质，不是玻璃的复刻，观感与升级前一致。
            background(Capsule(style: .continuous).fill(.ultraThinMaterial))
        }
    }

    /// 玻璃按钮：skill 点名「最常见的错误」就是 `Button { }.glassEffect()` ——
    /// 那等于在按钮后面垫了一块玻璃板。正确做法是让按钮**自己**成为玻璃。
    /// 这里保留 `.plain` + 显式几何，因为 Lumi 的控件尺寸由 `*Metrics` 单一来源
    /// 决定（22×20 的药丸），交给系统 `GlassButtonStyle` 的内边距会把尺寸撑散。
    ///
    /// 用法：`Button { … } label: { … }.frame(w, h).glassButton(tint: …)`
    /// —— `.frame` 必须在 `glassButton` 之前。
    @ViewBuilder
    func glassButton(
        tint: Color? = nil,
        variant: GlassVariant = .regular,
        interactive: Bool = true
    ) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(
                makeGlass(variant: variant, tint: tint, interactive: interactive),
                in: .capsule
            )
        } else {
            background(Capsule(style: .continuous).fill(.ultraThinMaterial))
        }
    }

    /// 玻璃分组：相邻**且相关**的玻璃必须同处一个 `GlassEffectContainer` 采样，
    /// 否则各自采样会互相污染。skill 的修正规则：容器只包「相近且需共享采样/融合/
    /// 形变」的一组，不是「屏上有多个玻璃就全包进去」，更**绝不能嵌套**。
    @ViewBuilder
    func glassGroup<Content: View>(
        spacing: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }

    /// `.clear` 玻璃下的暗化层。HIG 给的数值：底层内容明亮时 ≈35% 黑；
        /// 内容本就暗、或控件自带对比处理时不需要。
    ///
    /// `cornerRadius`：传入圆角时把暗化层一起裁圆。`background` 是矩形
    /// 填充，不裁就会在玻璃圆角弧外侧露出四块直角黑边，正是要消灭的边角料。
    @ViewBuilder
    func glassDimmingLayer(_ amount: Double = 0.35, cornerRadius: CGFloat? = nil) -> some View {
        if let cornerRadius {
            background(Color.black.opacity(amount))
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            background(Color.black.opacity(amount))
        }
    }
}
