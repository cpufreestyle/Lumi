import XCTest
@testable import Lumi

/// 守住胶囊右键菜单的 action 字面量与 KeyboardShortcutCatalog 严格对齐。
///
/// 踩过的坑：调用方写的是 U+2212 真减号「音量 +5 / −5」，而目录里已改成 ASCII「-」，
/// 字符串不相等 → entry(action:) 返回 nil → 按 menuTitle 的兜底逻辑只显示动作名，
/// 把「（滚轮）」这个键位提示悄悄丢掉了。这类漂移编译期完全没有提示，只能靠断言兜住。
final class KeyboardShortcutCatalogMenuTitleTests: XCTestCase {

    /// 胶囊右键菜单实际用到的三个 action 字面量（与 IslandWindowController 逐字一致）。
    private static let usedActions = ["上一首", "下一首", "音量 +5 / -5"]

    func testEveryMenuActionResolvesToCatalogEntry() {
        for action in Self.usedActions {
            let entry = KeyboardShortcutCatalog.entry(action: action)
            XCTAssertNotNil(entry, "菜单 action「\(action)」在目录里找不到，键位提示会被悄悄丢掉")
        }
    }

    func testMenuTitleAlwaysEmbedsKeysWhenEntryExists() {
        for action in Self.usedActions {
            let title = KeyboardShortcutCatalog.menuTitle(action: action)
            XCTAssertTrue(title.contains("（"), "「\(title)」缺少键位括号，说明没有从目录取到 keys")
            XCTAssertTrue(title.contains(action), "「\(title)」应包含动作文案本身")
        }
    }

    func testCatalogActionsUseAsciiHyphenOnly() {
        // 目录里的减号统一用 ASCII -：一旦混入 U+2212，调用方就会踩上面那个坑。
        for entry in KeyboardShortcutCatalog.allEntries {
            XCTAssertFalse(entry.action.contains("\u{2212}"),
                           "「\(entry.action)」含 U+2212，请改用 ASCII -")
        }
    }
}
