import SwiftUI

/// 胶囊歌词的悬停控制条：与桌面歌词浮窗控制条**同一份 SwiftUI 实现**。
///
/// 桌面那套历史上是 AppKit NSView（浮窗嵌在 NSPanel 里、不能被整窗拖拽吃掉点击），
/// 胶囊是纯 SwiftUI 重画，两边靠常量对齐仍然会漂移。现在统一为一份 Liquid Glass
/// 控件（见 `LyricsGlass`）：桌面侧由独立 `NSHostingView` 承载，命中测试先落到
/// 控制条自己的 hosting 视图上，SwiftUI 按钮可以正常收到点击，控制条以外的区域
/// 仍由内容 hosting 视图负责整窗拖拽 —— 于是两处真正共用同一份代码、同一套皮肤。
struct CapsuleLyricsControls: View {
    /// 数据源由调用方注入，**不能**在这里取 `MusicController.shared`：
    /// 桌面浮窗的控制条会在 `MusicController.shared` 自身的懒初始化里被创建
    /// （init 读 UserDefaults → didSet → 建浮窗 → 建控制条），再走一次 shared
    /// 会在同一线程对同一个 once token 递归加锁，直接被 libdispatch 判死锁 trap。
    @ObservedObject var music: MusicController
    /// 是否可见（悬停时由外层驱动）。不可见时不占据命中测试区域。
    var visible: Bool
    /// 点击隐藏按钮：与桌面一致，临时隐藏浮窗（不关功能、不持久化）。
    var onHide: (() -> Void)?

    var body: some View {
        LyricsGlass.bar(spacing: DesktopLyricsControlsMetrics.pillSpacing) {
            HStack(spacing: DesktopLyricsControlsMetrics.pillSpacing) {
                ForEach(DesktopLyricsSizePreset.allCases, id: \.self) { preset in
                    pill(title: preset.label, selected: preset == music.desktopLyricsSizePreset) {
                        music.desktopLyricsSizePreset = preset
                    }
                    .help("桌面歌词字号·\(preset.label)")
                }
                pill(title: "×", selected: false) { onHide?() }
                    .help("隐藏桌面歌词浮窗")
            }
            .padding(.horizontal, DesktopLyricsControlsMetrics.inset)
            .frame(height: DesktopLyricsControlsMetrics.barHeight)
        }
        .opacity(visible ? 1 : 0)
        // 不可见时整体退出命中测试，避免在胶囊上拦出隐形热区
        .allowsHitTesting(visible)
        .animation(.easeInOut(duration: 0.15), value: visible)
    }

    private func pill(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        // 玻璃**长在按钮自己身上**，而不是在按钮后面垫一块玻璃板 —— 后者是
        // apple-liquid-glass skill 点名「最常见的错误」：`Button{}.glassEffect()`
        // 与「按钮坐在玻璃板上」观感相同，命中测试与高光都会错位。
        // 修饰顺序：先 `.frame` 把玻璃形状定死，再上玻璃（skill：size → pad → glass → position）。
        Button(action: action) {
            Text(title)
                .font(.system(size: DesktopLyricsControlsMetrics.pillFontSize,
                              weight: selected ? .semibold : .medium))
                .foregroundColor(.white.opacity(selected ? 1 : 0.62))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(width: DesktopLyricsControlsMetrics.pillWidth,
               height: DesktopLyricsControlsMetrics.pillHeight)
        .lyricsGlassPill(selected: selected)
    }
}

/// 控制条视觉常量：桌面浮窗控制条（`DesktopLyricsControlsBar`）与胶囊控制条共用，
/// 保证两处药丸尺寸/间隔/圆角/字重不分叉。
enum DesktopLyricsControlsMetrics {
    /// 控制条与宿主边缘的距离：胶囊 overlay 的 .padding(edgeInset) 与桌面浮窗
    /// layoutControls 的 inset 共用同一值，避免两边定位漂移。
    /// 与 inset（控件内部水平留白）区分：一个对外、一个对内。
    static let edgeInset: CGFloat = 5
    static let barWidth: CGFloat = 100
    static let barHeight: CGFloat = 26
    static let inset: CGFloat = 3
    static let pillWidth: CGFloat = 22
    static let pillHeight: CGFloat = 20
    static let pillSpacing: CGFloat = 2
    static let pillCornerRadius: CGFloat = 4
    static let pillFontSize: CGFloat = 10

    /// 右上角控制条对歌词行的让位总宽：药丸条本体 + 两侧 edgeInset。
    /// 桌面浮窗的窗口加宽（contentSize 的 trailingReserve）与歌词文本右侧收尾
    /// （DesktopLyricsContentView 的 .padding(.trailing)）共用这一值；
    /// 只加宽窗口不收尾的话，文字仍会从按钮下方穿过。
    static var trailingReserve: CGFloat { barWidth + edgeInset * 2 }
}
