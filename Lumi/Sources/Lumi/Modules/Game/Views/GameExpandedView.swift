import AppKit
import SwiftUI
import WebKit

struct GameExpandedView: View {
    @ObservedObject private var game = GameController.shared

    var body: some View {
        VStack(spacing: 0) {
            // 工具栏：后退 / 刷新 / 在浏览器打开
            HStack(spacing: 8) {
                Button(action: { game.goBack() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(game.canGoBack ? .white : .white.opacity(0.3))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(PanelInk.chip(0.08)))
                }
                .buttonStyle(.plain)
                .disabled(!game.canGoBack)

                Button(action: { game.reload() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(PanelInk.control)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(PanelInk.chip(0.08)))
                }
                .buttonStyle(.plain)

                Spacer()

                if game.isLoading {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 20, height: 20)
                }

                Button(action: { game.openInBrowser() }) {
                    Image(systemName: "safari")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(PanelInk.control)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(PanelInk.chip(0.08)))
                }
                .buttonStyle(.plain)
                .help("在浏览器中打开")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider().background(PanelInk.chip(0.1))

            // 网页内容
            ZStack {
                GameWebView(controller: game)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let err = game.loadError {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 28))
                            .foregroundColor(PanelInk.orange)
                        Text("加载失败")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(PanelInk.primary)
                        Text(err)
                            .font(.system(size: 10))
                            .foregroundColor(PanelInk.text(0.5))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 240)
                        Button("重试") { game.reload() }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(PanelInk.pink)
                            .buttonStyle(.plain)
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.black.opacity(0.6))
                    )
                }
            }
        }
    }
}
