import SwiftUI

// MARK: - 主内容视图（收缩/展开/悬停预览）
struct ContentView: View {
    @ObservedObject private var state = AppState.shared

    var body: some View {
        Group {
            if state.isExpanded {
                ExpandedView()
            } else if state.isHovering {
                PeekView()
            } else {
                CollapsedView()
            }
        }
        .background(WindowAccessor())
        .onHover { inside in
            AppState.shared.isHovering = inside
        }
    }
}

// MARK: - 悬停预览态：胶囊 + 模块预览
struct PeekView: View {
    @ObservedObject private var state = AppState.shared

    var body: some View {
        VStack(spacing: 0) {
            PeekPreviewContent()
                .frame(maxHeight: .infinity)
            CollapsedView()
                .padding(.bottom, 6)
        }
    }
}

struct PeekPreviewContent: View {
    @ObservedObject private var state = AppState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(state.activeModule.rawValue, systemImage: state.activeModule.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))

            switch state.activeModule {
            case .music:          MusicPeekView()
            case .calendar:       Text("今日日程预览").font(.system(size: 11)).foregroundColor(.white.opacity(0.55))
            case .focus:          Text("专注计时").font(.system(size: 11)).foregroundColor(.white.opacity(0.55))
            case .clipboard:      Text("最近复制内容").font(.system(size: 11)).foregroundColor(.white.opacity(0.55))
            case .liveDetection:  Text("环境连接检测").font(.system(size: 11)).foregroundColor(.white.opacity(0.55))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }
}

// MARK: - 音乐悬停预览
struct MusicPeekView: View {
    @ObservedObject private var music = MusicController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(music.title.isEmpty ? "未在播放" : music.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
            Text(music.artist.isEmpty ? "打开音乐 App" : music.artist)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.55))
                .lineLimit(1)
            if music.duration > 0 {
                ProgressView(value: min(1, music.currentTime / music.duration))
                    .progressViewStyle(LinearProgressViewStyle(tint: Color.pink))
                    .frame(height: 4)
            }
        }
    }
}

// MARK: - 收缩态：胶囊条
struct CollapsedView: View {
    @ObservedObject private var state = AppState.shared

    var body: some View {
        HStack(spacing: 0) {
            // 左侧：当前模块图标
            moduleIconView
                .padding(.leading, 14)

            Spacer()

            // 中间：简要信息
            moduleBriefView
                .padding(.horizontal, 8)

            Spacer()

            // 右侧：模块切换小点
            moduleDotsView
                .padding(.trailing, 14)
        }
        .frame(height: 42)
        .background(
            RoundedRectangle(cornerRadius: 21)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 21)
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                )
        )
        .shadow(color: .black.opacity(0.3), radius: 15, y: 5)
        .onTapGesture {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                AppState.shared.isExpanded = true
            }
        }
    }

    var moduleIconView: some View {
        Image(systemName: state.activeModule.icon)
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.white)
            .frame(width: 26, height: 26)
            .background(
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.pink, Color.purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
    }

    @ViewBuilder
    var moduleBriefView: some View {
        switch state.activeModule {
        case .music:
            MusicBriefView()
        case .calendar:
            CalendarBriefView()
        case .focus:
            FocusBriefView()
        case .clipboard:
            ClipboardBriefView()
        case .liveDetection:
            LiveDetectionBriefView()
        }
    }

    var moduleDotsView: some View {
        HStack(spacing: 5) {
            ForEach(AppModule.allCases) { mod in
                Circle()
                    .fill(
                        state.activeModule == mod
                            ? Color.pink
                            : Color.white.opacity(0.25)
                    )
                    .frame(
                        width: state.activeModule == mod ? 8 : 5,
                        height: state.activeModule == mod ? 8 : 5
                    )
                    .animation(.spring(), value: state.activeModule)
            }
        }
    }
}

// MARK: - 展开态：完整面板
struct ExpandedView: View {
    @ObservedObject private var state = AppState.shared
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            // 顶部标签栏
            TabBarView()

            // 模块内容
            moduleContentView
                .frame(maxHeight: .infinity)

            // 底部拖拽指示器
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.white.opacity(0.3))
                .frame(width: 32, height: 3)
                .padding(.bottom, 8)
        }
        .frame(width: 360, height: 480)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 22)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                )
        )
        .shadow(color: .black.opacity(0.4), radius: 25, y: 8)
        .gesture(
            DragGesture()
                .onChanged { v in
                    if v.translation.height > 30 {
                        dragOffset = v.translation.height
                    }
                }
                .onEnded { v in
                    if v.translation.height > 60 {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                            AppState.shared.isExpanded = false
                        }
                        // 收缩后通知窗口收回尺寸
                        NotificationCenter.default.post(name: .islandDidCollapse, object: nil)
                    }
                    dragOffset = 0
                }
        )
        .offset(y: dragOffset)
        .onAppear {
            // 展开时通知窗口调整大小
            NotificationCenter.default.post(name: .islandDidExpand, object: nil)
        }
    }

    @ViewBuilder
    var moduleContentView: some View {
        switch state.activeModule {
        case .music:
            MusicExpandedView()
        case .calendar:
            CalendarExpandedView()
        case .focus:
            FocusExpandedView()
        case .clipboard:
            ClipboardExpandedView()
        case .liveDetection:
            LiveDetectionExpandedView()
        }
    }
}

// MARK: - 顶部标签栏
struct TabBarView: View {
    @ObservedObject private var state = AppState.shared

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppModule.allCases) { mod in
                Button(action: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                        state.activeModule = mod
                    }
                }) {
                    VStack(spacing: 3) {
                        Image(systemName: mod.icon)
                            .font(.system(size: 15))
                        Text(mod.shortName)
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundColor(state.activeModule == mod ? .pink : .white.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)

        // 底部分隔线
        Rectangle()
            .fill(Color.white.opacity(0.1))
            .frame(height: 0.5)
            .padding(.horizontal, 16)
    }
}

// MARK: - 各模块收缩态简要视图（占位）
struct MusicBriefView: View { var body: some View { MusicBriefContent() } }
struct CalendarBriefView: View { var body: some View { Text("📅 今日 3 项日程").font(.system(size: 12)).foregroundColor(.white.opacity(0.7)) } }
struct FocusBriefView: View { var body: some View { FocusBriefContent() } }
struct ClipboardBriefView: View { var body: some View { Text("📋 12 条记录").font(.system(size: 12)).foregroundColor(.white.opacity(0.7)) } }
struct LiveDetectionBriefView: View { var body: some View { LiveDetectionBriefContent() } }

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
