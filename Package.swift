// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "miri",
    platforms: [
        .macOS(.v13),
    ],
    targets: [
        .executableTarget(
            name: "miri",
            path: "Sources/Miri"
        ),
        .testTarget(
            name: "MiriTests",
            dependencies: ["miri"],
            path: "Tests/MiriTests"
        ),
    ]
)
