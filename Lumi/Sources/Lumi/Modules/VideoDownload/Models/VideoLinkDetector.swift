import Foundation

/// 剪贴板视频链接嗅探的纯逻辑层（Foundation only，进单测目标）。
///
/// 定位：yt-dlp 支持 1800+ 站点，但「用户复制了什么」需要一层轻量预筛查——
/// 本类型只回答三个问题：文本里有没有链接、是不是（默认支持的）视频站点、这个链接是否已处理过。
/// 所有判定规则可注入（额外域名 / 已入队集合），不留全局可变状态。
///
/// 对应提案 7（docs/lumi-功能提案-2026-09-23.md）：剪贴板链接嗅探 + 一键入队下载。
enum VideoLinkDetector {

    // MARK: - 模型

    struct DetectedLink: Equatable {
        let url: URL
        /// 同一视频的归一化键：忽略 utm/share 等跟踪参数，用于入队去重。
        let key: String

        var host: String { url.host ?? "" }
        /// 展示用主机名：去 www.，适合胶囊窄条。
        var hostDisplay: String { host.replacingOccurrences(of: "www.", with: "") }
    }

    // MARK: - 默认站点白名单

    /// 只对高频视频站点出手（yt-dlp 本身不挑站，这里控制打扰面）。
    /// 用户可在设置里追加自定义域名；未命中白名单的链接（普通网页、文档）不会触发提示。
    static let defaultHosts: Set<String> = [
        // 国际
        "youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be",
        "vimeo.com", "dailymotion.com", "twitch.tv", "clips.twitch.tv",
        "tiktok.com", "instagram.com", "facebook.com", "fb.watch",
        "twitter.com", "x.com", "reddit.com", "v.redd.it",
        "nicovideo.jp", "soundcloud.com", "bandcamp.com",
        // 国内
        "bilibili.com", "m.bilibili.com", "b23.tv",
        "douyin.com", "v.douyin.com", "ixigua.com",
        "kuaishou.com", "v.kuaishou.com", "xiaohongshu.com", "xhslink.com",
        "weibo.com", "weibo.cn", "video.weibo.com",
        "youku.com", "v.youku.com", "iqiyi.com", "v.qq.com",
        "zhihu.com", "zhuanlan.zhihu.com",
        "weixin.qq.com", "mp.weixin.qq.com",
        "xiaoyuzhoufm.com", "podcasts.apple.com", "music.apple.com",
    ]

    /// 归一化用户输入时剥离的跟踪参数（大小写不敏感）。
    static let trackingQueryKeys: Set<String> = [
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "utm_id",
        "spm_id_from", "vd_source", "share_source", "share_medium", "share_plat",
        "from_spmid", "referfrom", "share_token", "_ts", "timestamp", "spm",
    ]

    // MARK: - URL 提取

    /// 从任意文本中按出现顺序提取去重后的链接（空文本 / 无链接返回空数组）。
    static func detectLinks(in text: String?) -> [URL] {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = detector.matches(in: text, options: [], range: range)

        var seen = Set<String>()
        var out: [URL] = []
        for match in matches {
            guard match.resultType == .link, let url = match.url else { continue }
            if seen.insert(url.absoluteString).inserted {
                out.append(url)
            }
        }
        return out
    }

    // MARK: - 站点判定

    /// 仅 http/https + 主机命中白名单（默认集合并集用户自定义集）。
    /// 主机大小写不敏感；www. 前缀等价于裸域（用户复制最多的正是 www 变体）。
    static func isSupported(url: URL, extraHosts: Set<String> = []) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let allowed = defaultHosts.union(extraHosts)
        return allowed.contains(host) || allowed.contains(bare)
    }

    // MARK: - 归一化

    /// 把用户粘贴的域名输入规整成 host 集合：容忍协议前缀、路径、大小写与首尾空白。
    static func normalizedHosts(_ raw: [String]) -> Set<String> {
        var out = Set<String>()
        for item in raw {
            var host = item.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if host.isEmpty { continue }
            if let schemeRange = host.range(of: "://") {
                host = String(host[schemeRange.upperBound...])
            }
            if let slash = host.firstIndex(of: "/") {
                host = String(host[host.startIndex..<slash])
            }
            host = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard host.contains("."), !host.contains(" ") else { continue }
            out.insert(host)
        }
        return out
    }

    /// 同一视频的归一化键：小写 host（去 www.）+ 去尾斜杠 path + 去跟踪参数的排序 query。
    static func canonicalKey(_ url: URL) -> String {
        var host = url.host?.lowercased() ?? ""
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }

        var path = url.path
        if path.count > 1, path.hasSuffix("/") { path = String(path.dropLast()) }

        var key = host + path
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let items = components.queryItems, !items.isEmpty {
            let kept = items
                .filter { !trackingQueryKeys.contains($0.name.lowercased()) }
                .map { $0.name + "=" + ($0.value ?? "") }
                .sorted()
            if !kept.isEmpty { key += "?" + kept.joined(separator: "&") }
        }
        return key
    }

    // MARK: - 综合决策

    /// 给定剪贴板文本与上下文，返回应当推荐的链接；无则 nil。
    /// - Parameters:
    ///   - text: 剪贴板文本（nil = 空剪贴板）
    ///   - enabled: 用户开关（默认关；关时一律不提示）
    ///   - extraHosts: 用户自定义域名
    ///   - queuedKeys: 已在下载列表中的 canonicalKey 集合（同一链接不重复提示）
    static func pick(
        text: String?,
        enabled: Bool,
        extraHosts: Set<String> = [],
        excluding queuedKeys: Set<String> = []
    ) -> DetectedLink? {
        guard enabled else { return nil }
        for url in detectLinks(in: text) where isSupported(url: url, extraHosts: extraHosts) {
            let key = canonicalKey(url)
            if queuedKeys.contains(key) { continue }
            return DetectedLink(url: url, key: key)
        }
        return nil
    }
}

// MARK: - 设置持久化

/// 剪贴板嗅探设置。默认关闭（隐私优先：不碰剪贴板除非用户显式开启）。
struct ClipboardSniffSettings: Codable, Equatable {
    var enabled: Bool
    var extraHosts: [String]

    static let defaults = ClipboardSniffSettings(enabled: false, extraHosts: [])

    private static let storageKey = "videoDownload.clipboardSniffSettings.v1"

    static func load(from defaults: UserDefaults = .standard) -> ClipboardSniffSettings {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(ClipboardSniffSettings.self, from: data)
        else { return Self.defaults }
        return decoded
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    /// 用户自定义域名经归一化后的集合。
    var normalizedExtraHosts: Set<String> { VideoLinkDetector.normalizedHosts(extraHosts) }

    func withEnabled(_ value: Bool) -> ClipboardSniffSettings {
        ClipboardSniffSettings(enabled: value, extraHosts: extraHosts)
    }

    func withExtraHosts(_ value: [String]) -> ClipboardSniffSettings {
        ClipboardSniffSettings(enabled: enabled, extraHosts: value)
    }
}

