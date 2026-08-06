import Foundation

/// 本地遥测（PRD 5.4 反馈与可观测）。
/// 仅记录于本机 UserDefaults，绝不上报。用于量化：
///   - 自助换码成功率（redeemAttempt / redeemSuccess / redeemFailure）
///   - 换码失败原因分布（failureReasons）
///   - 设备绑定覆盖率（激活中 LUMI2- 占比）
enum TelemetryEvent: String {
    case activateLumi1
    case activateLumi2
    case activateLifetime
    case activateTrial
    case redeemAttempt
    case redeemSuccess
    case redeemFailure
}

final class Telemetry {
    static let shared = Telemetry()

    private let defaults = UserDefaults.standard
    private let key = "lumi_telemetry_v1"

    private struct Store: Codable {
        var counts: [String: Int] = [:]
        var failureReasons: [String: Int] = [:]
    }

    private func read() -> Store {
        guard let data = defaults.data(forKey: key),
              let s = try? JSONDecoder().decode(Store.self, from: data) else { return Store() }
        return s
    }

    private func write(_ s: Store) {
        if let data = try? JSONEncoder().encode(s) {
            defaults.set(data, forKey: key)
        }
    }

    func record(_ event: TelemetryEvent) {
        var s = read()
        s.counts[event.rawValue, default: 0] += 1
        write(s)
    }

    /// 记录换码失败及原因分类（如「网络错误」「业务拒绝」等）
    func recordRedeemFailure(reason: String) {
        var s = read()
        s.counts[TelemetryEvent.redeemFailure.rawValue, default: 0] += 1
        let bucket = reason.isEmpty ? "未知" : reason
        s.failureReasons[bucket, default: 0] += 1
        write(s)
    }

    struct Snapshot {
        var activations: Int
        var deviceBoundActivations: Int
        var redeemAttempts: Int
        var redeemSuccesses: Int
        var redeemFailures: Int
        var failureBreakdown: [(reason: String, count: Int)]
    }

    func snapshot() -> Snapshot {
        let s = read()
        let c = s.counts
        let breakdown = s.failureReasons
            .sorted { $0.value > $1.value }
            .map { (reason: $0.key, count: $0.value) }
        return Snapshot(
            activations: c[TelemetryEvent.activateLumi1.rawValue, default: 0]
                       + c[TelemetryEvent.activateLumi2.rawValue, default: 0]
                       + c[TelemetryEvent.activateLifetime.rawValue, default: 0],
            deviceBoundActivations: c[TelemetryEvent.activateLumi2.rawValue, default: 0],
            redeemAttempts: c[TelemetryEvent.redeemAttempt.rawValue, default: 0],
            redeemSuccesses: c[TelemetryEvent.redeemSuccess.rawValue, default: 0],
            redeemFailures: c[TelemetryEvent.redeemFailure.rawValue, default: 0],
            failureBreakdown: breakdown
        )
    }
}
