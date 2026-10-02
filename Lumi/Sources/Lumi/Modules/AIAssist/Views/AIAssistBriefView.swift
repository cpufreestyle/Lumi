import AppKit
import SwiftUI

struct AIAssistBriefView: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 12))
                .foregroundColor(PanelInk.pink)
            Text("划词 AI · 复制即问")
                .font(.system(size: 12))
                .foregroundColor(PanelInk.text(0.7))
        }
    }
}
