import SwiftUI
import AppKit

/// 常驻「插件市场」主页：作为顶部「插件」标签的统一入口。
/// 内含两个子页：已安装 / 市场；市场支持分类筛选、点开详情、一键安装/更新/卸载，
/// 以及「市场源」管理（官方源 + 社区源开关 + 自定义源）。
struct PluginMarketplaceView: View {
    @ObservedObject private var market = PluginMarketplace.shared
    @ObservedObject private var state = AppState.shared
    @State private var tab: MarketTab = .market
    @State private var category: String = "全部"
    @State private var selected: PluginManifest? = nil
    @State private var showSources = false

    enum MarketTab: String, CaseIterable, Identifiable {
        case installed = "已安装"
        case market = "市场"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 子页切换
            Picker("", selection: $tab) {
                ForEach(MarketTab.allCases) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if tab == .market {
                marketBody
            } else {
                installedBody
            }
        }
        .sheet(isPresented: $showSources) {
            PluginSourcesView()
        }
        .overlay(
            Group {
                if let p = selected {
                    PluginDetailView(plugin: p) {
                        selected = nil
                    }
                }
            }
        )
        .onAppear { market.loadFeed() }
    }

    // MARK: - 市场页

    private var marketBody: some View {
        VStack(spacing: 0) {
            // 分类筛选 + 源管理
            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(PluginMarketplace.categories, id: \.self) { c in
                            Button(action: { category = c }) {
                                Text(c)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(category == c ? .white : .white.opacity(0.5))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(
                                        category == c
                                            ? Color.pink.opacity(0.85)
                                            : Color.white.opacity(0.08)
                                    )
                                    .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.leading, 12)
                }
                Button(action: { showSources = true }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.6))
                        .padding(6)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("市场源设置")
                .padding(.trailing, 10)
            }
            .padding(.bottom, 6)

            Divider().background(Color.white.opacity(0.1))

            ScrollView {
                LazyVStack(spacing: 8) {
                    let items = filteredMarketItems
                    if items.isEmpty {
                        emptyHint("市场暂无可安装插件", sub: "检查网络，或在「市场源」中添加社区源")
                    } else {
                        ForEach(items) { plugin in
                            PluginMarketRow(plugin: plugin) { selected = plugin }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
    }

    private var filteredMarketItems: [PluginManifest] {
        market.available.filter { plugin in
            guard category != "全部" else { return true }
            return (plugin.category ?? "其它") == category
        }
    }

    // MARK: - 已安装页

    private var installedBody: some View {
        VStack(spacing: 0) {
            Divider().background(Color.white.opacity(0.1))
            ScrollView {
                LazyVStack(spacing: 8) {
                    if market.installed.isEmpty {
                        emptyHint("尚未安装任何插件", sub: "前往「市场」一键安装示例插件")
                    } else {
                        ForEach(market.installed) { plugin in
                            PluginInstalledRow(plugin: plugin)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
    }

    private func emptyHint(_ title: String, sub: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "puzzlepiece")
                .font(.system(size: 26))
                .foregroundColor(.white.opacity(0.25))
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
            Text(sub)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}

// MARK: - 市场列表行

struct PluginMarketRow: View {
    let plugin: PluginManifest
    let onTap: () -> Void
    @ObservedObject private var market = PluginMarketplace.shared

    private var isInstalled: Bool { market.isInstalled(plugin) }
    private var hasUpdate: Bool { market.updatesAvailable[plugin.id] != nil }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: plugin.resolvedIconName)
                    .font(.system(size: 20))
                    .foregroundColor(.white.opacity(0.85))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(plugin.resolvedName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                        if let v = plugin.version {
                            Text("v\(v)")
                                .font(.system(size: 9))
                                .foregroundColor(.white.opacity(0.4))
                        }
                    }
                    if let s = plugin.summary, !s.isEmpty {
                        Text(s)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                installBadge
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var installBadge: some View {
        if isInstalled {
            if hasUpdate {
                Text("更新")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.pink)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().stroke(Color.pink.opacity(0.6)))
            } else {
                Text("已装")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
            }
        } else if plugin.downloadURL != nil {
            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: 14))
                .foregroundColor(.pink)
        } else {
            Text("无源")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.3))
        }
    }
}

// MARK: - 已安装列表行

struct PluginInstalledRow: View {
    let plugin: PluginManifest
    @ObservedObject private var market = PluginMarketplace.shared

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: plugin.resolvedIconName)
                .font(.system(size: 20))
                .foregroundColor(.white.opacity(0.85))
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.white.opacity(0.08)))
            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.resolvedName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                if let v = plugin.version {
                    Text("已安装 v\(v)")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                }
            }
            Spacer(minLength: 6)
            Button(action: { market.uninstall(plugin) }) {
                Text("卸载")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.red.opacity(0.85))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Color.red.opacity(0.12)))
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
    }
}

// MARK: - 插件详情页（覆盖层）

struct PluginDetailView: View {
    let plugin: PluginManifest
    let onClose: () -> Void
    @ObservedObject private var market = PluginMarketplace.shared

    private var isInstalled: Bool { market.isInstalled(plugin) }
    private var hasUpdate: Bool { market.updatesAvailable[plugin.id] != nil }
    private var state_: PluginMarketplace.InstallState {
        market.installState[plugin.id] ?? .none
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { onClose() }
            VStack(spacing: 0) {
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                            .padding(8)
                            .background(Circle().fill(Color.white.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text("插件详情")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()
                    Color.clear.frame(width: 30, height: 30)
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 12) {
                            Image(systemName: plugin.resolvedIconName)
                                .font(.system(size: 30))
                                .foregroundColor(.white.opacity(0.9))
                                .frame(width: 52, height: 52)
                                .background(Circle().fill(Color.white.opacity(0.08)))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(plugin.resolvedName)
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(.white)
                                if let v = plugin.version {
                                    Text("版本 v\(v)")
                                        .font(.system(size: 11))
                                        .foregroundColor(.white.opacity(0.45))
                                }
                                if let c = plugin.category {
                                    Text("分类 · \(c)")
                                        .font(.system(size: 11))
                                        .foregroundColor(.white.opacity(0.45))
                                }
                            }
                        }

                        if let s = plugin.summary, !s.isEmpty {
                            Text(s)
                                .font(.system(size: 13))
                                .foregroundColor(.white.opacity(0.7))
                        }

                        if let perms = plugin.permissions, !perms.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("所需权限")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.6))
                                ForEach(perms, id: \.type) { p in
                                    HStack(alignment: .top, spacing: 6) {
                                        Image(systemName: "lock.shield")
                                            .font(.system(size: 11))
                                            .foregroundColor(.orange)
                                        Text(p.reason)
                                            .font(.system(size: 11))
                                            .foregroundColor(.white.opacity(0.6))
                                    }
                                }
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 8)
                                .fill(Color.orange.opacity(0.08)))
                        }

                        actionButton
                    }
                    .padding(14)
                }
            }
            .frame(width: 320, height: 420)
            .background(RoundedRectangle(cornerRadius: 16)
                .fill(Color(NSColor.windowBackgroundColor).opacity(0.97)))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.12)))
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch state_ {
        case .downloading(let p):
            ProgressView(value: p) {
                Text("下载中…").font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.7))
            }
            .progressViewStyle(.linear)
            .frame(maxWidth: .infinity)
        case .installing:
            Text("安装中…")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
                .frame(maxWidth: .infinity)
        case .installed, .none:
            if !isInstalled {
                if let _ = plugin.downloadURL {
                    Button(action: { market.install(plugin) }) {
                        Text("一键安装")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 9).fill(Color.pink))
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("无可用下载地址")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(maxWidth: .infinity)
                }
            } else if hasUpdate {
                Button(action: { market.install(plugin) }) {
                    Text("更新到最新版")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color.pink))
                }
                .buttonStyle(.plain)
            } else {
                Button(action: { market.uninstall(plugin) }) {
                    Text("卸载")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.red.opacity(0.9))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 9)
                            .fill(Color.red.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
        case .failed(let msg):
            VStack(spacing: 8) {
                Text("安装失败：\(msg)")
                    .font(.system(size: 11))
                    .foregroundColor(.red.opacity(0.85))
                if plugin.downloadURL != nil {
                    Button(action: { market.install(plugin) }) {
                        Text("重试")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 9).fill(Color.pink))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - 市场源管理

struct PluginSourcesView: View {
    @ObservedObject private var market = PluginMarketplace.shared
    @Environment(\.dismiss) private var dismiss
    @State private var newURL: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("市场源")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(6)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("官方源（始终启用）")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                Text(market.officialFeedURL?.absoluteString ?? "")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
                    .textSelection(.enabled)
            }

            Toggle("启用社区源", isOn: Binding(
                get: { market.communitySourcesEnabled },
                set: { market.setCommunitySourcesEnabled($0) }
            ))
            .toggleStyle(SwitchToggleStyle())
            .foregroundColor(.white)

            VStack(alignment: .leading, spacing: 6) {
                Text("自定义社区源")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                HStack {
                    TextField("https://example.com/feed.json", text: $newURL)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(.white)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.08)))
                    Button(action: addSource) {
                        Image(systemName: "plus")
                            .foregroundColor(.white)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(Color.pink))
                    }
                    .buttonStyle(.plain)
                    .disabled(!isValidURL(newURL))
                }
                ForEach(market.customSources, id: \.self) { url in
                    HStack {
                        Text(url.absoluteString)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.5))
                            .lineLimit(1)
                        Spacer()
                        Button(action: { market.removeCustomSource(url) }) {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                                .foregroundColor(.red.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Spacer()
        }
        .padding(16)
        .frame(width: 340, height: 360)
        .background(RoundedRectangle(cornerRadius: 14)
            .fill(Color(NSColor.windowBackgroundColor).opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12)))
    }

    private func isValidURL(_ s: String) -> Bool {
        guard let u = URL(string: s), u.scheme == "https" || u.scheme == "http" else {
            return false
        }
        return true
    }

    private func addSource() {
        guard let u = URL(string: newURL.trimmingCharacters(in: .whitespaces)),
              u.scheme == "https" || u.scheme == "http" else { return }
        market.addCustomSource(u)
        newURL = ""
    }
}
