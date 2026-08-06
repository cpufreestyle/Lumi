// =====================================================
//  license-tool — 激活码签发工具（服务端 / 运营侧使用）
//
//  ⚠️ 本目标不参与 Lumi.app 打包，私钥只存在于此工具与
//     secrets/license_private_key.b64（已 gitignore）中。
//     App 二进制内仅有 Ed25519 公钥，无法伪造激活码。
//
//  用法（在 Lumi 仓库根目录执行）：
//    swift run license-tool genkey                生成新密钥对，写入 secrets 并打印公钥
//    swift run license-tool gen --months 12       生成 12 个月有效期的激活码
//    swift run license-tool gen --lifetime         生成永久激活码
//    LUMI_LICENSE_PRIVATE_KEY=<b64> swift run license-tool gen --months 6
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

    private func printUsage() {
        fputs("""
        用法:
          swift run license-tool genkey                 生成密钥对（私钥写入 secrets/）
          swift run license-tool gen --months <N>       生成 N 个月有效期激活码（默认 12）
          swift run license-tool gen --lifetime         生成永久激活码
          LUMI_LICENSE_PRIVATE_KEY=<b64> swift run license-tool gen ...

        """, stderr)
    }
}

LicenseTool().run(arguments: Array(CommandLine.arguments.dropFirst()))
