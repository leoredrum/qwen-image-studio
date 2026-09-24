// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "QwenImageStudio",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "QwenImageStudio", path: "Sources", swiftSettings: [.enableUpcomingFeature("BareSlashRegexLiterals")])
    ]
)
