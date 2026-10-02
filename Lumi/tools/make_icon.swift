import AppKit

// Lumi 应用图标生成（Apple 风格 / macOS 11+ Big Sur 规范）
//
// 设计约定：
//   1) 1024 全出血，不自己画圆角、不加透明边 —— 系统会套连续圆角（squircle）遮罩，
//      自己画圆角会双重遮罩、接缝处发虚；
//   2) 视觉母题与 App 本体一致：黑色胶囊「岛」（RoundedRectangle cornerRadius 18 的
//      同比例放大）+ 粉紫渐变（.pink -> .purple，App 主操作按钮同款）作主色调，
//      岛身俯视即 Lumi 的动态岛；岛内底部一条粉紫渐变进度线（胶囊底部进度条同款），
//      一条白色歌词行 + 一条青色译文行，对应浮窗/胶囊的双语歌词显示；
//   3) 左上径向高光 + 底部轻压暗，营造「有厚度的实物感」——这是 macOS 图标的关键。

let OUT_ARG = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil
let SIZE: CGFloat = 1024

// —— 配色（与 App 一致）——
let PINK  = NSColor(srgbRed: 1.000, green: 0.176, blue: 0.333, alpha: 1)   // .pink
let PURP  = NSColor(srgbRed: 0.686, green: 0.000, blue: 1.000, alpha: 1)   // .purple
let CYAN  = NSColor(srgbRed: 0.000, green: 0.800, blue: 0.800, alpha: 1)   // 译文行 .cyan
let WHITE = NSColor(srgbRed: 1.000, green: 1.000, blue: 1.000, alpha: 1)
let INK   = NSColor(srgbRed: 0.043, green: 0.043, blue: 0.051, alpha: 1)   // 岛身近黑

func roundRect(_ r: CGRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
}

/// 全出血渐变底：粉紫对角渐变 + 左上高光 + 底部轻压暗（1024 坐标系，y 向上）
func drawBackground(_ ctx: CGContext, size: CGFloat) {
    let space = CGColorSpaceCreateDeviceRGB()
    let layers = [PINK.cgColor, PURP.cgColor] as CFArray
    let grad = CGGradient(colorsSpace: space, colors: layers, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: size),
                           end: CGPoint(x: size, y: 0), options: [])
    // 左上径向高光
    let glowColors = [NSColor.white.withAlphaComponent(0.20).cgColor,
                      NSColor.white.withAlphaComponent(0.0).cgColor] as CFArray
    let glow = CGGradient(colorsSpace: space, colors: glowColors, locations: [0, 1])!
    let gc = CGPoint(x: size * 0.30, y: size * 0.78)
    ctx.drawRadialGradient(glow, startCenter: gc, startRadius: 0,
                           endCenter: gc, endRadius: size * 0.72,
                           options: .drawsBeforeStartLocation)
    // 底部压暗
    let vigColors = [NSColor.black.withAlphaComponent(0.0).cgColor,
                     NSColor.black.withAlphaComponent(0.14).cgColor] as CFArray
    let vig = CGGradient(colorsSpace: space, colors: vigColors, locations: [0, 1])!
    ctx.drawLinearGradient(vig, start: CGPoint(x: 0, y: size * 0.36),
                           end: CGPoint(x: 0, y: 0), options: [])
}

/// 主题字形：黑色胶囊岛 + 岛内双语歌词行 + 底部粉紫进度线。s 为缩放系数，1024 布局下传 1。
func drawMotif(scale s: CGFloat) {
    // 岛身：宽胶囊，垂直居中略偏上（给底部留呼吸）
    let island = CGRect(x: 132 * s, y: 322 * s, width: 760 * s, height: 380 * s)
    let radius: CGFloat = 190 * s   // 对应 App 中 cornerRadius 18 的等比放大（胶囊）

    // 柔和投影：让岛「浮」在渐变瓷面上
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.34)
    shadow.shadowBlurRadius = 42 * s
    shadow.shadowOffset = NSSize(width: 0, height: -18 * s)
    shadow.set()

    INK.setFill()
    NSBezierPath(roundedRect: island, xRadius: radius, yRadius: radius).fill()
    NSShadow().set()   // 后续元素不再重复投影

    // 岛内顶部极细高光（模拟刘海接缝的受光边）
    let hl = NSBezierPath(roundedRect: CGRect(x: island.minX + 26 * s,
                                              y: island.maxY - 26 * s,
                                              width: island.width - 52 * s,
                                              height: 3 * s),
                          xRadius: 1.5 * s, yRadius: 1.5 * s)
    NSColor.white.withAlphaComponent(0.18).setFill()
    hl.fill()

    let contentX = island.minX + 76 * s
    let contentW = island.width - 152 * s

    // 原文歌词行（白色，较长）
    let line1 = CGRect(x: contentX, y: island.minY + 178 * s,
                       width: contentW * 0.82, height: 34 * s)
    WHITE.setFill()
    NSBezierPath(roundedRect: line1, xRadius: 17 * s, yRadius: 17 * s).fill()

    // 译文歌词行（青色，较短）
    let line2 = CGRect(x: contentX, y: island.minY + 112 * s,
                       width: contentW * 0.55, height: 30 * s)
    CYAN.setFill()
    NSBezierPath(roundedRect: line2, xRadius: 15 * s, yRadius: 15 * s).fill()

    // 底部粉紫进度线：与 App 胶囊底部进度条同款渐变，两端收在岛肋内
    let bar = CGRect(x: contentX, y: island.minY + 52 * s,
                     width: contentW * 0.62, height: 16 * s)
    let barPath = NSBezierPath(roundedRect: bar, xRadius: 8 * s, yRadius: 8 * s)
    let space = CGColorSpaceCreateDeviceRGB()
    let grad = CGGradient(colorsSpace: space,
                          colors: [PINK.cgColor, PURP.cgColor] as CFArray,
                          locations: [0, 1])!
    NSGraphicsContext.saveGraphicsState()
    barPath.addClip()
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.drawLinearGradient(grad, start: CGPoint(x: bar.minX, y: bar.midY),
                           end: CGPoint(x: bar.maxX, y: bar.midY), options: [])
    NSGraphicsContext.restoreGraphicsState()

    // 进度线剩余部分：暗色占位，示意「播放中」
    let rest = CGRect(x: bar.maxX + 10 * s, y: island.minY + 52 * s,
                      width: contentW - bar.width - 10 * s, height: 16 * s)
    NSColor.white.withAlphaComponent(0.16).setFill()
    NSBezierPath(roundedRect: rest, xRadius: 8 * s, yRadius: 8 * s).fill()
}

func savePng(_ image: NSImage, _ path: String, _ px: CGFloat) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote " + path)
}

let out = OUT_ARG ?? FileManager.default.currentDirectoryPath
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

// —— 1) macOS 主图标：1024 全出血 ——
let mac = NSImage(size: NSSize(width: SIZE, height: SIZE))
mac.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
drawBackground(ctx, size: SIZE)
drawMotif(scale: 1.0)
mac.unlockFocus()
savePng(mac, out + "/AppIcon_1024.png", SIZE)
