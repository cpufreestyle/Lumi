# 视频下载依赖探测：ffmpeg 前置拦截 + 失败归因（VideoDownload 模块）

> 建立时间：2026-09-26 ｜ 关联模块：`Sources/Lumi/Modules/VideoDownload`
> 对应本轮目标：**学习和调用开源项目，增加项目实用性**

## 1. 为什么必须有这一步

`VideoDownloadController.performDownload` 的两组 yt-dlp 参数都隐式依赖 ffmpeg：

| 格式 | 参数 | 为什么需要 ffmpeg |
| --- | --- | --- |
| MP4 视频 | `-f bestvideo[ext=mp4]+bestaudio[ext=m4a]` + `--merge-output-format mp4` | 视频与音频是分离流，下载完必须合并 |
| MP3 音频 | `-f bestaudio` + `--extract-audio --audio-format mp3 --audio-quality 0` | 抽音轨 + 重封装成 mp3 是 ffmpeg 的活 |

ffmpeg 缺失时 yt-dlp 必然非零退出，并把 `ERROR: ffmpeg is not installed` 之类写进输出。
改之前 Lumi 只透出「下载失败 (错误码: 1)」，用户既不知道该装什么，也看不出跟 MP3 有什么关系——
表现为「点了 MP3 就失败，MP4 时好时坏」。

## 2. 探测顺序（与 yt-dlp 自身一致）

`FFmpegLocator.resolve(which:probe:)`：

1. **先 PATH**：`/usr/bin/env which ffmpeg`（runner 可注入，测试里换成 stub）；
2. **再回退常见路径**：`/opt/homebrew/bin`（Apple Silicon）→ `/usr/local/bin`（Intel Homebrew）
   → `/opt/local/bin`（MacPorts）→ `/usr/bin` → Xcode 附带工具。

brew 装的 ffmpeg 是 **symlink**，而 `FileManager.isExecutableFile` 对 symlink 返回 false，
因此可用性判定为：fileExists → （若是 symlink）取出真实目标（相对目标按 `dirname` 拼成绝对路径）
→ 判目标可执行。老代码里 yt-dlp 的解析也踩过同一个点，这里顺带固化成 `absoluteDestination(of:target:)`。

## 3. 前置拦截（不让用户白等一次失败下载）

- `VideoDownloadController.ffmpegAvailable`：`private init()` 里同步探测（纯路径查询，几毫秒），
  避免面板闪一下假警告；展开态 `.onAppear` 再 `refreshDependencies()` 一次，
  覆盖「用户刚 `brew install` 完就打开面板而无需重启 App」的场景。
- `startDownload()` 在 yt-dlp 检查之后插入 ffmpeg 守卫：缺失时直接 `statusMessage = FFmpegLocator.missingDependencyMessage`
  （含 `brew install ffmpeg`）并返回，不再起进程。
- 展开态在 yt-dlp 提示旁边并列 `ffmpegInstallPrompt`，文案与安装命令与前置拦截完全一致。

## 4. 失败归因（仍然失败时给出能行动的话）

下载进程的 stdout/stderr 合并进 `outputTail`（只留最近 8 行、每行截 300 字符，**不展示原文**，
避免把视频地址/本地路径刷到面板上）。非零退出时：

    FFmpegLocator.Failure.classify(output: tail) -> FFmpegLocator.message(for:)

| 分类 | 判定 | 面板文案 |
| --- | --- | --- |
| `ffmpegMissing` | 输出含 `ffmpeg` | 下载失败：缺少 ffmpeg（合并 / 转码必需）。brew install ffmpeg |
| `network` | 含 `timed out` / `connection` / `unable to download webpage` / `http error 4|5` / `429` / DNS 解析失败 | 下载失败：网络错误，请检查代理或 VPN 后重试 |
| `unknown` | 其他 | 下载失败，请重试或更换格式 |

> 与「无法获取歌词」排障手册同源的教训：上游工具的隐性依赖（ffmpeg、代理、限流）必须显式化，
> 否则每次现象都不一样，排查成本全落在用户侧。

## 5. 测试

`Tests/LumiTests/FFmpegLocatorTests.swift`（16 用例，测试目标零 GUI 依赖）：

- `resolve` 优先 PATH 命中；PATH 命中但不可用时继续回退，且回退顺序 Homebrew(arm) 先于 Intel；
- 全 stub 场景下返回 nil（本机探测与逻辑解耦，CI 无 ffmpeg 也能跑）；
- `isUsable` 跟随 symlink 到可执行目标、拒绝不存在的路径；
- `absoluteDestination` 处理相对目标（`../Cellar/...`）、保留绝对目标、拒绝空目标；
- `Failure.classify` 覆盖 ffmpeg 缺失 / 超时 / 连接重置 / 429 / DNS / 进度行；
- 文案包含 `brew install ffmpeg` 等可行动信息。

## 6. 验证记录

- `swift build --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk` → Build complete!
- `swift test --sdk ...` → **237 tests, 0 failures**（含本模块 16 条）
- 本机实探：`/opt/homebrew/bin/ffmpeg` → `../Cellar/ffmpeg-full/8.1.2_2/bin/ffmpeg`（symlink 场景即真实用例）

