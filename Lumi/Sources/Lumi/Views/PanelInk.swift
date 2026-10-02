import SwiftUI
import AppKit

/// 展开面板是系统 Liquid Glass 底，跟随 macOS 明暗外观：浅色玻璃需要深字，
/// 深色玻璃需要浅字。历史上所有模块都写死 `.white`，浅色外观下必然糊进背景。
/// 统一从这里取「反差色」，明暗两种模式都保持可读。
///
/// 约定取色方向：`mono(lightAlpha, darkAlpha)` —— 浅色外观给黑、深色外观给白。
/// 深色外观的分量与原写死的 `.white.opacity(o)` 逐值一致，所以换过来以后
/// 深色模式零回归；只有浅色模式从「白字消失」变成「同权重的黑字」。
enum PanelInk {
    private static func mono(_ light: Double, _ dark: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? .white.withAlphaComponent(dark)
                : .black.withAlphaComponent(light)
        })
    }

    /// 彩色反差字（提示/状态）：浅底下压深、深底下提亮。
    private static func duo(_ light: (Double, Double, Double),
                            _ dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(calibratedRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }

    /// 正文/主标签
    static let primary = mono(0.13, 0.95)
    /// 次级说明文字、标题行、时间、歌手名
    static let secondary = mono(0.32, 0.70)
    /// 弱化数值与占位文案
    static let tertiary = mono(0.42, 0.50)
    /// 控件图标/按钮文字
    static let control = mono(0.16, 0.85)
    /// 不写实的纯白需求（深色模式保持原样，浅色模式换成浓墨）
    static var solid: Color { mono(0.86, 1.0) }

    /// 按原 `.white.opacity(o)` 的权重取反差字：浅底=同权重黑、深底=同权重白。
    static func text(_ o: Double) -> Color { mono(min(1, o * 1.7), o) }

    /// 弱底片（输入框、未选中胶囊、滑轨底）：浅底淡黑罩、深底淡白罩。
    static func chip(_ o: Double) -> Color { mono(o * 0.85, o) }

    /// 描边：与 chip 同权重，浅底下用淡黑才不会消失。
    static func stroke(_ o: Double) -> Color { mono(o * 0.8, o) }

    /// 状态色：红/橙/粉等语义色在浅底太淡，压深保证反差。
    static let pink = duo((0.72, 0.08, 0.42), (1.00, 0.42, 0.62))
    static let orange = duo((0.72, 0.36, 0.02), (1.00, 0.62, 0.18))
    static let red = duo((0.70, 0.10, 0.14), (1.00, 0.30, 0.32))
    static let green = duo((0.10, 0.50, 0.24), (0.32, 0.86, 0.46))
    static let blue = duo((0.10, 0.36, 0.72), (0.42, 0.66, 1.00))
    static let cyan = duo((0.00, 0.46, 0.56), (0.38, 0.85, 0.94))
    static let yellow = duo((0.66, 0.44, 0.02), (1.00, 0.82, 0.24))
    static let purple = duo((0.42, 0.24, 0.74), (0.68, 0.50, 1.00))
}
