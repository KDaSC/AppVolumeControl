// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppVolumeControl",
    // SwiftPM's current macOS SDK accepts v15 as the source build baseline;
    // the shipped app enforces macOS 18.0 through LSMinimumSystemVersion.
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AppVolumeControlCore", targets: ["AppVolumeControlCore"]),
        .executable(name: "AppVolumeControl", targets: ["AppVolumeControl"])
    ],
    targets: [
        .target(
            name: "AppVolumeControlCore",
            path: "Sources/AppVolumeControlCore"
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
