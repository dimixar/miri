// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "miri",
    platforms: [
        .macOS("26.0"),
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
