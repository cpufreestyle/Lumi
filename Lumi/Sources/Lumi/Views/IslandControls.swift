import SwiftUI

// MARK: - 右下角手动缩放手柄
/// 拖拽即可调整展开面板大小，尺寸上限/下限由窗口控制器夹紧，
/// 松手后尺寸持久化，下次展开沿用。手柄手势挂在自身，不会被
/// 面板的"下拉收起"全局手势误触发。
struct ResizeHandle: View {
    @State private var lastTranslation: CGSize = .zero
    @State private var dragging = false

    var body: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.white.opacity(dragging ? 0.65 : 0.3))
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { v in
                        let delta = CGSize(
                            width: v.translation.width - lastTranslation.width,
                            height: v.translation.height - lastTranslation.height
                        )
                        SharedIslandController.controller?.resizeBy(delta)
                        lastTranslation = v.translation
                        dragging = true
                        AppState.shared.isResizing = true
                    }
                    .onEnded { _ in
                        SharedIslandController.controller?.saveUserSize()
                        lastTranslation = .zero
                        dragging = false
                        AppState.shared.isResizing = false
                    }
            )
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() }
                else { NSCursor.pop() }
            }
    }
}

// MARK: - 歌词与胶囊设置弹层
/// 展开面板内点「slider.horizontal.3」打开，提供行间距 / 胶囊宽 / 胶囊高 三个滑块，
/// 实时生效并持久化（值存于 AppState，已写 UserDefaults）。
struct LyricTuningPanel: View {
    @ObservedObject private var state = AppState.shared

    var body: some View {
        ZStack {
            // 半透明遮罩，点击空白处关闭
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { state.showLyricTuning = false }

            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("歌词与胶囊")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()
                    Button(action: { state.showLyricTuning = false }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }

                // 行间距
                tuningRow(
                    title: "歌词行间距",
                    value: state.lyricLineSpacing,
                    range: 0...20,
                    step: 1,
                    format: "%.0f pt"
                ) { state.lyricLineSpacing = $0 }

                // 胶囊宽度
                tuningRow(
                    title: "胶囊宽度",
                    value: state.capsuleSize.width,
                    range: 280...900,
                    step: 10,
                    format: "%.0f pt"
                ) { state.capsuleSize.width = $0 }

                // 胶囊高度
                tuningRow(
                    title: "胶囊高度",
                    value: state.capsuleSize.height,
                    range: 60...260,
                    step: 5,
                    format: "%.0f pt"
                ) { state.capsuleSize.height = $0 }

                // 重置
                HStack {
                    Spacer()
                    Button(action: { state.resetLyricTuning() }) {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.counterclockwise")
                            Text("恢复默认")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.pink.opacity(0.85)))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            }
            .padding(20)
            .frame(width: 320)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
                    .overlay(Color.black.opacity(0.9))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.12), lineWidth: 0.5))
            )
            .shadow(color: .black.opacity(0.5), radius: 25, y: 10)
        }
    }

    private func tuningRow(
        title: String,
        value: CGFloat,
        range: ClosedRange<CGFloat>,
        step: CGFloat,
        format: String,
        onChanged: @escaping (CGFloat) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
                Spacer()
                Text(String(format: format, value))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(width: 56, alignment: .trailing)
            }
            Slider(value: Binding(
                get: { value },
                set: { onChanged($0) }
            ), in: range, step: step)
            .tint(.pink)
        }
    }
}

// MARK: - 胶囊尺寸拖拽手柄
/// 收缩态胶囊右下角的缩放手柄：拖拽实时改变 AppState.capsuleSize（宽/高），
/// 窗口控制器已订阅 capsuleSize 变化并即时重排窗口 frame；松手即持久化。
/// 手柄手势挂在自身，不与「长按拖移歌词」整胶囊手势冲突。
struct CapsuleResizeHandle: View {
    @ObservedObject private var state = AppState.shared
    @State private var lastTranslation: CGSize = .zero
    @State private var dragging = false

    private let minW: CGFloat = 280, maxW: CGFloat = 900
    private let minH: CGFloat = 60,  maxH: CGFloat = 260

    var body: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.white.opacity(dragging ? 0.75 : 0.35))
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { v in
                        let delta = CGSize(
                            width: v.translation.width - lastTranslation.width,
                            height: v.translation.height - lastTranslation.height
                        )
                        lastTranslation = v.translation
                        dragging = true
                        // 右下角手柄：向右下拖 = 增大。宽度随 dx，高度随 -dy（向下 dy 为正，增大高度）。
                        let newW = min(maxW, max(minW, state.capsuleSize.width + delta.width))
                        let newH = min(maxH, max(minH, state.capsuleSize.height + delta.height))
                        state.capsuleSize = CGSize(width: newW, height: newH)
                        // 胶囊缩小后，若歌词偏移已越界则同步钳制，保证歌词仍在胶囊内
                        state.lyricOffset = state.clampLyricOffset(state.lyricOffset)
                    }
                    .onEnded { _ in
                        lastTranslation = .zero
                        dragging = false
                    }
            )
    }
}

// MARK: - 胶囊宽度拖拽手柄
/// 收缩态胶囊右侧竖直居中的「只拉宽」手柄：拖拽实时改变 AppState.capsuleSize.width，
/// 高度保持不变。独立于右下角缩放手柄，互不冲突。
struct CapsuleWidthHandle: View {
    @ObservedObject private var state = AppState.shared
    @State private var lastTranslation: CGFloat = 0
    @State private var dragging = false

    private let minW: CGFloat = 280, maxW: CGFloat = 900

    var body: some View {
        Image(systemName: "arrow.left.and.right")
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.white.opacity(dragging ? 0.85 : 0.4))
            .frame(width: 18, height: 30)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { v in
                        let delta = v.translation.width - lastTranslation
                        lastTranslation = v.translation.width
                        dragging = true
                        let newW = min(maxW, max(minW, state.capsuleSize.width + delta))
                        state.capsuleSize = CGSize(width: newW, height: state.capsuleSize.height)
                        state.lyricOffset = state.clampLyricOffset(state.lyricOffset)
                    }
                    .onEnded { _ in
                        lastTranslation = 0
                        dragging = false
                    }
            )
    }
}
