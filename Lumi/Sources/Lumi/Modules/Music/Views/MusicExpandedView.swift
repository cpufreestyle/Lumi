import SwiftUI
import AppKit

/// 展开面板是系统玻璃底，跟随 macOS 明暗外观：浅色玻璃=深墨字、深色玻璃=浅白字。
/// 两种模式下文字都与背景保持反差——固定单色必有一头糊进背景。
enum LyricsInk {
    /// 明暗双色：浅底=黑(light)，深底=白(dark)。
    private static func mono(_ light: Double, _ dark: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? .white.withAlphaComponent(dark)
                : .black.withAlphaComponent(light)
        })
    }

    /// 彩色明暗双色（当前行 / 译文）：深底下提亮保证反差。
    private static func duo(_ light: (Double, Double, Double),
                            _ dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(calibratedRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }

    /// 正文：歌词原文 / 空态提示
    static let primary = mono(0.15, 0.95)
    /// 次要文字与图标：标题行、工具栏、时间、歌手
    static let secondary = mono(0.50, 0.68)
    /// 弱化数值：校准偏移等
    static let tertiary = mono(0.62, 0.50)
    /// 播放控制按钮
    static let control = mono(0.20, 0.85)
    /// 进度条 / 滑轨底
    static let track = mono(0.22, 0.24)
    /// 弱标签底色（modelPicker）：浅底淡黑罩、深底淡白罩
    static let chip = mono(0.06, 0.10)
    /// 当前中文行
    static let zh = duo((0.78, 0.10, 0.22), (1.00, 0.45, 0.55))
    /// 译文 / 英文行：浅底上的系统青不可读，换深青
    static let en = duo((0.0, 0.50, 0.60), (0.35, 0.85, 0.95))
}

struct MusicExpandedView: View {
    /// 面板玻璃跟随系统外观；文字与药丸据此切换，明暗两种模式下都有反差。
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var music = MusicController.shared
    @ObservedObject private var state = AppState.shared
    /// 卡片实际尺寸（随用户缩放变化）。据此让字幕字号与歌词区高度自适应卡片大小。
    @State private var viewSize: CGSize = CGSize(width: 360, height: 480)

    // 歌词字号随卡片宽度线性缩放：基准 360 宽 → 17pt，并夹紧在合理区间，
    // 卡片放大时字变大、缩小时字变小，始终与卡片尺寸协调。
    private var lyricBaseSize: CGFloat {
        let w = max(280, min(viewSize.width, 520))
        // 放大歌词基础字号：基准 360 宽 → 22pt，上限提到 30
        return min(30, max(19, 22 * (w / 360)))
    }
    private var lyricActiveSize: CGFloat { lyricBaseSize + 3 }
    private var translationSize: CGFloat {
        let w = max(280, min(viewSize.width, 520))
        return min(23, max(15, 18 * (w / 360)))
    }
    // 歌词区高度随卡片高度比例自适应（卡片越高，可展示的歌词越多）。
    // 已移除顶部音频频谱可视化，把原频谱占用的空间（约 40pt）补偿给歌词区，
    // 让歌词区更舒展、不再留白。整体尽量撑大：基准映射到更高区间。
    private var lyricAreaHeight: CGFloat {
        let h = max(360, min(viewSize.height, 720))
        // 360→220，720→420 线性映射（歌词区尽可能撑大）
        return min(420, max(200, 220 + (h - 360) / (720 - 360) * (420 - 220)))
    }
    // 专辑封面随卡片宽度等比缩放：基准 360 宽 → 160，夹在 120–240。
    private var artworkSize: CGFloat {
        let w = max(280, min(viewSize.width, 520))
        return min(240, max(120, 160 * (w / 360)))
    }

    /// 药丸条底色上下文：深色外观走浮窗同款玻璃药丸，浅色外观走显式石墨填充。
    private var glassContext: LyricsGlass.Context { colorScheme == .dark ? .dark : .light }

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
                    .padding(.top, 8)

                // 专辑封面
                albumArtworkSection
                    .padding(.top, 8)

            // 歌曲信息（歌手名已移至顶部固定头部，此处只留歌名，省出空间给歌词）
            VStack(spacing: 2) {
                Text(music.title.isEmpty ? "未在播放" : music.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(PanelInk.primary)
                    .shadow(color: .black.opacity(0.6), radius: 4, x: 0, y: 1)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)

            // 进度条
            progressSection
                .padding(.horizontal, 24)
                .padding(.top, 12)

            // 播放控制按钮
            controlButtons
                .padding(.top, 10)

            // 音量控制
            volumeSection

            // 歌词
            lyricsSection
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 12)
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
            .onChange(of: geo.size) { _, nv in
                if !AppState.shared.isResizing { viewSize = nv }
            }
            }
        }
    }

    // MARK: 顶部固定头部：歌手名（左）。固定/取消固定已改为「双击刘海」触发，故移除固定按钮。
    var headerBar: some View {
        HStack(spacing: 8) {
            Text(music.artist.isEmpty ? "歌手" : music.artist)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(LyricsInk.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            modelPicker
        }
    }

    /// 顶部右侧：翻译模型选择器。默认阶跃 StepFun（step-3.5-flash），可在菜单内切换；
    /// 选中项持久化（UserDefaults），供翻译通道按模型驱动端点与 key。
    private var modelPicker: some View {
        Menu {
            ForEach(MusicController.availableTranslateModels) { opt in
                Button {
                    music.selectedTranslateModelID = opt.id
                } label: {
                    if opt.id == music.selectedTranslateModelID {
                        Label(opt.label, systemImage: "checkmark")
                    } else {
                        Text(opt.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "cpu")
                    .font(.system(size: 11))
                Text(music.selectedTranslateOption.label)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(LyricsInk.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(LyricsInk.chip)
            .cornerRadius(6)
        }
        .menuStyle(.borderlessButton)
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
                            .foregroundColor(LyricsInk.secondary)
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
                        .fill(LyricsInk.track)
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
            .padding(.vertical, 2)

            HStack {
                Text(formatTime(music.currentTime))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(LyricsInk.secondary)
                Spacer()
                Text(formatTime(music.duration))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(LyricsInk.secondary)
            }
        }
    }

    // MARK: 播放控制
    var controlButtons: some View {
        HStack(spacing: 20) {
            Button(action: { MusicController.shared.previousTrack() }) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 20))
                    .foregroundColor(LyricsInk.control)
            }
            .buttonStyle(.plain)
            .help("上一首")

            Button(action: { MusicController.shared.skip(by: -15) }) {
                Image(systemName: "gobackward.15")
                    .font(.system(size: 20))
                    .foregroundColor(LyricsInk.control)
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
                    .foregroundColor(LyricsInk.control)
            }
            .buttonStyle(.plain)
            .help("快进 15 秒")

            Button(action: { MusicController.shared.nextTrack() }) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 20))
                    .foregroundColor(LyricsInk.control)
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
                .foregroundColor(LyricsInk.secondary)
            Slider(value: Binding(
                get: { Double(max(0, music.volume)) },
                set: { music.setVolume(Int($0)) }
            ), in: 0...100, step: 1)
            .frame(maxWidth: .infinity)
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 12))
                .foregroundColor(LyricsInk.secondary)
            Text("\(max(0, music.volume))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(LyricsInk.tertiary)
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
                            .foregroundColor(LyricsInk.secondary)

                        // 时间轴校准滑块：放在「歌词」标题右侧。
                        // 社区 LRC 时间轴常与播放位置有整体偏移，可手动对齐当前播放行。
                        if !music.syncedLines.isEmpty,
                           (music.lyricsOffset != 0 || music.playbackState == .playing) {
                            Text("校准")
                                .font(.system(size: 10))
                                .foregroundColor(LyricsInk.secondary)
                            Button(action: {
                                music.lyricsOffset = max(-10, music.lyricsOffset - 0.1)
                            }) {
                                Image(systemName: "minus.circle")
                                    .font(.system(size: 11))
                                    .foregroundColor(LyricsInk.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("歌词延后 0.1 秒")
                            Slider(value: $music.lyricsOffset, in: -10...10, step: 0.05)
                                .frame(width: 90)
                                .tint(.pink)
                            Button(action: {
                                music.lyricsOffset = min(10, music.lyricsOffset + 0.1)
                            }) {
                                Image(systemName: "plus.circle")
                                    .font(.system(size: 11))
                                    .foregroundColor(LyricsInk.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("歌词提前 0.1 秒")
                            Text(String(format: "%+.2fs", music.lyricsOffset))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(LyricsInk.tertiary)
                                .frame(width: 44, alignment: .trailing)
                        }

                        Spacer()

                        // 字号档位：小 / 中 / 大。独占本行右上角，与桌面歌词浮窗布局对齐：
                        // 桌面那套是「右上角一根独立玻璃药丸条」，这里同样让字号按钮
                        // 单独占角落，不跟取词/浮窗等功能图标混排。
                        // 皮肤/尺寸沿用同一份 DesktopLyricsControlsMetrics 常量，
                        // 且解除 desktopLyricsEnabled 门控：没开浮窗也能调字号。
                        // 写法与 CapsuleLyricsControls 逐行同源（glass 长在按钮自己身上），
                        // 仅去掉「× 隐藏」——隐藏由「隐藏歌词 / 显示桌面歌词浮窗」承担。
                        LyricsGlass.bar(spacing: DesktopLyricsControlsMetrics.pillSpacing,
                                         context: glassContext) {
                            HStack(spacing: DesktopLyricsControlsMetrics.pillSpacing) {
                                ForEach(DesktopLyricsSizePreset.allCases, id: \.self) { preset in
                                    Button(action: { music.desktopLyricsSizePreset = preset }) {
                                        Text(preset.label)
                                            .font(.system(size: DesktopLyricsControlsMetrics.pillFontSize,
                                                          weight: music.desktopLyricsSizePreset == preset ? .semibold : .medium))
                                            .foregroundColor(music.desktopLyricsSizePreset == preset
                                                             ? .white
                                                             : LyricsInk.secondary)
                                            .contentShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .frame(width: DesktopLyricsControlsMetrics.pillWidth,
                                           height: DesktopLyricsControlsMetrics.pillHeight)
                                    .lyricsGlassPill(selected: music.desktopLyricsSizePreset == preset,
                                                     context: glassContext)
                                    .help("歌词字号·\(preset.label)")
                                }
                            }
                            .padding(.horizontal, DesktopLyricsControlsMetrics.inset)
                            .frame(height: DesktopLyricsControlsMetrics.barHeight)
                        }
                        .layoutPriority(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // 第二行：歌词功能图标一组（取词呈现 / 浮窗开关 / 隐藏歌词），
                    // 同类集中摆放；第一行右上角落只剩字号档位，与桌面歌词浮窗布局一致。
                    HStack(spacing: 6) {
                        // 取词呈现一组：双语模式 + 重新获取
                        HStack(spacing: 6) {
                            HStack(spacing: 0) {
                                ForEach(MusicController.BilingualMode.allCases, id: \.self) { mode in
                                    Button(action: { music.bilingualMode = mode }) {
                                        let label = mode == .off ? "原" : (mode == .auto ? "双" : "译")
                                        Text(label)
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundColor(
                                                music.bilingualMode == mode
                                                    ? .white
                                                    : LyricsInk.secondary
                                            )
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(
                                                music.bilingualMode == mode
                                                    ? Color(white: 0.25)
                                                    : Color.clear
                                            )
                                            .cornerRadius(4)
                                    }
                                    .buttonStyle(.plain)
                                    .help(mode.label)
                                }
                            }

                            // 重新获取：在线源全靠异步请求，网络抖动就会落空，
                            // 给一条不切歌的补救路径（会清掉该曲的失败/纯音乐缓存）。
                            Button(action: { music.retryLyrics() }) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 11))
                                    .foregroundColor(LyricsInk.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("重新获取歌词")
                        }

                        // 桌面歌词浮窗一组：开关 / 锁定，与取词呈现、隐藏歌词集中在第二行。
                        HStack(spacing: 6) {
                            // 置顶小窗跟随当前歌词行，全屏/切 App 也能看。
                            Button(action: { music.desktopLyricsEnabled.toggle() }) {
                                Image(systemName: music.desktopLyricsEnabled ? "captions.bubble.fill" : "captions.bubble")
                                    .font(.system(size: 11))
                                    .foregroundColor(music.desktopLyricsEnabled
                                                     ? LyricsInk.primary
                                                     : LyricsInk.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(music.desktopLyricsEnabled ? "关闭桌面歌词浮窗" : "开启桌面歌词浮窗")

                            if music.desktopLyricsEnabled {
                                // 锁定后浮窗点击穿透（不拦截鼠标、不能拖动；解锁需回到本面板操作）。
                                Button(action: { music.desktopLyricsLocked.toggle() }) {
                                    Image(systemName: music.desktopLyricsLocked ? "lock.fill" : "lock.open")
                                        .font(.system(size: 11))
                                        .foregroundColor(LyricsInk.secondary)
                                }
                                .buttonStyle(.plain)
                                .help(music.desktopLyricsLocked ? "解锁桌面歌词浮窗" : "锁定桌面歌词浮窗")

                            }
                        }

                        // 隐藏整块歌词区
                        Button(action: { music.showLyrics = false }) {
                            Image(systemName: "eye.slash")
                                .font(.system(size: 11))
                                .foregroundColor(LyricsInk.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("隐藏歌词")
                    }

                    // 浮窗被悬停控制条 × 临时隐藏后，从这里一步恢复，不必先关再开开关。
                    // 独立成一行 + 明显底色：塞在图标组里用户找不到「怎么再调出来」。
                    if music.desktopLyricsHidden {
                        Button(action: { music.showDesktopLyricsWindow() }) {
                            HStack(spacing: 6) {
                                Image(systemName: "rectangle.on.rectangle")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("显示桌面歌词浮窗")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(white: 0.30))
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(PanelInk.chip(0.35), lineWidth: 0.5)
                            )
                        }
                        .buttonStyle(.plain)
                        .help("重新显示桌面歌词浮窗")
                    }

                    if music.lyrics.isEmpty {
                        // lyricsNote 非空表示已查明原因（目前为纯音乐），比笼统的
                        // 「暂无歌词」更准确，也省得用户反复怀疑是功能坏了。
                        Text(music.lyricsNote.isEmpty ? "当前歌曲暂无歌词" : music.lyricsNote)
                            .font(.system(size: lyricBaseSize))
                            .foregroundColor(LyricsInk.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if !music.syncedLines.isEmpty {
                        // Apple Music 官方歌词（带时间轴）：逐行高亮当前播放行。
                        LyricsSyncView(lines: music.syncedLines,
                                       // 实时外推值：currentTime 是补间定时器一拍的量化快照，
                                       // 两次 tick 间平均滞后 124ms（见 MusicController.livePosition）。
                                       currentTime: music.livePosition,
                                       bilingual: music.bilingualMode,
                                       offset: music.lyricsOffset,
                                       baseSize: lyricBaseSize * 0.78,
                                       activeSize: lyricActiveSize * 0.78,
                                       translationSize: translationSize * 0.78) { delta in
                            // 一键对齐：adjustedTime = currentTime - offset，
                            // 要让 line.time == adjustedTime，反推得到
                            // offset = currentTime - line.time = -delta。
                            // 保留 0.01s 精度，与 0.05s 步进滑块完全兼容。
                            music.lyricsOffset = LyricsAlignment.offset(fromLineDelta: delta)
                        }
                            .frame(maxHeight: lyricAreaHeight)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(music.lyrics)
                                    .font(.system(size: DesktopLyricsLayout.languageAdjusted(lyricBaseSize, line: music.lyrics)))
                                    .foregroundColor(LyricsInk.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .lineSpacing(4)
                                if music.bilingualMode != .off {
                                    Text(music.lyricsTranslation.isEmpty ? "翻译中…" : music.lyricsTranslation)
                                        .font(.system(size: DesktopLyricsLayout.languageAdjusted(translationSize, line: music.lyricsTranslation)))
                                        .foregroundColor(music.lyricsTranslation.isEmpty
                                                         ? LyricsInk.en.opacity(0.55)
                                                         : LyricsInk.en)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .lineSpacing(3)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .frame(maxHeight: lyricAreaHeight)
                    }

                    // 当前句两排双语展示：中文一行 + 英文一行，垂直居中于歌词区。
                    // 无论是否带时间轴，都优先从这里拿到「当前行 / 译文」，
                    // 让展开态始终有一块醒目的居中双语字幕（带时间轴时取当前行，
                    // 纯文本时回退整段原文+译文）。
                    // 只算一次：条件里再读 currentLineText 会让同一帧把防抖状态
                    // 写两遍，且多跑一次二分查找。直接用 pair 的文本判空。
                    if music.bilingualMode != .off, !music.currentLineText.isEmpty {
                        let currentPair = music.currentLyricPair
                        let zh = currentPair.text
                        let en = currentPair.translation
                        // 与桌面浮窗/胶囊同一套双语字号规则：英文行不低于中文行
                        let pairSizes = DesktopLyricsLayout.bilingualSizes(
                            originalBase: lyricActiveSize,
                            translationBase: translationSize,
                            original: zh,
                            translation: en,
                            wantsTranslation: !en.isEmpty)
                        VStack(spacing: 6) {
                            Text(zh)
                                .font(.system(size: pairSizes.original, weight: .semibold))
                                .foregroundColor(LyricsInk.zh)
                                .shadow(color: .black.opacity(0.6), radius: 4, x: 0, y: 1)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity, alignment: .center)
                            if !en.isEmpty {
                                Text(en)
                                    .font(.system(size: pairSizes.translation, weight: .medium))
                                    .foregroundColor(LyricsInk.en)
                                    .shadow(color: .black.opacity(0.6), radius: 4, x: 0, y: 1)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity, alignment: .center)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: lyricAreaHeight, alignment: .center)
                        .padding(.vertical, 4)
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
                    .foregroundColor(LyricsInk.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
