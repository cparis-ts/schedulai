// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Schedulai",
    platforms: [
        .macOS(.v26),
    ],
    targets: [
        .executableTarget(
            name: "Schedulai",
            path: "Sources/Schedulai",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
