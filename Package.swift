// swift-tools-version: 6.0
// Builds the viewer app and the agent with SwiftPM, for scripts/build-app.sh, which
// wraps them into "What Made That Sound.app". The Xcode project builds the same sources.
import PackageDescription

let package = Package(
    name: "WhatMadeThatSound",
    platforms: [.macOS("14.2")],
    dependencies: [
        .package(path: "Packages/WhatMadeThatSoundKit"),
    ],
    targets: [
        .executableTarget(
            name: "WhatMadeThatSound",
            dependencies: [.product(name: "WhatMadeThatSoundKit", package: "WhatMadeThatSoundKit")],
            path: "WhatMadeThatSound",
            exclude: ["Assets.xcassets"]
        ),
        .executableTarget(
            name: "WhatMadeThatSoundAgent",
            dependencies: [.product(name: "WhatMadeThatSoundKit", package: "WhatMadeThatSoundKit")],
            path: "WhatMadeThatSoundAgent"
        ),
    ]
)
