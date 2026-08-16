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

    // MARK: - The silent collision

    /// **THE DEFECT, AT ITS HOST-SIDE DEATH POINT.** Metal, 2026-08-16: a
    /// file dropped onto the guest whose name already existed there did
    /// nothing and said nothing. The guest refuses `code=exists` correctly
    /// and this Mac receives it; the failure arm then assigned `notice` and
    /// nothing else — no log line for a metal round to find.
    func testANameCollisionIsAuditedRatherThanOnlyAssignedToNotice() {
        let line = MirrorFileTransferModel.hostFileFailureAudit(
            code: "exists", name: "main.c",
            reason: "a file of that name is already there")
        XCTAssertEqual(line.level, .warn)
        XCTAssertTrue(line.body.contains("collision:"), line.body)
        XCTAssertTrue(line.body.contains("name=main.c"), line.body)
    }

    /// **THE DIALOG'S VOCABULARY IS NOT SPENT BEFORE THE DIALOG EXISTS.**
    /// `replaced` and `cancelled` are the words a person's decision earns
    /// (docs/open-issues.md, the collision ruling). Using either for a
    /// refusal nobody authored would make the dialog's arrival invisible in
    /// the log: a reader could not tell a person's choice from this Mac's
    /// silence. Today's line must read as the defect it describes.
    func testTheRefusalDoesNotClaimAnybodyDecidedAnything() {
        let line = MirrorFileTransferModel.hostFileFailureAudit(
            code: "exists", name: "main.c", reason: "already there")
        XCTAssertTrue(line.body.contains("refused-without-asking"), line.body)
        XCTAssertFalse(line.body.contains("cancelled"), line.body)
        XCTAssertFalse(line.body.contains("replaced"), line.body)
    }

    /// **`declined` IS CONSENT WORKING, NOT THE OLD DEFECT.** Once the guest
    /// asks a Mirror-drag drop before refusing it (`now_wire_put_pending_replace`
    /// / `now_wire_put_resolve_replace`), a person choosing to keep their file
    /// answers with `file.refuse code=declined`, not `exists`. That line must
    /// not read as the swallowed-dialog defect `exists` still reads as —
    /// conflating the two would make the fixed defect invisible again, which
    /// is exactly what the contract's own note about this pair warns against.
    func testADeclinedReplaceIsLoggedAsConsentNotAsTheOldDefect() {
        let line = MirrorFileTransferModel.hostFileFailureAudit(
            code: "declined", name: "main.c",
            reason: "somebody chose to keep the file already there")
        XCTAssertEqual(line.level, .info)
        XCTAssertTrue(line.body.contains("collision:"), line.body)
        XCTAssertTrue(line.body.contains("declined"), line.body)
        XCTAssertTrue(line.body.contains("name=main.c"), line.body)
        XCTAssertFalse(line.body.contains("refused-without-asking"), line.body)
    }

    /// A collision is not the only way a host→guest copy fails, and the
    /// others must not be dressed as one — they get the code they came with.
    func testAnOrdinaryRefusalKeepsItsOwnCodeAndIsNotCalledACollision() {
        let line = MirrorFileTransferModel.hostFileFailureAudit(
            code: "disk-full", name: "big.bin", reason: "no room")
        XCTAssertFalse(line.body.contains("collision"), line.body)
        XCTAssertTrue(line.body.contains("code=disk-full"), line.body)
        XCTAssertTrue(line.body.contains("reason=no room"), line.body)
    }

    func testStoppedGlobalMonitorCannotUseAssumeIsolated() throws {
        let adapter = try GateSource.hostSwift(
            "now-host/Sources/Host/AppKitContinuityPointerEnvironment.swift")
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
