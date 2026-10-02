import AppKit

// Lumi 应用图标多尺寸生成：从 1024 全出血母图缩放出全倍率 PNG，
// 再由 iconutil 打包成 AppIcon.icns。
//
// 用法：swift make_iconset.swift <1024母图.png> <输出目录>

let args = CommandLine.arguments
guard args.count > 2 else {
    print("usage: make_iconset.swift <1024.png> <outdir>")
    exit(2)
}
let src = args[1]
let outArg = args[2]

guard let srcImg = NSImage(contentsOf: URL(fileURLWithPath: src)) else {
    print("cannot read " + src)
    exit(1)
}

// macOS 图标规范要求的完整尺寸集（含 2x）
let specs: [(String, CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

let iconset = (outArg as NSString).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

for (name, px) in specs {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // 高质量缩放，避免小尺寸出现锯齿/摩尔纹
    NSGraphicsContext.current?.imageInterpolation = .high
    srcImg.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    let path = (iconset as NSString).appendingPathComponent(name)
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote " + path)
}
