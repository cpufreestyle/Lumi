import SwiftUI

// MARK: - 跑马灯文本（用于收缩态显示过长歌词/标题）
struct MarqueeText: View {
    let text: String
    let font: Font
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var timer: Timer?

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

    func restart() {
        timer?.invalidate()
        timer = nil
        offset = 0
        guard textWidth > containerWidth, containerWidth > 0 else { return }
        let total = textWidth + 24
        timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
            DispatchQueue.main.async {
                offset -= 1
                if -offset >= total { offset = containerWidth }
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
        HStack(spacing: 8) {
            if music.isPlaying {
                MiniVisualizer()
                    .frame(width: 22, height: 14)
            }
            VStack(alignment: .leading, spacing: 2) {
                if music.isPlaying {
                    if music.showLyrics, !music.lyrics.isEmpty {
                        MarqueeText(
                            text: music.lyrics.replacingOccurrences(of: "\n", with: "   •   "),
                            font: .system(size: 11, weight: .medium)
                        )
                        .frame(height: 14)
                        Text(music.artist.isEmpty ? "Apple Music" : music.artist)
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.5))
                            .lineLimit(1)
                    } else {
                        let fallback = "\(music.title.isEmpty ? "正在播放" : music.title)\(music.artist.isEmpty ? "" : " - " + music.artist)"
                        MarqueeText(text: fallback, font: .system(size: 11, weight: .medium))
                            .frame(height: 14)
                    }
                } else {
                    Text("未在播放")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1)
                    Text("打开音乐 App")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(1)
                }
            }
        }
    }
}

// MARK: - 音乐模块：展开态完整视图
struct MusicExpandedView: View {
    @ObservedObject private var music = MusicController.shared

    var body: some View {
        VStack(spacing: 0) {
            // 专辑封面
            albumArtworkSection
                .padding(.top, 16)

            // 歌曲信息
            VStack(spacing: 2) {
                Text(music.title.isEmpty ? "未在播放" : music.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(music.artist.isEmpty ? "在音乐 App 中播放歌曲" : music.artist)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)

            // 进度条
            progressSection
                .padding(.horizontal, 24)
                .padding(.top, 16)

            // 播放控制按钮
            controlButtons
                .padding(.top, 12)

            // 音频可视化频谱
            if music.isPlaying {
                AudioVisualizer()
                    .frame(height: 40)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
            }

            // 歌词
            lyricsSection
                .padding(.horizontal, 24)
                .padding(.top, 10)

            Spacer()
        }
    }

    // MARK: 专辑封面
    var albumArtworkSection: some View {
        Group {
            if let artwork = music.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 160, height: 160)
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
                    .frame(width: 160, height: 160)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 50))
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
            }
            .frame(height: 4)

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
        HStack(spacing: 36) {
            Button(action: { MusicController.shared.previousTrack() }) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.white.opacity(0.8))
            }
            .buttonStyle(.plain)

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

            Button(action: { MusicController.shared.nextTrack() }) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.white.opacity(0.8))
            }
            .buttonStyle(.plain)
        }
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

                        Spacer()

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
                        Text("当前歌曲暂无内嵌歌词")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.4))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ScrollView {
                            Text(music.lyrics)
                                .font(.system(size: 13))
                                .foregroundColor(.white.opacity(0.78))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineSpacing(4)
                                .padding(.vertical, 4)
                        }
                        .frame(maxHeight: 96)
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

// MARK: - 音频可视化频谱
struct AudioVisualizer: View {
    @State private var timer: Timer?
    @State private var amplitudes: [CGFloat] = Array(repeating: 3, count: 48)

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<48, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(barColor(for: i, amplitude: amplitudes[i]))
                    .frame(width: 2.5, height: max(3, amplitudes[i]))
                    .animation(.linear(duration: 0.06), value: amplitudes[i])
            }
        }
        .onAppear {
            timer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { _ in
                DispatchQueue.main.async {
                    amplitudes = (0..<48).map { _ in CGFloat.random(in: 3...36) }
                }
            }
        }
        .onDisappear { timer?.invalidate() }
    }

    func barColor(for index: Int, amplitude: CGFloat) -> Color {
        let ratio = amplitude / 36.0
        return Color(
            hue: 0.88 - ratio * 0.18,
            saturation: 0.75,
            brightness: 0.45 + ratio * 0.45
        )
    }
}

// MARK: - 迷你波形（收缩态）
struct MiniVisualizer: View {
    @State private var timer: Timer?
    @State private var heights: [CGFloat] = Array(repeating: 3, count: 7)

    var body: some View {
        HStack(spacing: 1.2) {
            ForEach(0..<7, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.pink.opacity(0.7))
                    .frame(width: 2, height: max(2, heights[i]))
                    .animation(.linear(duration: 0.1), value: heights[i])
            }
        }
        .onAppear {
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                DispatchQueue.main.async {
                    heights = (0..<7).map { _ in CGFloat.random(in: 2...12) }
                }
            }
        }
        .onDisappear { timer?.invalidate() }
    }
}
