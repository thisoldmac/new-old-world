// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScreenshotsPrototype",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Host", targets: ["Host"]),
    ],
    targets: [
        .executableTarget(name: "Host", path: "Sources/Host"),
        .testTarget(name: "HostTests", dependencies: ["Host"],
                    path: "Tests/HostTests"),
    ]
)

