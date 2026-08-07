import AppKit
import XCTest
@testable import Host

@MainActor
final class QuickCaptureTests: XCTestCase {
    private func makeCommand() -> (QuickCaptureCommand, ScreenshotModuleModel,
                                   FilesModuleModel) {
        let listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"))
        let suite = "quickcapture.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults.standard.removeSuite(named: suite) }
        let screenshots = ScreenshotModuleModel(listener: listener,
                                                defaults: defaults)
        let files = FilesModuleModel(listener: listener, defaults: defaults)
        return (QuickCaptureCommand(screenshots: screenshots, files: files),
                screenshots, files)
    }

    // MARK: - Enablement

    func testDisabledWithoutAGuest() {
        let ready = QuickCaptureReadiness.evaluate(
            connection: .disconnected, isCapturing: false,
            isStreaming: false, isTransferringFile: false)
        XCTAssertFalse(ready.isEnabled)
        XCTAssertEqual(ready.reason, "No \(MachineNaming.commonNoun) is connected")
    }

    func testConnectingIsNotYetConnected() {
        XCTAssertFalse(QuickCaptureReadiness.evaluate(
            connection: .connecting, isCapturing: false,
            isStreaming: false, isTransferringFile: false).isEnabled)
    }

    func testEnabledOnAnIdleConnection() {
        let ready = QuickCaptureReadiness.evaluate(
            connection: .connected(named: "PowerBook 1400"),
            isCapturing: false, isStreaming: false, isTransferringFile: false)
        XCTAssertTrue(ready.isEnabled)
        XCTAssertNil(ready.reason)
    }

    /// The single transfer lane: each of the three occupants blocks, and
    /// each names itself so the toast can explain the grey-out.
    func testEveryLaneOccupantDisablesWithItsOwnReason() {
        let connected = GuestConnectionState.connected(named: "Quadra 950")
        let cases: [(Bool, Bool, Bool, String)] = [
            (true, false, false, "A screenshot is already on its way"),
            (false, true, false, "The live stream is using the connection"),
            (false, false, true, "A file transfer is using the connection"),
        ]
        for (capturing, streaming, transferring, reason) in cases {
            let ready = QuickCaptureReadiness.evaluate(
                connection: connected, isCapturing: capturing,
                isStreaming: streaming, isTransferringFile: transferring)
            XCTAssertFalse(ready.isEnabled)
            XCTAssertEqual(ready.reason, reason)
        }
    }

    func testReadinessTracksTheConnectionLive() {
        let (command, screenshots, _) = makeCommand()
        XCTAssertFalse(command.readiness.isEnabled)
        screenshots.connection = .connected(named: "PowerBook 1400")
        XCTAssertTrue(command.readiness.isEnabled)
        screenshots.connection = .disconnected
        XCTAssertFalse(command.readiness.isEnabled)
    }

    // MARK: - Running

    func testRunningWhileDisabledReportsTheReasonAndSendsNothing() {
        let (command, _, _) = makeCommand()
        var outcomes: [QuickCaptureOutcome] = []
        command.report = { outcomes.append($0) }
        command.run()
        XCTAssertEqual(outcomes, [.failed("No \(MachineNaming.commonNoun) is connected")])
    }

    /// The badge says connected but the listener holds no session, so the
    /// request is refused on the spot — the command must surface that, not
    /// hang waiting for a toast that never comes.
    func testAFailedCaptureIsReportedNotSwallowed() {
        let (command, screenshots, _) = makeCommand()
        screenshots.connection = .connected(named: "PowerBook 1400")
        var outcomes: [QuickCaptureOutcome] = []
        command.report = { outcomes.append($0) }
        command.run()
        // The listener's own refusal, not QuickCapture's: the badge said
        // connected, so the readiness rule let the command through.
        XCTAssertEqual(outcomes, [.failed(
            "No \(MachineNaming.commonNoun) is connected")])
    }

    // MARK: - Outcome copy

    func testCopiedOutcomeNamesTheFileOnlyWhenOneWasSaved() {
        let bare = QuickCaptureOutcome.copied(width: 640, height: 480,
                                              depth: 8, savedAs: nil)
        XCTAssertEqual(bare.body, "640 × 480 · 8-bit · on the clipboard")
        let saved = QuickCaptureOutcome.copied(width: 640, height: 480,
                                               depth: 8, savedAs: "Shot.png")
        XCTAssertEqual(saved.body,
                       "640 × 480 · 8-bit · on the clipboard · saved as Shot.png")
        XCTAssertEqual(saved.title, "Screenshot copied")
    }

    func testFailedOutcomeCarriesTheReasonVerbatim() {
        let outcome = QuickCaptureOutcome.failed("The Mac did not answer")
        XCTAssertEqual(outcome.body, "The Mac did not answer")
        XCTAssertEqual(outcome.title, "Screenshot failed")
    }

    // MARK: - Clipboard, forced

    /// Copying is the command's entire point, so it must not be gated on
    /// the panel's auto-copy toggle — the toggle is off by default here.
    func testCaptureToClipboardCopiesWithAutoCopyOff() throws {
        let (_, screenshots, _) = makeCommand()
        XCTAssertFalse(screenshots.autoCopy)

        let blob: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7]
        let format = CaptureFormat(
            width: 4, height: 2, depth: 8, rowBytes: 4, bytes: blob.count,
            paletteBytes: 0, packed: false, captureMs: 0, encodeMs: 0)
        let record = ScreenshotRecord(
            capturedAt: Date(),
            image: try CaptureDecoder.makeImage(blob: blob, format: format),
            format: format, transferMs: 1, wireBytes: blob.count)

        NSPasteboard.general.clearContents()
        screenshots.copyToPasteboard(record)
        XCTAssertTrue(NSPasteboard.general.canReadObject(
            forClasses: [NSImage.self], options: nil))
    }

    // MARK: - The menu item itself

    func testStatusMenuCarriesTheCommandGreyedOutWithNoGuest() throws {
        let delegate = AppDelegate()
        let menu = delegate.makeStatusMenu()
        let shoot = try XCTUnwrap(menu.items.first {
            $0.title == "Capture Screen"
        }, "the status menu must offer the command")
        XCTAssertEqual(shoot.keyEquivalent, "s")
        XCTAssertTrue(shoot.target === delegate)
        // Nothing is connected in a fresh delegate, so the menu's validation
        // hook must grey it out rather than let it fail on send.
        XCTAssertFalse(delegate.validateMenuItem(shoot))
        // Sibling items must stay unconditionally live.
        let quit = try XCTUnwrap(menu.items.first {
            $0.title.hasPrefix("Quit")
        })
        XCTAssertTrue(delegate.validateMenuItem(quit))
    }

    // MARK: - Visible fallback

    func testFlashShowsThenRestoresTheRestingTitle() {
        let expectation = expectation(description: "restored")
        var titles: [String] = []
        let flash = StatusItemFlash(duration: 0.05) {
            "● New Old World"
        } apply: {
            titles.append($0)
            if titles.count == 2 { expectation.fulfill() }
        }
        flash.flash("✓ Copied")
        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(titles, ["✓ Copied", "● New Old World"])
    }

    /// A second flash must not be cut short by the first one's timer.
    func testASecondFlashOutlivesTheFirstsRestore() {
        let expectation = expectation(description: "settled once")
        var titles: [String] = []
        let flash = StatusItemFlash(duration: 0.15) { "rest" } apply: {
            titles.append($0)
            if $0 == "rest" { expectation.fulfill() }
        }
        flash.flash("first")
        flash.flash("second")
        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(titles, ["first", "second", "rest"],
                       "only the latest flash should restore")
    }

    /// The resting title carries the live connection glyph, so it must be
    /// read at restore time — a title captured when the flash began would
    /// put a stale connection state back in the menu bar.
    func testFlashRestoresTheCurrentTitleNotTheOneItStartedWith() {
        let expectation = expectation(description: "restored")
        var resting = "◌ New Old World"
        var titles: [String] = []
        let flash = StatusItemFlash(duration: 0.05) { resting } apply: {
            titles.append($0)
            if titles.count == 2 { expectation.fulfill() }
        }
        flash.flash("✓ Copied")
        // The guest connects while the flash is still on screen.
        resting = "● New Old World"
        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(titles.last, "● New Old World")
    }

    func testIsFlashingGuardsTheTitleWhileAFlashIsUp() {
        let flash = StatusItemFlash(duration: 5) { "rest" } apply: { _ in }
        XCTAssertFalse(flash.isFlashing)
        flash.flash("✓ Copied")
        XCTAssertTrue(flash.isFlashing)
        flash.settle()
        XCTAssertFalse(flash.isFlashing)
    }
}
