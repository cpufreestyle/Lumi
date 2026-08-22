import XCTest
import CryptoKit
@testable import Lumi

/// LicenseManager 激活码验证与吊销清单解析的纯逻辑测试。
/// 注入测试密钥对与设备 ID,不触碰 LicenseManager.shared(其 init 有文件/网络副作用)。
final class LicenseValidationTests: XCTestCase {

    private var privateKey: Curve25519.Signing.PrivateKey!
    private var publicKey: Curve25519.Signing.PublicKey!

    override func setUpWithError() throws {
        privateKey = Curve25519.Signing.PrivateKey()
        publicKey = privateKey.publicKey
    }

    /// 用指定私钥构造 LUMI1-/LUMI2- 激活码字符串
    private func makeKey(prefix: String, payload: [String: Any],
                         signer: Curve25519.Signing.PrivateKey? = nil) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: payload)
        let sig = try (signer ?? privateKey).signature(for: data)
        return "\(prefix)-\(data.base64EncodedString())-\(sig.base64EncodedString())"
    }

    private func assertFailure(_ result: Result<Date?, LicenseError>, _ expected: LicenseError,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard case .failure(let err) = result else {
            return XCTFail("期望失败(\(expected)),实际成功:\(result)", file: file, line: line)
        }
        let matches: Bool
        switch (err, expected) {
        case (.invalidFormat, .invalidFormat),
             (.verificationFailed, .verificationFailed),
             (.invalid, .invalid),
             (.legacyKey, .legacyKey),
             (.deviceMismatch, .deviceMismatch):
            matches = true
        default:
            matches = false
        }
        XCTAssertTrue(matches, "期望错误类型与实际一致", file: file, line: line)
    }

    private func validate(_ key: String, deviceID: String = "device-A") -> Result<Date?, LicenseError> {
        LicenseManager.validateLicenseKey(key, publicKey: publicKey, currentDeviceID: deviceID)
    }

    // MARK: - 成功路径

    func testLifetimeKeySucceedsWithNilExpiry() throws {
        let key = try makeKey(prefix: "LUMI1", payload: ["v": 1, "life": true, "n": "nonce-1"])
        guard case .success(let expiry) = validate(key) else {
            return XCTFail("永久许可激活码应验证通过")
        }
        XCTAssertNil(expiry, "life=true 时到期日应为 nil")
    }

    func testExpiryKeySucceedsWithDate() throws {
        let ts: TimeInterval = 2_000_000_000
        let key = try makeKey(prefix: "LUMI1", payload: ["v": 1, "exp": ts, "n": "nonce-2"])
        guard case .success(let expiry) = validate(key) else {
            return XCTFail("限期激活码应验证通过")
        }
        XCTAssertEqual(expiry?.timeIntervalSince1970, ts, "到期日应与 payload 中的 exp 一致")
    }

    func testWhitespaceAroundKeyIsTrimmed() throws {
        let key = try makeKey(prefix: "LUMI1", payload: ["v": 1, "life": true, "n": "n"])
        guard case .success = validate("  \(key) \n") else {
            return XCTFail("前后空白应被容忍")
        }
    }

    // MARK: - 格式与旧版识别

    func testGarbageInputFailsFormat() {
        assertFailure(validate("not-a-key"), .invalidFormat)
    }

    func testTwoSegmentKeyFailsFormat() {
        assertFailure(validate("LUMI1-onlypayload"), .invalidFormat)
    }

    func testLegacyCRCKeyDetected() {
        assertFailure(validate("LUMI-1234-ABCD-5678-EF90"), .legacyKey)
    }

    // MARK: - 验签

    func testSignatureFromWrongKeyRejected() throws {
        let otherKey = Curve25519.Signing.PrivateKey()
        let key = try makeKey(prefix: "LUMI1",
                              payload: ["v": 1, "life": true, "n": "n"],
                              signer: otherKey)
        assertFailure(validate(key), .verificationFailed)
    }

    func testMissingPublicKeyRejected() throws {
        let key = try makeKey(prefix: "LUMI1", payload: ["v": 1, "life": true, "n": "n"])
        let result = LicenseManager.validateLicenseKey(key, publicKey: nil, currentDeviceID: "d")
        assertFailure(result, .verificationFailed)
    }

    func testValidSignatureButNonJSONPayloadIsInvalid() throws {
        let data = Data("definitely not json".utf8)
        let sig = try privateKey.signature(for: data)
        let key = "LUMI1-\(data.base64EncodedString())-\(sig.base64EncodedString())"
        assertFailure(validate(key), .invalid)
    }

    func testPayloadWithoutLifeOrExpIsInvalid() throws {
        let key = try makeKey(prefix: "LUMI1", payload: ["v": 1, "n": "n"])
        assertFailure(validate(key), .invalid)
    }

    // MARK: - 设备绑定(仅 LUMI2)

    func testLUMI2DeviceMatchSucceeds() throws {
        let key = try makeKey(prefix: "LUMI2",
                              payload: ["v": 1, "life": true, "dev": "device-A", "n": "n"])
        guard case .success = validate(key, deviceID: "device-A") else {
            return XCTFail("dev 与本机一致时应通过")
        }
    }

    func testLUMI2DeviceMismatchRejected() throws {
        let key = try makeKey(prefix: "LUMI2",
                              payload: ["v": 1, "life": true, "dev": "device-B", "n": "n"])
        assertFailure(validate(key, deviceID: "device-A"), .deviceMismatch)
    }

    func testLUMI1IgnoresDeviceBinding() throws {
        // LUMI1 不做设备绑定:即使 payload 带 dev 字段也不校验
        let key = try makeKey(prefix: "LUMI1",
                              payload: ["v": 1, "life": true, "dev": "device-B", "n": "n"])
        guard case .success = validate(key, deviceID: "device-A") else {
            return XCTFail("LUMI1 不应做设备绑定校验")
        }
    }

    // MARK: - 吊销清单解析

    private func makeRevocationList(entries: [[String: Any]], ts: TimeInterval = 123) throws -> String {
        let payload = try JSONSerialization.data(withJSONObject: ["v": 1, "ts": ts, "entries": entries])
        let sig = try privateKey.signature(for: payload)
        return "LUMIRL-\(payload.base64EncodedString())-\(sig.base64EncodedString())"
    }

    func testParseRevocationListValid() throws {
        let raw = try makeRevocationList(entries: [["n": "a", "ts": 1], ["n": "b", "ts": 2]])
        guard let (nonces, ts) = LicenseManager.parseRevocationList(raw, publicKey: publicKey) else {
            return XCTFail("合法签名清单应解析成功")
        }
        XCTAssertEqual(nonces, ["a", "b"])
        XCTAssertEqual(ts, 123)
    }

    func testParseRevocationListTamperedSignatureRejected() throws {
        var raw = try makeRevocationList(entries: [["n": "a"]])
        // 篡改签名末位
        raw = String(raw.dropLast()) + "A"
        XCTAssertNil(LicenseManager.parseRevocationList(raw, publicKey: publicKey))
    }

    func testParseRevocationListWrongPrefixRejected() throws {
        let payload = try JSONSerialization.data(withJSONObject: ["entries": []])
        let sig = try privateKey.signature(for: payload)
        let raw = "NOTRL-\(payload.base64EncodedString())-\(sig.base64EncodedString())"
        XCTAssertNil(LicenseManager.parseRevocationList(raw, publicKey: publicKey))
    }
}
