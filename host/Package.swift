// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NewOldWorld",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Host", targets: ["Host"]),
        .executable(name: "NOWAgentCompanion",
                    targets: ["NOWAgentCompanion"]),
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
