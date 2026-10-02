import SwiftUI

/// 收缩态视频下载 brief：嗅探命中 / 完成闪烁 / 下载进度 / 默认文案，四态合一。
struct VideoDownloadBriefView: View {
    @ObservedObject private var vd = VideoDownloadController.shared
    @ObservedObject private var clipboard = ClipboardLinkController.shared

    private var text: String {
        if let pending = clipboard.pending { return "检测到 \(pending.hostDisplay) 链接" }
        if let flash = vd.completionFlash { return "✅ \(flash)" }
        if vd.isDownloading { return "下载中 \(Int(vd.progress * 100))%" }
        return "视频下载 MP4/MP3"
    }

    private var icon: String {
        if clipboard.pending != nil { return "link" }
        if vd.completionFlash != nil { return "checkmark.circle.fill" }
        if vd.isDownloading { return "arrow.down.circle" }
        return "arrow.down.to.line"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(PanelInk.pink)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(PanelInk.text(0.7))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
