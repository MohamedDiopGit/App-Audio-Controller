// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AppAudioController",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "AppAudioController",
            dependencies: [.product(name: "Atomics", package: "swift-atomics")],
            path: "Sources"
        )
    ]
)
