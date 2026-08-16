import Foundation

/// 市场安装包（.app.zip）解压后的 .app 定位与修复。
///
/// 仅依赖 Foundation，保持可被 `swift test`（无 GUI 会话）覆盖。
///
/// 背景：历史版本的 `make_sample_plugin.sh --zip` 用 `ditto -c -k` 打包时
/// 丢了 `--keepParent`，导致 Release 上的 zip 根目录直接是 `Contents/`
/// 而非 `LumiSamplePlugin.app/Contents/`，市场安装端解压后找不到 `.app`
/// 报「压缩包内无 .app」，表现为「卸载后无法重新安装」。
/// 此工具在定位 .app 时对这类坏包做兼容修复（用清单里的 appName 补一层外壳）。
enum PluginArchive {

    enum ArchiveError: LocalizedError {
        case noAppFound

        var errorDescription: String? {
            switch self {
            case .noAppFound:
                return "压缩包内无 .app"
            }
        }
    }

    /// 在解压目录 `workDir` 中定位 .app；必要时就地修复坏包结构。
    ///
    /// 兼容三种布局：
    /// 1. 标准：`workDir/Foo.app/…`（`ditto -c -k --keepParent` 产物）→ 直接返回；
    /// 2. 坏包：`workDir/Contents/…`（丢了 .app 外壳）→ 以 `fallbackAppName`
    ///    （取自插件清单的 `appName`，缺省 `Plugin.app`）包一层外壳后返回；
    /// 3. 嵌套：`workDir/唯一目录/Foo.app/…` → 下钻一层返回。
    ///
    /// - Note: 方法会移动 `workDir` 内的文件（修复坏包）；调用方需保证
    ///   `workDir` 是本次安装的临时目录，且其中的 zip 等杂物不会被误认。
    static func locateOrWrapApp(in workDir: URL,
                                fallbackAppName: String? = nil) throws -> URL {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(
            at: workDir, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []

        // 1) 标准布局：顶层直接有 .app
        if let app = entries.first(where: { isAppDirectory($0) }) {
            return app
        }

        let directories = entries.filter { hasDirectoryPath($0) }

        // 2) 坏包：顶层是 Contents/（.app 的内容被直接打了包）
        if let contents = directories.first(where: { $0.lastPathComponent == "Contents" }) {
            return try wrapContents(contents, fallbackAppName: fallbackAppName)
        }

        // 3) 嵌套：zip 根是唯一目录，.app 在其中（某些打包器会多包一层）
        if directories.count == 1 {
            let inner = directories[0]
            let innerEntries = (try? fm.contentsOfDirectory(
                at: inner, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
            if let app = innerEntries.first(where: { isAppDirectory($0) }) {
                return app
            }
            // 内层也是坏包（Contents/）→ 就地补外壳
            if let contents = innerEntries.first(where: {
                hasDirectoryPath($0) && $0.lastPathComponent == "Contents"
            }) {
                let app = try wrapContents(contents, fallbackAppName: fallbackAppName)
                // 把补好外壳的 .app 提升到顶层，保持与标准布局一致
                let promoted = workDir.appendingPathComponent(app.lastPathComponent)
                try? fm.removeItem(at: promoted)
                try fm.moveItem(at: app, to: promoted)
                return promoted
            }
        }

        throw ArchiveError.noAppFound
    }

    // MARK: - 内部

    private static func isAppDirectory(_ url: URL) -> Bool {
        url.pathExtension == "app" && hasDirectoryPath(url)
    }

    private static func hasDirectoryPath(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    /// 把裸 `Contents/` 补上 .app 外壳（就地移动到 workDir/<name>/Contents）。
    private static func wrapContents(_ contents: URL,
                                     fallbackAppName: String?) throws -> URL {
        let fm = FileManager.default
        var name = fallbackAppName?.isEmpty == false ? fallbackAppName! : "Plugin.app"
        if !name.hasSuffix(".app") { name += ".app" }
        let wrapper = contents.deletingLastPathComponent().appendingPathComponent(name)
        guard !fm.fileExists(atPath: wrapper.path) else {
            // 已存在同名 .app（异常状态）：不覆盖，交给上层报错
            throw ArchiveError.noAppFound
        }
        try fm.createDirectory(at: wrapper, withIntermediateDirectories: false)
        try fm.moveItem(at: contents, to: wrapper.appendingPathComponent("Contents"))
        return wrapper
    }
}
