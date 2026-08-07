# 示例测试（零依赖，必过）

放在 `Tests/LumiTests/LumiCoreTests.swift`。不依赖 AppKit/SwiftUI，
仅用 Foundation + CryptoKit，可在无登录会话下编译运行。

```swift
import XCTest
import CryptoKit

final class LumiCoreTests: XCTestCase {

    private func sha256(_ s: String) -> String {
        Data(CryptoKit.SHA256.hash(data: Data(s.utf8)))
            .map { String(format: "%02x", $0) }.joined()
    }

    func testSHA256_isDeterministic() {
        XCTAssertEqual(sha256("Lumi"), sha256("Lumi"))
    }

    func testSHA256_knownVector() {
        XCTAssertEqual(
            sha256("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testEd25519_signAndVerify_roundTrip() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let message = "LUMI2-device-123".data(using: .utf8)!
        let sig = try privateKey.signature(for: message)
        XCTAssertTrue(privateKey.publicKey.isValidSignature(sig, for: message))
    }

    func testEd25519_rejectsTamperedMessage() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let message = "hello".data(using: .utf8)!
        let sig = try privateKey.signature(for: message)
        XCTAssertFalse(privateKey.publicKey.isValidSignature(sig, for: "HELLO".data(using: .utf8)!))
    }
}
```

运行：

```bash
cd Lumi
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test
# 期望：Executed 5 tests, with 0 failures
```
