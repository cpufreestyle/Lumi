import SwiftUI
import AppKit
import CoreBluetooth
import IOBluetooth

// MARK: - 实时检测模块
final class LiveDetectionController: ObservableObject {
    static let shared = LiveDetectionController()

    @Published var detections: [DetectionItem] = []
    @Published var showManualSettings: Bool = false
    private var timer: Timer?
    /// 采集用的后台串行队列（子进程 / AppleScript 均为同步阻塞调用）
    private let workQueue = DispatchQueue(label: "com.lumi.livedetection", qos: .utility)

    // 手动覆盖：label -> 状态（active），nil 表示使用自动检测
    private var manualActive: [String: Bool] = [:]
    // 手动覆盖：label -> 显示文本
    private var manualValue: [String: String] = [:]
    private let manualActiveKey = "live_manual_active"
    private let manualValueKey  = "live_manual_value"

    struct DetectionItem: Identifiable, Equatable {
        /// 使用稳定标识（label 全局唯一），避免每次刷新都生成新 UUID
        /// 导致 SwiftUI 认为所有行都是新元素而全量重建（会清空正在编辑的输入框）。
        var id: String { label }
        let icon: String
        let label: String
        let value: String
        let active: Bool
        let category: Category
        let manual: Bool

        enum Category: String, CaseIterable {
            case audio = "音频"
            case display = "显示"
            case system = "系统"
            case connectivity = "连接"
        }
    }

    private init() {
        manualActive = UserDefaults.standard.dictionary(forKey: manualActiveKey) as? [String: Bool] ?? [:]
        manualValue  = UserDefaults.standard.dictionary(forKey: manualValueKey)  as? [String: String] ?? [:]
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: - 手动覆盖 API

    /// 是否为某项设置了手动覆盖
    func isManual(_ label: String) -> Bool {
        manualActive[label] != nil || manualValue[label] != nil
    }

    /// 已保存的手动显示文本（未设置则为 nil）
    func storedManualValue(_ label: String) -> String? {
        manualValue[label]
    }

    /// 设置手动状态（nil 表示清除）
    func setManualActive(_ label: String, _ value: Bool?) {
        if let value = value {
            manualActive[label] = value
        } else {
            manualActive.removeValue(forKey: label)
        }
        UserDefaults.standard.set(manualActive, forKey: manualActiveKey)
        refresh()
    }

    /// 设置手动显示文本（nil / 空 表示清除）
    func setManualValue(_ label: String, _ value: String?) {
        if let value = value, !value.trimmingCharacters(in: .whitespaces).isEmpty {
            manualValue[label] = value
        } else {
            manualValue.removeValue(forKey: label)
        }
        UserDefaults.standard.set(manualValue, forKey: manualValueKey)
        refresh()
    }

    /// 清除某项的全部手动设置
    func clearManual(_ label: String) {
        manualActive.removeValue(forKey: label)
        manualValue.removeValue(forKey: label)
        UserDefaults.standard.set(manualActive, forKey: manualActiveKey)
        UserDefaults.standard.set(manualValue, forKey: manualValueKey)
        refresh()
    }

    func refresh() {
        // 采集涉及同步子进程（pmset / defaults）与 AppleScript，耗时可达数百毫秒，
        // 必须放到后台串行队列，否则每 2 秒的轮询会周期性卡住主线程 UI。
        let snapshotActive = manualActive
        let snapshotValue  = manualValue
        // NSApp.effectiveAppearance / NSWorkspace 为主线程 API，先在主线程取快照
        let uiSnapshot = Self.captureUISnapshot()
        workQueue.async { [weak self] in
            guard let self = self else { return }
            let auto = self.collectDetections(ui: uiSnapshot)
            // 应用手动覆盖
            let result: [DetectionItem] = auto.map { item in
                let overridden = snapshotActive[item.label] != nil || snapshotValue[item.label] != nil
                return DetectionItem(
                    icon: item.icon,
                    label: item.label,
                    value: snapshotValue[item.label] ?? item.value,
                    active: snapshotActive[item.label] ?? item.active,
                    category: item.category,
                    manual: overridden
                )
            }
            DispatchQueue.main.async {
                // 内容未变化时不赋值，避免无谓的视图刷新
                guard self.detections != result else { return }
                self.detections = result
            }
        }
    }

    /// 主线程 AppKit 只读快照
    struct UISnapshot {
        let darkMode: Bool
        let frontApp: String?
    }

    private static func captureUISnapshot() -> UISnapshot {
        let read: () -> UISnapshot = {
            let name = NSApp?.effectiveAppearance.name
            return UISnapshot(
                darkMode: name == .darkAqua || name == .vibrantDark,
                frontApp: NSWorkspace.shared.frontmostApplication?.localizedName
            )
        }
        if Thread.isMainThread { return read() }
        return DispatchQueue.main.sync(execute: read)
    }

    private func collectDetections(ui: UISnapshot) -> [DetectionItem] {
        var items: [DetectionItem] = []

        // 音量
        let volume = getSystemVolume()
        items.append(DetectionItem(icon: volume > 0 ? "speaker.wave.2.fill" : "speaker.slash.fill",
                                    label: "系统音量",
                                    value: "\(Int(volume * 100))%",
                                    active: volume > 0,
                                    category: .audio,
                                    manual: false))

        // 静音
        let muted = volume == 0
        items.append(DetectionItem(icon: muted ? "speaker.slash" : "speaker.wave.2",
                                    label: "静音状态",
                                    value: muted ? "已静音" : "正常",
                                    active: muted,
                                    category: .audio,
                                    manual: false))

        // 屏幕亮度
        let brightness = getBrightness()
        items.append(DetectionItem(icon: "sun.max.fill",
                                    label: "屏幕亮度",
                                    value: "\(Int(brightness * 100))%",
                                    active: brightness > 0.8,
                                    category: .display,
                                    manual: false))

        // 暗色模式
        let darkMode = ui.darkMode
        items.append(DetectionItem(icon: darkMode ? "moon.fill" : "sun.max.fill",
                                    label: "外观模式",
                                    value: darkMode ? "深色" : "浅色",
                                    active: false,
                                    category: .display,
                                    manual: false))

        // 专注模式
        let isDoNotDisturb = checkDoNotDisturb()
        items.append(DetectionItem(icon: isDoNotDisturb ? "moon.zzz.fill" : "bell.fill",
                                    label: "专注模式",
                                    value: isDoNotDisturb ? "已开启" : "未开启",
                                    active: isDoNotDisturb,
                                    category: .system,
                                    manual: false))

        // 蓝牙
        let bluetoothOn = checkBluetooth()
        items.append(DetectionItem(icon: "antenna.radiowaves.left.and.right",
                                    label: "蓝牙",
                                    value: bluetoothOn ? "已开启" : "已关闭",
                                    active: bluetoothOn,
                                    category: .connectivity,
                                    manual: false))

        // 当前前台应用
        if let frontApp = ui.frontApp {
            items.append(DetectionItem(icon: "app.fill",
                                        label: "当前应用",
                                        value: frontApp,
                                        active: true,
                                        category: .system,
                                        manual: false))
        }

        // 电池
        let batteryInfo = getBatteryInfo()
        if let (level, charging, status) = batteryInfo {
            let icon = charging
                ? (level >= 1.0 ? "battery.100.bolt" : "battery.75.bolt")
                : batteryIcon(for: level)
            items.append(DetectionItem(icon: icon,
                                        label: "电池",
                                        value: "\(Int(level * 100))%\(charging ? " · 充电中" : "")",
                                        active: level < 0.2,
                                        category: .system,
                                        manual: false))
            // 同时提供一条"充电状态"可供手动覆盖
            items.append(DetectionItem(icon: charging ? "bolt.fill" : "bolt.slash",
                                        label: "充电状态",
                                        value: status,
                                        active: charging,
                                        category: .system,
                                        manual: false))
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

    /// 专注模式检测代价较高（起子进程解析 plist），且状态变化不频繁，缓存 30 秒
    private var dndCache: (value: Bool, at: Date)?

    private func checkDoNotDisturb() -> Bool {
        if let c = dndCache, Date().timeIntervalSince(c.at) < 30 { return c.value }
        let value = readDoNotDisturb()
        dndCache = (value, Date())
        return value
    }

    private func readDoNotDisturb() -> Bool {
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

    /// 解析 pmset -g batt 输出，精确提取电量百分比与充电状态
    private func getBatteryInfo() -> (Float, Bool, String)? {
        let task = Process()
        task.launchPath = "/usr/bin/pmset"
        task.arguments = ["-g", "batt"]
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
            task.waitUntilExit()
            guard let str = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                                   encoding: .utf8) else { return nil }

            // 1) 百分比：匹配 "数字%"（电池 ID 后的数字后跟的是 ')' 而非 '%'，
            //    因此 "%" 前只会出现电量百分比本身的数值）
            guard let pctMatch = str.range(of: #"\d+%"#, options: .regularExpression),
                  let level = Float(String(str[pctMatch]).dropLast()) else { return nil }
            let levelFloat = min(max(level, 0), 100) / 100.0

            // 2) 充电状态：基于整段输出按关键词优先级判定。
            //    必须先把 "not charging" 排在 "charging" 之前，否则 "discharging" /
            //    "not charging" 会因其包含 "charging" 子串而被误判为充电中。
            let full = str.localizedLowercase
            let charging: Bool
            let displayStatus: String
            if full.contains("not charging") {
                charging = false
                displayStatus = (full.contains("ac attached") || full.contains("ac power"))
                    ? "已连接电源（未充电）" : "未充电"
            } else if full.contains("finishing charge") {
                charging = true;  displayStatus = "充电中（即将充满）"
            } else if full.contains("charging") {
                charging = true;  displayStatus = "充电中"
            } else if full.contains("charged") {
                charging = false; displayStatus = "已充满"
            } else if full.contains("discharging") {
                charging = false; displayStatus = "放电中（未充电）"
            } else if full.contains("ac attached") || full.contains("ac power") {
                charging = false; displayStatus = "已连接电源"
            } else {
                charging = false; displayStatus = "未充电"
            }

            return (levelFloat, charging, displayStatus)
        } catch {
            return nil
        }
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
        VStack(spacing: 0) {
            // 顶部标题 + 手动设置按钮
            HStack {
                Text("环境检测")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.75))
                Spacer()
                Button(action: { detector.showManualSettings.toggle() }) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 4)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(detector.categories, id: \.rawValue) { category in
                        categorySection(category)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }
        }
        .sheet(isPresented: $detector.showManualSettings) {
            LiveManualSettingsView()
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

            if item.manual {
                Image(systemName: "hand.draw")
                    .font(.system(size: 9))
                    .foregroundColor(.orange)
            }

            Spacer()

            Text(item.value)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(item.active ? .pink.opacity(0.9) : .white.opacity(0.5))
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(item.manual ? Color.orange.opacity(0.06) : Color.white.opacity(0.02))
        .cornerRadius(6)
        .padding(.bottom, 2)
    }
}

// MARK: - 手动设置面板
struct LiveManualSettingsView: View {
    @ObservedObject private var detector = LiveDetectionController.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("手动设置环境状态")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            Text("自动检测不准时，可手动覆盖每一项的状态与显示文本。")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.4))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(detector.detections) { item in
                        ManualRow(item: item)
                    }
                }
                .padding(.horizontal, 16)
            }

            Button(action: {
                // 清除全部手动设置
                for item in detector.detections { detector.clearManual(item.label) }
            }) {
                Text("清除全部手动设置")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.orange)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 340, height: 460)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.12), lineWidth: 0.5))
        )
    }
}

struct ManualRow: View {
    @ObservedObject private var detector = LiveDetectionController.shared
    let item: LiveDetectionController.DetectionItem
    /// 输入框文本以 controller 中的手动值为单一数据源。
    /// 不要用 @State 镜像 item.value：2 秒轮询刷新会重建该行并把用户
    /// 正在输入的内容重置回自动检测值。
    @State private var editingValue: String = ""
    @State private var didLoad = false

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .font(.system(size: 13))
                    .foregroundColor(item.active ? .pink : .white.opacity(0.5))
                    .frame(width: 20)

                Text(item.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))

                Spacer()

                // 状态开关
                Toggle("", isOn: Binding(
                    get: { item.active },
                    set: { detector.setManualActive(item.label, $0) }
                ))
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: .pink))
                .scaleEffect(0.7)
            }

            // 手动数值输入
            HStack(spacing: 6) {
                TextField("显示文本（手动）", text: $editingValue)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.white)
                    .padding(7)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(6)
                    .onSubmit { detector.setManualValue(item.label, editingValue) }

                Button(action: { detector.setManualValue(item.label, editingValue) }) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.03))
        .cornerRadius(10)
        .onAppear {
            // 只在首次出现时填充初值，后续轮询刷新不覆盖用户输入
            guard !didLoad else { return }
            didLoad = true
            editingValue = detector.storedManualValue(item.label) ?? item.value
        }
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
