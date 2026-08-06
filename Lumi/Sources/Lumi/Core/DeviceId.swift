import Foundation
import CryptoKit
import IOKit

/// 稳定的本机设备标识，用于激活码设备绑定（写入签名 payload 的 `dev` 字段）。
/// - 取 `IOPlatformUUID` 并 SHA-256 散列（不暴露原始硬件序列号）。
/// - 散列结果存 Keychain，保证重装 App 后不变；换机则不同。
enum DeviceId {
    static var current: String {
        if let cached = Keychain.get(storageKey), !cached.isEmpty { return cached }
        let raw = platformUUID() ?? UUID().uuidString
        let hashed = sha256(raw)
        _ = Keychain.set(hashed, for: storageKey)
        return hashed
    }

    private static let storageKey = "lumi_device_id"

    private static func sha256(_ s: String) -> String {
        Data(CryptoKit.SHA256.hash(data: Data(s.utf8)))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// 通过 IOKit 读取平台 UUID（macOS 专属）
    private static func platformUUID() -> String? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return (IORegistryEntryCreateCFProperty(
            service,
            "IOPlatformUUID" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String)
    }
}
