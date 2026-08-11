// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MirrorKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MirrorKit", targets: ["MirrorKit"]),
        .library(name: "MirrorKitUI", targets: ["MirrorKitUI"]),
        .executable(name: "mirror-render", targets: ["MirrorRenderCLI"]),
    ],
    targets: [
        .target(name: "MirrorKit"),
        // The Platinum asset pack is a runtime dependency selected by
        // AssetPack. Apple-owned bytes never become package resources.
        .target(name: "MirrorKitUI", dependencies: ["MirrorKit"]),
        .executableTarget(
            name: "MirrorRenderCLI",
            dependencies: ["MirrorKit", "MirrorKitUI"]
        ),
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
