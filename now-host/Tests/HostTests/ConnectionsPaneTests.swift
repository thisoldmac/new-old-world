import XCTest
import NOWAgentIntegration
@testable import Host

/// **The link and who is on it are one page.**
///
/// They were two sidebar rows: "Connections" in the list (the roster of
/// machines) and "Connection" in the footer (the port and the state of the
/// link). Neither half stood up alone — the roster explained an empty page
/// by naming the port, and the link page explained the port by describing a
/// machine that would dial into it — and a person reading the sidebar had no
/// way to tell which of the two nearly-identically-named rows they wanted.
///
/// These guards are about the fold surviving: one row, in the footer, with
/// the link dot; one headline answering both halves in every state the link
/// can be in; and a saved selection of the retired id still landing on it.
@MainActor
final class ConnectionsPaneTests: XCTestCase {

    // MARK: - One row, not two

    /// The defect in one assertion: there is no longer a second module about
    /// connections. Restore the list descriptor and this fails naming it.
    func testTheSidebarHasOneRowAboutTheConnection() {
        let registry = ModuleRegistry.standard
        XCTAssertNil(registry.module(id: "connections"),
                     "the roster pane folded into the link pane; a second "
                     + "descriptor here is the split coming back")

        let about = registry.modules.filter {
            $0.title.lowercased().hasPrefix("connection")
        }
        XCTAssertEqual(about.map(\.id), ["settings"],
                       "exactly one module is named for the connection")
    }

    /// The survivor is the footer one, and it keeps the live link dot: the
    /// footer exists for the state of the link, and the roster came down to
    /// it rather than the link going up into the list.
    func testTheSurvivorKeepsTheFooterPlacementAndTheLinkDot() throws {
        let module = try XCTUnwrap(ModuleRegistry.standard
            .module(id: "settings"))
        XCTAssertEqual(module.placement, .footer)
        XCTAssertTrue(module.showsLinkStatus)
        XCTAssertEqual(ModuleRegistry.standard.modules
            .filter(\.showsLinkStatus).count, 1,
            "one module IS the link; the rest show their summary")
    }

    /// The summary has to promise both halves, or the sidebar sends a person
    /// looking for the roster somewhere else.
    func testTheSummaryPromisesBothHalves() throws {
        let summary = try XCTUnwrap(ModuleRegistry.standard
            .module(id: "settings")?.summary)
        XCTAssertTrue(summary.contains("port"),
                      "this side of the link: \(summary)")
        XCTAssertTrue(summary.contains(MachineNaming.properNounPlural),
                      "who is on it: \(summary)")
    }

    // MARK: - The retired id still resolves

    /// **A saved selection of the retired id lands on the merged page.**
    ///
    /// The selection is persisted by id. Somebody last looking at
    /// "connections" has that word in their preferences, and without a
    /// forwarding entry it resolves to nothing and the next launch drops
    /// them on the first module — which reads as the app forgetting them
    /// rather than as two pages becoming one.
    func testASavedSelectionOfTheRetiredIDLandsOnTheMergedPage() {
        XCTAssertEqual(ModuleRegistry.standard
            .resolvingRenames(id: "connections")?.id, "settings")
        XCTAssertEqual(ModuleRegistry.standard
            .resolvingRenames(id: "connections")?.title, "Connection")
    }

    /// The forwarding table is shared, and entries land in it from separate
    /// pieces of work. Every entry has to point at a module that exists and
    /// away from an id nothing still claims — checked for all of them, so
    /// one arriving beside another cannot quietly invalidate either.
    func testEveryForwardingEntryResolvesIncludingTheOnesAddedBeside() {
        XCTAssertFalse(ModuleRegistry.renamedIDs.isEmpty)
        for (old, new) in ModuleRegistry.renamedIDs {
            XCTAssertNil(ModuleRegistry.standard.module(id: old),
                         "\(old) was retired, so nothing may still claim it")
            XCTAssertNotNil(ModuleRegistry.standard.module(id: new),
                            "\(old) forwards to \(new), which must exist")
        }
    }

    // MARK: - One headline for every state the link can be in

    /// **The page's whole state matrix, in the one line that carries it.**
    ///
    /// Both panes used to draw a status line and the two were worded
    /// differently — the roster said how many machines, the link pane said
    /// whether the socket was up, and neither said both. The merged page has
    /// one, so it has to answer both halves in all four states.
    func testTheHeadlineAnswersBothHalvesInEveryState() {
        let notListening = snapshot(state: .idle, guests: [])
        XCTAssertEqual(notListening.headline, "Not listening")
        XCTAssertTrue(notListening.isIdle)

        let waiting = snapshot(state: .listening(port: 5250), guests: [])
        XCTAssertEqual(waiting.headline,
                       "Listening on 5250 — no old world mac connected",
                       "the port AND the emptiness, in one line")
        XCTAssertTrue(waiting.isIdle)

        let one = snapshot(state: .connected(guestName: "NOW 0.14"),
                           guests: [guest("pb1400c", active: true)])
        XCTAssertEqual(one.headline, "1 old world mac connected")
        XCTAssertNil(one.headline.range(of: "driving"),
                     "one machine is not a choice, so naming the driven one "
                     + "would dress it up as one")

        let several = snapshot(
            state: .connected(guestName: "NOW 0.14"),
            guests: [guest("q950"), guest("pb1400c", active: true, at: 5)])
        XCTAssertEqual(several.headline,
                       "2 old world macs connected — driving pb1400c",
                       "with a choice, the line says which way it went")
        XCTAssertEqual(several.driving?.machineID, "pb1400c")
    }

    /// The one word the merged page may not use for the machines it lists.
    ///
    /// This is the page that lists several machines, read from a Mac, so
    /// "no Mac connected" and "2 Macs connected" each had two readings and
    /// the wrong one was the alarming one. `MachineNaming` exists so the
    /// choice is a position rather than a phrase; this guard is what stops
    /// the phrase drifting back in.
    func testNoHeadlineCallsTheDrivenMachineAMac() {
        let lines = [
            snapshot(state: .listening(port: 5250), guests: []).headline,
            snapshot(state: .connected(guestName: "NOW 0.14"),
                     guests: []).headline,
            snapshot(state: .connected(guestName: "NOW 0.14"),
                     guests: [guest("pb1400c", active: true)]).headline,
            snapshot(state: .connected(guestName: "NOW 0.14"),
                     guests: [guest("q950"),
                              guest("pb1400c", active: true, at: 5)]).headline,
        ]
        for line in lines {
            XCTAssertFalse(line.contains("Mac connected"),
                           "\"\(line)\" names the wrong machine")
            XCTAssertFalse(line.contains("Macs connected"),
                           "\"\(line)\" names the wrong machine")
        }
    }

    // MARK: - Multi-guest, on the merged page

    /// Switching which machine is driven still moves the whole host through
    /// the one seam, and the page's headline follows it — the fold changed
    /// where the roster is drawn, not what choosing a row does.
    func testDrivingAnotherMachineStillMovesTheHostAndTheHeadline() {
        let listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"))
        var asked: [GuestKey] = []
        let model = ConnectionsModel(
            listener: listener,
            resolve: { _ in nil },
            select: { key in asked.append(key); return true })

        let before = snapshot(
            state: .connected(guestName: "NOW 0.14"),
            guests: [guest("pb1400c", active: true), guest("q950", at: 5)])
        XCTAssertEqual(before.headline,
                       "2 old world macs connected — driving pb1400c")

        let other = before.rows.first { $0.machineID == "q950" }!
        XCTAssertTrue(model.drive(other))
        XCTAssertEqual(asked, [GuestKey.synthetic("q950")])

        let after = snapshot(
            state: .connected(guestName: "NOW 0.14"),
            guests: [guest("pb1400c", at: 5), guest("q950", active: true)])
        XCTAssertEqual(after.headline,
                       "2 old world macs connected — driving q950")
    }

    /// A machine arriving or leaving while the page is open moves it between
    /// the roster and Remembered without either half of the page going
    /// stale: the link section is still the same link, and the headline
    /// re-answers who is on it.
    func testAMachineArrivingAndLeavingMovesBetweenTheHalves() throws {
        let empty = snapshot(state: .listening(port: 5250), guests: [],
                             known: [record("pb1400c")])
        XCTAssertTrue(empty.isIdle)
        XCTAssertEqual(empty.known.map(\.machineID), ["pb1400c"])
        XCTAssertTrue(empty.connected.isEmpty)

        let arrived = snapshot(state: .connected(guestName: "NOW 0.14"),
                               guests: [guest("pb1400c", active: true)],
                               known: [record("pb1400c")])
        XCTAssertFalse(arrived.isIdle)
        XCTAssertTrue(arrived.known.isEmpty,
                      "a remembered row never shadows the live machine")
        XCTAssertEqual(arrived.headline, "1 old world mac connected")

        let left = snapshot(state: .listening(port: 5250), guests: [],
                            known: [record("pb1400c")])
        XCTAssertEqual(left.headline,
                       "Listening on 5250 — no old world mac connected",
                       "a machine that left leaves the link up, not broken")
        XCTAssertEqual(try XCTUnwrap(left.known.first).presence, .known)
    }

    // MARK: - Fixtures

    private func snapshot(state: GuestListener.State,
                          guests: [ConnectedGuest],
                          known: [GuestRegistry.Record] = [])
        -> ConnectionsSnapshot {
        ConnectionsSnapshot.make(state: state, guests: guests, known: known,
                                 ended: [:], resolve: { _ in nil })
    }

    private func guest(_ id: String,
                       active: Bool = false,
                       at seconds: TimeInterval = 0) -> ConnectedGuest {
        ConnectedGuest(
            key: GuestKey.synthetic(id),
            id: GuestID(id)!,
            idIsAutoAssigned: false,
            idIsAnchored: true,
            name: "NOW 0.14",
            address: GuestAddress(text: "10.91.5.34"),
            version: "0.14",
            build: "b12",
            agentAccess: .readOnly,
            operatingSystem: "9.1",
            connectedAt: Date(timeIntervalSince1970: 1_000 + seconds),
            isActive: active)
    }

    private func record(_ id: String) -> GuestRegistry.Record {
        GuestRegistry.Record(
            id: GuestID(id)!, address: "10.91.5.34",
            fingerprint: "now|9.1", slot: 0, autoAssigned: false,
            lastSeen: Date(timeIntervalSince1970: 500), lastName: "NOW 0.13")
    }
}
