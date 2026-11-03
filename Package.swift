// swift-tools-version:6.0

import PackageDescription

let package = Package(
    name: "AVPlus",
    platforms: [.iOS(.v17), .macOS(.v14), .tvOS(.v17), .visionOS(.v1)],
    products: [
        .library(name: "AVPlus", targets: ["AVPlus"]),
    ],
    dependencies: [
        // LGPL build of libmpv + FFmpeg. Swap for the "MPVKit-GPL" product if you need GPL-only features (e.g. SMB).
        .package(url: "https://github.com/mpvkit/MPVKit.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "AVPlus",
            dependencies: [
                .product(name: "MPVKit", package: "MPVKit"),
            ]
        ),
        .testTarget(
            name: "AVPlusTests",
            dependencies: ["AVPlus"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
