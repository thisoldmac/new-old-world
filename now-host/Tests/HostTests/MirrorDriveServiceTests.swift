import XCTest
import MirrorKit
import NOWAgentIntegration
@testable import Host

/// **The reply an agent gets when it drives the Mirror.**
///
/// This surface had no tests at all, which is how it came to tell a
/// caller `dispatched` for an act the host had explicitly declined. The
/// defect was invisible from inside: `perform` reported the reason to the
/// Mirror's status line — which a person reads and a headless caller
/// cannot — and the service inferred an outcome from the ABSENCE of a
/// broker record, a signal that "refused before dispatch" and "took the
/// direct path" both produce.
@MainActor
final class MirrorDriveServiceTests: XCTestCase {

    /// Measured live 2026-08-05 against a guest whose interaction plane
    /// had never armed: `acts.log` carried `NOT DISPATCHED: Interaction
    /// policy is off` and the same act answered MCP `outcome: dispatched`.
    func testARefusedActIsNotReportedAsDispatched() throws {
        var asked: [Interaction] = []
        let service = MirrorDriveService(
            scene: { try? self.makeScene() },
            perform: { interaction in
                asked.append(interaction)
                return .refused("Interaction is off; the Mirror is read-only.")
            },
            journal: { nil }, cancel: { 0 })

        let reply = service.drive(.init(gesture: .finderOpen,
                                        itemName: "Macintosh HD",
                                        container: "desktop"))
        let operation = try XCTUnwrap(reply.operation)

        XCTAssertEqual(operation.outcome, "refused")
        XCTAssertEqual(operation.reason,
                       "Interaction is off; the Mirror is read-only.")
        XCTAssertTrue(operation.settled,
                      "nothing is coming; a caller must not poll for it")
        XCTAssertFalse(operation.awaitsObservation)
        XCTAssertEqual(asked.count, 1,
                       "the refusal must come from the real dispatch door, "
                           + "not from a second opinion about it")
    }

    /// The other half, and the reason the absence of a record cannot carry
    /// this meaning alone: an act that DID leave by the direct path has no
    /// typed postcondition and no journal record either, and it is not a
    /// refusal.
    func testAnActThatLeftByTheDirectPathStillReadsAsDispatched() throws {
        let service = MirrorDriveService(
            scene: { try? self.makeScene() },
            perform: { _ in .direct },
            journal: { nil }, cancel: { 0 })

        let reply = service.drive(.init(gesture: .finderSelect,
                                        itemName: "Macintosh HD",
                                        container: "desktop"))
        let operation = try XCTUnwrap(reply.operation)

        XCTAssertEqual(operation.outcome, "dispatched")
        XCTAssertEqual(operation.id, "direct")
        XCTAssertNil(operation.reason)
        XCTAssertFalse(operation.awaitsObservation,
                       "the direct path can never be confirmed by observation")
    }

    /// **The third ending that used to be `nil` too**, and the one that
    /// cost a live drive: an act arriving while an observation is in
    /// flight is HELD, so no record exists yet. The old service diffed
    /// the journal, found nothing, and answered `id: "direct",
    /// awaitsObservation: false` — *stop waiting, this can never settle*
    /// — about the exact act that went on to settle `confirmed`
    /// (2026-08-05).
    func testAHeldActIsNotReportedAsTheDirectPath() throws {
        let service = MirrorDriveService(
            scene: { try? self.makeScene() },
            perform: { _ in .held },
            journal: { MirrorOperationJournal() },   // empty, as it is then
            cancel: { 0 })

        let reply = service.drive(.init(gesture: .finderOpen,
                                        itemName: "Macintosh HD",
                                        container: "desktop"))
        let operation = try XCTUnwrap(reply.operation)

        XCTAssertNotEqual(operation.id, "direct",
                          "a held act is not the direct path; the absence "
                              + "of a record is what makes them look alike")
        XCTAssertEqual(operation.outcome, "queued")
        XCTAssertFalse(operation.settled)
        XCTAssertTrue(operation.awaitsObservation,
                      "the record is coming and it settles by observation; "
                          + "false here is what tells a caller to give up")
    }

    /// And a brokered act is fetched by the id `perform` returned, rather
    /// than by looking for a record that resembles the request. The old
    /// code took `records.last { !before.contains($0.id) }`, which is a
    /// guess whenever anything else appended concurrently.
    func testABrokeredActIsFetchedByItsOwnID() throws {
        let journal = MirrorOperationJournal()
        let wanted = try makeOperation(id: "wanted")
        _ = journal.append(try makeOperation(id: "someone-elses"))
        _ = journal.append(wanted)

        let service = MirrorDriveService(
            scene: { try? self.makeScene() },
            perform: { _ in .brokered("wanted") },
            journal: { journal }, cancel: { 0 })

        let reply = service.drive(.init(gesture: .finderOpen,
                                        itemName: "Macintosh HD",
                                        container: "desktop"))

        XCTAssertEqual(try XCTUnwrap(reply.operation).id, "wanted")
    }

    /// A refusal that happens BEFORE the dispatch door — an unresolvable
    /// name — still answers the older shape, and must not be turned into
    /// an operation record by the change above.
    func testAnUnresolvableTargetIsStillAnUnavailableRatherThanAnOperation() {
        var performed = false
        let service = MirrorDriveService(
            scene: { try? self.makeScene() },
            perform: { _ in performed = true; return .direct },
            journal: { nil }, cancel: { 0 })

        let reply = service.drive(.init(gesture: .select,
                                        entityID: "window:not-on-this-mac"))

        XCTAssertNil(reply.operation)
        XCTAssertFalse(reply.available)
        XCTAssertFalse(performed,
                       "a name the snapshot does not carry never reaches "
                           + "the dispatch door")
    }

    /// **A cancel must be reachable from the exact situation it exists
    /// for: a wedged guest publishing nothing.** Gating it on the scene
    /// guard would make the escape hatch unreachable when the machine is
    /// deaf — so it is served first, touches no entity, and never reaches
    /// the dispatch door.
    func testACancelEndsTheLaneWithoutASceneAndWithoutDispatching() throws {
        var performed = false
        var cancelled = false
        let service = MirrorDriveService(
            scene: { nil },                    // the wedged case: no scene
            perform: { _ in performed = true; return .direct },
            journal: { nil },
            cancel: { cancelled = true; return 3 })

        let reply = service.drive(.init(gesture: .cancel))
        let operation = try XCTUnwrap(reply.operation)

        XCTAssertTrue(cancelled)
        XCTAssertFalse(performed,
                       "a cancel acts on the host's lane, never the guest")
        XCTAssertEqual(operation.outcome, "cancelled")
        XCTAssertTrue(operation.settled)
        XCTAssertFalse(operation.awaitsObservation)
        XCTAssertTrue(operation.reason?.contains("3 acts") == true,
                      operation.reason ?? "(no reason)")
    }

    func testACancelWithNothingWaitingSaysSo() throws {
        let service = MirrorDriveService(
            scene: { nil },
            perform: { _ in .direct },
            journal: { nil },
            cancel: { 0 })

        let reply = service.drive(.init(gesture: .cancel))
        let operation = try XCTUnwrap(reply.operation)

        XCTAssertEqual(operation.reason, "nothing was waiting")
        XCTAssertTrue(operation.settled)
    }

    private func makeOperation(id: String) throws -> MirrorOperation {
        let process = MirrorProcessIdentity(
            session: .init(guest: "test", incarnation: "boot-1"),
            incarnation: "finder")
        return .init(id: id, source: .mcp, displayedSnapshotID: 1,
                     displayedSequence: 1, target: .process(process),
                     postcondition: .processFront(process),
                     enqueuedAt: Date(timeIntervalSince1970: 0))
    }

    private func makeScene() throws -> MirrorKit.Scene {
        do {
            let data = Data(#"""
            {"version":2,"seq":1,"capturedAt":1,"source":"peek",
             "screen":{"w":640,"h":480},
             "apps":[{"psn":"0.3","name":"Finder","front":true}],
             "desktopItems":[
              {"name":"Macintosh HD","kind":"disk","x":500,"y":40,
               "placed":true,"alias":false,"invisible":false}],
             "windows":[],
             "meta":{"errors":[]}}
            """#.utf8)
            return try JSONDecoder().decode(MirrorKit.Scene.self, from: data)
        }
    }
}
