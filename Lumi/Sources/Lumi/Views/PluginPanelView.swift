import SwiftUI
import AppKit

/// L3 第三方插件内嵌面板（Phase 2）。
///
/// 渲染 `PluginPanelData`：标题/图标/副标题 + 结构化行（文本、键值、进度、按钮）。
/// 按钮行点击时通过插件声明的 URL Scheme（加 `?action=<title>`）回传给第三方 app 处理。
struct PluginPanelView: View {
    let panel: PluginPanelData
    @ObservedObject private var plugins = PluginDiscovery.shared
    @ObservedObject private var state = AppState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 头部：圆形图标 + 标题/副标题（每个插件为独立页面，需自带身份标识）
            HStack(spacing: 10) {
                Image(systemName: panel.iconName.isEmpty ? "puzzlepiece" : panel.iconName)
                    .font(.system(size: 18))
                    .foregroundColor(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(
                        LinearGradient(colors: [Color.pink, Color.purple],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(panel.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                    if let sub = panel.subtitle, !sub.isEmpty {
                        Text(sub)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
                Spacer()
                // 回插件按钮（若声明了 URL Scheme）
                if let scheme = pluginScheme, !scheme.isEmpty {
                    Button(action: {
                        if let url = URL(string: "\(scheme)://open") {
                            NSWorkspace.shared.open(url)
                        }
                    }) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.5))
                            .padding(6)
                            .background(Circle().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .help("打开 \(panel.title) 主程序")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            Divider().background(Color.white.opacity(0.1)).padding(.horizontal, 16)

            // 结构化内容
            if panel.lines.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.system(size: 24))
                        .foregroundColor(.white.opacity(0.3))
                    Text("插件暂无内容")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(panel.lines.enumerated()), id: \.offset) { _, line in
                            lineView(line)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                }
            }

            if panel.isStale {
                Text("插件数据已 30 秒未更新，可能已退出")
                    .font(.system(size: 9))
                    .foregroundColor(.orange.opacity(0.7))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func lineView(_ line: PluginPanelLine) -> some View {
        switch line.kind {
        case .text:
            Text(line.value ?? "")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        case .kv:
            HStack {
                Text(line.key ?? "").font(.system(size: 12)).foregroundColor(.white.opacity(0.5))
                Spacer()
                Text(line.value ?? "").font(.system(size: 12, weight: .medium)).foregroundColor(.white)
            }
        case .progress:
            ProgressView(value: min(1, max(0, line.p ?? 0)))
                .progressViewStyle(LinearProgressViewStyle(tint: Color.pink))
                .frame(height: 4)
        case .button:
            Button(action: {
                guard let scheme = pluginScheme, !scheme.isEmpty,
                      let t = line.title,
                      let url = URL(string: "\(scheme)://action?name=\(t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")") else { return }
                NSWorkspace.shared.open(url)
            }) {
                Text(line.title ?? "")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
    }

    private var pluginScheme: String? {
        plugins.plugins.first(where: { $0.id == panel.id })?.urlScheme
    }
}
