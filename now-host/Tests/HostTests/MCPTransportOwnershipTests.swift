import XCTest
@testable import Host

/// Architectural guards for the MCP boundary a person deploys.
///
/// NOW owns one MCP surface and two transports. HTTP is part of the running
/// app; stdio is a narrow mode of that same executable. A second executable
/// target would turn a transport choice back into a separately deployed
/// component, which is the regression these source-level checks name.
final class MCPTransportOwnershipTests: XCTestCase {
    func testPackageShipsNoSeparateMCPCompanionProduct() throws {
        let package = try GateSource.raw("now-host/Package.swift")

        XCTAssertFalse(package.contains("NOWAgentCompanion"), """
            MCP is a NOW-owned surface. Do not add a companion executable or \
            target; add transports beneath Host/MCP and share NOWMCPServer.
            """)
        XCTAssertTrue(package.contains(".executable(name: \"Host\""))
    }

    func testBothTransportsUseNOWsOneMCPServer() throws {
        let stdio = try GateSource.hostSwift(
            "now-host/Sources/Host/MCP/StdioMCPTransport.swift")
        let http = try GateSource.hostSwift(
            "now-host/Sources/Host/MCP/HTTPMCPTransport.swift")
        let app = try GateSource.hostSwift("now-host/Sources/Host/App.swift")

        XCTAssertTrue(stdio.contains("NOWMCPServer("))
        XCTAssertTrue(http.contains("NOWMCPServer"),
                      "HTTP must remain typed around the shared MCP core.")
        XCTAssertTrue(app.contains("MCPHTTPListener("),
                      "The normal NOW app must own the HTTP listener.")
        XCTAssertTrue(app.contains("[\"--mcp-stdio\"]"),
                      "The same NOW executable must own stdio mode.")
    }

    func testMCPPageOwnsIndependentControlsForBothTransports() throws {
        let view = try GateSource.hostSwift(
            "now-host/Sources/Host/MCPModuleView.swift")

        for required in [
            "title: \"Standard Input\"",
            "state: model.stdio",
            "start: startStdio",
            "stop: stopStdio",
            "title: \"HTTP\"",
            "state: model.http",
            "start: startHTTP",
            "stop: stopHTTP",
        ] {
            XCTAssertTrue(view.contains(required),
                          "MCP page lost independent transport control: "
                              + required)
        }

        for required in [
            "startsAutomatically: $settings.stdioStartsAutomatically",
            "startsAutomatically: $settings.httpStartsAutomatically",
            "Toggle(\"Start automatically\"",
            "TextField(\"Port\", value: $settings.httpPort",
            ".disabled(isRunning)",
        ] {
            XCTAssertTrue(view.contains(required),
                          "MCP page lost transport configuration: "
                              + required)
        }
    }

    func testRuntimeControlsDoNotRewriteAutomaticStartPolicy() throws {
        let app = try GateSource.hostSwift("now-host/Sources/Host/App.swift")

        XCTAssertFalse(app.contains(".stdioStartsAutomatically ="),
                       "Starting or stopping stdio must not rewrite launch policy.")
        XCTAssertFalse(app.contains(".httpStartsAutomatically ="),
                       "Starting or stopping HTTP must not rewrite launch policy.")
        XCTAssertTrue(app.contains(
            "if preferences.stdioStartsAutomatically { startMCPStdio() }"))
        XCTAssertTrue(app.contains(
            "if preferences.httpStartsAutomatically { startMCPHTTP() }"))
    }
}
