import AppKit

// MARK: - 音乐模块：封面获取
// MusicController 的封面 extension：AppleScript 取封面数据、稳健解码缩放、切歌快速重试。
extension MusicController {

    /// 取专辑封面：在 artworkQueue（高优先级）上取数据并稳健解码缩放（纯计算），
    /// 结果回主线程赋值，标志位 hasArtFlag 写回 scriptQueue（消除跨队列竞争导致的偶发崩溃）。
    /// 取不到（Music 封面尚未下载好）时安排下一次快速重试。
    func fetchArtwork() {
        artworkQueue.async { [weak self] in
            guard let self = self else { return }
            let src = """
            tell application "Music"
                try
                    if exists artwork 1 of current track then
                        return data of artwork 1 of current track
                    end if
                end try
                return ""
            end tell
            """
            guard let desc = self.runScript(src) else {
                self.scheduleArtworkRetry()
                return
            }
            let data = desc.data
            guard !data.isEmpty else {
                // 封面数据还没就绪（流媒体正在下载），安排重试
                self.scheduleArtworkRetry()
                return
            }
            guard let original = NSImage(data: data) else {
                self.scheduleArtworkRetry()
                return
            }
            // 用 CGContext 稳健缩放至 280×280（避免后台队列 lockFocus 的隐患）
            guard let thumb = Self.scaledImage(original, to: NSSize(width: 280, height: 280)) else {
                self.scheduleArtworkRetry()
                return
            }
            DispatchQueue.main.async { [weak self] in self?.artwork = thumb }
            self.scriptQueue.async { [weak self] in self?.hasArtFlag = true }
        }
    }

    /// 切歌后用 scriptQueue 周期性探一次封面：Music 封面往往晚于切歌事件就绪，
    /// 因此主动重试若干次（总跨度约 2.2s），不等 1.5s 主轮询，缩短首屏延迟。
    /// 计数器与探测闭包统一收敛到 scriptQueue：fetchArtwork 从 artworkQueue 调用
    /// 本方法时，原实现会在 artworkQueue 上读写 artworkRetryCount，与 fetchInfoSync
    /// 在 scriptQueue 上的重置形成跨队列无锁访问。
    func scheduleArtworkRetry() {
        scriptQueue.async { [weak self] in
            guard let self = self else { return }
            guard self.artworkRetryCount < 4 else { return }
            self.artworkRetryCount += 1
            let delay = [0.5, 0.9, 1.5, 2.2][self.artworkRetryCount - 1]
            self.scriptQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self else { return }
                if self.hasArtFlag { return }   // 已取到封面
                let src = """
                tell application "Music"
                    try
                        if player state is not stopped and exists artwork 1 of current track then
                            return "yes"
                        else
                            return "no"
                        end if
                    end try
                    return "no"
                end tell
                """
                guard let d = self.runScript(src), d.stringValue == "yes" else { return }
                self.fetchArtwork()
            }
        }
    }

    /// 在后台把 NSImage 稳健缩放为目标尺寸（CGContext 绘制，避免 lockFocus 隐患）。
    private static func scaledImage(_ image: NSImage, to size: NSSize) -> NSImage? {
        var srcCG: CGImage?
        if let tiff = image.tiffRepresentation,
           let src = CGImageSourceCreateWithData(tiff as CFData, nil),
           let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            srcCG = cg
        } else if let rep = image.representations.first as? NSBitmapImageRep {
            srcCG = rep.cgImage
        }
        guard let cg = srcCG else { return nil }
        let target = CGSize(width: size.width, height: size.height)
        guard let context = CGContext(data: nil,
                                      width: Int(target.width),
                                      height: Int(target.height),
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(cg, in: CGRect(x: 0, y: 0, width: target.width, height: target.height))
        guard let out = context.makeImage() else { return nil }
        return NSImage(cgImage: out, size: size)
    }
}
