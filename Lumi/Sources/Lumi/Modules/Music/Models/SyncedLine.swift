import Foundation
import MusicKit

/// 一条带时间轴的歌词行（来自 Apple Music 同步歌词 / lrclib 的 syncedLyrics）。
struct SyncedLine: Equatable {
    let text: String
    /// 该行的翻译（双语对照用）。自带双语歌词或联网翻译补全时填充，否则为 nil。
    let translation: String?
    /// 该行起始时间（秒）。无时间信息时留 -1，UI 退化为纯文本展示。
    let time: TimeInterval

    init(text: String, time: TimeInterval, translation: String? = nil) {
        self.text = text
        self.translation = translation
        self.time = time
    }
}
