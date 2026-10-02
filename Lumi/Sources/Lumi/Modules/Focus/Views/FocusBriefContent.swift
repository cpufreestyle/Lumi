import SwiftUI

struct FocusBriefContent: View {
    @ObservedObject private var focus = FocusController.shared

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: focus.isRunning ? "timer" : "timer.circle")
                .font(.system(size: 12))
                .foregroundColor(focus.isRunning ? .pink : .white.opacity(0.5))
            Text(focus.isRunning ? "\(focus.timeString()) \(focus.modeLabel)" : "番茄钟 · 25 分钟")
                .font(.system(size: 12))
                .foregroundColor(PanelInk.text(0.7))
        }
    }
}
