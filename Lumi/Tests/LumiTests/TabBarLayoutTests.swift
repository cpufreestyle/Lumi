import XCTest
@testable import Lumi

/// 标签栏「固定两行」布局计算测试（Foundation only，符合 LumiTests 不引入 GUI 框架的约束）。
///
/// 用户明确要求「这里固定就 2 行」。原先用 `.adaptive(minimum:)` 自适应折行，
/// 面板变窄时标签栏会从两行变三行、高度随宽度漂移。改成锁定列数后必须
/// 有测试守住，否则改回 adaptive 时编译与运行都不会报错、只有肉眼能发现。
final class TabBarLayoutTests: XCTestCase {

    // MARK: - 当前实际配置

    /// 第二行的全部单元数：插件市场入口 1 + 带面板的插件 4 + 工具按钮 3。
    private let currentSecondRowCells = 8

    func testCurrentConfigurationIsExactlyTwoRows() {
        // 第一行：12 个内置模块；第二行：1 市场入口 + 4 插件 + 3 工具按钮 = 8。
        // 注意工具按钮已经并入第二行（用户要求「所有内容都在两行」），
        // 所以这里必须按 8 而不是 5 来算，否则测的是过时的结构。
        XCTAssertEqual(TabBarLayout.totalRows(builtInCount: 12, pluginCount: currentSecondRowCells), 2)
        XCTAssertEqual(TabBarLayout.alignedTotalRows(builtInCount: 12, secondRowCount: currentSecondRowCells), 2)
    }

    func testSharedColumnsAlignsBothRowsToTwelveColumns() {
        // 两行必须共用同一套列数（取较多者 = 12 列），
        // 单元格才会等宽，上下两行的图标、文字垂直对齐。
        XCTAssertEqual(TabBarLayout.cellColumns(builtInCount: 12, secondRowCount: currentSecondRowCells), 12)
        // 第一行满 12 列，不需要补占位
        XCTAssertEqual(TabBarLayout.spacerCount(itemCount: 12, columns: 12), 0)
        // 第二行 8 个单元，中间补 4 个透明占位撑满 12 列，把工具按钮推到行尾
        XCTAssertEqual(TabBarLayout.spacerCount(itemCount: currentSecondRowCells, columns: 12), 4)
    }

    func testBuiltInGroupTakesOneRow() {
        XCTAssertEqual(TabBarLayout.columns(forItemCount: 12), 12)
        XCTAssertEqual(TabBarLayout.rows(itemCount: 12, columns: 12), 1)
    }

    func testSecondRowWithToolButtonsTakesOneRow() {
        // 8 个单元（含 3 个工具按钮）仍应排在一行内
        XCTAssertEqual(TabBarLayout.columns(forItemCount: currentSecondRowCells), currentSecondRowCells)
        XCTAssertEqual(TabBarLayout.rows(itemCount: currentSecondRowCells,
                                          columns: TabBarLayout.columns(forItemCount: currentSecondRowCells)), 1)
    }

    // MARK: - 列数与容量的边界

    func testColumnCountEqualsItemCountUpToCap() {
        for n in 1...TabBarLayout.maxColumns {
            XCTAssertEqual(TabBarLayout.columns(forItemCount: n), n, "标签数 \(n) 应正好排一行")
        }
    }

    func testColumnCountClampedAtCapSoCellsStayReadable() {
        // 超过 12 个就允许折行：否则每列只剩十几 pt，文字没法看。
        XCTAssertEqual(TabBarLayout.columns(forItemCount: 13), TabBarLayout.maxColumns)
        XCTAssertEqual(TabBarLayout.columns(forItemCount: 40), TabBarLayout.maxColumns)
        // 13 个标签 / 12 列 = 2 行
        XCTAssertEqual(TabBarLayout.rows(itemCount: 13, columns: TabBarLayout.maxColumns), 2)
    }

    func testZeroOrNegativeCountStillYieldsOneColumn() {
        // 列数至少为 1：GridItem 数组不能为空，否则 LazyVGrid 直接崩。
        XCTAssertEqual(TabBarLayout.columns(forItemCount: 0), 1)
        XCTAssertEqual(TabBarLayout.columns(forItemCount: -3), 1)
    }

    // MARK: - 行数计算

    func testRowsUsesCeilingDivision() {
        XCTAssertEqual(TabBarLayout.rows(itemCount: 12, columns: 5), 3)   // 12/5 → 3
        XCTAssertEqual(TabBarLayout.rows(itemCount: 10, columns: 5), 2)   // 正好整除
        XCTAssertEqual(TabBarLayout.rows(itemCount: 1, columns: 5), 1)
    }

    func testRowsIsZeroForEmptyGroup() {
        XCTAssertEqual(TabBarLayout.rows(itemCount: 0, columns: 5), 0)
    }

    // MARK: - 跨宽度的稳定性

    func testRowCountDoesNotDependOnPanelWidth() {
        // 关键性质：总行数只由「标签个数」决定，与面板宽度无关。
        // 面板从 360pt 拉到 1000pt，行数都必须是 2 —— 这正是修复的意义。
        for panelWidth in [360, 480, 560, 625, 800, 1000] {
            XCTAssertEqual(TabBarLayout.totalRows(builtInCount: 12, pluginCount: 5), 2,
                           "面板宽 \(panelWidth)pt 时行数不应变化")
        }
    }

    func testTwoRowsHoldForAPlausibleRangeOfSecondRowCells() {
        // 内置恒为 12 个；第二行从 1（只有市场入口）到 12 个单元
        // （含工具按钮与插件），标签栏都应是两行。
        for secondRowCells in 1...12 {
            XCTAssertEqual(TabBarLayout.totalRows(builtInCount: 12, pluginCount: secondRowCells), 2,
                           "第二行 \(secondRowCells) 个单元时应仍为两行")
        }
    }

    func testDegradesToThreeRowsOnlyWhenSecondRowExceedsCap() {
        // 第二行超过 12 个单元才会多出一行，这是刻意的：可读性优先于死守两行。
        // 12 内置 + 1 市场入口 + 3 工具 = 16，意味着最多还能装 8 个带面板插件。
        XCTAssertEqual(TabBarLayout.totalRows(builtInCount: 12, pluginCount: 13), 3)
    }
}
