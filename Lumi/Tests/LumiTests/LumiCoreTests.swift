import XCTest
import CryptoKit

/// 纯逻辑单元测试用例。
/// 这些用例不依赖 AppKit / SwiftUI / GUI 框架，可在无登录会话的命令行环境
/// （CI、`swift test`）下直接编译运行。
///
/// 约定：
/// - 测试文件名以 `Tests.swift` 结尾，方法以 `test` 开头。
/// - 新增纯函数（如校验、编解码、哈希）时，优先在此补用例，保证回归可见。
final class LumiCoreTests: XCTestCase {

    // MARK: - SHA-256（与 DeviceId.sha256 同算法，验证确定性 & 稳定性）

    private func sha256(_ s: String) -> String {
        Data(CryptoKit.SHA256.hash(data: Data(s.utf8)))
            .map { String(format: "%02x", $0) }.joined()
    }

    func testSHA256_isDeterministic() {
        let a = sha256("Lumi")
        let b = sha256("Lumi")
        XCTAssertEqual(a, b, "同一输入应产生相同哈希")
    }

    func testSHA256_knownVector() {
        // "abc" 的 SHA-256 标准向量，用于确认实现正确。
        XCTAssertEqual(
            sha256("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testSHA256_differentInputsDiffer() {
        XCTAssertNotEqual(sha256("a"), sha256("b"))
    }

    // MARK: - Ed25519 验签（激活码体系的核心原语）

    func testEd25519_signAndVerify_roundTrip() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey
        let message = "LUMI2-device-123".data(using: .utf8)!

        let signature = try privateKey.signature(for: message)
        XCTAssertTrue(publicKey.isValidSignature(signature, for: message))
    }

    func testEd25519_rejectsTamperedMessage() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey
        let message = "hello".data(using: .utf8)!
        let signature = try privateKey.signature(for: message)

        let tampered = "HELLO".data(using: .utf8)!
        XCTAssertFalse(publicKey.isValidSignature(signature, for: tampered))
    }
}
