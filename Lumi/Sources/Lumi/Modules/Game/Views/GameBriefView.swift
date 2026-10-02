import AppKit
import SwiftUI
import WebKit

struct GameBriefView: View {
    @ObservedObject private var game = GameController.shared

    var body: some View {
        HStack(spacing: 6) {
            if game.isLoading {
                ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
            }
            Text("TapTap 小游戏")
                .font(.system(size: 12))
                .foregroundColor(PanelInk.text(0.7))
                .lineLimit(1)
        }
    }
}
