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

    /// 验证激活码 (本地算法验证)
    private func validateLicenseKey(_ key: String) -> Result<Date?, LicenseError> {
        let cleaned = key.replacingOccurrences(of: "LUMI-", with: "")
                          .replacingOccurrences(of: "-", with: "")
                          .uppercased()

        guard cleaned.count == 16 else {
            return .failure(.invalidFormat)
        }

        // 验证校验和
        let segments = stride(from: 0, to: cleaned.count, by: 4).map {
            String(cleaned[cleaned.index(cleaned.startIndex, offsetBy: $0)..<min(cleaned.index(cleaned.startIndex, offsetBy: $0 + 4), cleaned.endIndex)])
        }

        guard segments.count == 4 else {
            return .failure(.invalidFormat)
        }

        // 第4段是前3段的校验和
        let data = segments[0] + segments[1] + segments[2]
        let checksum = segments[3]

        let expected = String(format: "%04X", crc16(data.data(using: .ascii) ?? Data()))

        guard checksum == expected else {
            return .failure(.verificationFailed)
        }

        // 解析有效期（编码在第2段中）
        let validitySegment = segments[1]
        if validitySegment == "FFFF" {
            // 永久许可
            return .success(nil)
        } else if let months = UInt16(validitySegment, radix: 16), months > 0 {
            let expiry = Calendar.current.date(byAdding: .month, value: Int(months), to: Date())
            return .success(expiry)
        }

        return .failure(.invalid)
    }

    private func crc16(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                if (crc & 0x8000) != 0 {
                    crc = (crc << 1) ^ 0x1021
                } else {
                    crc <<= 1
                }
            }
        }
        return crc & 0xFFFF
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
            return "无效的激活码格式。请输入完整的 LUMI-XXXX-XXXX-XXXX-XXXX 格式激活码。"
        case .verificationFailed:
            return "激活码验证失败，请检查输入是否正确。"
        case .invalid:
            return "激活码无效，无法解析有效期。"
        }
    }
}

// MARK: - 激活码生成工具 (供服务端使用)
enum LicenseKeyGenerator {

    /// 生成激活码
    /// - Parameters:
    ///   - months: 有效月数，nil 表示永久
    /// - Returns: LUMI-XXXX-XXXX-XXXX-XXXX 格式的激活码
    static func generate(months: Int?) -> String {
        // 第1段: 随机
        let seg1 = String(format: "%04X", UInt16.random(in: 0x1000...0xFFFE))
        // 第2段: 有效期 (FFFF = 永久)
        let seg2 = months.map { String(format: "%04X", UInt16($0)) } ?? "FFFF"
        // 第3段: 随机
        let seg3 = String(format: "%04X", UInt16.random(in: 0x1000...0xFFFE))
        // 第4段: 校验和
        let dataStr = seg1 + seg2 + seg3
        let crc = crc16String(dataStr.data(using: .ascii) ?? Data())
        let seg4 = String(format: "%04X", crc)

        return "LUMI-\(seg1)-\(seg2)-\(seg3)-\(seg4)"
    }

    private static func crc16String(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                if (crc & 0x8000) != 0 {
                    crc = (crc << 1) ^ 0x1021
                } else {
                    crc <<= 1
                }
            }
        }
        return crc & 0xFFFF
    }
}
