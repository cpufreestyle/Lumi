import SwiftUI
import WebKit

// MARK: - TapTap 小游戏模块

/// 默认加载的 H5 小游戏地址。
/// 说明：TapTap 的游戏详情页（如 https://www.taptap.cn/app/889164 ）只是介绍/下载页，
/// 并不内嵌可玩的 H5 游戏；要在面板里「即点即玩」，需加载真正运行的 H5 承载页。
/// 这里默认用 4399《星球大合成》（与 TapTap 那款合成玩法同类，纯 H5 即点即玩、鼠标操作）。
/// 想换成 TapTap 那款的 H5 或任意其他在线小游戏，直接改这个地址即可。
let tapTapGameURL = URL(string: "https://www.4399.com/swf.htm?gamepath=//sda.4399.com/4399swf/upload_swf/ftp46/gamehwq/20240304/10/index.html")!

/// WKWebView 的 SwiftUI 封装：支持加载指定 URL、显示加载进度、刷新与后退。
struct GameWebView: NSViewRepresentable {
    @ObservedObject var controller: GameController

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // macOS 下无需特殊设置即可内联播放；这里仅确保视频播放无需先用户手势。
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        context.coordinator.webView = webView
        controller.webView = webView
        webView.load(URLRequest(url: controller.url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // URL 改变时重新加载（如用户在地址栏输入新地址）
        if nsView.url?.absoluteString != controller.url.absoluteString {
            nsView.load(URLRequest(url: controller.url))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: GameWebView
        weak var webView: WKWebView?

        init(_ parent: GameWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async { self.parent.controller.isLoading = true }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.controller.isLoading = false
                self.parent.controller.canGoBack = webView.canGoBack
                if let url = webView.url { self.parent.controller.url = url }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.controller.isLoading = false
                self.parent.controller.loadError = error.localizedDescription
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.controller.isLoading = false
                self.parent.controller.loadError = error.localizedDescription
            }
        }
    }
}

/// 游戏模块控制器：持有 WebView 引用与加载状态。
final class GameController: ObservableObject {
    static let shared = GameController()

    @Published var url: URL = tapTapGameURL
    @Published var isLoading: Bool = false
    @Published var canGoBack: Bool = false
    @Published var loadError: String? = nil

    weak var webView: WKWebView?

    func reload() { webView?.reload() }
    func goBack() { webView?.goBack() }
    func openInBrowser() { NSWorkspace.shared.open(url) }
}

// MARK: - 展开态：完整游戏面板
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
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .disabled(!game.canGoBack)

                Button(action: { game.reload() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white.opacity(0.08)))
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
                        .foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("在浏览器中打开")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider().background(Color.white.opacity(0.1))

            // 网页内容
            ZStack {
                GameWebView(controller: game)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let err = game.loadError {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 28))
                            .foregroundColor(.orange)
                        Text("加载失败")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white)
                        Text(err)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.5))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 240)
                        Button("重试") { game.reload() }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.pink)
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

// MARK: - 收缩态 / 预览：简要信息
struct GameBriefView: View {
    @ObservedObject private var game = GameController.shared

    var body: some View {
        HStack(spacing: 6) {
            if game.isLoading {
                ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
            }
            Text("TapTap 小游戏")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.7))
                .lineLimit(1)
        }
    }
}
