import MirrorKit
import XCTest
@testable import Host

@MainActor
final class MirrorFileTransferModelTests: XCTestCase {
    func testDesktopAndFinderSourcesStayDistinctOnTheWire() {
        let file = CrossMachineFileTargeting.FileIdentity(
            name: "Read Me", kind: "document", fileType: "TEXT",
            creator: "ttxt")
        XCTAssertEqual(
            MirrorFileTransferModel.wireSource(.desktop(file)),
            MirrorFileSource(kind: "desktop", name: "Read Me"))
        XCTAssertEqual(
            MirrorFileTransferModel.wireSource(
                .finderWindow(path: "Macintosh HD:Work", file: file)),
            MirrorFileSource(kind: "finder-window", name: "Read Me",
                             path: "Macintosh HD:Work"))
    }

    func testEveryReleaseTargetHasOneClosedWireIdentity() {
        XCTAssertEqual(MirrorFileTransferModel.wireTarget(.desktop),
                       MirrorFileDrop(kind: "desktop"))
        XCTAssertEqual(MirrorFileTransferModel.wireTarget(
            .finderFolder(path: "Macintosh HD:Work")),
            MirrorFileDrop(kind: "finder-folder",
                           path: "Macintosh HD:Work"))
        XCTAssertEqual(MirrorFileTransferModel.wireTarget(
            .applicationProcess(psn: "1:2", name: "SimpleText")),
            MirrorFileDrop(kind: "application-process", psn: "1:2",
                           name: "SimpleText"))
        XCTAssertEqual(MirrorFileTransferModel.wireTarget(
            .applicationCreator(creator: "ttxt", name: "SimpleText")),
            MirrorFileDrop(kind: "application-creator", creator: "ttxt",
                           name: "SimpleText"))
    }

    func testPromiseBatchKeepsSharedRootUntilEverySiblingFinishes() {
        let batch = MirrorFileTransferModel.PromiseBatch(
            root: URL(fileURLWithPath: "/tmp/promise-batch"),
            generation: 7, expectedCallbacks: 2)

        batch.callbackFinished(enqueued: true)
        batch.fileFinished()
        XCTAssertFalse(batch.isFinished,
                       "the second promise callback still owns the root")

        batch.callbackFinished(enqueued: true)
        XCTAssertFalse(batch.isFinished,
                       "the second materialized file still owns the root")
        batch.fileFinished()
        XCTAssertTrue(batch.isFinished)
    }

    func testStoppedGlobalMonitorCannotUseAssumeIsolated() throws {
        let source = try GateSource.hostSwift(
            "now-host/Sources/Host/ContinuityEdgeController.swift")
        let adapter = try XCTUnwrap(source.components(
            separatedBy: "@MainActor\nprotocol ContinuityEdgeDriving").first)
        XCTAssertFalse(adapter.contains("MainActor.assumeIsolated"))
        XCTAssertTrue(adapter.contains("monitorGeneration == generation"))
    }

    func testStalePreparationCannotClearTheCurrentGuestWorker() throws {
        let source = try GateSource.hostSwift(
            "now-host/Sources/Host/MirrorFileTransferModel.swift")
        let completion = try XCTUnwrap(source.range(
            of: "guard let self,\n                  generation == self.transferGeneration else { return }"))
        let stateMutation = try XCTUnwrap(source.range(
            of: "self.hostFilePreparationInFlight = false",
            range: completion.lowerBound..<source.endIndex))
        XCTAssertLessThan(completion.lowerBound, stateMutation.lowerBound,
                          "generation must be checked before worker state changes")
    }
}
