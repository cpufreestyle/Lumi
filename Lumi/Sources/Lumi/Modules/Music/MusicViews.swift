import SwiftUI

// MARK: - 跑马灯文本（用于收缩态显示过长歌词/标题）
/// 恒定滚动速度（points/sec），长/短歌词观感一致，便于阅读。
struct MarqueeText: View {
    let text: String
    let font: Font
    /// 滚动速度：每列歌词在屏幕上移动的像素速度。恒定值保证不同长度歌词速度一致。
    var speed: Double = 40
    /// 一次滚动结束后停顿时长
    var pause: Double = 1.2

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var animating: Bool = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Text(text)
                    .font(font)
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .fixedSize()
                    .background(
                        GeometryReader { tg in
                            Color.clear.preference(key: WidthKey.self, value: tg.size.width)
                        }
                    )
                    .offset(x: offset)
            }
            .clipped()
            .onAppear { containerWidth = w; restart() }
            .onChange(of: w) { nv in containerWidth = nv; restart() }
            .onPreferenceChange(WidthKey.self) { nv in
                textWidth = nv
                restart()
            }
        }
    }

    /// 仅当文本超出容器时才滚动；速度恒定，长文本只是滚得更久而非更快。
    func restart() {
        animating = false
        offset = 0
        guard textWidth > containerWidth, containerWidth > 0 else { return }
        let distance = textWidth - containerWidth + 12
        let duration = max(distance / max(speed, 1), 0.1)
        animating = true
        // 先停顿，再平滑滚动整段，结束后循环
        DispatchQueue.main.asyncAfter(deadline: .now() + pause) {
            withAnimation(.linear(duration: duration)) {
                offset = -(textWidth + 12)
            }
        }
    }
}

struct WidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - 音乐模块：收缩态简要
struct MusicBriefContent: View {
    @ObservedObject private var music = MusicController.shared

    var body: some View {
        // 小胶囊只显示当前歌词（歌手名与黄色固定标志已移到 music 展开页头部）
        if music.isPlaying {
            if music.showLyrics, !music.currentLineText.isEmpty {
                // 当前歌词作为视觉焦点：尽量撑大
                MarqueeText(
                    text: music.currentLineText,
                    font: .system(size: 14.5, weight: .semibold)
                )
                .frame(height: 18)
            } else {
                let fallback = "\(music.title.isEmpty ? "正在播放" : music.title)\(music.artist.isEmpty ? "" : " - " + music.artist)"
                MarqueeText(text: fallback, font: .system(size: 14.5, weight: .semibold))
                    .frame(height: 18)
            }
        } else {
            Text("未在播放 · 打开音乐 App")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.6))
                .lineLimit(1)
        }
    }
}

// MARK: - 音乐模块：展开态完整视图
struct MusicExpandedView: View {
    @ObservedObject private var music = MusicController.shared
    @ObservedObject private var state = AppState.shared
    /// 卡片实际尺寸（随用户缩放变化）。据此让字幕字号与歌词区高度自适应卡片大小。
    @State private var viewSize: CGSize = CGSize(width: 360, height: 480)

    // 歌词字号随卡片宽度线性缩放：基准 360 宽 → 17pt，并夹紧在合理区间，
    // 卡片放大时字变大、缩小时字变小，始终与卡片尺寸协调。
    private var lyricBaseSize: CGFloat {
        let w = max(280, min(viewSize.width, 520))
        // 放大歌词基础字号：基准 360 宽 → 19pt（原 17），上限提到 26
        return min(26, max(17, 19 * (w / 360)))
    }
    private var lyricActiveSize: CGFloat { lyricBaseSize + 3 }
    private var translationSize: CGFloat {
        let w = max(280, min(viewSize.width, 520))
        return min(20, max(14, 16 * (w / 360)))
    }
    // 歌词区高度随卡片高度比例自适应（卡片越高，可展示的歌词越多）。
    // 已移除顶部音频频谱可视化，把原频谱占用的空间（约 40pt）补偿给歌词区，
    // 让歌词区更舒展、不再留白。整体尽量撑大：基准映射到更高区间。
    private var lyricAreaHeight: CGFloat {
        let h = max(360, min(viewSize.height, 720))
        // 360→180，720→360 线性映射（尽量撑大歌词区）
        return min(380, max(160, 180 + (h - 360) / (720 - 360) * (360 - 180)))
    }
    // 专辑封面随卡片宽度等比缩放：基准 360 宽 → 160，夹在 120–240。
    private var artworkSize: CGFloat {
        let w = max(280, min(viewSize.width, 520))
        return min(240, max(120, 160 * (w / 360)))
    }

    var body: some View {
        // 整体包一层 ScrollView：面板高度上限内内容超出时整块滚动，
        // 避免底部歌词区被裁切（尤其播放中带频谱时总高超上限）。
        GeometryReader { geo in
            ScrollView {
            // 缩放拖拽期间：把内容区尺寸冻结为拖拽前的 viewSize，并裁剪，
            // 避免窗口每帧变大导致 SwiftUI 对几十行歌词/封面做整树重排（卡顿主因）。
            // 松手 (isResizing=false) 后才由下方 onChange 一次性按最终尺寸重排。
            VStack(spacing: 0) {
                // 顶部固定头部：左侧歌手名、右侧黄色固定标志，占固定位置不随内容滚动
                headerBar
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                // 专辑封面
                albumArtworkSection
                    .padding(.top, 12)

            // 歌曲信息（歌手名已移至顶部固定头部，此处只留歌名，省出空间给歌词）
            VStack(spacing: 2) {
                Text(music.title.isEmpty ? "未在播放" : music.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.top, 10)

            // 进度条
            progressSection
                .padding(.horizontal, 24)
                .padding(.top, 16)

            // 播放控制按钮
            controlButtons
                .padding(.top, 12)

            // 音量控制
            volumeSection

            // 歌词
            lyricsSection
                .padding(.horizontal, 24)
                .padding(.top, 10)
                .padding(.bottom, 16)
            }
            // 缩放拖拽期间：把内容 VStack 尺寸钉死在拖拽前的大小并裁剪，
            // 窗口 frame 即便每帧变化，内部几十行歌词/封面不再重排，松手后一次性重排。
            .frame(
                width: state.isResizing ? viewSize.width : nil,
                height: state.isResizing ? viewSize.height : nil,
                alignment: .top
            )
            .clipped()
            // 缩放拖拽期间冻结 viewSize：避免每帧重建几十行歌词造成卡顿，
            // 松手（isResizing=false）后下一帧再一次性应用最终尺寸并重排。
            .onChange(of: geo.size) { nv in
                if !AppState.shared.isResizing { viewSize = nv }
            }
            }
        }
    }

    // MARK: 顶部固定头部：歌手名（左） + 黄色固定标志（右）
    var headerBar: some View {
        HStack(spacing: 8) {
            Text(music.artist.isEmpty ? "歌手" : music.artist)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.6))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    AppState.shared.islandPinned.toggle()
                }
            } label: {
                Image(systemName: AppState.shared.islandPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(AppState.shared.islandPinned ? .yellow : .white.opacity(0.5))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help(AppState.shared.islandPinned ? "取消固定小胶囊" : "固定小胶囊（常驻显示）")
        }
    }

    // MARK: 专辑封面
    var albumArtworkSection: some View {
        Group {
            let size = artworkSize
            if let artwork = music.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
            } else {
                RoundedRectangle(cornerRadius: 14)
                    .fill(
                        LinearGradient(
                            colors: [Color.pink.opacity(0.5), Color.purple.opacity(0.5)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: size, height: size)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.31))
                            .foregroundColor(.white.opacity(0.5))
                    )
                    .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
            }
        }
    }

    // MARK: 进度条
    var progressSection: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.2))
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(
                            LinearGradient(
                                colors: [Color.pink, Color.purple],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(
                            width: music.duration > 0
                                ? geo.size.width * (music.currentTime / music.duration)
                                : 0,
                            height: 4
                        )
                }
                // 点击 / 拖动进度条跳转到对应位置
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard music.duration > 0 else { return }
                        let ratio = min(1, max(0, value.location.x / geo.size.width))
                        music.seek(to: ratio * music.duration)
                    }
                )
            }
            .frame(height: 4)
            .padding(.vertical, 8)

            HStack {
                Text(formatTime(music.currentTime))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                Spacer()
                Text(formatTime(music.duration))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
    }

    // MARK: 播放控制
    var controlButtons: some View {
        HStack(spacing: 28) {
            Button(action: { MusicController.shared.previousTrack() }) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.white.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help("上一首")

            Button(action: { MusicController.shared.skip(by: -15) }) {
                Image(systemName: "gobackward.15")
                    .font(.system(size: 20))
                    .foregroundColor(.white.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help("快退 15 秒")

            Button(action: { MusicController.shared.togglePlayPause() }) {
                Image(systemName: music.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.white)
                    .frame(width: 52, height: 52)
                    .background(
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.pink, Color.purple],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
            }
            .buttonStyle(.plain)

            Button(action: { MusicController.shared.skip(by: 15) }) {
                Image(systemName: "goforward.15")
                    .font(.system(size: 20))
                    .foregroundColor(.white.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help("快进 15 秒")

            Button(action: { MusicController.shared.nextTrack() }) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.white.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help("下一首")
        }
    }

    // MARK: 音量控制
    var volumeSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.wave.1.fill")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.5))
            Slider(value: Binding(
                get: { Double(max(0, music.volume)) },
                set: { music.setVolume(Int($0)) }
            ), in: 0...100, step: 1)
            .frame(maxWidth: .infinity)
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.5))
            Text("\(max(0, music.volume))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.6))
                .frame(width: 26, alignment: .trailing)
        }
        .padding(.horizontal, 24)
        .padding(.top, 6)
    }

    func formatTime(_ t: TimeInterval) -> String {
        let m = Int(t) / 60, s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: 歌词区
    var lyricsSection: some View {
        // 用户可在右侧开关隐藏整块歌词
        Group {
            if music.showLyrics {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("歌词")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.45))

                        // 时间轴校准滑块：放在「歌词」标题右侧。
                        // 社区 LRC 时间轴常与播放位置有整体偏移，可手动对齐当前播放行。
                        if !music.syncedLines.isEmpty,
                           (music.lyricsOffset != 0 || music.playbackState == .playing) {
                            Text("校准")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.45))
                            Slider(value: $music.lyricsOffset, in: -10...10, step: 0.5)
                                .frame(width: 90)
                            Text(String(format: "%+.1fs", music.lyricsOffset))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.white.opacity(0.6))
                                .frame(width: 40, alignment: .trailing)
                        }

                        Spacer()

                        // 双语模式分段切换：原文 / 双语
                        HStack(spacing: 0) {
                            ForEach(MusicController.BilingualMode.allCases, id: \.self) { mode in
                                Button(action: { music.bilingualMode = mode }) {
                                    let label = mode == .off ? "原" : (mode == .auto ? "双" : "译")
                                    Text(label)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(
                                            music.bilingualMode == mode
                                                ? .white
                                                : .white.opacity(0.4)
                                        )
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(
                                            music.bilingualMode == mode
                                                ? Color.white.opacity(0.18)
                                                : Color.clear
                                        )
                                        .cornerRadius(4)
                                }
                                .buttonStyle(.plain)
                                .help(mode.label)
                            }
                        }

                        Button(action: { music.showLyrics = false }) {
                            Image(systemName: "eye.slash")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.45))
                        }
                        .buttonStyle(.plain)
                        .help("隐藏歌词")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if music.lyrics.isEmpty {
                        Text("当前歌曲暂无歌词")
                            .font(.system(size: lyricBaseSize))
                            .foregroundColor(.white.opacity(0.4))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if !music.syncedLines.isEmpty {
                        // Apple Music 官方歌词（带时间轴）：逐行高亮当前播放行。
                        LyricsSyncView(lines: music.syncedLines,
                                       currentTime: music.currentTime,
                                       offset: music.lyricsOffset,
                                       baseSize: lyricBaseSize,
                                       activeSize: lyricActiveSize,
                                       translationSize: translationSize) { delta in
                            // 一键对齐：用户点击「当前在唱」的那行，反推 offset 并夹在 ±10s
                            var v = delta
                            v = max(-10, min(10, v))
                            v = round(v / 0.5) * 0.5
                            music.lyricsOffset = v
                        }
                            .frame(maxHeight: lyricAreaHeight)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(music.lyrics)
                                    .font(.system(size: lyricBaseSize))
                                    .foregroundColor(.white.opacity(0.78))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .lineSpacing(4)
                                if music.bilingualMode != .off,
                                   !music.lyricsTranslation.isEmpty {
                                    Text(music.lyricsTranslation)
                                        .font(.system(size: translationSize))
                                        .foregroundColor(.white.opacity(0.45))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .lineSpacing(3)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .frame(maxHeight: lyricAreaHeight)
                    }
                }
            } else {
                // 已隐藏：提供「显示歌词」入口
                Button(action: { music.showLyrics = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "eye")
                            .font(.system(size: 11))
                        Text("显示歌词")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Apple Music 逐行高亮歌词
/// 根据当前播放进度高亮对应歌词行，并自动滚动到该行。
struct LyricsSyncView: View {
    let lines: [SyncedLine]
    let currentTime: TimeInterval
    /// 时间轴校准偏移（秒）。正值表示歌词时间轴比实际播放快，需要把匹配基准往后推。
    var offset: TimeInterval = 0
    /// 字号（由卡片大小自适应传入）：普通行 / 当前高亮行 / 翻译行
    var baseSize: CGFloat = 13
    var activeSize: CGFloat = 14
    var translationSize: CGFloat = 11
    /// 点击某行即「一键对齐」：该行此刻应在唱，自动算出 offset = 行时间 - 当前进度。
    var onAlign: ((TimeInterval) -> Void)? = nil

    /// 当前应高亮的行索引：最后一个 time <= (currentTime - offset) 的行（time<0 视为无时间轴，不高亮）。
    private var adjustedTime: TimeInterval { currentTime - offset }
    private var activeIndex: Int? {
        var idx: Int?
        for (i, line) in lines.enumerated() {
            guard line.time >= 0 else { continue }
            if line.time <= adjustedTime { idx = i }
            else { break }
        }
        return idx
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(line.text)
                                .font(.system(size: i == activeIndex ? activeSize : baseSize,
                                              weight: i == activeIndex ? .semibold : .regular))
                                .foregroundColor(
                                    i == activeIndex ? Color.pink : .white.opacity(0.5)
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineSpacing(4)
                            if let tr = line.translation, !tr.isEmpty {
                                Text(tr)
                                    .font(.system(size: translationSize,
                                                  weight: .regular))
                                    .foregroundColor(.white.opacity(i == activeIndex ? 0.7 : 0.38))
                                    .frame(maxWidth: .infinity, alignment: .leading)
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
            .frame(maxHeight: 140)
            // 当前行变化时平滑滚动到它（居中），仅在播放且确有时间轴时进行
            .onChange(of: activeIndex) { newIndex in
                guard let newIndex = newIndex else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }
}
