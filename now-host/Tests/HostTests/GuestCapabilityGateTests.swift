import XCTest
import NOWAgentIntegration
@testable import Host

/// The gating DECISION, not the pixels.
///
/// Everything here is a pure function of what the connected machine has said,
/// which is the point of the evidence being a value: the three facts a person
/// must be able to tell apart — this Mac cannot, nothing is connected, nobody
/// has asked — are exactly what a test can pin, and flattening any two of them
/// is what produces a control permanently dark on a machine that would serve
/// it fine.
@MainActor
final class GuestCapabilityGateTests: XCTestCase {
    private let peer = "PowerBook 1400"

    private func evidence(
        connected: Bool = true,
        commands: Set<String>? = nil,
        observations: [String: GuestCapabilityObservation] = [:]
    ) -> GuestCapabilityEvidence {
        GuestCapabilityEvidence(isConnected: connected, peerLabel: peer,
                                commandNames: commands,
                                observations: observations)
    }

    private var streamFamilies: [String] { StreamScreenProjection.requires }

    // MARK: the three states

    func testNoGuestIsItsOwnAnswerAndNotAMachineThatCannot() {
        let decision = GuestCapabilityGate.decide(
            StreamScreenProjection.self, in: evidence(connected: false))
        guard case .noGuest(let reason) = decision else {
            return XCTFail("expected noGuest, got \(decision)")
        }
        XCTAssertFalse(decision.isEnabled)
        XCTAssertTrue(decision.deservesAVisibleReason)
        // It must not name the machine as the thing that cannot: there isn't
        // one. The peer label degrades to a description before a connection,
        // and a sentence built around it would read as an accusation.
        XCTAssertFalse(reason.contains("does not serve"))
        XCTAssertTrue(reason.contains(
            "No \(MachineNaming.commonNoun) is connected"))
    }

    func testUnaskedIsEnabledAndSaysTheClickIsWhatSettlesIt() {
        let decision = GuestCapabilityGate.decide(
            StreamScreenProjection.self, in: evidence())
        guard case .unsettled(let reason) = decision else {
            return XCTFail("expected unsettled, got \(decision)")
        }
        // The whole reason this is not a Bool: unproven leaves the control
        // live, because the machine's own refusal beats this side declining
        // to ask.
        XCTAssertTrue(decision.isEnabled)
        XCTAssertFalse(decision.deservesAVisibleReason)
        XCTAssertTrue(reason.contains(peer))
        XCTAssertTrue(reason.contains("stream.start"))
    }

    func testARefusalByNameDisablesAndQuotesTheMachine() {
        let decision = GuestCapabilityGate.decide(
            StreamScreenProjection.self,
            in: evidence(observations: [
                AgentIntegrationCapabilityNames.streamStart:
                    .init(served: false, code: "not-implemented",
                          message: "unsupported message type"),
            ]))
        guard case .unsupported(let reason) = decision else {
            return XCTFail("expected unsupported, got \(decision)")
        }
        XCTAssertFalse(decision.isEnabled)
        XCTAssertTrue(decision.deservesAVisibleReason)
        XCTAssertTrue(reason.contains(peer))
        XCTAssertTrue(reason.contains("stream.start"))
        // Its words, not ours.
        XCTAssertTrue(reason.contains("unsupported message type"))
        XCTAssertTrue(reason.contains("not-implemented"))
        // And it must not read as damage.
        XCTAssertTrue(reason.contains("Nothing is wrong with the machine"))
    }

    func testEveryRequirementServedIsPlainlyAllowed() {
        var observations: [String: GuestCapabilityObservation] = [:]
        for family in streamFamilies {
            observations[family] = .init(served: true, code: nil,
                                         message: nil)
        }
        let decision = GuestCapabilityGate.decide(
            StreamScreenProjection.self,
            in: evidence(observations: observations))
        XCTAssertEqual(decision, .allowed)
        XCTAssertTrue(decision.isEnabled)
        XCTAssertNil(decision.explanation)
    }

    // MARK: what must NOT be read as an answer

    func testATimeoutIsNotARefusalAndLeavesTheControlLive() {
        /* Silence proves nothing about what a machine implements. Recording
           it as a no would let one wedged MacTCP stack read as a permanently
           missing feature — the failure the listener's own observation path
           refuses to make. */
        for code in ["timeout", "disconnected", "busy", "-108"] {
            let decision = GuestCapabilityGate.decide(
                StreamScreenProjection.self,
                in: evidence(observations: [
                    AgentIntegrationCapabilityNames.streamStart:
                        .init(served: false, code: code, message: "no reply"),
                ]))
            XCTAssertTrue(decision.isEnabled,
                          "\(code) must not disable a control")
            guard case .unsettled = decision else {
                return XCTFail("\(code) settled the question: \(decision)")
            }
        }
    }

    func testARefusalOutweighsAnUnprovenSibling() {
        // The conjunction's worst answer wins, as the ledger's does: one
        // requirement the machine said no to settles the row whatever is
        // unknown about the rest.
        let decision = GuestCapabilityGate.decide(
            StreamScreenProjection.self,
            in: evidence(observations: [
                AgentIntegrationCapabilityNames.streamStop:
                    .init(served: false, code: "unknown-message",
                          message: "no such message"),
            ]))
        guard case .unsupported(let reason) = decision else {
            return XCTFail("expected unsupported, got \(decision)")
        }
        XCTAssertTrue(reason.contains("stream.stop"))
    }

    // MARK: commands resolve off help, families never do

    func testACommandAbsentFromAnAnsweredHelpTableIsNotServed() {
        let decision = GuestCapabilityGate.decide(
            requiring: [AgentIntegrationCapabilityNames.putstatCommand],
            in: evidence(commands: ["help", "vprobe", "shotdiag"]))
        guard case .unsupported(let reason) = decision else {
            return XCTFail("expected unsupported, got \(decision)")
        }
        XCTAssertTrue(reason.contains("command table"))
    }

    func testACommandIsUnsettledUntilHelpHasAnswered() {
        let decision = GuestCapabilityGate.decide(
            requiring: [AgentIntegrationCapabilityNames.putstatCommand],
            in: evidence(commands: nil))
        guard case .unsettled = decision else {
            return XCTFail("a machine that has not listed its commands "
                           + "cannot have answered: \(decision)")
        }
    }

    func testACommandPresentInHelpIsAllowed() {
        XCTAssertEqual(
            GuestCapabilityGate.decide(
                requiring: [AgentIntegrationCapabilityNames.vprobeCommand],
                in: evidence(commands: ["help", "vprobe"])),
            .allowed)
    }

    /// **The fall-through that would switch every stream off, silently.**
    ///
    /// `help` lists commands and cannot list message families — that gap is
    /// how `ps` shipped wire-only. A family falling through to the command
    /// table would resolve "absent" against every machine that exists, and
    /// the sentence would read as a fact about the Macintosh.
    func testAMessageFamilyIsNeverAnsweredByTheCommandTable() {
        let decision = GuestCapabilityGate.decide(
            StreamScreenProjection.self,
            in: evidence(commands: ["help", "vprobe", "gestalt"]))
        guard case .unsettled = decision else {
            return XCTFail("a command table answered a message family: "
                           + "\(decision)")
        }
    }

    /// The classification is read off the ledger's own declaration rather
    /// than guessed from the spelling, so this pins the two together: every
    /// requirement any projection row declares is either a declared family or
    /// a name `help` could plausibly carry, and never both.
    func testEveryProjectionRequirementClassifiesOneWayOnly() {
        for row in HostProjectionRegistry.hostFaces.projections {
            for requirement in row.requires {
                let isFamily = GuestCapabilityEvidence.messageFamilies
                    .contains(requirement)
                XCTAssertEqual(
                    isFamily, requirement.contains("."),
                    "\(row.capability.rawValue) requires \(requirement), "
                    + "which is declared a "
                    + (isFamily ? "family" : "command")
                    + " but is spelled like the other")
            }
        }
    }
}
