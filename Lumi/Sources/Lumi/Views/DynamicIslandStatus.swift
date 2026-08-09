import SwiftUI

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
                    statusIcon
                    statusText
                    Spacer(minLength: 0)
                    if expanded {
                        Image(systemName: islandOpen ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.4))
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
        .background(
            Capsule()
                .fill(Color.black.opacity(0.92))
                .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
        )
        // 展开操作区时岛不再是纯胶囊，改为大圆角矩形
        .clipShape(islandOpen && expanded && hasActions ?
                   RoundedRectangle(cornerRadius: 18) : Capsule())
    }

    // MARK: - 状态
    private var statusIcon: some View {
        Image(systemName: iconName)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(iconColor)
            .frame(width: 18, height: 18)
            .overlay(
                Group {
                    if case .checking = updater.status {
                        ProgressView().scaleEffect(0.4)
                            .frame(width: 18, height: 18)
                    }
                }
            )
    }

    private var statusText: some View {
        Text(label)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.white)
            .lineLimit(1)
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
                        primary ?
                        LinearGradient(colors: [Color.pink, Color.purple],
                                       startPoint: .leading, endPoint: .trailing)
                        : Color.white.opacity(0.1)
                    )
                )
        }
        .buttonStyle(.plain)
    }
}
