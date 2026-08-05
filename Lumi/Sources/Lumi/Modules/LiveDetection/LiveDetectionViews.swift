import SwiftUI
import AppKit
import CoreBluetooth
import IOBluetooth

// MARK: - 实时检测模块
final class LiveDetectionController: ObservableObject {
    static let shared = LiveDetectionController()

    @Published var detections: [DetectionItem] = []
    private var timer: Timer?

    struct DetectionItem: Identifiable {
        let id = UUID()
        let icon: String
        let label: String
        let value: String
        let active: Bool
        let category: Category

        enum Category: String, CaseIterable {
            case audio = "音频"
            case display = "显示"
            case system = "系统"
            case connectivity = "连接"
        }
    }

    private init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        DispatchQueue.main.async {
            self.detections = self.collectDetections()
        }
    }

    private func collectDetections() -> [DetectionItem] {
        var items: [DetectionItem] = []

        // 音量
        let volume = getSystemVolume()
        items.append(DetectionItem(icon: volume > 0 ? "speaker.wave.2.fill" : "speaker.slash.fill",
                                    label: "系统音量",
                                    value: "\(Int(volume * 100))%",
                                    active: volume > 0,
                                    category: .audio))

        // 静音
        let muted = volume == 0
        items.append(DetectionItem(icon: muted ? "speaker.slash" : "speaker.wave.2",
                                    label: "静音状态",
                                    value: muted ? "已静音" : "正常",
                                    active: muted,
                                    category: .audio))

        // 屏幕亮度
        let brightness = getBrightness()
        items.append(DetectionItem(icon: "sun.max.fill",
                                    label: "屏幕亮度",
                                    value: "\(Int(brightness * 100))%",
                                    active: brightness > 0.8,
                                    category: .display))

        // 暗色模式
        let darkMode = NSApp.effectiveAppearance.name == .darkAqua ||
                       NSApp.effectiveAppearance.name == .vibrantDark
        items.append(DetectionItem(icon: darkMode ? "moon.fill" : "sun.max.fill",
                                    label: "外观模式",
                                    value: darkMode ? "深色" : "浅色",
                                    active: false,
                                    category: .display))

        // 专注模式
        let isDoNotDisturb = checkDoNotDisturb()
        items.append(DetectionItem(icon: isDoNotDisturb ? "moon.zzz.fill" : "bell.fill",
                                    label: "专注模式",
                                    value: isDoNotDisturb ? "已开启" : "未开启",
                                    active: isDoNotDisturb,
                                    category: .system))

        // 蓝牙
        let bluetoothOn = checkBluetooth()
        items.append(DetectionItem(icon: "antenna.radiowaves.left.and.right",
                                    label: "蓝牙",
                                    value: bluetoothOn ? "已开启" : "已关闭",
                                    active: bluetoothOn,
                                    category: .connectivity))

        // 当前前台应用
        if let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName {
            items.append(DetectionItem(icon: "app.fill",
                                        label: "当前应用",
                                        value: frontApp,
                                        active: true,
                                        category: .system))
        }

        // 电池
        let batteryInfo = getBatteryInfo()
        if let (level, charging) = batteryInfo {
            items.append(DetectionItem(icon: charging ? "battery.100.bolt" : batteryIcon(for: level),
                                        label: "电池",
                                        value: "\(Int(level * 100))%\(charging ? " 充电中" : "")",
                                        active: level < 0.2,
                                        category: .system))
        }

        return items
    }

    private func getBrightness() -> CGFloat {
        var brightness: Float = 0.7
        var iterator: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == KERN_SUCCESS {
            if let service = IOIteratorNext(iterator) as io_object_t?, service != 0 {
                IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &brightness)
                IOObjectRelease(service)
            }
            IOObjectRelease(iterator)
        }
        return CGFloat(brightness)
    }

    private func checkDoNotDisturb() -> Bool {
        let task = Process()
        task.launchPath = "/usr/bin/defaults"
        task.arguments = ["read", "com.apple.ncprefs", "dnd_prefs"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let str = String(data: data, encoding: .utf8) {
                return str.contains("userPref") && str.contains("enabled") && str.contains("1")
            }
        } catch {}
        return false
    }

    private func checkBluetooth() -> Bool {
        // 通过 IOBluetooth 检测蓝牙电源状态
        return IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON
    }

    private func getSystemVolume() -> Float {
        let src = "output volume of (get volume settings)"
        var error: NSDictionary?
        if let script = NSAppleScript(source: src) {
            let result = script.executeAndReturnError(&error)
            if error == nil {
                return Float(result.int32Value) / 100.0
            }
        }
        return 0.5
    }

    private func getBatteryInfo() -> (Float, Bool)? {
        let task = Process()
        task.launchPath = "/usr/bin/pmset"
        task.arguments = ["-g", "batt"]
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let str = String(data: data, encoding: .utf8) {
                let charging = str.contains("charging") || str.contains("AC Power")
                let parts = str.components(separatedBy: CharacterSet.decimalDigits.inverted)
                    .filter { !$0.isEmpty }
                if let pct = parts.first, let level = Float(pct) {
                    return (level / 100.0, charging)
                }
            }
        } catch {}
        return nil
    }

    private func batteryIcon(for level: Float) -> String {
        if level > 0.75 { return "battery.100" }
        if level > 0.5  { return "battery.75" }
        if level > 0.25 { return "battery.50" }
        return "battery.25"
    }

    var categories: [DetectionItem.Category] { DetectionItem.Category.allCases }
    func items(for category: DetectionItem.Category) -> [DetectionItem] {
        detections.filter { $0.category == category }
    }
}

// MARK: - 实时检测视图
struct LiveDetectionExpandedView: View {
    @ObservedObject private var detector = LiveDetectionController.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(detector.categories, id: \.rawValue) { category in
                    categorySection(category)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
    }

    func categorySection(_ category: LiveDetectionController.DetectionItem.Category) -> some View {
        VStack(spacing: 0) {
            Text(category.rawValue)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.35))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)

            ForEach(detector.items(for: category)) { item in
                detectionRow(item)
            }
        }
        .padding(.bottom, 8)
    }

    func detectionRow(_ item: LiveDetectionController.DetectionItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .font(.system(size: 13))
                .foregroundColor(item.active ? .pink : .white.opacity(0.5))
                .frame(width: 20)

            Text(item.label)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.8))

            Spacer()

            Text(item.value)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(item.active ? .pink.opacity(0.9) : .white.opacity(0.5))

            Circle()
                .fill(item.active ? Color.pink : Color.white.opacity(0.2))
                .frame(width: 6, height: 6)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Color.white.opacity(0.02))
        .cornerRadius(6)
        .padding(.bottom, 2)
    }
}

// MARK: - 检测收缩态
struct LiveDetectionBriefContent: View {
    @ObservedObject private var detector = LiveDetectionController.shared

    var body: some View {
        let activeCount = detector.detections.filter { $0.active }.count
        return Text("🟢 \(activeCount) 项活跃")
            .font(.system(size: 12))
            .foregroundColor(.white.opacity(0.7))
    }
}
