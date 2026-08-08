import Foundation
import AppKit

/// Lumi 示例插件（真实可运行版 · Phase 2 L3 演示）。
///
/// 这是一个独立的 macOS 菜单栏 app（LSUIElement，无窗口），演示如何把你的软件
/// 「插进」Lumi 动态岛面板：
///   1. 启动时向 Lumi 的共享目录写入面板 JSON（L3 内嵌面板数据）；
///   2. 后台定时器周期性刷新该 JSON（Lumi 每 1 秒轮询读取）；
///   3. 注册 URL Scheme `lumi-sample`，响应 Lumi 面板里的按钮/打开回调。
///
/// 接入你自己的软件时，只需：
///   - 复制本工程的 lumi-plugin.json + Info.plist 的 URL Types；
///   - 把「写面板 JSON」的逻辑接到你自己的数据变化上（替换 fetchWeather）。

// MARK: - 面板数据 → JSON

struct PanelLine: Codable {
    enum Kind: String, Codable { case text, kv, progress, button }
    let kind: Kind
    let key: String?
    let value: String?
    let p: Double?
    let title: String?

    static func kv(_ k: String, _ v: String) -> PanelLine {
        PanelLine(kind: .kv, key: k, value: v, p: nil, title: nil)
    }
    static func progress(_ v: Double) -> PanelLine {
        PanelLine(kind: .progress, key: nil, value: nil, p: v, title: nil)
    }
    static func button(_ t: String) -> PanelLine {
        PanelLine(kind: .button, key: nil, value: nil, p: nil, title: t)
    }
    static func text(_ t: String) -> PanelLine {
        PanelLine(kind: .text, key: nil, value: t, p: nil, title: nil)
    }
}

struct PanelData: Codable {
    let id: String
    let title: String
    let iconName: String
    let subtitle: String?
    let lines: [PanelLine]
    let updatedAt: TimeInterval
}

/// Lumi 读取面板 JSON 的共享目录（与宿主 PluginPanelBridge.panelsDir 保持一致）。
func panelsDir() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                        in: .userDomainMask).first!
    return base.appendingPathComponent("Lumi/PluginPanels", isDirectory: true)
}

// MARK: - 真实天气获取（Open-Meteo，无需 API Key）

/// 上海坐标（演示用）。接入你自己的城市时改这里，或从设置读取。
let CITY_NAME = "上海"
let LAT: Double = 31.23
let LON: Double = 121.47

/// WMO 天气代码 → 中文描述（Open-Meteo 使用 WMO 标准代码）
func wmoDescription(_ code: Int) -> String {
    switch code {
    case 0:  return "晴"
    case 1:  return "大致晴朗"
    case 2:  return "局部多云"
    case 3:  return "阴"
    case 45, 48: return "雾"
    case 51, 53, 55: return "毛毛雨"
    case 56, 57: return "冻毛雨"
    case 61, 63, 65: return "雨"
    case 66, 67: return "冻雨"
    case 71, 73, 75: return "雪"
    case 77: return "雪粒"
    case 80, 81, 82: return "阵雨"
    case 85, 86: return "阵雪"
    case 95: return "雷阵雨"
    case 96, 99: return "雷阵雨伴冰雹"
    default: return "未知"
    }
}

/// 同步拉取天气（在后台线程调用，避免阻塞主线程）。返回解析后的字段，失败返回 nil。
func fetchWeather() -> (temp: Double, humidity: Int, wind: Double, code: Int)? {
    let urlStr = "https://api.open-meteo.com/v1/forecast?latitude=\(LAT)&longitude=\(LON)" +
                 "&current=temperature_2m,relative_humidity_2m,wind_speed_10m,weather_code"
    guard let url = URL(string: urlStr) else { return nil }
    let sem = DispatchSemaphore(value: 0)
    var result: (Double, Int, Double, Int)?
    let task = URLSession.shared.dataTask(with: url) { data, _, err in
        defer { sem.signal() }
        guard err == nil, let data = data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cur = json["current"] as? [String: Any] else { return }
        let temp = cur["temperature_2m"] as? Double ?? 0
        let hum  = cur["relative_humidity_2m"] as? Int ?? 0
        let wind = cur["wind_speed_10m"] as? Double ?? 0
        let code = cur["weather_code"] as? Int ?? 0
        result = (temp, hum, wind, code)
    }
    task.resume()
    sem.wait()
    return result
}

func writePanel() {
    let dir = panelsDir()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    // 真实联网取数；失败则回退到「获取失败」提示，不写假数据
    guard let w = fetchWeather() else {
        let fail = PanelData(
            id: "com.lumi.sample-plugin",
            title: "示例插件（天气）",
            iconName: "cloud.sun",
            subtitle: "\(CITY_NAME) · 获取失败",
            lines: [ .text("网络异常，无法获取天气"), .button("刷新天气") ],
            updatedAt: Date().timeIntervalSince1970
        )
        writeData(fail, to: dir)
        return
    }

    let cond = wmoDescription(w.code)
    let data = PanelData(
        id: "com.lumi.sample-plugin",
        title: "示例插件（天气）",
        iconName: "cloud.sun",
        subtitle: "\(CITY_NAME) · 实时",
        lines: [
            .kv("天气", "\(cond) \(Int(w.temp))°C"),
            .kv("湿度", "\(w.humidity)%"),
            .kv("风速", "\(w.wind.rounded(to: 1)) km/h"),
            .progress(min(1, max(0, w.temp / 40))),  // 温度占比：仅作可视化演示
            .button("刷新天气"),
        ],
        updatedAt: Date().timeIntervalSince1970
    )
    writeData(data, to: dir)
}

private func writeData(_ data: PanelData, to dir: URL) {
    let url = dir.appendingPathComponent("\(data.id).json")
    do {
        let encoded = try JSONEncoder().encode(data)
        try encoded.write(to: url, options: .atomic)
        NSLog("[LumiSamplePlugin] 面板已写入：\(url.path)")
    } catch {
        NSLog("[LumiSamplePlugin] 写面板失败：\(error)")
    }
}

// MARK: - URL Scheme 处理

final class SchemeHandler: NSObject {
    @objc func handle(event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let raw = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: raw) else { return }
        NSLog("[LumiSamplePlugin] 收到 URL：\(raw)")

        switch (url.host, url.path) {
        case ("open", _):
            // Lumi 面板头部「打开主程序」按钮
            showMenuBarMessage("主程序被唤起")
        case ("action", _):
            // 面板里按钮点击：lumi-sample://action?name=刷新天气
            let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "name" })?.value ?? "未知"
            if name == "刷新天气" {
                writePanel() // 立即刷新一次
                showMenuBarMessage("已刷新天气")
            } else {
                showMenuBarMessage("收到动作：\(name)")
            }
        default:
            break
        }
    }
}

// MARK: - 菜单栏（LSUIElement 无窗口，用状态栏图标）

var statusItem: NSStatusItem?

func setupStatusBar() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let btn = item.button {
        btn.image = NSImage(systemSymbolName: "cloud.sun.fill", accessibilityDescription: "示例插件")
        btn.image?.isTemplate = true
    }
    let menu = NSMenu()
    let refresh = NSMenuItem(title: "刷新天气", action: #selector(AppDelegate.menuRefresh), keyEquivalent: "r")
    refresh.target = NSApp.delegate
    menu.addItem(refresh)
    menu.addItem(.separator())
    let quit = NSMenuItem(title: "退出示例插件", action: #selector(AppDelegate.menuQuit), keyEquivalent: "q")
    quit.target = NSApp.delegate
    menu.addItem(quit)
    item.menu = menu
    statusItem = item
}

func showMenuBarMessage(_ text: String) {
    let alert = NSAlert()
    alert.messageText = "示例插件"
    alert.informativeText = text
    alert.addButton(withTitle: "好的")
    // 作为 accessory app 直接 runModal 会卡，改为短暂弹出
    DispatchQueue.main.async { alert.runModal() }
}

// MARK: - App 入口

final class AppDelegate: NSObject, NSApplicationDelegate {
    @objc func menuRefresh() { writePanel() }
    @objc func menuQuit() { NSApp.terminate(nil) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 注册 URL Scheme 监听
        let handler = SchemeHandler()
        NSAppleEventManager.shared().setEventHandler(handler,
            andSelector: #selector(SchemeHandler.handle(event:reply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))

        setupStatusBar()

        // 立即写一次，并启动 3 秒周期刷新
        writePanel()
        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
            writePanel()
        }

        NSLog("[LumiSamplePlugin] 已启动，URL Scheme: lumi-sample://")
    }
}

extension Double {
    func rounded(to places: Int) -> Double {
        let f = pow(10, Double(places))
        return (self * f).rounded() / f
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // LSUIElement：无 Dock 图标
app.run()
