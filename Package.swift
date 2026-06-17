// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tintpad",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Tintpad", targets: ["Tintpad"])
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "Tintpad",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "TintpadTests",
            dependencies: ["Tintpad"]
        )
    ]
)
