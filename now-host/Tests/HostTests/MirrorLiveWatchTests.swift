import Foundation
import XCTest
@testable import Host
import MirrorKit

/// **The watch loop: what makes the Mirror page a mirror rather than a
/// screenshot viewer, and what keeps it from being a metronome.**
///
/// Every test here drives a real `GuestListener` over a real loopback socket
/// with a `FakeGuest` answering, because the properties at risk live in the
/// seams — what goes on the wire, and what does not.
///
/// The loop is driven by hand (`WatchPolicy.manual`) rather than by its
/// timer. A suite whose assertions depend on a real half-second passing is a
/// suite that fails on a busy machine, and the timer is one `scheduledTimer`
/// call away from the same `watchTick()` these tests call.
///
/// The properties, and why each is the one that would pass by accident:
///
/// - **An unchanged Mac costs no transfer.** The whole argument for a probe
///   is this ratio. A loop that fetched every tick would pass any test that
///   only asserted "the page updates".
/// - **The ceiling fetches anyway.** The probe cannot see a window move, so
///   a loop that trusted it completely would sit on a wrong picture calling
///   itself live — and would pass every test written against a probe that
///   *does* change.
/// - **A guest refusal stops the loop.** Otherwise a guest that does not
///   serve scenes at all is asked forever, which nothing in a green suite
///   would ever show.
@MainActor
final class MirrorLiveWatchTests: XCTestCase {

    // MARK: - rig

    private struct NotConnected: Error {}

    private struct Rig {
        let listener: GuestListener
        let guest: FakeGuest
        let model: MirrorModuleModel
    }

    /// The front-process block `axsnap` answers with, as the guest writes it.
    private static func axsnap(front: String, hasWindows: Bool = true,
                               stampTicks: Int) -> [String: JSONValue] {
        ["axsnap": .object([
            "front": .object([
                "name": .string(front),
                "signature": .string("MACS"),
                "serialHi": .number(0),
                "serialLo": .number(8_192),
                "front": .bool(true),
                "bind": .string("psn"),
                "stampTicks": .number(Double(stampTicks)),
                "hasWindows": .bool(hasWindows),
                "hasMenus": .bool(true),
            ]),
            "references": .object([
                "live": .number(3), "minted": .number(9),
                "evicted": .number(6), "capacity": .number(32),
            ]),
        ])]
    }

    /// A guest that answers `axsnap` with whatever the test currently wants
    /// in front, and serves a scene for every `scene.request`.
    private func rig(front: @escaping () -> String?,
                     serveScenes: Bool = true) async throws -> Rig {
        let (listener, guest) = try await connectedListener()
        guest.onMessage = { message in
            switch message {
            case .commandRequest(let request)
                where request.name == MirrorSceneProbe.command:
                guard let name = front() else {
                    try? guest.send(.commandResult(.init(
                        id: request.id, ok: false, output: nil,
                        error: .init(code: "unknown-command",
                                     message: "this Mac serves no axsnap"))))
                    return
                }
                /* The ticks move on every answer, exactly as the guest's own
                   `emit_process_head` does. A token that folded them in
                   would report a change on every single probe. */
                try? guest.send(.commandResult(.init(
                    id: request.id, ok: true, output: nil,
                    outputObjects: Self.axsnap(
                        front: name,
                        stampTicks: Int(Date().timeIntervalSince1970 * 60)),
                    error: nil)))
            case .sceneRequest(let request):
                guard serveScenes else {
                    try? guest.send(.sceneEnd(SceneEnd(
                        id: request.id, transfer: 1, ok: false,
                        reason: "no scene plane on this Mac", sendMs: 0)))
                    return
                }
                try? Self.serve(scene: Self.document, id: request.id,
                                to: guest)
            default:
                break
            }
        }
        let model = MirrorModuleModel(listener: listener,
                                      watch: .manual)
        let key = try XCTUnwrap(listener.activeKey)
        guard case .connected(let name) = listener.state else {
            throw NotConnected()
        }
        model.connection = .connected(name: name, key: key)
        return Rig(listener: listener, guest: guest, model: model)
    }

    private static let document = """
        {"version":1,"seq":4,"source":"peek","capturedAt":1750000000,\
        "screen":{"w":640,"h":480},"apps":[],"windows":[],\
        "meta":{"errors":[]}}
        """

    private static func serve(scene document: String, id: Int,
                              to guest: FakeGuest) throws {
        let body = Data(document.utf8)
        try guest.send(.sceneBegin(SceneBegin(
            id: id, transfer: 9, bytes: body.count, irVersion: 1, seq: 4,
            capturedAt: 1_750_000_000, source: "peek", walkMs: 3)))
        guest.sendRaw(try FrameCodec.encode(
            channel: .bulk, flags: [.end], transfer: 9, payload: body))
        try guest.send(.sceneEnd(SceneEnd(id: id, transfer: 9, ok: true,
                                          reason: nil, sendMs: 1)))
    }

    private func sceneRequests(_ guest: FakeGuest) -> Int {
        guest.received.filter {
            if case .sceneRequest = $0 { return true }
            return false
        }.count
    }

    private func probes(_ guest: FakeGuest) -> Int {
        guest.received.filter {
            if case .commandRequest(let r) = $0 {
                return r.name == MirrorSceneProbe.command
            }
            return false
        }.count
    }

    private func settle(_ seconds: Double = 0.25) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
    }

    // MARK: - the ratio the probe exists for

    /// **A Mac where nothing moved costs control messages, not transfers.**
    ///
    /// This is the whole argument. The first tick fetches (there is nothing
    /// on screen), and every tick after it inside the ceiling asks the cheap
    /// question and stops there.
    func testAnUnchangedMacIsProbedRatherThanFetched() async throws {
        let rig = try await rig(front: { "Finder" })
        defer { rig.guest.connection.cancel(); rig.listener.stop() }

        rig.model.watchTick()
        try await settle()
        XCTAssertEqual(sceneRequests(rig.guest), 1,
                       "the first tick has nothing on screen and must fetch")

        for _ in 0..<6 {
            rig.model.watchTick()
            try await settle(0.05)
        }
        try await settle()

        XCTAssertEqual(
            sceneRequests(rig.guest), 1,
            "a tick spent a transfer on a Mac where nothing changed. The "
                + "probe is the only reason this loop is allowed to run at "
                + "half a second; a loop that fetches anyway is the poll "
                + "the lane argument was about.")
        XCTAssertGreaterThanOrEqual(
            probes(rig.guest), 5,
            "the cheap question was not asked either — this loop is not "
                + "running at all, and the assertion above proves nothing")
    }

    /// A change in what is in front spends a transfer, promptly.
    func testAChangeInFrontFetchesAScene() async throws {
        var front = "Finder"
        let rig = try await rig(front: { front })
        defer { rig.guest.connection.cancel(); rig.listener.stop() }

        rig.model.watchTick()          // the first fetch
        try await settle()
        rig.model.watchTick()          // establishes the probe's baseline
        try await settle()
        XCTAssertEqual(sceneRequests(rig.guest), 1)

        front = "SimpleText"
        rig.model.watchTick()
        try await settle()

        XCTAssertEqual(sceneRequests(rig.guest), 2,
                       "the front application changed and the page did not "
                           + "ask for a scene")
    }

    /// **The ceiling fetches even when the probe says nothing moved.**
    ///
    /// `axsnap` reports the front process; a window dragged inside one
    /// application changes none of its fields. Without this the page would
    /// hold a wrong picture indefinitely while reporting itself live, and
    /// every probe-driven test above would still be green.
    func testTheCeilingRefreshesWhatTheProbeCannotSee() async throws {
        let rig = try await rig(front: { "Finder" })
        defer { rig.guest.connection.cancel(); rig.listener.stop() }

        rig.model.watchTick()
        try await settle()
        XCTAssertEqual(sceneRequests(rig.guest), 1)

        /* A tick from far enough in the future that the drawing is older
           than the ceiling — the same decision the timer's tick makes, taken
           without waiting five seconds for it. */
        rig.model.watchTick(
            now: Date().addingTimeInterval(rig.model.watch.refreshCeiling + 1))
        try await settle()

        XCTAssertEqual(
            sceneRequests(rig.guest), 2,
            "the drawing aged past the ceiling and nothing refreshed it. A "
                + "probe that cannot see a window move is only safe because "
                + "of this fetch.")
    }

    // MARK: - a person's switch

    /// Paused means paused: no transfer, and not even the cheap question.
    func testPausedAsksTheMacNothing() async throws {
        let rig = try await rig(front: { "Finder" })
        defer { rig.guest.connection.cancel(); rig.listener.stop() }

        rig.model.setLive(false)
        try await settle()
        let scenesAtPause = sceneRequests(rig.guest)
        let probesAtPause = probes(rig.guest)

        for _ in 0..<5 {
            rig.model.watchTick(
                now: Date().addingTimeInterval(60))   // well past the ceiling
            try await settle(0.05)
        }
        try await settle()

        XCTAssertEqual(sceneRequests(rig.guest), scenesAtPause,
                       "a paused page asked for a scene")
        XCTAssertEqual(probes(rig.guest), probesAtPause,
                       "a paused page kept polling the Mac with the cheap "
                           + "question. Paused is a statement about the "
                           + "wire, not about the drawing.")

        // And the manual ask still works while paused — the button is not
        // the loop.
        rig.model.fetchScene()
        try await settle()
        XCTAssertEqual(sceneRequests(rig.guest), scenesAtPause + 1)
    }

    /// **A guest that refuses stops the loop.** It was asked, it answered,
    /// and the answer was no; asking it again every ceiling forever is a
    /// loop nobody is reading.
    func testAGuestRefusalStopsLiveUpdating() async throws {
        let rig = try await rig(front: { "Finder" }, serveScenes: false)
        defer { rig.guest.connection.cancel(); rig.listener.stop() }

        rig.model.watchTick()
        try await settle()

        XCTAssertFalse(rig.model.isLive,
                       "the Mac refused a scene and the loop kept running")
        XCTAssertNotNil(rig.model.liveNote,
                        "live updating stopped and the page says nothing "
                            + "about why")
        let after = sceneRequests(rig.guest)
        for _ in 0..<3 {
            rig.model.watchTick(now: Date().addingTimeInterval(60))
            try await settle(0.05)
        }
        try await settle()
        XCTAssertEqual(sceneRequests(rig.guest), after,
                       "a stopped loop asked again")

        /* Resuming forgives it: the refusal was true when it was written and
           is not a fact about the Mac now, so the loop asks again. This
           guest still refuses, so it stops again — which is the loop
           working, and is why the note is rewritten rather than left
           standing from the first time. */
        rig.model.setLive(true)
        try await settle()
        XCTAssertGreaterThan(sceneRequests(rig.guest), after,
                             "resuming did not ask the Mac anything")
        XCTAssertFalse(rig.model.isLive)
        XCTAssertNotNil(rig.model.liveNote)
    }

    /// **A collision backs off and says so; it does not queue.**
    ///
    /// The lane is held by a capture, so this side refuses locally. The loop
    /// must not turn that into a retry every tick — and must not queue the
    /// ask behind the capture either, which is the shape that lands somebody
    /// else's refusal in the middle of their download.
    func testACollisionBacksOffRatherThanQueueing() async throws {
        let rig = try await rig(front: { "Finder" })
        defer { rig.guest.connection.cancel(); rig.listener.stop() }

        rig.listener.requestCapture(depth: 8) { _ in }
        try await settle()

        rig.model.watchTick()
        try await settle()

        XCTAssertEqual(sceneRequests(rig.guest), 0,
                       "a scene.request went out over a held lane")
        XCTAssertTrue(rig.model.isLive,
                      "a collision with somebody else's transfer is the "
                          + "system working, not a reason to stop")
        let note = try XCTUnwrap(rig.model.liveNote)
        XCTAssertTrue(note.lowercased().contains("lane"),
                      "the page does not say what the loop is waiting on: "
                          + "\(note)")

        /* The hold is a hold: the very next tick asks nothing at all, which
           is what "backs off" means as against "retries immediately". */
        let probesSoFar = probes(rig.guest)
        rig.model.watchTick()
        try await settle()
        XCTAssertEqual(probes(rig.guest), probesSoFar,
                       "the loop kept asking through its own back-off")
    }

    /// A guest with no `axsnap` is not hammered and is not lied about: the
    /// probe is disabled, the page says so, and the ceiling carries the
    /// loop on its own.
    func testAGuestWithoutTheProbeFallsBackToTheCeiling() async throws {
        let rig = try await rig(front: { nil })
        defer { rig.guest.connection.cancel(); rig.listener.stop() }

        rig.model.watchTick()                     // fetch
        try await settle()
        rig.model.watchTick()                     // probe → unsupported
        try await settle()

        XCTAssertFalse(rig.model.probeUsable)
        XCTAssertNotNil(rig.model.liveNote)
        let probesSoFar = probes(rig.guest)

        rig.model.watchTick()
        try await settle()
        XCTAssertEqual(probes(rig.guest), probesSoFar,
                       "the probe was asked again after the Mac said it "
                           + "does not serve it")

        rig.model.watchTick(
            now: Date().addingTimeInterval(rig.model.watch.refreshCeiling + 1))
        try await settle()
        XCTAssertEqual(sceneRequests(rig.guest), 2,
                       "with no probe the ceiling IS the loop, and it did "
                           + "not run")
    }

    /// The loop's memory is about one machine and dies with it. A token
    /// carried across would make the first tick of the next connection
    /// report a change that is really a change of Mac.
    func testTheLoopForgetsTheMachineThatLeft() async throws {
        let rig = try await rig(front: { "Finder" })
        defer { rig.guest.connection.cancel(); rig.listener.stop() }

        rig.model.watchTick()
        try await settle()
        XCTAssertNotNil(rig.model.lastSceneAt)

        rig.model.guestLeft(try XCTUnwrap(rig.listener.activeKey))
        XCTAssertNil(rig.model.lastSceneAt)
        XCTAssertNil(rig.model.lastAction)
    }
}
