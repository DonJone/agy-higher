// swift-tools-version: 5.10
import Foundation
import PackageDescription

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let repoRoot = packageDir.deletingLastPathComponent()
let rustReleaseLibDir = repoRoot.appendingPathComponent("rust-core/target/release").path

let rustLinkerSettings: [LinkerSetting] = [
    .unsafeFlags([
        "-L\(rustReleaseLibDir)",
        "-lagy_higher_core",
        "-lsqlite3"
    ])
]

let package = Package(
    name: "AgyHigher",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AgyHigher", targets: ["AgyHigherApp"]),
        .executable(name: "AgyHigherBridgeVerify", targets: ["AgyHigherBridgeVerify"])
    ],
    targets: [
        .target(
            name: "CAgyHigherCore",
            path: "Sources/CAgyHigherCore",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "AgyHigherApp",
            dependencies: ["CAgyHigherCore"],
            path: "Sources/AgyHigherApp",
            linkerSettings: rustLinkerSettings
        ),
        .executableTarget(
            name: "AgyHigherBridgeVerify",
            dependencies: ["CAgyHigherCore"],
            path: "Sources/AgyHigherBridgeVerify",
            linkerSettings: rustLinkerSettings
        )
    ]
)
