// swift-tools-version:6.2

import PackageDescription

let package = Package(
    name: "AVPlus",
    // iOS 26 is required for on-device subtitle generation (SpeechAnalyzer / SpeechTranscriber).
    platforms: [.iOS(.v26), .macOS(.v26), .tvOS(.v26), .visionOS(.v26)],
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
