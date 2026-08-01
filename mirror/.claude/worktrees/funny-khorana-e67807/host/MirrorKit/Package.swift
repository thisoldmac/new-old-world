// swift-tools-version:5.9
// MirrorKit — the renderer-free semantic core for perceiving and manipulating
// a guest OS 9 UI (MIRRORKIT-PLAN.md). MirrorKitUI / MirrorApp arrive in later
// slices; this package starts core-only so every line is agent-verifiable.
import PackageDescription

let package = Package(
    name: "MirrorKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MirrorKit", targets: ["MirrorKit"]),
        .library(name: "MirrorKitUI", targets: ["MirrorKitUI"]),
        .executable(name: "MirrorApp", targets: ["MirrorApp"]),
    ],
    targets: [
        .target(name: "MirrorKit"),
        .target(name: "MirrorKitUI", dependencies: ["MirrorKit"],
                resources: [.copy("Resources/fonts"),
                            .copy("Resources/patterns"),
                            .copy("Resources/icons"),
                            .copy("Resources/appicons")]),
        .executableTarget(name: "MirrorApp",
                          dependencies: ["MirrorKit", "MirrorKitUI"]),
        .testTarget(
            name: "MirrorKitTests",
            dependencies: ["MirrorKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "MirrorKitUITests",
            dependencies: ["MirrorKit", "MirrorKitUI"]
        ),
    ]
)
