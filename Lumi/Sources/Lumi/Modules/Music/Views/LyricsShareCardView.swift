import SwiftUI
import AppKit

/// 歌词分享卡片视图（复刻 Musixmatch / Apple Music 付费功能）。
///
/// 由 `LyricsCardExporter` 拿到 `LyricsShareCard` 数据后渲染成一张 800×500 的
/// 玻璃质感卡片，可导出为 NSImage 分享。纯 SwiftUI：文本截断与空值兜底
/// 已在 `LyricsShareCard.displayFields` 完成，这里只做视觉排版。
struct LyricsShareCardView: View {
    let card: LyricsShareCard
    /// 封面缩略图（可空；UI 层传 MusicController.shared.artwork）。
    var artwork: NSImage?

    var body: some View {
        let fields = card.displayFields
        ZStack(alignment: .topLeading) {
            // 背景：深色玻璃底 + 左上品牌角标
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(white: 0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                )

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    if let artwork {
                        Image(nsImage: artwork)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fields.title)
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        if !fields.artist.isEmpty {
                            Text(fields.artist)
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.65))
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(card.branding)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.4))
                }

                Divider().opacity(0.15)

                VStack(alignment: .leading, spacing: 8) {
                    Text(fields.original)
                        .font(.system(size: 22, weight: .medium, design: .rounded))
                        .foregroundColor(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    if let tr = fields.translation {
                        Text(tr)
                            .font(.system(size: 15, weight: .regular))
                            .foregroundColor(Color.cyan.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(24)
        }
        .frame(width: 480, height: 260)
    }
}

/// 把卡片 View 渲染成 NSImage（macOS 13+ ImageRenderer；旧系统给出空图兜底）。
@MainActor
enum LyricsCardExporter {
    /// 把卡片渲染为 NSImage。失败返回 nil（调用方禁用分享按钮）。
    static func render(_ card: LyricsShareCard, artwork: NSImage?) -> NSImage? {
        if #available(macOS 13.0, *) {
            let view = LyricsShareCardView(card: card, artwork: artwork)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2.0
            return renderer.nsImage
        }
        return nil
    }

    /// 打开系统分享面板（NSSharingService）。无可用服务时静默失败。
    @MainActor
    static func share(_ image: NSImage, fileName: String, from view: NSView?, rect: NSRect) {
        // 用 NSSharingServicePicker（macOS 13+ 推荐路径）：不 deprecated，
        // 由系统弹出包含 AirDrop / 邮件 / 备忘录等所有服务的标准面板。
        let picker = NSSharingServicePicker(items: [image])
        picker.show(relativeTo: rect, of: view ?? NSView(), preferredEdge: .minY)
    }
}
