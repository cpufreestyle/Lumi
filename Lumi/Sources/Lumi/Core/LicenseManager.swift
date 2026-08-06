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
}

// MARK: - 激活错误
enum LicenseError: Error {
    case invalidFormat
    case verificationFailed
    case invalid
    /// 旧版 CRC 激活码（LUMI-XXXX-XXXX-XXXX-XXXX），授权体系升级后已失效
    case legacyKey
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
    }

    // MARK: - 公开方法

    /// 检查某个功能是否已解锁
    func isUnlocked(_ feature: PremiumFeature) -> Bool {
        switch status {
        case .licensed, .lifetime:
            return true
        case .trial:
            return unlockedFeatures.contains(feature)
        case .unlicensed:
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
                    let licenseData: [String: Any] = [
                        "type": expiry == nil ? "lifetime" : "licensed",
                        "activatedAt": Date().timeIntervalSince1970,
                        "expiry": expiry?.timeIntervalSince1970 as Any,
                        "keyHash": self.sha256(key)
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
        guard parts.count == 3, parts[0].uppercased() == "LUMI1" else {
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
        }
    }
}

