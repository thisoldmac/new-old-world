// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NewOldWorld",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Host", targets: ["Host"]),
        .executable(name: "NOWAgentCompanion",
                    targets: ["NOWAgentCompanion"]),
        // The Xcode app target consumes this as a real package product, so
        // that `import NOWAgentIntegration` means the same thing to both
        // build systems. It used to compile these sources into the app
        // directly, which left the module name unresolvable there and every
        // import needing a `#if canImport` guard.
        .library(name: "NOWAgentIntegration",
                 targets: ["NOWAgentIntegration"]),
        // Ported from this project's own prototype (`timbottu/mirror`,
        // `host/MirrorKit`) — see the port note atop
        // Sources/MirrorKit/PORTING.md. Two targets, not three: upstream's
        // `MirrorApp` executable does not cross, because NOW's host app is
        // the app.
        .library(name: "MirrorKit", targets: ["MirrorKit"]),
        .library(name: "MirrorKitUI", targets: ["MirrorKitUI"]),
    ],
    targets: [
        .target(name: "NOWAgentIntegration",
                path: "Sources/NOWAgentIntegration"),
        .target(name: "MirrorKit", path: "Sources/MirrorKit",
                // The port's own note. Excluded rather than moved so it sits
                // beside the code it describes.
                exclude: ["PORTING.md"]),
        // The renderer's assets are `.copy`, not `.process`: the bitmap
        // fonts and Platinum patterns are read byte-for-byte at their own
        // pixel sizes, and asset processing would be free to re-encode them.
        .target(name: "MirrorKitUI",
                dependencies: ["MirrorKit"],
                path: "Sources/MirrorKitUI",
                resources: [.copy("Resources/fonts"),
                            .copy("Resources/patterns"),
                            .copy("Resources/icons"),
                            .copy("Resources/appicons")]),
        // MirrorKit and MirrorKitUI join the app here: the Mirror module's
        // adapter turns a `NOWSceneDocument` into `MirrorKit.Scene`, and its
        // pane draws that scene with `MirrorKitUI.SceneView`.
        .executableTarget(name: "Host",
                          dependencies: ["NOWAgentIntegration",
                                         "MirrorKit", "MirrorKitUI"],
                          path: "Sources/Host"),
        .executableTarget(name: "NOWAgentCompanion",
                          dependencies: ["NOWAgentIntegration"],
                          path: "Sources/NOWAgentCompanion"),
        .testTarget(name: "HostTests",
                    dependencies: ["Host", "NOWAgentIntegration",
                                   "MirrorKit", "MirrorKitUI"],
                    path: "Tests/HostTests",
                    // The real-scene fixture (RealSceneFixtureTests): a
                    // live 2026-08-01 capture, so the adapter+render path
                    // is checked against what the guest actually sends,
                    // not a literal this test constructs and then parses.
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "NOWAgentCompanionTests",
                    dependencies: ["NOWAgentCompanion",
                                   "NOWAgentIntegration"],
                    path: "Tests/NOWAgentCompanionTests"),
        // Upstream's coverage crosses with the code it covers. The golden
        // fixtures are the expensive half: raw guest replies beside their
        // expected scenes, recorded off a live Mac OS 9.1.
        .testTarget(name: "MirrorKitTests",
                    dependencies: ["MirrorKit"],
                    path: "Tests/MirrorKitTests",
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "MirrorKitUITests",
                    dependencies: ["MirrorKit", "MirrorKitUI"],
                    path: "Tests/MirrorKitUITests"),
    ]
)
