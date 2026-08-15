import CryptoKit
import Foundation
import XCTest
@testable import Host

/// Whether the Connections page tells the truth about an installed update.
///
/// The contract is explicit that installing an application never relaunches
/// it — the guest "remains connected" reporting `relaunch-required`, and the
/// person has to quit and launch it again — and installing an extension
/// never restarts the Mac. A host that says "Installed." and stops talking
/// is indistinguishable from a host that confirmed the new build is
/// running, and on 2026-08-15 that ambiguity cost a metal round: a guest
/// update was applied, nobody relaunched, and the next round metal-tested
/// the OLD build believing it new. These guards are the reconnect-fingerprint
/// check that replaces the one-shot "Installed." text.
@MainActor
final class ConnectionsModelUpdateTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "now-connections-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private static let oldBuild = String(repeating: "a", count: 64)
    private static let newBuild = String(repeating: "b", count: 64)

    private func applicationProvider() throws -> UpdateProvider {
        let bytes = Data("application".utf8)
        let url = root.appendingPathComponent("New Old World.bin")
        try bytes.write(to: url)
        let manifest: [String: Any] = [
            "schema": 1, "component": "application", "version": "0.2.0",
            "build": Self.newBuild, "sha256": Self.sha256(bytes),
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

    private static func sha256(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5,
                           _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out waiting for \(what)")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Sets up a listener with a newer application build published, a
    /// FakeGuest connected reporting the old one, and the model driving it —
    /// the shared prefix every test below needs before it can install.
    private func connectedRig() async throws
        -> (listener: GuestListener, guest: FakeGuest, model: ConnectionsModel) {
        let provider = try applicationProvider()
        let listener = GuestListener(
            identity: .init(version: "test", name: "Test Host"),
            timing: .init(idleTimeout: 60), updateProvider: provider)
        listener.start(port: 0)
        try await waitUntil("listening") {
            if case .listening = listener.state { return true }
            return false
        }
        let guest = FakeGuest(port: try XCTUnwrap(listener.boundPort))
        guest.start()
        try guest.send(.hello(.init(
            contract: Contract.revision, side: "guest", version: "0.1.0",
            build: Self.oldBuild, name: "PowerBook 1400c", os: "9.1",
            chunk: 8192)))
        try await waitUntil("guest connected") { listener.activeKey != nil }

        let model = ConnectionsModel(listener: listener,
                                     resolve: { _ in nil })
        model.refresh()
        return (listener, guest, model)
    }

    /// The primary regression: a person clicks Replace, the guest ACKs the
    /// command and reports `relaunch-required`, and nobody ever quits and
    /// relaunches the app. This Mac must keep saying so — not once, but on
    /// every later refresh — because that is exactly the metal round that
    /// went undetected.
    func testAnUnrelaunchedApplicationKeepsSayingSoAcrossRefreshes()
        async throws {
        let (listener, guest, model) = try await connectedRig()
        defer { guest.connection.cancel(); listener.stop() }

        let acked = Box(false)
        guest.onMessage = { message in
            guard case .commandRequest(let command) = message else { return }
            try? guest.send(.commandResult(.init(id: command.id, ok: true)))
            acked.value = true
        }
        let row = try XCTUnwrap(model.snapshot.driving)
        model.installUpdate(for: row, component: .application)
        try await waitUntil("install command acked") { acked.value }

        /* The guest answers over the control channel, not the ack above:
           `update.result` with `ok: true, action: "relaunch-required"` and
           the process still running is exactly what the contract promises
           for an application install. */
        try guest.send(.updateResult(.init(
            id: 1, component: "application", ok: true,
            action: "relaunch-required", code: nil, reason: nil)))
        try await waitUntil("update finished") {
            let notice = model.updateNotice(for: row, component: .application)
            return notice != nil && notice != "Downloading and installing…"
        }

        let firstNotice = try XCTUnwrap(
            model.updateNotice(for: row, component: .application))
        XCTAssertTrue(firstNotice.contains("NOT relaunched"),
                      "got: \(firstNotice)")
        XCTAssertTrue(model.isAwaitingRelaunch(for: row,
                                               component: .application))

        /* An UNRELATED refresh — the roster changing for its own reasons —
           must not silently clear or stale-freeze the warning. This is the
           re-derivation the one-shot text never did. */
        model.refresh()
        let secondNotice = try XCTUnwrap(
            model.updateNotice(for: row, component: .application))
        XCTAssertTrue(secondNotice.contains("NOT relaunched"),
                      "a later refresh must keep telling the truth, got: "
                        + secondNotice)
        XCTAssertTrue(model.isAwaitingRelaunch(for: row,
                                               component: .application))
    }

    /// The other half, and the reason `pendingRelaunches` is keyed by
    /// MACHINE and not by session: a real relaunch is a quit and a
    /// re-launch, which on the wire is this connection closing and a NEW
    /// one opening — a new `GuestKey` — and this Mac's only proof is that
    /// new session reporting the installed build. If the tracking were
    /// keyed by the old session, this confirmation could never fire.
    func testAGenuineRelaunchOnANewSessionIsConfirmedOnTheNewRow()
        async throws {
        let (listener, oldGuest, model) = try await connectedRig()
        defer { listener.stop() }

        let acked = Box(false)
        oldGuest.onMessage = { message in
            guard case .commandRequest(let command) = message else { return }
            try? oldGuest.send(.commandResult(.init(id: command.id, ok: true)))
            acked.value = true
        }
        let oldRow = try XCTUnwrap(model.snapshot.driving)
        model.installUpdate(for: oldRow, component: .application)
        try await waitUntil("install command acked") { acked.value }
        try oldGuest.send(.updateResult(.init(
            id: 1, component: "application", ok: true,
            action: "relaunch-required", code: nil, reason: nil)))
        try await waitUntil("stale notice recorded") {
            model.isAwaitingRelaunch(for: oldRow, component: .application)
        }
        XCTAssertTrue(model.isAwaitingRelaunch(for: oldRow,
                                               component: .application))

        /* Quit: the old TCP conversation ends. */
        oldGuest.connection.cancel()
        try await waitUntil("old session gone") { listener.activeKey == nil }

        /* Launch again: a brand new connection, reporting the NEW build —
           the only fact this Mac can trust as proof. */
        let newGuest = FakeGuest(port: try XCTUnwrap(listener.boundPort))
        defer { newGuest.connection.cancel() }
        newGuest.start()
        try newGuest.send(.hello(.init(
            contract: Contract.revision, side: "guest", version: "0.2.0",
            build: Self.newBuild, name: "PowerBook 1400c", os: "9.1",
            chunk: 8192)))
        try await waitUntil("new session connected") {
            listener.activeKey != nil
        }
        model.refresh()

        try await waitUntil("confirmed on the new row") {
            model.refresh()
            guard let newRow = model.snapshot.driving else { return false }
            return !model.isAwaitingRelaunch(for: newRow,
                                             component: .application)
        }

        let newRow = try XCTUnwrap(model.snapshot.driving)
        XCTAssertNotEqual(newRow.liveSessionID, oldRow.liveSessionID,
                          "the confirmation must be about a real reconnect, "
                            + "not the same session read twice")
        let notice = try XCTUnwrap(
            model.updateNotice(for: newRow, component: .application))
        XCTAssertTrue(notice.contains("Relaunched"), "got: \(notice)")
        XCTAssertFalse(model.isAwaitingRelaunch(for: newRow,
                                                component: .application))
    }

    /// A plain mutable box for a flag `FakeGuest.onMessage` sets from its
    /// own (non-main-actor) callback — the same shape as `Held`/`Asked` in
    /// `ContinuityGuestDragTests`.
    private final class Box: @unchecked Sendable {
        var value: Bool
        init(_ value: Bool) { self.value = value }
    }
}
