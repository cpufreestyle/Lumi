import SwiftUI

/// 收缩态副标题：一眼看出「有没有电视在控、连的是哪台」。
/// 不展示按钮——胶囊空间极小，遥控操作交给展开态。
struct TVBriefView: View {
    @ObservedObject private var tv = TVController.shared

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "tv.fill")
                .font(.system(size: 12))
                .foregroundColor(tv.status.connected ? .pink : .white.opacity(0.5))
            Text(briefText)
                .font(.system(size: 12))
                .foregroundColor(PanelInk.text(0.7))
                .lineLimit(1)
        }
    }

    private var briefText: String {
        guard tv.status.serviceReachable else { return "电视遥控 · 服务未连接" }
        guard tv.status.hasDevice else { return "电视遥控 · 未选设备" }
        let name = tv.status.deviceName ?? "电视"
        return tv.status.connected ? "\(name) · 遥控就绪" : "\(name) · 离线"
    }
}
