// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MirrorKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MirrorKit", targets: ["MirrorKit"]),
        .library(name: "MirrorKitUI", targets: ["MirrorKitUI"]),
    ],
    targets: [
        .target(name: "MirrorKit"),
        // The Platinum asset pack is a runtime dependency selected by
        // AssetPack. Apple-owned bytes never become package resources.
        .target(name: "MirrorKitUI", dependencies: ["MirrorKit"]),
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
