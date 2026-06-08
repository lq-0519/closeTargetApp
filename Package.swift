// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CloseTargetApp",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "CloseTargetApp", targets: ["CloseTargetApp"])
    ],
    targets: [
        .executableTarget(
            name: "CloseTargetApp",
            path: "Sources/CloseTargetApp"
        )
    ]
)
