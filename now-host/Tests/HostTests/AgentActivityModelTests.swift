import XCTest
import NOWAgentIntegration
@testable import Host

/// The Agent page's words and its stream, tested where they are decided —
/// in the model — so the sentences a person reads are a fact rather than a
/// screenshot somebody took once.
@MainActor
final class AgentActivityModelTests: XCTestCase {

    // MARK: - The resting state

    /// **The state the page spends most of its life in, on most Macs.**
    ///
    /// A struct of zeroes rendered into the same table as an idle companion
    /// reads as a feature that failed to load, which is why the presence
    /// type keeps `neverAttached` as its own case. The reading has to spend
    /// that: its own sentences, and NO counters.
    func testNothingHasEverAttachedIsNotDrawnAsZeroes() {
        let reading = AgentPresenceReading(.none, asOf: Date())
        XCTAssertFalse(reading.showsCounters,
                       "Zero counters read as broken; this state has words.")
        XCTAssertEqual(reading.tone, .resting)
        XCTAssertFalse(reading.detail.contains("0"),
                       "No count belongs in the never-attached sentence.")
        // It says what is true and what would appear, rather than nothing.
        XCTAssertTrue(reading.detail.contains("Nothing is driving this Mac"),
                      reading.detail)
        XCTAssertTrue(reading.detail.contains("this page is where its work "
                                              + "appears"),
                      reading.detail)
    }

    /// Nothing has ever attached and nothing is attached now are different
    /// sentences. If they ever render the same, the pane reads as broken on
    /// the Mac where the first one is permanently true.
    func testNeverAttachedAndIdleAreDifferentSentences() {
        let now = Date()
        let idle = AgentPresenceReading(
            .init(totalRequests: 3,
                  lastSeen: now.addingTimeInterval(-3600)),
            asOf: now)
        let never = AgentPresenceReading(.none, asOf: now)
        XCTAssertNotEqual(never.headline, idle.headline)
        XCTAssertNotEqual(never.detail, idle.detail)
        XCTAssertTrue(idle.showsCounters,
                      "A companion that HAS attached has counts to show.")
        XCTAssertTrue(idle.detail.contains("1 hour ago"), idle.detail)
    }

    /// An endpoint that never opened reports the same `.neverAttached` — it
    /// is the honest reading, nothing reached it — so the page has to carry
    /// the reason separately or it prints a socket path to a file that does
    /// not exist.
    func testAFailedEndpointIsItsOwnStateRatherThanAnEmptyPage() {
        let model = AgentActivityModel()
        XCTAssertEqual(model.endpoint, .unopened)
        model.endpointUnavailable("Refusing to replace an unsafe endpoint")
        XCTAssertEqual(
            model.endpoint,
            .unavailable("Refusing to replace an unsafe endpoint"))
        model.endpointOpened(at: "/tmp/x/host.sock")
        XCTAssertEqual(model.endpoint, .open(path: "/tmp/x/host.sock"))
    }

    // MARK: - The server's lifecycle, which the MCP pane owns

    /// **Stopped is not "never started", and neither is "did not start".**
    ///
    /// The MCP pane draws one line off this state and offers one button, so
    /// three different reasons the socket is absent have to stay three
    /// states: a person whose client cannot connect is told whether they
    /// switched it off, whether it failed, or whether it has yet to run.
    func testAServerStoppedByHandIsItsOwnStateAndNotAFailure() {
        let model = AgentActivityModel()
        model.endpointOpened(at: "/tmp/x/host.sock")
        XCTAssertTrue(model.endpoint.isRunning)

        model.endpointStopped()

        XCTAssertEqual(model.endpoint, .stopped)
        XCTAssertFalse(model.endpoint.isRunning,
                       "A stopped server offers Start, never Stop.")
        XCTAssertNotEqual(model.endpoint, .unopened)
        for state in [AgentEndpointState.unopened, .stopped,
                      .unavailable("no")] {
            XCTAssertFalse(state.isRunning,
                           "\(state) is not a server anyone can reach.")
        }
    }

    /// **Closing the door does not erase what came through it.** The record
    /// of an agent's calls is the reason the pane exists; a stop that
    /// cleared it would lose exactly the history somebody stops the server
    /// to go and read.
    func testStoppingTheServerKeepsWhatAnAgentAlreadyDid() {
        let model = AgentActivityModel()
        model.endpointOpened(at: "/tmp/x/host.sock")
        model.record(
            HostProjectionAuditEvent(
                capability: ListProcessesProjection.capability, face: .mcp,
                guest: "PB 180c", outcome: .answered, reason: nil),
            drivenGuest: nil)

        model.endpointStopped()

        XCTAssertEqual(model.events.count, 1)
        XCTAssertEqual(model.events.first?.capability,
                       ListProcessesProjection.capability.rawValue)
    }

    // MARK: - Presence that changes with nothing happening

    /// The ledger publishes on every change, which covers every transition
    /// that HAPPENS. This one does not happen: the same activity, unread and
    /// untouched, crosses from attached to not-attached on the clock alone.
    /// It is why the reading takes a clock and why the pane re-derives on a
    /// schedule rather than on the publisher.
    func testAttachedDecaysToIdleWithNothingHappening() {
        let spoke = Date()
        let activity = AgentCompanionActivity(totalRequests: 1,
                                              firstSeen: spoke,
                                              lastSeen: spoke)
        let inside = AgentPresenceReading(
            activity,
            asOf: spoke.addingTimeInterval(
                AgentCompanionActivity.activeWindow - 1))
        let outside = AgentPresenceReading(
            activity,
            asOf: spoke.addingTimeInterval(
                AgentCompanionActivity.activeWindow + 1))
        XCTAssertEqual(inside.tone, .attached)
        XCTAssertEqual(outside.tone, .resting)
        XCTAssertNotEqual(inside.headline, outside.headline)
    }

    /// A request in flight beats the clock: a companion whose last COMPLETED
    /// call was an hour ago but which is being served right now is working,
    /// not idle.
    func testAnInFlightCallReadsAsWorkingWhateverTheClockSays() {
        let reading = AgentPresenceReading(
            .init(totalRequests: 9, inFlight: 1,
                  lastSeen: Date().addingTimeInterval(-3600)),
            asOf: Date())
        XCTAssertEqual(reading.tone, .working)
        XCTAssertEqual(reading.headline, "An agent is working now")
    }

    func testElapsedIsWrittenOutRatherThanFormatted() {
        let now = Date()
        func text(_ ago: TimeInterval) -> String {
            AgentPresenceReading.elapsed(now.addingTimeInterval(-ago),
                                         to: now)
        }
        XCTAssertEqual(text(2), "just now")
        XCTAssertEqual(text(30), "30 seconds ago")
        XCTAssertEqual(text(60), "1 minute ago")
        XCTAssertEqual(text(600), "10 minutes ago")
        XCTAssertEqual(text(7200), "2 hours ago")
        XCTAssertEqual(text(86400 * 3), "3 days ago")
    }

    // MARK: - The stream

    /// The stream answers "what did it do", which the presence ledger
    /// deliberately refuses to record. It carries exactly the audit event's
    /// fields — and the row's own words for the capability, read from the
    /// registry rather than from a table kept here.
    func testAnEventCarriesTheRowsOwnWordsAndItsDestructiveHint() {
        let model = AgentActivityModel()
        model.record(
            HostProjectionAuditEvent(
                capability: GuestFilesMutateProjection.capability,
                face: .mcp, guest: nil, outcome: .answered),
            drivenGuest: "pb1400c")
        model.record(
            HostProjectionAuditEvent(
                capability: ListProcessesProjection.capability,
                face: .mcp, guest: "q950", outcome: .refused,
                reason: "now_list_processes accepts no arguments"),
            drivenGuest: "pb1400c")

        // Newest first: the question is asked in that order.
        XCTAssertEqual(model.events.first?.capability,
                       "now_list_processes")
        XCTAssertEqual(model.events.first?.machine, "q950",
                       "A named machine is the caller's, not the driven one.")
        XCTAssertEqual(model.events.first?.reason,
                       "now_list_processes accepts no arguments")
        XCTAssertEqual(model.events.first?.isDestructive, false)

        let mutation = try? XCTUnwrap(model.events.last)
        XCTAssertEqual(mutation?.isDestructive, true,
                       "The row declares itself destructive; the page reads "
                       + "that rather than deciding it again.")
        XCTAssertEqual(mutation?.machine, "pb1400c",
                       "An omitted selector resolves to the driven machine.")
        // The row's MCP title, less the product name it repeats.
        XCTAssertEqual(mutation?.title, "Change the Guest's Files")
        XCTAssertFalse(mutation?.title.contains("New Old World") ?? true)
    }

    /// Every registered capability has words, because the title comes from
    /// the row. A hand-kept list is the failure this derivation avoids: it
    /// would go stale one row at a time and nothing would fail.
    func testEveryRegisteredCapabilityHasWordsOfItsOwn() {
        for capability in HostProjectionRegistry.hostFaces.capabilities {
            let title = AgentActivityEvent.title(for: capability.rawValue)
            XCTAssertFalse(title.isEmpty, capability.rawValue)
            XCTAssertNotEqual(
                title, capability.rawValue,
                "\(capability.rawValue) fell back to its tool name, so its "
                + "row states no title for the MCP face.")
            XCTAssertFalse(title.contains("New Old World"), title)
        }
    }

    /// The page is the glance, not the record — the log is the record and
    /// keeps 2000 lines. So the stream is bounded, and drops the oldest.
    func testTheStreamIsBoundedAndDropsTheOldest() {
        let model = AgentActivityModel()
        for _ in 0..<(AgentActivityModel.rememberedEvents + 5) {
            model.record(
                HostProjectionAuditEvent(
                    capability: SessionHealthProjection.capability,
                    face: .mcp, guest: nil, outcome: .answered),
                drivenGuest: nil)
        }
        XCTAssertEqual(model.events.count,
                       AgentActivityModel.rememberedEvents)
        let ids = model.events.map(\.id)
        XCTAssertEqual(ids.first, AgentActivityModel.rememberedEvents + 4,
                       "Newest first.")
        XCTAssertEqual(ids.last, 5, "The oldest five are gone.")
    }

    /// One call, both readers. The log line and the pane row are composed
    /// from the same typed event at the same seam, so a reporting site
    /// cannot write one and forget the other — which is exactly how the
    /// visible half of rule 3 went missing for twelve capabilities.
    func testOneAuditCallReachesBothTheLogAndThePage() throws {
        let model = AgentActivityModel()
        let log = HostLog.shared
        let before = log.lines.count
        AgentIntegrationAuditLog.record(
            HostProjectionAuditEvent(
                capability: RevealItemProjection.capability,
                face: .mcp, guest: nil, outcome: .answered),
            drivenGuest: "pb1400c",
            stream: model)

        XCTAssertEqual(log.lines.count, before + 1)
        let line = try XCTUnwrap(log.lines.last?.text)
        XCTAssertTrue(line.contains("mcp now_reveal_item guest=pb1400c "
                                    + "answered"), line)
        XCTAssertEqual(model.events.count, 1)
        XCTAssertEqual(model.events.first?.capability, "now_reveal_item")
        XCTAssertEqual(model.events.first?.machine, "pb1400c")
    }

    // MARK: - The machine's own answer

    /// **Silence is not consent.** A guest that predates the field says
    /// nothing, and a build that omitted the agent features says `disabled`
    /// out loud — the whole reason the field is three-state. The page must
    /// never render the first as a yes.
    func testSilenceReadsAsAnAbsentAnswerRatherThanAYes() {
        let silent = AgentConsentReading(machine: "q950", access: nil)
        XCTAssertFalse(silent.isConsent)
        XCTAssertTrue(silent.detail.contains("Silence is not consent"),
                      silent.detail)
        // And it says who is proceeding anyway, rather than implying the
        // machine agreed to it.
        XCTAssertTrue(silent.detail.contains(
            "decision made on \(MachineNaming.thisMac)"), silent.detail)
        // And it names the machine that stayed silent rather than calling
        // it "this Mac" — the phrase the window around this row already
        // spends on the reader's own machine.
        XCTAssertTrue(silent.detail.lowercased().contains("q950"),
                      silent.detail)
        XCTAssertFalse(silent.detail.contains("This Mac"), silent.detail)
    }

    func testTheFourAnswersReadAsFourDifferentThings() {
        let readings = [
            AgentConsentReading(machine: "m", access: nil),
            AgentConsentReading(machine: "m", access: .disabled),
            AgentConsentReading(machine: "m", access: .readOnly),
            AgentConsentReading(machine: "m", access: .fullAccess),
            AgentConsentReading(machine: "m", access: .unrecognized("god")),
        ]
        XCTAssertEqual(Set(readings.map(\.title)).count, readings.count,
                       "Five states, five readings.")
        XCTAssertEqual(readings.map(\.isConsent),
                       [false, false, true, true, false],
                       "Only a tier this build can NAME is consent.")
        XCTAssertTrue(readings[1].detail.contains("says no"),
                      readings[1].detail)
        // A refusing machine is changed at the machine. There is no control
        // on this page, and the sentence says where one is.
        XCTAssertTrue(readings[1].detail.contains("not here"),
                      readings[1].detail)
        XCTAssertTrue(readings[4].title.contains("god"), readings[4].title)
    }
}
