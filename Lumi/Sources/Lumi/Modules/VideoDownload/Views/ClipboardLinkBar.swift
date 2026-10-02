import SwiftUI

struct ClipboardLinkBar: View {
    @ObservedObject private var clipboard = ClipboardLinkController.shared

    var body: some View {
        // 与 AI 动作条同一套玻璃：容器 + 按钮同组采样（见 AIActionBar）
        glassGroup(spacing: 6) {
            HStack(spacing: 6) {
                if let pending = clipboard.pending {
                    Text(pending.hostDisplay)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(PanelInk.text(0.9))
                        .lineLimit(1)

                    ForEach(VideoDownloadController.DownloadFormat.allCases) { fmt in
                        Button { clipboard.acceptPending(format: fmt) } label: {
                            HStack(spacing: 3) {
                                Image(systemName: fmt.icon)
                                Text(fmt.rawValue)
                            }
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(PanelInk.text(0.9))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                        }
                        .buttonStyle(.plain)
                        // 玻璃长在按钮自己身上；粉色 tint 标识「下载」动作
                        .glassButton(tint: Color.pink.opacity(0.3))
                    }

                    Button { clipboard.dismissPending() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(PanelInk.text(0.5))
                            .padding(4)
                    }
                    .buttonStyle(.plain)
                    .glassButton()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        // 容器换系统玻璃：tint + legacy scrim 保持深色可读性
        .glassPanel(cornerRadius: 18, tint: Color.black.opacity(0.35),
                    scrim: 0.62, stroke: 0.12)
        .transition(.opacity)
    }
}
