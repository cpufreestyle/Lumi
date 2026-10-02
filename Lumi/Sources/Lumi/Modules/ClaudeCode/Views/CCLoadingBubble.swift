import SwiftUI

struct CCLoadingBubble: View {
    /// 省略号每次跳动的间隔（秒）
    private static let dotInterval: TimeInterval = 0.4

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 11))
                .foregroundColor(.purple.opacity(0.7))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.purple.opacity(0.15)))
            // 用 TimelineView 取代原先 0.4s 的 Timer + @State 计数：
            // 去掉定时器对 self 的持有与每 0.4s 一次的无谓 body 重算，
            // 动画节奏交给 SwiftUI 调度，随视图生命周期自动起停。
            TimelineView(.periodic(from: .now, by: Self.dotInterval)) { timeline in
                let step = Int(timeline.date.timeIntervalSince1970 / Self.dotInterval)
                Text(String(repeating: ".", count: (step % 3) + 1))
                    .font(.system(size: 11))
                    .foregroundColor(PanelInk.text(0.4))
                    .padding(10)
                    .background(PanelInk.chip(0.06))
                    .cornerRadius(10)
            }
        }
    }
}
