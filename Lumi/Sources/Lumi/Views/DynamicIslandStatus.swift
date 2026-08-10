import SwiftUI

extension View {
    /// 条件修饰符：满足条件时应用 transform
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool,
                             transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

// MARK: - 仿灵动岛（黑色岛）
/// 把 Lumi 的运行/更新「状态」与「操作」都收敛进黑色岛：
/// 常态只显示状态（紧凑），点击岛展开为更大的黑色岛，内置操作按钮。
/// 这样检查更新、更新并重启、忽略、前往下载、取消等入口都隐藏在岛内，
/// 不再散落在展开面板的各处。
struct DynamicIslandStatusView: View {
    @ObservedObject private var updater = Updater.shared
    /// 展开态：面板顶部的大岛（可交互、含操作）
    var expanded: Bool = false
    /// 收缩态点击直接检查更新（菜单栏胶囊条用）
    var tapChecksUpdate: Bool = false
    /// 是否已内嵌于黑色岛容器（如菜单栏那条黑色岛），true 时不画自己的背景，
    /// 只提供状态/操作内容，避免「双层黑岛」叠成发灰的胶囊。
    var embedded: Bool = false
    /// 菜单栏岛专用：常驻显示「运行中 · {模块}」作为主状态，不被更新检查状态覆盖。
    /// 有更新/失败时图标仍会变橙/绿做提示，但文字稳定显示「运行中」。
    var running: Bool = false

    /// 岛的本地展开（点击后显示操作按钮），与全局 status 解耦
    @State private var islandOpen = false

    var body: some View {
        islandContent
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: islandOpen)
            .animation(.easeInOut(duration: 0.25), value: updater.status)
    }

    // 黑色岛主体
    private var islandContent: some View {
        VStack(spacing: 0) {
            // 常驻状态行（点击切换操作区 / 或触发检查）
            Button(action: {
                if tapChecksUpdate {
                    updater.checkForUpdates(force: true)
                } else {
                    islandOpen.toggle()
                }
            }) {
                HStack(spacing: 8) {
                    if running {
                        // 菜单栏黑岛（刘海下方）：只保留一个小状态指示点，
                        // 不显示文字、不放任何按钮（下载/更新操作只在展开态大岛内）。
                        statusIcon
                    } else {
                        statusIcon
                        // 仅在「有更新/下载/失败」等需要提示的状态显示文字，
                        // 常态（运行中/idle/已是最新）不显示「Lumi 运行中」字样，
                        // 只保留状态点，避免黑岛里出现冗余的「运行中」文字。
                        if showStatusText {
                            statusText
                        }
                        Spacer(minLength: 0)
                        if expanded {
                            Image(systemName: islandOpen ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.white.opacity(0.4))
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
            .buttonStyle(.plain)
            .help(statusHelp)

            // 操作区：仅在展开岛且需要操作时显示
            if expanded && islandOpen && hasActions {
                actionArea
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
        // 内嵌于黑色岛容器时（如菜单栏那条黑岛）不画自己的背景，避免双层。
        // 否则画纯黑实心岛背景（直角矩形，更贴近「黑色岛」质感）。
        .`if`(!embedded) { view in
            view.background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.black)
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.12), lineWidth: 0.5))
            )
        }
    }

    // MARK: - 状态
    private var statusIcon: some View {
        Image(systemName: running ? runIconName : iconName)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(running ? runIconColor : iconColor)
            .frame(width: 18, height: 18)
            .overlay(
                Group {
                    if !running, case .checking = updater.status {
                        ProgressView().scaleEffect(0.4)
                            .frame(width: 18, height: 18)
                    }
                }
            )
    }

    private var statusText: some View {
        Text(running ? runLabel : label)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.white)
            .lineLimit(1)
    }

    /// 是否显示状态文字：常态（运行中/idle/已是最新）不显示「Lumi 运行中」等冗余文案，
    /// 仅在有更新/下载/失败等需要用户关注的状态时显示对应文字。
    private var showStatusText: Bool {
        guard !running else { return false }
        switch updater.status {
        case .idle, .upToDate:
            return false
        default:
            return true
        }
    }

    private var iconName: String {
        switch updater.status {
        case .checking:       return "arrow.triangle.2.circlepath"
        case .available:      return "arrow.down.circle.fill"
        case .upToDate:       return "checkmark.circle.fill"
        case .downloading:    return "icloud.and.arrow.down"
        case .readyToInstall: return "power"
        case .failed:         return "exclamationmark.triangle.fill"
        default:              return "circle.fill"
        }
    }

    private var iconColor: Color {
        switch updater.status {
        case .available, .upToDate: return .green
        case .failed:               return .orange
        case .readyToInstall, .downloading: return .blue
        default:                    return .white.opacity(0.6)
        }
    }

    private var label: String {
        switch updater.status {
        case .checking:       return "检查更新中"
        case .available:      return "新版本 v\(updater.latestVersion ?? "")"
        case .upToDate:       return "已是最新 v\(updater.currentVersion)"
        case .downloading(let p): return "下载中 \(Int(p * 100))%"
        case .readyToInstall: return "即将更新重启"
        case .failed:         return "更新失败"
        default:              return "Lumi 运行中"
        }
    }

    // MARK: - 运行态（菜单栏黑岛专用）
    @ObservedObject private var state = AppState.shared
    /// 运行态图标：有可用更新时变绿/橙提示，平时为白点。
    private var runIconName: String {
        switch updater.status {
        case .available:      return "arrow.down.circle.fill"
        case .failed:         return "exclamationmark.triangle.fill"
        default:              return "circle.fill"
        }
    }
    private var runIconColor: Color {
        switch updater.status {
        case .available:      return .green
        case .failed:         return .orange
        default:              return .green
        }
    }
    /// 主文字稳定显示「运行中 · {当前模块}」，不被更新检查状态覆盖。
    private var runLabel: String {
        "运行中 · \(state.activeModule.shortName)"
    }

    private var statusHelp: String {
        switch updater.status {
        case .available:  return "发现新版本 v\(updater.latestVersion ?? "")，点击展开操作"
        case .upToDate:   return "已是最新版本 v\(updater.currentVersion)"
        case .failed:     return "检查/更新失败，点击展开"
        case .checking:   return "正在检查更新…"
        default:          return "点击展开更新操作"
        }
    }

    // MARK: - 操作区
    private var hasActions: Bool {
        switch updater.status {
        case .available, .downloading, .failed: return true
        default: return false
        }
    }

    @ViewBuilder
    private var actionArea: some View {
        switch updater.status {
        case .available:
            HStack(spacing: 8) {
                islandButton("更新并重启", primary: true) { updater.downloadAndInstall() }
                islandButton("忽略", primary: false) { updater.ignoreCurrent() }
            }
        case .downloading:
            HStack(spacing: 8) {
                Text("下载中，请稍候…")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))
                Spacer(minLength: 0)
                islandButton("取消", primary: false) { updater.cancelDownload() }
            }
        case .failed:
            HStack(spacing: 8) {
                islandButton("前往下载", primary: true) { updater.openRelease() }
                islandButton("重试", primary: false) { updater.checkForUpdates(force: true) }
            }
        default:
            EmptyView()
        }
    }

    private func islandButton(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(primary ? .white : .white.opacity(0.7))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background(
                    Capsule().fill(
                        AnyShapeStyle(primary ?
                            AnyShapeStyle(LinearGradient(colors: [Color.pink, Color.purple],
                                                         startPoint: .leading, endPoint: .trailing))
                            : AnyShapeStyle(Color.white.opacity(0.1)))
                    )
                )
        }
        .buttonStyle(.plain)
    }
}
