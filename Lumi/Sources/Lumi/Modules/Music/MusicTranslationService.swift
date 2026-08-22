import Foundation
import AppKit

// MARK: - 音乐模块：翻译服务
// MusicController 的翻译 extension：翻译缓存（内存 + 落盘）、大模型/Google 双通道、
// 批量翻译与重试、双语歌词逐行补全。
extension MusicController {

    // MARK: - 翻译缓存（内存 + 磁盘持久化）
    /// 翻译缓存持久化文件路径：~/Library/Application Support/Lumi/translation_cache.json
    private var translationCacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lumi")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("translation_cache.json")
    }
    /// 启动时从磁盘加载已翻译歌词缓存，避免重复翻译（命中即跳过网络请求）。
    func loadTranslationCache() {
        translationQueue.async { [weak self] in
            guard let self = self else { return }
            guard let data = try? Data(contentsOf: self.translationCacheURL),
                  let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return }
            self.translationCache = dict
        }
    }
    /// 将当前翻译缓存写盘（在 translationQueue 内调用，保证与内存读写一致）。
    private func persistTranslationCache() {
        let url = self.translationCacheURL
        let snapshot = self.translationCache
        translationQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
    /// 写入一条译文到内存缓存并异步持久化到磁盘（统一入口，覆盖所有翻译来源）。
    private func cacheTranslation(_ src: String, _ tr: String) {
        translationQueue.async { [weak self] in
            guard let self = self else { return }
            self.translationCache[src] = tr
            // 落盘（粗粒度写整文件，缓存规模小，写盘成本低）
            let url = self.translationCacheURL
            let snapshot = self.translationCache
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - 双语歌词翻译补全
    /// 对带时间轴的歌词逐行补全翻译（仅针对没有自带 translation 的行）。
    /// 自带双语已在 parseSyncedLyrics 拆分，无需联网；联网用 MyMemory 免费 API（无需 key）。
    /// 译文按行缓存，避免重复请求。整段翻译结果在回调中重建 syncedLines 写回主线程。
    func fetchTranslations(synced: [SyncedLine], title: String) {
        guard bilingualMode != .off else { return }
        // 待译行：translation 为 nil 或空字符串都算未翻译（避免"假完成"——空译文被当成已完成而永不重译）
        let targets = synced.enumerated().filter {
            ($0.element.translation ?? "").isEmpty && !$0.element.text.isEmpty
        }
        guard !targets.isEmpty else { return }
        // 限制单首翻译行数，避免触发翻译 API 限流（MyMemory 未认证约 5000 词/日）
        let capped = Array(targets.prefix(60))
        // 每批 8 行拼接成一段一次请求，显著减少网络往返（RTT），加快整首补全速度。
        let batchSize = 8
        let batches = stride(from: 0, to: capped.count, by: batchSize).map {
            Array(capped[$0..<min($0 + batchSize, capped.count)])
        }
        // 串行处理各批次：避免一次性并发所有请求触发 Google/LLM 限流（表现为"翻译到一半断掉"）。
        // 每批之间间隔 0.4s，且每批失败重试 1 次；失败的行不写空占位，保留"翻译中"状态，
        // 下一轮轮询可再次补译，避免永久断掉。
        func processBatch(at index: Int) {
            guard index < batches.count else {
                self.rebuildSyncedWithTranslations(title: title)
                return
            }
            let batch = batches[index]
            let pending = batch.filter { line in
                var cached: String?
                self.translationQueue.sync { cached = self.translationCache[line.element.text] }
                return cached == nil
            }
            guard !pending.isEmpty else {
                // 整批已命中缓存，直接下一批
                self.scriptQueue.asyncAfter(deadline: .now() + 0.1) { processBatch(at: index + 1) }
                return
            }
            let srcs = pending.map { $0.element.text }
            var attempts = 0
            func attempt() {
                attempts += 1
                self.translateBatchWithRetry(lines: srcs, attempt: attempts) { [weak self] translated in
                    guard let self = self else { return }
                    if let translated = translated, translated.count == srcs.count {
                        for (k, src) in srcs.enumerated() {
                            let tr = translated[k]
                            guard !tr.isEmpty else { continue }
                            self.cacheTranslation(src, tr)
                        }
                        self.scriptQueue.asyncAfter(deadline: .now() + 0.3) { processBatch(at: index + 1) }
                    } else if attempts < 2 {
                        // 整批失败：重试一次（限流往往是突发并发导致，稍后重试大多成功）
                        self.diagLog("translateBatch 整批失败，重试（attempt=\(attempts)）")
                        self.scriptQueue.asyncAfter(deadline: .now() + 0.8) { attempt() }
                    } else {
                        // 重试仍失败：逐行兜底翻译（每条计入批次完成信号）
                        let subgroup = DispatchGroup()
                        for src in srcs {
                            var cached: String?
                            self.translationQueue.sync { cached = self.translationCache[src] }
                            guard cached == nil else { continue }
                            subgroup.enter()
                            self.translateWithRetry(text: src, attempt: 1) { [weak self] tr in
                                defer { subgroup.leave() }
                                guard let self = self else { return }
                                if let tr = tr, !tr.isEmpty {
                                    self.cacheTranslation(src, tr)
                                }
                                // 注意：失败不写空占位，保留"翻译中"，下一轮可补译
                            }
                        }
                        subgroup.notify(queue: self.scriptQueue) {
                            // 本批兜底完成，进入下一批
                            self.scriptQueue.asyncAfter(deadline: .now() + 0.3) { processBatch(at: index + 1) }
                        }
                    }
                }
            }
            attempt()
        }
        scriptQueue.async { processBatch(at: 0) }
    }

    /// 根据翻译缓存重建 syncedLines（为每行缺失 translation 的行补全译文）。
    /// 仅当仍是同一首歌时写回，避免串词。
    private func rebuildSyncedWithTranslations(title: String) {
        // 同步从 translationQueue 取快照到局部变量，再回到主线程重建。
        // 必须 sync 取快照（而非在 translationQueue.async 闭包里捕获 snapshot 再
        // 跨到 DispatchQueue.main.async）：之前的 async 写法会让 snapshot 在后台队列
        // 与主线程闭包之间被多次并发捕获，配合 translationCache 的并发写入触发
        // 字典桥接损坏（unrecognized selector objectForKey: sent to NSNumber），导致崩溃。
        var snapshot: [String: String] = [:]
        translationQueue.sync { snapshot = self.translationCache }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard self.title == title || title.isEmpty else { return }
            let synced = self.syncedLines
            var rebuilt = synced
            var filled = 0
            for i in synced.indices {
                let line = synced[i]
                if line.translation != nil { continue }
                // 显式以 String? 取值，避免任何桥接把值当字典
                if let tr = snapshot[line.text] as String?, !tr.isEmpty {
                    rebuilt[i] = SyncedLine(text: line.text, time: line.time, translation: tr)
                    filled += 1
                }
            }
            // 仅在有变化时写回，减少无谓的 @Published 刷新
            if rebuilt != self.syncedLines { self.syncedLines = rebuilt }
        }
    }

    /// 无时间轴纯文本歌词：整段翻译补全（双语模式时展示原文 + 译文）。
    func fetchPlainTranslation(plain: String, title: String) {
        guard bilingualMode != .off, !plain.isEmpty else { return }
        scriptQueue.async { [weak self] in
            guard let self = self else { return }
            var cached: String?
            self.translationQueue.sync { cached = self.translationCache[plain] }
            if let cached = cached, !cached.isEmpty {
                DispatchQueue.main.async { if self.title == title { self.lyricsTranslation = cached } }
                return
            }
            self.translate(text: plain) { [weak self] tr in
                guard let self = self else { return }
                if let tr = tr, !tr.isEmpty {
                    self.cacheTranslation(plain, tr)
                    DispatchQueue.main.async {
                        if self.title == title || title.isEmpty { self.lyricsTranslation = tr }
                    }
                } else {
                    // 翻译失败：写空占位，避免 UI 永久卡在"翻译中"
                    self.cacheTranslation(plain, "")
                }
            }
        }
    }

    /// 切换双语模式后，对当前已载入歌词重新应用（触发翻译或仅依赖 UI 隐藏）。
    func reapplyBilingualForCurrentTrack() {
        guard bilingualMode != .off else { return }
        if !syncedLines.isEmpty {
            fetchTranslations(synced: syncedLines, title: title)
        } else if !lyrics.isEmpty {
            fetchPlainTranslation(plain: lyrics, title: title)
        }
    }

    // MARK: - 翻译后端配置（大模型，OpenAI 兼容 Chat Completions）
    /// key / baseURL / model 均从环境变量读取，不写死在代码里、不进 git。
    /// - LUMI_TRANSLATE_API_KEY：必填。免费 key 可去 OpenRouter（默认）/ Gemini 等注册。
    /// - LUMI_TRANSLATE_BASE_URL：OpenAI 兼容端点，默认 OpenRouter。
    /// - LUMI_TRANSLATE_MODEL：模型名，默认 OpenRouter 免费模型。
    /// 统一从 ~/Library/Application Support/Lumi/translate.env 解析翻译配置。
    /// 该文件是用户维护的权威配置源（不进 git）。为避免历史 `launchctl setenv` 写入的旧
    /// OpenRouter key（已 401 失效）残留在进程环境中、悄悄覆盖正确配置，这里**只认文件，
    /// 不再 fallback 进程环境变量**（仅在文件本身不存在/无该 key 时才退回默认值）。
    private var translateEnv: [String: String] {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Lumi/translate.env")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var dict: [String: String] = [:]
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq])
            let val = String(trimmed[trimmed.index(after: eq)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !val.isEmpty { dict[key] = val }
        }
        return dict
    }

    /// 仅从 translate.env 文件读取值（不再回退进程环境变量，杜绝旧 key 污染）。
    /// 文件缺 key 时返回 nil，由调用方决定是否用代码内置默认 baseURL/model。
    func envValue(_ name: String) -> String? {
        translateEnv[name]
    }

    // 翻译端点/key 现由「选中的模型」驱动（见 MusicController.swift 中 activeTranslate* 计算属性），
    // 不再使用 LUMI_FORCE_LLM 环境变量开关。

    /// 翻译主入口。
    /// 通道由「当前选中的翻译模型」决定：选中大模型类模型 -> 优先走大模型；
    /// 大模型失败则回退 Google 公开接口。最终失败返回 nil（UI 显示原文），不长时间挂起。
    private func translate(text: String, completion: @escaping (String?) -> Void) {
        if useLLMTranslate, let key = activeTranslateAPIKey {
            self.diagLog("translate: 大模型 key=\(String(key.prefix(12)))... model=\(activeTranslateModel)")
            self.translateViaLLM(text: text) { result in
                if let result { completion(result) }
                else { self.translateViaGoogle(text: text, completion: completion) }
            }
        } else {
            self.diagLog("translate: 走 Google 公开接口（稳定、无 key）")
            translateViaGoogle(text: text) { result in
                if let result { completion(result) }
                else if self.useLLMTranslate, self.activeTranslateAPIKey != nil {
                    self.translateViaLLM(text: text) { completion($0) }
                } else { completion(nil) }
            }
        }
    }

    /// 调用大模型（OpenAI 兼容 Chat Completions）补全翻译。
    /// 端点与 key 由选中的模型决定（dashscope 走兼容模式，openrouter 沿用原配置）。
    /// 目标语言：原文含中文 -> 译为英文；否则 -> 译为中文。失败时返回 nil，由调用方兜底。
    private func translateViaLLM(text: String, completion: @escaping (String?) -> Void) {
        guard let key = activeTranslateAPIKey else { completion(nil); return }
        let hasCJK = text.contains { 0x4E00...0x9FFF ~= $0.unicodeScalars.first?.value ?? 0 }
        let targetLang = hasCJK ? "English" : "Chinese"
        let sysPrompt = "You are a lyrics translator. Translate the given line into \(targetLang) only. Keep it concise, preserve tone, do NOT add explanations or quotes. Output only the translation."
        let urlStr = "\(activeTranslateBaseURL)/chat/completions"
        guard let url = URL(string: urlStr) else { completion(nil); return }

        let body: [String: Any] = [
            "model": activeTranslateModel,
            "messages": [
                ["role": "system", "content": sysPrompt],
                ["role": "user", "content": text]
            ],
            "temperature": 0.3,
            "max_tokens": 200
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 12
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                self.diagLog("translateViaLLM: HTTP \(http.statusCode) 失败，回退")
                completion(nil); return
            }
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any],
                  let tr = msg["content"] as? String else {
                completion(nil); return
            }
            let cleaned = tr.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'‘’“”"))
            guard !cleaned.isEmpty else { completion(nil); return }
            self.diagLog("translateViaLLM OK: \(text) -> \(cleaned)")
            completion(cleaned)
        }.resume()
    }

    // MARK: - 带重试的翻译封装

    /// 单句翻译，最多重试 2 次（限流时重试通常成功）。失败不写空占位。
    private func translateWithRetry(text: String, attempt: Int, completion: @escaping (String?) -> Void) {
        let maxAttempts = 2
        translate(text: text) { [weak self] result in
            guard let self = self else { return }
            if let result = result, !result.isEmpty {
                completion(result)
            } else if attempt < maxAttempts {
                self.diagLog("translate 单句失败，重试（attempt=\(attempt)）：\(text.prefix(20))")
                self.scriptQueue.asyncAfter(deadline: .now() + 0.6) {
                    self.translateWithRetry(text: text, attempt: attempt + 1, completion: completion)
                }
            } else {
                completion(nil)
            }
        }
    }

    /// 批量翻译，最多重试 2 次。
    private func translateBatchWithRetry(lines: [String], attempt: Int, completion: @escaping ([String]?) -> Void) {
        let maxAttempts = 2
        translateBatch(lines: lines) { [weak self] result in
            guard let self = self else { return }
            if let result = result, result.count == lines.count {
                completion(result)
            } else if attempt < maxAttempts {
                self.diagLog("translateBatch 失败，重试（attempt=\(attempt)），行数=\(lines.count)")
                self.scriptQueue.asyncAfter(deadline: .now() + 0.6) {
                    self.translateBatchWithRetry(lines: lines, attempt: attempt + 1, completion: completion)
                }
            } else {
                completion(nil)
            }
        }
    }

    /// 批量翻译：把多行歌词拼成一个段落一次请求，大幅减少网络往返（RTT），
    /// 从而显著加快整首歌双语译文的补全速度。
    /// 返回按原顺序拆分的译文数组（与输入行数一致）；失败或行数不符时返回 nil，由调用方逐行兜底。
    private func translateBatch(lines: [String], completion: @escaping ([String]?) -> Void) {
        let joined = lines.joined(separator: "\n")
        guard !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion(nil); return
        }
        // 大模型优先通道（按选中的模型驱动）；否则默认 Google 公开接口
        if useLLMTranslate, activeTranslateAPIKey != nil {
            translateBatchViaLLM(lines: lines, joined: joined, completion: completion)
            return
        }
        translateViaGoogle(text: joined) { tr in
            if let tr, self.splitBatch(tr, expected: lines.count) != nil {
                completion(self.splitBatch(tr, expected: lines.count))
            } else if self.useLLMTranslate, self.activeTranslateAPIKey != nil {
                self.translateBatchViaLLM(lines: lines, joined: joined, completion: completion)
            } else { completion(nil) }
        }
    }

    /// 批量翻译走大模型（LLM 优先通道）。失败时回退 Google 公开接口，最终失败返回 nil。
    private func translateBatchViaLLM(lines: [String], joined: String,
                                      completion: @escaping ([String]?) -> Void) {
        guard let key = activeTranslateAPIKey else {
            translateViaGoogle(text: joined) { completion(self.splitBatch($0, expected: lines.count)) }
            return
        }
        let hasCJK = joined.contains { 0x4E00...0x9FFF ~= $0.unicodeScalars.first?.value ?? 0 }
        let targetLang = hasCJK ? "English" : "Chinese"
        let sysPrompt = "You are a lyrics translator. Translate each line of the given text into \(targetLang), keeping the SAME number of lines as the input, and use a single newline to separate lines. Keep it concise, preserve tone. Do NOT add explanations, numbering, or quotes. Output only the translated lines."
        let urlStr = "\(activeTranslateBaseURL)/chat/completions"
        guard let url = URL(string: urlStr) else {
            translateViaGoogle(text: joined) { completion(self.splitBatch($0, expected: lines.count)) }
            return
        }
        let body: [String: Any] = [
            "model": activeTranslateModel,
            "messages": [
                ["role": "system", "content": sysPrompt],
                ["role": "user", "content": joined]
            ],
            "temperature": 0.3,
            "max_tokens": 800
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 12
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                self.translateViaGoogle(text: joined) { completion(self.splitBatch($0, expected: lines.count)) }
                return
            }
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any],
                  let tr = msg["content"] as? String,
                  !tr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.translateViaGoogle(text: joined) { completion(self.splitBatch($0, expected: lines.count)) }
                return
            }
            let split = self.splitBatch(tr, expected: lines.count)
            if let split { completion(split) }
            else { self.translateViaGoogle(text: joined) { completion(self.splitBatch($0, expected: lines.count)) } }
        }.resume()
    }

    /// 把批量译文按换行拆回逐行；空行保留以对应原行位置；行数不符或为空返回 nil。
    private func splitBatch(_ text: String?, expected: Int) -> [String]? {
        guard let text = text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let parts = text.components(separatedBy: "\n")
        guard parts.count == expected else { return nil }
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// 免费翻译回退源：Google 翻译公开网页接口（translate.googleapis.com/translate_a/single）。
    /// 无需 key、无每日硬限额（仅频率限制，个人使用足够），替代原 MyMemory（有每日限额易耗尽）。
    private func translateViaGoogle(text: String, completion: @escaping (String?) -> Void) {
        let q = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard !q.isEmpty else { completion(nil); return }
        let hasCJK = text.contains { 0x4E00...0x9FFF ~= $0.unicodeScalars.first?.value ?? 0 }
        let target = hasCJK ? "en" : "zh"
        let urlStr = "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=\(target)&dt=t&q=\(q)"
        guard let url = URL(string: urlStr) else { completion(nil); return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let e = err { self.diagLog("translateViaGoogle 网络错误: \(e.localizedDescription)") }
            guard let data = data,
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  let seg0 = arr.first as? [Any], !seg0.isEmpty else {
                if let http = resp as? HTTPURLResponse { self.diagLog("translateViaGoogle HTTP \(http.statusCode) 失败") }
                completion(nil)
                return
            }
            // 译文分布在 seg0 每个子数组的第 0 个元素，拼接得到完整翻译
            var out = ""
            for piece in seg0 {
                if let p = piece as? [Any], let t = p.first as? String { out += t }
            }
            let cleaned = out.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { completion(nil); return }
            completion(cleaned)
        }.resume()
    }

    /// [临时诊断] 写入 ~/Library/Application Support/Lumi/lumi_translate.log 便于离线排查翻译。确认后移除。
    func diagLog(_ msg: String) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lumi")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("lumi_translate.log")
        let line = "\(Date()) [diag] \(msg)\n"
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile()
            fh.write(line.data(using: .utf8) ?? Data())
            try? fh.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
