// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "VirtualList",
    platforms: [
        .iOS(.v17),
        .macCatalyst(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "VirtualList",
            targets: ["VirtualList"]
        ),
    ],
    targets: [
        .target(
            name: "VirtualList",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "VirtualListTests",
            dependencies: ["VirtualList"]
        ),
    ]
)
