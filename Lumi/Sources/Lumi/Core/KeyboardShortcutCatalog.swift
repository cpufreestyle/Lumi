import Foundation

/// Lumi 全部键位 / 手势的单一描述源（纯 Foundation，无 GUI 依赖）。
///
/// 为什么要有这个文件：此前快捷键提示只藏在「右键长按胶囊」的 NSMenu 里，
/// 既没有菜单栏入口、也没有集中说明，用户根本无从得知有哪些手势可操作
/// （用户原话：「快捷键的提示要让用户有办法找到」）。
///
/// 现在每一条手势只在这里描述一次：
/// - 菜单栏「快捷键与手势说明」面板从本目录读取（可见入口，随时可打开）；
/// - AppKit 侧菜单项也拼这里的文案（menuTitle），两处永不漂移。
///
/// 纯逻辑 + 无 AppKit 依赖是本文件的设计约束：它必须能进 LumiTests
/// （该 target 禁 GUI 框架），因此「新增手势忘了描述」「描述与实际实现不符」
/// 这类回归可以有测试兜住。
enum KeyboardShortcutCatalog {

    /// 一条键位说明。keys 是「按键描述」，scope 是「生效位置」，action 是「动作」。
    struct Entry: Equatable, Identifiable {
        /// 稳定列表标识：三者拼合保证同一手柄不会在同一分组里出现两次。
        var id: String { keys + "|" + scope + "|" + action }
        /// 按键组合描述（如「Option + 右键」「滚轮」）。纯展示层，不参与逻辑判断。
        var keys: String
        /// 该手势生效的位置（如「胶囊」「桌面歌词浮窗」）。
        var scope: String
        /// 动作文案（如「播放 / 暂停」）。
        var action: String
    }

    // MARK: - 分组

    /// 分组标题与分组内容，说明面板按顺序渲染。
    struct Section: Equatable, Identifiable {
        var id: String { title }
        var title: String
        var entries: [Entry]
    }

    /// 全部分组（顺序即面板顺序）。
    static let sections: [Section] = [
        Section(title: "胶囊（收缩态）", entries: capsuleEntries),
        Section(title: "桌面歌词浮窗", entries: desktopLyricsEntries),
        Section(title: "全局入口", entries: globalEntries),
    ]

    // MARK: - 胶囊（收缩态）

    /// 收缩态胶囊上的手势。与 IslandWindowController 的回调接线一一对应：
    /// handleCapsuleAuxClick / handleCapsuleNextTrack / handleCapsulePrevTrack /
    /// handleCapsuleScroll / showCapsuleMenu / handleNotchDoubleClick。
    static let capsuleEntries: [Entry] = [
        Entry(keys: "单击左键", scope: "胶囊", action: "展开 / 收起总面板"),
        Entry(keys: "双击左键", scope: "刘海热区", action: "固定 / 取消固定常驻"),
        Entry(keys: "右键", scope: "胶囊", action: "播放 / 暂停"),
        Entry(keys: "Option + 右键", scope: "胶囊", action: "上一首"),
        Entry(keys: "Shift + 右键 或 中键", scope: "胶囊", action: "下一首"),
        Entry(keys: "滚轮", scope: "胶囊", action: "音量 +5 / -5"),
        Entry(keys: "右键长按 0.45 秒", scope: "胶囊", action: "弹出快捷菜单"),
        Entry(keys: "长按左键 0.35 秒后拖动", scope: "胶囊", action: "微调歌词位置（放开后自动记住）"),
        Entry(keys: "双击左键", scope: "歌词区", action: "重置歌词微调偏移"),
    ]

    // MARK: - 桌面歌词浮窗

    /// 桌面歌词浮窗上的手势。与 DesktopLyricsWindowController 的接线对应：
    /// 左键整窗拖拽（performDrag）、滚轮循环字号、右键短按播控、悬停显控制条。
    /// 中键同为下一首，与胶囊同一套键位观。
    static let desktopLyricsEntries: [Entry] = [
        Entry(keys: "左键拖动", scope: "桌面歌词", action: "移动浮窗（位置自动记住）"),
        Entry(keys: "右键", scope: "桌面歌词", action: "播放 / 暂停"),
        Entry(keys: "中键", scope: "桌面歌词", action: "下一首"),
        Entry(keys: "滚轮", scope: "桌面歌词", action: "切换字号（小 / 中 / 大）"),
        Entry(keys: "悬停右上角", scope: "桌面歌词", action: "显示字号按钮与隐藏按钮"),
    ]

    // MARK: - 全局入口

    /// 全局 / 系统级入口（菜单栏是用户最先能找到的地方）。
    static let globalEntries: [Entry] = [
        Entry(keys: "点击菜单栏图标", scope: "菜单栏", action: "显示 / 隐藏动态岛"),
        Entry(keys: "打开快捷键说明", scope: "菜单栏", action: "查看全部键位与手势"),
        // 默认关闭：新增功能不擅自抢占键位。括号里的说明让用户知道去哪儿开。
        Entry(keys: "⌘⌥P（需先在菜单栏开启）", scope: "任意应用前台", action: "播放 / 暂停"),
        Entry(keys: "播放 / 暂停", scope: "菜单栏", action: "直接播控（无需快捷键）"),
    ]

    /// 全部分组拼成扁平列表（测试与调试用）。
    static var allEntries: [Entry] {
        sections.flatMap { $0.entries }
    }

    /// AppKit 侧菜单项标题（如胶囊右键菜单）。与说明面板共用同一份 Entry，
    /// 因此菜单里写的手势和说明面板里写的手势不可能对不上。
    static func menuTitle(for entry: Entry) -> String {
        entry.action + "　（" + entry.keys + "）"
    }

    /// 按动作文案精确取条目（供菜单项按语义取键位描述）。
    /// 返回 nil 表示目录里没有该动作：调用方必须兜底，不能崩——
    /// 用下标访问在条目增删时会静默串位，那比 nil 更难查。
    static func entry(action: String) -> Entry? {
        allEntries.first { $0.action == action }
    }

    /// 菜单项标题：按动作文案取键位描述拼成「动作　（键位）」。
    /// 目录缺该动作时退回只显示动作本身，菜单仍可用、只是没有键位提示。
    static func menuTitle(action: String) -> String {
        guard let entry = entry(action: action) else { return action }
        return menuTitle(for: entry)
    }
}
