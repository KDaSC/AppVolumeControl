// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppVolumeControl",
    // The local SwiftPM/Clang toolchain cannot form a macosx18.0 target.
    // The shipped app still enforces macOS 18.0 in Info.plist and at runtime.
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AppVolumeControlCore", targets: ["AppVolumeControlCore"]),
        .executable(name: "AppVolumeControl", targets: ["AppVolumeControl"])
    ],
    targets: [
        .target(
            name: "AppVolumeControlCore",
            dependencies: ["AppVolumeControlRealtime"],
            path: "Sources/AppVolumeControlCore"
        ),
        .target(
            name: "AppVolumeControlRealtime",
            path: "Sources/AppVolumeControlRealtime",
            publicHeadersPath: "."
        ),
        .executableTarget(
            name: "AppVolumeControl",
            dependencies: ["AppVolumeControlCore"],
            path: "Sources/AppVolumeControl"
        ),
        .executableTarget(
            name: "AppVolumeControlTests",
            dependencies: ["AppVolumeControlCore"],
            path: "Tests/AppVolumeControlTests"
        )
    ]
)
