import Foundation
import XCTest
@testable import Host
import MirrorKit

/// **Breaking the Mirror pane into its own window — the model's half.**
///
/// The window itself (`MirrorDetachedWindowController`) is AppKit, and this
/// file does not touch it — per the brief, these are model-level tests.
/// What the model has to prove needs no `NSWindow` at all: `isDetached` is
/// nothing but a fact the embedded pane and a standalone window's copy of
/// the same view would draw differently from, and `detach()`/`reattach()`
/// must never disturb the session or the scene sitting underneath it. If
/// they did, breaking a pane out would be indistinguishable from a second
/// `MirrorModuleModel` quietly replacing the first one's state.
@MainActor
final class MirrorDetachModelTests: XCTestCase {

    // MARK: - rig (same shape as MirrorSessionModelTests' own)

    private struct Rig {
        let listener: GuestListener
        let guest: FakeGuest
        let model: MirrorModuleModel
    }

    private static let scene = """
        {"version":1,"seq":7,"capturedAt":1750000000.0,"source":"peek",\
        "screen":{"w":640,"h":480},\
        "windows":[{"id":"0.1/Window#0","app":"Finder",\
        "psn":"0.1","title":"Window",\
        "rect":{"l":8,"t":40,"r":400,"b":300},"front":true,"z":0,\
        "visible":true}],\
        "meta":{"errors":[]}}
        """

    private func rig() async throws -> Rig {
        let (listener, guest) = try await connectedListener()
        guest.onMessage = { message in
            guard case .sceneRequest(let request) = message else { return }
            let body = Data(Self.scene.utf8)
            try? guest.send(.sceneBegin(SceneBegin(
                id: request.id, transfer: 9, bytes: body.count,
                irVersion: 1, seq: 7, capturedAt: 1_750_000_000,
                source: "peek", walkMs: 3)))
            guest.sendRaw(try! FrameCodec.encode(
                channel: .bulk, flags: [.end], transfer: 9, payload: body))
            try? guest.send(.sceneEnd(SceneEnd(
                id: request.id, transfer: 9, ok: true, reason: nil,
                sendMs: 1)))
        }
        let model = MirrorModuleModel(listener: listener, watch: .manual)
        let key = try XCTUnwrap(listener.activeKey)
        guard case .connected(let name) = listener.state else {
            throw XCTSkip("guest did not connect")
        }
        model.connection = .connected(name: name, key: key)
        return Rig(listener: listener, guest: guest, model: model)
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

    // MARK: - detach/reattach with nothing running

    func testDetachFlipsTheFlagAndReattachFlipsItBack() {
        let model = MirrorModuleModel()
        XCTAssertFalse(model.isDetached)
        model.detach()
        XCTAssertTrue(model.isDetached)
        model.reattach()
        XCTAssertFalse(model.isDetached)
    }

    /// A second detach while already detached, or a reattach while already
    /// attached, must be a no-op — not a crash, not a second toggle. This is
    /// the property that lets `MirrorDetachedWindowController.show()` call
    /// `detach()` unconditionally on every press without first checking
    /// whether a window is already open.
    func testDetachAndReattachAreIdempotent() {
        let model = MirrorModuleModel()
        model.detach()
        model.detach()
        XCTAssertTrue(model.isDetached)

        model.reattach()
        model.reattach()
        XCTAssertFalse(model.isDetached)
    }

    // MARK: - one session, undisturbed by either direction

    /// Breaking the pane out must not touch the session it is showing —
    /// there is exactly one `MirrorModuleModel` and exactly one wire
    /// session, and `detach()` only changes which window draws it.
    func testDetachDoesNotDisturbTheRunningSessionOrItsScene() async throws {
        let rig = try await rig()
        defer { rig.guest.connection.cancel(); rig.listener.stop() }

        rig.model.startSession()
        try await waitUntil("a streaming session") {
            rig.model.sessionState == .streaming
        }
        let windowCountBefore = rig.model.scene?.windows.count
        let lastSceneAtBefore = rig.model.lastSceneAt

        rig.model.detach()

        XCTAssertTrue(rig.model.isDetached)
        XCTAssertEqual(rig.model.sessionState, .streaming,
                       "breaking the pane into its own window stopped the "
                           + "session it was showing")
        XCTAssertEqual(rig.model.scene?.windows.count, windowCountBefore,
                       "detach rebuilt or wiped the held scene")
        XCTAssertEqual(rig.model.lastSceneAt, lastSceneAtBefore,
                       "detach asked the guest for anything at all — it "
                           + "should ask nothing")
    }

    /// The model's half of "closing the window returns the pane to the
    /// module rather than ending the session": `reattach()` is exactly
    /// what `windowWillClose` calls, and it must leave the session running.
    func testReattachAfterACloseLeavesTheSameSessionRunning() async throws {
        let rig = try await rig()
        defer { rig.guest.connection.cancel(); rig.listener.stop() }

        rig.model.startSession()
        try await waitUntil("a streaming session") {
            rig.model.sessionState == .streaming
        }
        rig.model.detach()

        rig.model.reattach()

        XCTAssertFalse(rig.model.isDetached)
        XCTAssertEqual(rig.model.sessionState, .streaming,
                       "the window closing stopped the session it was "
                           + "showing rather than just returning the pane")
        XCTAssertNotNil(rig.model.scene,
                        "the scene on screen was lost across a detach and "
                            + "a close")
    }

    /// Stop, while detached, must behave exactly as it does embedded — the
    /// session state machine has no third path for "detached", because
    /// there is no second model here for it to have one in.
    func testStoppingWhileDetachedBehavesLikeStoppingEmbedded()
        async throws {
        let rig = try await rig()
        defer { rig.guest.connection.cancel(); rig.listener.stop() }

        rig.model.startSession()
        try await waitUntil("a streaming session") {
            rig.model.sessionState == .streaming
        }
        rig.model.detach()
        rig.model.stopSession()

        XCTAssertEqual(rig.model.sessionState, .stopped)
        XCTAssertTrue(rig.model.isDetached,
                      "stopping the session is not the same fact as "
                          + "reattaching the pane, and must not silently "
                          + "flip it back")
    }
}
