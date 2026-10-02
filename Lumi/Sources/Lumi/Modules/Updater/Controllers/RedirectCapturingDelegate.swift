import AppKit
import Combine
import Foundation

/// 拦截 HTTP 重定向的轻量 delegate：不自动跟随 302，
/// 从而让上层能从响应头读取 Location（含最新版本号），避开 api.github.com 限流。
/// URLSession 重定向捕获代理。
/// 拆分为独立文件后需要 module 内可见（仅 Updater 使用）。
final class RedirectCapturingDelegate: NSObject, URLSessionDataDelegate {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // 返回 nil = 不跟随重定向，response 仍会照常回调给 dataTask 的 completion
        completionHandler(nil)
    }
}
