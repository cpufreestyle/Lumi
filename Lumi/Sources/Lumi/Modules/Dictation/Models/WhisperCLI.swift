import Foundation

/// whisper.cpp 官方 CLI（`whisper-cli`）的本机调用层。
///
/// 纯 Foundation 逻辑，零 GUI 依赖，可完整单测（见 `Tests/LumiTests/WhisperCLITests.swift`）。
///
/// 为什么是「调用」而不是「重写」：whisper.cpp 的 GGML 推理、Metal 加速、音频解码
/// （miniaudio）是上游数万行 C/C++ 的积累，在 Lumi 里重新实现毫无收益。这里只做四件
/// 事：找到二进制 → 找到（完整的）模型 → 拼装参数 → 从 stdout 提取转写文本。上游升级
/// （新模型、新参数、bug 修复）Lumi 自动跟上——与 TV 遥控（调 atv-remote）、
/// AI 助手（调 Ollama）完全同构的「接口朝上复用」策略。
///
/// 实测环境（2026-09-26，Apple Silicon，`brew install whisper-cpp`）：
/// - 二进制位于 `/opt/homebrew/bin/whisper-cli`，Metal 后端正常（M5 GPU）；
/// - 日志（ggml 初始化 / timings）全部走 **stderr**；`-np -nt` 下 **stdout 仅含结果**；
/// - 支持音频格式：flac / mp3 / ogg / wav（miniaudio 解码）。听写直接用 AVAudioRecorder
///   录 16kHz 单声道 16-bit PCM WAV，不经 ffmpeg 中转。
enum WhisperCLI {

    // MARK: - 路径解析

    /// `whisper-cli` 可执行文件候选路径，按优先级排列。
    /// 覆盖：Apple Silicon Homebrew、Intel Homebrew、MacPorts、系统目录、源码构建常见位置。
    static let binaryCandidates: [String] = [
        "/opt/homebrew/bin/whisper-cli",
        "/usr/local/bin/whisper-cli",
        "/opt/local/bin/whisper-cli",
        "/usr/bin/whisper-cli",
        "~/whisper.cpp/build/bin/whisper-cli",
        "~/dev/whisper.cpp/build/bin/whisper-cli",
    ]

    /// GGML 模型搜索目录（按优先级）：
    /// 1. Lumi 自己的 models 目录（下载指引指向这里，优先用用户按需拉取的模型）；
    /// 2. Homebrew share 目录（`brew install whisper-cpp` 只附带一个 for-tests 哑模型，
    ///    真实转写输出为空，排在后面仅为兜底）。
    static let modelSearchDirs: [String] = [
        "~/Library/Application Support/Lumi/models",
        "/opt/homebrew/share/whisper-cpp",
        "/opt/homebrew/share/whisper.cpp/models",
        "/usr/local/share/whisper-cpp",
        "/usr/local/share/whisper.cpp/models",
    ]

    /// 只认 `ggml-*.bin`（上游官方模型命名），忽略目录里的其他文件。
    static let modelPrefix = "ggml-"
    static let modelExtension = "bin"

    /// 模型档位选择偏好。听写是交互式场景，等半分钟才出结果的 medium/large 没有意义，
    /// base（约 148MB）是速度/质量的平衡点；tiny 仅兜底。
    static let tierPreference = ["base", "small", "medium", "tiny", "large-v3", "large-v2", "large-v1", "large"]

    /// 模型下载基址（HuggingFace 官方仓库）。
    static let modelDownloadBase = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main"

    /// UI 里推荐给用户下载的档位（体积从小到大）。
    static let suggestedTiers = ["tiny", "base", "small"]

    static func downloadURL(forTier tier: String) -> URL? {
        URL(string: "\(modelDownloadBase)/\(modelPrefix)\(tier).\(modelExtension)")
    }

    // MARK: - 模型

    struct Model: Identifiable, Equatable {
        /// 文件名，如 `ggml-base.bin`。
        let name: String
        /// 绝对路径（`~` 已展开）。
        let path: String
        /// 文件字节数。
        let sizeBytes: Int64

        var id: String { path }

        /// 档位名：`ggml-base.bin` → `base`；`ggml-base.en.bin` → `base.en`。
        var tier: String {
            let stem = (name as NSString).deletingPathExtension
            return stem.hasPrefix(WhisperCLI.modelPrefix)
                ? String(stem.dropFirst(WhisperCLI.modelPrefix.count))
                : stem
        }

        /// 是否下载完整：GGML 文件头没有长度字段，截断的模型会让 whisper-cli 直接崩溃，
        /// 用「档位体积下限」兜底判断（下限取官方体积略偏下的整数 MB）。
        var isComplete: Bool {
            sizeBytes >= WhisperCLI.minimumBytes(forTier: tier)
        }
    }

    /// 各档位模型体积下限（字节）。实测体积：tiny≈78MB、base≈148MB、small≈488MB。
    static func minimumBytes(forTier tier: String) -> Int64 {
        let mb: Int64 = 1_000_000
        switch tier {
        case "tiny", "tiny.en":               return 70 * mb
        case "base", "base.en":               return 140 * mb
        case "small", "small.en":             return 460 * mb
        case "medium", "medium.en":           return 1_400 * mb
        case "large-v3", "large-v2", "large-v1", "large": return 2_800 * mb
        default:                              return 70 * mb
        }
    }

    // MARK: - 语言 / 翻译

    /// 面板可选语言（whisper 语言码）。`auto` = 自动检测。
    static let supportedLanguages = ["auto", "zh", "en", "ja", "ko", "yue", "fr", "de", "es", "ru"]

    /// 归一化语言码：持久化值被手改坏/越改越乱时回落 `auto`。
    static func normalizeLanguage(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "auto" }
        return supportedLanguages.contains(raw) ? raw : "auto"
    }

    // MARK: - 解析

    /// 找 `whisper-cli`：按候选表逐个检查可执行位；找不到返回 nil（调用方给安装指引）。
    static func resolveBinaryPath(
        candidates: [String] = binaryCandidates,
        fileManager: FileManager = .default
    ) -> String? {
        for candidate in candidates {
            let path = expandTilde(candidate)
            if fileManager.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// 扫描模型目录，按体积从大到小返回全部 `ggml-*.bin`（含未下完的，UI 要显示状态）。
    static func installedModels(
        searchDirs: [String] = modelSearchDirs,
        fileManager: FileManager = .default
    ) -> [Model] {
        var models: [Model] = []
        for dir in searchDirs {
            let expanded = expandTilde(dir)
            guard let names = try? fileManager.contentsOfDirectory(atPath: expanded) else { continue }
            for name in names {
                guard name.hasPrefix(modelPrefix),
                      (name as NSString).pathExtension == modelExtension else { continue }
                let path = (expanded as NSString).appendingPathComponent(name)
                guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                      let size = attributes[.size] as? Int64 else { continue }
                models.append(Model(name: name, path: path, sizeBytes: size))
            }
        }
        return models.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// 挑一个可用的模型：按 `tierPreference` 取第一个**完整**的；全都不完整返回 nil。
    static func preferredModel(_ models: [Model]) -> Model? {
        let complete = models.filter(\.isComplete)
        guard !complete.isEmpty else { return nil }
        for tier in tierPreference {
            if let model = complete.first(where: { $0.tier == tier }) { return model }
        }
        return complete.max(by: { $0.sizeBytes < $1.sizeBytes })
    }

    static func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    // MARK: - 参数

    /// 拼 whisper-cli 参数。
    /// - `-np -nt`：只输出结果、不带时间戳（实测日志全走 stderr，stdout 干净）；
    /// - `-l`：语言码（`auto` 自动检测；误检时让用户在面板里钉死中文/英文）；
    /// - `-tr`：翻译成英语（whisper 内置任务，零额外成本）。
    static func buildArguments(
        modelPath: String,
        audioPath: String,
        language: String,
        translateToEnglish: Bool = false
    ) -> [String] {
        var arguments = ["-m", modelPath, "-f", audioPath, "-np", "-nt", "-l", normalizeLanguage(language)]
        if translateToEnglish { arguments.append("-tr") }
        return arguments
    }

    // MARK: - 输出提取

    /// 已知 whisper-cli 可能打到 stdout 的日志前缀（防御性过滤；本机实测日志全走 stderr）。
    private static let logLinePrefixes = [
        "system_info:", "whisper_print_timings:", "ggml_", "load_backend:",
        "read_audio_data:", "error:", "warning:",
    ]

    /// 从 stdout 提取转写文本。
    ///
    /// `-np -nt` 下 stdout 应仅含转写结果（一行一个片段）。仍做三层防御：
    /// 1. 剥掉时间戳片段行的 `[00:00.000 --> 00:02.000] ` 前缀，只留文本；
    /// 2. 过滤日志行（防上游改输出目标）；
    /// 3. 去空行，片段间用换行拼接（与 `whisper-cli -otxt` 的落盘格式一致）。
    static func extractTranscription(fromStdout stdout: String) -> String {
        var segments: [String] = []
        for rawLine in stdout.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("["), let bracket = line.firstIndex(of: "]") {
                line = line[line.index(after: bracket)...].trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }
            }
            if logLinePrefixes.contains(where: { line.hasPrefix($0) }) { continue }
            segments.append(line)
        }
        return segments.joined(separator: "\n")
    }
}
