import XCTest
import Network
import NOWAgentIntegration
@testable import Host

/// What the Connections page is allowed to say.
///
/// The page exists because an agent can address any connected Mac and a
/// person could see none of it. So these guards are about the facts the
/// page carries, not its pixels: that the three identities stay apart,
/// that all four addressing outcomes reach the person in the host's own
/// words, that a remembered machine can never shadow one on the wire, and
/// that zero connected reads as idle rather than as broken.
@MainActor
final class ConnectionsModelTests: XCTestCase {

    // MARK: - Fixtures

    private func guest(_ id: String,
                       name: String = "NOW 0.14",
                       address: String = "10.91.5.34",
                       active: Bool = false,
                       autoAssigned: Bool = false,
                       anchored: Bool = true,
                       at seconds: TimeInterval = 0) -> ConnectedGuest {
        let key = GuestKey.synthetic(id)
        return ConnectedGuest(
            key: key,
            id: GuestID(id)!,
            idIsAutoAssigned: autoAssigned,
            idIsAnchored: anchored,
            name: name,
            address: GuestAddress(text: address),
            version: "0.14",
            build: "b12",
            agentAccess: .readOnly,
            operatingSystem: "9.1",
            connectedAt: Date(timeIntervalSince1970: 1_000 + seconds),
            isActive: active)
    }

    private func record(_ id: String,
                        name: String = "NOW 0.13",
                        address: String = "10.91.5.2",
                        seen: TimeInterval = 0) -> GuestRegistry.Record {
        GuestRegistry.Record(
            id: GuestID(id)!, address: address,
            fingerprint: "now|9.1", slot: 0, autoAssigned: false,
            lastSeen: Date(timeIntervalSince1970: 500 + seen),
            lastName: name)
    }

    /// Stands in for the host's own `addressingRefusal` with the same
    /// shape: nil is answered, anything else is a typed refusal.
    private func resolver(driving: String?, connected: [String])
        -> (String) -> AgentIntegrationUnavailable? {
        { selector in
            guard let driving else { return .guest }
            if selector == driving { return nil }
            if let key = GuestKey.parse(selector) {
                if key.machine.slug == driving { return nil }
                if connected.contains(key.machine.slug) {
                    return .notAddressed(asking: key.machine.slug,
                                         driving: driving,
                                         connected: connected)
                }
                return .sessionEnded(selector)
            }
            if connected.contains(selector) {
                return .notAddressed(asking: selector, driving: driving,
                                     connected: connected)
            }
            return .notConnected(selector)
        }
    }

    // MARK: - The four addressing outcomes

    /// Answered, notAddressed, notConnected and sessionEnded exist because
    /// they are four different facts. The page has to carry all four, and
    /// it has to carry the host's OWN sentence for each — a person
    /// comparing what the pane says to what an agent was told must not
    /// have to translate between two wordings.
    func testEveryAddressingOutcomeReachesTheRowVerbatim() throws {
        let ended = ["pb180c": EndedGuestSession(
            machineID: "pb180c",
            sessionID: GuestKey.synthetic("pb180c").text,
            endedAt: Date(timeIntervalSince1970: 900))]
        let snapshot = ConnectionsSnapshot.make(
            state: .connected(guestName: "NOW 0.14"),
            guests: [guest("pb1400c", active: true),
                     guest("q950", at: 5)],
            known: [record("pb180c")],
            ended: ended,
            resolve: resolver(driving: "pb1400c",
                              connected: ["pb1400c", "q950"]))

        let driving = try XCTUnwrap(snapshot.driving)
        XCTAssertEqual(driving.byMachineID.outcome, .answered)
        XCTAssertEqual(driving.bySessionID?.outcome, .answered)
        XCTAssertNil(driving.byMachineID.message,
                     "an answer has no refusal to quote")

        let other = try XCTUnwrap(snapshot.rows.first { $0.machineID == "q950" })
        XCTAssertEqual(other.byMachineID.outcome, .notAddressed)
        XCTAssertEqual(other.bySessionID?.outcome, .notAddressed)
        XCTAssertEqual(other.byMachineID.message,
                       AgentIntegrationUnavailable.notAddressed(
                        asking: "q950", driving: "pb1400c",
                        connected: ["pb1400c", "q950"]).message,
                       "the host's own sentence, not a paraphrase")

        let gone = try XCTUnwrap(snapshot.rows.first { $0.machineID == "pb180c" })
        XCTAssertEqual(gone.byMachineID.outcome, .notConnected)
        XCTAssertEqual(gone.bySessionID?.outcome, .sessionEnded,
                       "a stale session id is refused as ended, which is a "
                       + "different fact from the machine being absent")
        XCTAssertEqual(gone.bySessionID?.message,
                       AgentIntegrationUnavailable
                        .sessionEnded(ended["pb180c"]!.sessionID).message)
    }

    /// With nothing connected the host answers "no guest", not "that Mac
    /// is not connected" — and the page must not fold the two together.
    func testNothingConnectedIsItsOwnOutcome() {
        let snapshot = ConnectionsSnapshot.make(
            state: .listening(port: 1400),
            guests: [],
            known: [record("pb1400c")],
            ended: [:],
            resolve: resolver(driving: nil, connected: []))

        XCTAssertTrue(snapshot.isIdle)
        XCTAssertEqual(snapshot.known.first?.byMachineID.outcome,
                       .noGuestConnected)
        XCTAssertEqual(snapshot.known.first?.byMachineID.message,
                       AgentIntegrationUnavailable.guest.message)
    }

    /// A refusal code this build has never seen must not be quietly filed
    /// under one it has. It is reported as unrecognised, with the code.
    func testAnUnknownRefusalCodeIsNotFoldedIntoAKnownOne() {
        let addressing = ConnectionAddressing(refusal:
            AgentIntegrationUnavailable(code: "now-guest-on-fire",
                                        message: "the Mac is on fire"))
        XCTAssertEqual(addressing.outcome,
                       .unrecognised(code: "now-guest-on-fire"))
        XCTAssertEqual(addressing.message, "the Mac is on fire")
    }

    // MARK: - The three identities

    /// Machine id, session id and address are three answers to three
    /// questions. A row that carried one of them where another belongs
    /// would mislead exactly when it matters, so each is its own field and
    /// none is derived from another.
    func testTheThreeIdentitiesStayApartOnTheRow() throws {
        let live = guest("pb1400c", address: "10.91.5.34", active: true)
        let snapshot = ConnectionsSnapshot.make(
            state: .connected(guestName: live.name),
            guests: [live], known: [], ended: [:],
            resolve: resolver(driving: "pb1400c", connected: ["pb1400c"]))

        let row = try XCTUnwrap(snapshot.driving)
        XCTAssertEqual(row.machineID, "pb1400c")
        XCTAssertEqual(row.liveSessionID, live.key.text)
        XCTAssertNotEqual(row.liveSessionID, row.machineID,
                          "the session is not the machine")
        XCTAssertEqual(row.address, "10.91.5.34")
        XCTAssertEqual(row.name, "NOW 0.14",
                       "what the Mac calls itself is a label, kept beside "
                       + "the handle and never in place of it")
    }

    /// The two hedges the identity design makes explicit — an id nobody
    /// has named, and an id the host cannot anchor — have to survive onto
    /// the page, or it draws a guess as a fact.
    func testUnnamedAndUnanchoredIdsAreCarriedNotSmoothedOver() throws {
        let emulated = guest("guest-1", address: "127.0.0.1",
                             active: true, autoAssigned: true,
                             anchored: false)
        let snapshot = ConnectionsSnapshot.make(
            state: .connected(guestName: emulated.name),
            guests: [emulated], known: [], ended: [:],
            resolve: resolver(driving: "guest-1", connected: ["guest-1"]))

        let row = try XCTUnwrap(snapshot.driving)
        XCTAssertTrue(row.idIsAutoAssigned)
        XCTAssertFalse(row.idIsAnchored)
    }

    /// A remembered machine at a loopback address is no more anchored than
    /// a live one there; the page must not read the registry's row as
    /// firmer than the connection it came from.
    func testARememberedLoopbackMachineIsNotDrawnAsAnchored() {
        let snapshot = ConnectionsSnapshot.make(
            state: .listening(port: 1400), guests: [],
            known: [record("guest-1", address: "127.0.0.1")],
            ended: [:],
            resolve: resolver(driving: nil, connected: []))

        XCTAssertEqual(snapshot.known.first?.idIsAnchored, false)
    }

    // MARK: - Known versus connected

    /// The registry remembers machines that are not here, and a remembered
    /// row must never shadow the machine actually on the wire — the same
    /// rule the listener keeps when it builds the roster from live
    /// sessions only.
    func testARememberedMachineCannotShadowTheConnectedOne() {
        let snapshot = ConnectionsSnapshot.make(
            state: .connected(guestName: "NOW 0.14"),
            guests: [guest("pb1400c", active: true)],
            known: [record("pb1400c", name: "NOW 0.9"), record("q950")],
            ended: [:],
            resolve: resolver(driving: "pb1400c", connected: ["pb1400c"]))

        XCTAssertEqual(snapshot.rows.filter { $0.machineID == "pb1400c" }
            .count, 1, "one row per machine, and it is the live one")
        XCTAssertEqual(snapshot.driving?.presence, .driving)
        XCTAssertEqual(snapshot.known.map(\.machineID), ["q950"])
    }

    /// Known-but-not-connected is a state the product owes the person: it
    /// can address machines by name, so it has to admit which names it
    /// knows and cannot currently reach.
    func testKnownMachinesAreListedWhenNothingIsConnected() {
        let snapshot = ConnectionsSnapshot.make(
            state: .listening(port: 1400), guests: [],
            known: [record("pb1400c"), record("q950")], ended: [:],
            resolve: resolver(driving: nil, connected: []))

        XCTAssertEqual(Set(snapshot.known.map(\.machineID)),
                       ["pb1400c", "q950"])
        XCTAssertTrue(snapshot.known.allSatisfy { $0.presence == .known })
        XCTAssertTrue(snapshot.known.allSatisfy { $0.key == nil },
                      "there is no session to drive or rename")
    }

    // MARK: - The resting state

    /// Zero connected is what most of an afternoon looks like. It reads as
    /// what the host is doing — the single most-cited UX defect in this
    /// repo is an idle state that reads as a fault.
    func testZeroGuestsReadsAsIdleNotAsFailure() {
        let listening = ConnectionsSnapshot.make(
            state: .listening(port: 1400), guests: [], known: [], ended: [:],
            resolve: resolver(driving: nil, connected: []))
        XCTAssertTrue(listening.isIdle)
        XCTAssertEqual(listening.headline,
                       "Listening on 1400 — no Mac connected")

        let stopped = ConnectionsSnapshot.make(
            state: .idle, guests: [], known: [], ended: [:],
            resolve: resolver(driving: nil, connected: []))
        XCTAssertEqual(stopped.headline, "Not listening")

        let broken = ConnectionsSnapshot.make(
            state: .failed("Port 1400 is already in use"),
            guests: [], known: [], ended: [:],
            resolve: resolver(driving: nil, connected: []))
        XCTAssertEqual(broken.headline, "Port 1400 is already in use",
                       "the only alarming line is an actual failure")
    }

    /// Idle is the ROSTER's answer, not the state's.
    ///
    /// The listener publishes its state and its roster separately, and a
    /// `@Published` fires before the value settles, so the two can be read
    /// a turn apart. If they disagree the page believes the roster: it is
    /// built from live sessions, and a page that drew "connected" from a
    /// stale state line would show a Mac with no row under it.
    func testIdleFollowsTheRosterWhenTheStateDisagrees() {
        let snapshot = ConnectionsSnapshot.make(
            state: .connected(guestName: "NOW 0.14"),
            guests: [], known: [], ended: [:],
            resolve: resolver(driving: nil, connected: []))

        XCTAssertTrue(snapshot.isIdle)
        XCTAssertEqual(snapshot.headline, "No Mac connected")
    }

    /// One Mac is the common case, and it must not be dressed up as a
    /// choice between machines.
    func testOneConnectedMacDoesNotReadAsAFleet() {
        let snapshot = ConnectionsSnapshot.make(
            state: .connected(guestName: "NOW 0.14"),
            guests: [guest("pb1400c", active: true)], known: [], ended: [:],
            resolve: resolver(driving: "pb1400c", connected: ["pb1400c"]))

        XCTAssertEqual(snapshot.headline, "1 Mac connected")
        XCTAssertFalse(snapshot.isIdle)
    }

    /// With two, the headline answers the question the page exists for:
    /// which one is being driven.
    func testTwoConnectedMacsNameTheOneBeingDriven() {
        let snapshot = ConnectionsSnapshot.make(
            state: .connected(guestName: "NOW 0.14"),
            /* The driven Mac arrived SECOND on purpose: sorted by
               connection time alone it would fall to the bottom, and the
               row a person is looking for would move whenever another
               machine dialled in. */
            guests: [guest("q950"), guest("pb1400c", active: true, at: 5)],
            known: [], ended: [:],
            resolve: resolver(driving: "pb1400c",
                              connected: ["pb1400c", "q950"]))

        XCTAssertEqual(snapshot.headline,
                       "2 Macs connected — driving pb1400c")
        XCTAssertEqual(snapshot.rows.first?.machineID, "pb1400c",
                       "the machine being driven leads, and does not move "
                       + "when another Mac dials in")
    }

    // MARK: - What a person can initiate

    /// Whatever an agent can do, a person should be able to initiate.
    /// An agent picks a Mac by naming it; a person picks by choosing a
    /// row, and the same seam moves the host either way.
    func testDrivingARowMovesTheHostThroughTheSameSeam() {
        let listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"))
        var asked: [GuestKey] = []
        let model = ConnectionsModel(
            listener: listener,
            resolve: resolver(driving: "pb1400c",
                              connected: ["pb1400c", "q950"]),
            select: { key in asked.append(key); return true })

        let row = ConnectionsSnapshot.make(
            state: .connected(guestName: "NOW 0.14"),
            guests: [guest("pb1400c", active: true), guest("q950", at: 5)],
            known: [], ended: [:],
            resolve: resolver(driving: "pb1400c",
                              connected: ["pb1400c", "q950"]))
            .rows.first { $0.machineID == "q950" }!

        XCTAssertTrue(model.drive(row))
        XCTAssertEqual(asked, [GuestKey.synthetic("q950")])
    }

    /// A control that cannot do anything is refused rather than faked: the
    /// Mac already being driven is not a change, and a remembered machine
    /// has no connection to point at.
    func testDrivingRefusesWhereThereIsNothingToMove() {
        let listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"))
        var asked = 0
        let model = ConnectionsModel(
            listener: listener,
            resolve: resolver(driving: "pb1400c", connected: ["pb1400c"]),
            select: { _ in asked += 1; return true })

        let snapshot = ConnectionsSnapshot.make(
            state: .connected(guestName: "NOW 0.14"),
            guests: [guest("pb1400c", active: true)],
            known: [record("q950")], ended: [:],
            resolve: resolver(driving: "pb1400c", connected: ["pb1400c"]))

        XCTAssertFalse(model.drive(snapshot.driving!),
                       "the Mac already being driven is not a change")
        XCTAssertFalse(model.drive(snapshot.known.first!),
                       "a remembered machine has no session to point at")
        XCTAssertEqual(asked, 0)
    }

    /// A rename failure has to say what to do about it. `taken` names the
    /// other machine, because "that id is in use" without saying by what
    /// leaves a person guessing which Mac to go and free first.
    func testRenameFailuresAreExplainedInTermsOfTheFix() {
        XCTAssertTrue(ConnectionsModel
            .explain(.taken(by: "PowerBook 180c"), proposed: "pb180c")
            .contains("PowerBook 180c"))
        XCTAssertTrue(ConnectionsModel
            .explain(.malformed, proposed: "my mac!")
            .contains("my mac!"))
        XCTAssertNotEqual(ConnectionsModel.explain(.notFound, proposed: "x"),
                          ConnectionsModel.explain(.malformed, proposed: "x"),
                          "three failures, three sentences")
        /* `notFound` is about the MACHINE having gone, not about the name
           that was typed, so quoting the name back would send a person
           looking for a fault in their typing. */
        XCTAssertEqual(ConnectionsModel.explain(.notFound, proposed: "pb180c"),
                       "That Mac is no longer connected.")
    }

    /// Renaming a machine that is not connected is refused with a reason
    /// rather than silently doing nothing — the listener owns the rename
    /// because it has to re-label the live session's row.
    func testRenamingARememberedMachineIsRefusedOutLoud() {
        let listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"))
        let model = ConnectionsModel(
            listener: listener,
            resolve: resolver(driving: nil, connected: []))
        let row = ConnectionsSnapshot.make(
            state: .listening(port: 1400), guests: [],
            known: [record("q950")], ended: [:],
            resolve: resolver(driving: nil, connected: [])).known.first!

        XCTAssertFalse(model.rename(row, to: "quadra"))
        XCTAssertEqual(model.renameProblem, "q950 is not connected.")
    }

    // MARK: - The model against a real listener

    /// The live path, end to end: a Mac dials in, the page grows a row
    /// for it, the Mac goes away, and the page keeps the session id long
    /// enough to say what a caller still holding it would be told.
    ///
    /// Written against a real listener and a real socket because the
    /// ledger is fed by watching the roster change — a unit test that
    /// handed the ledger its own entries would prove the formatting and
    /// not the watching.
    func testAMachineThatLeavesBecomesARememberedRowWithItsEndedSession()
        async throws {
        let listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"))
        let model = ConnectionsModel(
            listener: listener,
            resolve: { [weak listener] selector in
                // Nothing connected once it has gone, which is exactly the
                // host's own answer in that state.
                guard let listener, !listener.guests.isEmpty else {
                    return .guest
                }
                return GuestKey.parse(selector) == nil
                    ? .notConnected(selector) : .sessionEnded(selector)
            })
        let port: UInt16 = 52987
        listener.start(port: port)

        let deadline = Date().addingTimeInterval(8)
        func wait(_ cond: @escaping () -> Bool) async throws {
            while !cond(), Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        try await wait {
            if case .listening = listener.state { return true }
            return false
        }

        let guest = NWConnection(host: .ipv4(.loopback),
                                 port: NWEndpoint.Port(rawValue: port)!,
                                 using: .tcp)
        guest.start(queue: .main)
        let hello = try ControlMessageCodec.encode(.hello(
            Hello(contract: Contract.revision, side: "guest",
                  version: "0.1.0", name: "PowerBook 180c", os: "7.1",
                  chunk: 8192)))
        guest.send(content: try FrameCodec.encode(channel: .control,
                                                  payload: hello),
                   completion: .idempotent)

        /* Waited for on the MODEL, not on the listener: the page has to
           learn about the roster by subscribing to it. A test that called
           `refresh()` itself would pass with the subscription deleted. */
        try await wait { model.snapshot.driving != nil }
        let live = try XCTUnwrap(model.snapshot.driving,
                                 "the one connected Mac is the driven one")
        let session = try XCTUnwrap(live.liveSessionID)
        XCTAssertEqual(live.name, "PowerBook 180c")

        guest.cancel()
        try await wait { model.snapshot.isIdle }

        XCTAssertTrue(model.snapshot.isIdle,
                      "a Mac that left leaves the page idle, not broken")
        let remembered = try XCTUnwrap(
            model.snapshot.known.first { $0.machineID == live.machineID },
            "a machine the host has met is remembered by name")
        XCTAssertNil(remembered.liveSessionID)
        XCTAssertEqual(remembered.lastSessionID, session,
                       "the session id survives the connection, because "
                       + "that is the only thing that can answer a caller "
                       + "still holding it")
        listener.stop()
    }

    /// The empty page a fresh host draws: listening at nothing, no rows,
    /// and no invented machine.
    func testAFreshModelReadsTheListenerRatherThanGuessing() {
        let listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"))
        let model = ConnectionsModel(
            listener: listener,
            resolve: resolver(driving: nil, connected: []))

        XCTAssertEqual(model.snapshot.state, .idle)
        XCTAssertTrue(model.snapshot.rows.isEmpty)
        XCTAssertTrue(model.snapshot.isIdle)
        XCTAssertEqual(model.snapshot.headline, "Not listening")
    }
}
