# 语音听写：一键调用本机 whisper.cpp（离线 / 免费 / 音频不出本机）

> 建立时间：2026-09-26 ｜ 关联模块：`Modules/Dictation`
> 对应本轮目标：**学习和调用开源项目，增加项目实用性**

## 1. 为什么是「调用」而不是「重写」

whisper.cpp 是 OpenAI Whisper 的 C/C++ 移植（GGML + Metal/CPU 推理 + miniaudio 解码），
GitHub 90k+ star，模型格式与 CLI 都是事实标准。让 Lumi 的「语音听写」调用它是零成本的：

- 模型下载、量化、推理加速全由 whisper.cpp 负责，Lumi 不碰任何模型细节；
- Lumi 只做：找二进制 → 找（完整的）模型 → 拼参数 → `Process` 起进程 → 从 stdout 提取文本；
- 上游升级（新模型 large-v3-turbo、新参数、bug 修复）Lumi 自动跟上。

> 同 `docs/ollama-integration.md`、`docs/tv-remote-atv-integration.md` 的原则：
> **接口朝上复用，不在 Lumi 里复制上游实现**。

## 2. 依赖的 CLI（`whisper-cli`，brew install whisper-cpp 安装）

听写一次转写的完整调用：

    whisper-cli -m <model.ggml> -f <16k-mono.wav> -np -nt -l <auto|zh|en|…> [-tr]

| 参数 | 作用 | 备注 |
| --- | --- | --- |
| `-m FNAME` | GGML 模型路径 | 见第 3 节完整性规则 |
| `-f FNAME` | 输入音频 | 本机录音为 16kHz 单声道 16-bit PCM WAV |
| `-np` | 只输出结果 | 实测日志（ggml/Metal/timings）全部走 **stderr**，stdout 干净 |
| `-nt` | 不带时间戳 | 结果一行一个片段 |
| `-l LANG` | 语言码 | `auto` 自动检测；误检时让用户在面板钉死 `zh` / `en` |
| `-tr` | 翻译成英语 | whisper 内置任务，零额外成本，面板一个开关 |

输入格式：whisper-cli 原生支持 flac / mp3 / ogg / wav（miniaudio 解码），但推理要求
16kHz 采样——所以录音侧直接让 `AVAudioRecorder` 按 16kHz 单声道 PCM 录制，**免 ffmpeg 中转**。

## 3. 五个必须知道的坑

1. **日志走 stderr、结果走 stdout，但别把宝全押在通道上。** 本机实测（whisper.cpp
   2026-09 Homebrew 版）：`-np -nt` 下 stdout 仅含转写结果，ggml/Metal 初始化与
   timings 全在 stderr。`WhisperCLI.extractTranscription` 仍对 stdout 做防御性过滤
   （日志前缀、时间戳片段行），上游若改输出目标也不会把日志粘进剪贴板。
2. **GGML 模型文件没有长度字段，下到一半的模型会让 whisper-cli 直接崩。** curl 断线 /
   手动中断都会留下几十 MB 的残缺文件。`WhisperCLI.Model.isComplete` 用「档位体积下限」
   （tiny≈78MB / base≈148MB / small≈488MB）兜底，不完整的模型不出现在可选列表，
   面板上单独提示「检测到未下完的模型」。
3. **`brew install whisper-cpp` 附带的 `for-tests-ggml-tiny.bin` 是哑模型**，加载正常、
   转写输出为空（实测 jfk.wav 与 TTS 语音均空）。所以模型搜索路径里 Lumi 自己的
   `~/Library/Application Support/Lumi/models/` 排在 Homebrew share 目录之前。
4. **录音必须 16kHz 单声道。** whisper 推理固定 16kHz；`AVAudioRecorder` 直接按
   `kAudioFormatLinearPCM / 16000 / 1ch / 16bit` 录制 WAV，是最省事的路径——
   若日后要支持导入任意音频，再引入 ffmpeg 重采样。
5. **麦克风要 TCC 授权。** 已在 `Lumi/Resources/Info.plist` 补
   `NSMicrophoneUsageDescription`（缺这个 key 访问麦克风会直接 crash）；授权前先
   `AVCaptureDevice.requestAccess(for: .audio)`，被拒时面板给出系统设置路径。

## 4. Lumi 侧分层

| 文件 | 职责 |
| --- | --- |
| `Modules/Dictation/Models/WhisperCLI.swift` | 纯逻辑：候选路径表、模型目录扫描、档位体积下限、参数拼装、stdout 提取（Foundation only，25 条单测） |
| `Modules/Dictation/Controllers/DictationController.swift` | AVAudioRecorder 录音（16kHz WAV）→ Process 起 whisper-cli（stdout 管道实时读、stderr 落临时文件供诊断）→ 结果写剪贴板 + 面板状态 |
| `Modules/Dictation/Views/DictationBriefView.swift` | 收缩态一行：录音中秒数 / 模型就绪状态 |
| `Modules/Dictation/Views/DictationExpandedView.swift` | 展开态：录音按钮、结果区（可选中复制）、模型管理与下载指引、语言/翻译设置 |
| `Core/AppState.swift` | `AppModule.dictation`（标签页自动带出） |
| `Core/IslandScreenGeometry.swift` | 听写面板默认尺寸 360×520（比默认高 40，给结果区） |

边界：不起常驻进程、不监听全局热键、不改动任何现有模块；转写是「按钮触发 → 一次性
Process → 结束」，不用 PollingCoordinator（事件驱动，无周期任务）。

## 5. 验证方式

- 单测：`cd Lumi && swift test`——`WhisperCLITests` 25 条覆盖路径解析 / 模型发现 /
  档位完整性 / 参数拼装 / 输出提取；当前基线 **191/191 通过**。
- 管道实测：`say` 合成语音 → ffmpeg 转 16kHz 单声道 → `whisper-cli -np -nt` 跑通，
  Metal 后端正常加载（M5 GPU），stdout/stderr 分离行为符合预期。
- 真模型转写已验证（2026-09-26 01:18）：`ggml-base.bin`（147,951,465 B）经 `curl -C -` 续传下完，`whisper-cli -np -nt -l auto` 跑 jfk.wav 输出 JFK 名言，M5 Metal 后端全程约 0.5s。

模型下载命令（约 148MB，直连 HuggingFace 国内较慢，可后台跑）：

    curl -L -C - -o ~/Library/Application\ Support/Lumi/models/ggml-base.bin \
      https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin

## 6. 未做 / 后续

- **In-app 模型下载器**：目前面板给出下载页与 curl 命令（复制即用），下载进度靠 curl 自
  己的 `-C -` 续传；后续可在面板内嵌下载任务（复用 VideoDownloadController 的
  Process + 进度解析模式）。
- **VAD**：whisper.cpp 新版支持 `--vad`（silero）抑制静音段幻觉，需确认内置 VAD 模型
  是否随 Homebrew 分发后再开启。
- **全局快捷键唤起听写**：见 `docs/播放暂停快捷键方案.md` 的既有模式。
- **导入音频文件转写**：拖入 mp3/m4a 需引入 ffmpeg 重采样，当前只做麦克风实时录音。
