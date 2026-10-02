import AppKit
import SwiftUI

struct AIActionBar: View {
    @ObservedObject private var ai = AIAssistController.shared

    var body: some View {
        // 整条动作条 = 一组相近且需共享采样的玻璃：容器（圆角矩形）+ 动作钮
        // （胶囊）同处一个 GlassEffectContainer，与桌面歌词控制条同一套皮肤。
        glassGroup(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(AIAction.builtins) { action in
                    Button { ai.runAction(action) } label: {
                        HStack(spacing: 3) {
                            Image(systemName: action.icon)
                            Text(action.title)
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(PanelInk.text(0.9))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    // 玻璃长在按钮自己身上（skill 点名「最常见的错误」反例）；
                    // 粉色 tint 只为标识动作，不做装饰。
                    .glassButton(tint: Color.pink.opacity(0.3))
                }
                Button { ai.dismissActionBar() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(PanelInk.text(0.5))
                        .padding(4)
                }
                .buttonStyle(.plain)
                .glassButton()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        // 容器换系统玻璃：tint + legacy scrim 保持原来的深色可读性
        .glassPanel(cornerRadius: 18, tint: Color.black.opacity(0.35),
                    scrim: 0.62, stroke: 0.12)
        .transition(.opacity)
    }
}
