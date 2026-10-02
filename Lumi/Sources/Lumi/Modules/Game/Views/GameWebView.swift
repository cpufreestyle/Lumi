import AppKit
import SwiftUI
import WebKit

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
                // 若当前处于游戏模块的键盘捕获态，页面加载完成后立即把焦点交给 WebView，
                // 使其能接收键盘（方向键/字母键）控制 H5 小游戏。
                if AppState.shared.activeModule == .game {
                    webView.becomeFirstResponder()
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.controller.isLoading = false
                // 网页加载失败常是本机代理/证书问题：统一中文文案，避免直接抛英文原串。
                self.parent.controller.loadError = NetworkErrorText.describe(error)
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.controller.isLoading = false
                self.parent.controller.loadError = NetworkErrorText.describe(error)
            }
        }
    }
}
