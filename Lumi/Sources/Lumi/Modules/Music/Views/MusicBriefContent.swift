import SwiftUI

/// 收缩态胶囊的歌词内容：布局与桌面歌词浮窗保持一致 ——
/// 原文一行 + 译文一行（0 间距贴合、原文红色高亮、译文青色）。
///
/// 历史上这里是单行 MarqueeText（只显示原文），与桌面浮窗的两行结构不一致；
/// 用户要求「胶囊歌词布局和桌面的一模一样」，故改为同一套两行结构。
/// 档位字号同样复用 DesktopLyricsSizePreset 与 latinScale，单一数据源不分叉。
struct MusicBriefContent: View {
    @ObservedObject private var music = MusicController.shared
    /// 悬停态：驱动控制条显隐，与桌面浮窗「hover 才出按钮」一致
    @State private var hovering = false

    var body: some View {
        content
            // 控制条放在右上角，与桌面歌词浮窗同一套定位（edgeInset 内边距）。
            // 注意：本视图当前不在真实渲染路径上——收缩态胶囊实际渲染的是
            // IslandViews.CollapsedView 自带的歌词块（见里面 topTrailing overlay），
            // moduleBriefView / MusicBriefView 无人引用。这里保持一致只为不留误导。
            .overlay(alignment: .topTrailing) {
                if music.desktopLyricsEnabled {
                    CapsuleLyricsControls(music: music, visible: hovering) {
                        music.hideDesktopLyricsWindow()
                    }
                    .padding(DesktopLyricsControlsMetrics.edgeInset)
                }
            }
            .onHover { hovering = $0 }
    }

    /// 歌词主体：原文 + 译文两行；未播放时给一句提示。
    @ViewBuilder
    private var content: some View {
        if music.isPlaying {
            let pair = music.currentLyricPair
            let showLyrics = music.showLyrics && !pair.text.isEmpty
            let displayLine = showLyrics
                ? pair.text
                : "\(music.title.isEmpty ? "正在播放" : music.title)\(music.artist.isEmpty ? "" : " - " + music.artist)"
            let wantTranslation = music.bilingualMode != .off && showLyrics && !pair.translation.isEmpty

            VStack(spacing: 0) {
                Text(displayLine)
                    .font(.system(
                        size: DesktopLyricsLayout.scaledOriginalFontSize(music.desktopLyricsSizePreset,
                                                                          line: displayLine),
                        weight: .semibold, design: .rounded))
                    .foregroundColor(showLyrics ? .red : .white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if wantTranslation {
                    Text(pair.translation)
                        .font(.system(
                            size: DesktopLyricsLayout.scaledTranslationFontSize(music.desktopLyricsSizePreset,
                                                                                  line: pair.translation)))
                        .foregroundColor(PanelInk.cyan)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .minimumScaleFactor(0.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            Text("未在播放 · 打开音乐 App")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(PanelInk.text(0.6))
                .lineLimit(1)
        }
    }
}
