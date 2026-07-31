import XCTest
import NOWAgentIntegration
@testable import Host

/// The second axis: whether an action means anything for the ITEM, which is
/// a different question from whether the attached Mac can serve it — and the
/// tests are mostly about keeping the two apart.
@MainActor
final class GuestItemApplicabilityTests: XCTestCase {
    private func connected(
        _ observations: [String: GuestCapabilityObservation] = [:]
    ) -> GuestCapabilityEvidence {
        GuestCapabilityEvidence(isConnected: true, peerLabel: "Quadra 950",
                                commandNames: ["help", "launch", "reveal"],
                                observations: observations)
    }

    private func entry(name: String, type: String?) -> SoftwareEntry {
        SoftwareEntry(name: name, path: "HD:System Folder:\(name)",
                      type: type)
    }

    private func process(name: String, kind: String) -> ProcessEntry {
        ProcessEntry(name: name, kind: kind, psnHigh: 0, psnLow: 42)
    }

    // MARK: the kinds come off facts the product already carries

    func testASoftwareItemsKindIsItsFinderType() {
        XCTAssertEqual(entry(name: "SimpleText", type: "APPL").itemKind,
                       .application)
        XCTAssertEqual(entry(name: "AppleShare", type: "INIT").itemKind,
                       .notAnApplication(type: "INIT"))
        // Absent is not a guess: a responder that sent no type has said
        // nothing, and nothing must not disable a real application.
        XCTAssertEqual(entry(name: "Mystery", type: nil).itemKind, .unknown)
    }

    func testAProcessKindIsTheResponderesOwnClassification() {
        // The guest derives this from processMode's modeOnlyBackground bit
        // and is explicit that the 'appe' file type is NOT the authority;
        // this side must read the classification, not the type code.
        XCTAssertEqual(process(name: "Time Sync", kind: "background").itemKind,
                       .backgroundOnly)
        XCTAssertEqual(process(name: "Finder", kind: "finder").itemKind,
                       .finder)
        XCTAssertEqual(process(name: "SimpleText", kind: "application")
                        .itemKind, .application)
    }

    // MARK: the rules

    func testLaunchingSomethingThatIsNotAnApplicationDoesNotApply() {
        let decision = GuestCapabilityGate.decide(
            LaunchSoftwareProjection.self, performing: .launch,
            on: entry(name: "AppleShare", type: "INIT").itemKind,
            named: "AppleShare", in: connected())
        guard case .inapplicable(let reason) = decision else {
            return XCTFail("expected inapplicable, got \(decision)")
        }
        XCTAssertFalse(decision.isEnabled)
        XCTAssertTrue(decision.deservesAVisibleReason)
        XCTAssertTrue(reason.contains("AppleShare"))
        XCTAssertTrue(reason.contains("INIT"))
        /* The distinction the whole case exists for: this must never read as
           a limitation of the machine on the wire. */
        XCTAssertFalse(reason.contains("Quadra 950"))
        XCTAssertFalse(reason.contains("does not serve"))
    }

    func testFrontingAFacelessProcessDoesNotApply() {
        let decision = GuestCapabilityGate.decide(
            BringToFrontProjection.self, performing: .bringToFront,
            on: process(name: "Time Sync", kind: "background").itemKind,
            named: "Time Sync", in: connected())
        guard case .inapplicable(let reason) = decision else {
            return XCTFail("expected inapplicable, got \(decision)")
        }
        XCTAssertTrue(reason.contains("no windows and no menu bar"))
    }

    func testAnOrdinaryApplicationIsNotGatedByThisAxis() {
        XCTAssertNil(GuestCapabilityGate.inapplicability(
            of: .launch, to: .application, named: "SimpleText"))
        XCTAssertNil(GuestCapabilityGate.inapplicability(
            of: .bringToFront, to: .application, named: "SimpleText"))
        XCTAssertNil(GuestCapabilityGate.inapplicability(
            of: .bringToFront, to: .finder, named: "Finder"))
    }

    func testAnUnstatedKindGatesNothing() {
        // Same discipline as `unsettled`: absence is not a value, and a
        // catalog that left the type out must not grey out its own rows.
        for action: GuestItemAction in [.launch, .bringToFront, .reveal] {
            XCTAssertNil(GuestCapabilityGate.inapplicability(
                of: action, to: .unknown, named: "Mystery"))
        }
    }

    /// Reveal opens nothing, so it applies to every item the machine can
    /// name — including the ones launch refuses. It is also the shape a
    /// future action takes: rule-free until someone states a rule, so a
    /// control meant to be ENABLED on an extension needs nothing added here.
    func testRevealAppliesToEverything() {
        for kind: GuestItemKind in [.application, .finder, .backgroundOnly,
                                    .notAnApplication(type: "cdev"),
                                    .unknown] {
            XCTAssertNil(GuestCapabilityGate.inapplicability(
                of: .reveal, to: kind, named: "Item"))
        }
    }

    // MARK: the two axes stay apart

    func testTheMachinesRefusalAndTheItemsKindAreDifferentSentences() {
        let refused = connected([
            AgentIntegrationCapabilityNames.processFront:
                .init(served: false, code: "not-implemented",
                      message: "unsupported message type"),
        ])
        let machine = GuestCapabilityGate.decide(
            BringToFrontProjection.self, performing: .bringToFront,
            on: .application, named: "SimpleText", in: refused)
        let item = GuestCapabilityGate.decide(
            BringToFrontProjection.self, performing: .bringToFront,
            on: .backgroundOnly, named: "Time Sync", in: connected())

        // Both dark, and a person must be able to tell which is which:
        // one is answered by attaching a different Mac, the other never is.
        XCTAssertFalse(machine.isEnabled)
        XCTAssertFalse(item.isEnabled)
        XCTAssertNotEqual(machine, item)
        guard case .unsupported = machine else {
            return XCTFail("expected unsupported, got \(machine)")
        }
        guard case .inapplicable = item else {
            return XCTFail("expected inapplicable, got \(item)")
        }
    }

    func testWithNoMacAttachedThatIsTheReasonGiven() {
        /* Ordering, stated: with nothing on the wire every control is dark
           for one reason, and explaining an extension to someone who has no
           machine connected is noise. */
        let decision = GuestCapabilityGate.decide(
            LaunchSoftwareProjection.self, performing: .launch,
            on: .notAnApplication(type: "INIT"), named: "AppleShare",
            in: GuestCapabilityEvidence(isConnected: false,
                                        peerLabel: "the classic Mac"))
        guard case .noGuest = decision else {
            return XCTFail("expected noGuest, got \(decision)")
        }
    }

    func testTheItemsKindOutranksAnUnprovenCapability() {
        // Nothing has established process.front here, so the capability axis
        // would leave the control live. The item settles it anyway: no
        // amount of asking makes a faceless process frontable.
        let decision = GuestCapabilityGate.decide(
            BringToFrontProjection.self, performing: .bringToFront,
            on: .backgroundOnly, named: "Time Sync", in: connected())
        XCTAssertFalse(decision.isEnabled)
    }
}
