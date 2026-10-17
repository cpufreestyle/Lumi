import XCTest
@testable import Lumi

/// 桌面歌词浮窗纯逻辑测试（Foundation only，符合 LumiTests 不引入 GUI 框架的约束）。
final class DesktopLyricsLayoutTests: XCTestCase {

    // MARK: - 文本宽度估算

    func testTextWidthCJKCountsOneEmPerChar() {
        let cjk = DesktopLyricsLayout.textWidth("你好世界", fontSize: 20)
        let ascii = DesktopLyricsLayout.textWidth("abcd", fontSize: 20)
        // CJK 1.06 em、ASCII 0.60 em（含 .rounded design 字宽余量，防右侧裁切）
        XCTAssertEqual(cjk, 1.06 * 20 * 4, accuracy: 0.001)
        XCTAssertEqual(ascii, 0.60 * 20 * 4, accuracy: 0.001)
        XCTAssertGreaterThan(cjk, ascii)
    }

    func testTextWidthEmptyStringIsZero() {
        XCTAssertEqual(DesktopLyricsLayout.textWidth("", fontSize: 20), 0)
    }

    func testTextWidthScalesLinearlyWithFontSize() {
        let line = "Hello 世界"
        let small = DesktopLyricsLayout.textWidth(line, fontSize: 10)
        let big = DesktopLyricsLayout.textWidth(line, fontSize: 20)
        XCTAssertEqual(big / small, 2.0, accuracy: 0.001)
    }

    // MARK: - 内容尺寸

    func testContentSizeSingleLineHasNoTranslationRow() {
        let size = DesktopLyricsLayout.contentSize(line: "测试歌词", translation: "", showTranslation: false)
        let expectedWidth = max(DesktopLyricsLayout.minWidth,
                                DesktopLyricsLayout.textWidth("测试歌词", fontSize: 20)
                                    + DesktopLyricsLayout.horizontalPadding)
        XCTAssertEqual(size.width, expectedWidth, accuracy: 0.5)
        XCTAssertEqual(size.height,
                       DesktopLyricsLayout.originalHeight + DesktopLyricsLayout.verticalPadding)
    }

    func testContentSizeWithTranslationAddsRow() {
        let single = DesktopLyricsLayout.contentSize(line: "你好", translation: "", showTranslation: false)
        let bilingual = DesktopLyricsLayout.contentSize(line: "你好",
                                                        translation: "Hello",
                                                        showTranslation: true)
        // 英文译文行被抬到与中文原文同字号（20pt），行高随之按比例放大：
        // 18 * (20/13) ≈ 27.7，而不是旧的固定 18（旧值会把放大的第二行裁掉）。
        XCTAssertEqual(bilingual.height - single.height,
                       DesktopLyricsLayout.translationHeight * (20.0 / 13.0), accuracy: 0.6)
        // 宽度也按放大后的字号算
        let expectedWidth = max(DesktopLyricsLayout.textWidth("你好", fontSize: 20),
                                DesktopLyricsLayout.textWidth("Hello", fontSize: 20))
            + DesktopLyricsLayout.horizontalPadding
        XCTAssertEqual(bilingual.width, max(DesktopLyricsLayout.minWidth, expectedWidth), accuracy: 0.5)
    }

    func testEnglishTranslationNotSmallerThanChineseOriginal() {
        // 用户要求：英文歌词字号「大于中文或等于中文」。中英双语对里英文那行
        // 不能再低于中文那行（bilingualSizes 的统一规则）。
        let sizes = DesktopLyricsLayout.bilingualSizes(originalBase: 20,
                                                       translationBase: 13,
                                                       original: "你好世界",
                                                       translation: "Hello world",
                                                       wantsTranslation: true)
        XCTAssertGreaterThanOrEqual(sizes.translation, sizes.original)
        // 中文译文的场景不受影响：仍是 13 基准，不会被抬到 20
        let zhPair = DesktopLyricsLayout.bilingualSizes(originalBase: 20,
                                                        translationBase: 13,
                                                        original: "Hello world",
                                                        translation: "你好世界",
                                                        wantsTranslation: true)
        XCTAssertEqual(zhPair.original, 20 * DesktopLyricsLayout.latinScale, accuracy: 0.001)
        XCTAssertEqual(zhPair.translation, 13, accuracy: 0.001)
        // 关闭双语：译文完全不参与
        let off = DesktopLyricsLayout.bilingualSizes(originalBase: 20,
                                                     translationBase: 13,
                                                     original: "你好",
                                                     translation: "Hello",
                                                     wantsTranslation: false)
        XCTAssertEqual(off.translation, 13 * DesktopLyricsLayout.latinScale, accuracy: 0.001)
    }

    func testContentSizeLongLineClampsToMaxWidth() {
        let long = String(repeating: "很长的一句歌词", count: 20)
        let size = DesktopLyricsLayout.contentSize(line: long, translation: "", showTranslation: false)
        XCTAssertEqual(size.width, DesktopLyricsLayout.maxWidth)
        XCTAssertGreaterThanOrEqual(size.height, DesktopLyricsLayout.originalHeight)
    }

    func testContentSizeShortLineFallsBackToMinWidth() {
        let size = DesktopLyricsLayout.contentSize(line: "♪", translation: "", showTranslation: false)
        XCTAssertEqual(size.width, DesktopLyricsLayout.minWidth)
    }

    func testContentSizeTrailingReserveWidensWindowOnly() {
        // 右上角悬停控制条的让位：窗口按「文字 + 让位」加宽，歌词行不伸到按钮下方；
        // 高度只由行数与字号决定，不受让位影响。
        // 行长得足以突破 minWidth，否则宽度被保底、看不到让位增量
        let line = String(repeating: "很长的一句歌词", count: 3)
        let base = DesktopLyricsLayout.contentSize(line: line,
                                                   translation: "",
                                                   showTranslation: false)
        let reserved = DesktopLyricsLayout.contentSize(line: line,
                                                       translation: "",
                                                       showTranslation: false,
                                                       trailingReserve: 110)
        XCTAssertEqual(reserved.width, base.width + 110, accuracy: 0.5)
        XCTAssertEqual(reserved.height, base.height, accuracy: 0.001)
        // 默认不传让位参数：与旧行为完全一致（既有调用点不受影响）
        let legacy = DesktopLyricsLayout.contentSize(line: line,
                                                     translation: "",
                                                     showTranslation: false,
                                                     trailingReserve: 0)
        XCTAssertEqual(legacy.width, base.width, accuracy: 0.001)
        // 短行仍被 minWidth 保底，但保底的是「文字预算」：让位加在保底之外
        // （200 → 310），文字区仍有 168pt 可用，不会因按钮让位被挤压截断
        let short = DesktopLyricsLayout.contentSize(line: "♪",
                                                    translation: "",
                                                    showTranslation: false,
                                                    trailingReserve: 110)
        XCTAssertEqual(short.width, DesktopLyricsLayout.minWidth + 110, accuracy: 0.001)
        // 与 maxWidth 钳制叠加：上限只夹文字预算，让位加在夹制之外 ——
        // 超长行的可见字数与无让位时一致，按钮只压让位留白、不吃歌词
        let long = String(repeating: "很长的一句歌词", count: 20)
        let clamped = DesktopLyricsLayout.contentSize(line: long,
                                                      translation: "",
                                                      showTranslation: false,
                                                      trailingReserve: 110)
        let clampedPlain = DesktopLyricsLayout.contentSize(line: long,
                                                           translation: "",
                                                           showTranslation: false)
        XCTAssertEqual(clamped.width, DesktopLyricsLayout.maxWidth + 110, accuracy: 0.001)
        // 去掉让位后剩下的宽度 == 无让位时的宽度：文字预算零损耗
        XCTAssertEqual(clamped.width - 110, clampedPlain.width, accuracy: 0.001)
    }

    func testContentSizeIgnoresTranslationWhenModeOff() {
        let off = DesktopLyricsLayout.contentSize(line: "你好", translation: "Hello", showTranslation: false)
        let single = DesktopLyricsLayout.contentSize(line: "你好", translation: "", showTranslation: false)
        // 关闭双语：传入的译文被忽略，行高与「无译文」完全一致
        XCTAssertEqual(off.height, single.height)
        XCTAssertEqual(off.width, single.width)
    }

    // MARK: - 屏幕边界钳制

    func testClampKeepsOriginInsideVisibleFrame() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 300, height: 56)
        let ok = DesktopLyricsLayout.clamp(origin: CGPoint(x: 400, y: 300), size: size, visibleFrame: visible)
        XCTAssertEqual(ok.x, 400)
        XCTAssertEqual(ok.y, 300)
        let outside = DesktopLyricsLayout.clamp(origin: CGPoint(x: -500, y: -500), size: size, visibleFrame: visible)
        XCTAssertEqual(outside.x, DesktopLyricsLayout.edgeMargin)
        XCTAssertEqual(outside.y, DesktopLyricsLayout.edgeMargin)
        let overflow = DesktopLyricsLayout.clamp(origin: CGPoint(x: 5000, y: 5000), size: size, visibleFrame: visible)
        XCTAssertEqual(overflow.x, visible.maxX - size.width - DesktopLyricsLayout.edgeMargin)
        XCTAssertEqual(overflow.y, visible.maxY - size.height - DesktopLyricsLayout.edgeMargin)
    }

    func testClampWhenWindowBiggerThanVisibleFrame() {
        let visible = CGRect(x: 100, y: 50, width: 200, height: 100)
        let huge = CGSize(width: 900, height: 400)
        let origin = DesktopLyricsLayout.clamp(origin: CGPoint(x: 5000, y: 5000),
                                                size: huge, visibleFrame: visible)
        XCTAssertEqual(origin.x, visible.minX + DesktopLyricsLayout.edgeMargin)
        XCTAssertEqual(origin.y, visible.minY + DesktopLyricsLayout.edgeMargin)
    }

    // MARK: - 松钳制（拖拽 / 松手共用：可探出屏幕，跨屏不硬停）

    func testClampAllowingOverhangKeepsWindowGrabbable() {
        // 主屏 0~1147，窗口 568x70：允许探出，但每轴至少留 onScreenMinimum 在屏内。
        let visible = CGRect(x: 0, y: 0, width: 1147, height: 745)
        let size = CGSize(width: 568, height: 70)
        let keep = DesktopLyricsLayout.onScreenMinimum

        // 完全在屏内：原样保留。
        let inside = DesktopLyricsLayout.clampAllowingOverhang(
            origin: CGPoint(x: 100, y: 300), size: size, visibleFrame: visible)
        XCTAssertEqual(inside.x, 100, accuracy: 0.001)
        XCTAssertEqual(inside.y, 300, accuracy: 0.001)

        // 往右探出：右边界只受 maxX - keep 约束，不再要求整窗落屏。
        let right = DesktopLyricsLayout.clampAllowingOverhang(
            origin: CGPoint(x: 5000, y: 300), size: size, visibleFrame: visible)
        XCTAssertEqual(right.x, visible.maxX - keep, accuracy: 0.001)

        // 往左探出：允许左边界跑到屏外，只要保留 keep 宽。
        let left = DesktopLyricsLayout.clampAllowingOverhang(
            origin: CGPoint(x: -5000, y: 300), size: size, visibleFrame: visible)
        XCTAssertEqual(left.x, visible.minX + keep - size.width, accuracy: 0.001)
    }

    func testClampAllowingOverhangLetsWindowCrossScreens() {
        // 两块屏：主屏 0~1147、竖屏 -1152~0。竖屏右缘允许的 x 上界是 -keep，
        // 而不是 clamp 的 -568-8；否则窗口拖到屏缘就被硬顶住。
        let portrait = CGRect(x: -1152, y: -224, width: 1152, height: 2048)
        let size = CGSize(width: 568, height: 70)
        let keep = DesktopLyricsLayout.onScreenMinimum

        let atEdge = DesktopLyricsLayout.clampAllowingOverhang(
            origin: CGPoint(x: 5000, y: 800), size: size, visibleFrame: portrait)
        XCTAssertEqual(atEdge.x, portrait.maxX - keep, accuracy: 0.001)
        // 与紧钳制的差别：这里允许右缘越过 0 探到主屏，而不是被夹回 -576。
        XCTAssertGreaterThan(atEdge.x + size.width, 0)

        // 探到主屏后按主屏钳制也不该把它瞬移回竖屏（起点就在允许区间内）。
        let main = CGRect(x: 0, y: 0, width: 1147, height: 745)
        let crossed = DesktopLyricsLayout.clampAllowingOverhang(
            origin: CGPoint(x: -40, y: 300), size: size, visibleFrame: main)
        XCTAssertEqual(crossed.x, -40, accuracy: 0.001)
    }

    func testClampAllowingOverhangKeepsWholeWindowWhenSmallerThanMinimum() {
        // 窗口比 onScreenMinimum 还小时，少留的那一轴等于窗口自身宽/高，
        // 即小窗口必须完整落屏，不会被允许探出到只剩一条。
        let visible = CGRect(x: -1152, y: -224, width: 1152, height: 2048)
        let size = CGSize(width: 30, height: 20)
        let origin = DesktopLyricsLayout.clampAllowingOverhang(
            origin: CGPoint(x: -5000, y: -5000), size: size, visibleFrame: visible)
        XCTAssertEqual(origin.x, visible.minX, accuracy: 0.001)
        XCTAssertEqual(origin.y, visible.minY, accuracy: 0.001)
    }

    func testScreenFramePicksScreenContainingCursorPoint() {
        let screens = [CGRect(x: 0, y: 0, width: 1147, height: 745),
                       CGRect(x: -1152, y: -224, width: 1152, height: 2048)]
        // 光标在竖屏内：必须选竖屏（主屏会把它钳到另一块屏）。
        let onPortrait = DesktopLyricsLayout.screenFrame(
            containing: CGPoint(x: -600, y: 900), screens: screens)
        XCTAssertEqual(onPortrait.minX, -1152)
        XCTAssertEqual(onPortrait.height, 2048)
        // 光标在主屏内：选主屏。
        let onMain = DesktopLyricsLayout.screenFrame(
            containing: CGPoint(x: 500, y: 400), screens: screens)
        XCTAssertEqual(onMain.minX, 0)
        // 哪块屏都不在：回退第一块。
        let outside = DesktopLyricsLayout.screenFrame(
            containing: CGPoint(x: 9999, y: 9999), screens: screens)
        XCTAssertEqual(outside, screens[0])
    }

    // MARK: - 默认位置

    func testDefaultOriginBottomCentered() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 300, height: 56)
        let origin = DesktopLyricsLayout.defaultOrigin(size: size, visibleFrame: visible)
        XCTAssertEqual(origin.x, (1440 - 300) / 2)
        XCTAssertEqual(origin.y, DesktopLyricsLayout.defaultBottomOffset)
        let clamped = DesktopLyricsLayout.clamp(origin: origin, size: size, visibleFrame: visible)
        XCTAssertEqual(clamped.x, origin.x)
        XCTAssertEqual(clamped.y, origin.y)
    }

    // MARK: - 位置持久化编解码

    func testEncodeDecodeRoundTrip() {
        let original = CGPoint(x: 123.4, y: 567.8)
        let decoded = DesktopLyricsLayout.decode(origin: DesktopLyricsLayout.encode(origin: original))
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.x ?? -1, 123, accuracy: 0.5)
        XCTAssertEqual(decoded?.y ?? -1, 568, accuracy: 0.5)
    }

    func testDecodeRejectsMalformedStrings() {
        XCTAssertNil(DesktopLyricsLayout.decode(origin: ""))
        XCTAssertNil(DesktopLyricsLayout.decode(origin: "abc"))
        XCTAssertNil(DesktopLyricsLayout.decode(origin: "100"))
        XCTAssertNil(DesktopLyricsLayout.decode(origin: "100,200,300"))
        XCTAssertNil(DesktopLyricsLayout.decode(origin: "x,y"))
    }

    func testDecodeHandlesSpaces() {
        let decoded = DesktopLyricsLayout.decode(origin: " 120 , 240 ")
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.x ?? -1, 120)
        XCTAssertEqual(decoded?.y ?? -1, 240)
    }

    // MARK: - 持久化防抖

    func testShouldPersistIgnoresSubPixelJitter() {
        let base = CGPoint(x: 100, y: 100)
        XCTAssertFalse(DesktopLyricsLayout.shouldPersist(from: base, to: CGPoint(x: 100.5, y: 100.2)))
        XCTAssertTrue(DesktopLyricsLayout.shouldPersist(from: base, to: CGPoint(x: 140, y: 100)))
        XCTAssertTrue(DesktopLyricsLayout.shouldPersist(from: base, to: CGPoint(x: 100, y: 90)))
    }

    // MARK: - 浮窗空态文案

    func testPlaceholderPrefersLyricsNote() {
        XCTAssertEqual(DesktopLyricsLayout.placeholder(state: "playing",
                                                       title: "刀马旦",
                                                       note: "纯音乐 · 无歌词"),
                       "纯音乐 · 无歌词")
    }

    func testPlaceholderWaitsForTrackInfoWhenTitleBlank() {
        for state in ["playing", "paused", "stopped"] {
            XCTAssertEqual(DesktopLyricsLayout.placeholder(state: state, title: "", note: ""),
                           "♪ 等待歌曲信息")
        }
        // 纯空白歌名同样视为「还没有歌曲信息」
        XCTAssertEqual(DesktopLyricsLayout.placeholder(state: "playing", title: "   ", note: ""),
                       "♪ 等待歌曲信息")
    }

    func testPlaceholderReflectsPlaybackState() {
        let title = "刀马旦"
        XCTAssertEqual(DesktopLyricsLayout.placeholder(state: "stopped", title: title, note: ""),
                       "♪ 未在播放")
        XCTAssertEqual(DesktopLyricsLayout.placeholder(state: "paused", title: title, note: ""),
                       "♪ 已暂停")
        XCTAssertEqual(DesktopLyricsLayout.placeholder(state: "playing", title: title, note: ""),
                       "♪ 正在获取歌词…")
    }

    func testPlaceholderNeverEmpty() {
        // 空态文案必须始终有内容，否则浮窗会变成一条看不见的透明条
        for state in ["playing", "paused", "stopped", ""] {
            for title in ["", "歌名"] {
                for note in ["", "纯音乐 · 无歌词"] {
                    XCTAssertFalse(DesktopLyricsLayout.placeholder(state: state,
                                                                   title: title,
                                                                   note: note).isEmpty)
                }
            }
        }
    }

    func testPlaceholderStaysWithinMaxWidth() {
        // 空态文案也不能超过 maxWidth，否则钳制逻辑可能把窗口推出屏幕
        for state in ["playing", "paused", "stopped"] {
            let text = DesktopLyricsLayout.placeholder(state: state, title: "刀马旦", note: "")
            let width = DesktopLyricsLayout.textWidth(text,
                                                      fontSize: DesktopLyricsLayout.originalFontSize)
                + DesktopLyricsLayout.horizontalPadding
            XCTAssertLessThanOrEqual(width, DesktopLyricsLayout.maxWidth)
        }
    }

    // MARK: - 字号档位（小 / 中 / 大）

    func testStoredFallsBackToMediumForNilOrDirtyValue() {
        XCTAssertEqual(DesktopLyricsSizePreset.stored(nil), .medium)
        XCTAssertEqual(DesktopLyricsSizePreset.stored(""), .medium)
        XCTAssertEqual(DesktopLyricsSizePreset.stored("huge"), .medium)
        XCTAssertEqual(DesktopLyricsSizePreset.stored("medium"), .medium)
        XCTAssertEqual(DesktopLyricsSizePreset.stored("small"), .small)
        XCTAssertEqual(DesktopLyricsSizePreset.stored("large"), .large)
    }

    func testSizePresetScalesAreOrderedWithMediumAsBaseline() {
        let scales = DesktopLyricsSizePreset.allCases.map(\.scale)
        XCTAssertEqual(scales.count, 3)
        // 中档恒为 1：老用户升级后默认观感与升级前完全一致
        XCTAssertEqual(DesktopLyricsSizePreset.medium.scale, 1.0, accuracy: 0.001)
        XCTAssertLessThan(DesktopLyricsSizePreset.small.scale, DesktopLyricsSizePreset.medium.scale)
        XCTAssertLessThan(DesktopLyricsSizePreset.medium.scale, DesktopLyricsSizePreset.large.scale)
    }

    func testSizePresetLabelsAreDistinct() {
        let labels = DesktopLyricsSizePreset.allCases.map(\.label)
        XCTAssertEqual(labels, ["小", "中", "大"])
        XCTAssertEqual(Set(labels).count, labels.count)
    }

    func testSizePresetCyclesThroughAllCases() {
        for preset in DesktopLyricsSizePreset.allCases {
            // next / previous 互为逆操作，滚轮上下拨动能原路返回
            XCTAssertEqual(preset.next.previous, preset)
            XCTAssertEqual(preset.previous.next, preset)
            // 连续拨三格回到自身：滚轮不会漏档或卡死
            XCTAssertEqual(preset.next.next.next, preset)
            XCTAssertTrue(DesktopLyricsSizePreset.allCases.contains(preset.next))
        }
        XCTAssertEqual(DesktopLyricsSizePreset.small.next, .medium)
        XCTAssertEqual(DesktopLyricsSizePreset.medium.next, .large)
        XCTAssertEqual(DesktopLyricsSizePreset.large.next, .small)
    }

    func testScaledFontSizesFollowPresetScale() {
        for preset in DesktopLyricsSizePreset.allCases {
            XCTAssertEqual(DesktopLyricsLayout.scaledOriginalFontSize(preset),
                           DesktopLyricsLayout.originalFontSize * preset.scale,
                           accuracy: 0.001)
            XCTAssertEqual(DesktopLyricsLayout.scaledTranslationFontSize(preset),
                           DesktopLyricsLayout.translationFontSize * preset.scale,
                           accuracy: 0.001)
        }
        XCTAssertEqual(DesktopLyricsLayout.scaledOriginalFontSize(.medium),
                       DesktopLyricsLayout.originalFontSize)
        XCTAssertEqual(DesktopLyricsLayout.scaledTranslationFontSize(.medium),
                       DesktopLyricsLayout.translationFontSize)
    }

    func testContentSizeHeightScalesWithPreset() {
        var previous: CGSize?
        for preset in DesktopLyricsSizePreset.allCases {
            let size = DesktopLyricsLayout.contentSize(
                line: "测试歌词",
                translation: "",
                showTranslation: false,
                originalFontSize: DesktopLyricsLayout.scaledOriginalFontSize(preset),
                translationFontSize: DesktopLyricsLayout.scaledTranslationFontSize(preset),
                sizeScale: preset.scale)
            XCTAssertEqual(size.height,
                           DesktopLyricsLayout.originalHeight * preset.scale
                               + DesktopLyricsLayout.verticalPadding,
                           accuracy: 0.001)
            if let previous { XCTAssertGreaterThan(size.height, previous.height) }
            previous = size
        }
    }

    func testBilingualExtraRowScalesWithPreset() {
        // 译文行行高同样按档位倍率放大，否则大档会出现两行文字挤在一起
        for preset in DesktopLyricsSizePreset.allCases {
            let bilingual = DesktopLyricsLayout.contentSize(
                line: "你好",
                translation: "Hello",
                showTranslation: true,
                originalFontSize: DesktopLyricsLayout.scaledOriginalFontSize(preset),
                translationFontSize: DesktopLyricsLayout.scaledTranslationFontSize(preset),
                sizeScale: preset.scale)
            let single = DesktopLyricsLayout.contentSize(
                line: "你好",
                translation: "",
                showTranslation: false,
                originalFontSize: DesktopLyricsLayout.scaledOriginalFontSize(preset),
                translationFontSize: DesktopLyricsLayout.scaledTranslationFontSize(preset),
                sizeScale: preset.scale)
            // 英文译文行被抬到中文原文的同字号（20·scale），行高按 (20/13) 同比放大
            XCTAssertEqual(bilingual.height - single.height,
                           DesktopLyricsLayout.translationHeight * preset.scale * (20.0 / 13.0),
                           accuracy: 0.001)
        }
    }

    func testContentSizeWidthGrowsWithScaleButStaysClamped() {
        // 档位放大必须放得更宽（避免歌词被挤断），但始终受 min/maxWidth 夹制
        let line = String(repeating: "歌词", count: 12)
        var previousWidth: CGFloat = 0
        for preset in DesktopLyricsSizePreset.allCases {
            let size = DesktopLyricsLayout.contentSize(
                line: line,
                translation: "",
                showTranslation: false,
                originalFontSize: DesktopLyricsLayout.scaledOriginalFontSize(preset),
                sizeScale: preset.scale)
            XCTAssertGreaterThanOrEqual(size.width, previousWidth - 0.001)
            XCTAssertGreaterThanOrEqual(size.width, DesktopLyricsLayout.minWidth)
            XCTAssertLessThanOrEqual(size.width, DesktopLyricsLayout.maxWidth)
            previousWidth = size.width
        }
    }

    func testContentSizeScaleOneMatchesLegacyBehavior() {
        // sizeScale=1 + 基准字号：必须与只传三个参数的旧调用完全同尺寸（回归护栏）
        let line = "同一行歌词"
        let legacy = DesktopLyricsLayout.contentSize(line: line,
                                                    translation: "译文",
                                                    showTranslation: true)
        let explicitOne = DesktopLyricsLayout.contentSize(
            line: line,
            translation: "译文",
            showTranslation: true,
            originalFontSize: DesktopLyricsLayout.originalFontSize,
            translationFontSize: DesktopLyricsLayout.translationFontSize,
            sizeScale: 1.0)
        XCTAssertEqual(legacy.width, explicitOne.width, accuracy: 0.001)
        XCTAssertEqual(legacy.height, explicitOne.height, accuracy: 0.001)
    }

    // MARK: - 用户自定行间距（与胶囊同一设置源）

    func testLineSpacingOnlyAffectsBilingualRow() {
        // 单行没有第二行，间距无从体现：调了也必须保持原高（否则空窗口白白高一截）
        let singleDefault = DesktopLyricsLayout.contentSize(line: "测试歌词",
                                                            translation: "",
                                                            showTranslation: false)
        let singleSpaced = DesktopLyricsLayout.contentSize(line: "测试歌词",
                                                           translation: "",
                                                           showTranslation: false,
                                                           lineSpacing: 12)
        XCTAssertEqual(singleSpaced.height, singleDefault.height, accuracy: 0.001)

        // 双语时按传入值精确加高一次：译文行不再被窗口底边裁掉
        let bilingualDefault = DesktopLyricsLayout.contentSize(line: "你好",
                                                               translation: "Hello",
                                                               showTranslation: true)
        let bilingualSpaced = DesktopLyricsLayout.contentSize(line: "你好",
                                                              translation: "Hello",
                                                              showTranslation: true,
                                                              lineSpacing: 12)
        XCTAssertEqual(bilingualSpaced.height - bilingualDefault.height, 12, accuracy: 0.001)
    }

    func testLineSpacingZeroMatchesLegacyCall() {
        // 默认 0 必须与不传该参数的旧调用逐字节同尺寸（回归护栏：
        // 没调过滑杆的老用户，浮窗既不变高也不变宽）
        let line = "同一行歌词"
        let legacy = DesktopLyricsLayout.contentSize(line: line,
                                                    translation: "译文",
                                                    showTranslation: true)
        let explicitZero = DesktopLyricsLayout.contentSize(line: line,
                                                           translation: "译文",
                                                           showTranslation: true,
                                                           lineSpacing: 0)
        XCTAssertEqual(explicitZero.width, legacy.width, accuracy: 0.001)
        XCTAssertEqual(explicitZero.height, legacy.height, accuracy: 0.001)
    }

    func testLineSpacingDoesNotChangeWidth() {
        // 间距只该变高度：宽度若跟着变，行距一调窗口就左右抽动
        let base = DesktopLyricsLayout.contentSize(line: "你好",
                                                   translation: "Hello",
                                                   showTranslation: true)
        let spaced = DesktopLyricsLayout.contentSize(line: "你好",
                                                     translation: "Hello",
                                                     showTranslation: true,
                                                     lineSpacing: 20)
        XCTAssertEqual(spaced.width, base.width, accuracy: 0.001)
    }

    func testLineSpacingIsNotScaledBySizePreset() {
        // 档位倍率只缩放两个字号行高，间距按原始 pt 加：与胶囊 IslandViews 的
        // VStack(spacing: AppState.shared.lyricLineSpacing) 一致，跨档观感统一，
        // 否则调 6pt 在「大」档会变成 8pt。
        let scale: CGFloat = 1.12
        let base = DesktopLyricsLayout.contentSize(line: "你好",
                                                   translation: "Hello",
                                                   showTranslation: true,
                                                   originalFontSize: DesktopLyricsLayout.originalFontSize * scale,
                                                   translationFontSize: DesktopLyricsLayout.translationFontSize * scale,
                                                   sizeScale: scale)
        let spaced = DesktopLyricsLayout.contentSize(line: "你好",
                                                     translation: "Hello",
                                                     showTranslation: true,
                                                     originalFontSize: DesktopLyricsLayout.originalFontSize * scale,
                                                     translationFontSize: DesktopLyricsLayout.translationFontSize * scale,
                                                     sizeScale: scale,
                                                     lineSpacing: 12)
        XCTAssertEqual(spaced.height - base.height, 12, accuracy: 0.001)
    }

    // MARK: - 恢复位置时选哪块屏

    func testVisibleFramePicksScreenContainingSavedPoint() {
        // 两块屏：主屏 0~1147，竖屏 -1152~0。保存点只在竖屏里，必须用竖屏钳制。
        let screens = [CGRect(x: 0, y: 0, width: 1147, height: 745),
                       CGRect(x: -1152, y: -224, width: 1152, height: 2048)]
        let saved = CGPoint(x: -795, y: 444)
        let frame = DesktopLyricsLayout.visibleFrame(forSavedPoint: saved, screens: screens)
        XCTAssertEqual(frame.minX, -1152)
        XCTAssertEqual(frame.height, 2048)
        // 点在允许范围内：原样保留，且确实落在竖屏内（主屏钳制会把它甩到 x=8）。
        let size = CGSize(width: 200, height: 48)
        let kept = DesktopLyricsLayout.clamp(origin: saved, size: size, visibleFrame: frame)
        XCTAssertEqual(kept.x, -795, accuracy: 0.001)
        XCTAssertEqual(kept.y, 444, accuracy: 0.001)
    }

    func testClampAgainstChosenScreenNotMainScreen() {
        // 回归护栏：保存点落在竖屏、但横坐标超出竖屏右边界时，必须按竖屏钳到 -208，
        // 而不是按 NSScreen.main 钳成 8（老代码就是这么把浮窗甩去另一块屏的）。
        let screens = [CGRect(x: 0, y: 0, width: 1147, height: 745),
                       CGRect(x: -1152, y: -224, width: 1152, height: 2048)]
        let frame = DesktopLyricsLayout.visibleFrame(forSavedPoint: CGPoint(x: -20, y: 100),
                                                     screens: screens)
        XCTAssertEqual(frame.minX, -1152)
        let clamped = DesktopLyricsLayout.clamp(origin: CGPoint(x: -20, y: 100),
                                                size: CGSize(width: 200, height: 48),
                                                visibleFrame: frame)
        XCTAssertEqual(clamped.x, -208, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(clamped.x, frame.minX + DesktopLyricsLayout.edgeMargin)
        XCTAssertLessThanOrEqual(clamped.x, frame.maxX - 200 - DesktopLyricsLayout.edgeMargin)
    }

    func testVisibleFrameFallsBackToFirstScreenWhenSavedPointOutsideAll() {
        let screens = [CGRect(x: 0, y: 0, width: 800, height: 600),
                       CGRect(x: -1200, y: 0, width: 1200, height: 800)]
        let frame = DesktopLyricsLayout.visibleFrame(forSavedPoint: CGPoint(x: 5000, y: 5000),
                                                    screens: screens)
        XCTAssertEqual(frame.origin, CGPoint(x: 0, y: 0))
        XCTAssertEqual(frame.width, 800)
    }

    func testVisibleFrameEmptyScreensFallsBackToDesktopDefault() {
        let frame = DesktopLyricsLayout.visibleFrame(forSavedPoint: CGPoint(x: 10, y: 10),
                                                    screens: [])
        XCTAssertEqual(frame.width, 1920)
        XCTAssertEqual(frame.height, 1080)
    }

    func testVisibleFrameOverlappingScreensPreferFirstMatch() {
        // 保存点同时落在两块相交屏里时按数组顺序取第一块，保证结果稳定可预期。
        let screens = [CGRect(x: 0, y: 0, width: 1147, height: 745),
                       CGRect(x: -300, y: 0, width: 1600, height: 800)]
        let frame = DesktopLyricsLayout.visibleFrame(forSavedPoint: CGPoint(x: 100, y: 500),
                                                    screens: screens)
        XCTAssertEqual(frame.minX, 0)
        XCTAssertEqual(frame.width, 1147)
    }

    // MARK: - 多屏镜像

    func testShouldMirrorOnlyWhenEnabledAndMultipleScreens() {
        // 关开关一律不镜像，哪怕插了八块屏。
        XCTAssertFalse(DesktopLyricsLayout.shouldMirror(screenCount: 3, enabled: false))
        XCTAssertFalse(DesktopLyricsLayout.shouldMirror(screenCount: 8, enabled: false))
        // 开开关但只有一块屏：不能在同一块屏上叠出一个重复浮窗。
        XCTAssertFalse(DesktopLyricsLayout.shouldMirror(screenCount: 1, enabled: true))
        // 开开关且多屏才镜像。
        XCTAssertTrue(DesktopLyricsLayout.shouldMirror(screenCount: 2, enabled: true))
        XCTAssertTrue(DesktopLyricsLayout.shouldMirror(screenCount: 3, enabled: true))
    }

    func testMirrorScreenIndicesExcludesPrimaryScreen() {
        // 副屏下标 = 除主浮窗所在屏以外的所有屏。
        XCTAssertEqual(DesktopLyricsLayout.mirrorScreenIndices(screenCount: 2, primaryIndex: 0), [1])
        XCTAssertEqual(DesktopLyricsLayout.mirrorScreenIndices(screenCount: 2, primaryIndex: 1), [0])
        XCTAssertEqual(DesktopLyricsLayout.mirrorScreenIndices(screenCount: 3, primaryIndex: 1), [0, 2])
        // 单屏时没有副屏可镜像。
        XCTAssertEqual(DesktopLyricsLayout.mirrorScreenIndices(screenCount: 1, primaryIndex: 0), [])
        // 主浮窗所在屏自身永远不出现在结果里，否则自己会被镜像一份。
        XCTAssertFalse(DesktopLyricsLayout.mirrorScreenIndices(screenCount: 3, primaryIndex: 2)
            .contains(2))
    }

    func testMirrorScreenIndicesBoundsSafeForOutOfRangePrimary() {
        // 屏幕刚被拔掉时 primaryIndex 可能越界（调用方拿不到下标只能兜底），
        // 此时仍要返回合法下标，不能让调用方去 screens[越界] 取屏崩溃。
        let indices = DesktopLyricsLayout.mirrorScreenIndices(screenCount: 2, primaryIndex: 7)
        XCTAssertEqual(indices.sorted(), [0, 1])
        XCTAssertTrue(indices.allSatisfy { $0 >= 0 && $0 < 2 })
    }

    func testMirrorOriginMatchesDefaultOriginForEveryScreen() {
        // 每块副屏各自「可见区底部居中」，与主浮窗默认位同一套算法 ——
        // 几块屏的歌词不能全叠到同一个坐标上。
        // 两块屏原点与尺寸都不同（横屏 + 竖屏），落点必须各自算各自的。
        let screens = [CGRect(x: 0, y: 0, width: 3024, height: 1964),
                       CGRect(x: -1152, y: 37, width: 1152, height: 2048)]
        let size = CGSize(width: 360, height: 60)
        for frame in screens {
            XCTAssertEqual(DesktopLyricsLayout.mirrorOrigin(size: size, visibleFrame: frame),
                           DesktopLyricsLayout.defaultOrigin(size: size, visibleFrame: frame))
        }
        // 换一块屏落点必须不同（否则「各自归位」这条规则失效）。
        let onMain = DesktopLyricsLayout.mirrorOrigin(size: size, visibleFrame: screens[0])
        let onSide = DesktopLyricsLayout.mirrorOrigin(size: size, visibleFrame: screens[1])
        XCTAssertNotEqual(onMain.x, onSide.x)
        XCTAssertNotEqual(onMain.y, onSide.y)
    }

    func testMirrorOriginStaysInsideVisibleFrame() {
        // 竖屏（1152×2048）与横屏底部居中都不能把窗口甩出可见区。
        let frames = [CGRect(x: 3024, y: 0, width: 1152, height: 2048),
                      CGRect(x: 0, y: 0, width: 1512, height: 982)]
        for frame in frames {
            let size = CGSize(width: 400, height: 90)
            let origin = DesktopLyricsLayout.mirrorOrigin(size: size, visibleFrame: frame)
            XCTAssertGreaterThanOrEqual(origin.x, frame.minX)
            XCTAssertLessThanOrEqual(origin.x + size.width, frame.maxX + 0.001)
            XCTAssertGreaterThanOrEqual(origin.y, frame.minY)
        }
    }

    func testScreenIndexReturnsIndexOfContainingScreen() {
        let screens = [CGRect(x: 0, y: 0, width: 1000, height: 800),
                       CGRect(x: 1000, y: 0, width: 1000, height: 800)]
        // 主浮窗停在哪块屏，那块屏就不镜像 —— 命中必须返回正确下标。
        XCTAssertEqual(DesktopLyricsLayout.screenIndex(
            containing: CGPoint(x: 1500, y: 400), screens: screens), 1)
        XCTAssertEqual(DesktopLyricsLayout.screenIndex(
            containing: CGPoint(x: 500, y: 100), screens: screens), 0)
    }

    func testScreenIndexReturnsNilWhenPointOutsideAllScreens() {
        let screens = [CGRect(x: 0, y: 0, width: 1000, height: 800)]
        // 没有任何屏包含该点时返回 nil（调用方据此兜底，而不是猜一块屏）。
        XCTAssertNil(DesktopLyricsLayout.screenIndex(
            containing: CGPoint(x: 5000, y: 5000), screens: screens))
        XCTAssertNil(DesktopLyricsLayout.screenIndex(
            containing: CGPoint(x: -500, y: 100), screens: screens))
    }

    func testScreenIndexAgreesWithScreenFrameOnHit() {
        // 同一套匹配规则：命中的下标其矩形必须真的包含该点，
        // 否则「主浮窗所在屏」与「保存点所在屏」会判成两块屏。
        let screens = [CGRect(x: 0, y: 0, width: 1000, height: 800),
                       CGRect(x: 1000, y: 0, width: 1000, height: 800)]
        let point = CGPoint(x: 1800, y: 700)
        let index = DesktopLyricsLayout.screenIndex(containing: point, screens: screens)
        XCTAssertNotNil(index)
        XCTAssertEqual(DesktopLyricsLayout.screenFrame(containing: point, screens: screens),
                       screens[index!])
    }

    // MARK: - CJK/拉丁检测与 latinScale

    func testHasCJKDetectsChinese() {
        XCTAssertTrue(DesktopLyricsLayout.hasCJK("你好世界"))
        XCTAssertTrue(DesktopLyricsLayout.hasCJK("测试"))
        XCTAssertFalse(DesktopLyricsLayout.hasCJK("Hello World"))
        XCTAssertFalse(DesktopLyricsLayout.hasCJK("12345"))
    }

    func testHasCJKDetectsJapaneseKana() {
        XCTAssertTrue(DesktopLyricsLayout.hasCJK("こんにちは"))
        XCTAssertTrue(DesktopLyricsLayout.hasCJK("サクラ"))
    }

    func testHasCJKDetectsKorean() {
        XCTAssertTrue(DesktopLyricsLayout.hasCJK("안녕하세요"))
    }

    func testHasLatinDetectsEnglish() {
        XCTAssertTrue(DesktopLyricsLayout.hasLatin("Hello World"))
        XCTAssertTrue(DesktopLyricsLayout.hasLatin("Yesterday Once More"))
        XCTAssertTrue(DesktopLyricsLayout.hasLatin("We Don't Talk Anymore"))
    }

    func testHasLatinDetectsAccentedCharacters() {
        XCTAssertTrue(DesktopLyricsLayout.hasLatin("À Paris"))
        XCTAssertTrue(DesktopLyricsLayout.hasLatin("Élégie"))
        XCTAssertTrue(DesktopLyricsLayout.hasLatin("Café"))
    }

    func testIsPureLatin() {
        XCTAssertTrue(DesktopLyricsLayout.isPureLatin("Hello World"))
        XCTAssertTrue(DesktopLyricsLayout.isPureLatin("Yesterday Once More"))
        XCTAssertTrue(DesktopLyricsLayout.isPureLatin("We Don't Talk Anymore"))
        XCTAssertTrue(DesktopLyricsLayout.isPureLatin("À Paris"))
        XCTAssertFalse(DesktopLyricsLayout.isPureLatin("你好世界"))
        XCTAssertFalse(DesktopLyricsLayout.isPureLatin("Hello 世界"))
        XCTAssertFalse(DesktopLyricsLayout.isPureLatin("后来 (Live)"))
        XCTAssertFalse(DesktopLyricsLayout.isPureLatin("さくら (Sakura)"))
        XCTAssertFalse(DesktopLyricsLayout.isPureLatin("♪ ~ ♫"))
        XCTAssertFalse(DesktopLyricsLayout.isPureLatin(""))
        XCTAssertFalse(DesktopLyricsLayout.isPureLatin("12345"))
    }

    func testScaledOriginalFontSizeAppliesLatinScale() {
        let latinLine = "Yesterday once more"
        let cjkLine = "测试歌词"
        let preset = DesktopLyricsSizePreset.medium // scale = 1.0

        let latinSize = DesktopLyricsLayout.scaledOriginalFontSize(preset, line: latinLine)
        let cjkSize = DesktopLyricsLayout.scaledOriginalFontSize(preset, line: cjkLine)

        XCTAssertEqual(latinSize, 20.0 * DesktopLyricsLayout.latinScale, accuracy: 0.001)
        XCTAssertEqual(cjkSize, 20.0, accuracy: 0.001)
        XCTAssertEqual(latinSize / cjkSize, DesktopLyricsLayout.latinScale, accuracy: 0.001)
    }

    func testScaledOriginalFontSizeRespectsPresetScale() {
        let latinLine = "Hello World"
        let smallSize = DesktopLyricsLayout.scaledOriginalFontSize(.small, line: latinLine)
        let mediumSize = DesktopLyricsLayout.scaledOriginalFontSize(.medium, line: latinLine)
        let largeSize = DesktopLyricsLayout.scaledOriginalFontSize(.large, line: latinLine)

        XCTAssertEqual(smallSize, 20.0 * 0.72 * DesktopLyricsLayout.latinScale, accuracy: 0.001)
        XCTAssertEqual(mediumSize, 20.0 * 1.0 * DesktopLyricsLayout.latinScale, accuracy: 0.001)
        XCTAssertEqual(largeSize, 20.0 * 1.4 * DesktopLyricsLayout.latinScale, accuracy: 0.001)
    }

    func testContentSizeUsesLatinScaleForWidth() {
        let latinLine = "Yesterday once more"
        let cjkLine = "测试歌词"

        let latinSize = DesktopLyricsLayout.contentSize(
            line: latinLine,
            translation: "",
            showTranslation: false,
            originalFontSize: DesktopLyricsLayout.scaledOriginalFontSize(.medium, line: latinLine),
            sizeScale: 1.0
        )
        let cjkSize = DesktopLyricsLayout.contentSize(
            line: cjkLine,
            translation: "",
            showTranslation: false,
            originalFontSize: DesktopLyricsLayout.scaledOriginalFontSize(.medium, line: cjkLine),
            sizeScale: 1.0
        )

        // 拉丁文行应该更宽（因为字号放大了 1.15x）
        XCTAssertGreaterThan(latinSize.width, cjkSize.width)
    }
}

// MARK: - 紧凑间距与英文字号

/// 用户反馈两点：桌面歌词「空隙太大」，以及「英文要比中文大一点」。
final class DesktopLyricsDensityTests: XCTestCase {
    func testVerticalPaddingIsCompact() {
        // 上下合计 8pt：旧值 14 会让浮窗明显比文字高一截
        XCTAssertEqual(DesktopLyricsLayout.verticalPadding, 8, accuracy: 0.001)
    }

    func testRowHeightsAreCompact() {
        XCTAssertEqual(DesktopLyricsLayout.originalHeight, 26, accuracy: 0.001)
        XCTAssertEqual(DesktopLyricsLayout.translationHeight, 18, accuracy: 0.001)
    }

    func testContentHeightShrinksForSameContent() {
        // 同样内容，收紧后的窗口必须更矮
        let size = DesktopLyricsLayout.contentSize(line: "你好世界",
                                                   translation: "Hello world",
                                                   showTranslation: true,
                                                   sizeScale: 1.0)
        // 26 + 8 + 18 * (20/13) ≈ 61.7：英文译文被抬到中文同字号后行高同比放大，
        // 否则第二行会被窗口底边裁掉（用户反馈「歌词出错」）。
        XCTAssertEqual(size.height, 62, accuracy: 0.6)
    }

    func testSingleLineHeightIsCompact() {
        let size = DesktopLyricsLayout.contentSize(line: "你好",
                                                   translation: "",
                                                   showTranslation: false,
                                                   sizeScale: 1.0)
        // 26 + 8 = 34
        XCTAssertEqual(size.height, 34, accuracy: 0.001)
    }

    func testLatinOriginalIsLargerThanCJK() {
        let en = DesktopLyricsLayout.scaledOriginalFontSize(.medium, line: "Hello world")
        let zh = DesktopLyricsLayout.scaledOriginalFontSize(.medium, line: "你好世界")
        XCTAssertGreaterThan(en, zh)
    }

    func testLatinTranslationAlsoGetsScale() {
        // 译文为英文时同样放大，避免「中英行」一大一小失衡
        let enTr = DesktopLyricsLayout.scaledTranslationFontSize(.medium, line: "Hello world")
        let zhTr = DesktopLyricsLayout.scaledTranslationFontSize(.medium, line: "你好世界")
        XCTAssertGreaterThan(enTr, zhTr)
    }

    func testTranslationScaleMatchesOriginalRatio() {
        // 原文与译文用同一个倍率，视觉才协调
        let ratioOriginal = DesktopLyricsLayout.scaledOriginalFontSize(.medium, line: "Hello")
            / DesktopLyricsLayout.scaledOriginalFontSize(.medium, line: "你好")
        let ratioTranslation = DesktopLyricsLayout.scaledTranslationFontSize(.medium, line: "Hello")
            / DesktopLyricsLayout.scaledTranslationFontSize(.medium, line: "你好")
        XCTAssertEqual(ratioOriginal, ratioTranslation, accuracy: 0.0001)
    }

    func testLatinWindowWiderToAvoidClipping() {
        // 放大字号后窗口必须同步变宽，否则英文会被裁。
        // 用足够长的文本：短文本会被 minWidth 夹住，测不出宽度差异。
        let long = "Every single word of this line is written in plain latin"
        let latin = DesktopLyricsLayout.contentSize(line: long,
                                                    translation: "",
                                                    showTranslation: false,
                                                    originalFontSize: 20,
                                                    translationFontSize: 13,
                                                    sizeScale: 1.0)
        let plain = DesktopLyricsLayout.contentSize(line: long,
                                                    translation: "",
                                                    showTranslation: false,
                                                    originalFontSize: 20 / DesktopLyricsLayout.latinScale,
                                                    translationFontSize: 13,
                                                    sizeScale: 1.0)
        XCTAssertGreaterThan(latin.width, plain.width)
    }

    func testMixedLineIsNotTreatedAsPureLatin() {
        // 中英混合不算纯拉丁，不放大（否则那一行会突然变大挑出战局）
        XCTAssertFalse(DesktopLyricsLayout.isPureLatin("Hello 世界"))
        XCTAssertTrue(DesktopLyricsLayout.isPureLatin("Hello world"))
    }
}
