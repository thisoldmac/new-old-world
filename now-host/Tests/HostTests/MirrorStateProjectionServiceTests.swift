import XCTest
import MirrorKit
import NOWAgentIntegration
@testable import Host

@MainActor
final class MirrorStateProjectionServiceTests: XCTestCase {
    private let key = GuestKey.synthetic("mirror-projection")

    private func scene(seq: Int, title: String = "Macintosh HD") throws
        -> Scene {
        let document = #"""
        {
          "version":2,"seq":\#(seq),"capturedAt":\#(seq),"source":"peek",
          "screen":{"w":640,"h":480},
          "apps":[{"psn":"0.3","name":"Finder","front":true,
                   "incarnation":"process-finder"}],
          "processes":[{"psn":"0.3","name":"Finder","front":true,
                         "signature":"MACS",
                         "incarnation":"process-finder"}],
          "windows":[{
            "id":"0.3/\#(title)#0","app":"Finder","psn":"0.3",
            "title":"\#(title)",
            "rect":{"l":10,"t":20,"r":300,"b":240},
            "front":true,"z":0,"visible":true,"controls":[],
            "ref":"window-ref",
            "incarnation":"process-finder/window-disk"
          }],
          "meta":{"errors":[],"coverage":[
            {"scope":"processes","status":"complete"},
            {"scope":"windows","owner":"process-finder",
             "status":"complete"}
          ]}
        }
        """#
        return try JSONDecoder().decode(Scene.self, from: Data(document.utf8))
    }

    private func service(_ registry: MirrorStateEngineRegistry)
        -> MirrorStateProjectionService {
        MirrorStateProjectionService(engines: registry,
                                     currentGuest: { self.key })
    }

    func testStatusAndSnapshotCarryTheEnginesExactIdentity() async throws {
        let registry = MirrorStateEngineRegistry()
        let engine = registry.engine(for: key)
        _ = engine.accept(try scene(seq: 7))
        let published = try XCTUnwrap(engine.snapshot)
        let originalEntries = engine.store.entries.count

        let status = await service(registry).read(.init(intention: .status))
        let snapshot = await service(registry).read(
            .init(intention: .snapshot))

        XCTAssertEqual(status.value?.current?.snapshotID, published.id)
        XCTAssertEqual(status.value?.current?.digest, published.digest)
        XCTAssertEqual(snapshot.value?.snapshot?.metadata,
                       status.value?.current)
        XCTAssertEqual(snapshot.value?.snapshot?.entities.map(\.id), [
            "process:process-finder",
            "window:process-finder:process-finder/window-disk",
        ])
        XCTAssertEqual(engine.store.entries.count, originalEntries,
                       "a projection read must publish no second snapshot")
    }

    func testFindUsesStableEngineEntitiesWithoutAnotherObserver() async throws {
        let registry = MirrorStateEngineRegistry()
        let engine = registry.engine(for: key)
        _ = engine.accept(try scene(seq: 1))

        let result = await service(registry).read(.init(
            intention: .find, query: "macintosh"))

        XCTAssertEqual(result.value?.matches?.count, 1)
        XCTAssertEqual(result.value?.matches?.first?.id,
                       "window:process-finder:process-finder/window-disk")
        XCTAssertEqual(result.value?.matches?.first?.freshness, "fresh")
        XCTAssertEqual(engine.store.entries.count, 1)
    }

    func testWaitReturnsTheNextSnapshotFromTheSameEngine() async throws {
        let registry = MirrorStateEngineRegistry()
        let engine = registry.engine(for: key)
        _ = engine.accept(try scene(seq: 1))
        let firstID = try XCTUnwrap(engine.snapshot?.id)
        let projection = service(registry)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 35_000_000)
            _ = engine.accept(try! self.scene(seq: 2, title: "System Folder"))
        }
        let result = await projection.read(.init(
            intention: .wait, afterSnapshotID: firstID, timeoutMs: 500))

        XCTAssertFalse(result.value?.timedOut ?? true)
        XCTAssertEqual(result.value?.current?.sequence, 2)
        XCTAssertEqual(result.value?.snapshot?.metadata.snapshotID,
                       engine.snapshot?.id)
        XCTAssertEqual(engine.store.entries.count, 2,
                       "only the test's authoritative observation publishes")
    }

    func testUnavailableEngineAndBoundedTimeoutAreExplicit() async throws {
        let registry = MirrorStateEngineRegistry()
        let absent = await service(registry).read(.init(intention: .status))
        XCTAssertEqual(absent.unavailable?.code,
                       "now-mirror-snapshot-unavailable")

        let engine = registry.engine(for: key)
        _ = engine.accept(try scene(seq: 1))
        let currentID = try XCTUnwrap(engine.snapshot?.id)
        let timedOut = await service(registry).read(.init(
            intention: .wait, afterSnapshotID: currentID, timeoutMs: 1))
        XCTAssertTrue(timedOut.value?.timedOut == true)
        XCTAssertEqual(timedOut.value?.current?.snapshotID, currentID)
        XCTAssertEqual(engine.store.entries.count, 1)
    }
}
