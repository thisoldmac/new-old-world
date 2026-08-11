// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NewOldWorld",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Host", targets: ["Host"]),
        // The Xcode app target consumes this as a real package product, so
        // that `import NOWAgentIntegration` means the same thing to both
        // build systems. It used to compile these sources into the app
        // directly, which left the module name unresolvable there and every
        // import needing a `#if canImport` guard.
        .library(name: "NOWAgentIntegration",
                 targets: ["NOWAgentIntegration"]),
        // MirrorKit and MirrorKitUI are production-owned libraries. The
        // retired standalone Mirror application and its oracle adapter live
        // only in archive/; NOW's host owns the runtime lifecycle and wire.
    ],
    // Keep the semantic core beside the host which owns it. The package stays
    // separate so its renderer and fixture corpus retain an independent gate.
    dependencies: [
        .package(path: "Packages/MirrorKit"),
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
        .testTarget(name: "HostTests",
                    dependencies: ["Host", "NOWAgentIntegration",
                                   .product(name: "MirrorKit",
                                            package: "MirrorKit"),
                                   .product(name: "MirrorKitUI",
                                            package: "MirrorKit")],
                    path: "Tests/HostTests",
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "NOWMCPTests",
                    dependencies: ["Host", "NOWAgentIntegration"],
                    path: "Tests/NOWMCPTests"),
    ]
)
