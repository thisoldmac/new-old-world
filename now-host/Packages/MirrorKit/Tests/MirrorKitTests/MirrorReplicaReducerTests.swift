import XCTest
@testable import MirrorKit

final class MirrorReplicaReducerTests: XCTestCase {
    private let session = MirrorGuestSession(guest: "maxbook",
                                             incarnation: "session-a")

    private func scene(
        seq: Int,
        processes: [(String, String, Bool)],
        windows: [(String, String, String)],
        processCoverage: Scene.CoverageStatus,
        windowCoverage: [String: Scene.CoverageStatus]
    ) -> Scene {
        let claims = [
            Scene.CoverageClaim(scope: "processes",
                                status: processCoverage),
        ] + windowCoverage.sorted(by: { $0.key < $1.key }).map {
            Scene.CoverageClaim(scope: "windows", owner: $0.key,
                                status: $0.value)
        }
        return Scene(
            version: 2, seq: seq, source: "peek", capturedAt: Double(seq),
            screen: .init(w: 640, h: 480),
            apps: processes.map {
                .init(psn: $0.1, name: $0.0, front: $0.2,
                      incarnation: $0.1, error: nil)
            },
            processes: processes.map {
                .init(psn: $0.1, name: $0.0, front: $0.2,
                      signature: $0.0 == "Finder" ? "MACS" : "NOW!",
                      incarnation: $0.1)
            },
            menubar: nil,
            windows: windows.map {
                let owner = $0.0
                return .init(
                    id: "\(owner)/\($0.1)#0", app: $0.2, psn: owner,
                    title: $0.1, kind: 0,
                    rect: .init(l: 10, t: 20, r: 300, b: 240),
                    front: false, z: 0, visible: true, controls: [],
                    dialogItems: nil, ref: "ref-\($0.1)", addr: 1,
                    incarnation: "\(owner)/window-\($0.1)",
                    text: nil, items: nil, display: nil)
            },
            desktopItems: nil,
            meta: .init(latencyMs: nil, bytes: nil, errors: [], plane: "p",
                        coverage: claims))
    }

    private func reduce(_ scene: Scene, previous: MirrorReplica? = nil,
                        session: MirrorGuestSession? = nil) throws
        -> MirrorReplica {
        let observation = GuestSceneObservation(
            session: session ?? self.session, scene: scene,
            receivedAt: Date(timeIntervalSince1970: Double(scene.seq)))
        switch MirrorReplicaReducer.reduce(observation, previous: previous) {
        case .accepted(let replica): return replica
        case .rejected(let reason): throw reason
        }
    }

    func testIncompleteAbsenceRetainsExpectedStaleAndInert() throws {
        let finder = "process-finder"
        let workshop = "process-now"
        let first = try reduce(scene(
            seq: 1,
            processes: [("Finder", finder, true),
                        ("New Old World", workshop, false)],
            windows: [(finder, "Macintosh HD", "Finder"),
                      (workshop, "Workshop", "New Old World")],
            processCoverage: .complete,
            windowCoverage: [finder: .complete, workshop: .complete]))

        let second = try reduce(scene(
            seq: 2, processes: [("Finder", finder, true)],
            windows: [(finder, "Macintosh HD", "Finder")],
            processCoverage: .partial,
            windowCoverage: [finder: .complete]), previous: first)

        let retained = try XCTUnwrap(second.applications[.init(
            session: session, incarnation: workshop)])
        XCTAssertEqual(retained.freshness, .expectedStale)
        XCTAssertFalse(retained.actionable)
        XCTAssertFalse(retained.app.front)
        XCTAssertNotNil(second.windows.values.first {
            $0.identity.process.incarnation == workshop
                && $0.freshness == .expectedStale && !$0.actionable
        })
    }

    func testCompleteScopedAbsenceTombstonesOnlyItsOwnedMembers() throws {
        let finder = "process-finder"
        let first = try reduce(scene(
            seq: 1, processes: [("Finder", finder, true)],
            windows: [(finder, "Macintosh HD", "Finder")],
            processCoverage: .complete,
            windowCoverage: [finder: .complete]))
        let second = try reduce(scene(
            seq: 2, processes: [("Finder", finder, true)], windows: [],
            processCoverage: .complete,
            windowCoverage: [finder: .complete]), previous: first)

        XCTAssertTrue(second.windows.isEmpty)
        XCTAssertEqual(second.tombstones.count, 1)
    }

    func testCompleteProcessCensusDeletesMissingProcess() throws {
        let finder = "process-finder"
        let workshop = "process-now"
        let first = try reduce(scene(
            seq: 1,
            processes: [("Finder", finder, true),
                        ("New Old World", workshop, false)],
            windows: [], processCoverage: .complete,
            windowCoverage: [finder: .complete, workshop: .complete]))
        let second = try reduce(scene(
            seq: 2, processes: [("Finder", finder, true)], windows: [],
            processCoverage: .complete,
            windowCoverage: [finder: .complete]), previous: first)

        XCTAssertNil(second.applications[.init(
            session: session, incarnation: workshop)])
    }

    func testSequenceAndSessionAreHardBoundaries() throws {
        let finder = "process-finder"
        let firstScene = scene(
            seq: 2, processes: [("Finder", finder, true)], windows: [],
            processCoverage: .complete,
            windowCoverage: [finder: .complete])
        let first = try reduce(firstScene)
        let old = GuestSceneObservation(
            session: session,
            scene: scene(seq: 1, processes: [], windows: [],
                         processCoverage: .complete, windowCoverage: [:]),
            receivedAt: Date())
        XCTAssertEqual(MirrorReplicaReducer.reduce(old, previous: first),
                       .rejected(.outOfOrder(last: 2, received: 1)))

        let other = GuestSceneObservation(
            session: .init(guest: "maxbook", incarnation: "session-b"),
            scene: firstScene, receivedAt: Date())
        XCTAssertEqual(MirrorReplicaReducer.reduce(other, previous: first),
                       .rejected(.sessionMismatch))
    }

    func testDigestIgnoresTransportTimeButTracksSemanticChange() throws {
        let finder = "process-finder"
        let base = try reduce(scene(
            seq: 1, processes: [("Finder", finder, true)], windows: [],
            processCoverage: .complete,
            windowCoverage: [finder: .complete]))
        let same = try reduce(scene(
            seq: 2, processes: [("Finder", finder, true)], windows: [],
            processCoverage: .complete,
            windowCoverage: [finder: .complete]), previous: base)
        XCTAssertEqual(base.snapshot.digest, same.snapshot.digest)

        let changed = try reduce(scene(
            seq: 3, processes: [("Finder renamed", finder, true)], windows: [],
            processCoverage: .complete,
            windowCoverage: [finder: .complete]), previous: same)
        XCTAssertNotEqual(same.snapshot.digest, changed.snapshot.digest)
    }

    func testBaseBarrierNeedsEveryOwnedWindowCollectionComplete() throws {
        let finder = "process-finder"
        let workshop = "process-now"
        let replica = try reduce(scene(
            seq: 1,
            processes: [("Finder", finder, true),
                        ("New Old World", workshop, false)],
            windows: [], processCoverage: .complete,
            windowCoverage: [finder: .complete, workshop: .partial]))

        XCTAssertFalse(replica.snapshot.baseComplete)
        XCTAssertTrue(try XCTUnwrap(replica.applications[.init(
            session: session, incarnation: workshop)]).actionable,
                      "process activation authority is independent of its "
                      + "window collection")
    }

    func testDuplicateTitlesRemainSeparateByWindowIncarnation() throws {
        let finder = "process-finder"
        var capture = scene(
            seq: 1, processes: [("Finder", finder, true)],
            windows: [(finder, "Untitled", "Finder"),
                      (finder, "Other", "Finder")],
            processCoverage: .complete,
            windowCoverage: [finder: .complete])
        capture.windows[1].title = "Untitled"
        capture.windows[1].id = "\(finder)/Untitled#1"
        capture.windows[1].incarnation = "\(finder)/window-second"

        let replica = try reduce(capture)
        XCTAssertEqual(replica.windows.count, 2)
        XCTAssertEqual(Set(replica.windows.keys.map(\.incarnation)).count, 2)
    }

    func testWindowSeenInsidePartialMembershipIsFreshButInert() throws {
        let finder = "process-finder"
        let replica = try reduce(scene(
            seq: 1, processes: [("Finder", finder, true)],
            windows: [(finder, "Macintosh HD", "Finder")],
            processCoverage: .complete,
            windowCoverage: [finder: .partial]))
        let window = try XCTUnwrap(replica.windows.values.first)

        XCTAssertEqual(window.freshness, .fresh)
        XCTAssertFalse(window.actionable)
        XCTAssertFalse(replica.snapshot.baseComplete)
    }

    func testCompatibleStructuredContentRetainsAndGeometryInvalidates() throws {
        let finder = "process-finder"
        var firstScene = scene(
            seq: 1, processes: [("Finder", finder, true)],
            windows: [(finder, "Macintosh HD", "Finder")],
            processCoverage: .complete,
            windowCoverage: [finder: .complete])
        firstScene.windows[0].display = [.init(op: "frameRect", ticks: 1)]
        let first = try reduce(firstScene)

        let retained = try reduce(scene(
            seq: 2, processes: [("Finder", finder, true)],
            windows: [(finder, "Macintosh HD", "Finder")],
            processCoverage: .complete,
            windowCoverage: [finder: .complete]), previous: first)
        XCTAssertEqual(retained.windows.values.first?.window.display?.count, 1)

        var movedScene = scene(
            seq: 3, processes: [("Finder", finder, true)],
            windows: [(finder, "Macintosh HD", "Finder")],
            processCoverage: .complete,
            windowCoverage: [finder: .complete])
        movedScene.windows[0].rect.r += 20
        let invalidated = try reduce(movedScene, previous: retained)
        XCTAssertNil(invalidated.windows.values.first?.window.display)
    }

    /// The desktop plane is a HOST contribution — no guest producer emits
    /// `desktopItems`, and every structural scene therefore omits the key
    /// honestly. It must survive the next structural scene the way a
    /// window's `items` does, and for the same reason: absent means "this
    /// producer does not report it", not "the desktop is empty".
    ///
    /// This is the whole of the long-standing defect. The roster read
    /// worked all along; the icons were published for the fraction of a
    /// second between the enrichment and the next poll, and the poll
    /// erased them — so `desktopItems` read nil on every drive while the
    /// Finder's own folder windows, which the replica retains per window
    /// record, kept theirs.
    func testDesktopItemsSurviveTheNextStructuralScene() throws {
        let finder = "process-finder"
        let first = try reduce(scene(
            seq: 1, processes: [("Finder", finder, true)],
            windows: [(finder, "Macintosh HD", "Finder")],
            processCoverage: .complete,
            windowCoverage: [finder: .complete]))

        var contribution = first.snapshot.scene
        contribution.desktopItems = [
            .init(name: "Macintosh HD", kind: "disk", type: nil,
                  creator: nil, x: 736, y: 28, placed: true, alias: false,
                  invisible: false),
            .init(name: "Trash", kind: "folder", type: nil, creator: nil,
                  x: 716, y: 510, placed: true, alias: false,
                  invisible: false),
        ]
        let enriched = try XCTUnwrap(
            MirrorReplicaReducer.enrich(contribution, previous: first))
        XCTAssertEqual(enriched.snapshot.scene.desktopItems?.count, 2)

        // The next ordinary poll. Its scene omits `desktopItems`, exactly
        // as every real guest scene does.
        let next = try reduce(scene(
            seq: 2, processes: [("Finder", finder, true)],
            windows: [(finder, "Macintosh HD", "Finder")],
            processCoverage: .complete,
            windowCoverage: [finder: .complete]), previous: enriched)

        XCTAssertEqual(
            next.snapshot.scene.desktopItems?.map(\.name),
            ["Macintosh HD", "Trash"],
            "a structural scene that never reports the desktop plane must "
                + "not delete it")
    }

    /// The other half of the same rule: a producer that DOES report the
    /// plane still speaks for it. Retention may not outrank an answer.
    func testAReportedDesktopPlaneWins() throws {
        let finder = "process-finder"
        let first = try reduce(scene(
            seq: 1, processes: [("Finder", finder, true)],
            windows: [(finder, "Macintosh HD", "Finder")],
            processCoverage: .complete,
            windowCoverage: [finder: .complete]))
        var contribution = first.snapshot.scene
        contribution.desktopItems = [
            .init(name: "Trash", kind: "folder", type: nil, creator: nil,
                  x: 716, y: 510, placed: true, alias: false,
                  invisible: false),
        ]
        let enriched = try XCTUnwrap(
            MirrorReplicaReducer.enrich(contribution, previous: first))

        var reporting = scene(
            seq: 2, processes: [("Finder", finder, true)],
            windows: [(finder, "Macintosh HD", "Finder")],
            processCoverage: .complete,
            windowCoverage: [finder: .complete])
        reporting.desktopItems = []
        let next = try reduce(reporting, previous: enriched)
        XCTAssertEqual(next.snapshot.scene.desktopItems, [],
                       "an empty array is a claim, and it must be kept")
    }

    func testV1CanDisplayButCannotDeleteOrAuthorize() throws {
        var legacy = scene(
            seq: 1, processes: [("Finder", "0.3", true)],
            windows: [("0.3", "Macintosh HD", "Finder")],
            processCoverage: .unavailable,
            windowCoverage: [:])
        legacy.version = 1
        legacy.meta.coverage = nil
        legacy.apps[0].incarnation = nil
        legacy.processes?[0].incarnation = nil
        legacy.windows[0].incarnation = nil

        let replica = try reduce(legacy)
        XCTAssertEqual(replica.snapshot.scene.apps.map(\.name), ["Finder"])
        XCTAssertEqual(replica.snapshot.scene.windows.map(\.title),
                       ["Macintosh HD"])
        XCTAssertFalse(replica.snapshot.baseComplete)
        XCTAssertTrue(replica.applications.isEmpty)
        XCTAssertTrue(replica.windows.isEmpty)
    }
}
