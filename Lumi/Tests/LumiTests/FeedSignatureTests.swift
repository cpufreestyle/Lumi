import XCTest
import CryptoKit
@testable import Lumi

/// 插件市场 feed 签名校验的纯逻辑测试。
/// 用测试密钥对模拟「license-tool 签发 → App 验签」的完整链路。
final class FeedSignatureTests: XCTestCase {

    private var privateKey: Curve25519.Signing.PrivateKey!
    private var publicKey: Curve25519.Signing.PublicKey!

    override func setUpWithError() throws {
        privateKey = Curve25519.Signing.PrivateKey()
        publicKey = privateKey.publicKey
    }

    /// 构造 feed JSON:{"plugins":[...], "signature": "<sig>"}
    /// 签名对 canonical 化后的 plugins 数组(与 App/license-tool 同一套字节)。
    private func makeSignedFeed(plugins: String, signer: Curve25519.Signing.PrivateKey? = nil,
                                omitSignature: Bool = false) throws -> Data {
        var obj = try JSONSerialization.jsonObject(with: Data(#"{"plugins": \#(plugins)}"#.utf8)) as! [String: Any]
        if !omitSignature {
            let canonical = try JSONSerialization.data(withJSONObject: obj["plugins"]!,
                                                       options: [.sortedKeys])
            let sig = try (signer ?? privateKey).signature(for: canonical)
            obj["signature"] = sig.base64EncodedString()
        }
        return try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }

    private func state(_ data: Data, key: Curve25519.Signing.PublicKey?) -> PluginMarketplace.FeedSignatureState {
        PluginMarketplace.feedSignatureState(rawData: data, publicKey: key)
    }

    // MARK: - 有效签名

    func testValidSignatureAccepted() throws {
        let feed = try makeSignedFeed(plugins: #"[{"id":"a.b","name":"P"}]"#)
        XCTAssertEqual(state(feed, key: publicKey), .valid)
    }

    func testCanonicalizationIsStableAcrossKeyOrder() throws {
        // 字段顺序不同但内容相同的 plugins,canonical 化后字节必须一致(签名校验的关键前提)
        let a = try makeSignedFeed(plugins: #"[{"id":"a.b","name":"P","panel":false}]"#)
        let rawB = Data(#"{"plugins": [{"panel": false, "name": "P", "id": "a.b"}]}"#.utf8)
        let ca = PluginMarketplace.canonicalPluginsData(from: a)
        let cb = PluginMarketplace.canonicalPluginsData(from: rawB)
        XCTAssertEqual(ca, cb, "键序不同、内容相同的数组 canonical 化后字节应一致")
    }

    // MARK: - 篡改与伪造

    func testTamperedPluginsRejected() throws {
        let feed = try makeSignedFeed(plugins: #"[{"id":"a.b","name":"P"}]"#)
        var obj = try JSONSerialization.jsonObject(with: feed) as! [String: Any]
        obj["plugins"] = [["id": "a.b", "name": "EVIL"]]
        let tampered = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        XCTAssertEqual(state(tampered, key: publicKey), .invalid, "改插件内容后验签必须失败")
    }

    func testSignatureFromWrongKeyRejected() throws {
        let other = Curve25519.Signing.PrivateKey()
        let feed = try makeSignedFeed(plugins: #"[{"id":"a.b","name":"P"}]"#, signer: other)
        XCTAssertEqual(state(feed, key: publicKey), .invalid)
    }

    func testMissingPublicKeyInvalid() throws {
        let feed = try makeSignedFeed(plugins: #"[{"id":"a.b","name":"P"}]"#)
        // 公钥缺失(打包错误):带签名的 feed 按无效处理,官方源不放行
        XCTAssertEqual(state(feed, key: nil), .invalid)
    }

    func testGarbageSignatureRejected() throws {
        var obj = try JSONSerialization.jsonObject(
            with: Data(#"{"plugins": []}"#.utf8)) as! [String: Any]
        obj["signature"] = "not-base64!!!"
        let feed = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        XCTAssertEqual(state(feed, key: publicKey), .invalid)
    }

    // MARK: - 未签名(社区源路径)

    func testUnsignedFeedIsMissing() throws {
        let feed = try makeSignedFeed(plugins: #"[{"id":"a.b","name":"P"}]"#, omitSignature: true)
        XCTAssertEqual(state(feed, key: publicKey), .missing,
                       "无签名字段应返回 missing(社区源放行、官方源拒绝)")
    }

    // MARK: - canonical 化健壮性

    func testCanonicalizationFailsWithoutPlugins() throws {
        let data = Data(#"{"schemaVersion": 1}"#.utf8)
        XCTAssertNil(PluginMarketplace.canonicalPluginsData(from: data))
    }

    // MARK: - 端到端:内置离线 feed 必须能通过嵌入公钥验签

    func testBundledOfflineFeedVerifiesAgainstEmbeddedPublicKey() throws {
        // license-tool sign-feed 与 App 验签走同一套 canonical 化;
        // 此测试锁住两侧字节一致性:重签工具或验签实现任一侧漂移都会立刻失败。
        let url = try XCTUnwrap(Bundle.module.url(forResource: "plugin-feed", withExtension: "json"),
                                "内置离线 feed 资源缺失")
        let raw = try Data(contentsOf: url)
        XCTAssertEqual(PluginMarketplace.feedSignatureState(rawData: raw,
                                                            publicKey: PluginMarketplace.officialFeedPublicKey),
                       .valid, "内置离线 feed 必须带有效签名且与嵌入公钥匹配")
    }
}
