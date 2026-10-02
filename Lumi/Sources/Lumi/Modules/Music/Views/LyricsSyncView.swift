import SwiftUI

/// 根据当前播放进度高亮对应歌词行，并自动滚动到该行。
struct LyricsSyncView: View {
    let lines: [SyncedLine]
    let currentTime: TimeInterval
    /// 当前双语模式（决定译文占位/隐藏）。
    var bilingual: MusicController.BilingualMode = .auto
    /// 时间轴校准偏移（秒）。正值表示歌词时间轴比实际播放快，需要把匹配基准往后推。
    var offset: TimeInterval = 0
    /// 字号（由卡片大小自适应传入）：普通行 / 当前高亮行 / 翻译行
    var baseSize: CGFloat = 13
    var activeSize: CGFloat = 14
    var translationSize: CGFloat = 11
    /// 点击某行即「一键对齐」：该行此刻应在唱，自动算出 offset = 行时间 - 当前进度。
    var onAlign: ((TimeInterval) -> Void)? = nil

    /// 防抖：上次确定的高亮行。歌词在行切换边界附近时，Music 真值回调可能比
    /// 补间进度略旧，把高亮暂时拉回上一行。为消除这种回退闪烁，保留
    /// retreatHysteresis 的回退余量；前进方向不再加滞后，否则每行都会固定
    /// 晚 0.12s 才切换，听感就是“歌词时序不准”。
    @State private var debouncedIndex: Int? = nil

    /// 当前应高亮的行索引：最后一个 time <= (currentTime - offset) 的行（time<0 视为无时间轴，不高亮）。
    private var adjustedTime: TimeInterval { currentTime - offset }
    /// 纯时间轴算出的理想高亮行（最后一个 time <= adjustedTime）。
    private var rawActiveIndex: Int? {
        LyricsTimeline.activeLineIndex(lines: lines, adjustedTime: adjustedTime)
    }

    /// 防抖后的高亮行：边界附近不轻易切换，消除来回跳动。
    /// 与收缩态胶囊 / 桌面浮窗共用同一套防抖规则（LyricsTimeline），
    /// 否则三个界面会在同一时刻显示不同句子。
    private var activeIndex: Int? {
        LyricsTimeline.debouncedLineIndex(raw: rawActiveIndex,
                                         prev: debouncedIndex,
                                         lines: lines,
                                         adjustedTime: adjustedTime)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .center, spacing: 7) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        // 双语并排组：原文（上）+ 译文（下）上下紧贴，成对成组显示
                        // 逐行双语对字号：英文行不低于中文行（用户要求「英文大于或等于中文」）
                        let pairSizes = DesktopLyricsLayout.bilingualSizes(
                            originalBase: i == activeIndex ? activeSize : baseSize,
                            translationBase: translationSize,
                            original: line.text,
                            translation: line.translation ?? "",
                            wantsTranslation: bilingual != .off && !(line.translation ?? "").isEmpty)
                        VStack(alignment: .center, spacing: 1) {
                            Text(line.text)
                                .font(.system(size: pairSizes.original,
                                              weight: i == activeIndex ? .semibold : .regular))
                                .foregroundColor(
                                    i == activeIndex ? LyricsInk.zh : LyricsInk.secondary
                                )
                                .frame(maxWidth: .infinity, alignment: .center)
                                .multilineTextAlignment(.center)
                                .lineSpacing(4)
                            // 双语模式：每行都预留译文位置，译文缺失时显示占位，
                            // 翻译到达后自动替换（translation 是 @Published，行会刷新）。
                            if bilingual != .off, let tr = line.translation, !tr.isEmpty {
                                Text(tr)
                                    .font(.system(size: pairSizes.translation, weight: .regular))
                                    .foregroundColor(LyricsInk.en.opacity(i == activeIndex ? 0.95 : 0.6))
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .multilineTextAlignment(.center)
                                    .lineSpacing(3)
                            }
                        }
                        .id(i)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // 点击即对齐：该行此刻应在唱，反推 offset
                            guard line.time >= 0 else { return }
                            onAlign?(line.time - currentTime)
                        }
                        .animation(.easeInOut(duration: 0.2), value: i == activeIndex)
                    }
                    .padding(.vertical, 4)
                }
                .padding(.horizontal, 4)
            }
            .frame(maxHeight: .infinity)
            // 首次出现即同步防抖状态。onChange 在视图首次出现时不触发，
            // 若不在这里播种，播放中打开面板会让第一帧走「无历史」分支 ——
            // 本身能得到正确结果，但紧接着的第一次 onChange 会把 prev 当作
            // nil 再判一次，可能让防抖余量在第一句上失效（前奏抖动会被放大）。
            .onAppear {
                // 直接用时间轴结果播种：此时还没有历史，防抖等价于采纳 raw
                let resolved = rawActiveIndex
                if debouncedIndex != resolved {
                    debouncedIndex = resolved
                }
            }
            // 当前行变化时平滑滚动到它（居中），仅在播放且确有时间轴时进行。
            // 用 raw 而非防抖后的 activeIndex 触发滚动：滚动应跟上时间轴的
            // 真实推进，而防抖只服务于高亮稳定性，两者目的不同。
            .onChange(of: rawActiveIndex) { _, newIndex in
                guard let newIndex = newIndex else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
            // 播放中打开面板：首帧就要滚到正在唱的那句，否则用户看到的是
            // 歌词开头，而胶囊已经在唱中段 —— 观感就是「歌词和歌声对不上」。
            // 这里必须晚一帧执行：ScrollViewReader 的 proxy 在 onAppear 时
            // 尚未完成首次布局，立即 scrollTo 会被忽略。
            .onAppear {
                guard let seed = rawActiveIndex else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(seed, anchor: .center)
                }
            }
            // 换了一整套时间轴（换源命中 / 翻译重建）时重置防抖状态：
            /// @State 在视图生命周期内持久，不会因为 lines 被替换而自动清空。
            /// 旧索引在新数组里指向完全不同的行 —— 防抖基于错误的前提工作，
            /// 用户看到的就是「切到新歌词后高亮跳错位置」。
            .onChange(of: lines) { _, newLines in
                debouncedIndex = LyricsTimeline.activeLineIndex(
                    lines: newLines, adjustedTime: adjustedTime)
            }
            // 防抖状态推进：紧跟时间轴，不等 UI 帧
            .onChange(of: adjustedTime) { _, _ in
                let resolved = activeIndex
                if resolved != debouncedIndex {
                    debouncedIndex = resolved
                }
            }
        }
    }
}
