import XCTest
import EventKit
@testable import Lumi

/// 守住「已授权就不要重复提示」的授权守卫决策（Foundation only，符合 LumiTests 约束）。
///
/// 用户明确要求：检测到已经授权就不要重复提示。Calendar / 通知 / 麦克风三处
/// 原先都无条件调 request*，已授权时虽然不会重复弹窗，但每次都会走一次授权
/// 往返、并在系统设置的「最近请求权限」里反复刷新 —— 用户看到的就是 Lumi
/// 反复在要权限。这里守住 Calendar 的决策函数：只有 notDetermined 才允许请求。
final class CalendarAuthorizationGuardTests: XCTestCase {

    func testNotDeterminedIsTheOnlyStateThatRequests() {
        XCTAssertTrue(CalendarController.shouldRequestEventAccess(status: .notDetermined))
    }

    func testAlreadyAuthorizedDoesNotRequestAgain() {
        XCTAssertFalse(CalendarController.shouldRequestEventAccess(status: .fullAccess))
    }

    func testDeniedDoesNotRequestOrPrompt() {
        XCTAssertFalse(CalendarController.shouldRequestEventAccess(status: .denied))
        XCTAssertFalse(CalendarController.shouldRequestEventAccess(status: .restricted))
    }

    func testWriteOnlyStatusDoesNotRequestEither() {
        // writeOnly 是更窄的旧权限档位，不是「未决定」，不应再触发请求。
        if #available(macOS 14.0, *) {
            XCTAssertFalse(CalendarController.shouldRequestEventAccess(status: .writeOnly))
        }
    }
}
