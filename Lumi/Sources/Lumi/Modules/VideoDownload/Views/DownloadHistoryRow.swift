import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DownloadHistoryRow: View {
    let item: VideoDownloadController.DownloadItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.isCompleted
                  ? "checkmark.circle.fill"
                  : "arrow.down.circle")
                .font(.system(size: 12))
                .foregroundColor(item.isCompleted ? .green : .white.opacity(0.4))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 11))
                    .foregroundColor(PanelInk.primary)
                    .lineLimit(1)
                Text(item.format.rawValue)
                    .font(.system(size: 9))
                    .foregroundColor(PanelInk.text(0.35))
            }

            Spacer()

            if item.isCompleted, let path = item.filePath {
                Button(action: {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }) {
                    Image(systemName: "folder")
                        .font(.system(size: 10))
                        .foregroundColor(PanelInk.text(0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(PanelInk.chip(0.03))
        .cornerRadius(6)
    }
}
