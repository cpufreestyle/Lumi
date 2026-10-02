import Foundation

/// 展开态标签栏的「固定两行」布局计算（纯逻辑，Foundation only）。
///
/// 抽成独立类型是为了能进 `LumiTests`（该 target 禁 GUI 框架，只允许 Foundation）。
/// 「标签栏恒为两行」是用户明确提出的硬要求，必须有测试兜住：
/// 一旦有人把 `GridItem(.flexible(), count:)` 改回 `.adaptive(minimum:)`，
/// 行数就会随面板宽度漂移（窄面板变三行），而这类回归在编译期与单测里
/// 都发现不了，只能靠这里的断言守住。
enum TabBarLayout {

    /// 单个网格最多占几列。超过就允许折行 —— 否则每列会被压到十几 pt，
    /// 文字完全不可读（只有插件装到十几个才会触发）。
    static let maxColumns = 12

    /// 某组标签应该用几列：正常情况下「标签个数」即列数，正好排满一行。
    static func columns(forItemCount count: Int) -> Int {
        max(1, min(count, maxColumns))
    }

    /// 两行共用的列数 —— **这是「整齐」的关键**。
    ///
    /// 两行必须用同一个列数，单元格才会等宽、上下对齐。若各行按自己的
    /// 单元数取列数（第一行 12 格、第二行 8 格），两行单元格宽度不同，
    /// 图标与文字在垂直方向错位，看上去就是「不整齐」。
    ///
    /// 取两行单元数的较大者：宽的那行正好铺满，窄的那行用透明占位补齐，
    /// 于是两行都是相同的网格节奏，且都不会折行。
    static func cellColumns(builtInCount: Int, secondRowCount: Int) -> Int {
        max(1, min(max(builtInCount, secondRowCount), maxColumns))
    }

    /// 某行要补几个透明占位单元，才能撑满 `columns` 列。
    /// 返回 0 表示该行本来就够宽（或不值得补）。
    static func spacerCount(itemCount: Int, columns: Int) -> Int {
        max(0, columns - itemCount)
    }

    /// 某组标签实际占几行。
    static func rows(itemCount: Int, columns: Int) -> Int {
        guard itemCount > 0, columns > 0 else { return 0 }
        return (itemCount + columns - 1) / columns
    }

    /// 整条标签栏（内置组 + 插件组）合计占几行。
    static func totalRows(builtInCount: Int, pluginCount: Int) -> Int {
        let builtInRows = rows(itemCount: builtInCount, columns: columns(forItemCount: builtInCount))
        let pluginRows = rows(itemCount: pluginCount, columns: columns(forItemCount: pluginCount))
        return builtInRows + pluginRows
    }

    /// 按「两行共用列数」的算法算总行数（与 `totalRows` 的区别：这里含补齐后的判断）。
    /// 补齐后每行恰好 `columns` 个单元，因此**恒为 2 行**（只要不超过 maxColumns）。
    static func alignedTotalRows(builtInCount: Int, secondRowCount: Int) -> Int {
        let columns = cellColumns(builtInCount: builtInCount, secondRowCount: secondRowCount)
        return rows(itemCount: max(builtInCount, 1), columns: columns)
             + rows(itemCount: max(secondRowCount, 1), columns: columns)
    }
}
