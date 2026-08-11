import XCTest
import NOWAgentIntegration
@testable import Host

/// Streaming, gated on what the connected Mac has said — the one place the
/// mechanism is applied so far.
@MainActor
final class ScreenshotStreamGateTests: XCTestCase {
    private func makeModel(
        _ record: GuestCapabilityRecord
    ) -> ScreenshotModuleModel {
        ScreenshotModuleModel(
            listener: GuestListener(
                identity: .init(version: "0.1-test", name: "Test Host")),
            defaults: UserDefaults.standard,
            capabilities: record)
    }

    private func refuseStreaming(on record: GuestCapabilityRecord,
                                 for key: GuestKey?) {
        record.noteRefusal(AgentIntegrationCapabilityNames.streamStart,
                           by: key, code: "not-implemented",
                           message: "unsupported message type")
    }

    func testStreamingIsOfferedToAMachineNobodyHasAskedYet() {
        let model = makeModel(GuestCapabilityRecord())
        model.connection = .connected(named: "PowerBook 1400")

        // Unproven is not a no: the click is what settles it.
        XCTAssertTrue(model.canStream)
        XCTAssertNil(model.streamUnavailableNote)
        XCTAssertNotNil(model.streamGateTooltip)
    }

    func testAMachineThatRefusedStreamingLosesTheButtonAndKeepsItsWords() {
        let record = GuestCapabilityRecord()
        let model = makeModel(record)
        model.connection = .connected(named: "Quadra 950")
        refuseStreaming(on: record, for: model.connection.key)

        XCTAssertFalse(model.canStream)
        let note = model.streamUnavailableNote
        XCTAssertNotNil(note)
        XCTAssertTrue(note?.contains("Quadra 950") == true)
        XCTAssertTrue(note?.contains("unsupported message type") == true)
        // The reason must reach the pointer as well as the eye.
        XCTAssertEqual(model.streamGateTooltip, note)
    }

    func testNoConnectionIsADifferentSentenceFromAMachineThatCannot() {
        let model = makeModel(GuestCapabilityRecord())
        XCTAssertFalse(model.canStream)
        let note = model.streamUnavailableNote
        XCTAssertNotNil(note)
        XCTAssertFalse(note?.contains("does not serve") == true)
    }

    /// **One machine's refusal must not grey out another's control.** The
    /// record is keyed per Mac for the reason the listener keys its own that
    /// way: an observation is a claim about ONE machine.
    func testARefusalBelongsToTheMachineThatMadeIt() {
        let record = GuestCapabilityRecord()
        let model = makeModel(record)
        model.connection = .connected(named: "Quadra 950")
        refuseStreaming(on: record, for: model.connection.key)
        XCTAssertFalse(model.canStream)

        model.connection = .connected(named: "Power Mac G3")
        XCTAssertTrue(model.canStream,
                      "a 68K Mac's refusal disabled a PowerPC Mac's button")
    }

    func testAMachineLeavingTheRosterTakesItsAnswersWithIt() {
        let record = GuestCapabilityRecord()
        let model = makeModel(record)
        model.connection = .connected(named: "Quadra 950")
        let key = try? XCTUnwrap(model.connection.key)
        refuseStreaming(on: record, for: key)
        XCTAssertFalse(model.canStream)

        /* The same name dialling back in may be a different build with a
           different command table; a refusal carried across would be this
           page asserting something it has not asked. */
        if let key { model.guestLeft(key) }
        XCTAssertTrue(model.canStream)
    }

    func testANonRefusalDoesNotTakeTheButtonAway() {
        let record = GuestCapabilityRecord()
        let model = makeModel(record)
        model.connection = .connected(named: "PowerBook 1400")
        record.noteRefusal(AgentIntegrationCapabilityNames.streamStart,
                           by: model.connection.key, code: "busy",
                           message: "a transfer is running")
        XCTAssertTrue(model.canStream)
        XCTAssertNil(model.streamUnavailableNote)
    }
}
