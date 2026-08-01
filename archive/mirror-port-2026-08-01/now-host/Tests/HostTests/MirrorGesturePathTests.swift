import CoreGraphics
import Foundation
import XCTest
@testable import Host
import MirrorKit
import MirrorKitUI

/// **A press on the drawing: where it lands, and what it is allowed to
/// become.**
///
/// Two halves, and the first is the dangerous one.
///
/// **The mapping.** A click that lands near-but-wrong is worse than no click
/// at all: the person sees the Macintosh do the wrong thing and debugs the
/// wrong machine. The letterbox offset is the specific way to be silently
/// wrong — with a 4:3 guest in a wide pane, a third of the box is margin, and
/// a mapping that forgot the offset still maps every point to a plausible
/// place on the screen. So the tests below check the mapping against KNOWN
/// points in a box whose offset is not zero; a version that drops the offset,
/// or divides by the wrong axis's scale, fails them.
///
/// **The refusals.** A control the scene draws but carries no reference for
/// is not addressable, and the page must say so rather than click where it
/// was drawn. Silence is the failure mode this product keeps paying for, and
/// it is the one a green suite is least likely to notice.
@MainActor
final class MirrorGesturePathTests: XCTestCase {

    // MARK: - fixtures

    /// A 640×480 guest with one document window carrying one button.
    ///
    /// Written as the **document a guest sends**, not as a `MirrorKit.Scene`
    /// built in memory: the ref a control carries survives the adapter
    /// (`control.ref ?? ""`), so a test that skipped the wire shape could
    /// pass on a scene no producer can send.
    ///
    /// The window is at (100,100)–(400,300); ITS OWN rect and, per
    /// `MirrorSceneAdapter`'s header, the WIRE's control rect too are both
    /// global (a `ControlRecord.contrlRect` for an ordinary window is the
    /// same coordinates as the screen) — so this fixture writes the button
    /// at its global (120,140)–(200,160), matching where the button should
    /// actually land, and the adapter crosses it to content-local (20,20)–
    /// (100,40) — window left (100) + title bar (20) subtracted — the
    /// numbers `HitTester`/`ActionModel` below actually read.
    private static func document(controlRef: String) -> Data {
        let ref = controlRef.isEmpty ? "" : "\"ref\":\"\(controlRef)\","
        return Data("""
            {"version":1,"seq":4,"capturedAt":1750000000.0,"source":"peek",\
            "screen":{"w":640,"h":480},\
            "apps":[{"psn":"0.8192","name":"SimpleText","front":true}],\
            "windows":[{"id":"w1","app":"SimpleText","psn":"0.8192",\
            "title":"Untitled","kind":20,\
            "rect":{"l":100,"t":100,"r":400,"b":300},"front":true,"z":0,\
            "visible":true,"controls":[{\(ref)"title":"Save",\
            "rect":{"l":120,"t":140,"r":200,"b":160},"enabled":true,\
            "visible":true}]}],\
            "meta":{"plane":"peek anchors"}}
            """.utf8)
    }

    private static let liveReference =
        "now-element-11111111-2222-4333-8444-555555555555"

    /// A pane showing that scene, with no act lane behind it.
    private func model(controlRef: String = "") -> MirrorModuleModel {
        let model = MirrorModuleModel(watch: .manual)
        model.connection = .connected(named: "PowerBook 1400")
        model.show(document: Self.document(controlRef: controlRef),
                   irVersion: 1, provenance: .fixture(name: "test.json"))
        return model
    }

    /// The scene those tests draw, for the mapping's own assertions.
    private func scene() throws -> MirrorKit.Scene {
        let model = model()
        return try XCTUnwrap(model.scene)
    }

    // MARK: - the mapping

    /// **A known point, in a box with a letterbox.** 640×480 drawn into a
    /// 1000×480 pane fits at scale 1 with a 180 pt margin on each side, so
    /// the guest's origin is at view x=180. A mapping that ignored the
    /// offset would answer (280, 50) here and be wrong by the whole margin.
    func testAPointMapsThroughTheLetterboxOffset() throws {
        let scene = try scene()
        let point = CGPoint(x: 180 + 100, y: 50)
        let guest = MirrorPointMapping.guestPoint(
            point, in: CGSize(width: 1000, height: 480), scene: scene)
        XCTAssertEqual(guest?.x, 100)
        XCTAssertEqual(guest?.y, 50)
    }

    /// The other axis, so a mapping that offsets only x cannot pass: 640×480
    /// in a 640×600 pane letterboxes 60 pt top and bottom.
    func testTheOffsetAppliesToBothAxes() throws {
        let guest = try MirrorPointMapping.guestPoint(
            CGPoint(x: 320, y: 60 + 240),
            in: CGSize(width: 640, height: 600), scene: scene())
        XCTAssertEqual(guest?.x, 320)
        XCTAssertEqual(guest?.y, 240)
    }

    /// Scale as well as offset: a half-size drawing halves every distance.
    func testAScaledDrawingScalesThePoint() throws {
        let guest = try MirrorPointMapping.guestPoint(
            CGPoint(x: 160, y: 120),
            in: CGSize(width: 320, height: 240), scene: scene())
        XCTAssertEqual(guest?.x, 320)
        XCTAssertEqual(guest?.y, 240)
    }

    /// **The mapping is the renderer's own, inverted.** Rather than trusting
    /// two hand-computed numbers, this walks the guest's screen and demands
    /// that every point the renderer would draw at maps back to itself. A
    /// transform that is off by a pixel anywhere in the box fails here even
    /// where a corner case would not.
    func testEveryDrawnPointMapsBackToItself() throws {
        let scene = try scene()
        let size = CGSize(width: 977, height: 611)     // deliberately odd
        let fit = FitTransform(
            logical: SceneRenderer(scene: scene).logicalSize, view: size)
        for x in stride(from: 0, to: 640, by: 37) {
            for y in stride(from: 0, to: 480, by: 31) {
                let drawn = fit.toView(x, y)
                let back = MirrorPointMapping.guestPoint(drawn, in: size,
                                                         scene: scene)
                XCTAssertEqual(back?.x, x, "x round trip at (\(x), \(y))")
                XCTAssertEqual(back?.y, y, "y round trip at (\(x), \(y))")
            }
        }
    }

    /// **The letterbox is not the Mac.** Clamping a press there to the
    /// nearest edge would invent a press on the edge of somebody's screen.
    func testAPressInTheLetterboxIsNotAPointOnTheScreen() throws {
        let scene = try scene()
        let size = CGSize(width: 1000, height: 480)
        XCTAssertNil(MirrorPointMapping.guestPoint(CGPoint(x: 20, y: 100),
                                                   in: size, scene: scene),
                     "a press in the left margin mapped onto the screen")
        XCTAssertNil(MirrorPointMapping.guestPoint(CGPoint(x: 990, y: 100),
                                                   in: size, scene: scene),
                     "a press in the right margin mapped onto the screen")
        /* The far edge is half-open, matching the hit tester's own
           `contains`: the column at exactly the width is the first one that
           is not on the screen. */
        XCTAssertNil(MirrorPointMapping.guestPoint(CGPoint(x: 180 + 640,
                                                           y: 100),
                                                   in: size, scene: scene))
        XCTAssertNotNil(MirrorPointMapping.guestPoint(CGPoint(x: 180 + 639,
                                                              y: 100),
                                                      in: size, scene: scene))
    }

    /// And the page says so rather than swallowing it.
    func testAPressOffTheScreenIsReported() {
        let model = model()
        model.clickedOffScreen()
        XCTAssertEqual(model.lastAction?.outcome, .offScreen)
    }

    // MARK: - what a press becomes

    /// **A control the scene cannot address refuses visibly.**
    ///
    /// NOW's producer emits `ref` empty, so this is the ordinary case today
    /// and the one silence would hide: the control is drawn, it looks
    /// clickable, and `ActionModel.click` answers with no action at all. The
    /// page must not read that as "nothing happened".
    func testARefLessControlRefusesWithItsReason() {
        let model = model(controlRef: "")
        model.click(x: 130, y: 145)          // inside the Save button

        let report = try? XCTUnwrap(model.lastAction)
        XCTAssertEqual(report?.outcome, .unavailable,
                       "a control with no reference was treated as an inert "
                           + "press. It is not inert — it is not addressable, "
                           + "and those are different sentences to a person "
                           + "looking at a button that did nothing.")
        XCTAssertEqual(report?.target, "\"Save\"")
        let sentence = report?.sentence ?? ""
        XCTAssertTrue(sentence.contains("reference"),
                      "the refusal does not say which half is missing: "
                          + "\(sentence)")
        XCTAssertTrue(sentence.contains("ctlact"),
                      "the refusal does not name the lane that is built and "
                          + "waiting: \(sentence)")
    }

    /// The desktop is a coordinate, and a coordinate names nothing. NOW's
    /// contract declares no positional click, and the page says that rather
    /// than sending one.
    func testAPressOnTheDesktopIsRefusedRatherThanSentAsACoordinate() {
        let model = model()
        model.click(x: 600, y: 460)

        XCTAssertEqual(model.lastAction?.outcome, .unavailable)
        XCTAssertEqual(model.lastAction?.target, "the desktop")
        XCTAssertTrue(
            (model.lastAction?.sentence ?? "").contains("positional click"),
            "the page did not name the reason a coordinate cannot be sent")
    }

    /// A window with no act lane behind it says exactly that — it does not
    /// report a dispatch it could not have made.
    func testAPageWithNoActLaneSaysSo() {
        let model = model(controlRef: Self.liveReference)
        model.click(x: 130, y: 145)
        XCTAssertEqual(model.lastAction?.outcome, .unavailable)
        XCTAssertNotEqual(model.lastAction?.outcome, .dispatched)
    }

    /// **`dispatched` is the driver's word, read off the guest's reply.**
    ///
    /// An addressable control — one carrying an observation reference —
    /// reaches `ctlact` on the wire, and the sentence the page shows is the
    /// driver's, which claims the event was handed to the application and
    /// nothing more.
    func testAnAddressableControlReachesTheActLane() async throws {
        let (listener, guest) = try await connectedListener()
        defer { guest.connection.cancel(); listener.stop() }
        var seen: [String: String]?
        guest.onMessage = { message in
            guard case .commandRequest(let request) = message,
                  request.name == "ctlact" else { return }
            seen = request.args
            try? guest.send(.commandResult(.init(
                id: request.id, ok: true,
                output: ["ctlact": [["Dispatch", "dispatched"]]],
                error: nil)))
        }

        let model = MirrorModuleModel(
            listener: listener,
            actions: MirrorActionDriver(
                adapter: AgentIntegrationHostAdapter(listener: listener)),
            watch: .manual)
        model.connection = .connected(
            name: "PowerBook 1400", key: try XCTUnwrap(listener.activeKey))
        model.show(document: Self.document(controlRef: Self.liveReference),
                   irVersion: 1, provenance: .fixture(name: "test.json"))

        model.click(x: 130, y: 145)
        let deadline = Date().addingTimeInterval(5)
        while model.lastAction?.outcome == .asking, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(seen?["element"], Self.liveReference,
                       "the act named something other than the control the "
                           + "scene addressed")
        XCTAssertEqual(model.lastAction?.outcome, .dispatched)
        let sentence = model.lastAction?.sentence ?? ""
        for claimed in ["clicked", "worked", "succeeded"] {
            XCTAssertFalse(sentence.contains(claimed),
                           "the page claims \"\(claimed)\"; the event was "
                               + "dispatched and nothing here saw what the "
                               + "application did with it")
        }
    }
}
