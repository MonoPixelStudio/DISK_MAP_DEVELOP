// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiskMap",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DiskMap", targets: ["DiskMap"]),
        .executable(name: "DiskMapChecks", targets: ["DiskMapChecks"]),
        .library(name: "DiskMapCore", targets: ["DiskMapCore"]),
    ],
    targets: [
        .target(name: "DiskMapCore"),
        .executableTarget(name: "DiskMap", dependencies: ["DiskMapCore"]),
        // This Mac's Command Line Tools do not include Swift Testing.
        .executableTarget(name: "DiskMapChecks", dependencies: ["DiskMapCore"], path: "Tests/DiskMapCoreTests"),
    ]
)
