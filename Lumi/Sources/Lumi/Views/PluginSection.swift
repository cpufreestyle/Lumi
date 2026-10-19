import SwiftUI
import AppKit

/// 插件区（Phase 1）：分段「已安装 | 市场」。
///
/// - 已安装：本地发现的第三方 app，点击即唤起（L1 URL Scheme / open .app）。
/// - 市场：从官方源拉取可安装插件，一键下载安装 / 卸载。
struct PluginSection: View {
    @ObservedObject private var plugins = PluginDiscovery.shared
    @ObservedObject private var bridge = PluginPanelBridge.shared
    @ObservedObject private var market = PluginMarketplace.shared
    /// 待确认卸载的插件 id：卸载是破坏性操作（直接删 .app），
    /// 误点一次就丢数据，所以点「卸载」后要求二次确认。
    @State private var pendingUninstall: PluginManifest?
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
                    .foregroundColor(PanelInk.text(0.55))
                Text("插件")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(PanelInk.text(0.55))
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
                .foregroundColor(PanelInk.text(0.4))
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
                    .foregroundColor(PanelInk.pink)
                    .padding(.horizontal, 14)
            }
        case .ready:
            if market.available.isEmpty {
                Text("市场暂无可用插件。")
                    .font(.system(size: 10))
                    .foregroundColor(PanelInk.text(0.4))
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
            Text(text).font(.system(size: 10)).foregroundColor(PanelInk.text(0.5))
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
                    .foregroundColor(PanelInk.text(0.85))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(plugin.resolvedName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(PanelInk.text(0.92))
                    let sub = [
                        plugin.version.map { "v\($0)" },
                        plugin.panelHint,
                        plugin.urlScheme.map { "scheme: \($0)://" }
                    ].compactMap { $0 }.first
                    if let sub, !sub.isEmpty {
                        Text(sub).font(.system(size: 9))
                            .foregroundColor(PanelInk.text(0.45)).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                healthBadge(plugin)
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 12))
                    .foregroundColor(PanelInk.text(0.35))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 10).fill(PanelInk.chip(0.04)))
        .padding(.horizontal, 10)
    }

    /// 面板型插件的健康徽标：让用户在列表层就看得出哪个插件异常，
    /// 不必逐个点开面板才发现「数据 30 秒没更新」或「写了坏 JSON」。
    @ViewBuilder
    private func healthBadge(_ plugin: PluginManifest) -> some View {
        // 只有声明了 panel 的插件才有桥接状态；L1 插件不显示徽标
        if plugin.panel, let status = bridge.entries[plugin.id]?.status {
            switch status {
        case .live:
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
                .foregroundColor(PanelInk.green)
        case .stale:
            Image(systemName: "clock.badge.exclamationmark")
                .font(.system(size: 11))
                .foregroundColor(.orange.opacity(0.85))
                .help("面板数据 30 秒未更新，插件可能已退出")
        case .malformed(let reason):
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(.red.opacity(0.85))
                .help(reason)
        case .noData:
            Image(systemName: "circle.dashed")
                .font(.system(size: 11))
                .foregroundColor(PanelInk.text(0.3))
                .help("已声明面板但未写入数据")
            }
        }
    }

    // MARK: - 行：市场（安装/卸载）

    private func marketRow(_ plugin: PluginManifest) -> some View {
        HStack(spacing: 10) {
            Image(systemName: plugin.resolvedIconName)
                .font(.system(size: 14))
                .foregroundColor(PanelInk.text(0.85))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.resolvedName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(PanelInk.text(0.92))
                if let hint = plugin.panelHint, !hint.isEmpty {
                    Text(hint).font(.system(size: 9))
                        .foregroundColor(PanelInk.text(0.45)).lineLimit(1)
                }
            }
            Spacer(minLength: 4)

            installButton(plugin)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(PanelInk.chip(0.04)))
        .padding(.horizontal, 10)
    }

    @ViewBuilder
    private func installButton(_ plugin: PluginManifest) -> some View {
        let state = market.installState[plugin.id] ?? .none
        if market.isInstalled(plugin) {
            if pendingUninstall?.id == plugin.id {
                HStack(spacing: 4) {
                    Button("确认") {
                        market.uninstall(plugin)
                        pendingUninstall = nil
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.red.opacity(0.85)))
                    Button("取消") { pendingUninstall = nil }
                        .font(.system(size: 10))
                        .foregroundColor(PanelInk.text(0.6))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                }
            } else {
                Button("卸载") { pendingUninstall = plugin }
                    .font(.system(size: 10))
                    .foregroundColor(PanelInk.text(0.6))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(PanelInk.chip(0.08)))
            }
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
                        .foregroundColor(PanelInk.text(0.6))
                }
            case .installing:
                ProgressView().scaleEffect(0.6)
            case .installed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(PanelInk.green)
                    .font(.system(size: 13))
            case .failed(let msg):
                // 不设 lineLimit：卸载被拒绝时要给出完整路径，
                // 截断成一行会让用户不知道该手动删哪个文件。
                Text(msg)
                    .font(.system(size: 9))
                    .foregroundColor(.orange.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 180, alignment: .trailing)
            }
        }
    }
}
