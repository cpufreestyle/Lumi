// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LumiSamplePlugin",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "LumiSamplePlugin",
            path: "Sources/LumiSamplePlugin"
        )
    ]
)
