import AppKit
import Combine
import Foundation

/// 剪贴板视频链接嗅探控制器。
///
/// 隐私边界（与划词 AI 一致，务必保留）：
/// - 默认关闭，只有用户在视频下载面板显式开启后才轮询剪贴板；
/// - 不落盘剪贴板原文，命中白名单只在内存暂存一条链接供「一键入队」；
/// - 只对高频视频站点（默认白名单 + 用户自定义域名）出手，普通网页不打扰。
///
/// 节流设计：仅「开关打开且无待处理链接」时向 PollingCoordinator 占 1s 拍，
/// 其余情况返回 0，由调度器退化为 5s 空闲拍，不增加常驻开销。
///
/// 对应提案 7（docs/lumi-功能提案-2026-09-23.md）：剪贴板链接嗅探 + 一键入队下载。
final class ClipboardLinkController: ObservableObject {
    static let shared = ClipboardLinkController()

    /// 嗅探设置（默认关闭）。展开态设置区直接绑定此属性的 enabled / extraHosts。
    @Published private(set) var settings: ClipboardSniffSettings = .load()

    /// 当前待处理的链接（nil = 不显示浮条）。
    @Published private(set) var pending: VideoLinkDetector.DetectedLink?

    /// 浮条自动隐藏延迟（秒）。
    private let barLifetime: TimeInterval = 12

    private var hideWork: DispatchWorkItem?
    private var lastChangeCount = NSPasteboard.general.changeCount

    private init() {
        PollingCoordinator.shared.register(
            id: "videoDownload.clipboardLink",
            interval: { [weak self] in
                guard let self else { return 0 }
                return (self.settings.enabled && self.pending == nil) ? 1 : 0
            },
            action: { [weak self] in self?.checkPasteboard() }
        )
    }

    // MARK: - 设置

    func setEnabled(_ on: Bool) {
        var next = settings
        next.enabled = on
        next.save()
        settings = next
        if on {
            // 打开瞬间先同步计数，避免把「开启前就在剪贴板里的内容」当成新复制
            lastChangeCount = NSPasteboard.general.changeCount
            pending = nil
        } else {
            dismissPending()
        }
    }

    func setExtraHosts(_ raw: [String]) {
        var next = settings
        next.extraHosts = raw
        next.save()
        settings = next
    }

    // MARK: - 剪贴板轮询

    private func checkPasteboard() {
        guard settings.enabled else { return }

        // 下载中不弹浮条；故意不更新 lastChangeCount，下载结束后的下一拍再评估当前剪贴板
        guard !VideoDownloadController.shared.isDownloading else { return }

        let pasteboard = NSPasteboard.general
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count

        guard let text = pasteboard.string(forType: .string) else { return }

        // 已在下载列表里的链接不重复提示
        let vd = VideoDownloadController.shared
        let queued = Set(vd.downloads.compactMap { item -> String? in
            URL(string: item.url).map { VideoLinkDetector.canonicalKey($0) }
        })

        if let picked = VideoLinkDetector.pick(
            text: text,
            enabled: settings.enabled,
            extraHosts: settings.normalizedExtraHosts,
            excluding: queued
        ) {
            pending = picked
            scheduleAutoHide()
        }
    }

    private func scheduleAutoHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pending = nil
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + barLifetime, execute: work)
    }

    func dismissPending() {
        hideWork?.cancel()
        hideWork = nil
        pending = nil
    }

    /// 接受当前链接：按指定格式一键入队下载。
    func acceptPending(format: VideoDownloadController.DownloadFormat) {
        guard let pending else { return }
        let vd = VideoDownloadController.shared
        vd.selectedFormat = format
        vd.startDownload(url: pending.url.absoluteString)
        dismissPending()
    }
}
