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
            linkerSettings: [
                .linkedFramework("MediaPlayer"),
                .linkedFramework("EventKit"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("IOKit"),
                .linkedFramework("CryptoKit"),
                .linkedFramework("MusicKit"),
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
        // 单元测试目标：仅依赖 Foundation/CryptoKit，不引入 AppKit/SwiftUI/GUI 框架，
        // 以保证 `swift test` 在 CI/命令行下无需登录会话即可编译运行。
        .testTarget(
            name: "LumiTests",
            dependencies: [
                .target(name: "Lumi")
            ],
            path: "Tests/LumiTests"
        )
    ]
)
