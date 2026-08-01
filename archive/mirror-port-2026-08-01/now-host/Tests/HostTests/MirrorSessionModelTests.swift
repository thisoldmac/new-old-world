import Foundation
import XCTest
@testable import Host
import MirrorKit

/// **The session model: Start/Stop, and content that survives a fetch.**
///
/// The maintainer's brief for this wave: the Mirror module's controls reduce
/// to Start Mirror / Stop Mirror plus a config area, Start arms the content
/// plane and re-arms it on a front-window change, content joined onto a
/// window must survive the NEXT scene fetch rather than being wiped by it,
/// and the session's own state (not-started/starting/streaming/stopped/
/// guest-gone) must be honest in the model.
///
/// Every test that needs a scene to land drives a real `GuestListener` over
/// a real loopback socket with a `FakeGuest` answering — the same rig
/// `MirrorLiveWatchTests` and `MirrorSceneFetchTests` use, and for the same
/// reason: the properties here live in what crosses the wire (a
/// `qdtrace drain`'s reply, a second `scene.request`), not in anything a
/// model built from bytes alone could exercise.
@MainActor
final class MirrorSessionModelTests: XCTestCase {

    // MARK: - rig

    private struct Rig {
        let listener: GuestListener
        let guest: FakeGuest
        let model: MirrorModuleModel
    }

    /// One front window, `"0.1/Window"` in `MirrorContentHold`'s own keying
    /// — stable across fetches, which is exactly the property under test.
    private static let scene = """
        {"version":1,"seq":7,"capturedAt":1750000000.0,"source":"peek",\
        "screen":{"w":640,"h":480},\
        "windows":[{"id":"0.1/Window#0","app":"Finder",\
        "psn":"0.1","title":"Window",\
        "rect":{"l":8,"t":40,"r":400,"b":300},"front":true,"z":0,\
        "visible":true}],\
        "meta":{"errors":[]}}
        """

    /// A drain reply with `count` rect ops on one port — `qdtrace_json.c`'s
    /// own shape, transcribed the way `MirrorContentJoinTests` does.
    private static func drainReply(id: Int, ops count: Int,
                                   cursor: Int) -> CommandResult {
        let rects = (0..<count).map { i in
            "{\"op\":\"rect\",\"port\":\"0x00aa00\",\"ticks\":\(i),"
                + "\"verb\":0,\"rect\":[0,0,10,10],\"ext\":[0,0]}"
        }.joined(separator: ",")
        let json = "{\"type\":\"command.result\",\"id\":\(id),\"ok\":true,"
            + "\"output\":{\"qdtrace\":{\"cmd\":\"drain\",\"ops\":[\(rects)],"
            + "\"cursor\":0,\"nextCursor\":\(cursor),\"writeCursor\":\(cursor),"
            + "\"pending\":0,\"records\":\(count),\"wraps\":0,\"more\":false,"
            + "\"resync\":false,\"torn\":false,\"busy\":false,"
            + "\"lostBytes\":0,\"dropped\":0}}}"
        return try! JSONDecoder().decode(CommandResult.self,
                                         from: Data(json.utf8))
    }

    /// A guest that serves `Self.scene` for every `scene.request` and, when
    /// `joinsContent`, one drain of `contentOps` rect ops for every
    /// `qdtrace` command — otherwise refuses `qdtrace` outright, the way a
    /// guest with no QDPeek would.
    private func rig(joinsContent: Bool = true,
                     contentOps: Int = 2) async throws -> Rig {
        let (listener, guest) = try await connectedListener()
        var nextCursor = 96
        guest.onMessage = { message in
            switch message {
            case .sceneRequest(let request):
                let body = Data(Self.scene.utf8)
                try? guest.send(.sceneBegin(SceneBegin(
                    id: request.id, transfer: 9, bytes: body.count,
                    irVersion: 1, seq: 7, capturedAt: 1_750_000_000,
                    source: "peek", walkMs: 3)))
                guest.sendRaw(try! FrameCodec.encode(
                    channel: .bulk, flags: [.end], transfer: 9,
                    payload: body))
                try? guest.send(.sceneEnd(SceneEnd(
                    id: request.id, transfer: 9, ok: true, reason: nil,
                    sendMs: 1)))
            case .commandRequest(let request) where request.name == "qdtrace":
                guard joinsContent else {
                    try? guest.send(.commandResult(.init(
                        id: request.id, ok: false, output: nil,
                        error: .init(code: "unknown-command",
                                     message: "this Mac serves no qdtrace"))))
                    return
                }
                nextCursor += contentOps
                try? guest.send(.commandResult(
                    Self.drainReply(id: request.id, ops: contentOps,
                                    cursor: nextCursor)))
            default:
                break
            }
        }
        let model = MirrorModuleModel(listener: listener, watch: .manual)
        let key = try XCTUnwrap(listener.activeKey)
        guard case .connected(let name) = listener.state else {
            throw XCTSkip("guest did not connect")
        }
        model.connection = .connected(name: name, key: key)
        return Rig(listener: listener, guest: guest, model: model)
    }

    private func settle(_ seconds: Double = 0.25) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
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

    // MARK: - content survives a fetch

    /// **The mutation this test is watching for**: comment out
    /// `MirrorContentHold.apply`'s call in `show(document:)` and this goes
    /// red, because the SECOND fetch below never asks for content at all —
    /// it can only pass by carrying the first join forward.
    func testContentSurvivesAFetchThatDidNotAskForIt() async throws {
        let rig = try await rig(contentOps: 3)
        defer { rig.guest.connection.cancel(); rig.listener.stop() }

        rig.model.fetchScene(withContent: true)
        try await waitUntil("a joined scene") {
            rig.model.scene?.windows.first?.display != nil
        }
        XCTAssertEqual(rig.model.scene?.windows.first?.display?.count, 3,
                       "the first, content-asking fetch did not join")

        /* A second fetch, content-less — the shape every ceiling and
           probe-driven refresh takes. `MirrorSceneAdapter` decodes this
           window's `display` back to nil; only carrying the FIRST join
           forward keeps it from reading as wiped. */
        rig.model.fetchScene()
        try await waitUntil("a second scene") {
            rig.model.lastSeq != nil
        }
        try await settle()

        XCTAssertEqual(rig.model.scene?.windows.first?.display?.count, 3,
                       "a window's joined content was wiped by a fetch that "
                           + "never asked for content — MirrorContentHold "
                           + "did not carry it forward")
    }

    /// A window absent from the scene is not the same as a window present
    /// with nothing joined — this only proves the HELD side of the story;
    /// eviction (a window gone for `contentGraceFetches` running) is
    /// `MirrorContentHold`'s own unit, not re-proven here over a socket.
    func testAWindowThatNeverJoinsContentStaysNilNotZero() async throws {
        let rig = try await rig(joinsContent: false)
        defer { rig.guest.connection.cancel(); rig.listener.stop() }

        rig.model.fetchScene(withContent: true)
        try await waitUntil("a scene, refused content") {
            rig.model.lastSeq != nil
        }
        try await settle()
        XCTAssertNil(rig.model.scene?.windows.first?.display,
                     "nothing was ever joined; carrying forward an absence "
                         + "must not invent one")
    }

    /// **The retired button's first defect, still reachable through the
    /// loop.** `fetchScene()` (no content) and `fetchScene(withContent:
    /// true)` called back to back, with nothing awaited in between, land
    /// while the first is still in flight — the second must not be dropped
    /// silently; it has to upgrade the ask already running so its want for
    /// content is not lost.
    func testAConcurrentContentAskUpgradesTheInFlightFetch() async throws {
        let rig = try await rig(contentOps: 2)
        defer { rig.guest.connection.cancel(); rig.listener.stop() }

        rig.model.fetchScene()
        XCTAssertEqual(rig.model.fetch, .looking,
                       "the first ask must already be in flight for this to "
                           + "test the race at all")
        rig.model.fetchScene(withContent: true)

        try await waitUntil("a joined scene") {
            rig.model.scene?.windows.first?.display != nil
        }
        XCTAssertEqual(rig.model.scene?.windows.first?.display?.count, 2,
                       "a content ask that arrived while a fetch was "
                           + "already in flight was silently dropped rather "
                           + "than upgrading it")
    }

    // MARK: - session lifecycle

    /// Start begins the loop (a probe or a fetch keeps happening on its
    /// own) and arms content — the first scene comes back joined without a
    /// second, manual ask for it.
    func testStartBeginsTheLoopAndArmsContent() async throws {
        let rig = try await rig(contentOps: 2)
        defer { rig.guest.connection.cancel(); rig.listener.stop() }

        XCTAssertEqual(rig.model.sessionState, .notStarted)
        rig.model.startSession()
        XCTAssertEqual(rig.model.sessionState, .starting)
        XCTAssertTrue(rig.model.isLive,
                      "Start must begin the loop, not just ask once")

        try await waitUntil("a streaming session") {
            rig.model.sessionState == .streaming
        }
        try await waitUntil("content joined without a second ask") {
            rig.model.scene?.windows.first?.display?.count == 2
        }
    }

    /// Pressing Start twice does not restart anything already running or
    /// starting — a defect this shape invites once a button becomes
    /// idempotent-by-guard rather than disabled.
    func testStartIsIdempotentWhileStartingOrStreaming() async throws {
        let rig = try await rig()
        defer { rig.guest.connection.cancel(); rig.listener.stop() }

        rig.model.startSession()
        rig.model.startSession()
        XCTAssertEqual(rig.model.sessionState, .starting)

        try await waitUntil("streaming") {
            rig.model.sessionState == .streaming
        }
        rig.model.startSession()
        XCTAssertEqual(rig.model.sessionState, .streaming,
                       "a second Start while streaming must be a no-op")
    }

    /// Stop tears the loop down — no more probes, no more fetches — and the
    /// last scene stays exactly where it was.
    func testStopTearsDownTheLoop() async throws {
        let rig = try await rig()
        defer { rig.guest.connection.cancel(); rig.listener.stop() }

        rig.model.startSession()
        try await waitUntil("streaming") {
            rig.model.sessionState == .streaming
        }
        let sceneBeforeStop = rig.model.scene

        rig.model.stopSession()
        XCTAssertEqual(rig.model.sessionState, .stopped)
        XCTAssertFalse(rig.model.isLive)
        XCTAssertNotNil(rig.model.scene,
                        "Stop must not clear the drawing — it stops "
                            + "updating, it does not forget what was shown")
        XCTAssertEqual(rig.model.scene, sceneBeforeStop)
    }

    /// A guest leaving mid-session is `guestGone`, not `stopped` — nobody
    /// asked for this, and it reads differently from a person's own Stop.
    ///
    /// `HostAppState` sends the active connection's departure as two
    /// signals — `connection = .disconnected` from the roster publisher and
    /// `guestLeft` from the state one — so this drives both, the way a real
    /// disconnect would.
    func testGuestDepartureFromAStreamingSessionBecomesGuestGone() async throws {
        let rig = try await rig()
        defer { rig.guest.connection.cancel(); rig.listener.stop() }

        rig.model.startSession()
        try await waitUntil("streaming") {
            rig.model.sessionState == .streaming
        }
        let key = try XCTUnwrap(rig.listener.activeKey)
        rig.model.connection = .disconnected
        rig.model.guestLeft(key)

        XCTAssertEqual(rig.model.sessionState, .guestGone)
        XCTAssertFalse(rig.model.canStartSession,
                       "a departed guest must not still look startable")
        XCTAssertFalse(rig.model.canFetch,
                       "the loop cannot run with nothing on the wire")
    }

    /// A guest leaving a session that was never started, or already
    /// stopped, has nothing to lose — the departure must not manufacture a
    /// session state that was never true.
    func testGuestDepartureLeavesANeverStartedSessionAlone() async throws {
        let rig = try await rig()
        defer { rig.guest.connection.cancel(); rig.listener.stop() }

        rig.model.guestLeft(try XCTUnwrap(rig.listener.activeKey))
        XCTAssertEqual(rig.model.sessionState, .notStarted)
    }

    /// Content held from one guest must not answer for the next: the keys
    /// are psn/title on ONE machine's windows, and a departure resets the
    /// hold the same way it resets the probe token and the ring cursor.
    ///
    /// The rig's `FakeGuest` stays on the same socket throughout — `guestLeft`
    /// is the app's own notification that a guest departed, independent of
    /// the transport itself, so this can drive it by hand and then fetch
    /// again from the very same simulated Mac. The fixture's window key
    /// (`"0.1/Window"`) is unchanged between the two fetches on purpose: a
    /// hold that survived the departure would still answer for it.
    func testGuestDepartureForgetsHeldContent() async throws {
        let rig = try await rig(contentOps: 4)
        defer { rig.guest.connection.cancel(); rig.listener.stop() }

        rig.model.fetchScene(withContent: true)
        try await waitUntil("content joined") {
            rig.model.scene?.windows.first?.display != nil
        }
        let key = try XCTUnwrap(rig.listener.activeKey)
        rig.model.guestLeft(key)
        XCTAssertNil(rig.model.scene, "a live scene leaves with its guest")

        guard case .connected(let name) = rig.listener.state else {
            return XCTFail("expected the listener to still be connected")
        }
        rig.model.connection = .connected(name: name, key: key)
        rig.model.fetchScene()
        try await waitUntil("a fresh scene") { rig.model.scene != nil }
        try await settle()

        XCTAssertNil(rig.model.scene?.windows.first?.display,
                     "content held from a departed guest answered for the "
                         + "next connection's identically-keyed window")
    }

    // MARK: - config plumbing

    private func suiteDefaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(
            suiteName: "now.tests.mirror-session.\(UUID().uuidString)"))
    }

    func testProbeIntervalPersistsAcrossModels() throws {
        let defaults = try suiteDefaults()
        let first = MirrorModuleModel(defaults: defaults)
        XCTAssertEqual(first.probeInterval,
                       MirrorModuleModel.WatchPolicy.live.probeInterval,
                       "a fresh suite must seed from the live policy")
        first.setProbeInterval(1.5)

        let second = MirrorModuleModel(defaults: defaults)
        XCTAssertEqual(second.probeInterval, 1.5,
                       "a persisted probe interval did not survive a new "
                           + "model reading the same defaults")
    }

    func testRefreshCeilingPersistsAcrossModels() throws {
        let defaults = try suiteDefaults()
        let first = MirrorModuleModel(defaults: defaults)
        first.setRefreshCeiling(12)

        let second = MirrorModuleModel(defaults: defaults)
        XCTAssertEqual(second.refreshCeiling, 12)
    }

    func testContentGraceFetchesPersistsAcrossModels() throws {
        let defaults = try suiteDefaults()
        let first = MirrorModuleModel(defaults: defaults)
        XCTAssertEqual(first.contentGraceFetches,
                       MirrorModuleModel.defaultContentGraceFetches)
        first.setContentGraceFetches(5)

        let second = MirrorModuleModel(defaults: defaults)
        XCTAssertEqual(second.contentGraceFetches, 5)
    }
}
