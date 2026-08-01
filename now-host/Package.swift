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
        // MirrorKit and MirrorKitUI were vendored here — a port of
        // `timbottu/mirror`'s own package, so NOW's host app could draw and
        // drive the mirror itself. It never worked, and the answer is not a
        // better port: Mirror is vendored WHOLE at `now/mirror/`, keeping its
        // own wire, its own INITs and its own agent surface. Nothing in this
        // package builds it — it is a separate SwiftPM package, and the
        // Mirror module here launches it (`MirrorLauncherModel`).
    ],
    targets: [
        .target(name: "NOWAgentIntegration",
                path: "Sources/NOWAgentIntegration"),
        .executableTarget(name: "Host",
                          dependencies: ["NOWAgentIntegration"],
                          path: "Sources/Host"),
        .executableTarget(name: "NOWAgentCompanion",
                          dependencies: ["NOWAgentIntegration"],
                          path: "Sources/NOWAgentCompanion"),
        .testTarget(name: "HostTests",
                    dependencies: ["Host", "NOWAgentIntegration"],
                    path: "Tests/HostTests"),
        .testTarget(name: "NOWAgentCompanionTests",
                    dependencies: ["NOWAgentCompanion",
                                   "NOWAgentIntegration"],
                    path: "Tests/NOWAgentCompanionTests"),
    ]
)
