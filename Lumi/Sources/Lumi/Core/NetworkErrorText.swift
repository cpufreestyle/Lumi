import Foundation

/// 网络错误的统一可读文案。
///
/// 为什么需要：`URLError.localizedDescription` 在证书校验失败时会把 Secure Transport 的
/// 原始英文串直接抛到界面上（典型表现就是 `unknown certificate verification error`）。
/// 用户看到这种串既不知道该做什么，也分不清是本机代理的问题还是目标站点的问题。
///
/// 结论性的经验：这类失败在国内网络下几乎总是「本机代理 / 网关 / 远控软件对 HTTPS 做了
/// 中间人解密」，而不是目标站点证书过期。因此文案必须给出可操作动作（把域名设为代理直连），
/// 同时让调用方能据此判定「这是机器级能力问题」，直接进入主机冷却而不是反复重试。
enum NetworkErrorText {

    /// 是否为证书 / TLS 链校验类失败（含代理中间人劫持）。
    static func isCertificateFailure(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorSecureConnectionFailed,          // -1200 TLS 握手失败
                 NSURLErrorServerCertificateHasBadDate,     // -1201 证书过期
                 NSURLErrorServerCertificateUntrusted,      // -1202 最常见：证书不受信
                 NSURLErrorServerCertificateNotYetValid,    // -1203
                 NSURLErrorServerCertificateHasUnknownRoot, // -1204
                 NSURLErrorClientCertificateRejected,       // -1205
                 NSURLErrorClientCertificateRequired:       // -1206
                return true
            default:
                break
            }
        }
        // 部分系统版本只把 Secure Transport 的 OSStatus 码塞在底层错误里；
        // -9840 ... -9800 就是 SSL/TLS 错误区间（-9813 即 unknown certificate error）。
        let candidates = [ns, ns.userInfo[NSUnderlyingErrorKey] as? NSError].compactMap { $0 }
        for candidate in candidates {
            if candidate.domain == NSOSStatusErrorDomain, (-9840 ... -9800).contains(candidate.code) {
                return true
            }
        }
        return false
    }

    /// 面向用户 / 日志的中文描述：证书类给出可操作的代理排查建议，其余保留系统文案。
    static func describe(_ error: Error) -> String {
        if isCertificateFailure(error) {
            return "证书校验失败：多半是本机代理或网关在解密 HTTPS。"
                + "请把该域名设为代理直连（或在代理里加直连规则）后重试。"
                + "（系统原文：\(error.localizedDescription)）"
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorNotConnectedToInternet {
            return "当前无网络连接：请检查网络或代理是否已开启。"
        }
        return error.localizedDescription
    }
}
