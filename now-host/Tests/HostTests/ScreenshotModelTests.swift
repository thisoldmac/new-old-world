import AppKit
import XCTest
@testable import Host

@MainActor
final class ScreenshotModelTests: XCTestCase {
    private func makeModel() -> ScreenshotModuleModel {
        ScreenshotModuleModel(listener: GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host")))
    }
    func testSupportedDepthsMatchGuestContract() {
        XCTAssertEqual(CaptureDepth.allCases.map(\.rawValue),
                       [0, 1, 2, 4, 8, 16, 32])
        XCTAssertEqual(CaptureDepth.native.title, "Native")
        XCTAssertEqual(makeModel().selectedDepth, .native)
    }

    func testCaptureRequiresARealConnection() {
        let model = makeModel()
        XCTAssertFalse(model.canCapture)

        model.connection = .connecting
        XCTAssertFalse(model.canCapture)

        model.connection = .connected(named: "Power Mac")
        XCTAssertTrue(model.canCapture)
    }

    func testProgressFractionIsBoundedAndSafeAtZero() {
        XCTAssertEqual(GuestListener.CaptureProgress(
            received: 0, expected: 0).fraction, 0)
        XCTAssertEqual(GuestListener.CaptureProgress(
            received: 50, expected: 200).fraction, 0.25)
        // A guest that overshoots its own announced size must not push the
        // bar past full.
        XCTAssertEqual(GuestListener.CaptureProgress(
            received: 300, expected: 200).fraction, 1)
    }

    func testDeliverySettingsPersistAcrossModels() throws {
        let suite = "screenshots.test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removeSuite(named: suite) }
        let listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"))
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())

        let first = ScreenshotModuleModel(listener: listener,
                                          defaults: defaults)
        XCTAssertFalse(first.autoSave)
        XCTAssertFalse(first.autoCopy)
        first.autoSave = true
        first.autoCopy = true
        first.saveDirectory = dir

        let second = ScreenshotModuleModel(listener: listener,
                                           defaults: defaults)
        XCTAssertTrue(second.autoSave)
        XCTAssertTrue(second.autoCopy)
        XCTAssertEqual(second.saveDirectory.path, dir.path)
    }

    func testCopyPutsAnImageOnThePasteboard() throws {
        let model = makeModel()
        let blob: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7]
        let format = CaptureFormat(
            width: 4, height: 2, depth: 8, rowBytes: 4, bytes: blob.count,
            paletteBytes: 0, packed: false, captureMs: 0, encodeMs: 0)
        let record = ScreenshotRecord(
            capturedAt: Date(),
            image: try CaptureDecoder.makeImage(blob: blob, format: format),
            format: format, transferMs: 1, wireBytes: blob.count)

        NSPasteboard.general.clearContents()
        model.copyToPasteboard(record)
        XCTAssertTrue(NSPasteboard.general.canReadObject(
            forClasses: [NSImage.self], options: nil))
    }

    func testCancelIsIgnoredWhenNothingIsInFlight() {
        let model = makeModel()
        model.connection = .connected(named: "PowerBook 1400")
        model.cancel()
        XCTAssertNil(model.lastError)
    }

    func testWriteLandsAPNGAndNeverClobbers() throws {
        let model = makeModel()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let blob: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7]
        let format = CaptureFormat(
            width: 4, height: 2, depth: 8, rowBytes: 4, bytes: blob.count,
            paletteBytes: 0, packed: false, captureMs: 0, encodeMs: 0)
        let image = try CaptureDecoder.makeImage(blob: blob, format: format)
        let stamped = Date()
        let record = ScreenshotRecord(
            capturedAt: stamped, image: image, format: format,
            transferMs: 1, wireBytes: blob.count)

        XCTAssertNil(model.write(record, to: dir))
        // Same timestamp twice: the second must land beside the first.
        XCTAssertNil(model.write(record, to: dir))
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(files.filter { $0.hasSuffix(".png") }.count, 2)
    }

    func testWriteReportsAnUnwritableDirectory() throws {
        let model = makeModel()
        let blob: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7]
        let format = CaptureFormat(
            width: 4, height: 2, depth: 8, rowBytes: 4, bytes: blob.count,
            paletteBytes: 0, packed: false, captureMs: 0, encodeMs: 0)
        let record = ScreenshotRecord(
            capturedAt: Date(),
            image: try CaptureDecoder.makeImage(blob: blob, format: format),
            format: format, transferMs: 1, wireBytes: blob.count)
        let missing = URL(fileURLWithPath: "/does/not/exist/now-test")
        XCTAssertNotNil(model.write(record, to: missing))
    }

    func testCapturingWithoutAGuestFailsHonestly() {
        let model = makeModel()
        model.connection = .connected(named: "PowerBook 1400")
        model.capture()
        // The listener holds no session, so it refuses immediately.
        XCTAssertEqual(model.lastError,
                       "No \(MachineNaming.commonNoun) is connected")
        XCTAssertTrue(model.history.isEmpty)
    }

    // MARK: - What the app calls the machine on the other end

    /// **`peerLabel` keeps no fallback of its own.**
    ///
    /// It is where roughly two dozen call sites across the app ask what to
    /// call the driven machine, and it used to answer "the classic Mac" —
    /// a second answer to a question `MachineNaming` already owns, which is
    /// how the copy came to name that machine four different ways. Nothing
    /// in the suite noticed when the literal was put back: this is the
    /// guard that does.
    func testPeerLabelDefersToMachineNamingRatherThanAFallbackOfItsOwn() {
        for state: GuestConnectionState in [.disconnected, .connecting] {
            XCTAssertEqual(state.peerLabel, MachineNaming.simpleReference,
                           "\(state) must read through MachineNaming")
            XCTAssertFalse(state.peerLabel.lowercased().contains("classic"),
                           "\"classic\" is not one of this app's words for "
                           + "a machine")
        }
        // A machine that has said its name is called by it, still.
        XCTAssertEqual(GuestConnectionState.connected(named: "Zulu").peerLabel,
                       "Zulu")
        /* The placeholder the host writes into its own registry when a
           machine says nothing about itself reaches display code as an
           ordinary name — and must not be shown as one. Only MachineNaming
           knows that, which is the second reason not to answer here. */
        XCTAssertEqual(
            GuestConnectionState.connected(named: Session.unnamedGuest).peerLabel,
            MachineNaming.simpleReference)
    }
}
