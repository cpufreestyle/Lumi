// =====================================================
//  license-tool — 激活码签发工具（服务端 / 运营侧使用）
//
//  ⚠️ 本目标不参与 Lumi.app 打包，私钥只存在于此工具与
//     secrets/license_private_key.b64（已 gitignore）中。
//     App 二进制内仅有 Ed25519 公钥，无法伪造激活码。
//
//  用法（在 Lumi 仓库根目录执行）：
//    swift run license-tool genkey                生成新密钥对，写入 secrets 并打印公钥
//    swift run license-tool gen --months 12       生成 12 个月有效期的激活码（LUMI1-）
//    swift run license-tool gen --lifetime         生成永久激活码（LUMI1-）
//    swift run license-tool gen-legacy             生成旧版 CRC16 激活码（LUMI-XXXX-...，仅测试）
//    swift run license-tool redeem --old-key <旧码> --order <订单号> --device <设备ID> [--months N | --lifetime]
//                                               旧码换发，签发绑定设备的新码（LUMI2-）
//    swift run license-tool revoke-list <path>    生成/更新签名吊销清单（secrets/revocations.lumi）
//    swift run license-tool gen-feed-key          生成市场 feed 签名密钥对（独立于激活码密钥）
//    swift run license-tool sign-feed <path>      对插件市场 feed JSON 签名（写入 signature 字段）
//    LUMI_LICENSE_PRIVATE_KEY=<b64> swift run license-tool gen ...
//    订单白名单（生产必设）：export LUMI_VALID_ORDERS=ORD-001,ORD-002
// =====================================================
import Foundation
import CryptoKit

struct LicenseTool {
    func run(arguments: [String]) {
        guard let command = arguments.first else { printUsage(); return }
        switch command {
        case "genkey":
            generateKeyPair()
        case "gen":
            generateLicense(args: Array(arguments.dropFirst()))
        case "gen-legacy":
            generateLegacyKey()
        case "redeem":
            redeemLicense(args: Array(arguments.dropFirst()))
        case "verify":
            verifyLicense(args: Array(arguments.dropFirst()))
        case "pubkey":
            let key = loadPrivateKey()
            print(key.publicKey.rawRepresentation.base64EncodedString())
        case "revoke-list":
            revokeList(args: Array(arguments.dropFirst()))
        case "gen-feed-key":
            generateFeedKeyPair()
        case "sign-feed":
            signFeed(args: Array(arguments.dropFirst()))
        default:
            printUsage()
        }
    }

    // MARK: - 密钥对生成
    private func generateKeyPair() {
        let key = Curve25519.Signing.PrivateKey()
        let privB64 = key.rawRepresentation.base64EncodedString()
        let pubB64 = key.publicKey.rawRepresentation.base64EncodedString()

        // 写入私钥到 secrets/（相对仓库根目录运行）
        let url = URL(fileURLWithPath: "secrets/license_private_key.b64")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try privB64.write(to: url, atomically: true, encoding: .utf8)
            print("✅ 私钥已写入: \(url.path)")
        } catch {
            fputs("⚠️ 无法写入私钥文件（\(error)），请手动保存下面的私钥。\n", stderr)
        }

        print("")
        print("----- 请将以下【公钥】嵌入 LicenseManager.licensePublicKey -----")
        print(pubB64)
        print("---------------------------------------------------------------")
        print("【私钥】务必离线保管，切勿提交或打包进 App：")
        print(privB64)
    }

    // MARK: - Feed 签名（市场插件清单，独立于激活码密钥对）

    private var feedPrivateKeyURL: URL {
        URL(fileURLWithPath: "secrets/feed_signing_private_key.b64")
    }

    private func generateFeedKeyPair() {
        let key = Curve25519.Signing.PrivateKey()
        let privB64 = key.rawRepresentation.base64EncodedString()
        let pubB64 = key.publicKey.rawRepresentation.base64EncodedString()
        do {
            try FileManager.default.createDirectory(at: feedPrivateKeyURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try privB64.write(to: feedPrivateKeyURL, atomically: true, encoding: .utf8)
            print("✅ feed 签名私钥已写入: \(feedPrivateKeyURL.path)")
        } catch {
            fputs("⚠️ 无法写入私钥文件（\(error)），请手动保存下面的私钥。\n", stderr)
        }
        print("")
        print("----- 请将以下【公钥】嵌入 PluginMarketplace.officialFeedPublicKey -----")
        print(pubB64)
        print("-----------------------------------------------------------------------")
    }

    private func loadFeedPrivateKey() -> Curve25519.Signing.PrivateKey? {
        if let env = ProcessInfo.processInfo.environment["LUMI_FEED_SIGNING_PRIVATE_KEY"],
           let raw = Data(base64Encoded: env) {
            return try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        }
        guard let b64 = try? String(contentsOf: feedPrivateKeyURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let raw = Data(base64Encoded: b64) else { return nil }
        return try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    }

    /// 对插件市场 feed 签名：canonical 化 plugins 数组（JSONSerialization + .sortedKeys，
    /// 与 App 侧 PluginMarketplace.canonicalPluginsData 完全一致）后 Ed25519 签名，
    /// 将 signature 字段写回原文件（prettyPrinted + sortedKeys 格式化输出）。
    private func signFeed(args: [String]) {
        guard let path = args.first else {
            fputs("用法: swift run license-tool sign-feed <plugin-feed.json>\n", stderr)
            return
        }
        guard let key = loadFeedPrivateKey() else {
            fputs("❌ 未找到 feed 签名私钥。请先运行 `swift run license-tool gen-feed-key` 生成，\n   或设置环境变量 LUMI_FEED_SIGNING_PRIVATE_KEY=<私钥base64>。\n", stderr)
            return
        }
        let url = URL(fileURLWithPath: path)
        do {
            let raw = try Data(contentsOf: url)
            guard var obj = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
                  let plugins = obj["plugins"] else {
                fputs("❌ \(path) 不是合法的 feed JSON（缺少 plugins 数组）。\n", stderr)
                return
            }
            let canonical = try JSONSerialization.data(withJSONObject: plugins, options: [.sortedKeys])
            let sig = try key.signature(for: canonical)
            obj["signature"] = sig.base64EncodedString()
            let out = try JSONSerialization.data(withJSONObject: obj,
                                                 options: [.prettyPrinted, .sortedKeys])
            try out.write(to: url, options: .atomic)
            print("✅ 已签名并写回: \(url.path)")
        } catch {
            fputs("❌ 签名失败: \(error)\n", stderr)
        }
    }

    // MARK: - 读取私钥
    private func loadPrivateKey() -> Curve25519.Signing.PrivateKey {
        if let env = ProcessInfo.processInfo.environment["LUMI_LICENSE_PRIVATE_KEY"],
           let raw = Data(base64Encoded: env.trimmingCharacters(in: .whitespacesAndNewlines)),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
            return key
        }
        let url = URL(fileURLWithPath: "secrets/license_private_key.b64")
        if let str = try? String(contentsOf: url, encoding: .utf8),
           let raw = Data(base64Encoded: str.trimmingCharacters(in: .whitespacesAndNewlines)),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
            return key
        }
        fputs("❌ 未找到私钥。请先运行 `swift run license-tool genkey` 生成，\n   或设置环境变量 LUMI_LICENSE_PRIVATE_KEY=<私钥base64>。\n", stderr)
        exit(1)
    }

    // MARK: - 生成激活码
    private func generateLicense(args: [String]) {
        let key = loadPrivateKey()

        var lifetime = false
        var months: Int?
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--lifetime": lifetime = true
            case "--months" where i + 1 < args.count:
                months = Int(args[i + 1]); i += 1
            default: break
            }
            i += 1
        }

        let exp: TimeInterval
        if lifetime {
            exp = 0
        } else {
            let m = months ?? 12
            exp = Calendar.current.date(byAdding: .month, value: m, to: Date())!.timeIntervalSince1970
        }

        let payload = licensePayload(lifetime: lifetime, exp: exp)
        let signature: Data
        do { signature = try key.signature(for: payload) }
        catch { fputs("❌ 签名失败: \(error)\n", stderr); exit(1) }

        let code = "LUMI1-\(payload.base64EncodedString())-\(signature.base64EncodedString())"
        print(code)
    }

    private func licensePayload(lifetime: Bool, exp: TimeInterval) -> Data {
        let nonce = (0..<8).map { _ in String(format: "%02X", UInt8.random(in: 0...255)) }.joined()
        let dict: [String: Any] = [
            "v": 1,
            "life": lifetime,
            "exp": Int(exp),
            "n": nonce
        ]
        return try! JSONSerialization.data(withJSONObject: dict)
    }

    // MARK: - 旧版激活码生成（仅工具侧，用于测试与向后兼容演示；不进 App）

    /// 生成旧版 CRC16 格式 LUMI-XXXX-XXXX-XXXX-XXXX（用于 redeem 测试）
    private func generateLegacyKey() {
        let seg1 = String(format: "%04X", UInt16.random(in: 0x1000...0xFFFE))
        let seg2 = String(format: "%04X", UInt16.random(in: 0x1000...0xFFFE))
        let seg3 = String(format: "%04X", UInt16.random(in: 0x1000...0xFFFE))
        let dataStr = seg1 + seg2 + seg3
        let crc = crc16(dataStr.data(using: .ascii)!)
        let seg4 = String(format: "%04X", crc)
        print("LUMI-\(seg1)-\(seg2)-\(seg3)-\(seg4)")
    }

    private func crc16(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                if (crc & 0x8000) != 0 { crc = (crc << 1) ^ 0x1021 }
                else { crc <<= 1 }
            }
        }
        return crc & 0xFFFF
    }

    /// 校验旧码（CRC16 格式/校验和）。仅服务端工具保留该算法。
    private func validateLegacyKey(_ key: String) -> Bool {
        let cleaned = key.replacingOccurrences(of: "LUMI-", with: "")
                        .replacingOccurrences(of: "-", with: "")
                        .uppercased()
        guard cleaned.count == 16, cleaned.allSatisfy({ $0.isHexDigit }) else { return false }
        let segments = stride(from: 0, to: cleaned.count, by: 4).map {
            String(cleaned[cleaned.index(cleaned.startIndex, offsetBy: $0)..<min(cleaned.index(cleaned.startIndex, offsetBy: $0 + 4), cleaned.endIndex)])
        }
        guard segments.count == 4 else { return false }
        let expected = String(format: "%04X", crc16((segments[0] + segments[1] + segments[2]).data(using: .ascii)!))
        return segments[3] == expected
    }

    // MARK: - 换发状态（防重放 / 设备上限 / 旧码一次性）
    private struct RedeemState: Codable {
        var orders: [String: [String]] = [:]   // 订单号 -> 已绑定设备列表
        var nonces: [String] = []              // 已消费的防重放 nonce
        var redeemedOldKeys: [String] = []      // 已换发的旧激活码（一次性）
    }

    private func loadRedeemState() -> RedeemState {
        let url = URL(fileURLWithPath: "secrets/redeem_state.json")
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(RedeemState.self, from: data) else { return RedeemState() }
        return s
    }

    private func saveRedeemState(_ state: RedeemState) {
        let url = URL(fileURLWithPath: "secrets/redeem_state.json")
        let enc = JSONEncoder()
        enc.outputFormatting = .prettyPrinted
        guard let data = try? enc.encode(state),
              let str = String(data: data, encoding: .utf8) else { return }
        try? str.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - 旧码换发（模拟服务端 /v1/redeem）

    /// 校验旧码 + 订单号，用私钥签发绑定设备的新 LUMI2- 码。
    /// 实际生产应由后端服务暴露 HTTP 接口，工具侧实现仅作本地闭环演示。
    private func redeemLicense(args: [String]) {
        var oldKey: String?, order: String?, device: String?
        var lifetime = false
        var months: Int?
        var nonce: String?
        var deviceLimit = Int(ProcessInfo.processInfo.environment["LUMI_DEVICE_LIMIT"] ?? "") ?? 2
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--old-key" where i + 1 < args.count: oldKey = args[i + 1]; i += 1
            case "--order"  where i + 1 < args.count: order = args[i + 1]; i += 1
            case "--device" where i + 1 < args.count: device = args[i + 1]; i += 1
            case "--nonce"  where i + 1 < args.count: nonce = args[i + 1]; i += 1
            case "--device-limit" where i + 1 < args.count:
                deviceLimit = Int(args[i + 1]) ?? deviceLimit; i += 1
            case "--lifetime": lifetime = true
            case "--months"  where i + 1 < args.count: months = Int(args[i + 1]); i += 1
            default: break
            }
            i += 1
        }

        // 服务端(CGI/HTTP handler)调用场景:参数经环境变量传入,
        // 避免 argv 注入(CWE-88)。CLI 交互用法不受影响。
        if oldKey == nil || order == nil || device == nil {
            let env = ProcessInfo.processInfo.environment
            oldKey = oldKey ?? env["LUMI_REDEEM_OLD_KEY"]
            order = order ?? env["LUMI_REDEEM_ORDER"]
            device = device ?? env["LUMI_REDEEM_DEVICE"]
            if nonce == nil { nonce = env["LUMI_REDEEM_NONCE"] }
        }
        guard let oldKey, let order, let device else {
            fputs("❌ 用法: license-tool redeem --old-key <旧码> --order <订单号> --device <设备ID> [--nonce <uuid>] [--device-limit N] [--months N | --lifetime]\n", stderr)
            exit(1)
        }

        // 0) 旧码一次性：已换发过的旧码禁止重复换发
        var state = loadRedeemState()
        if state.redeemedOldKeys.contains(oldKey) {
            fputs("❌ 该旧激活码已换发过，不能重复换发。\n", stderr)
            exit(15)
        }

        // 0.5) 防重放：同一 nonce 重复使用拒绝
        if let nonce, !nonce.isEmpty, state.nonces.contains(nonce) {
            fputs("❌ 请求 nonce 重复，疑似重放，已拒绝。\n", stderr)
            exit(14)
        }

        // 1) 校验旧码（CRC16）
        guard validateLegacyKey(oldKey) else {
            fputs("❌ 旧激活码无效（格式或校验和错误）。\n", stderr)
            exit(2)
        }

        // 2) 校验订单号（初期：环境变量 LUMI_VALID_ORDERS 白名单；未设置则放行，生产必须设置）
        if let whitelist = ProcessInfo.processInfo.environment["LUMI_VALID_ORDERS"] {
            let valid = whitelist.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if !valid.contains(order) {
                fputs("❌ 订单号 \(order) 不在有效清单中。\n", stderr)
                exit(3)
            }
        } else {
            fputs("⚠️ 未设置 LUMI_VALID_ORDERS，订单号校验跳过（仅限本地/测试）。\n", stderr)
        }

        // 2.5) 设备上限：同一订单已绑定设备数达上限则拒绝
        var devices = state.orders[order] ?? []
        if !devices.contains(device) {
            guard devices.count < deviceLimit else {
                fputs("❌ 该订单已达设备上限（\(deviceLimit)），无法换发更多设备。\n", stderr)
                exit(17)
            }
            devices.append(device)
            state.orders[order] = devices
        }

        // 3) 用私钥签发绑定设备的 LUMI2- 码
        let key = loadPrivateKey()
        let exp: TimeInterval = lifetime ? 0 :
            Calendar.current.date(byAdding: .month, value: months ?? 12, to: Date())!.timeIntervalSince1970

        let freshNonce = (0..<8).map { _ in String(format: "%02X", UInt8.random(in: 0...255)) }.joined()
        let dict: [String: Any] = [
            "v": 2, "life": lifetime, "exp": Int(exp),
            "n": freshNonce, "dev": device
        ]
        let payload = try! JSONSerialization.data(withJSONObject: dict)
        let signature: Data
        do { signature = try key.signature(for: payload) }
        catch { fputs("❌ 签名失败: \(error)\n", stderr); exit(1) }

        let code = "LUMI2-\(payload.base64EncodedString())-\(signature.base64EncodedString())"

        // 4) 持久化状态（仅成功签名后写入）
        if let nonce, !nonce.isEmpty { state.nonces.append(nonce) }
        state.redeemedOldKeys.append(oldKey)
        saveRedeemState(state)
        print(code)
    }

    // MARK: - 验码（模拟 App 侧，使用内嵌公钥）

    /// App 内嵌的 Ed25519 公钥（与 LicenseManager.licensePublicKey 保持一致）。
    /// 注意：这是公钥，可公开；用于本地验证换发/签发产物是否与 App 期望一致。
    private let appLicensePublicKeyBase64 = "OjfYkzCzO8ZjHJxCJOG0gI2O0fMeXtaCWSCcM573HlI="

    /// 用 App 内嵌公钥校验激活码（LUMI1-/LUMI2-），并报告有效期与设备绑定。
    /// 用法: license-tool verify <激活码> [--device <本机设备ID>]
    private func verifyLicense(args: [String]) {
        guard let code = args.first, !code.isEmpty else {
            fputs("❌ 用法: license-tool verify <激活码> [--device <本机设备ID>]\n", stderr)
            exit(1)
        }
        let deviceArg = args.dropFirst().first { $0 == "--device" }.flatMap { _ in
            args.dropFirst().dropFirst().first
        }

        // 仅规范化前缀大小写；base64 的 payload/signature 大小写敏感，不可整体大写
        // （与 LicenseManager.validateLicenseKey 行为一致）
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.components(separatedBy: "-")
        let prefix = parts.first?.uppercased() ?? ""
        guard ["LUMI1", "LUMI2"].contains(prefix), parts.count == 3 else {
            print("INVALID_FORMAT"); exit(1)
        }
        guard let payload = Data(base64Encoded: parts[1]),
              let signature = Data(base64Encoded: parts[2]) else {
            print("INVALID_BASE64"); exit(1)
        }
        guard let raw = Data(base64Encoded: appLicensePublicKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
              let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
            fputs("❌ 内嵌公钥不可用。\n", stderr); exit(1)
        }

        guard pub.isValidSignature(signature, for: payload) else {
            print("SIGNATURE_INVALID"); exit(2)
        }

        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            print("PAYLOAD_INVALID"); exit(3)
        }
        let life = json["life"] as? Bool == true
        let exp = json["exp"] as? Int ?? 0
        let dev = json["dev"] as? String
        let expired = !life && exp > 0 && exp < Int(Date().timeIntervalSince1970)
        var deviceOK = true
        if prefix == "LUMI2", let bound = dev, let expect = deviceArg {
            deviceOK = (bound == expect)
        }

        let expStr: String
        if life {
            expStr = "永久"
        } else if expired {
            expStr = "已过期 (\(Date(timeIntervalSince1970: TimeInterval(exp))))"
        } else {
            expStr = "\(Date(timeIntervalSince1970: TimeInterval(exp)))"
        }

        print("VALID")
        print("  prefix : \(prefix)")
        print("  life   : \(life)")
        print("  exp    : \(expStr)")
        print("  dev    : \(dev ?? "(无)")")
        if prefix == "LUMI2" { print("  deviceOK: \(deviceOK)") }
        if expired || !deviceOK { exit(4) }
    }

    // MARK: - 吊销清单签发（仅工具侧，服务端离线生成后用私钥签名）

    /// 生成签名的吊销清单 LUMIRL-<payload>-<sig>。
    /// 用法: license-tool revoke-list --nonces N1,N2,N3 [--reason compromise] [--out <path>]
    ///   默认写入 secrets/revocations.lumi（server.js 的 /api/revocations 直接提供该文件）。
    private func revokeList(args: [String]) {
        var nonces: [String] = []
        var reason = "compromise"
        var outPath: String?
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--nonces" where i + 1 < args.count:
                nonces = args[i + 1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                i += 1
            case "--reason" where i + 1 < args.count:
                reason = args[i + 1]; i += 1
            case "--out" where i + 1 < args.count:
                outPath = args[i + 1]; i += 1
            default: break
            }
            i += 1
        }
        guard !nonces.isEmpty else {
            fputs("❌ 用法: license-tool revoke-list --nonces N1,N2,N3 [--reason compromise] [--out <path>]\n", stderr)
            exit(1)
        }

        let now = Int(Date().timeIntervalSince1970)
        let entries: [[String: Any]] = nonces.map { ["n": $0, "ts": now, "reason": reason] }
        let dict: [String: Any] = ["v": 1, "ts": now, "entries": entries]
        let payload = try! JSONSerialization.data(withJSONObject: dict)
        let key = loadPrivateKey()
        let signature: Data
        do { signature = try key.signature(for: payload) }
        catch { fputs("❌ 签名失败: \(error)\n", stderr); exit(1) }

        let signed = "LUMIRL-\(payload.base64EncodedString())-\(signature.base64EncodedString())"
        let out = outPath ?? "secrets/revocations.lumi"
        do {
            try signed.write(to: URL(fileURLWithPath: out), atomically: true, encoding: .utf8)
            print("✅ 吊销清单已写入: \(out)")
        } catch {
            fputs("⚠️ 无法写入 \(out)（\(error)），仅打印到 stdout。\n", stderr)
        }
        print(signed)
    }

    private func printUsage() {
        fputs("""
        用法:
          swift run license-tool genkey                 生成密钥对（私钥写入 secrets/）
          swift run license-tool gen --months <N>       生成 N 个月有效期激活码（默认 12，LUMI1-）
          swift run license-tool gen --lifetime         生成永久激活码（LUMI1-）
          swift run license-tool gen-legacy             生成旧版 CRC16 激活码（仅测试）
          swift run license-tool redeem --old-key <码> --order <订单号> --device <设备ID> [--nonce <uuid>] [--device-limit N] [--months N | --lifetime]
                                                    旧码换发，签发绑定设备的新码（LUMI2-）
          swift run license-tool verify <激活码> [--device <本机设备ID>]
                                                    用 App 内嵌公钥校验（验签/有效期/设备绑定）
          swift run license-tool revoke-list --nonces N1,N2,N3 [--reason compromise]
                                                    签发签名吊销清单（写入 secrets/revocations.lumi）
          LUMI_LICENSE_PRIVATE_KEY=<b64> swift run license-tool gen ...
          订单白名单（生产必设）：export LUMI_VALID_ORDERS=ORD-001,ORD-002

        """, stderr)
    }
}

LicenseTool().run(arguments: Array(CommandLine.arguments.dropFirst()))
