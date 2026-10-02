import XCTest
import Foundation
@testable import Lumi

/// 证书 / TLS 类网络错误的识别与文案测试。
///
/// 这类错误的用户现场表现是界面上冒出 `unknown certificate verification error`
/// 这类英文原串（Secure Transport 的 OSStatus 原文），既无法行动也无法判断归属，
/// 因此必须在本层就识别出来并转成可操作的中文。
final class NetworkErrorTextTests: XCTestCase {

    // MARK: - 识别

    func testRecognizesCertificateFailures() {
        // 代理做 TLS 中间人时最常见的 -1202（证书不受信）
        let untrusted = NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted)
        XCTAssertTrue(NetworkErrorText.isCertificateFailure(untrusted))

        // 证书过期 / 尚未生效 / 根未知 / 客户端证书被拒
        XCTAssertTrue(NetworkErrorText.isCertificateFailure(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateHasBadDate)))
        XCTAssertTrue(NetworkErrorText.isCertificateFailure(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateHasUnknownRoot)))
        XCTAssertTrue(NetworkErrorText.isCertificateFailure(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorClientCertificateRejected)))
        XCTAssertTrue(NetworkErrorText.isCertificateFailure(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed)))

        // 只把 Secure Transport 码塞在 underlying 里的形态（-9813）
        let wrapped = NSError(domain: NSURLErrorDomain, code: -1, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -9813)
        ])
        XCTAssertTrue(NetworkErrorText.isCertificateFailure(wrapped))
    }

    func testDoesNotMisclassifyOtherFailures() {
        // 超时 / 连不上 / 取消都不是证书问题：若判成证书问题，主机会被误冷却 15 分钟
        XCTAssertFalse(NetworkErrorText.isCertificateFailure(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)))
        XCTAssertFalse(NetworkErrorText.isCertificateFailure(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)))
        XCTAssertFalse(NetworkErrorText.isCertificateFailure(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))
        XCTAssertFalse(NetworkErrorText.isCertificateFailure(
            NSError(domain: NSURLErrorDomain, code: 500)))
    }

    // MARK: - 文案

    func testDescribeGivesActionableChineseForCertificateError() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted)
        let text = NetworkErrorText.describe(error)
        XCTAssertTrue(text.contains("证书"), text)
        XCTAssertTrue(text.contains("代理"), text)   // 给出可行动方向
        XCTAssertFalse(text.isEmpty)
    }

    func testDescribePassesThroughOrdinaryError() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
                            userInfo: [NSLocalizedDescriptionKey: "请求超时"])
        XCTAssertEqual(NetworkErrorText.describe(error), "请求超时")
    }
}
