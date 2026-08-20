import XCTest
@testable import Host
@testable import NOWAgentIntegration

/// The transport tag rides BESIDE the log line the way `area` does: the
/// line's text and file format are frozen, and only the writer may say
/// which transport a line belongs to, because the text cannot — the audit
/// message opens with the transport-neutral `mcp` face.
@MainActor
final class HostLogTransportTagTests: XCTestCase {
    func testTaggedWriteLeavesTheLineTextIdentical() {
        let log = HostLog.shared
        log.write(.warn, "agent", "the same sentence")
        let untagged = log.lines.last!
        log.write(.warn, "agent", "the same sentence", transport: .http)
        let tagged = log.lines.last!

        XCTAssertEqual(untagged.text.dropFirst(8), tagged.text.dropFirst(8),
                       "everything after the clock must match")
        XCTAssertNil(untagged.transport)
        XCTAssertEqual(tagged.transport, "http")
        XCTAssertEqual(untagged.area, tagged.area)
    }

    func testAuditRecordTagsItsLineWithoutChangingTheMessage() {
        let log = HostLog.shared
        let event = HostProjectionAuditEvent(
            capability: HostCapabilityID("now_list_machines"), face: .mcp,
            guest: nil, outcome: .answered, reason: nil)

        AgentIntegrationAuditLog.record(event, drivenGuest: "pb1400c",
                                        log: log)
        let untagged = log.lines.last!
        AgentIntegrationAuditLog.record(event, drivenGuest: "pb1400c",
                                        log: log, transport: .http)
        let tagged = log.lines.last!

        XCTAssertEqual(untagged.text.dropFirst(8), tagged.text.dropFirst(8))
        XCTAssertEqual(tagged.transport, "http")
        XCTAssertTrue(tagged.area.hasPrefix("agent"))
    }
}
