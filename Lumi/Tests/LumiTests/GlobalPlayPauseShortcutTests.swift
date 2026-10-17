import XCTest
@testable import Lumi

/// 全局播放/暂停快捷键的匹配逻辑测试（Foundation only，符合 LumiTests 不引入 GUI 框架的约束）。
///
/// 对应 `docs/播放暂停快捷键方案.md` 的方案 A。三条断言各守一个真实失败场景：
/// 中文输入法下用 characters 匹配会失灵（必须按 keyCode 比）、开着 CapsLock 时
/// 全等比较 modifierFlags 会让快捷键失效、目标键位无修饰键时不能「随便按 P 就触发」。
final class GlobalPlayPauseShortcutTests: XCTestCase {

    /// ⌘⌥P —— 方案文档推荐的默认键位（冲突最少，P = Play 易记）。
    private let wantKeyCode: UInt16 = 35
    private var wantModifiers: NSEvent.ModifierFlags { [.command, .option] }

    func testExactMatch() {
        XCTAssertTrue(GlobalPlayPauseShortcut.matches(keyCode: 35,
                                                    modifiers: [.command, .option],
                                                    expectedKeyCode: wantKeyCode,
                                                    expectedModifiers: wantModifiers))
    }

    func testKeyCodeMismatchDoesNotTrigger() {
        // 修饰键全对但按的是别的键（例如 I / O），不能触发。
        XCTAssertFalse(GlobalPlayPauseShortcut.matches(keyCode: 34,
                                                     modifiers: [.command, .option],
                                                     expectedKeyCode: wantKeyCode,
                                                     expectedModifiers: wantModifiers))
    }

    func testModifierSubsetDoesNotTrigger() {
        // 只按 ⌘P（少一个 ⌥）不能触发：否则更容易撞到别的 app 的快捷键。
        XCTAssertFalse(GlobalPlayPauseShortcut.matches(keyCode: 35,
                                                     modifiers: [.command],
                                                     expectedKeyCode: wantKeyCode,
                                                     expectedModifiers: wantModifiers))
    }

    func testExtraModifierDoesNotTrigger() {
        // 多按一个 ⇧ 也不能触发。
        XCTAssertFalse(GlobalPlayPauseShortcut.matches(keyCode: 35,
                                                     modifiers: [.command, .option, .shift],
                                                     expectedKeyCode: wantKeyCode,
                                                     expectedModifiers: wantModifiers))
    }

    func testCapsLockAndFunctionFlagsAreIgnored() {
        // 关键回归点：开着 CapsLock / Function（或小键盘状态位）时快捷键必须仍然可用。
        // 早期写法直接全等比较 modifierFlags，这些状态位一进来就永远匹配不上。
        let noisy: NSEvent.ModifierFlags = [.command, .option, .capsLock, .function, .numericPad]
        XCTAssertTrue(GlobalPlayPauseShortcut.matches(keyCode: 35,
                                                    modifiers: noisy,
                                                    expectedKeyCode: wantKeyCode,
                                                    expectedModifiers: wantModifiers))
    }

    func testNoModifierExpectedRequiresNoModifierPressed() {
        // 目标键位不带修饰键时，误按 ⌘+该键 也不触发，只在「真的只按这一个键」时触发。
        XCTAssertFalse(GlobalPlayPauseShortcut.matches(keyCode: 35,
                                                     modifiers: [.command],
                                                     expectedKeyCode: 35,
                                                     expectedModifiers: []))
        XCTAssertTrue(GlobalPlayPauseShortcut.matches(keyCode: 35,
                                                    modifiers: [],
                                                    expectedKeyCode: 35,
                                                    expectedModifiers: []))
    }

    func testShiftAsRequiredModifierMatches() {
        // 目标含 ⇧ 时必须真的按到 ⇧（与只用 ⌘⌥ 区分开）。
        XCTAssertTrue(GlobalPlayPauseShortcut.matches(keyCode: 35,
                                                    modifiers: [.command, .option, .shift],
                                                    expectedKeyCode: 35,
                                                    expectedModifiers: [.command, .option, .shift]))
    }
}
