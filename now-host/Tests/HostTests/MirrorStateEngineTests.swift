import XCTest
import MirrorKit
@testable import Host

@MainActor
final class MirrorStateEngineTests: XCTestCase {
    private let key = GuestKey.synthetic("maxbook")

    private func scene(seq: Int, includeWindow: Bool = true,
                       processStatus: String = "complete",
                       windowsStatus: String = "complete") throws -> Scene {
        let window = includeWindow ? #"""
        ,"windows":[{
          "id":"0.3/Macintosh HD#0","app":"Finder","psn":"0.3",
          "title":"Macintosh HD","rect":{"l":10,"t":20,"r":300,"b":240},
          "front":true,"z":0,"visible":true,"controls":[],
          "ref":"window-ref",
          "incarnation":"process-finder/window-disk"
        }]
        """# : #", "windows":[]"#
        let document = #"""
        {
          "version":2,"seq":\#(seq),"capturedAt":\#(seq),"source":"peek",
          "screen":{"w":640,"h":480},
          "apps":[{"psn":"0.3","name":"Finder","front":true,
                   "incarnation":"process-finder"}],
          "processes":[{"psn":"0.3","name":"Finder","front":true,
                         "signature":"MACS",
                         "incarnation":"process-finder"}]
          \#(window),
          "meta":{"errors":[],"coverage":[
            {"scope":"processes","status":"\#(processStatus)"},
            {"scope":"windows","owner":"process-finder",
             "status":"\#(windowsStatus)"},
            {"scope":"menubar","owner":"process-finder",
             "status":"unavailable"}
          ]}
        }
        """#
        return try JSONDecoder().decode(Scene.self, from: Data(document.utf8))
    }

    func testRegistryReturnsOneEnginePerExactSession() {
        let registry = MirrorStateEngineRegistry()
        let first = registry.engine(for: key)
        XCTAssertTrue(first === registry.engine(for: key))

        let successor = GuestKey(machine: key.machine, session: UUID())
        XCTAssertFalse(first === registry.engine(for: successor))
        XCTAssertEqual(registry.count, 2)
    }

    func testEnginePublishesDeletionSafeShadowSnapshots() throws {
        let engine = MirrorStateEngine(guestKey: key)
        _ = engine.accept(try scene(seq: 1),
                          receivedAt: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(engine.snapshot?.scene.windows.count, 1)
        XCTAssertTrue(engine.snapshot?.baseComplete == true)

        _ = engine.accept(try scene(seq: 2, includeWindow: false,
                                    windowsStatus: "partial"),
                          receivedAt: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(engine.snapshot?.scene.windows.count, 1,
                       "a partial miss retains the last guest-proven window")
        XCTAssertFalse(engine.replica?.windows.values.first?.actionable
                       ?? true)
    }

    func testOldSequenceIsRecordedAndDoesNotRepublish() throws {
        let engine = MirrorStateEngine(guestKey: key)
        _ = engine.accept(try scene(seq: 2))
        let snapshot = engine.snapshot
        _ = engine.accept(try scene(seq: 1, includeWindow: false))

        XCTAssertEqual(engine.lastRejection, .outOfOrder(last: 2, received: 1))
        XCTAssertEqual(engine.snapshot, snapshot)
        XCTAssertEqual(engine.store.entries.count, 1)
    }

    func testSnapshotHistoryIsBoundedByCountAndAge() throws {
        let store = MirrorSnapshotStore(limit: 3, maxAge: 10)
        let engine = MirrorStateEngine(guestKey: key, store: store)
        for seq in 1...4 {
            _ = engine.accept(try scene(seq: seq), receivedAt:
                Date(timeIntervalSince1970: Double(seq)))
        }
        XCTAssertEqual(store.entries.map(\.snapshot.sequence), [2, 3, 4])

        _ = engine.accept(try scene(seq: 5),
                          receivedAt: Date(timeIntervalSince1970: 30))
        XCTAssertEqual(store.entries.map(\.snapshot.sequence), [5])
    }

    func testShadowDifferenceIsBoundedAndNeverPatchesEitherSide() throws {
        let diagnostics = MirrorEngineDiagnostics(limit: 1)
        let engine = MirrorStateEngine(guestKey: key,
                                       diagnostics: diagnostics)
        let current = try scene(seq: 1)
        _ = engine.accept(current)
        let empty = try scene(seq: 2, includeWindow: false,
                              windowsStatus: "partial")
        engine.compareVisible(empty)
        engine.compareVisible(empty)

        XCTAssertEqual(diagnostics.differences.count, 1)
        XCTAssertEqual(diagnostics.differences[0].summary, "windows")
        XCTAssertEqual(current.windows.count, 1)
        XCTAssertEqual(empty.windows.count, 0)
    }
}
