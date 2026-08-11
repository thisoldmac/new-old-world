import XCTest
import NOWAgentIntegration
@testable import Host

/// **The three pages that used to decide for themselves**, asked through the
/// answer each control actually spends.
///
/// `GuestItemApplicabilityTests` proves the rules; this proves they are
/// REACHED — that Launch on the Software page, Bring to Front on the Processes
/// page, and Run on each Diagnostics card come off the gate rather than off a
/// private test written into a view. The defect these close is one a person
/// found by hand: Launch was offered on a system extension, and the guest
/// refused it after the round trip.
///
/// Every case is asked as the five outcomes, because collapsing any two of
/// them is the mutation that matters: `unsettled` must stay LIVE (unproven is
/// not a no), `noGuest` must never accuse the machine, and `inapplicable` must
/// never name one.
@MainActor
final class GuestItemGateWiringTests: XCTestCase {
    private func listener() -> GuestListener {
        GuestListener(identity: .init(version: "0.1-test", name: "Test Host"))
    }

    private func application(_ name: String) -> SoftwareEntry {
        SoftwareEntry(name: name, path: "HD:Applications:\(name)",
                      type: "APPL")
    }

    private func extensionItem(_ name: String) -> SoftwareEntry {
        SoftwareEntry(name: name, path: "HD:System Folder:Extensions:\(name)",
                      type: "INIT")
    }

    // MARK: - Software: Launch

    private func softwareModel(
        _ record: GuestCapabilityRecord
    ) -> SoftwareModel {
        SoftwareModel(listener: listener(), capabilities: record)
    }

    /// The reported defect, in the order it was found: the button is right for
    /// an application, and was wrong for the extension beside it.
    func testLaunchIsOfferedOnAnApplicationAndNotOnAnExtension() {
        let model = softwareModel(GuestCapabilityRecord())
        model.connection = .connected(named: "Quadra 950")

        XCTAssertTrue(model.launchGate(application("SimpleText")).isEnabled)
        XCTAssertNil(model.launchUnavailableNote(application("SimpleText")))

        let decision = model.launchGate(extensionItem("AppleShare"))
        XCTAssertFalse(decision.isEnabled)
        guard case .inapplicable(let reason) = decision else {
            return XCTFail("expected inapplicable, got \(decision)")
        }
        XCTAssertEqual(model.launchUnavailableNote(extensionItem("AppleShare")),
                       reason)
        /* It holds on every Mac ever made, so it must not read as this one's
           limitation — a person told the wrong thing checks the wrong Mac. */
        XCTAssertFalse(reason.contains("Quadra 950"))
        XCTAssertFalse(reason.contains("does not serve"))
    }

    func testAnUnprovenMachineStillOffersLaunch() {
        let model = softwareModel(GuestCapabilityRecord())
        model.connection = .connected(named: "PowerBook 1400")
        let decision = model.launchGate(application("SimpleText"))
        guard case .unsettled = decision else {
            return XCTFail("expected unsettled, got \(decision)")
        }
        XCTAssertTrue(decision.isEnabled)
        // Enabled, so it does not get to nag: the sentence lives in the
        // tooltip, and the click is what settles the question.
        XCTAssertNil(model.launchUnavailableNote(application("SimpleText")))
        XCTAssertNotNil(decision.explanation)
    }

    func testAMachineThatRefusedLaunchTakesTheButtonAndKeepsItsWords() {
        let record = GuestCapabilityRecord()
        let model = softwareModel(record)
        model.connection = .connected(named: "Quadra 950")
        XCTAssertTrue(model.launchGate(application("SimpleText")).isEnabled)

        record.noteRefusal(AgentIntegrationCapabilityNames.launchCommand,
                           by: model.connection.key, code: "not-implemented",
                           message: "unsupported message type")
        let decision = model.launchGate(application("SimpleText"))
        guard case .unsupported = decision else {
            return XCTFail("expected unsupported, got \(decision)")
        }
        let note = model.launchUnavailableNote(application("SimpleText"))
        XCTAssertEqual(note, decision.explanation)
        XCTAssertTrue(note?.contains("Quadra 950") == true)
        XCTAssertTrue(note?.contains("unsupported message type") == true)
    }

    func testAMachineThatServesBothRequirementsIsSimplyAllowed() {
        let record = GuestCapabilityRecord()
        let model = softwareModel(record)
        model.connection = .connected(named: "Quadra 950")
        record.noteServed(AgentIntegrationCapabilityNames.softwareList,
                          by: model.connection.key)
        record.noteServed(AgentIntegrationCapabilityNames.launchCommand,
                          by: model.connection.key)

        XCTAssertEqual(model.launchGate(application("SimpleText")), .allowed)
        XCTAssertNil(model.launchUnavailableNote(application("SimpleText")))
    }

    func testWithNoMacAttachedLaunchBlamesNoMachine() {
        let model = softwareModel(GuestCapabilityRecord())
        let decision = model.launchGate(extensionItem("AppleShare"))
        guard case .noGuest(let reason) = decision else {
            return XCTFail("expected noGuest, got \(decision)")
        }
        XCTAssertFalse(decision.isEnabled)
        // There is no machine to accuse and no extension to explain: with
        // nothing on the wire every control is dark for one reason.
        XCTAssertFalse(reason.contains("does not serve"))
        XCTAssertFalse(reason.contains("AppleShare"))
    }

    /// **Reveal is rule-free and must stay that way.** It opens nothing, so
    /// every item the machine can name can be shown in its own Finder — the
    /// same item the gate refuses to launch.
    func testShowInFinderIsNotGatedByTheItemAxis() {
        for kind: GuestItemKind in [.application, .finder, .backgroundOnly,
                                    .notAnApplication(type: "INIT"),
                                    .unknown] {
            XCTAssertNil(GuestCapabilityGate.inapplicability(
                of: .reveal, to: kind, named: "AppleShare"))
        }
        // And the view does not gate it either: the Software page's Reveal
        // button is left to `isRevealable` alone.
        let view = try? GateSource.hostSwift(
            "now-host/Sources/Host/SoftwareModuleView.swift")
        XCTAssertNotNil(view)
        XCTAssertFalse(view?.contains("revealGate") == true)
        XCTAssertFalse(view?.contains(".reveal,") == true)
    }

    // MARK: - Processes: Bring to Front

    private func processesModel(
        _ record: GuestCapabilityRecord
    ) -> ProcessesModel {
        ProcessesModel(listener: listener(), capabilities: record)
    }

    private func process(_ name: String, kind: String) -> ProcessEntry {
        ProcessEntry(name: name, kind: kind, psnHigh: 0, psnLow: 42)
    }

    func testFrontingIsOfferedOnAnAppAndNotOnAFacelessProcess() {
        let model = processesModel(GuestCapabilityRecord())
        model.connection = .connected(named: "Quadra 950")

        XCTAssertTrue(model.bringToFrontGate(
            process("SimpleText", kind: "application")).isEnabled)
        XCTAssertTrue(model.bringToFrontGate(
            process("Finder", kind: "finder")).isEnabled)

        let decision = model.bringToFrontGate(
            process("Time Sync", kind: "background"))
        XCTAssertFalse(decision.isEnabled)
        guard case .inapplicable(let reason) = decision else {
            return XCTFail("expected inapplicable, got \(decision)")
        }
        XCTAssertTrue(reason.contains("no windows and no menu bar"))
        XCTAssertFalse(reason.contains("Quadra 950"))
    }

    /// The footer's line, which is what a person actually reads beside the
    /// dark button.
    func testTheFooterExplainsTheDarkButtonForTheSelectedRow() {
        let model = processesModel(GuestCapabilityRecord())
        model.connection = .connected(named: "Quadra 950")
        // Nothing selected: a control dark for want of a selection is
        // explained by the empty selection, not by a sentence about kinds.
        XCTAssertNil(model.bringToFrontNote(for: nil))
        // An application: the control works, so there is nothing to say.
        XCTAssertNil(model.bringToFrontNote(
            for: process("SimpleText", kind: "application")))

        let faceless = process("Time Sync", kind: "background")
        let note = model.bringToFrontNote(for: faceless)
        XCTAssertEqual(note, model.bringToFrontGate(faceless).explanation)
        XCTAssertTrue(note?.contains("Time Sync") == true)
    }

    func testAnUnprovenMachineStillOffersBringToFront() {
        let model = processesModel(GuestCapabilityRecord())
        model.connection = .connected(named: "PowerBook 1400")
        let decision = model.bringToFrontGate(
            process("SimpleText", kind: "application"))
        guard case .unsettled = decision else {
            return XCTFail("expected unsettled, got \(decision)")
        }
        XCTAssertTrue(decision.isEnabled)
    }

    func testAMachineThatRefusedProcessFrontLosesTheButton() {
        let record = GuestCapabilityRecord()
        let model = processesModel(record)
        model.connection = .connected(named: "Quadra 950")
        let app = process("SimpleText", kind: "application")
        XCTAssertTrue(model.bringToFrontGate(app).isEnabled)

        record.noteRefusal(AgentIntegrationCapabilityNames.processFront,
                           by: model.connection.key, code: "not-implemented",
                           message: "unsupported message type")
        let decision = model.bringToFrontGate(app)
        guard case .unsupported(let reason) = decision else {
            return XCTFail("expected unsupported, got \(decision)")
        }
        XCTAssertTrue(reason.contains("Quadra 950"))
    }

    func testAServedMachineFrontsAnApplicationWithoutComment() {
        let record = GuestCapabilityRecord()
        let model = processesModel(record)
        model.connection = .connected(named: "Quadra 950")
        record.noteServed(AgentIntegrationCapabilityNames.processList,
                          by: model.connection.key)
        record.noteServed(AgentIntegrationCapabilityNames.processFront,
                          by: model.connection.key)
        XCTAssertEqual(
            model.bringToFrontGate(process("SimpleText", kind: "application")),
            .allowed)
    }

    func testWithNoMacAttachedFrontingBlamesNoMachine() {
        let model = processesModel(GuestCapabilityRecord())
        let decision = model.bringToFrontGate(
            process("Time Sync", kind: "background"))
        guard case .noGuest(let reason) = decision else {
            return XCTFail("expected noGuest, got \(decision)")
        }
        XCTAssertFalse(reason.contains("does not serve"))
        XCTAssertFalse(reason.contains("Time Sync"))
    }

    /// **"This row sent no PSN" is a third fact and stays where it is.** It is
    /// about the LISTING — an older guest that names no PSN cannot be driven
    /// at all — so the gate neither knows it nor restates it.
    func testTheGateSaysNothingAboutARowWithoutAPSN() {
        let model = processesModel(GuestCapabilityRecord())
        model.connection = .connected(named: "Quadra 950")
        let noPSN = ProcessEntry(name: "SimpleText", kind: "application",
                                 psnHigh: nil, psnLow: nil)
        XCTAssertFalse(noPSN.isDrivable)
        // The gate is about the machine and the item; the button is dark for
        // a reason the row already carries.
        XCTAssertTrue(model.bringToFrontGate(noPSN).isEnabled)
        XCTAssertNil(model.bringToFrontNote(for: noPSN))
    }

    // MARK: - Diagnostics: Run

    private func diagnosticsModel(
        _ record: GuestCapabilityRecord
    ) -> DiagnosticsModel {
        DiagnosticsModel(listener: listener(), capabilities: record)
    }

    private var vprobe: GuestDiagnostic {
        GuestDiagnostics.all.first { $0.probe == .vprobe }!
    }

    func testADiagnosticNobodyHasAskedAboutStaysRunnable() {
        let model = diagnosticsModel(GuestCapabilityRecord())
        model.connection = .connected(named: "PowerBook 1400")
        let decision = model.gate(for: vprobe)
        guard case .unsettled = decision else {
            return XCTFail("expected unsettled, got \(decision)")
        }
        XCTAssertTrue(decision.isEnabled)
    }

    func testAMachineThatAnsweredTheProbeIsAllowedToRunItAgain() {
        let record = GuestCapabilityRecord()
        let model = diagnosticsModel(record)
        model.connection = .connected(named: "Quadra 950")
        record.noteServed(vprobe.verb, by: model.connection.key)
        XCTAssertEqual(model.gate(for: vprobe), .allowed)
    }

    /// The button is now PRESENT and dark rather than absent, so the sentence
    /// beside it is what carries the reason — and it must be the machine's.
    func testAMachineThatRefusedTheVerbDarkensRunAndSaysWhy() {
        let record = GuestCapabilityRecord()
        let model = diagnosticsModel(record)
        model.connection = .connected(named: "Quadra 950")
        XCTAssertTrue(model.gate(for: vprobe).isEnabled)

        record.noteRefusal(vprobe.verb, by: model.connection.key,
                           code: "not-implemented",
                           message: "no such command")
        let decision = model.gate(for: vprobe)
        guard case .unsupported(let reason) = decision else {
            return XCTFail("expected unsupported, got \(decision)")
        }
        XCTAssertFalse(decision.isEnabled)
        XCTAssertTrue(reason.contains("Quadra 950"))
        XCTAssertTrue(reason.contains("no such command"))
    }

    /// The page's own `notServedSentence` is richer — it names the sibling
    /// guest that answers the verb — so it is what a verb absent from the
    /// command table carries, and the gate's line stands down there.
    func testTheCardKeepsItsOwnWordsForAVerbAbsentFromTheCommandTable() {
        let record = GuestCapabilityRecord()
        let model = diagnosticsModel(record)
        model.connection = .connected(named: "Quadra 950")
        record.noteRefusal(vprobe.verb, by: model.connection.key,
                           code: "not-implemented", message: "no such command")

        let notServed = DiagnosticState(diagnostic: vprobe,
                                        serving: .notServed)
        XCTAssertFalse(model.gate(for: notServed.diagnostic).isEnabled)
        XCTAssertEqual(model.availability(for: notServed).reason,
                       model.notServedSentence(vprobe),
                       "the page writes this case itself; two sentences for "
                       + "one dark button is one too many")

        // Any OTHER dark state carries the gate's sentence instead, so no
        // greyed button on the page is left standing beside nothing.
        let unknown = DiagnosticState(diagnostic: vprobe, serving: .unknown)
        XCTAssertEqual(model.availability(for: unknown).reason,
                       model.gate(for: vprobe).explanation)
    }

    func testWithNoMacAttachedTheDiagnosticBlamesNoMachine() {
        let model = diagnosticsModel(GuestCapabilityRecord())
        let decision = model.gate(for: vprobe)
        guard case .noGuest(let reason) = decision else {
            return XCTFail("expected noGuest, got \(decision)")
        }
        XCTAssertFalse(decision.isEnabled)
        XCTAssertFalse(reason.contains("does not serve"))
        XCTAssertEqual(model.availability(
            for: DiagnosticState(diagnostic: vprobe)).reason, reason)
    }

    // MARK: - the controls actually spend the answer

    /* A decision no control consumes is a decision that changes nothing, and
       the model tests above cannot see the difference: they ask the gate
       directly. So each pane is read for the two things that make the answer
       reach a person — the call, and the `disabled` it feeds.

       Read through `GateSource`, which strips comments, because the prose
       beside each of these names the very symbols being looked for. Its
       stated limit applies here too: this proves the text is present and
       cannot prove the control is reachable. That is what the manual pass in
       docs/metal-and-ux-review.md §4c is for. */

    private func pane(_ file: String) throws -> String {
        try GateSource.hostSwift("now-host/Sources/Host/\(file)")
    }

    func testTheSoftwarePageSpendsTheLaunchDecision() throws {
        let view = try pane("SoftwareModuleView.swift")
        XCTAssertTrue(view.contains("model.launchGate(entry)"))
        XCTAssertTrue(view.contains("!launch.isEnabled"),
                      "the Launch button no longer disables on the gate")
        XCTAssertTrue(view.contains("model.launchUnavailableNote(entry)"),
                      "a dark Launch button with nothing beside it reads as "
                      + "a bug")
    }

    func testTheProcessesPageSpendsTheFrontDecision() throws {
        let view = try pane("ProcessesModuleView.swift")
        XCTAssertTrue(view.contains("model.bringToFrontGate($0)"))
        XCTAssertTrue(view.contains("front?.isEnabled == false"),
                      "Bring to Front no longer disables on the gate")
        XCTAssertTrue(view.contains("model.bringToFrontNote("))
        // The other two verbs are NOT gated on this axis: quitting a faceless
        // process is a real thing to do, and screenshotting one is the guest's
        // own refusal to make.
        XCTAssertFalse(view.contains("askToQuitGate"))
        XCTAssertFalse(view.contains("screenshotAppGate"))
    }

    /// The Diagnostics page spends ONE decision — the same one for the row's
    /// dimming, the button's state and the sentence — and keeps its button.
    ///
    /// The page is a list and a detail pane now rather than three cards, and
    /// the gate reaches it through `availability(for:)`: the model asks the
    /// gate and folds in the one case it can word better (a verb absent from
    /// the command table). Two separate asks would let the greyed row and the
    /// dark button disagree about the same machine.
    func testTheDiagnosticsCardsSpendTheirDecisionAndKeepTheirButton() throws {
        let view = try pane("DiagnosticsModuleView.swift")
        XCTAssertTrue(view.contains("model.availability(for: state)"))
        XCTAssertTrue(view.contains("!availability.isRunnable"),
                      "the Run button no longer disables on the gate")
        XCTAssertTrue(view.contains("availability.reason"),
                      "a dark Run button with nothing beside it reads as a "
                      + "bug")
        /* Present-and-dark, not absent. The button used to be replaced by an
           `EmptyView()` on a verb the machine does not serve, which moved
           everything below it as machines came and went. */
        XCTAssertFalse(view.contains("EmptyView()"),
                       "the Run button is missing again on some row")
    }

    /// **The gate is handed the command table this page already asked for.**
    ///
    /// Not a saving worth a line on its own — it is that a second `help` per
    /// card would be this side asking a machine something it has already
    /// answered, and the page's own `serving` and the gate would then be two
    /// answers about one command table, settling at different moments.
    func testTheDiagnosticsPageAsksForACommandTableExactlyOnce() throws {
        let model = try GateSource.hostSwift(
            "now-host/Sources/Host/DiagnosticsModel.swift")
        /* Read at the CALL rather than anywhere in the file: this model also
           parks a command table per machine, so a scan of the whole text goes
           on passing after the evidence stops carrying one. */
        let calls = model.components(separatedBy: "capabilities.evidence(")
        XCTAssertEqual(calls.count, 2, "expected exactly one evidence call")
        let arguments = calls.last?.components(separatedBy: "))").first
        XCTAssertEqual(arguments?.contains("commandNames: commandNames"), true,
                       "the gate is deciding without this page's own help "
                       + "table, so a card would need a second `help`")
        XCTAssertEqual(
            model.components(separatedBy: "\"help\", line: \"\"").count - 1,
            1,
            "a second help per connection")
    }

    /// One machine's refusal must not darken another's card — the record is
    /// keyed per Mac, and a page reading it must pass the key it is showing.
    func testARefusedDiagnosticBelongsToTheMachineThatRefusedIt() {
        let record = GuestCapabilityRecord()
        let model = diagnosticsModel(record)
        model.connection = .connected(named: "Quadra 950")
        record.noteRefusal(vprobe.verb, by: model.connection.key,
                           code: "not-implemented", message: "no such command")
        XCTAssertFalse(model.gate(for: vprobe).isEnabled)

        model.connection = .connected(named: "Power Mac G3")
        XCTAssertTrue(model.gate(for: vprobe).isEnabled,
                      "a 68K Mac's refusal darkened a PowerPC Mac's card")
    }
}
