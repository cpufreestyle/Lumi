import AppKit
import SwiftUI
import WebKit

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
