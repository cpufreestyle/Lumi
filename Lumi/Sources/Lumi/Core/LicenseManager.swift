import Foundation
import Combine
import CryptoKit
import IOKit

// MARK: - 付费功能定义
enum PremiumFeature: String, CaseIterable, Identifiable {
    case claudeCode  = "Claude Code 集成"
    case codex       = "Codex 集成"
    case videoDownload = "视频下载 MP4/MP3 (1800+ 站点)"
    case futureAI    = "未来所有 AI 功能"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .claudeCode:  return "内置 Claude AI 编程助手标签，支持代码问答与生成"
        case .codex:       return "内置 OpenAI Codex 标签，实时代码补全与生成"
        case .videoDownload: return "从 1800+ 站点下载视频为 MP4 或提取 MP3 音频"
        case .futureAI:    return "所有未来新增 AI 功能的永久访问权限"
        }
    }

    var icon: String {
        switch self {
        case .claudeCode:  return "brain.head.profile"
        case .codex:       return "wand.and.stars"
        case .videoDownload: return "arrow.down.to.line"
        case .futureAI:    return "sparkles"
        }
    }
}

// MARK: - 授权状态
enum LicenseStatus: Equatable {
    case unlicensed
    case trial(daysRemaining: Int)
    case licensed(expiryDate: Date?)
    case lifetime
    case revoked(reason: String?)
}

// MARK: - 激活错误
enum LicenseError: Error {
    case invalidFormat
    case verificationFailed
    case invalid
    /// 旧版 CRC 激活码（LUMI-XXXX-XXXX-XXXX-XXXX），授权体系升级后已失效
    case legacyKey
    /// 激活码绑定的设备与当前设备不一致（LUMI2- 的 dev 字段不匹配）
    case deviceMismatch
}

// MARK: - 授权管理器
final class LicenseManager: ObservableObject {
    static let shared = LicenseManager()

    @Published var status: LicenseStatus = .unlicensed
    @Published var isActivating: Bool = false
    @Published var activationError: String?

    /// 已解锁的功能集合
    @Published var unlockedFeatures: Set<PremiumFeature> = []

    private let licenseFileURL: URL
    private let trialDays = 7

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let lumiDir = appSupport.appendingPathComponent("Lumi")
        try? FileManager.default.createDirectory(at: lumiDir, withIntermediateDirectories: true)
        licenseFileURL = lumiDir.appendingPathComponent("license.dat")
        loadLicense()
        loadRevocationCache()
        refreshRevocations()
        // Q3: 吊销清单拉取策略 —— 每日定时拉取一次（配合启动拉取 + 面板「重新检查」）
        Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            self?.refreshRevocations()
        }
    }

    // MARK: - 公开方法

    /// 检查某个功能是否已解锁
    func isUnlocked(_ feature: PremiumFeature) -> Bool {
        switch status {
        case .licensed, .lifetime:
            return true
        case .trial:
            return unlockedFeatures.contains(feature)
        case .unlicensed, .revoked:
            return false
        }
    }

    /// 开始试用
    func startTrial() {
        let trialData: [String: Any] = [
            "type": "trial",
            "startedAt": Date().timeIntervalSince1970,
            "features": PremiumFeature.allCases.map { $0.rawValue }
        ]
        saveLicenseData(trialData)
        loadLicense()
    }

    /// 通过激活码激活
    func activate(with key: String) {
        isActivating = true
        activationError = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let result = self.validateLicenseKey(key)

            DispatchQueue.main.async {
                self.isActivating = false
                switch result {
                case .success(let expiry):
                    let nonce = self.nonceOfKey(key)
                    // 本地激活埋点（PRD 5.4）
                    let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    if normalized.hasPrefix("LUMI2-") {
                        Telemetry.shared.record(.activateLumi2)
                    } else if normalized.hasPrefix("LUMI1-") {
                        let parts = normalized.components(separatedBy: "-")
                        if let payload = Data(base64Encoded: parts[1]),
                           let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                           json["life"] as? Bool == true {
                            Telemetry.shared.record(.activateLifetime)
                        } else {
                            Telemetry.shared.record(.activateLumi1)
                        }
                    }
                    let licenseData: [String: Any] = [
                        "type": expiry == nil ? "lifetime" : "licensed",
                        "activatedAt": Date().timeIntervalSince1970,
                        "expiry": expiry?.timeIntervalSince1970 as Any,
                        "keyHash": self.sha256(key),
                        "nonce": nonce as Any
                    ]
                    self.saveLicenseData(licenseData)
                    self.loadLicense()
                case .failure(let error):
                    self.activationError = Self.errorMessage(for: error)
                }
            }
        }
    }

    // MARK: - 内部方法

    private func loadLicense() {
        guard let data = try? Data(contentsOf: licenseFileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            status = .unlicensed
            unlockedFeatures = []
            return
        }

        let storedNonce = json["nonce"] as? String

        switch type {
        case "trial":
            let started = json["startedAt"] as? TimeInterval ?? Date().timeIntervalSince1970
            let elapsed = Int((Date().timeIntervalSince1970 - started) / 86400)
            let remaining = max(0, trialDays - elapsed)

            if remaining > 0 {
                status = .trial(daysRemaining: remaining)
                if let features = json["features"] as? [String] {
                    unlockedFeatures = Set(features.compactMap { PremiumFeature(rawValue: $0) })
                } else {
                    unlockedFeatures = Set(PremiumFeature.allCases)
                }
            } else {
                status = .unlicensed
                unlockedFeatures = []
            }

        case "licensed":
            if let expiryTS = json["expiry"] as? TimeInterval {
                let expiry = Date(timeIntervalSince1970: expiryTS)
                if expiry > Date() {
                    status = .licensed(expiryDate: expiry)
                    unlockedFeatures = Set(PremiumFeature.allCases)
                } else {
                    status = .unlicensed
                    unlockedFeatures = []
                }
            } else {
                status = .licensed(expiryDate: nil)
                unlockedFeatures = Set(PremiumFeature.allCases)
            }

        case "lifetime":
            status = .lifetime
            unlockedFeatures = Set(PremiumFeature.allCases)

        default:
            status = .unlicensed
            unlockedFeatures = []
        }

        // 吊销检查：联网拉取的签名清单命中本机 nonce → 置为已吊销。
        // 离线期间沿用上一次缓存（存在最多到下次联网的吊销延迟，属已知取舍）。
        if let nonce = storedNonce, cachedRevokedNonces.contains(nonce) {
            status = .revoked(reason: nil)
            unlockedFeatures = []
        }
    }

    private func saveLicenseData(_ data: [String: Any]) {
        let json = try? JSONSerialization.data(withJSONObject: data, options: .prettyPrinted)
        try? json?.write(to: licenseFileURL, options: .atomic)
    }

    // MARK: - 授权公钥（仅验签；私钥绝不存在于本二进制内）
    /// 部署说明：
    ///   - 本常量仅为 Ed25519 公钥，无法用于伪造激活码。
    ///   - 私钥只保存在独立的 license-tool 中（读取 secrets/license_private_key.b64
    ///     或环境变量 LUMI_LICENSE_PRIVATE_KEY），不参与 App 打包。
    ///   - 若私钥泄露，需更换密钥对并重新向用户下发激活码。
    private static let licensePublicKey: Curve25519.Signing.PublicKey? = {
        let b64 = "OjfYkzCzO8ZjHJxCJOG0gI2O0fMeXtaCWSCcM573HlI="
        guard let raw = Data(base64Encoded: b64) else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }()

    /// 验证激活码（Ed25519 验签）
    /// 格式: LUMI1-<payloadBase64>-<signatureBase64>
    ///   payload 为 JSON: {"v":1,"life":<Bool>,"exp":<Unix秒, life=true 时为0>,"n":<随机串>}
    /// 因为签名必须由持有私钥的服务端生成，本地无法伪造（替换原先的纯 CRC16 校验和）。
    private func validateLicenseKey(_ key: String) -> Result<Date?, LicenseError> {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = normalized.uppercased()

        // 旧版 CRC 激活码（LUMI-XXXX-XXXX-XXXX-XXXX）：授权体系升级后已作废。
        // 提前识别，给出专门的迁移提示，而不是笼统的“格式无效”。
        if upper.hasPrefix("LUMI-") {
            let body = upper.replacingOccurrences(of: "LUMI-", with: "")
                            .replacingOccurrences(of: "-", with: "")
            let isHex = body.allSatisfy { $0.isHexDigit }
            if body.count == 16, isHex {
                return .failure(.legacyKey)
            }
        }

        let parts = normalized.components(separatedBy: "-")
        let prefix = parts[0].uppercased()
        guard parts.count == 3, ["LUMI1", "LUMI2"].contains(prefix) else {
            return .failure(.invalidFormat)
        }
        guard let payload = Data(base64Encoded: parts[1]),
              let signature = Data(base64Encoded: parts[2]) else {
            return .failure(.invalidFormat)
        }
        guard let pub = Self.licensePublicKey else {
            // 公钥缺失属于打包错误，按验证失败处理，绝不放行
            return .failure(.verificationFailed)
        }
        guard pub.isValidSignature(signature, for: payload) else {
            return .failure(.verificationFailed)
        }
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return .failure(.invalid)
        }
        // 设备绑定（仅 LUMI2-）：payload 中的 dev 必须与本机 DeviceId 一致。
        // 此检查在验签之后，攻击者无法篡改 dev（改了签名即失效）。
        if prefix == "LUMI2", let boundDev = json["dev"] as? String {
            guard boundDev == DeviceId.current else {
                return .failure(.deviceMismatch)
            }
        }
        if json["life"] as? Bool == true {
            return .success(nil)   // 永久许可
        }
        if let expTS = json["exp"] as? TimeInterval, expTS > 0 {
            return .success(Date(timeIntervalSince1970: expTS))
        }
        return .failure(.invalid)
    }

    private func sha256(_ input: String) -> String {
        guard let data = input.data(using: .utf8) else { return "" }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 吊销清单（签名清单 + 联网拉取）
    //
    // 纯离线 Ed25519 无法实时吊销。采用「服务端用私钥签名的吊销清单」：
    // 客户端联网时拉取并验签，命中本机 nonce 即失效。离线期间沿用上一次
    // 缓存（存在最多到下次联网的吊销延迟，这是该架构的已知取舍）。
    //
    // 清单格式（单行）：LUMIRL-<payloadBase64>-<signatureBase64>
    //   payload(JSON): {"v":1,"ts":<签发Unix>,"entries":[{"n":<nonce>,"ts":<吊销Unix>,"reason":<String>}]}

    private let revokedCacheKey = "lumi_revoked_list_cache"
    private var cachedRevokedNonces: Set<String> = []

    /// 联网拉取并验签吊销清单；成功则更新缓存并重新评估授权状态。
    /// 拉取/验签失败时保留上次缓存，绝不降级为「已吊销」。
    func refreshRevocations(completion: ((Bool) -> Void)? = nil) {
        let endpoint: URL
        if let override = UserDefaults.standard.string(forKey: "lumi_revocation_endpoint"),
           let u = URL(string: override.trimmingCharacters(in: .whitespacesAndNewlines)),
           u.scheme != nil {
            endpoint = u
        } else {
            endpoint = URL(string: "https://api.lumi.app/v1/revocations")!
        }

        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod = "GET"
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self = self,
                  error == nil,
                  let data = data,
                  let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  let (nonces, _) = self.parseRevocationList(raw) else {
                DispatchQueue.main.async { completion?(false) }
                return
            }
            UserDefaults.standard.set(raw, forKey: self.revokedCacheKey)
            DispatchQueue.main.async {
                self.cachedRevokedNonces = nonces
                self.loadLicense()
                completion?(true)
            }
        }.resume()
    }

    /// 解析并验签吊销清单，返回被吊销的 nonce 集合
    private func parseRevocationList(_ raw: String) -> (Set<String>, TimeInterval)? {
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "-")
        guard parts.count == 3, parts[0].uppercased() == "LUMIRL",
              let payload = Data(base64Encoded: parts[1]),
              let signature = Data(base64Encoded: parts[2]),
              let pub = Self.licensePublicKey,
              pub.isValidSignature(signature, for: payload) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let entries = json["entries"] as? [[String: Any]] else { return nil }
        let nonces = Set(entries.compactMap { $0["n"] as? String })
        let ts = json["ts"] as? TimeInterval ?? 0
        return (nonces, ts)
    }

    /// 从本地缓存恢复吊销清单（启动时使用，离线也可用上一次结果）
    private func loadRevocationCache() {
        guard let raw = UserDefaults.standard.string(forKey: revokedCacheKey),
              let (nonces, _) = parseRevocationList(raw) else {
            cachedRevokedNonces = []
            return
        }
        cachedRevokedNonces = nonces
    }

    /// 从激活码提取唯一标识 nonce（用于吊销匹配）
    private func nonceOfKey(_ key: String) -> String? {
        let parts = key.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "-")
        guard parts.count == 3, let payload = Data(base64Encoded: parts[1]),
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return nil
        }
        return json["n"] as? String
    }

    /// 将激活错误转换为用户友好提示
    private static func errorMessage(for error: LicenseError) -> String {
        switch error {
        case .invalidFormat:
            return "无效的激活码格式。请输入完整的 LUMI1-<payload>-<signature> 格式激活码。"
        case .verificationFailed:
            return "激活码验证失败，请检查输入是否正确。"
        case .invalid:
            return "激活码无效，无法解析授权信息。"
        case .legacyKey:
            return "您输入的是旧版激活码，授权体系已升级，旧码已失效。请凭原购买凭证联系 support@lumi.app 免费换取新的 LUMI1- 激活码（权益不变）。"
        case .deviceMismatch:
            return "该激活码已绑定其他设备。若您换机或重装，请使用「旧码换发」重新获取绑定本机的新激活码（权益不变）。"
        }
    }
}

