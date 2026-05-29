// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DroidScout",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "DroidScout", targets: ["DroidScoutApp"])
    ],
    targets: [
        .target(
            name: "DroidScout",
            path: "Sources/DroidScout"
        ),
        .executableTarget(
            name: "DroidScoutApp",
            dependencies: ["DroidScout"],
            path: "Sources/DroidScoutApp"
        ),
        .testTarget(
            name: "DroidScoutTests",
            dependencies: [
                .target(name: "DroidScout")
            ]
        )
    ]
)
