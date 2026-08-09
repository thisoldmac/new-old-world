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
        .library(name: "MirrorOracleKit", targets: ["MirrorOracleKit"]),
        .executable(name: "MirrorApp", targets: ["MirrorApp"]),
    ],
    targets: [
        .target(name: "MirrorKit"),
        // NO resources. The Platinum asset pack is Apple's bitmaps and is
        // a runtime DEPENDENCY, not repository content — `Resources/` is
        // gitignored, resolved at run time by `AssetPack`, and rebuilt by
        // `tools/extract-assets-offline`. Declaring `.copy("Resources/…")`
        // here would make the build fail outright on a checkout that has
        // no pack, which is precisely the state a fresh clone is in.
        .target(name: "MirrorKitUI", dependencies: ["MirrorKit"]),
        .target(name: "MirrorOracleKit",
                dependencies: ["MirrorKit", "MirrorKitUI"]),
        .executableTarget(name: "MirrorApp",
                          dependencies: ["MirrorKit", "MirrorKitUI",
                                         "MirrorOracleKit"]),
        .testTarget(
            name: "MirrorKitTests",
            dependencies: ["MirrorKit", "MirrorOracleKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "MirrorKitUITests",
            dependencies: ["MirrorKit", "MirrorKitUI"]
        ),
    ]
)
