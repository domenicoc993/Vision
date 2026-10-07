// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Vision",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "Vision",
            targets: ["Vision"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "Vision",
            dependencies: [],
            path: "Sources/Vision"
        )
    ]
)
