// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "OpenCode-Go-Quotas",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "OpenCode-Go-Quotas",
            path: "Sources/OpenCodeGo-Quotas"
        ),
        .testTarget(
            name: "OpenCode-Go-QuotasTests",
            dependencies: ["OpenCode-Go-Quotas"],
            path: "Tests/OpenCodeGo-QuotasTests"
        ),
    ]
)
