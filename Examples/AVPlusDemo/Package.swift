// swift-tools-version:6.0

import PackageDescription

// A minimal macOS app: `swift run AVPlusDemo [path-or-url]`.
// For iOS/tvOS, add AVPlus to an app target and reuse `PlayerScreen`.
let package = Package(
    name: "AVPlusDemo",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "AVPlusDemo",
            dependencies: [.product(name: "AVPlus", package: "AVPlus")]
        ),
    ]
)
