import AppKit
import XCTest
@testable import Host

/// The pure half of the Processes module: how a wire entry becomes a row.
/// The wire path itself is proven end to end by MetalProcessTests; this
/// pins the classification and formatting that a person reads.
@MainActor
final class ProcessesModelTests: XCTestCase {
    private func entry(_ name: String, kind: String, code: String? = nil,
                       creator: String? = nil, sizeKB: Int? = nil,
                       front: Bool? = nil) -> ProcessEntry {
        ProcessEntry(name: name, kind: kind, code: code, creator: creator,
                     sizeKB: sizeKB, front: front)
    }

    func testFinderGroupsWithApplicationsNotBackground() {
        // The Finder is an application; filing it under "Background"
        // would read as wrong to anyone who knows the machine.
        XCTAssertEqual(ProcessesModel.group(of: entry("Finder", kind: "finder")),
                       .applications)
        XCTAssertEqual(
            ProcessesModel.group(of: entry("NOW", kind: "application")),
            .applications)
        XCTAssertEqual(
            ProcessesModel.group(of: entry("Control Strip", kind: "background")),
            .background)
    }

    func testKindLabelIsFaceForward() {
        XCTAssertEqual(entry("Finder", kind: "finder").kindLabel, "Finder")
        XCTAssertEqual(entry("x", kind: "application").kindLabel, "Application")
        XCTAssertEqual(entry("x", kind: "background").kindLabel, "Background")
    }

    func testSignatureLabelJoinsBothCodesAndDropsBlanks() {
        XCTAssertEqual(
            entry("NOW", kind: "application", code: "APPL", creator: "NwWs")
                .signatureLabel, "APPL · NwWs")
        // The host's own mirror direction sends neither, so there is no
        // caption rather than a lone separator.
        XCTAssertNil(entry("NOW", kind: "application").signatureLabel)
        XCTAssertNil(entry("NOW", kind: "application", code: "", creator: "")
            .signatureLabel)
        XCTAssertEqual(
            entry("x", kind: "application", code: "APPL").signatureLabel,
            "APPL")
    }

    func testSizeLabelPicksTheLegibleUnit() {
        XCTAssertEqual(entry("x", kind: "application", sizeKB: 512).sizeLabel,
                       "512 KB")
        XCTAssertEqual(entry("x", kind: "application", sizeKB: 3072).sizeLabel,
                       "3.0 MB")
        // A process with no size sent (or a nonsense zero) shows nothing,
        // not "0 KB".
        XCTAssertNil(entry("x", kind: "application", sizeKB: 0).sizeLabel)
        XCTAssertNil(entry("x", kind: "application").sizeLabel)
    }

    // MARK: - The list underneath the reader

    /// A stand-in wire: it answers a listing from whatever table the test
    /// last set, counts how many times it was asked, and hands back a
    /// capture on demand. Everything below needs rows in the model, and a
    /// listener with no session refuses every call before one arrives.
    private final class Fake {
        var table: [ProcessEntry] = []
        var listCalls = 0
        var shotCalls = 0
        var lastDepth: Int?
        var capture: Result<GuestListener.CaptureDelivery,
                            GuestListener.CaptureFailure>?
        /// What the far machine answers a drive verb with. Default is a
        /// bare refusal — ok:false with no reason, the case the page has to
        /// put words to itself.
        var driveResult: Result<ProcessResult, GuestListener.FileFailure> =
            .success(ProcessResult(id: 1, ok: false, reason: nil))

        func wire() -> ProcessWire {
            ProcessWire(
                list: { [self] _, done in
                    listCalls += 1
                    done(.success(ProcessListing(
                        id: listCalls, processes: table, more: false,
                        cursor: nil)))
                },
                drive: { [self] _, _, _, done in done(driveResult) },
                shoot: { [self] _, _, depth, done in
                    shotCalls += 1
                    lastDepth = depth
                    if let capture { done(capture) }
                })
        }
    }

    private func drivable(_ name: String, front: Bool? = nil) -> ProcessEntry {
        ProcessEntry(name: name, kind: "application", code: "APPL",
                     creator: name, sizeKB: 1024, front: front,
                     psnHigh: 0, psnLow: 7, isSelf: false)
    }

    private func connected(_ fake: Fake) -> ProcessesModel {
        let model = ProcessesModel(
            listener: GuestListener(
                identity: .init(version: "0.1-test", name: "Test Host")),
            capabilities: GuestCapabilityRecord(),
            wire: fake.wire())
        model.connection = .connected(named: "Zulu")
        return model
    }

    func testSelectionSurvivesAListThatRepaintsUnderneathIt() {
        let fake = Fake()
        fake.table = [drivable("Finder"), drivable("SimpleText")]
        let model = connected(fake)   // the connect refreshes on its own

        model.selection = fake.table[1].id
        XCTAssertEqual(model.selectedEntry?.name, "SimpleText")

        // An agent quits something elsewhere; the bus repaints this page.
        fake.table = [drivable("Finder"), drivable("SimpleText"),
                      drivable("Sherlock")]
        model.refresh()

        XCTAssertEqual(model.selection, fake.table[1].id)
        XCTAssertEqual(model.selectedEntry?.name, "SimpleText")
        XCTAssertEqual(model.subject, .running(fake.table[1]))
    }

    func testAVanishedSelectionKeepsItsLastFactsAndSaysSo() {
        let fake = Fake()
        let doomed = drivable("SimpleText")
        fake.table = [drivable("Finder"), doomed]
        let model = connected(fake)
        model.selection = doomed.id

        // It quit between one listing and the next.
        fake.table = [drivable("Finder")]
        model.refresh()

        // The highlight is NOT dropped and the pane is not emptied: the
        // details side keeps the last facts, flagged as no longer running.
        XCTAssertEqual(model.selection, doomed.id)
        XCTAssertNil(model.selectedEntry)
        XCTAssertEqual(model.subject, .gone(doomed))
    }

    func testPickingAnotherProcessLeavesTheGoneStateBehind() {
        let fake = Fake()
        let doomed = drivable("SimpleText")
        fake.table = [drivable("Finder"), doomed]
        let model = connected(fake)
        model.selection = doomed.id
        fake.table = [drivable("Finder")]
        model.refresh()
        XCTAssertEqual(model.subject, .gone(doomed))

        model.selection = fake.table[0].id
        XCTAssertEqual(model.subject, .running(fake.table[0]))
        model.selection = nil
        XCTAssertEqual(model.subject, .nothing)
    }

    // MARK: - Details / preview, without leaving the page

    private func delivery() throws -> GuestListener.CaptureDelivery {
        let blob: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7]
        let format = CaptureFormat(
            width: 4, height: 2, depth: 8, rowBytes: 4, bytes: blob.count,
            paletteBytes: 0, packed: false, captureMs: 0, encodeMs: 0)
        return GuestListener.CaptureDelivery(
            image: try CaptureDecoder.makeImage(blob: blob, format: format),
            format: format, transferMs: 3, wireBytes: blob.count,
            guestName: "Zulu")
    }

    func testCaptureEntersThePreviewStateAndTheXReturns() throws {
        let fake = Fake()
        fake.capture = .success(try delivery())
        let target = drivable("SimpleText")
        fake.table = [target]
        let model = connected(fake)
        model.selection = target.id
        XCTAssertNil(model.preview)

        model.screenshotApp(target)

        // The picture is HERE. Nothing about this page's state says another
        // module was opened — the capture never went through one.
        XCTAssertEqual(fake.shotCalls, 1)
        XCTAssertNotNil(model.preview)
        XCTAssertEqual(model.previewOf, "SimpleText")
        XCTAssertEqual(model.subject, .running(target))

        model.dismissPreview()
        XCTAssertNil(model.preview)
        XCTAssertNil(model.previewOf)
        XCTAssertEqual(model.subject, .running(target))
    }

    func testCaptureNeverRoutesThroughTheScreenModule() throws {
        let fake = Fake()
        fake.capture = .success(try delivery())
        let target = drivable("SimpleText")
        fake.table = [target]
        let model = connected(fake)
        // The hook the app used to navigate with must not be pulled: firing
        // it is what took the reader to the Screen module.
        var navigated = false
        model.onScreenshotApp = { _, _ in navigated = true }

        model.screenshotApp(target)

        XCTAssertFalse(navigated)
        XCTAssertNotNil(model.preview)
    }

    func testCaptureAsksForTheDepthThisPageChose() throws {
        let fake = Fake()
        fake.capture = .success(try delivery())
        let target = drivable("SimpleText")
        fake.table = [target]
        let model = connected(fake)

        XCTAssertEqual(model.captureDepth, .indexed)
        model.captureDepth = .mono
        model.screenshotApp(target)
        XCTAssertEqual(fake.lastDepth, CaptureDepth.mono.rawValue)
    }

    func testSelectingAnotherProcessDropsThePicture() throws {
        let fake = Fake()
        fake.capture = .success(try delivery())
        let target = drivable("SimpleText")
        fake.table = [target, drivable("Finder")]
        let model = connected(fake)
        model.selection = target.id
        model.screenshotApp(target)
        XCTAssertNotNil(model.preview)

        model.selection = fake.table[1].id
        XCTAssertNil(model.preview)
    }

    func testCopyPutsTheShownCaptureOnThePasteboard() throws {
        let fake = Fake()
        fake.capture = .success(try delivery())
        let target = drivable("SimpleText")
        fake.table = [target]
        let model = connected(fake)
        model.screenshotApp(target)

        NSPasteboard.general.clearContents()
        model.copyPreview()
        XCTAssertTrue(NSPasteboard.general.canReadObject(
            forClasses: [NSImage.self], options: nil))
    }

    func testSavePreviewWritesAPNGAndReportsAFailure() throws {
        let fake = Fake()
        fake.capture = .success(try delivery())
        let target = drivable("SimpleText")
        fake.table = [target]
        let model = connected(fake)
        model.screenshotApp(target)

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(model.savePreview(to: url))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        XCTAssertNotNil(model.savePreview(
            to: URL(fileURLWithPath: "/does/not/exist/now-test.png")))
    }

    // MARK: - One read per connect

    func testSwitchingGuestsRefreshesExactlyOnce() {
        let fake = Fake()
        fake.table = [drivable("Finder")]
        let model = connected(fake)
        XCTAssertEqual(fake.listCalls, 1)

        model.connection = .connected(named: "Atlas")
        // Once. The view used to ask as well, on the same state change.
        XCTAssertEqual(fake.listCalls, 2)

        // A state that is not another machine reads nothing.
        model.connection = .disconnected
        XCTAssertEqual(fake.listCalls, 2)
        XCTAssertTrue(model.rows.isEmpty)
    }

    /// A refusal with no reason used to read "The Mac declined", which names
    /// neither of the two Macs in front of the reader.
    func testABareRefusalNamesTheMachineThatRefused() {
        let fake = Fake()
        let target = drivable("SimpleText")
        fake.table = [target]
        let model = connected(fake)

        model.askToQuit(target)
        XCTAssertEqual(model.lastError, "Zulu declined")

        // With no name yet, the proper noun stands where the name would.
        let unnamed = ProcessesModel(
            listener: GuestListener(
                identity: .init(version: "0.1-test", name: "Test Host")),
            capabilities: GuestCapabilityRecord(), wire: fake.wire())
        unnamed.connection = .connected(name: MachineNaming.properNoun,
                                        key: .synthetic("x"))
        unnamed.askToQuit(target)
        XCTAssertEqual(unnamed.lastError,
                       "\(MachineNaming.properNoun) declined")
    }
}
