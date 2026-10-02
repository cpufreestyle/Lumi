// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Lumi",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Lumi", targets: ["Lumi"])
    ],
    targets: [
        .executableTarget(
            name: "Lumi",
            path: "Sources/Lumi",
            resources: [
                .copy("Resources")
            ],
            linkerSettings: [
                .linkedFramework("MediaPlayer"),
                .linkedFramework("EventKit"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("IOKit"),
                .linkedFramework("CryptoKit"),
                .linkedFramework("MusicKit"),
                .linkedFramework("WebKit"),
            ]
        ),
        // 激活码签发工具：持私钥签名，独立于 App 目标，不参与 Lumi.app 打包。
        .executableTarget(
            name: "license-tool",
            path: "Sources/license-tool",
            linkerSettings: [
                .linkedFramework("CryptoKit")
            ]
        ),
        // 单元测试目标：依赖完整 Lumi target（含 AppKit/SwiftUI），因为需要覆盖
        // 从 UI 层抽出的纯逻辑类型（如 TabBarLayout 两行布局计算）。
        // 代价：`swift test` 需与 App 相同的完整 Xcode 工具链 + macOS 26.5 SDK，
        // 不再满足「CI/命令行下仅 Foundation/CryptoKit」的原始约束；
        // 测试本身仍可在无 GUI 会话下通过（实测 532 passed / 0 failed）。
        // 若将来需要纯 CI 测试，应把这些纯逻辑类型抽到独立的 non-GUI target。
        .testTarget(
            name: "LumiTests",
            dependencies: [
                .target(name: "Lumi")
            ],
            path: "Tests/LumiTests"
        )
    ]
)
