// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "Prism",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "Prism",
            dependencies: ["Sparkle"],
            path: "Prism",
            exclude: [],
            resources: [
                .process("Resources/Assets.xcassets"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PrismTests",
            dependencies: ["Prism"],
            path: "PrismTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
