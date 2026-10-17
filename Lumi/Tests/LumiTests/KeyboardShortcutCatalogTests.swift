import XCTest
@testable import Lumi

/// 快捷键 / 手势目录的完整性测试（Foundation only，符合 LumiTests 不引入 GUI 框架的约束）。
///
/// 用户要求：「快捷键的提示要让用户有办法找到」。目录 KeyboardShortcutCatalog 是
/// 菜单栏说明面板与 AppKit 菜单项共用的单一数据源，这里守住三条不变量：
/// 1. 三个分组都非空，且每个 entry 的 keys / scope / action 都非空（防止半成品条目）；
/// 2. 分组标题不重复（section.id 由 title 推出，重复会让 SwiftUI 列表标识冲突）；
/// 3. allEntries 等于各组拼平（保证菜单栏面板与调试用扁平列表严格同源）。
final class KeyboardShortcutCatalogTests: XCTestCase {

    func testSectionsAreNonEmptyAndWellFormed() {
        XCTAssertFalse(KeyboardShortcutCatalog.sections.isEmpty)
        for section in KeyboardShortcutCatalog.sections {
            XCTAssertFalse(section.entries.isEmpty, "分组「\(section.title)」不能为空")
            for entry in section.entries {
                XCTAssertFalse(entry.keys.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               "「\(entry.action)」缺少按键描述")
                XCTAssertFalse(entry.scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               "「\(entry.action)」缺少生效位置")
                XCTAssertFalse(entry.action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               "「\(entry.keys)」缺少动作文案")
            }
        }
    }

    func testSectionTitlesAreUnique() {
        let titles = KeyboardShortcutCatalog.sections.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count)
    }

    func testAllEntriesIsConcatOfSections() {
        let flat = KeyboardShortcutCatalog.sections.flatMap(\.entries)
        XCTAssertEqual(KeyboardShortcutCatalog.allEntries, flat)
    }

    func testMenuTitleEmbedsActionAndKeys() {
        let entry = KeyboardShortcutCatalog.Entry(keys: "右键", scope: "胶囊", action: "播放 / 暂停")
        let title = KeyboardShortcutCatalog.menuTitle(for: entry)
        XCTAssertTrue(title.contains("播放 / 暂停"))
        XCTAssertTrue(title.contains("右键"))
    }

    func testCapsuleAndDesktopLyricsSectionsCoverCoreGestures() {
        // 关键手势必须出现在目录里：这是用户「找不到快捷键」抱怨的核心修复点。
        let all = KeyboardShortcutCatalog.allEntries
        let keys = all.map(\.keys)
        XCTAssertTrue(keys.contains { $0.contains("双击左键") })
        XCTAssertTrue(keys.contains { $0.contains("滚轮") })
        XCTAssertTrue(keys.contains { $0.contains("右键") })
        XCTAssertTrue(keys.contains { $0.contains("中键") })
        XCTAssertTrue(keys.contains { $0.contains("长按") })
        XCTAssertEqual(all.count, KeyboardShortcutCatalog.capsuleEntries.count
                       + KeyboardShortcutCatalog.desktopLyricsEntries.count
                       + KeyboardShortcutCatalog.globalEntries.count)
    }
}
