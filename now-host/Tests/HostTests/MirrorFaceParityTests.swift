import XCTest
import MirrorKit
import NOWAgentIntegration
@testable import Host

/// **The Mirror window and the NOW MCP are two clients of one engine —
/// the claim, made into a gate.**
///
/// The arc that built the headless face verified it by driving each face
/// and checking that each worked. Both do. That ceremony has been
/// performed many times and it found neither of the defects that were
/// actually there on 2026-08-05:
///
/// - an act driven entirely over the agent socket was journalled
///   `source: human`, because the path it took re-entered `perform`
///   through an overload whose `source` defaults to a person;
/// - and MCP was told `id: "direct"` — *nothing will ever settle this* —
///   about the same act, which settled `confirmed` seconds later.
///
/// Both are the two faces disagreeing about a FIELD of one record.
/// Neither is visible from watching a face work. Both are visible in one
/// diff, which is what this file is: the same interaction driven through
/// `perform` twice against one engine, and the two records compared
/// field by field.
@MainActor
final class MirrorFaceParityTests: XCTestCase {

    // MARK: - A2: the record diff

    /// **Every field but `source` and `id`.**
    ///
    /// The comparison is by reflection rather than by a hand-written list
    /// of assertions, for the reason a hand-written list always fails: a
    /// field added to `MirrorOperation` next year would be outside it and
    /// nothing would say so. The field NAMES are asserted too, so growing
    /// the record breaks this test until someone decides which side of
    /// the diff the new field belongs on.
    func testTheTwoFacesRecordTheSameOperationForTheSameAct() async throws {
        let rig = try await Rig.make()
        defer { rig.tearDown() }

        let act = rig.finderOpen("Macintosh HD")
        guard case .brokered(let humanID) = rig.source.perform(
            act, source: .human) else {
            return XCTFail("the human face must reach the broker, or this "
                               + "test is comparing something else")
        }
        guard case .brokered(let mcpID) = rig.source.perform(
            act, source: .mcp) else {
            return XCTFail("the MCP face must reach the SAME broker; a "
                               + "direct-path answer here is slice 3's "
                               + "claim failing")
        }

        let records = rig.engine.operations.records
        let human = try XCTUnwrap(records.first { $0.id == humanID })
        let mcp = try XCTUnwrap(records.first { $0.id == mcpID })

        XCTAssertEqual(human.source, .human)
        XCTAssertEqual(mcp.source, .mcp,
                       "the face that drove it is the one thing the "
                           + "journal exists to remember")
        XCTAssertNotEqual(human.id, mcp.id, "two acts, two records")

        /* `enqueuedAt` is a wall clock and the two legs are microseconds
           apart, so it cannot be equal and is not a field either defect
           could hide in. Everything else must match exactly. */
        let ignored: Set<String> = ["id", "source", "enqueuedAt"]
        XCTAssertEqual(Self.fieldNames(of: human),
                       ["id", "source", "displayedSnapshotID",
                        "displayedSequence", "target", "postcondition",
                        "enqueuedAt", "dispatchedAt", "settledAt",
                        "settledSequence", "outcome", "reason"],
                       "MirrorOperation grew a field. Decide whether the "
                           + "two faces must agree about it, then add it "
                           + "here or to `ignored` — do not let it slip "
                           + "past the diff unnamed")
        let differences = Self.differences(between: human, and: mcp,
                                           ignoring: ignored)
        XCTAssertEqual(differences, [],
                       "the two faces produced different records for one "
                           + "act; that is the defect class this gate "
                           + "exists for")
    }

    /// The same claim one layer down, where it can be TOTAL: the executor
    /// mints the record, and with the id and the clock pinned the two
    /// faces' operations must be equal outright — no field list, so
    /// nothing can drift out of the comparison.
    func testTheExecutorMintsAnIdenticalOperationForEitherFace()
        async throws {
        let rig = try await Rig.make()
        defer { rig.tearDown() }

        let act = rig.finderOpen("Macintosh HD")
        let plan = InteractionPolicy.plan(for: act)
        let at = Date(timeIntervalSince1970: 1_000)
        func mint(_ source: MirrorOperationSource) throws -> MirrorOperation {
            try XCTUnwrap(MirrorActionExecutor.operation(
                for: act, plan: plan, engine: rig.engine, source: source,
                id: "pinned", at: at))
        }

        var mcp = try mint(.mcp)
        XCTAssertEqual(mcp.source, .mcp)
        mcp.source = .human
        XCTAssertEqual(try mint(.human), mcp,
                       "the face is the ONLY thing an operation may carry "
                           + "about who asked for it")
    }

    // MARK: - A1: a held act is not the direct path

    /// **The reply MCP got for the act that settled.**
    ///
    /// Live on 2026-08-05, `now_semantic_ui_act --gesture finderOpen` was
    /// answered `{"id": "direct", "outcome": "dispatched"}` while the
    /// Mirror page cycled normally against the same guest. The suspicion
    /// recorded at the time was that `shadowEngine` was nil on the MCP
    /// path — that every MCP act took the direct path and could never
    /// settle. It was not that. `shadowEngine` and `pinnedGuestKey` are
    /// written together and cleared together, and an act with no pin is
    /// refused by name before the engine is ever consulted, so a nil
    /// engine cannot produce this answer.
    ///
    /// What produces it is an act arriving mid-observation: it is HELD,
    /// its record does not exist yet, and the service used to read that
    /// absence as the direct path. `awaitsObservation: false` is the
    /// damage — it tells the only face that cannot see the screen to stop
    /// waiting for a settlement that is on its way.
    func testAnActHeldMidObservationIsNotReportedToMCPAsTheDirectPath()
        async throws {
        let rig = try await Rig.make(joined: false)   // mid-observation
        defer { rig.tearDown() }

        /* Built exactly as `HostAppState` builds it, so this is the real
           MCP entry point and not a second opinion about it. */
        let service = MirrorDriveService(
            scene: { rig.source.scene },
            perform: { rig.source.perform($0, source: .mcp) },
            journal: { rig.source.shadowEngine?.operations },
            cancel: { rig.source.cancelPendingActs() })

        let reply = service.drive(.init(gesture: .finderOpen,
                                        itemName: "Macintosh HD",
                                        container: "desktop"))
        let operation = try XCTUnwrap(reply.operation)

        XCTAssertNotEqual(operation.id, "direct",
                          "the act is held and will be brokered; `direct` "
                              + "says it can never settle")
        XCTAssertTrue(operation.awaitsObservation,
                      "this is the field that cost the live drive: it told "
                          + "MCP to give up on an act that settled "
                          + "`confirmed`")
        XCTAssertFalse(operation.settled)
    }

    /// The other half, so the gate above cannot be satisfied by calling
    /// everything held: the plans that genuinely carry no postcondition
    /// must still say so. `finderSelect` is one of the seven.
    func testAnActWithNoPostconditionStillReportsTheDirectPath()
        async throws {
        let rig = try await Rig.make()
        defer { rig.tearDown() }

        let service = MirrorDriveService(
            scene: { rig.source.scene },
            perform: { rig.source.perform($0, source: .mcp) },
            journal: { rig.source.shadowEngine?.operations },
            cancel: { rig.source.cancelPendingActs() })

        let reply = service.drive(.init(gesture: .finderSelect,
                                        itemName: "Macintosh HD",
                                        container: "desktop"))
        let operation = try XCTUnwrap(reply.operation)

        XCTAssertEqual(operation.id, "direct")
        XCTAssertFalse(operation.awaitsObservation,
                       "nothing will ever settle a select, and a caller "
                           + "that waited for one would wait forever")
    }

    // MARK: - A3: the owed attribution regression

    /// **An agent's act stays an agent's act through the wait.**
    ///
    /// The deferred branch of `perform` re-enters through
    /// `self.perform(interaction, source: source)`. Until 2026-08-05 it
    /// called the one-argument overload, whose `source` defaults to
    /// `.human` — so an MCP act unlucky enough to arrive while an
    /// observation was in flight was journalled as a person's. Measured
    /// live: a `finderOpen` driven entirely over the agent socket settled
    /// `confirmed` and recorded `source: human`. It was the only record in
    /// that host's journal, so there was nothing to confuse it with.
    ///
    /// The journal is the only thing that can tell the two faces apart
    /// after the fact. Reverting that one argument makes this fail.
    func testAnMCPActHeldMidObservationIsStillRecordedAsMCPs() async throws {
        let rig = try await Rig.make(joined: false)   // mid-observation
        defer { rig.tearDown() }

        let act = rig.finderOpen("Macintosh HD")
        XCTAssertEqual(rig.source.perform(act, source: .mcp), .held,
                       "the case only exists while an observation is in "
                           + "flight; if this dispatched, the harness is "
                           + "not reproducing it")
        XCTAssertTrue(rig.engine.operations.records.isEmpty,
                      "a held act has no record yet — which is exactly why "
                          + "the drive service could not tell it from the "
                          + "direct path")

        rig.harness.completeJoin(0)                   // the cycle clears
        try await waitUntil("the held act reaches the broker") {
            !rig.engine.operations.records.isEmpty
        }

        XCTAssertEqual(rig.engine.operations.records.count, 1)
        XCTAssertEqual(rig.engine.operations.records.first?.source, .mcp,
                       "an act driven over the agent socket was recorded "
                           + "as a person's")
    }

    /// And the person's act is still the person's, so the test above is
    /// not passing because everything became `.mcp`.
    func testAHumanActHeldMidObservationIsStillRecordedAsAPersons()
        async throws {
        let rig = try await Rig.make(joined: false)
        defer { rig.tearDown() }

        XCTAssertEqual(rig.source.perform(rig.finderOpen("Macintosh HD"),
                                          source: .human), .held)
        rig.harness.completeJoin(0)
        try await waitUntil("the held act reaches the broker") {
            !rig.engine.operations.records.isEmpty
        }

        XCTAssertEqual(rig.engine.operations.records.first?.source, .human)
    }

    // MARK: - the rig

    /// One connected guest, one engine, one published scene — and the
    /// choice that matters: whether the content join has completed. An
    /// act performed before it is HELD; after it, brokered.
    @MainActor
    private struct Rig {
        let listener: GuestListener
        let guest: FakeGuest
        let harness: MirrorCycleHarness
        let source: NOWMirrorSource
        let engine: MirrorStateEngine

        static func make(joined: Bool = true) async throws -> Rig {
            let (listener, guest) = try await connectedListener()
            try await waitUntil("the guest is the active Mac") {
                listener.activeKey != nil
            }
            let key = try XCTUnwrap(listener.activeKey)
            let harness = MirrorCycleHarness(activeKey: key)
            let source = NOWMirrorSource(
                listener: listener,
                engineRegistry: MirrorStateEngineRegistry(),
                act: AgentIntegrationActControl(
                    listener: listener, currentSessionID: { UUID() },
                    commandTimeout: 0.3),
                interval: 3_600,
                finderRefreshOverride: { _, _, completion in completion() },
                visibilityRefreshOverride: { _, _, completion in completion() },
                cycleIO: harness.io)

            source.start()
            harness.completeScene(0, with: .success(sceneDelivery(
                try identifiedSceneDocument(seq: 1), seq: 1, for: key)))
            if joined { harness.completeJoin(0) }

            return .init(listener: listener, guest: guest, harness: harness,
                         source: source,
                         engine: try XCTUnwrap(source.shadowEngine))
        }

        /// A double-click on a Finder icon on the desktop — the gesture
        /// `now_semantic_ui_act --gesture finderOpen` resolves to, built the
        /// same way `MirrorDriveService` builds it.
        func finderOpen(_ name: String) -> Interaction {
            .init(object: .finderItem(.init(name: name, container: nil,
                                            point: .init(x: 0, y: 0))),
                  gesture: .click(count: 2, mods: 0, at: .init(x: 0, y: 0)))
        }

        func tearDown() {
            guest.connection.cancel()
            listener.stop()
        }
    }

    // MARK: - the diff

    private static func fieldNames(of operation: MirrorOperation) -> [String] {
        Mirror(reflecting: operation).children.compactMap(\.label)
    }

    /// Field-by-field, by name, comparing the rendered value. Crude on
    /// purpose: it needs no per-field knowledge, so it cannot be out of
    /// date with the struct, and the failure names the field.
    private static func differences(between a: MirrorOperation,
                                    and b: MirrorOperation,
                                    ignoring: Set<String>) -> [String] {
        let left = Mirror(reflecting: a).children
        let right = Dictionary(uniqueKeysWithValues:
            Mirror(reflecting: b).children.compactMap { child in
                child.label.map { ($0, String(describing: child.value)) }
            })
        return left.compactMap { child -> String? in
            guard let label = child.label, !ignoring.contains(label) else {
                return nil
            }
            let mine = String(describing: child.value)
            guard let theirs = right[label], theirs == mine else {
                return "\(label): human=\(mine) mcp=\(right[label] ?? "—")"
            }
            return nil
        }
    }
}
