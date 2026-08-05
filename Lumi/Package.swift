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
            ]
        )
    ]
)
