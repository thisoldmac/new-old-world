import Foundation
import Network
import XCTest
@testable import Host
import NOWAgentIntegration

/// The caller: a person asks, a scene comes back over the wire, and the
/// Mirror page draws it.
///
/// Every test here drives a real `GuestListener` over a real loopback socket
/// with a `FakeGuest` on the other end, because the properties at risk live
/// in the seams — the transfer lane, the envelope's version, the planes the
/// guest omits — and none of them can be reached by calling the model's door
/// directly with bytes.
///
/// Two of the properties are the kind that pass by accident:
///
/// **The version gate runs BEFORE the decode.** A gate placed after a parse
/// still refuses unknown majors on every well-formed document, so an ordinary
/// test of it is green either way. The only assertion that can tell them
/// apart hands over a body that would not parse and demands the *version*
/// complaint (`testAnUnknownMajorIsRefusedBeforeTheBodyIsParsed`).
///
/// **Absence survives.** A plane the guest never reported must not arrive
/// here as an empty one. The wire path adds an envelope, a buffer and a
/// delivery struct between the encoder and the adapter, and any of the three
/// could have helpfully filled a plane in.
@MainActor
final class MirrorSceneFetchTests: XCTestCase {
    private var listener: GuestListener!

    override func setUp() async throws {
        listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"),
            timing: .init(idleTimeout: 60))
        listener.start(port: 0)
        try await waitUntil("listening") {
            if case .listening = self.listener.state { return true }
            return false
        }
    }

    override func tearDown() async throws {
        listener.stop()
        listener = nil
    }

    // MARK: - rig

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

    private func connectedGuest(
        name: String = "PowerBook 1400") async throws -> FakeGuest {
        let guest = FakeGuest(port: listener.boundPort ?? 0)
        guest.start()
        try guest.send(.hello(Hello(
            contract: Contract.revision, side: "guest", version: "0.1.0",
            name: name, os: "9.1", chunk: 8192)))
        try await waitUntil("connected") {
            if case .connected = self.listener.state { return true }
            return false
        }
        return guest
    }

    /// A model wired to the listener under test, focused on the guest that
    /// is connected — the same two assignments `HostAppState` makes.
    private func focusedModel() throws -> MirrorModuleModel {
        let model = MirrorModuleModel(listener: listener)
        let key = try XCTUnwrap(listener.activeKey)
        guard case .connected(let name) = listener.state else {
            throw WaitTimeout(what: "a connected guest to focus on")
        }
        model.connection = .connected(name: name, key: key)
        return model
    }

    private func sceneRequestId(in guest: FakeGuest) -> Int? {
        for message in guest.received {
            if case .sceneRequest(let request) = message { return request.id }
        }
        return nil
    }

    private func sceneRequestCount(in guest: FakeGuest) -> Int {
        guest.received.filter {
            if case .sceneRequest = $0 { return true }
            return false
        }.count
    }

    /// Serves a scene the way the guest does: begin, one bulk frame, end.
    private func serve(_ document: String, id: Int, to guest: FakeGuest,
                       irVersion: Int = 1, transfer: Int = 9,
                       bytes: Int? = nil) throws {
        let body = Data(document.utf8)
        try guest.send(.sceneBegin(SceneBegin(
            id: id, transfer: transfer, bytes: bytes ?? body.count,
            irVersion: irVersion, seq: 7, capturedAt: 1_750_000_000,
            source: "peek", walkMs: 31)))
        guest.sendRaw(try FrameCodec.encode(
            channel: .bulk, flags: [.end], transfer: UInt16(transfer),
            payload: body))
        try guest.send(.sceneEnd(SceneEnd(id: id, transfer: transfer,
                                          ok: true, reason: nil, sendMs: 4)))
    }

    /// The guest's own encoder's output, with three planes deliberately
    /// absent: no `menus` on the menubar, no `controls` on the window, no
    /// `desktopItems` at all.
    private static let scene = """
        {"version":1,"seq":7,"capturedAt":1750000000.0,"source":"peek",\
        "screen":{"w":640,"h":480},\
        "apps":[{"psn":"0.8193","name":"Finder","front":true}],\
        "menubar":{"height":20},\
        "windows":[{"id":"0.8193/Macintosh HD#0","app":"Finder",\
        "psn":"0.8193","title":"Macintosh HD",\
        "rect":{"l":8,"t":40,"r":400,"b":300},"front":true,"z":0,\
        "visible":true}],\
        "meta":{"plane":"peek anchors","latencyMs":12}}
        """

    // MARK: - the whole path, once

    /// A person presses the button, the Mac answers, and the page draws it —
    /// named as that Mac, and not as a recording.
    func testAFetchedSceneReachesThePaneAsThisMac() async throws {
        let guest = try await connectedGuest(name: "Quadra 950")
        let model = try focusedModel()
        XCTAssertEqual(model.state, .notLookedYet(guest: "Quadra 950"),
                       "an unasked page has not looked")

        model.fetchScene()
        XCTAssertEqual(model.state, .looking(guest: "Quadra 950"),
                       "pressing the button must show that it was pressed")

        try await waitUntil("scene.request") {
            self.sceneRequestId(in: guest) != nil
        }
        try serve(Self.scene, id: try XCTUnwrap(sceneRequestId(in: guest)),
                  to: guest)
        try await waitUntil("a scene on the page") { model.state.hasScene }

        XCTAssertEqual(model.provenance, .guest(name: "Quadra 950"))
        XCTAssertEqual(model.provenance?.isLive, true)
        XCTAssertFalse(model.state.isFault)
        XCTAssertEqual(model.fetch, .idle)
        // A fetched scene is a moment that has passed. The page must not
        // call it live, which is the same discipline the replay banner keeps.
        let banner = try XCTUnwrap(model.provenance?.banner)
        XCTAssertTrue(banner.contains("Quadra 950"))
        XCTAssertTrue(banner.contains("not a live view"),
                      "a fetched scene is a moment that has passed, and the "
                          + "banner must say so: \(banner)")
    }

    /// A scene that arrives is proof of both rungs at once: only the
    /// extension can see other programs' windows, and only an armed plane
    /// runs the walk. Recorded through the seams a probe would use.
    func testAnArrivedSceneIsEvidenceOfTheExtensionAndThePlane() async throws {
        let guest = try await connectedGuest()
        let model = try focusedModel()
        XCTAssertEqual(model.extensionEvidence, .unasked)
        XCTAssertEqual(model.planeEvidence, .unasked)

        model.fetchScene()
        try await waitUntil("scene.request") {
            self.sceneRequestId(in: guest) != nil
        }
        try serve(Self.scene, id: try XCTUnwrap(sceneRequestId(in: guest)),
                  to: guest)
        try await waitUntil("a scene on the page") { model.state.hasScene }

        XCTAssertEqual(model.extensionEvidence, .present)
        XCTAssertEqual(model.planeEvidence, .armed)
    }

    // MARK: - the version gate, in the right order

    /// **The assertion this file exists for.**
    ///
    /// The body below is not JSON. A decoder reached first would fail on the
    /// parse and the page would say the scene was malformed; the contract is
    /// that the *envelope's* major is read first and an unknown one is
    /// refused before the body is touched at all. So the demand is not
    /// merely "it was refused" but "it was refused FOR THE VERSION" — the
    /// only outcome the two orders do not share.
    func testAnUnknownMajorIsRefusedBeforeTheBodyIsParsed() async throws {
        let guest = try await connectedGuest()
        let model = try focusedModel()
        model.fetchScene()
        try await waitUntil("scene.request") {
            self.sceneRequestId(in: guest) != nil
        }
        try serve("this is not JSON at all",
                  id: try XCTUnwrap(sceneRequestId(in: guest)),
                  to: guest, irVersion: 99)
        try await waitUntil("a verdict") { model.state.isFault }

        guard case .unreadable(let reason, let provenance) = model.state else {
            return XCTFail("an unknown major produced \(model.state)")
        }
        XCTAssertEqual(provenance, .guest(name: "PowerBook 1400"))
        XCTAssertTrue(reason.contains("99"),
                      "the refusal does not name the major it refused")
        XCTAssertTrue(reason.contains("before it was parsed"),
                      "the page does not say the body was refused unparsed")
        XCTAssertFalse(reason.contains("could not be read:"),
                       "a PARSE failure was reported, so the body was "
                           + "decoded before the version was checked — the "
                           + "one arrangement IR-V1.md forbids.")
        XCTAssertNil(model.scene, "nothing may be drawn from a refused major")
    }

    /// The envelope's number is what the gate runs on, so nothing on the way
    /// here may substitute the body's own stamp for it.
    ///
    /// The body below claims major 2 and the envelope says 1. A path that
    /// carried the envelope reports a DISAGREEMENT; a path that read the
    /// body's stamp and passed that along would have fed the gate 2 and
    /// reported an unsupported major instead. The two verdicts are how the
    /// two implementations are told apart.
    func testTheEnvelopeIsCarriedThroughRatherThanTheBodysOwnStamp()
        async throws {
        let guest = try await connectedGuest()
        let model = try focusedModel()
        model.fetchScene()
        try await waitUntil("scene.request") {
            self.sceneRequestId(in: guest) != nil
        }
        let body = Self.scene.replacingOccurrences(of: "{\"version\":1",
                                                   with: "{\"version\":2")
        try serve(body, id: try XCTUnwrap(sceneRequestId(in: guest)),
                  to: guest, irVersion: 1)
        try await waitUntil("a verdict") { model.state.isFault }

        guard case .unreadable(let reason, _) = model.state else {
            return XCTFail("a divergent envelope produced \(model.state)")
        }
        XCTAssertTrue(reason.contains("envelope says IR 1"),
                      "the envelope's major was not the one the gate ran "
                          + "on: \(reason)")
        XCTAssertTrue(reason.contains("its body says 2"))
    }

    // MARK: - absence survives the new path

    /// The guest omits `menus`, `controls` and `desktopItems` rather than
    /// emitting them empty. Nothing between the socket and the adapter may
    /// fill them in — the delivery carries bytes precisely so it cannot.
    func testAnAbsentPlaneArrivesAbsentAndNotEmpty() async throws {
        let guest = try await connectedGuest()
        let model = try focusedModel()
        model.fetchScene()
        try await waitUntil("scene.request") {
            self.sceneRequestId(in: guest) != nil
        }
        try serve(Self.scene, id: try XCTUnwrap(sceneRequestId(in: guest)),
                  to: guest)
        try await waitUntil("a scene on the page") { model.state.hasScene }

        let scene = try XCTUnwrap(model.scene)
        XCTAssertTrue(scene.windowsPresent, "windows WERE reported")
        XCTAssertEqual(scene.windows.count, 1)
        let bar = try XCTUnwrap(scene.menubar)
        XCTAssertFalse(bar.menusPresent,
                       "a menubar with no menus key reported an empty menu "
                           + "list, which tells the product this Mac has no "
                           + "menus rather than that it did not say")
        XCTAssertNil(scene.desktopItems,
                     "an omitted desktopItems plane arrived as an empty one")
        XCTAssertFalse(scene.windows[0].controlsPresent,
                       "an omitted controls plane arrived as an empty one")
    }

    // MARK: - the one transfer lane

    /// A scene is one more user of a lane that carries one thing at a time,
    /// so it refuses locally rather than spending a round trip to be told
    /// what this side already knows — and it names the holder, because
    /// "busy" without a reason is indistinguishable from a fault.
    ///
    /// **The negative assertion is ordered.** Asserting "no scene.request
    /// was sent" immediately would pass on a host that had simply not got
    /// round to sending one yet. So it runs only after the refusal has come
    /// back — by which point a request, had one been sent, would have been
    /// on the wire ahead of it — and after the capture that holds the lane
    /// has been seen to arrive.
    func testASceneWaitsItsTurnBehindACaptureOnTheOneLane() async throws {
        let guest = try await connectedGuest()
        let model = try focusedModel()

        listener.requestCapture(depth: 8) { _ in }
        try await waitUntil("capture.request on the wire") {
            guest.received.contains {
                if case .captureRequest = $0 { return true }
                return false
            }
        }

        var refusal: String?
        listener.requestScene { result in
            if case .failure(let f) = result { refusal = f.message }
        }
        try await waitUntil("the refusal") { refusal != nil }

        let said = try XCTUnwrap(refusal)
        XCTAssertTrue(said.contains("screenshot"),
                      "the refusal does not name what holds the lane: \(said)")
        XCTAssertEqual(sceneRequestCount(in: guest), 0,
                       "a scene.request went out over a held lane")

        // And the page says the same thing, as an answer rather than a fault.
        model.fetchScene()
        try await waitUntil("the page's verdict") {
            if case .refused = model.state { return true }
            return false
        }
        XCTAssertFalse(model.state.isFault,
                       "a busy Mac is not a broken one")
        XCTAssertEqual(model.extensionEvidence, .unasked,
                       "a local refusal taught the page a fact about the "
                           + "other Mac, which it cannot know")
    }

    /// The lane guard is symmetric: a scene holds it too.
    func testASecondSceneIsRefusedWhileTheFirstIsInFlight() async throws {
        let guest = try await connectedGuest()
        listener.requestScene { _ in }
        try await waitUntil("scene.request") {
            self.sceneRequestId(in: guest) != nil
        }
        var refusal: String?
        listener.requestScene { result in
            if case .failure(let f) = result { refusal = f.message }
        }
        try await waitUntil("the refusal") { refusal != nil }
        XCTAssertTrue(try XCTUnwrap(refusal).contains("already on its way"))
        XCTAssertEqual(sceneRequestCount(in: guest), 1,
                       "the second ask reached the Mac anyway")
    }

    /// An impatient second press is ignored, not queued and not shown as a
    /// refusal: the page is working, and telling a person otherwise teaches
    /// them it is broken.
    func testASecondPressWhileLookingIsIgnored() async throws {
        let guest = try await connectedGuest()
        let model = try focusedModel()
        model.fetchScene()
        try await waitUntil("scene.request") {
            self.sceneRequestId(in: guest) != nil
        }
        model.fetchScene()
        // Ordered: the first request is already on the wire, so a second one
        // would have had every chance to follow it.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(sceneRequestCount(in: guest), 1)
        XCTAssertEqual(model.state, .looking(guest: "PowerBook 1400"))
    }

    // MARK: - the Mac's own answers

    /// The guest refuses the same way it refuses everything else: an end
    /// with `ok:false`, a reason, and no bulk at all.
    func testAGuestsRefusalIsAnAnswerAndNotAFault() async throws {
        let guest = try await connectedGuest()
        let model = try focusedModel()
        model.fetchScene()
        try await waitUntil("scene.request") {
            self.sceneRequestId(in: guest) != nil
        }
        try guest.send(.sceneEnd(SceneEnd(
            id: try XCTUnwrap(sceneRequestId(in: guest)), transfer: 9,
            ok: false, reason: "a transfer is already in flight",
            sendMs: nil)))
        try await waitUntil("the verdict") {
            if case .refused = model.state { return true }
            return false
        }

        guard case .refused(let name, let reason) = model.state else {
            return XCTFail("unreachable")
        }
        XCTAssertEqual(name, "PowerBook 1400")
        XCTAssertEqual(reason, "a transfer is already in flight")
        XCTAssertFalse(model.state.isFault)
        XCTAssertNotEqual(model.state.resting?.symbol,
                          "exclamationmark.triangle")
        XCTAssertEqual(model.extensionEvidence, .unasked,
                       "a refusal is not evidence about the extension")
    }

    /// Half a JSON document is the worst partial answer, because it does not
    /// even parse. A body shorter than its begin promised is refused as a
    /// transfer rather than handed to the decoder as a bad scene.
    func testATruncatedSceneIsRefusedRatherThanDecoded() async throws {
        let guest = try await connectedGuest()
        let model = try focusedModel()
        model.fetchScene()
        try await waitUntil("scene.request") {
            self.sceneRequestId(in: guest) != nil
        }
        // The begin promises more than the bulk delivers.
        try serve(Self.scene, id: try XCTUnwrap(sceneRequestId(in: guest)),
                  to: guest, bytes: Self.scene.utf8.count + 200)
        try await waitUntil("the verdict") {
            if case .refused = model.state { return true }
            return false
        }
        guard case .refused(_, let reason) = model.state else {
            return XCTFail("unreachable")
        }
        XCTAssertTrue(reason.contains("short"),
                      "a truncated transfer was not named as one: \(reason)")
        XCTAssertNil(model.scene,
                     "part of a scene reached the page")
    }

    /// A guest that does not implement `scene.request` says so instantly.
    /// Without routing that answer, the page would spend twenty seconds
    /// looking like a wedged Mac to report something already said.
    func testAGuestThatDoesNotServeScenesRefusesImmediately() async throws {
        let guest = try await connectedGuest()
        let model = try focusedModel()
        model.fetchScene()
        try await waitUntil("scene.request") {
            self.sceneRequestId(in: guest) != nil
        }
        try guest.send(.error(ErrorMessage(
            id: try XCTUnwrap(sceneRequestId(in: guest)),
            code: "unknown-type",
            message: "scene.request is not implemented")))
        try await waitUntil("the verdict") {
            if case .refused = model.state { return true }
            return false
        }
        guard case .refused(_, let reason) = model.state else {
            return XCTFail("unreachable")
        }
        XCTAssertTrue(reason.contains("not implemented"))
        XCTAssertTrue(reason.contains("unknown-type"))
    }

    // MARK: - a scene already on screen is not thrown away

    /// A refused refresh must not blank a scene that arrived perfectly. The
    /// refusal is still said — through `fetchNote`, derived from the same
    /// stored value the `.refused` state is derived from.
    func testARefusedRefreshKeepsTheSceneAndSaysSoAnyway() async throws {
        let guest = try await connectedGuest()
        let model = try focusedModel()
        model.fetchScene()
        try await waitUntil("scene.request") {
            self.sceneRequestId(in: guest) != nil
        }
        try serve(Self.scene, id: try XCTUnwrap(sceneRequestId(in: guest)),
                  to: guest)
        try await waitUntil("a scene on the page") { model.state.hasScene }
        XCTAssertNil(model.fetchNote)

        // Hold the lane, then refresh.
        listener.requestCapture(depth: 8) { _ in }
        model.fetchScene()
        try await waitUntil("the note") { model.fetchNote != nil }

        XCTAssertTrue(model.state.hasScene,
                      "a refused refresh threw away a good scene")
        XCTAssertTrue(try XCTUnwrap(model.fetchNote).contains("screenshot"))
    }

    /// A machine leaving takes its refusal with it. The reason described a
    /// connection that no longer exists.
    func testARefusalDoesNotOutliveTheMacThatSaidIt() async throws {
        let guest = try await connectedGuest()
        let model = try focusedModel()
        listener.requestCapture(depth: 8) { _ in }
        model.fetchScene()
        try await waitUntil("the refusal") { model.fetchNote != nil }

        let key = try XCTUnwrap(listener.activeKey)
        model.guestLeft(key)
        XCTAssertNil(model.fetchNote)
        XCTAssertEqual(model.fetch, .idle)
        _ = guest
    }

    // MARK: - nothing to ask

    func testAPageWithNoMacCannotAsk() {
        let model = MirrorModuleModel(listener: listener)
        XCTAssertFalse(model.canFetch)
        model.fetchScene()
        XCTAssertEqual(model.fetch, .idle,
                       "a page with no Mac put itself in a waiting state")
        XCTAssertEqual(model.state, .noGuest)
    }

    /// A model without a listener — a preview, a copy-paste test — cannot
    /// fetch, rather than fetching into something that always fails.
    func testAPageWithNoWireCannotAsk() async throws {
        _ = try await connectedGuest()
        let model = MirrorModuleModel()
        let key = try XCTUnwrap(listener.activeKey)
        model.connection = .connected(name: "PowerBook 1400", key: key)
        XCTAssertFalse(model.canFetch)
        model.fetchScene()
        XCTAssertEqual(model.fetch, .idle)
    }
}
