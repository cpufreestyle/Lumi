import SwiftUI
import AppKit

/// 快捷键与手势说明面板内容。
///
/// 用户要求「快捷键的提示要让用户有办法找到」：此前所有手势只写在代码注释与
/// 胶囊右键菜单里，没有任何可见入口。这里把 KeyboardShortcutCatalog 的目录渲染成
/// 一张可随时从菜单栏打开的清单。
///
/// 深浅色都用：PanelInk 会按当前外观取反差色，浅色底下字跟着压深，不会糊进玻璃。
struct KeyboardShortcutsHelpView: View {
    /// 关闭按钮：关掉承载本视图的面板（由控制器注入）。
    var onClose: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 14)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(KeyboardShortcutCatalog.sections) { section in
                        sectionBlock(section)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 468)
        .frame(maxHeight: 540)
        // 与项目其它浮层同一套 Liquid Glass：scrim 保证浅色下字与玻璃有反差，
        // 圆角统一 20 并裁子内容，避免出现「圆角旁多出的边角料」。
        .glassPanel(cornerRadius: 20, scrim: 0.35, stroke: 0.10)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "command")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(PanelInk.control)
            VStack(alignment: .leading, spacing: 3) {
                Text("快捷键与手势")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(PanelInk.primary)
                Text("鼠标手势与菜单栏入口汇总，随时可从菜单栏图标再来。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(PanelInk.secondary)
            }
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(PanelInk.tertiary)
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
    }

    @ViewBuilder
    private func sectionBlock(_ section: KeyboardShortcutCatalog.Section) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(section.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(PanelInk.secondary)
            VStack(spacing: 0) {
                ForEach(rows(section.entries), id: \.id) { row in
                    rowBody(row)
                }
            }
        }
    }

    /// 把分组条目转成「带分隔线信息」的扁平行，避免在 ForEach 里判断 index。
    private func rows(_ entries: [KeyboardShortcutCatalog.Entry]) -> [HelpRow] {
        Array(entries.enumerated()).map { index, entry in
            HelpRow(id: entry.id,
                    entry: entry,
                    isLast: index == entries.count - 1)
        }
    }

    private func rowBody(_ row: HelpRow) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Text(row.entry.keys)
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(PanelInk.control)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(PanelInk.chip(0.12))
                    .clipShape(Capsule(style: .continuous))
                    .fixedSize()
                Text(row.entry.action)
                    .font(.system(size: 11.5))
                    .foregroundStyle(PanelInk.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Text(row.entry.scope)
                    .font(.system(size: 10))
                    .foregroundStyle(PanelInk.tertiary)
                    .fixedSize()
            }
            if !row.isLast {
                Divider()
                    .opacity(0.25)
                    .padding(.vertical, 5)
            }
        }
    }
}

/// 一行说明：条目 + 是否为分组末行（末行不画分隔线）。
private struct HelpRow: Identifiable, Equatable {
    var id: String
    var entry: KeyboardShortcutCatalog.Entry
    var isLast: Bool
}
