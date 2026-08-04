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

    func testSameSequenceContentEnrichmentPublishesThroughTheEngine() throws {
        let engine = MirrorStateEngine(guestKey: key)
        let structural = try scene(seq: 1)
        _ = engine.accept(structural)
        let structuralSnapshot = try XCTUnwrap(engine.snapshot)

        var enriched = structural
        enriched.windows[0].display = [.init(op: "frameRect", ticks: 7)]
        XCTAssertTrue(engine.enrichContent(enriched))

        let contentSnapshot = try XCTUnwrap(engine.snapshot)
        XCTAssertEqual(contentSnapshot.scene.windows[0].display?.count, 1)
        XCTAssertEqual(contentSnapshot.sceneGeneration,
                       structuralSnapshot.sceneGeneration)
        XCTAssertEqual(contentSnapshot.contentGeneration,
                       structuralSnapshot.contentGeneration + 1)
        XCTAssertNotEqual(contentSnapshot.digest, structuralSnapshot.digest)
        XCTAssertEqual(engine.store.entries.count, 2)
    }

    func testEnrichmentCannotPatchAnotherSequenceOrGeometry() throws {
        let engine = MirrorStateEngine(guestKey: key)
        let structural = try scene(seq: 2)
        _ = engine.accept(structural)
        let snapshot = engine.snapshot

        var stale = try scene(seq: 1)
        stale.windows[0].display = [.init(op: "paintRect", ticks: 3)]
        XCTAssertFalse(engine.enrichContent(stale))
        XCTAssertEqual(engine.snapshot, snapshot)

        var wrongGeometry = structural
        wrongGeometry.windows[0].rect.r += 1
        wrongGeometry.windows[0].display = [.init(op: "paintRect", ticks: 4)]
        XCTAssertFalse(engine.enrichContent(wrongGeometry))
        XCTAssertEqual(engine.snapshot, snapshot)
    }

    func testNoOpEnrichmentDoesNotPublishAnotherSnapshot() throws {
        let engine = MirrorStateEngine(guestKey: key)
        let structural = try scene(seq: 1)
        _ = engine.accept(structural)

        XCTAssertFalse(engine.enrichContent(structural))
        XCTAssertEqual(engine.store.entries.count, 1)
        XCTAssertEqual(engine.snapshot?.contentGeneration, 0)
    }

    func testPlaneTogglesReprojectRetainedContentAndSemanticsWithoutRefetch()
        throws {
        let engine = MirrorStateEngine(guestKey: key)
        var observed = try scene(seq: 1)
        observed.windows[0].controls = [
            .init(ref: "control-ref", role: "control", title: "City",
                  enabled: true, visible: true,
                  semantic: .init(knowledge: .known, kind: "list",
                                  action: "select",
                                  provenance: "resident-p2",
                                  completeness: .complete)),
        ]
        var observedText = DisplayOp(op: "text", ticks: 7)
        observedText.text = "Abu Dhabi"
        observed.windows[0].display = [observedText]
        _ = engine.accept(observed)
        let full = try XCTUnwrap(engine.snapshot)

        XCTAssertTrue(engine.setEnabledPlanes([.structure, .interaction]))
        let structureOnly = try XCTUnwrap(engine.snapshot)
        XCTAssertNil(structureOnly.scene.windows[0].display)
        XCTAssertNil(structureOnly.scene.windows[0].controls[0].semantic)
        XCTAssertGreaterThan(structureOnly.id, full.id)

        XCTAssertTrue(engine.setEnabledPlanes(Set(MirrorPlaneID.allCases)))
        let restored = try XCTUnwrap(engine.snapshot)
        XCTAssertEqual(restored.scene.windows[0].display,
                       full.scene.windows[0].display)
        XCTAssertEqual(restored.scene.windows[0].controls[0].semantic,
                       full.scene.windows[0].controls[0].semantic)
        XCTAssertEqual(restored.sequence, full.sequence,
                       "a policy toggle must not masquerade as a guest poll")
        XCTAssertEqual(restored.contentGeneration, full.contentGeneration,
                       "reprojection does not mutate retained plane state")
    }

    func testBitmapOnlyContentCannotEraseRetainedStructuredDrawing() throws {
        let engine = MirrorStateEngine(guestKey: key)
        let structural = try scene(seq: 1)
        _ = engine.accept(structural)

        var structured = structural
        var city = DisplayOp(op: "text", ticks: 7)
        city.text = "City"
        city.pen = [12, 24]
        structured.windows[0].display = [
            .init(op: "state", ticks: 6), city,
        ]
        XCTAssertTrue(engine.enrichContent(structured))

        var bitmapOnly = structural
        bitmapOnly.windows[0].display = [
            .init(op: "bits", ticks: 8),
        ]
        XCTAssertTrue(engine.enrichContent(bitmapOnly))
        XCTAssertEqual(engine.snapshot?.scene.windows[0].display?.map(\.op),
                       ["bits", "state", "text"])
        XCTAssertEqual(engine.snapshot?.scene.windows[0].display?.last?.text,
                       "City")
    }

    func testUndrawableInvertCannotEraseRetainedStructuredDrawing() throws {
        let engine = MirrorStateEngine(guestKey: key)
        let structural = try scene(seq: 1)
        _ = engine.accept(structural)

        var structured = structural
        var origin = DisplayOp(op: "state", ticks: 6)
        origin.kind = "origin"
        origin.origin = [0, 0]
        var title = DisplayOp(op: "text", ticks: 7)
        title.text = "Search Sites"
        title.pen = [12, 24]
        structured.windows[0].display = [origin, title]
        XCTAssertTrue(engine.enrichContent(structured))

        var bitmapAndInvert = structural
        var bitmap = DisplayOp(op: "bits", ticks: 8)
        bitmap.dst = [0, 0, 300, 200]
        var invert = DisplayOp(op: "rect", ticks: 9)
        invert.rect = [10, 10, 30, 30]
        invert.verb = 3
        bitmapAndInvert.windows[0].display = [bitmap, invert]

        XCTAssertTrue(engine.enrichContent(bitmapAndInvert))
        XCTAssertEqual(engine.snapshot?.scene.windows[0].display?.map(\.op),
                       ["bits", "rect", "state", "text"])
        XCTAssertEqual(engine.snapshot?.scene.windows[0].display?.last?.text,
                       "Search Sites")
    }

    func testDisabledPlaneStillAcceptsNewEvidenceForLaterInterleaving() throws {
        let engine = MirrorStateEngine(guestKey: key)
        let structural = try scene(seq: 1)
        _ = engine.accept(structural)
        _ = engine.setEnabledPlanes([.structure, .interaction])

        var content = structural
        content.windows[0].display = [
            .init(op: "frameRect", ticks: 9),
        ]
        XCTAssertTrue(engine.enrichContent(content))
        XCTAssertNil(engine.snapshot?.scene.windows[0].display,
                     "disabled means hidden, not discarded")

        _ = engine.setEnabledPlanes(Set(MirrorPlaneID.allCases))
        XCTAssertEqual(engine.snapshot?.scene.windows[0].display?.map(\.op),
                       ["frameRect"])
    }

    func testInteractionPolicyCannotEraseTheOperationJournal() throws {
        let engine = MirrorStateEngine(guestKey: key)
        _ = engine.accept(try scene(seq: 1))
        let process = MirrorProcessIdentity(
            session: engine.session, incarnation: "process-finder")
        let operation = MirrorOperation(
            id: "op-retained", source: .human,
            displayedSnapshotID: try XCTUnwrap(engine.snapshot?.id),
            displayedSequence: 1, target: .process(process),
            postcondition: .processFront(process), enqueuedAt: Date())
        XCTAssertTrue(engine.operations.append(operation))

        _ = engine.setEnabledPlanes([.structure])
        _ = engine.setEnabledPlanes(Set(MirrorPlaneID.allCases))

        XCTAssertEqual(engine.operations.records, [operation],
                       "P4 policy gates mutation, never retained history")
    }

    func testProjectionDigestIgnoresObservationSequenceAndCaptureTime() throws {
        let engine = MirrorStateEngine(guestKey: key)
        _ = engine.accept(try scene(seq: 1))
        let first = try XCTUnwrap(engine.snapshot?.digest)

        _ = engine.accept(try scene(seq: 2))

        XCTAssertEqual(engine.snapshot?.digest, first,
                       "stable guest state must survive the gate's stability sandwich")
    }

    func testEvidenceExporterWritesFrameAndCorrelatedState() throws {
        let engine = MirrorStateEngine(guestKey: key)
        _ = engine.accept(try scene(seq: 1))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirror-evidence-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try MirrorEvidenceExporter(engine: engine).export(
            to: directory, framePNG: { Data([1, 2, 3]) })

        XCTAssertTrue(FileManager.default.fileExists(atPath:
            result.frameURL.path))
        let artifact = try JSONDecoder().decode(
            MirrorEvidenceExporter.StateArtifact.self,
            from: Data(contentsOf: result.stateURL))
        XCTAssertEqual(artifact.snapshotId, result.snapshotId)
        XCTAssertEqual(artifact.sceneGeneration, 1)
        XCTAssertEqual(artifact.contentGeneration, 0)
        XCTAssertEqual(artifact.sequence, 1)
    }

    func testEvidenceExporterRefusesAFrameAcrossSnapshotChange() throws {
        let engine = MirrorStateEngine(guestKey: key)
        _ = engine.accept(try scene(seq: 1))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirror-evidence-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertThrowsError(try MirrorEvidenceExporter(engine: engine)
            .export(to: directory, framePNG: {
                _ = engine.accept(try self.scene(seq: 2))
                return Data([1, 2, 3])
            })) { error in
                XCTAssertEqual(error as? MirrorEvidenceExporter.ExportError,
                               .snapshotChanged)
            }
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            directory.path), "a torn capture must publish no artifacts")
    }
}
