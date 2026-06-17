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
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0")
    ],
    targets: [
        .executableTarget(
            name: "Tintpad",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")
            ]
        )
    ]
)
