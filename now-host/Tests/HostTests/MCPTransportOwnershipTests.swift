import XCTest
@testable import Host

/// Architectural guards for the MCP boundary a person deploys.
///
/// NOW owns one live MCP surface: HTTP inside the running app. The same-user
/// local agent socket remains a separate developer/control seam, but no
/// standard-input MCP process may sit in front of it.
final class MCPTransportOwnershipTests: XCTestCase {
    func testPackageShipsNoSeparateMCPCompanionProduct() throws {
        let package = try GateSource.raw("now-host/Package.swift")

        XCTAssertFalse(package.contains("NOWAgentCompanion"), """
            MCP is a NOW-owned surface. Do not add a companion executable or \
            target; add transports beneath Host/MCP and share NOWMCPServer.
            """)
        XCTAssertTrue(package.contains(".executable(name: \"Host\""))
    }

    func testHTTPIsTheOnlyLiveMCPTransport() throws {
        let http = try GateSource.hostSwift(
            "now-host/Sources/Host/MCP/HTTPMCPTransport.swift")
        let app = try GateSource.hostSwift("now-host/Sources/Host/App.swift")
        let view = try GateSource.hostSwift(
            "now-host/Sources/Host/MCPModuleView.swift")
        let settings = try GateSource.hostSwift(
            "now-host/Sources/Host/HostSettingsView.swift")

        XCTAssertTrue(http.contains("NOWMCPServer"),
                      "HTTP must remain typed around the shared MCP core.")
        XCTAssertTrue(app.contains("MCPHTTPListener("),
                      "The normal NOW app must own the HTTP listener.")
        for source in [app, view, settings] {
            XCTAssertFalse(source.contains("startMCPStdio"))
            XCTAssertFalse(source.contains("startStdio"))
            XCTAssertFalse(source.contains("stdioStartsAutomatically"))
            XCTAssertFalse(source.contains("Standard Input (Deprecated)"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            GateSource.repoRoot.appendingPathComponent(
                "now-host/Sources/Host/MCP/StdioMCPTransport.swift").path))
    }

    func testMCPPageOwnsHTTPControlsAndNoStdioCard() throws {
        let view = try GateSource.hostSwift(
            "now-host/Sources/Host/MCPModuleView.swift")

        for required in [
            "title: \"HTTP (Recommended)\"",
            "state: model.http",
            "start: startHTTP",
            "stop: stopHTTP",
        ] {
            XCTAssertTrue(view.contains(required),
                          "MCP page lost HTTP transport control: "
                              + required)
        }
        XCTAssertFalse(view.contains("transportStdio"))
        XCTAssertFalse(view.contains("stdioConfiguration"))

        for required in [
            "TextField(\"Port\", value: $settings.httpPort",
            ".disabled(isRunning)",
        ] {
            XCTAssertTrue(view.contains(required),
                          "MCP page lost transport configuration: "
                              + required)
        }
    }

    /// HTTP start policy lives in Settings, not on its runtime card.
    func testStartAutomaticallyMovedToSettingsNotTheMCPPage() throws {
        let view = try GateSource.hostSwift(
            "now-host/Sources/Host/MCPModuleView.swift")
        let settings = try GateSource.hostSwift(
            "now-host/Sources/Host/HostSettingsView.swift")

        XCTAssertFalse(view.contains("Toggle(\"Start"),
                       "the MCP page must not carry its own copy of "
                           + "start-automatically once Settings owns it")
        XCTAssertTrue(settings.contains("$model.httpStartsAutomatically"))
        XCTAssertFalse(settings.contains("stdioStartsAutomatically"))
    }

    func testRuntimeControlsDoNotRewriteAutomaticStartPolicy() throws {
        let app = try GateSource.hostSwift("now-host/Sources/Host/App.swift")

        XCTAssertFalse(app.contains(".httpStartsAutomatically ="),
                       "Starting or stopping HTTP must not rewrite launch policy.")
        XCTAssertTrue(app.contains(
            "if preferences.httpStartsAutomatically { startMCPHTTP() }"))
    }
}
