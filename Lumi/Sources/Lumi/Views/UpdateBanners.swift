import SwiftUI

// MARK: - 手动检查反馈条（已是最新 / 失败原因，几秒后自动消失）
// 注：更新状态与操作已统一收敛到顶部黑色岛（DynamicIslandStatusView），
// 以下 UpdateFeedbackBanner / UpdateAvailableBanner 两个独立横幅不再渲染，保留定义供后续复用。
struct UpdateFeedbackBanner: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        // 仅当存在手动检查反馈时显示；与 showUpdateBanner 解耦，
        // 即使 status == .upToDate（图标变绿）也能看到明确提示。
        if let feedback = updater.manualCheckFeedback {
            HStack(spacing: 8) {
                Image(systemName: feedbackIcon)
                    .font(.system(size: 14))
                    .foregroundColor(feedbackColor)
                Text(feedback)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                Spacer()
                Button(action: { updater.manualCheckFeedback = nil }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                        .padding(5)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(feedbackColor.opacity(0.3), lineWidth: 0.5))
            )
            .padding(.horizontal, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.25), value: updater.manualCheckFeedback)
        }
    }

    private var feedbackIcon: String {
        if (updater.manualCheckFeedback ?? "").contains("失败") { return "exclamationmark.circle" }
        if (updater.manualCheckFeedback ?? "").contains("新版本") { return "arrow.down.circle.fill" }
        return "checkmark.circle"
    }
    private var feedbackColor: Color {
        if (updater.manualCheckFeedback ?? "").contains("失败") { return .orange }
        if (updater.manualCheckFeedback ?? "").contains("新版本") { return .green }
        return .green
    }
}

// MARK: - 新版本可用浮层（发现更新时提示）
struct UpdateAvailableBanner: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        // 仅在有新版本 / 下载中 / 失败等需要常驻提示时渲染原浮层；
        // 手动检查的短暂反馈（已是最新等）由独立的 UpdateFeedbackBanner 负责。
        if shouldShow {
            VStack(alignment: .leading, spacing: 8) {
                // 头部：图标 + 标题/副标题 + 关闭按钮（始终右上角）
                HStack(spacing: 10) {
                    Image(systemName: iconName)
                        .font(.system(size: 18))
                        .foregroundColor(accentTint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(titleText)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                        Text(subtitleText)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    Spacer()
                    Button(action: { updater.dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))
                            .padding(6)
                    }
                    .buttonStyle(.plain)
                    .help("关闭提示")
                }
                // 操作按钮行（独立一行，避免与标题挤压重叠）
                actionRow
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(accentTint.opacity(0.3), lineWidth: 0.5))
            )
            .padding(.horizontal, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.25), value: updater.status)
        }
    }

    /// 操作按钮独立成一行（HStack 自适应宽度，防止与标题行重叠）
    @ViewBuilder
    private var actionRow: some View {
        switch updater.status {
        case .available:
            HStack(spacing: 8) {
                Button(action: { updater.downloadAndInstall() }) {
                    Text("更新并重启")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(LinearGradient(colors: [Color.pink, Color.purple], startPoint: .leading, endPoint: .trailing))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .help("自动下载并安装此更新")
                Button(action: { updater.ignoreCurrent() }) {
                    Text("忽略")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.2)))
                }
                .buttonStyle(.plain)
                .help("不再提示此版本")
            }
        case .downloading:
            HStack(spacing: 8) {
                Text("下载中…")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.6))
                Spacer()
                Button(action: { updater.cancelDownload() }) {
                    Text("取消")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.2)))
                }
                .buttonStyle(.plain)
                .help("取消下载")
            }
        case .failed:
            HStack(spacing: 8) {
                Button(action: { updater.openRelease() }) {
                    Text("前往下载")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(LinearGradient(colors: [Color.pink, Color.purple], startPoint: .leading, endPoint: .trailing))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .help("打开下载页面")
            }
        default:
            EmptyView()
        }
    }

    private var shouldShow: Bool {
        switch updater.status {
        case .available, .downloading, .readyToInstall, .failed:
            // 失败也可能展示（提示回退到网页）；忽略/稍后的版本不展示
            if let latest = updater.latestVersion,
               (latest == updater.ignoredVersion || latest == updater.skippedVersion) {
                return false
            }
            return true
        default:
            return false
        }
    }

    private var iconName: String {
        if case .downloading = updater.status { return "arrow.down.circle" }
        if case .readyToInstall = updater.status { return "checkmark.circle.fill" }
        if case .failed = updater.status { return "exclamationmark.circle" }
        return "arrow.down.circle.fill"
    }

    /// 手动检查反馈的图标（按文字内容判断成功/失败）
    private var feedbackIcon: String {
        if (updater.manualCheckFeedback ?? "").contains("失败") { return "exclamationmark.circle" }
        if (updater.manualCheckFeedback ?? "").contains("新版本") { return "arrow.down.circle.fill" }
        return "checkmark.circle"
    }
    private var feedbackColor: Color {
        if (updater.manualCheckFeedback ?? "").contains("失败") { return .orange }
        if (updater.manualCheckFeedback ?? "").contains("新版本") { return .green }
        return .green
    }

    private var titleText: String {
        switch updater.status {
        case .available:      return "新版本 v\(updater.latestVersion ?? "") 可用"
        case .downloading:   return "正在下载更新…"
        case .readyToInstall:return "更新已就绪，即将重启"
        case .failed(let m): return "更新失败：\(m)"
        default:             return "更新"
        }
    }

    private var subtitleText: String {
        switch updater.status {
        case .downloading(let p): return "\(Int(p * 100))% · 当前 v\(updater.currentVersion)"
        case .failed:            return "可前往网页手动下载"
        default:                 return "当前 v\(updater.currentVersion)"
        }
    }

    private var accentTint: Color {
        switch updater.status {
        case .available:  return .green
        case .failed:     return .orange
        case .upToDate:   return .white.opacity(0.5)
        default:          return .white.opacity(0.5)
        }
    }

}
