import CryptoKit
import Network
import XCTest
@testable import Host

/// Slice B (034): the update-in-place install path's host-side bookkeeping.
///
/// `ConnectionsModel.installUpdate()` used to wait on `.updateFinished`
/// with nothing bounding it (see `GuestListener.updateResultWatchdogSeconds`'s
/// own doc comment for why the 20 s command watchdog does not already cover
/// this) — a guest that went silent after accepting an update left
/// `pendingUpdates` and `updateNotices` stuck forever, with no way to
/// cancel and no progress shown while it waited. These are the guards: a
/// silent guest converges through the watchdog, a person's Cancel converges
/// the same way, and the progress bar reflects bytes actually crossing the
/// wire and clears once the wait ends — whichever of the three ways it
/// ends, all through the one `finishUpdate` seam.
///
/// This exercises the REAL wire: `GuestListener.installUpdate` addresses
/// the active session explicitly (`guard activeKey == key`), so nothing
/// short of an honest hello handshake produces a state these tests could
/// legitimately drive.
@MainActor
final class ConnectionsUpdateModelTests: XCTestCase {
    private var listener: GuestListener!
    private var tempRoot: URL!

    override func tearDown() async throws {
        listener?.stop()
        listener = nil
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
    }

    private struct WaitTimeout: Error { let what: String }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5,
                           _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out waiting for \(what)")
                throw WaitTimeout(what: what)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private static let build = String(repeating: "b", count: 64)

    private static func sha256(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// A minimal, validated "application" artifact — the same shape
    /// `UpdateProviderTests` builds — small enough to cross loopback in a
    /// single bulk frame, so a test does not need to script the
    /// acknowledgement windowing an ordinary large put would.
    private func makeProvider() throws -> UpdateProvider {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-update-model-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempRoot, withIntermediateDirectories: true)
        let bytes = Data("a tiny replacement application".utf8)
        let url = tempRoot.appendingPathComponent("New Old World.bin")
        try bytes.write(to: url)
        let manifest: [String: Any] = [
            "schema": 1, "component": "application", "version": "0.2.0",
            "build": Self.build, "sha256": Self.sha256(bytes),
            "bytes": bytes.count, "channel": "development", "signed": false,
            "compatibility": [
                "continuityWire": ContinuityContract.version,
                "continuityTable": ContinuityContract.residentTableVersion,
                "resident": ContinuityContract.residentVersion,
            ],
        ]
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: url.appendingPathExtension("now-update.json"))
        let asset = OnboardingAsset(kind: .application, fileURL: url,
                                    byteCount: Int64(bytes.count))
        return UpdateProvider(snapshot: .init(
            application: asset, codeKitten: nil, extensionComponent: nil,
            dependencies: []))
    }

    /// Stands up a real, connected-and-driven guest against a listener
    /// that offers exactly one replacement artifact.
    private func connected() async throws
        -> (model: ConnectionsModel, guest: FakeGuest, row: ConnectionRow,
            artifact: UpdateProvider.Artifact) {
        let provider = try makeProvider()
        let artifact = try XCTUnwrap(provider.artifacts[.application])
        listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"),
            timing: .init(idleTimeout: 60), updateProvider: provider)
        listener.start(port: 0)
        try await waitUntil("listening") {
            if case .listening = self.listener.state { return true }
            return false
        }
        let model = ConnectionsModel(listener: listener, resolve: { _ in nil })
        let guest = FakeGuest(port: try XCTUnwrap(listener.boundPort))
        guest.start()
        try guest.send(.hello(Hello(
            contract: Contract.revision, side: "guest", version: "0.1.0",
            name: "PowerBook 1400c", os: "9.1", chunk: 8192)))
        try await waitUntil("connected") {
            if case .connected = self.listener.state { return true }
            return false
        }
        try await waitUntil("row published") { model.snapshot.driving != nil }
        return (model, guest, try XCTUnwrap(model.snapshot.driving), artifact)
    }

    /// The guest acks "Downloading" (the near-instant reply `run_update`
    /// sends in the real guest — U2's own finding is exactly that this
    /// acknowledgment is not completion) and then goes silent forever:
    /// no `update.request`, no `update.result`. Before the watchdog this
    /// left `pendingUpdates`/`updateNotices` stuck for the rest of the
    /// app's life. `expireUpdateWatchdogsForTesting` exercises the SAME
    /// expiry path a real 3-minute wait would take, without sleeping
    /// through it.
    func testASilentGuestConvergesThroughTheWatchdog() async throws {
        let (model, guest, row, _) = try await connected()
        guest.onMessage = { message in
            guard case .commandRequest(let request) = message,
                  request.name == "update" else { return }
            try? guest.send(.commandResult(CommandResult(
                id: request.id, ok: true,
                output: ["update": [["application", "Downloading"]]],
                error: nil)))
        }

        model.installUpdate(for: row, component: .application)
        try await waitUntil("update pending") {
            model.updateIsPending(for: row, component: .application)
        }

        model.expireUpdateWatchdogsForTesting()

        XCTAssertFalse(model.updateIsPending(for: row, component: .application))
        XCTAssertEqual(
            model.updateNotice(for: row, component: .application),
            "The guest did not confirm the update in time.")
        XCTAssertNil(model.updateProgress,
                     "the bar must not freeze once the wait ends")
    }

    /// A LATE answer, arriving after the watchdog already gave up, must
    /// not resurrect a notice the person has already moved past — the
    /// same reasoning `GuestListener`'s own request watchdogs use
    /// (`putId`/`pendingCommands` are cleared before the timeout fires,
    /// so a late arrival finds nothing to settle).
    func testALateAnswerAfterTheWatchdogDoesNotResurrectTheNotice()
        async throws {
        let (model, guest, row, artifact) = try await connected()
        guest.onMessage = { message in
            guard case .commandRequest(let request) = message,
                  request.name == "update" else { return }
            try? guest.send(.commandResult(CommandResult(
                id: request.id, ok: true,
                output: ["update": [["application", "Downloading"]]],
                error: nil)))
        }
        model.installUpdate(for: row, component: .application)
        try await waitUntil("update pending") {
            model.updateIsPending(for: row, component: .application)
        }
        model.expireUpdateWatchdogsForTesting()
        let noticeAfterTimeout = model.updateNotice(
            for: row, component: .application)

        try guest.send(.updateResult(UpdateResult(
            id: 1, component: "application", ok: true,
            action: "relaunch-required", code: nil, reason: nil)))
        _ = artifact
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(
            model.updateNotice(for: row, component: .application),
            noticeAfterTimeout,
            "a late update.result must not overwrite the timeout notice")
        XCTAssertFalse(model.updateIsPending(for: row, component: .application))
    }

    /// Cancel settles LOCALLY on the person's say-so, the same philosophy
    /// as `GuestListener.cancelCapture` — "stop waiting", not "prove the
    /// far side agrees" — even though the wire-level half
    /// (`cancelUpdateTransfer`) is best-effort and this test never starts
    /// an actual byte transfer for it to interrupt.
    func testCancelConvergesImmediatelyWithoutWaitingOnTheGuest()
        async throws {
        let (model, guest, row, _) = try await connected()
        guest.onMessage = { message in
            guard case .commandRequest(let request) = message,
                  request.name == "update" else { return }
            try? guest.send(.commandResult(CommandResult(
                id: request.id, ok: true,
                output: ["update": [["application", "Downloading"]]],
                error: nil)))
        }
        model.installUpdate(for: row, component: .application)
        try await waitUntil("update pending") {
            model.updateIsPending(for: row, component: .application)
        }

        model.cancelUpdate(for: row, component: .application)

        XCTAssertFalse(model.updateIsPending(for: row, component: .application))
        XCTAssertEqual(model.updateNotice(for: row, component: .application),
                       "Cancelled.")
        XCTAssertNil(model.updateProgress)
    }

    /// Cancelling something that is not pending must not be able to
    /// fabricate a notice for it — the guard `cancelUpdate` opens with.
    func testCancelWithNothingPendingDoesNothing() async throws {
        let (model, guest, row, _) = try await connected()
        _ = guest

        model.cancelUpdate(for: row, component: .application)

        XCTAssertNil(model.updateNotice(for: row, component: .application))
    }

    /// The progress bar's numbers come from bytes actually leaving this
    /// Mac's socket, via the same `captureProgress`/`.transferProgressed`
    /// bus Screenshots already reads (`ScreenshotModel.swift:368-378`) —
    /// scripted here as a real `update.request` → `fileOffer` →
    /// `fileAccept` exchange rather than a synthetic event, so this
    /// proves the wiring this slice added actually reaches the real
    /// artifact-send path and not only its own event switch. It also
    /// proves the bar does not freeze at its last value once
    /// `finishUpdate` settles the attempt (a gap this slice's own
    /// `installUpdate` would otherwise have, since it never sets `putId`
    /// — see `finishUpdate`'s doc comment).
    func testProgressReflectsRealBytesAndClearsWhenSettled() async throws {
        let (model, guest, row, artifact) = try await connected()
        var offerID: Int?
        guest.onMessage = { message in
            switch message {
            case .commandRequest(let request) where request.name == "update":
                try? guest.send(.commandResult(CommandResult(
                    id: request.id, ok: true,
                    output: ["update": [["application", "Downloading"]]],
                    error: nil)))
                try? guest.send(.updateRequest(UpdateRequest(
                    id: 501, component: "application",
                    build: artifact.manifest.build,
                    sha256: artifact.manifest.sha256)))
            case .fileOffer(let offer):
                offerID = offer.id
                try? guest.send(.fileAccept(FileAccept(id: offer.id)))
            default:
                break
            }
        }

        model.installUpdate(for: row, component: .application)
        try await waitUntil("offer accepted") { offerID != nil }
        // The FIRST report (received: 0) lands the instant the offer is
        // accepted, before any byte actually leaves the socket — waiting
        // for that alone would pass on a progress bar that never moves.
        try await waitUntil("bytes seen on the wire") {
            (model.updateProgress?.received ?? 0) > 0
        }
        XCTAssertEqual(model.updateProgress?.expected,
                       artifact.bytes.count)

        model.expireUpdateWatchdogsForTesting()
        XCTAssertNil(model.updateProgress,
                     "settling must drop the bar, not freeze it")
    }
}
