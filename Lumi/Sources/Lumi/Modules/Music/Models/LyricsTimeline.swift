import Foundation

/// 歌词时间轴的「当前行」查找（纯逻辑，Foundation only，可进 LumiTests）。
///
/// 为什么抽出来：收缩态胶囊、展开态面板、桌面歌词浮窗三处都要按播放进度选行，
/// 过去各自复制同一套线性查找。任何一处改了判定规则（容差、边界、负时间处理），
/// 另外两处不会跟着变 —— 表现为「胶囊和浮窗歌词不一致」，而真正的原因是
/// 同一个算法有了两份实现。收敛到单一函数后，所有入口共用同一判定。
enum LyricsTimeline {
    /// 返回 `adjustedTime` 时刻应高亮的行索引；没有任何行命中返回 nil。
    /// 行时间必须已按时间升序排列（写入时统一排序，见 setSyncedLyrics）。
    ///
    /// 边界语义：`time <= adjustedTime` 的最后一行 —— 到达行起点那一刻即切换。
    /// 负时间（-1，无时间信息）永远不高亮，交由 UI 退化为纯文本展示。
    ///
    /// 重复时间戳（合唱/副歌 `[00:30][01:15]` 会有多行同刻）：取同刻的**第一行**，
    /// 而不是最后一行。取最后一行会让防抖状态在相邻索引间抖动（歌词闪跳），
    /// 取第一行则同刻行集合稳定，直到该刻结束才随下一时刻前进。
    static func activeLineIndex(lines: [SyncedLine],
                                adjustedTime: TimeInterval) -> Int? {
        guard !lines.isEmpty else { return nil }
        // 二分查找最后一个 time <= adjustedTime 的位置。
        // 原先是线性扫描：每拍（0.05s）三处 UI 各遍历一次，长歌 150 行时
        // 合计 1800 次/秒比较。二分把每拍降到 ~8 次，听感无差别但 CPU 显著下降。
        // 前置条件：lines 已按 time 升序（写入时统一排序，见 setSyncedLyrics）。
        var lo = 0
        var hi = lines.count - 1
        var found = -1
        while lo <= hi {
            let mid = lo + (hi - lo) / 2
            let t = lines[mid].time
            if t < 0 {
                // 负时间（无时间信息）排在最前且一律不高亮：跳过整个前缀
                lo = mid + 1
                continue
            }
            if t <= adjustedTime {
                found = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        guard found >= 0 else { return nil }
        // 同刻多行时回退到该刻的第一行，避免高亮在同刻内抖动。
        // 用容差比较而非 ==：行时间经过 [offset:] 元数据换算后可能存在
        // 浮点尾差（10.0000001 vs 10.0），严格相等会让回退中途停下，
        // 同刻仍会抖动。1e-6 秒远小于任何可感知的歌词切换间隔。
        let anchor = lines[found].time
        var first = found
        while first > 0, abs(lines[first - 1].time - anchor) < sameTimestampTolerance {
            first -= 1
        }
        return first
    }

    /// 判定「同一时间戳」的浮点容差（秒）。
    /// 行时间经过 [offset:] 换算后可能有尾差，严格相等会让同刻回退中途停下。
    static let sameTimestampTolerance: TimeInterval = 1e-6

    /// 回退余量（秒）。
    ///
    /// Music 真值回调可能比补间进度略旧（AppleScript 排队延迟），把高亮
    /// 暂时拉回上一行，观感就是歌词闪回。回退时要求越过余量才允许，
    /// 前进则立即切换——前进加余量会让每句固定晚一段，表现为时序不准。
    static let retreatHysteresis: TimeInterval = 0.30

    /// 带防抖的当前行选择：`prev` 为上次确定的索引，`raw` 为时间轴算出的索引。
    /// 三处 UI（胶囊 / 展开面板 / 桌面浮窗）共用，避免「胶囊已经到下一句、
    /// 展开态还在上一句」这种不一致。
    static func debouncedLineIndex(raw: Int?, prev: Int?, lines: [SyncedLine],
                                  adjustedTime: TimeInterval) -> Int? {
        // 首次（无历史）：直接采纳时间轴结果
        guard let prev else { return raw }
        // 时间轴判定为「无命中行」（如前奏未开始）：回到无高亮
        guard let raw else { return nil }
        if raw == prev { return prev }
        // 前进立即切换：不加余量，否则每句固定晚一段（表现为时序不准）
        if raw > prev { return raw }
        // 回退：要求越过余量（回退更可能是真值抖动，应更保守）
        let target = lines[prev].time
        if adjustedTime <= target - retreatHysteresis { return raw }
        return prev
    }
}