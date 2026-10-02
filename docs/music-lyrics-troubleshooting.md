# 歌词获取链路排障手册（Music 模块）

> 建立时间：2026-09-26 ｜ 更新：2026-10-01 ｜ 关联代码：`Lumi/Sources/Lumi/Modules/Music/Controllers/MusicController.swift`
> 背景：「无法获取歌词」在 2026-09-25 ~ 09-26 期间复现 8 次，根因各异（代理 / 轮询竞态 / 旧二进制 / 限流）。
> 本文档固化链路结构、静默跳过点与验证方法，避免每次从零排查。

## 1. 链路总览

    轮询(1.5s 播放 / 8s 暂停) → fetchInfoSync
      ├─ trackChanged → 清空 UI 歌词 + 复位上一曲取词记忆 + hasLyricsFlag=false
      └─ fetchLyricsSync(force: !hasLyricsFlag)
           ├─ Apple Music 内嵌歌词（本地导入文件才有，流媒体通常为空）
           └─ 在线链：lrclib.net → 网易云 → QQ 音乐 → lyrics.ovh
                └─ setSyncedLyrics() 写回 syncedLines / lyrics（主线程，写前校验曲目未切换）

关键状态（均在 scriptQueue 上串行访问）：

| 状态 | 作用 |
| --- | --- |
| `hasLyricsFlag` | 当前曲目是否已取到歌词；false 时下一轮轮询 force=true |
| `onlineSearchedKeys` | 已取到词/已判定纯音乐的曲目集合，命中即跳过 |
| `lyricInFlightKey` + 45s 窗口 | 在途去重，防 1.5s 轮询并发拉起同一条链 |
| `onlineAttempts`（3 次上限）+ `lyricLastFail`（6s 起步指数冷却，上限 48s） | 失败限频，网络恢复后自动重试 |

## 2. 日志

落盘文件：`~/Library/Logs/Lumi/music.log`（单文件滚动，超 512KB 截断重写）。
log show 抓不到 App 的 NSLog，排障只看这个文件。关键行：

| 日志 | 含义 |
| --- | --- |
| `候选[N]命中歌词 synced=… title=…` | 某个源搜到了词（注意：打在写回之前） |
| `歌词写回 synced=… plainLen=… title=…` | 歌词已写入 UI（2026-09-26 新增，此前缺失） |
| `歌词写回丢弃（曲目已切换）target=… current=…` | 取到词但已被切歌，按设计丢弃（2026-09-26 新增） |
| `命中 Music 内嵌歌词 len=… title=…` | 走的是内嵌歌词路径（2026-09-26 新增） |
| `lrclib 处于不可达冷却期，直接回退网易云` / `提前结束…回退网易云` | lrclib 超时或 5xx → 整源冷却跳过，立即交棒网易云（2026-09-26 起 HTTP 状态码也计入主机失败判定） |
| `resolveLyrics: entries=… parsed=… bytes=…` | parsed=false = 响应体非法（代理截断 chunked），≠「没歌词」（2026-09-26 新增） |
| `网易云 标注纯音乐` | 唱片方声明无歌词，停止后续换源 |

## 3. 「无法获取歌词」排查顺序

以下断点全部无日志，曾长期误导排查（表现为「明明命中了却还是不显示」）：

1. `if !force, hasLyricsFlag { return }` —— 同曲目仅在切歌时 force=true；
2. `onlineSearchedKeys.contains(key)` —— 成功/纯音乐结论会命中（重放前先确认 stop→replay 是否复位）；
3. `lyricInFlightKey == key` 且 45s 内 —— 并发去重；
4. `onlineAttempts >= 3` 且冷却期内（6s 起步、每多失败一轮翻倍、封顶 48s）—— 失败限频。

判定流程：tail ~/Library/Logs/Lumi/music.log
- 完全无新行 → 撞上第 1/2 条（App 认为已有词），点面板上的「重新获取」（`retryLyrics`）强制重跑；
- 只有「候选命中」没有「歌词写回」→ 写回被丢（切歌竞态），或 App 是旧版（无写回日志，需重启更新）；
- 有「写回」但仍不显示 → UI 层问题，转查 MusicExpandedView / DesktopLyricsWindow。

## 4. 历史根因记录（均已在代码注释留痕）

| 时间 | 根因 | 修复 |
| --- | --- | --- |
| 09-25 20:46 | Shadowrocket 代理打断 lrclib/lyrics.ovh 的 TLS（HTTP 000） | 新增网易云源 + 双源同步（lrc/tlyric）+ lrclib 不可达冷却整源跳过 |
| 09-25 23:46 | Music 停止时 artKey 变成 -，上一曲取词记忆没跟着复位，重播同曲被静默跳过 | 切歌逻辑捕获 previousTrackKey 并同步清理 onlineSearchedKeys / onlineAttempts |
| 09-26 00:29 | 1.5s 轮询无在途去重，异步链未完成时并发重入，3 次 attempt 被一次烧光导致永久丢失 | 新增 lyricInFlightKey 45s 在途窗口 + 失败冷却重试 + 失败汇点 markLyricsUnavailable |
| 09-26 01:00 | 「候选命中」日志打在写回之前，静默丢弃/未写回无法与「没取到」区分 | 写回成功/丢弃/内嵌命中三处补日志（本文档第 2 节） |
| 09-26 01:16 | 用户实际在跑的是 00:28 打包的旧 .app（不含当日修复），表现为「代码改了不生效」 | 重启前先确认进程二进制含诊断字符串（LC_ALL=C grep -ac 歌词写回 .build/Lumi.app/Contents/MacOS/Lumi），用 preview_restart.sh 重打包启动 |
| 09-26 01:16 | lrclib 走系统代理对中文歌名稳定 503/空，旧代码只判 NSURLErrorDomain——HTTP 5xx 不算主机级失败，白烧 9×8s 才换源 | fetchLyricsLrclib 补 HTTPURLResponse 2xx 判定，超时/5xx 即 markHostUnreachable + 交棒网易云 |
| 09-26 01:16 | 网易云「纯音乐」曲目只记 onlineSearchedKeys 未置 hasLyricsFlag，1.5s 轮询把 4 个源重刷 12 请求，网易云被限流后正常歌也取不到词 | markNoLyrics 补 hasLyricsFlag=true，纯音乐不再周期重刷 |
| 09-26 01:16 | 四源全失败只显示笼统「当前歌曲暂无歌词」，用户无重试入口 | 新增 markLyricsUnavailable()，提示改「未找到歌词 · 可点 ↻ 重试」 |
| 09-26 01:16 | lrclib 经代理返回 200 但 entries=0（响应体被截断），与「真没歌词」无法区分 | resolveLyrics 加 parsed/bytes 日志 |
| 09-26 03:00 | 单实例护栏（防双实例盖歌词面板）WIP 编译失败：`guard let fd = open(...)` 把 Int32 当 Optional 绑定，构建 0 产出 → 用户跑的是无护栏旧二进制，`/Applications/Lumi.app`（8 月构建）与预览版双开照旧，「无法获取歌词」复发 | main.swift:160 改 `let fd = open(...); guard fd >= 0`；26.5 SDK 下 preview_restart.sh 重打包，验证单实例 pid=83024 且 stop→play 三连日志（resolveLyrics→候选命中→歌词写回）通过 |
| 10-01 | 切歌复位漏清 `lyricLastFail`：它与 onlineAttempts 是同一份失败记忆的两半，只清 attempts 会让失败曲目的 lastFail 永久滞留，且无容量兜底、无限堆积 | fetchInfoSync 切歌分支同步 removeValue 新/上一曲 key + 200 条容量兜底（与 onlineAttempts 同规则）；同批更正本文档此前的「60s 冷却」「markLyricChainFailed」两处漂移（实为 6s 起步指数冷却上限 48s、markLyricsUnavailable， LyricsRetryBackoffTests 已锁行为） |

## 5. 验证方法（复现 + 预期）

    osascript -e 'tell application "Music" to stop'
    sleep 2
    osascript -e 'tell application "Music" to play'
    tail ~/Library/Logs/Lumi/music.log

预期：resolveLyrics → 候选[0]命中歌词 → 歌词写回 三连，且此后同曲目不重复请求。
09-26 01:00 实测（刀马旦 / 李玟，lrclib 命中 28 行）通过；同期 swift build / swift test（191 用例）全绿。09-26 01:16 实测（刀马旦 / 李玟：候选[0] 超时 → lrclib 冷却 → 网易云命中 36 行 → 写回）通过。

## 6. 播放进度标定（歌词同步精度）

> 2026-09-27 ｜ 关联代码：`MusicController.readPointFraction` / `fetchInfoSync` / `MusicPlaybackClock`
>
> 症状：歌词与歌声"时序不准"、"延迟"。除选错歌词版本外，还有一条独立的精度链路：
> App 的进度只能来自 AppleScript，而补间必须以「player position 被真正读到的时刻」为起点。

### 三个必须记住的事实

| 项 | 值 | 说明 |
| --- | --- | --- |
| 完整脚本往返（App 内 `NSAppleScript`） | ~50ms（p90 70ms，偶发 170ms） | 含 player state + 5 个属性 + artwork 探测 |
| 只读 position 的往返 | ~17ms | 差额即 position 之后的元数据成本 |
| `player position` 自身精度 | ±13ms、无固定网格 | 带状态守卫对照实测 n=121；早期「16~17ms 量化台阶」是对暂停数据采样的假象，已废弃 |

### 为什么旧值 0.7 是错的

旧标定用 `osascript` 子进程测量（往返 ~90ms），得出"读取点在 70% 处"。但 App 内是
`NSAppleScript` 直调，往返只有 ~50ms，成本构成完全不同。三种独立测法给出同一区间：

1. **position-first vs position-last 对比**：position 之后的 4 个属性约占往返 2/3，读取点在 1/3 处（0.33）；
2. **往返比例**：17ms / 50ms ≈ 0.34；
3. **按显示进度公式反解残差**：f=0.7 系统性超前 -31.5ms，f=0.45 降到 -5.7ms。

现取 **0.45**（区间中值，留极小回退余量，防止符号估反后整首歌持续超前）。

### 精度下限（必须对用户说清）

即便 f 完全精确，`player position` 自身有 ~16~17ms 量化台阶，1.5s 轮询 + 0.25s 补间也贡献固定项。
**语音同步的真实下限约 ±20ms，不是 0。** 不要为追这 20ms 加重复采样：同一往返内重读
`player position` 返回同一个值，只加延迟、不减误差。

### 仍不准时的排查顺序

1. 先怀疑**选错歌词版本**（Live / Remastered / 翻唱），偏差数秒级、一眼可辨，走取词链路排查；
2. 再看本曲目校准：面板歌词区**点一下当前应在唱的那一行**即一键对齐，偏移按曲目记忆（`offsetByTrack`）；
3. 最后才怀疑同步本身：约 ±20ms 抖动属正常，人耳几乎不可辨。


### 运行态实测（2026-09-27 20:40，n=120）

| 指标 | f=0.70（旧） | f=0.45（新） |
| --- | --- | --- |
| 系统性超前（中位） | -12.9 ms | -0.4 ms |
| p90 | -12.7 ms | -0.4 ms |
| 最差 | -10.5 ms | -0.3 ms |
| 120 次采样总中位误差 | — | -0.05 ms |
| 按 LRC 行间距 1.5s 算切错行概率 | — | 约 0.6% |

复测思路：interleave 一个 ~17ms 的只读 `player position` 脚本（作真值）与完整脚本，
按显示进度公式反解两者差。勿用 `osascript` 子进程，成本构成与 App 内不同。

### 三界面一致性

胶囊 / 桌面浮窗 / 展开态全部经由 `MusicController.currentLyricPair`，统一走
`currentTime - lyricsOffset` → `LyricsTimeline.activeLineIndex` → `debouncedLineIndex`。
展开态 `LyricsSyncView` 复用同一 `LyricsTimeline` 与同一容差，界面间不会分裂。


### 2026-09-27 20:50 追加：真正的滞后主因是补间节拍，不是校准

上一节把 `readPointFraction` 从 0.7 校到 0.45，系统性超前从 -12.9ms 降到 -0.4ms。
但实测后发现**还有一条大一个数量级的滞后源**：补间快照 `currentTime` 只在定时器
tick 时刻更新，而视图刷新与 tick 并不同相位，两次 tick 之间读到的永远是旧值。

| 项 | 修复前 | 修复后 |
| --- | --- | --- |
| 补间节拍（`playbackClockInterval`） | 0.25s | 0.05s（20Hz） |
| 快照滞后（均值 / 最坏） | 124ms / 250ms | 25ms / 50ms |
| 歌词侧残余（`livePosition` 帧级外推） | 124ms | ~16ms（一帧） |

两处改动：

1. `MusicPlaybackClock.playbackClockInterval` 0.25 → 0.05。旧注释写「人眼已无法分辨
   台阶」—— 实测不成立，快照滞后均值 124ms 是可感知的。代价是每秒多 8 次主线程唤醒，
   已实测 20Hz 节拍中位 50.09ms、最大漂移 0.58ms，系统可稳定支撑。
2. 新增 `MusicController.livePosition`：按同一锚点公式外推到当前墙钟。歌词高亮
   （`currentLyricPair` / `currentLine`）与展开态 `LyricsSyncView` 改用它，因此不受
   tick 相位影响。进度条 / 时间标签 / 胶囊仍读 `currentTime` 作兜底。

`livePosition` 的五条边界已单元验证：正常外推、暂停不外推、`duration` 夹取、
真值刚落时不回退、锚点在将来时（时钟回拨）保持当前值。

### 误差预算（当前状态）

| 分量 | 量级 | 能否再压 |
| --- | --- | --- |
| 帧级外推（`livePosition`） | ~16ms | 不能再压，已是刷新率上限 |
| 快照滞后（0.05s tick） | 均值 25ms | 取决于 UI 读哪个值，歌词侧已绕开 |
| 采样读取点校准 | -0.4ms | 已足够 |
| `player position` 自身精度 | ±13ms | 已知的唯一固有不确定度，不是量化台阶 |
| 1.5s 轮询真值校正 | 只在锚点刷新瞬间影响 | 已由 0.05s 补间覆盖 |

结论：歌词同步已进入「人耳不可辨」区间，剩余项要么是接口物理限制，要么已是刷新率上限。

### 2026-09-28 00:00 追加：拒绝陈旧采样时锚点取错，注入秒级超前

前两节把 `readPointFraction` 从 0.7 校到 0.45、把补间节拍从 0.25s 收到 0.05s，
但「歌词和演唱不同步」仍复现。**最终的主因不在这两处，而在补间锚点的选择。**

`fetchInfoSync` 的主线程分支里，`MusicPlaybackSample.shouldAccept` 判为「陈旧采样」
时会保留插值终点 `lastCommittedPosition`（防歌词闪回上一行）。问题出在紧接着的锚点：

| 项 | 值 |
| --- | --- |
| 锚点（修复前） | `sampledAt`（AppleScript 里 `player position` 的真实读点） |
| 锚点（修复后） | `mainThreadAt`（真值到达主线程的时刻，拒绝分支） |
| 真值采样的锚点 | 仍取 `sampledAt`（不受影响） |

`lastCommittedPosition` 这个插值**已经含**读点到主线程之间的排队耗时。若锚点取更早的
读点，`sampledPosition + elapsed` 就把同一段时间再算一次 —— 每次拒绝都把播放时钟往前多
推进一次排队耗时。音频没变快，歌词整体超前；且这种超前**不随播放收敛**，每次轮询拒绝
都在累加，越听越偏。

数值模拟（`如初之光` 真实 LRC 45 行 + `lrclib` 时长 + 本仓库轮询/补间常量）：

| 场景 | 修复前 err_p95 | 修复前 err_max | 修复后 err_p95 | 修复后 err_max | 拒绝次数 |
| --- | --- | --- | --- | --- | --- |
| 空闲（往返 2ms / 主线程 5ms） | 27.6 ms | 30.0 ms | 27.6 ms | 30.0 ms | 0 |
| 一般负载（10ms / 20ms） | 27.6 ms | 30.0 ms | 27.6 ms | 30.0 ms | 0 |
| 繁忙（30ms / 60ms） | 624 ms | 645 ms | 27.5 ms | 30.0 ms | 53 |

即：空闲时两条路径完全一致（所以日常难复现），一旦 AppleScript 排队变长（切歌、
开封面、翻译并发时必然发生），单次拒绝即可注入最高约 0.6s 超前 ≈ 13 行歌词。

代码与测试：`MusicPlaybackSample.anchorTime(sampledAt:mainThreadAt:accepted:)`；
`MusicPlaybackClockTests.swift::PlaybackAnchorTimeTests`（4 条，含把 `anchorTime`
改回 `sampledAt` 即 3 条失败的反证）。

**教训**：同一拍里「保留哪个值」和「从哪个时刻起算」必须同刻。这也是为什么这条规则
值得单测：歌词只是整体偏快，不像抖动那样一眼可辨，肉眼极难定位到锚点。

### 2026-09-28 01:00 追加：同步精度诊断（让「差不多」变成可核对的数字）

前两节把误差预算从「实测表」推到 ±30ms，但**一直缺一个可直接观测的指标**：
用户说「歌词和歌声不同步」时，没有数字能回答「到底差多少、是变快还是变慢」。
新增 `MusicController.recordSyncSample`（仅播放中累计，每 30s 汇总一次）：

| 日志字段 | 含义 |
| --- | --- |
| `超前p50` / `p95` | 歌词位置超前真实播放位置的中位 / 95 分位 |
| `最大` / `最小` | 窗口内的极值 |
| `≈N行` | 最大偏差折算成歌词行数（按 4s/行估算） |
| `排队p50` / `p95` | 读点到主线程的排队耗时（**不是**歌词偏差，单独看） |

口径（关键，容易搞错）：`newPosition` 是 `sampledAt`（AppleScript 里 `player position`
被真读到的时刻）的值，而它到 `mainThreadAt` 才进主线程。这段时间音频一直在走，
所以「此刻真实位置」必须是 `newPosition + (mainThreadAt - sampledAt)`。
不补这个排队项会把排队耗时当成歌词超前，常年多报 50~150ms 的假信号。

模拟验证（30ms 主线程延误 + 3% 位置噪声）：扣掉排队后 p50=-0.4ms / max=57ms；
不扣排队则 p50=+14.5ms / max=180ms —— 口径修正前后差 3 倍以上。

**怎么用**：播放 30s 后 `tail ~/Library/Logs/Lumi/music.log`，看一行 `同步诊断 ...`。
| 观测 | 结论 |
| --- | --- |
| `排队p95` 很大（>200ms） | 先优化 AppleScript 链路排队，不是补间问题 |
| `超前p50` 稳定在 +0.5s 以上 | 选错歌词版本，回取词链路 |
| `超前p50` 在 ±0.05s 内、max < 0.1s | 补间链路正常，剩余是 LRC 本身的 offset，用面板一键对齐 |

### 2026-09-28 01:00 追加：网易云曲末制作名单漏过滤

`LyricMetadataLine` 的中文标签表缺 `和声编写` / `混音室` 等，导致网易云 LRC 曲末的
制作名单作为歌词行高亮（用户看到「和声编写」被当成正在唱的一句，也是「歌词和歌声
对不上」的一种形态）。已补齐标签并新增 `testNeteaseCreditsAtTrackEndAreFiltered`
（实测《如初之光》/ 莫文蔚，网易云 id=531040038 的 11 行名单全过滤、6 行真实歌词不误伤）。

代价注意：名单标签扩大会让「含冒号且标签名撞表」的正常歌词被误过滤。
标签长度上限仍是 20 字，且只匹配**冒号前整段**，因此「他说：你好吗」这类句子不受影响。

### 2026-09-28 01:30 首条真实播放实测（诊断上线后第一次跑）

曲目：《如初之光》/ 莫文蔚（AudioTrack DRM 流媒体，music.163 id=531040038，45 行同步歌词）。
方式：静音播放 70 秒，只读日志，不动用户音量与暂停位置，跑完即恢复原状
（paused / 203.164 / volume 15，三项与操作前逐项一致）。

| 窗口 | n | 超前p50 | 超前p95 | 超前最大 | ≈行 | 排队p50 | 排队p95 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 16:22 | 1 | +0.010s | +0.010s | +0.010s | 0.0 | 0.054s | 0.054s |
| 16:23 | 21 | −0.000s | +0.009s | +0.009s | 0.0 | 0.057s | 0.064s |
| 16:23 | 41 | −0.001s | +0.008s | +0.008s | 0.0 | 0.055s | 0.060s |

结论：歌词超前量的中位数为 **0ms**，三个窗口的最大偏差 **9ms**，折算 0.0 行。
对照上一节的误差预算（帧级外推 ~16ms、快照 ~25ms、position 自身 ±13ms），实测用满预算
仍停在个位毫秒，说明三项确实已经压到接口物理下限附近，没有剩余可挖的项。

**这一节的意义**：前面所有"±30ms 已人耳不可辨"的说法此前都只有模拟数字支撑；
现在有了真实播放、真实 AppleScript 排队、真实 `player position` 噪声下的实测值，
「歌词和歌声差不多」第一次是被日志证明的，而不是被推断的。
