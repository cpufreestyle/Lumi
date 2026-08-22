import SwiftUI

// MARK: - 主内容视图（收缩/展开/悬停预览）
struct ContentView: View {
    @ObservedObject private var state = AppState.shared

    var body: some View {
        Group {
            if state.isExpanded {
                ExpandedView()
            } else if state.isHovering {
                // 预览卡片已移除：hover 时只显示收缩态胶囊，不再向下延伸预览内容。
                CollapsedView()
            } else {
                CollapsedView()
            }
        }
        // 内容严格填满窗口，不留额外边距，避免圆角外露出多余的透明矩形外框
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 命中区域裁剪为圆角形状：透明的四个直角不再响应 hover / 点击。
        // 只改命中区域、不用 clipShape，以免把内容自带的 .shadow 一并裁掉。
        // 注意：hover 命中只挂在收缩态胶囊(CollapsedView)上，不挂在整个窗口，
        // 否则鼠标只是靠近顶部热区、尚未碰到岛本身就会展开预览。
        .contentShape(RoundedRectangle(cornerRadius: state.isExpanded ? 22 : 21))
        .background(WindowAccessor())
    }
}

// MARK: - 音乐悬停预览
struct MusicPeekView: View {
    @ObservedObject private var music = MusicController.shared

    var body: some View {
        VStack(alignment: .center, spacing: 5) {
            Text(music.title.isEmpty ? "未在播放" : music.title)
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(.red)
                .shadow(color: .black.opacity(0.7), radius: 3, x: 0, y: 1)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)
            Text(music.artist.isEmpty ? "打开音乐 App" : music.artist)
                .font(.system(size: 18))
                .foregroundColor(.red)
                .shadow(color: .black.opacity(0.7), radius: 3, x: 0, y: 1)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)
            if music.duration > 0 {
                ProgressView(value: min(1, music.currentTime / music.duration))
                    .progressViewStyle(LinearProgressViewStyle(tint: Color.pink))
                    .frame(height: 4)
            }
        }
    }
}

// MARK: - 窗口大小通知辅助
extension Notification.Name {
    static let islandDidExpand = Notification.Name("islandDidExpand")
    static let islandDidCollapse = Notification.Name("islandDidCollapse")
}

/// 获取窗口引用
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            _ = view.window
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
