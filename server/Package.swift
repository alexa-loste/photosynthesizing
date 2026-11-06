// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "toreplyd",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "toreplyd",
            path: "Sources/toreplyd"
        )
    ]
)
