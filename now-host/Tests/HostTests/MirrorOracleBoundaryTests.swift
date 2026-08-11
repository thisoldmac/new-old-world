import XCTest

final class MirrorOracleBoundaryTests: XCTestCase {
    private var nowRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // file -> HostTests
            .deletingLastPathComponent() // HostTests -> Tests
            .deletingLastPathComponent() // Tests -> now-host
            .deletingLastPathComponent() // now-host -> now
    }

    func testNativeHostDoesNotDependOnTheQMPOracleProduct() throws {
        let manifest = try String(contentsOf:
            nowRoot.appendingPathComponent("now-host/Package.swift"),
            encoding: .utf8)
        XCTAssertFalse(manifest.contains("MirrorOracleKit"),
                       "the production host must remain QEMU-independent")
    }

    func testQMPClientAndDispatcherAreAbsentFromProductionPackage() {
        let sources = nowRoot.appendingPathComponent(
            "now-host/Packages/MirrorKit/Sources")
        for name in ["QmpClient.swift", "ActionDispatcher.swift"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath:
                sources.appendingPathComponent("MirrorKit/\(name)").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath:
                sources.appendingPathComponent("MirrorKitUI/\(name)").path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            sources.appendingPathComponent("MirrorOracleKit").path))
    }

    func testProductionMirrorModelsDoNotNameTheDevelopmentOracle() throws {
        let productionSources = [
            "now-host/Packages/MirrorKit/Sources/MirrorKit/MirrorTarget.swift",
            "now-host/Packages/MirrorKit/Sources/MirrorKit/ActionModel.swift",
        ]
        for relativePath in productionSources {
            let source = try String(contentsOf:
                nowRoot.appendingPathComponent(relativePath), encoding: .utf8)
            XCTAssertFalse(source.localizedCaseInsensitiveContains("qmp"),
                           "\(relativePath) must stay adapter-neutral")
        }
    }
}
