import SwiftUI

/// 恒定滚动速度（points/sec），长/短歌词观感一致，便于阅读。
struct MarqueeText: View {
    let text: String
    let font: Font
    /// 文本颜色。默认白色；收缩态双语歌词需传 .red(原文)/.cyan(译文) 以区分，
    /// 否则会被内部 Text 的白色覆盖，外部 .foregroundColor 修饰无效。
    var textColor: Color = .white
    /// 滚动速度：每列歌词在屏幕上移动的像素速度。恒定值保证不同长度歌词速度一致。
    var speed: Double = 40
    /// 一次滚动结束后停顿时长
    var pause: Double = 1.2

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var animating: Bool = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: Alignment(horizontal: .leading, vertical: .center)) {
                Text(text)
                    .font(font)
                    .foregroundColor(textColor)
                    .lineLimit(1)
                    .fixedSize()
                    .background(
                        GeometryReader { tg in
                            Color.clear.preference(key: WidthKey.self, value: tg.size.width)
                        }
                    )
                    .offset(x: offset)
            }
            .clipped()
            .onAppear { containerWidth = w; restart() }
            .onChange(of: w) { _, nv in containerWidth = nv; restart() }
            .onPreferenceChange(WidthKey.self) { nv in
                textWidth = nv
                restart()
            }
        }
    }

    /// 仅当文本超出容器时才滚动；速度恒定，长文本只是滚得更久而非更快。
    func restart() {
        animating = false
        offset = 0
        guard textWidth > containerWidth, containerWidth > 0 else { return }
        let distance = textWidth - containerWidth + 12
        let duration = max(distance / max(speed, 1), 0.1)
        animating = true
        // 先停顿，再平滑滚动整段，结束后循环
        DispatchQueue.main.asyncAfter(deadline: .now() + pause) {
            withAnimation(.linear(duration: duration)) {
                offset = -(textWidth + 12)
            }
        }
    }
}
