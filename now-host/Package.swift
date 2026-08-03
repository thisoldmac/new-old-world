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
        // Mirror module here starts and stops one instance of it
        // (`MirrorControlModel`).
    ],
    // Mirror is vendored WHOLE at now/mirror/ and keeps its own
    // package. NOW takes MirrorKit as a dependency of its TESTS
    // first, for one reason: NOW's scene calls itself Mirror's IR
    // v1 - the envelope says irVersion 1 - and until 2026-08-02
    // nothing had ever decoded one with the type that IR belongs
    // to. Five required fields were missing, and every one was
    // found by restaging an emulator, six minutes a cycle. A
    // decode is a millisecond.
    dependencies: [
        .package(path: "../mirror/host/MirrorKit"),
    ],
    targets: [
        .target(name: "NOWAgentIntegration",
                path: "Sources/NOWAgentIntegration"),
        .executableTarget(name: "Host",
                          dependencies: ["NOWAgentIntegration",
                                         .product(name: "MirrorKit",
                                                  package: "MirrorKit"),
                                         .product(name: "MirrorKitUI",
                                                  package: "MirrorKit")],
                          path: "Sources/Host"),
        .executableTarget(name: "NOWAgentCompanion",
                          dependencies: ["NOWAgentIntegration"],
                          path: "Sources/NOWAgentCompanion"),
        .testTarget(name: "HostTests",
                    dependencies: ["Host", "NOWAgentIntegration",
                                   .product(name: "MirrorKit",
                                            package: "MirrorKit"),
                                   .product(name: "MirrorKitUI",
                                            package: "MirrorKit")],
                    path: "Tests/HostTests",
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "NOWAgentCompanionTests",
                    dependencies: ["NOWAgentCompanion",
                                   "NOWAgentIntegration"],
                    path: "Tests/NOWAgentCompanionTests"),
    ]
)
