import SwiftUI
import AppKit

/// 插件区（Phase 1）：分段「已安装 | 市场」。
///
/// - 已安装：本地发现的第三方 app，点击即唤起（L1 URL Scheme / open .app）。
/// - 市场：从官方源拉取可安装插件，一键下载安装 / 卸载。
struct PluginSection: View {
    @ObservedObject private var plugins = PluginDiscovery.shared
    @ObservedObject private var market = PluginMarketplace.shared
    @State private var tab: Tab = .installed

    enum Tab: String, CaseIterable, Identifiable {
        case installed = "已安装"
        case market = "市场"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 分区标题 + 分段控制
            HStack(spacing: 6) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.55))
                Text("插件")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.55))
                Spacer()
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 116)
                .scaleEffect(0.82)
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)

            switch tab {
            case .installed:
                installedList
            case .market:
                marketList
            }
        }
    }

    // MARK: - 已安装

    @ViewBuilder
    private var installedList: some View {
        let list = plugins.plugins
        if list.isEmpty {
            Text("未发现第三方插件。在 App 的 Contents/Resources 放置 lumi-plugin.json 即可接入，或到「市场」一键安装。")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.top, 2)
        } else {
            ForEach(list) { plugin in
                pluginRow(plugin)
            }
        }
    }

    // MARK: - 市场

    @ViewBuilder
    private var marketList: some View {
        switch market.feedStatus {
        case .idle:
            Color.clear.onAppear { market.loadFeed() }
            loadingRow("正在加载市场…")
        case .loading:
            loadingRow("正在加载市场…")
        case .failed(let msg):
            VStack(alignment: .leading, spacing: 4) {
                Text("市场加载失败：\(msg)")
                    .font(.system(size: 10))
                    .foregroundColor(.orange.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                Button("重试") { market.loadFeed() }
                    .font(.system(size: 10))
                    .foregroundColor(.pink)
                    .padding(.horizontal, 14)
            }
        case .ready:
            if market.available.isEmpty {
                Text("市场暂无可用插件。")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.horizontal, 14)
            } else {
                ForEach(market.available) { plugin in
                    marketRow(plugin)
                }
            }
        }
    }

    private func loadingRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().scaleEffect(0.6)
            Text(text).font(.system(size: 10)).foregroundColor(.white.opacity(0.5))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - 行：已安装（唤起）

    private func pluginRow(_ plugin: PluginManifest) -> some View {
        Button(action: {
            if !PluginDiscovery.shared.launch(plugin) { NSSound.beep() }
        }) {
            HStack(spacing: 10) {
                Image(systemName: plugin.resolvedIconName)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.85))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(plugin.resolvedName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.92))
                    if let hint = plugin.panelHint, !hint.isEmpty {
                        Text(hint).font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.45)).lineLimit(1)
                    } else if let scheme = plugin.urlScheme, !scheme.isEmpty {
                        Text("scheme: \(scheme)://").font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.35)).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if let perms = plugin.permissions, !perms.isEmpty {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.orange.opacity(0.8))
                        .help(perms.map { "\($0.type): \($0.reason)" }.joined(separator: "\n"))
                }
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.35))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
        .padding(.horizontal, 10)
    }

    // MARK: - 行：市场（安装/卸载）

    private func marketRow(_ plugin: PluginManifest) -> some View {
        HStack(spacing: 10) {
            Image(systemName: plugin.resolvedIconName)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.85))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.resolvedName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.92))
                if let hint = plugin.panelHint, !hint.isEmpty {
                    Text(hint).font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.45)).lineLimit(1)
                }
            }
            Spacer(minLength: 4)

            installButton(plugin)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
        .padding(.horizontal, 10)
    }

    @ViewBuilder
    private func installButton(_ plugin: PluginManifest) -> some View {
        let state = market.installState[plugin.id] ?? .none
        if market.isInstalled(plugin) {
            Button("卸载") {
                market.uninstall(plugin)
            }
            .font(.system(size: 10))
            .foregroundColor(.white.opacity(0.6))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(0.08)))
        } else {
            switch state {
            case .none:
                Button("安装") { market.install(plugin) }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.pink.opacity(0.85)))
            case .downloading(let p):
                HStack(spacing: 5) {
                    ProgressView(value: p).frame(width: 44)
                    Text("\(Int(p * 100))%")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.6))
                }
            case .installing:
                ProgressView().scaleEffect(0.6)
            case .installed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 13))
            case .failed(let msg):
                Text(msg)
                    .font(.system(size: 9))
                    .foregroundColor(.orange.opacity(0.85))
                    .lineLimit(1)
            }
        }
    }
}
