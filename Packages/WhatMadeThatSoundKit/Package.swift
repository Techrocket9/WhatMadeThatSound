// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WhatMadeThatSoundKit",
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "WhatMadeThatSoundKit", targets: ["WhatMadeThatSoundKit"]),
    ],
    targets: [
        .target(name: "WhatMadeThatSoundKit"),
        .testTarget(
            name: "WhatMadeThatSoundKitTests",
            dependencies: ["WhatMadeThatSoundKit"]
        ),
    ]
)
