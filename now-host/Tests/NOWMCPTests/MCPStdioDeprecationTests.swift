import Foundation
@testable import Host
@testable import NOWAgentIntegration
import XCTest

final class MCPStdioDeprecationTests: XCTestCase {
    func testWarningIsOneBoundedSecretFreeLine() throws {
        let pipe = Pipe()
        MCPStdioDeprecation.writeWarning(to: pipe.fileHandleForWriting)
        try pipe.fileHandleForWriting.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let warning = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(warning, MCPStdioDeprecation.warning + "\n")
        XCTAssertEqual(warning.split(separator: "\n").count, 1)
        XCTAssertLessThanOrEqual(warning.utf8.count, 512)
        XCTAssertTrue(warning.contains("Streamable HTTP"))
        XCTAssertTrue(warning.contains(MCPStdioDeprecation.supportURL))
        XCTAssertFalse(warning.localizedCaseInsensitiveContains("bearer"))
        XCTAssertFalse(warning.contains("/Users/"))
    }

    func testLocalEvidenceKeepsInitializationAndActionSeparate() {
        let initialization = MCPInitializationEvidence(
            kind: .mcpStdio,
            agentName: "Claude Code 2.1",
            clientName: "Claude Code",
            clientVersion: "2.1",
            sessionKey: "pid:42",
            firstSeen: Date(timeIntervalSince1970: 10),
            lastSeen: Date(timeIntervalSince1970: 20))
        let action = MCPActionRow(
            action: MCPActionRecord(
                id: 1, at: Date(timeIntervalSince1970: 30), agentID: 2,
                sessionID: 3, targetID: nil,
                capability: "now_list_machines", face: .mcp,
                outcome: .answered, reason: nil),
            agentName: "Claude Code 2.1", targetMachine: nil)

        let presentation = MCPStdioEvidencePresentation(
            initialization: initialization, action: action,
            stamp: { "t\(Int($0.timeIntervalSince1970))" })

        XCTAssertEqual(presentation.lastInitialization,
                       "Claude Code 2.1 · t20")
        XCTAssertEqual(presentation.lastAction,
                       "Claude Code 2.1 · now_list_machines · t30")
        XCTAssertEqual(presentation.scope,
                       "This evidence is from this installation only.")
        XCTAssertFalse(presentation.lastInitialization.contains("pid:42"),
                       "session identifiers are not rendered in this summary")
    }
}
