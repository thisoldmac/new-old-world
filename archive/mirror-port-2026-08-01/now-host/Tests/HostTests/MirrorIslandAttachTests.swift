import Foundation
import XCTest
@testable import Host
import MirrorKit

/// **The pixel-island fallback, from a landed scene to a window's pixels.**
///
/// `SceneIslands` — the policy — has been unit-tested since it was ported
/// (`IslandLifecycleTests`), and `GuestListener.requestCaptureRegion` +
/// `CaptureDelivery.makePixelIsland` — the producer — landed this wave. What
/// had never existed is the join between them: `SceneIslands.attach` had zero
/// callers, so no window in this application had ever had pixels. These tests
/// are about that join, and they are written against the properties that make
/// it safe to spend a second of somebody else's Macintosh on a photograph.
///
/// Every test drives a real `GuestListener` over a real loopback socket with
/// a `FakeGuest` answering, the rig `MirrorSessionModelTests` uses — because
/// the sequencing under test (the item walk lands, THEN the plane decides
/// what to photograph) lives in what crosses the wire and in what order.
/// Only the capture itself is faked, through the model's own injection seam:
/// a real `capture.region` reply is `CaptureDecoderTests`' subject, not this
/// file's.
@MainActor
final class MirrorIslandAttachTests: XCTestCase {

    // MARK: - the fake capture

    /// Every rect the island plane asked a machine for, in order.
    ///
    /// `beforeReturning` is the hook the no-deadlock test needs: it runs
    /// while the capture is outstanding, which is exactly the window in which
    /// a blocking bridge would have the main queue held.
    @MainActor
    private final class CaptureSpy {
        private(set) var asked: [MirrorKit.Rect] = []
        var beforeReturning: (@MainActor () async -> Void)?
        /// Fills each returned island with a distinct byte so a held island
        /// can be told from a fresh one.
        private var fill: UInt8 = 1

        func capture(_ rect: MirrorKit.Rect) async throws -> PixelIsland {
            asked.append(rect)
            await beforeReturning?()
            defer { fill &+= 1 }
            let w = max(1, rect.r - rect.l), h = max(1, rect.b - rect.t)
            return PixelIsland(
                width: w, height: h,
                rgba: Data([UInt8](repeating: fill, count: w * h * 4)),
                originX: rect.l, originY: rect.t, scale: 1)
        }

        func timesAsked(for rect: MirrorKit.Rect) -> Int {
            asked.filter { $0 == rect }.count
        }
    }

    // MARK: - the rig

    private struct Rig {
        let listener: GuestListener
        let guest: FakeGuest
        let model: MirrorModuleModel
        let spy: CaptureSpy
    }

    /// One window's JSON, in the IR the guest actually sends.
    private static func window(app: String, psn: String, title: String,
                               rect: (Int, Int, Int, Int), front: Bool,
                               z: Int) -> String {
        """
        {"id":"\(psn)/\(title)#\(z)","app":"\(app)","psn":"\(psn)",\
        "title":"\(title)",\
        "rect":{"l":\(rect.0),"t":\(rect.1),"r":\(rect.2),"b":\(rect.3)},\
        "front":\(front),"z":\(z),"visible":true}
        """
    }

    private static func scene(seq: Int, _ windows: [String]) -> String {
        """
        {"version":1,"seq":\(seq),"capturedAt":\(1_750_000_000 + seq).0,\
        "source":"peek","screen":{"w":640,"h":480},\
        "windows":[\(windows.joined(separator: ","))],\
        "meta":{"errors":[]}}
        """
    }

    /// The content rect the island plane will ask for, for a document window
    /// at these bounds. Derived through `SceneGeometry` rather than restated,
    /// so a test asserting on a rect cannot drift from the inset the
    /// renderer and the policy share.
    private static func contentRect(_ r: (Int, Int, Int, Int))
        -> MirrorKit.Rect {
        let win = MirrorKit.Scene.Window.make(
            id: "x", app: "A", psn: "0.1", title: "t", kind: 0,
            rect: MirrorKit.Rect(l: r.0, t: r.1, r: r.2, b: r.3),
            front: false, z: 0, visible: true, controls: [])
        return SceneGeometry.contentRect(win)
    }

    /// A `script` reply carrying one Finder window's items — the shape
    /// `input_cmds.c`'s `reply_rows` emits, transcribed the way
    /// `MirrorFolderItemsJoinTests` does.
    private static func scriptReply(id: Int, records: String) -> String {
        let escaped = records.replacingOccurrences(of: "\"", with: "\\\"")
        return "{\"type\":\"command.result\",\"id\":\(id),\"ok\":true,"
            + "\"output\":{\"script\":[[\"output\",\"\(escaped)\"],"
            + "[\"osaErr\",\"0\"],[\"truncated\",\"false\"]]}}"
    }

    /// A `qdtrace drain` carrying ONE large screen blit over the front
    /// window — the redraw signal the island policy signs its held pixels
    /// with. `dst` only, no `src`: a blit with no screen source is a repaint,
    /// not the scroll the MoveBits fast path is for.
    private static func drainReply(id: Int, ticks: Int, cursor: Int,
                                   dst: (Int, Int, Int, Int)) -> String {
        let op = "{\"op\":\"bits\",\"port\":\"0x00aa00\",\"ticks\":\(ticks),"
            + "\"dst\":[\(dst.0),\(dst.1),\(dst.2),\(dst.3)]}"
        return "{\"type\":\"command.result\",\"id\":\(id),\"ok\":true,"
            + "\"output\":{\"qdtrace\":{\"cmd\":\"drain\",\"ops\":[\(op)],"
            + "\"cursor\":0,\"nextCursor\":\(cursor),"
            + "\"writeCursor\":\(cursor),\"pending\":0,\"records\":1,"
            + "\"wraps\":0,\"more\":false,\"resync\":false,\"torn\":false,"
            + "\"busy\":false,\"lostBytes\":0,\"dropped\":0}}}"
    }

    /// A guest that serves whatever `sceneJSON` currently holds, answers the
    /// Finder walk with `scriptRecords`, and answers `qdtrace` with a blit at
    /// `blitTicks` (or refuses it outright when `servesQDTrace` is false, the
    /// way a Mac with no QDPeek does).
    private final class GuestScript {
        var sceneJSON: String
        var scriptRecords: String
        var servesQDTrace: Bool
        var blitTicks = 100
        var blitDst = (0, 0, 390, 237)
        var transfer = 100

        init(sceneJSON: String, scriptRecords: String = "\"\"",
             servesQDTrace: Bool = false) {
            self.sceneJSON = sceneJSON
            self.scriptRecords = scriptRecords
            self.servesQDTrace = servesQDTrace
        }
    }

    private func rig(_ script: GuestScript) async throws -> Rig {
        let (listener, guest) = try await connectedListener()
        var cursor = 96
        guest.onMessage = { message in
            switch message {
            case .sceneRequest(let request):
                let body = Data(script.sceneJSON.utf8)
                script.transfer += 1
                let transfer = script.transfer
                try? guest.send(.sceneBegin(SceneBegin(
                    id: request.id, transfer: transfer, bytes: body.count,
                    irVersion: 1, seq: 7, capturedAt: 1_750_000_000,
                    source: "peek", walkMs: 3)))
                guest.sendRaw(try! FrameCodec.encode(
                    channel: .bulk, flags: [.end],
                    transfer: UInt16(transfer), payload: body))
                try? guest.send(.sceneEnd(SceneEnd(
                    id: request.id, transfer: transfer, ok: true,
                    reason: nil, sendMs: 1)))
            case .commandRequest(let request) where request.name == "script":
                guest.sendRaw(try! FrameCodec.encode(
                    channel: .control, flags: [.end], transfer: 0,
                    payload: Data(Self.scriptReply(
                        id: request.id,
                        records: script.scriptRecords).utf8)))
            case .commandRequest(let request) where request.name == "qdtrace":
                guard script.servesQDTrace else {
                    try? guest.send(.commandResult(.init(
                        id: request.id, ok: false, output: nil,
                        error: .init(code: "unknown-command",
                                     message: "this Mac serves no qdtrace"))))
                    return
                }
                cursor += 8
                guest.sendRaw(try! FrameCodec.encode(
                    channel: .control, flags: [.end], transfer: 0,
                    payload: Data(Self.drainReply(
                        id: request.id, ticks: script.blitTicks,
                        cursor: cursor, dst: script.blitDst).utf8)))
            case .commandRequest(let request):
                /* Everything else is answered rather than ignored: an
                   unanswered command sits on the listener's watchdog, and a
                   test that waits on one is measuring the watchdog. */
                try? guest.send(.commandResult(.init(
                    id: request.id, ok: true, output: nil, error: nil)))
            default:
                break
            }
        }
        let spy = CaptureSpy()
        let model = MirrorModuleModel(listener: listener, watch: .manual,
                                      islandCapture: spy.capture,
                                      defaults: Self.scratchDefaults())
        let key = try XCTUnwrap(listener.activeKey)
        guard case .connected(let name) = listener.state else {
            throw XCTSkip("guest did not connect")
        }
        model.connection = .connected(name: name, key: key)
        return Rig(listener: listener, guest: guest, model: model, spy: spy)
    }

    /// A defaults suite of this test's own, so a persisted probe interval or
    /// grace count from a developer's app cannot change what these prove.
    private static func scratchDefaults() -> UserDefaults {
        let suite = UserDefaults(suiteName: "mirror.islands.\(UUID())")!
        return suite
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

    // MARK: - (a) objects first

    private static let finderRect = (8, 40, 300, 300)
    private static let notesRect = (320, 40, 600, 300)

    /// **The plane hierarchy, proved at the join.** A Finder window whose
    /// items the walk supplied is a MODEL; the renderer draws items in
    /// preference to any island (`SceneRenderer` tests `win.items == nil`
    /// first), so photographing one spends ~1 s of somebody's Mac on pixels
    /// that can never be shown.
    ///
    /// Non-vacuous by construction: a second window with no semantic source
    /// sits beside it, unoccluded, and IS photographed in the same pass. A
    /// test where nothing was captured would pass even if the plane never
    /// ran.
    ///
    /// **The mutation this test is watching for**: delete
    /// `if scene.windows[i].items != nil { continue }` from
    /// `SceneIslands.attach` and this goes red naming the Finder window's
    /// content rect in the asked list.
    func testAWindowWithFolderItemsIsNeverPhotographed() async throws {
        let script = GuestScript(
            sceneJSON: Self.scene(seq: 1, [
                Self.window(app: "Finder", psn: "0.1", title: "TimBotTu",
                            rect: Self.finderRect, front: true, z: 0),
                Self.window(app: "SimpleText", psn: "0.2", title: "Notes",
                            rect: Self.notesRect, front: false, z: 1),
            ]),
            scriptRecords: "\"W|TimBotTu|Macintosh HD:TimBotTu:;;"
                + "I|tbt-worker|53,25;;\"")
        let rig = try await rig(script)
        defer { rig.guest.connection.cancel(); rig.listener.stop() }

        rig.model.startSession()
        try await waitUntil("the folder walk to land") {
            rig.model.scene?.windows.first?.items != nil
        }
        await rig.model.islandPass()

        let finder = Self.contentRect(Self.finderRect)
        let notes = Self.contentRect(Self.notesRect)
        XCTAssertEqual(rig.spy.timesAsked(for: finder), 0, """
            the Finder window \(finder) was photographed even though the \
            walk had already told this host what is in it — a second of \
            somebody's Mac spent on pixels the renderer refuses to draw. \
            Asked: \(rig.spy.asked)
            """)
        XCTAssertEqual(rig.spy.timesAsked(for: notes), 1,
                       "the window with NO semantic source was not "
                           + "photographed, so this test proves nothing "
                           + "about the one that has: \(rig.spy.asked)")
        XCTAssertNil(rig.model.scene?.windows.first?.island,
                     "a window drawn from items must carry no island")
        XCTAssertNotNil(rig.model.scene?.windows.last?.island,
                        "the fallback window never got its pixels")
    }

    // MARK: - (b) occlusion

    /// A capture reads a SCREEN region, so a covered window returns whatever
    /// is on top of it — someone else's pixels under this window's name. The
    /// covered window is left alone; being raised is what makes a photograph
    /// of it truthful.
    func testACoveredWindowIsNeverPhotographed() async throws {
        let front = (8, 40, 400, 300)
        let under = (200, 100, 500, 350)
        let script = GuestScript(sceneJSON: Self.scene(seq: 1, [
            Self.window(app: "SimpleText", psn: "0.2", title: "Front",
                        rect: front, front: true, z: 0),
            Self.window(app: "SimpleText", psn: "0.3", title: "Under",
                        rect: under, front: false, z: 1),
        ]))
        let rig = try await rig(script)
        defer { rig.guest.connection.cancel(); rig.listener.stop() }

        rig.model.startSession()
        try await waitUntil("a scene") { rig.model.scene != nil }
        await rig.model.islandPass()

        XCTAssertEqual(rig.spy.timesAsked(for: Self.contentRect(under)), 0,
                       "a covered window was photographed; the reply would "
                           + "carry the front window's pixels labelled as "
                           + "this one's. Asked: \(rig.spy.asked)")
        XCTAssertEqual(rig.spy.timesAsked(for: Self.contentRect(front)), 1,
                       "the uncovered front window was not photographed, so "
                           + "this test proves nothing: \(rig.spy.asked)")
        XCTAssertNil(rig.model.scene?.windows.last?.island,
                     "a covered window must stay empty rather than wear "
                         + "somebody else's pixels")
    }

    // MARK: - (c) hold on blur

    /// The product rule the whole plane exists for: an interior updates while
    /// its window is focused, and otherwise shows the last thing seen. It
    /// must survive BOTH the blur and the fetch that follows it — a fresh
    /// scene decodes every island back to nil, so holding is a decision, not
    /// an absence of one.
    func testABlurredWindowKeepsItsIslandAndIsNotRephotographed()
        async throws {
        let a = (8, 40, 300, 300)
        let b = (320, 40, 600, 300)
        let script = GuestScript(sceneJSON: Self.scene(seq: 1, [
            Self.window(app: "SimpleText", psn: "0.2", title: "A",
                        rect: a, front: true, z: 0),
            Self.window(app: "SimpleText", psn: "0.3", title: "B",
                        rect: b, front: false, z: 1),
        ]))
        let rig = try await rig(script)
        defer { rig.guest.connection.cancel(); rig.listener.stop() }

        rig.model.startSession()
        try await waitUntil("a scene") { rig.model.scene != nil }
        await rig.model.islandPass()
        let held = try XCTUnwrap(rig.model.scene?.windows.first?.island,
                                "A was never photographed while it was front")
        let heldByte = held.rgba.first
        XCTAssertEqual(rig.spy.timesAsked(for: Self.contentRect(a)), 1)

        /* B comes forward. A is now blurred, and the next scene arrives with
           `island == nil` on both windows. */
        script.sceneJSON = Self.scene(seq: 2, [
            Self.window(app: "SimpleText", psn: "0.3", title: "B",
                        rect: b, front: true, z: 0),
            Self.window(app: "SimpleText", psn: "0.2", title: "A",
                        rect: a, front: false, z: 1),
        ])
        rig.model.fetchScene()
        try await waitUntil("the second scene") {
            rig.model.scene?.windows.first?.title == "B"
        }
        await rig.model.islandPass()

        let blurred = try XCTUnwrap(rig.model.scene?.windows.last?.island,
                                    "a blurred window lost its interior and "
                                        + "reads as empty chrome")
        XCTAssertEqual(blurred.rgba.first, heldByte,
                       "the blurred window's island is not the one it was "
                           + "holding — it was re-read rather than held")
        XCTAssertEqual(rig.spy.timesAsked(for: Self.contentRect(a)), 1,
                       "a blurred window was photographed again; only the "
                           + "front window re-reads: \(rig.spy.asked)")
    }

    // MARK: - (d) the redraw signal

    /// **What makes a window re-photograph is a redraw, not a clock.** The
    /// policy signs each held island with its content rect plus the newest
    /// large blit over it, and those blits are the qdtrace ops the content
    /// join already drains. Same ops, however many passes: one capture. A
    /// new blit tick: exactly one more.
    func testARedrawTriggersExactlyOneRecapture() async throws {
        let front = (8, 40, 400, 300)
        let script = GuestScript(
            sceneJSON: Self.scene(seq: 1, [
                Self.window(app: "SimpleText", psn: "0.2", title: "Doc",
                            rect: front, front: true, z: 0),
            ]),
            servesQDTrace: true)
        script.blitTicks = 100
        let rig = try await rig(script)
        defer { rig.guest.connection.cancel(); rig.listener.stop() }
        let content = Self.contentRect(front)

        rig.model.startSession()
        try await waitUntil("content joined") {
            rig.model.scene?.windows.first?.display?.isEmpty == false
        }
        await rig.model.islandPass()
        XCTAssertEqual(rig.spy.timesAsked(for: content), 1,
                       "the first sight of a window must be photographed "
                           + "once: \(rig.spy.asked)")

        /* Passes over the same drawing. The blit tick has not moved, so
           nothing about this window's interior has changed and re-reading it
           would be a second on the wire for a picture already held. */
        await rig.model.islandPass()
        rig.model.fetchScene(withContent: true)
        try await waitUntil("a second scene") { rig.model.lastSeq != nil }
        try await settle()
        await rig.model.islandPass()
        XCTAssertEqual(rig.spy.timesAsked(for: content), 1,
                       "a window was re-photographed with no redraw behind "
                           + "it — the plane is running on a clock rather "
                           + "than on the blit ticks: \(rig.spy.asked)")

        /* The guest draws. One new large blit over the content area is the
           whole signal. */
        script.blitTicks = 400
        rig.model.fetchScene(withContent: true)
        try await waitUntil("the redrawn scene") {
            rig.model.scene?.windows.first?.display?
                .contains { $0.ticks == 400 } == true
        }
        await rig.model.islandPass()
        XCTAssertEqual(rig.spy.timesAsked(for: content), 2,
                       "a redraw did not produce exactly one recapture: "
                           + "\(rig.spy.asked)")
    }

    // MARK: - (e) the async path, and the deadlock it is shaped to avoid

    /// **The design decision this file exists to prove.**
    /// `requestCaptureRegion` is completion-based; `SceneIslands.Capture`
    /// used to be synchronous. Bridging the two with a semaphore was the
    /// obvious move and it cannot work: NOW's socket runs on `.main`, every
    /// received byte is delivered inside `Task { @MainActor }`
    /// (`Session.receiveLoop`), the 20 s watchdog is a
    /// `DispatchQueue.main.asyncAfter`, and the caller is `@MainActor`. A
    /// wait on the main queue would block the only path by which the reply —
    /// or the timeout that gives up on it — could ever arrive.
    ///
    /// So the property is: **the listener keeps working while a capture is
    /// outstanding**. This test proves it the only way that means anything —
    /// by running a real control round trip to the FakeGuest over the real
    /// socket from INSIDE the capture, and requiring it to complete.
    ///
    /// **If this property is broken, this test HANGS rather than fails.**
    /// That is not an oversight; the main queue is the thing under test, and
    /// a blocked one cannot run an assertion or a timeout either. Named here
    /// so that whoever meets a hung `swift test` after touching the island
    /// path knows where to look first.
    func testTheListenerKeepsAnsweringWhileACaptureIsOutstanding()
        async throws {
        let front = (8, 40, 400, 300)
        let script = GuestScript(sceneJSON: Self.scene(seq: 1, [
            Self.window(app: "SimpleText", psn: "0.2", title: "Doc",
                        rect: front, front: true, z: 0),
        ]))
        let rig = try await rig(script)
        defer { rig.guest.connection.cancel(); rig.listener.stop() }

        var roundTripsInsideACapture = 0
        var mainActorTurnsInsideACapture = 0
        rig.spy.beforeReturning = { [listener = rig.listener] in
            /* Ordinary main-actor work, enqueued and awaited from inside the
               capture. A blocking bridge would never let this turn run. */
            await Task { @MainActor in mainActorTurnsInsideACapture += 1 }.value
            /* The real proof: a command to the guest and back, over the
               loopback socket, while the pass is suspended. Its reply can
               only be consumed by `Session.receiveLoop`'s main-actor hop. */
            let result: CommandResult = await withCheckedContinuation {
                continuation in
                listener.runCommand("axsnap") {
                    continuation.resume(returning: $0)
                }
            }
            XCTAssertTrue(result.ok,
                          "the guest answered, but not ok — the round trip "
                              + "is what this test measures, so a refusal "
                              + "here means the rig, not the property")
            roundTripsInsideACapture += 1
        }

        rig.model.startSession()
        try await waitUntil("a scene") { rig.model.scene != nil }
        await rig.model.islandPass()

        XCTAssertEqual(rig.spy.asked.count, 1,
                       "no capture ran, so nothing was proved about what "
                           + "happens during one")
        XCTAssertEqual(mainActorTurnsInsideACapture, 1,
                       "main-actor work enqueued during a capture never ran")
        XCTAssertEqual(roundTripsInsideACapture, 1,
                       "the listener did not complete a round trip while a "
                           + "capture was outstanding")
        XCTAssertNotNil(rig.model.scene?.windows.first?.island,
                        "the pass suspended and never delivered its pixels")
    }

    // MARK: - the session owns the plane

    /// Capture is a session's privilege. Outside one there is nobody
    /// watching, and ~1 s of somebody's Mac per window is not something to
    /// spend on a page nobody asked to be live.
    func testNothingIsPhotographedOutsideASession() async throws {
        let front = (8, 40, 400, 300)
        let script = GuestScript(sceneJSON: Self.scene(seq: 1, [
            Self.window(app: "SimpleText", psn: "0.2", title: "Doc",
                        rect: front, front: true, z: 0),
        ]))
        let rig = try await rig(script)
        defer { rig.guest.connection.cancel(); rig.listener.stop() }

        rig.model.fetchScene()               // a fetch, with no session
        try await waitUntil("a scene") { rig.model.scene != nil }
        await rig.model.islandPass()
        XCTAssertEqual(rig.spy.asked, [],
                       "a window was photographed with no session running")

        rig.model.startSession()
        try await waitUntil("a session") {
            rig.model.sessionState == .streaming
        }
        await rig.model.islandPass()
        XCTAssertEqual(rig.spy.asked.count, 1,
                       "a started session photographs the window with no "
                           + "semantic source: \(rig.spy.asked)")

        /* Stop drops the store. The scene on screen keeps what it was
           already drawn with — Stop means "not updating any more" — but a
           later pass must ask again rather than serve pixels from a Mac that
           has had a while to change. */
        rig.model.stopSession()
        XCTAssertNotNil(rig.model.scene?.windows.first?.island,
                        "Stop wiped the drawing instead of freezing it")
        await rig.model.islandPass()
        XCTAssertEqual(rig.spy.asked.count, 1,
                       "a stopped session went on photographing")

        rig.model.startSession()
        try await waitUntil("a resumed session") {
            rig.model.sessionState == .streaming
        }
        await rig.model.islandPass()
        XCTAssertEqual(rig.spy.asked.count, 2,
                       "a restarted session served pixels held from before "
                           + "the stop rather than reading them again")
    }

    // MARK: - the pixel-draw toggle: the hard guarantee

    /// **The hard guarantee, proved at the join.** Off means no capture is
    /// requested at all — a stronger claim than "the reply says no", which
    /// is why the gate lives before `islandCapture` is ever reached rather
    /// than in a closure that always refuses (a refused capture still costs
    /// a round trip).
    ///
    /// **The mutation this test is watching for**: delete the
    /// `pixelDrawEnabled` guard from `scheduleIslandPass` or `onePass` and
    /// this goes red with the spy's list non-empty.
    func testNothingIsPhotographedWithPixelDrawOff() async throws {
        let front = (8, 40, 400, 300)
        let script = GuestScript(sceneJSON: Self.scene(seq: 1, [
            Self.window(app: "SimpleText", psn: "0.2", title: "Doc",
                        rect: front, front: true, z: 0),
        ]))
        let rig = try await rig(script)
        defer { rig.guest.connection.cancel(); rig.listener.stop() }

        rig.model.setPixelDrawEnabled(false)
        rig.model.startSession()
        try await waitUntil("a session") {
            rig.model.sessionState == .streaming
        }
        await rig.model.islandPass()

        XCTAssertEqual(rig.spy.asked, [],
                       "a capture was requested with the hard guarantee "
                           + "off: \(rig.spy.asked)")
        XCTAssertNil(rig.model.scene?.windows.first?.island,
                     "a window carried pixels with pixel draw off")
    }

    /// A held photograph is still pixels on screen. Turning the toggle off
    /// mid-session must drop what is already held, not merely stop taking
    /// new ones — leaving it up would make the guarantee a lie for exactly
    /// the window it was already showing.
    func testTurningPixelDrawOffMidSessionDropsHeldIslands() async throws {
        let front = (8, 40, 400, 300)
        let script = GuestScript(sceneJSON: Self.scene(seq: 1, [
            Self.window(app: "SimpleText", psn: "0.2", title: "Doc",
                        rect: front, front: true, z: 0),
        ]))
        let rig = try await rig(script)
        defer { rig.guest.connection.cancel(); rig.listener.stop() }

        rig.model.startSession()
        try await waitUntil("a scene") { rig.model.scene != nil }
        await rig.model.islandPass()
        XCTAssertNotNil(rig.model.scene?.windows.first?.island,
                        "nothing was held, so dropping it proves nothing")

        rig.model.setPixelDrawEnabled(false)
        XCTAssertNil(rig.model.scene?.windows.first?.island,
                     "a held photograph stayed on screen after the toggle "
                         + "went off")
    }

    /// The page's own words say why a window went back to empty chrome,
    /// and name the toggle rather than leaving a person to guess whether
    /// something broke.
    func testTurningPixelDrawOffNamesTheToggleInTheNote() throws {
        /* A scratch defaults suite, not the bare default: `pixelDrawEnabled`
           persists, and a model built against `.standard` could start this
           test already off from a prior run on this same machine — which
           would make `setPixelDrawEnabled(false)` a same-value no-op that
           never touches `islandNote` at all. */
        let model = MirrorModuleModel(defaults: Self.scratchDefaults())
        XCTAssertNil(model.islandNote)
        model.setPixelDrawEnabled(false)
        let note = try XCTUnwrap(model.islandNote)
        XCTAssertTrue(
            note.localizedCaseInsensitiveContains("pixel"),
            "the note must name the toggle, not just say pixels vanished: "
                + note)
    }

    /// Flipping it back on must not require a restart — a session already
    /// running picks the fallback plane back up on its own, the same gate
    /// a redraw or a join completing already runs through.
    func testTurningPixelDrawBackOnResumesWithoutARestart() async throws {
        let front = (8, 40, 400, 300)
        let script = GuestScript(sceneJSON: Self.scene(seq: 1, [
            Self.window(app: "SimpleText", psn: "0.2", title: "Doc",
                        rect: front, front: true, z: 0),
        ]))
        let rig = try await rig(script)
        defer { rig.guest.connection.cancel(); rig.listener.stop() }

        rig.model.setPixelDrawEnabled(false)
        rig.model.startSession()
        try await waitUntil("a session") {
            rig.model.sessionState == .streaming
        }
        await rig.model.islandPass()
        XCTAssertEqual(rig.spy.asked, [])

        /* Turning it back on and waiting on the AUTOMATIC resume — not a
           manually driven `islandPass()` — is the point: nothing here asks
           for Stop/Start. */
        rig.model.setPixelDrawEnabled(true)
        try await waitUntil("a resumed capture, with no restart") {
            rig.spy.asked.count == 1
        }
        XCTAssertNotNil(rig.model.scene?.windows.first?.island,
                        "the toggle went back on but the window never got "
                            + "its pixels")
    }

    /// A capture already in flight when the toggle goes off must not win
    /// the race and undo the drop when it lands: `onePass` discards the
    /// answer rather than writing it into `sceneIslands`.
    ///
    /// **The mutation this test is watching for**: remove the
    /// `guard pixelDrawEnabled else { return }` placed AFTER
    /// `policy.attach` in `onePass`, and this goes red with an island back
    /// on the window.
    func testACaptureInFlightWhenTheToggleGoesOffIsDiscarded() async throws {
        let front = (8, 40, 400, 300)
        let script = GuestScript(sceneJSON: Self.scene(seq: 1, [
            Self.window(app: "SimpleText", psn: "0.2", title: "Doc",
                        rect: front, front: true, z: 0),
        ]))
        let rig = try await rig(script)
        defer { rig.guest.connection.cancel(); rig.listener.stop() }

        /* Attached before the session starts, and before anything can
           capture — a join completing schedules the FIRST pass on its own
           (`scheduleIslandPass`), and this test does not care which pass
           performs it; it only needs to be inside the ONE capture this
           window gets, whichever call that turns out to be. */
        rig.spy.beforeReturning = { [model = rig.model] in
            /* The toggle flips OFF while this reply is outstanding — the
               race the guard exists for. */
            model.setPixelDrawEnabled(false)
        }
        rig.model.startSession()

        try await waitUntil("a capture attempt") { !rig.spy.asked.isEmpty }
        /* The write-back this guard exists to skip happens right after the
           capture returns — give it a moment to have run, wrongly or not,
           before reading the scene. */
        try await settle()

        XCTAssertEqual(rig.spy.asked.count, 1,
                       "more than one capture ran; this test proves the "
                           + "guard on exactly the first: \(rig.spy.asked)")
        XCTAssertNil(rig.model.scene?.windows.first?.island,
                     "a capture that landed after the toggle went off "
                         + "still put pixels on the window")
    }
}
