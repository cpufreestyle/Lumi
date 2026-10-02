import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct VideoDownloadExpandedView: View {
    @ObservedObject private var vd = VideoDownloadController.shared
    @FocusState private var isFocused: Bool
    @ObservedObject private var clipboard = ClipboardLinkController.shared
    @State private var extraHostsDraft: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("视频下载")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(PanelInk.primary)
                Spacer()
                Text("1800+ 站点")
                    .font(.system(size: 9))
                    .foregroundColor(PanelInk.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(PanelInk.chip(0.08)))
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // yt-dlp 状态检查
            if !vd.ytdlpAvailable {
                ytdlpInstallPrompt
            }

            // ffmpeg 状态检查：缺失时 MP4 合并流 / MP3 抽音频都必然失败，前置给出安装命令
            if !vd.ffmpegAvailable {
                ffmpegInstallPrompt
            }

            // URL 输入
            VStack(alignment: .leading, spacing: 4) {
                Text("视频链接")
                    .font(.system(size: 10))
                    .foregroundColor(PanelInk.tertiary)
                HStack(spacing: 6) {
                    TextField("粘贴视频 URL...", text: $vd.urlInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(PanelInk.solid)
                        .padding(10)
                        .background(PanelInk.chip(0.08))
                        .cornerRadius(8)
                        .focused($isFocused)

                    Button(action: { vd.pasteURL() }) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 12))
                            .foregroundColor(PanelInk.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)

            // 格式选择
            VStack(alignment: .leading, spacing: 4) {
                Text("下载格式")
                    .font(.system(size: 10))
                    .foregroundColor(PanelInk.tertiary)
                HStack(spacing: 8) {
                    ForEach(VideoDownloadController.DownloadFormat.allCases) { fmt in
                        Button(action: { vd.selectedFormat = fmt }) {
                            HStack(spacing: 5) {
                                Image(systemName: fmt.icon)
                                    .font(.system(size: 11))
                                Text(fmt.rawValue)
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundColor(vd.selectedFormat == fmt ? .white : PanelInk.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                vd.selectedFormat == fmt
                                    ? AnyShapeStyle(LinearGradient(colors: [Color.pink, Color.purple], startPoint: .leading, endPoint: .trailing))
                                    : AnyShapeStyle(PanelInk.chip(0.08))
                            )
                            .cornerRadius(10)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            // 进度条
            if vd.isDownloading || vd.progress > 0 {
                VStack(spacing: 6) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(PanelInk.chip(0.1))
                                .frame(height: 6)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(
                                    LinearGradient(colors: [Color.pink, Color.purple], startPoint: .leading, endPoint: .trailing)
                                )
                                .frame(width: geo.size.width * vd.progress, height: 6)
                                .animation(.easeInOut(duration: 0.3), value: vd.progress)
                        }
                    }
                    .frame(height: 6)

                    HStack {
                        Text(vd.statusMessage)
                            .font(.system(size: 10))
                            .foregroundColor(PanelInk.tertiary)
                            .lineLimit(1)
                        Spacer()
                        Text("\(Int(vd.progress * 100))%")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(PanelInk.pink)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }

            // 下载/取消按钮
            HStack(spacing: 10) {
                if vd.isDownloading {
                    Button(action: { vd.cancelDownload() }) {
                        HStack {
                            Image(systemName: "xmark.circle")
                                .font(.system(size: 12))
                            Text("取消下载")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.red.opacity(0.4))
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                }

                Button(action: { vd.startDownload() }) {
                    HStack {
                        Image(systemName: vd.isDownloading ? "arrow.down.circle" : "arrow.down.to.line")
                            .font(.system(size: 12))
                        Text(vd.isDownloading ? "下载中..." : "开始下载")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(PanelInk.solid)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        vd.urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vd.isDownloading
                            ? AnyShapeStyle(PanelInk.chip(0.1))
                            : AnyShapeStyle(LinearGradient(colors: [Color.pink, Color.purple], startPoint: .leading, endPoint: .trailing))
                    )
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .disabled(vd.urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vd.isDownloading)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // 剪贴板嗅探命中：展开态待处理卡片（浮条不覆盖展开态，动作按钮放这里）
            if let pending = clipboard.pending {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "link")
                            .font(.system(size: 11))
                            .foregroundColor(PanelInk.pink)
                        Text("检测到 \(pending.hostDisplay) 链接")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(PanelInk.primary)
                            .lineLimit(1)
                        Spacer()
                    }
                    Text(pending.url.absoluteString)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(PanelInk.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 8) {
                        ForEach(VideoDownloadController.DownloadFormat.allCases) { fmt in
                            Button(action: { clipboard.acceptPending(format: fmt) }) {
                                HStack(spacing: 4) {
                                    Image(systemName: fmt.icon)
                                        .font(.system(size: 11))
                                    Text(fmt.rawValue)
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundColor(vd.selectedFormat == fmt ? Color.white : PanelInk.text(0.95))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(
                                    vd.selectedFormat == fmt
                                        ? AnyShapeStyle(LinearGradient(colors: [Color.pink, Color.purple], startPoint: .leading, endPoint: .trailing))
                                        : AnyShapeStyle(PanelInk.chip(0.08))
                                )
                                .cornerRadius(10)
                            }
                            .buttonStyle(.plain)
                        }
                        Button(action: { clipboard.dismissPending() }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11))
                                .foregroundColor(PanelInk.tertiary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
                .background(Color.pink.opacity(0.08))
                .cornerRadius(10)
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            // 下载历史
            if !vd.downloads.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("下载历史")
                        .font(.system(size: 10))
                        .foregroundColor(PanelInk.tertiary)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)

                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(vd.downloads) { item in
                                DownloadHistoryRow(item: item)
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                    .frame(maxHeight: 150)
                }
            }

            // 剪贴板嗅探设置（默认关：隐私优先，只内存暂存不落盘）
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: Binding(
                    get: { clipboard.settings.enabled },
                    set: { clipboard.setEnabled($0) }
                )) {
                    HStack(spacing: 6) {
                        Image(systemName: "clipboard")
                            .font(.system(size: 11))
                        Text("剪贴板链接嗅探")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(PanelInk.primary)
                }
                .toggleStyle(.switch)

                Text("开启后复制视频链接即提示一键下载；自定义域名用逗号分隔")
                    .font(.system(size: 9))
                    .foregroundColor(PanelInk.tertiary)

                HStack(spacing: 6) {
                    TextField("自定义域名，如: example.com, m.example.cn", text: $extraHostsDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(PanelInk.solid)
                        .padding(8)
                        .background(PanelInk.chip(0.08))
                        .cornerRadius(8)
                        .onSubmit { clipboard.setExtraHosts(parseHosts(extraHostsDraft)) }
                    Button("保存") { clipboard.setExtraHosts(parseHosts(extraHostsDraft)) }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(PanelInk.solid)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(PanelInk.chip(0.12)))
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            Spacer(minLength: 0)
        }
        .onAppear {
            extraHostsDraft = clipboard.settings.extraHosts.joined(separator: ", ")
            // 面板每次打开重新探测一次：用户可能在打开前刚 brew install
            vd.refreshDependencies()
        }
    }

    /// 把输入框里的逗号（中英文）分隔域名拆成数组；规整交给 VideoLinkDetector.normalizedHosts。
    private func parseHosts(_ raw: String) -> [String] {
        raw.components(separatedBy: ",")
            .flatMap { $0.components(separatedBy: "，") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var ytdlpInstallPrompt: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundColor(PanelInk.orange)
                Text("需要安装 yt-dlp 以支持视频下载")
                    .font(.system(size: 11))
                    .foregroundColor(.orange.opacity(0.8))
            }
            Text("在终端运行: brew install yt-dlp")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(PanelInk.tertiary)
                .padding(6)
                .background(PanelInk.chip(0.06))
                .cornerRadius(6)
        }
        .padding(10)
        .background(Color.orange.opacity(0.08))
        .cornerRadius(10)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    var ffmpegInstallPrompt: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundColor(PanelInk.orange)
                Text("需要 ffmpeg：MP4 合并流 / MP3 抽音频都依赖它")
                    .font(.system(size: 11))
                    .foregroundColor(.orange.opacity(0.8))
            }
            Text("在终端运行: \(FFmpegLocator.installCommand)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(PanelInk.tertiary)
                .padding(6)
                .background(PanelInk.chip(0.06))
                .cornerRadius(6)
        }
        .padding(10)
        .background(Color.orange.opacity(0.08))
        .cornerRadius(10)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}
