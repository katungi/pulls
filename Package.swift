// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "pulls",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .executableTarget(
            name: "pulls",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .testTarget(
            name: "pullsTests",
            dependencies: ["pulls"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
    ]
)
