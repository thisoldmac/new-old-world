import XCTest
import AppKit
import MirrorKit
import MirrorKitUI
@testable import Host

/// **The gate the coverage harness could not be.**
///
/// `NOWMirrorContentCoverageTests` composes every capture onto a canned
/// scene whose window has `controls = []` and no `dialogItems` at all. That
/// is deliberate — it isolates the capture — and it means every render in
/// that suite is drawn with an EMPTY semantic-exclusion list, while the
/// live app draws the same capture with one entry per DITL row.
///
/// On 2026-08-06 that difference was the whole of a reported regression:
/// Date & Time rendered whole in the fixture harness and lost its date, its
/// time, both group boxes and every field in the app. Same drain, same
/// renderer, twenty dialog items. Nothing here could see it, because
/// nothing here had ever rendered a window that HAD a DITL.
///
/// So this suite composes the committed drain onto the REAL scene it was
/// captured against — `now-scene-sweep-date-and-time.json`, controls,
/// dialog items and all — and asserts against pixels.
@MainActor
final class LiveShapedRenderTests: XCTestCase {

    private func liveScene() throws -> MirrorKit.Scene {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "now-scene-sweep-date-and-time",
            withExtension: "json", subdirectory: "Fixtures"))
        return try NOWMirrorSceneDecoder.decode(
            irVersion: 2, document: Data(contentsOf: url))
    }

    private func composed() throws -> MirrorKit.Scene {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "qdtrace-drain-sweep-date-and-time",
            withExtension: "json", subdirectory: "Fixtures"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as? [String: Any])
        let drain = try XCTUnwrap(QDTraceDecode.drain(object))
        let plane = NOWMirrorContentPlane(listener: GuestListener(
            identity: .init(version: "test", name: "Test Host")))
        return plane.apply(drain, to: try liveScene()).scene
    }

    /// The panel's own window is at (217,64); the DITL puts its date field
    /// at content-local (36,32)-(155,55). Content starts one frame and one
    /// title bar below the window's top-left, which is what the renderer
    /// itself computes — so the region is taken generously and compared
    /// against itself rather than measured absolutely.
    private static let dateFieldProbe = CGRect(x: 217 + 40, y: 64 + 20 + 34,
                                               width: 110, height: 18)

    /// The "Time Zone" group-box title. A different rectangle answering a
    /// DIFFERENT gate: this one is inside DITL item 4, an untyped row that
    /// covers the whole group, and it was the first gate — the exclusion —
    /// that took it. Two probes because two rules, and a suite with one
    /// probe passes while half the defect is back.
    private static let groupTitleProbe = CGRect(x: 221 + 22, y: 84 + 98,
                                                width: 100, height: 14)

    private func pixels(_ scene: MirrorKit.Scene, in box: CGRect) throws
        -> [UInt8] {
        let png = try RenderShot.png(scene: scene)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
        var out: [UInt8] = []
        for y in Int(box.minY)..<Int(box.maxY) {
            for x in Int(box.minX)..<Int(box.maxX) {
                guard let colour = rep.colorAt(x: x, y: y) else { continue }
                out.append(UInt8(colour.redComponent * 255))
            }
        }
        return out
    }

    /// **P3 must reach a field the DITL also describes.**
    ///
    /// Stated as a difference rather than as an absolute: take the panel's
    /// own drawing away and the date field must LOOK different. If the
    /// dialog item is silencing the replay, or a placeholder is painted
    /// over it, the two renders agree — the field shows the same host
    /// furniture either way — and that agreement is the defect.
    func testTheGuestsOwnDrawingReachesAFieldTheDITLAlsoDescribes() throws {
        try skipUnlessAssetPack()
        let withDrawing = try composed()
        var without = withDrawing
        for index in without.windows.indices { without.windows[index].display = nil }

        for (name, probe) in [("the date field", Self.dateFieldProbe),
                              ("the Time Zone group title",
                               Self.groupTitleProbe)] {
            let a = try pixels(withDrawing, in: probe)
            let b = try pixels(without, in: probe)
            XCTAssertEqual(a.count, b.count)
            let differing = zip(a, b).filter { $0 != $1 }.count
            XCTAssertGreaterThan(differing, a.count / 20, """
                \(name) renders the SAME with and without the panel's own \
                drawing (\(differing) of \(a.count) pixels differ). The \
                guest drew there and 1200 ops reached this scene, so the \
                region is being taken by a dialog item — either excluded \
                from the replay (dialogItemOwnsDisplay) or painted over by \
                a placeholder (DisplayReplay.Coverage). See \
                docs/render-composition.md.
                """)
        }
    }

    /// **A window with a DITL still composes its interior at all.**
    ///
    /// The cheap half, kept separate: if the join stops working this fails
    /// for a reason that has nothing to do with the exclusion rules, and
    /// the two should not be diagnosed as one.
    func testTheLiveShapedSceneStillComposesItsInterior() throws {
        let scene = try composed()
        let display = try XCTUnwrap(scene.windows.first(where: \.front)?
            .display)
        XCTAssertFalse(display.isEmpty)
        let text = display.filter { $0.op == "text" }.compactMap(\.text)
        for label in ["Current Date", "Current Time", "Time Zone"] {
            XCTAssertTrue(text.contains(label), "missing \(label)")
        }
        XCTAssertTrue(text.contains("2026"), "the year crosses")
    }

    /// **Render a whole sweep the way the APP would draw it.**
    ///
    /// Opt-in, for eyes: `NOW_SWEEP_DIR` names a `tools/fidelity-sweep.py`
    /// output directory and `NOW_RENDER_DIR` where to put the PNGs. Each
    /// target is composed onto ITS OWN `<label>-scene.json` — the scene the
    /// capture came from, controls and dialog items intact — rather than
    /// onto the coverage harness's canned one.
    ///
    /// That difference is the whole reason this exists. The canned scene
    /// renders every capture with an empty exclusion list, so a sweep
    /// judged from those PNGs scores a picture the app never draws. The
    /// 2026-08-06 sweep was judged that way and could not have seen the
    /// defect it was later used to find.
    ///
    /// Pair the output against `<label>-guest.ppm` with
    /// tools/fidelity-pair.py.
    func testRenderASweepAsTheAppWouldDrawIt() throws {
        guard let sweep = ProcessInfo.processInfo
                .environment["NOW_SWEEP_DIR"],
              let out = ProcessInfo.processInfo
                .environment["NOW_RENDER_DIR"] else { return }
        let summary = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath:
                "\(sweep)/sweep-summary.json")))
        let results = ((summary as? [String: Any])?["results"]
            as? [[String: Any]]) ?? []
        for result in results
        where (result["status"] as? String) == "ok" {
            guard let label = result["label"] as? String else { continue }
            let scene = try NOWMirrorSceneDecoder.decode(
                irVersion: 2,
                document: Data(contentsOf: URL(fileURLWithPath:
                    "\(sweep)/\(label)-scene.json")))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(
                with: Data(contentsOf: URL(fileURLWithPath:
                    "\(sweep)/\(label).json"))) as? [String: Any])
            let drain = try XCTUnwrap(QDTraceDecode.drain(object))
            let plane = NOWMirrorContentPlane(listener: GuestListener(
                identity: .init(version: "test", name: "Test Host")))
            let update = plane.apply(drain, to: scene)
            print("### \(label): \(update.sentence)")
            let png = try RenderShot.png(scene: update.scene)
            try png.write(to: URL(fileURLWithPath: "\(out)/\(label).png"))
        }
    }

    /// **The fixture harness cannot stand in for this, and here is the
    /// proof.** If someone later "simplifies" the scene above to the
    /// canned one, the suite must fail rather than quietly become a
    /// second copy of the coverage gate.
    func testTheFixtureSceneActuallyCarriesADITL() throws {
        let window = try XCTUnwrap(liveScene().windows.first(where: \.front))
        XCTAssertGreaterThan(window.dialogItems?.count ?? 0, 10,
                             "this scene is the point: a window WITH its "
                             + "dialog items, which the coverage harness "
                             + "deliberately clears")
        XCTAssertGreaterThan(window.controls.count, 10)
    }

    // MARK: - One clock (plan 018 slice 1)

    /// The Finder capture sweep A priced as the worst result in the run —
    /// `Macintosh HD`, icon view, whose whole interior rendered as one
    /// "Bitmap unavailable" hatch. Composed onto its OWN scene, as the app
    /// draws it.
    private func composedFixture(drain drainName: String, scene sceneName: String)
        throws -> (scene: MirrorKit.Scene, plane: NOWMirrorContentPlane,
                   raw: QDTraceDecode.Drain) {
        let sceneURL = try XCTUnwrap(Bundle.module.url(
            forResource: sceneName, withExtension: "json",
            subdirectory: "Fixtures"))
        let scene = try NOWMirrorSceneDecoder.decode(
            irVersion: 2, document: Data(contentsOf: sceneURL))
        let drainURL = try XCTUnwrap(Bundle.module.url(
            forResource: drainName, withExtension: "json",
            subdirectory: "Fixtures"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: drainURL)) as? [String: Any])
        let drain = try XCTUnwrap(QDTraceDecode.drain(object))
        let plane = NOWMirrorContentPlane(listener: GuestListener(
            identity: .init(version: "test", name: "Test Host")))
        return (plane.apply(drain, to: scene).scene, plane, drain)
    }

    private static let finderDrain = "qdtrace-drain-sweep18a-finder-icon"
    private static let finderScene = "now-scene-sweep18a-finder-icon"

    /// Ops that cover (most of) the window — a composite blit or a
    /// full-area erase. The same test `lastRepaintPass` applies, restated
    /// here on purpose: a gate that imports the rule it checks proves the
    /// rule is spelled once, not that it is right.
    private func spanningIndices(_ ops: [MirrorKit.DisplayOp],
                                 w: Int, h: Int) -> [Int] {
        ops.indices.filter { i in
            let destructiveRect = ops[i].op == "rect"
                && (ops[i].verb == 1 || ops[i].verb == 2 || ops[i].verb == 4)
            let box = ops[i].op == "bits" ? ops[i].dst
                : (destructiveRect ? ops[i].rect : nil)
            guard let box, box.count == 4 else { return false }
            return Double(box[2] - box[0]) >= 0.8 * Double(w)
                && Double(box[3] - box[1]) >= 0.8 * Double(h)
        }
    }

    /// **A frame is ONE repaint pass, not three concatenated.**
    ///
    /// `displayEpoch` moves once per arm and never per repaint, so a drain
    /// that spans several front/back cycles arrives as one identity with
    /// successive repaints end to end — and a later pass's window-spanning
    /// op lands on top of an earlier pass's content. This capture carries
    /// two such openers; the published frame must carry one, and it must
    /// be the last.
    ///
    /// Watched failing by mutation: with `lastRepaintPass` returning `ops`
    /// unchanged, the published display carries both openers and the
    /// second assertion names it.
    func testTheFindersFrameIsTheLastRepaintPassAlone() throws {
        let (scene, _, _) = try composedFixture(drain: Self.finderDrain,
                                                scene: Self.finderScene)
        let window = try XCTUnwrap(scene.windows.first(where: \.front))
        XCTAssertEqual(window.title, "Macintosh HD")
        let w = window.rect.r - window.rect.l
        let h = window.rect.b - window.rect.t
        let display = try XCTUnwrap(window.display)

        // The capture itself must still exhibit the defect, or this gate
        // is measuring a fixture that was quietly replaced.
        let raw = try XCTUnwrap(QDTraceDecode.drain(
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(
                contentsOf: try XCTUnwrap(Bundle.module.url(
                    forResource: Self.finderDrain, withExtension: "json",
                    subdirectory: "Fixtures")))) as? [String: Any])))
        let rawWindowOps = raw.records
            .filter { $0.portAddress == window.addr }.map(\.op)
        XCTAssertGreaterThan(
            spanningIndices(rawWindowOps, w: w, h: h).count, 1,
            "the capture no longer carries several repaint passes, so this "
            + "gate proves nothing — replace the fixture or delete the test")

        let openers = spanningIndices(display, w: w, h: h)
        XCTAssertEqual(openers.count, 1, """
            the published frame carries \(openers.count) window-spanning \
            ops. Every one after the first paints over the content of the \
            pass before it — the Sound panel's list rows and the Finder's \
            interior both vanish that way. Only the LAST pass may be \
            published. See NOWMirrorContentPlane.lastRepaintPass.
            """)
        XCTAssertLessThan(try XCTUnwrap(openers.first), 6,
                          "the opener must start the frame; anything drawn "
                          + "before it belongs to a pass that is over")
    }

    /// **The published frame carries the clock it came off.**
    ///
    /// A window with a live stream gets a `displayEpoch`; a window without
    /// one gets `nil` and renders semantics-only rather than waiting. That
    /// second half is the degradation rule, and it is asserted here
    /// because its absence would be a deadlock rather than a wrong pixel.
    func testEveryWindowSaysWhetherItHasAClockAtAll() throws {
        let (scene, _, _) = try composedFixture(drain: Self.finderDrain,
                                                scene: Self.finderScene)
        let front = try XCTUnwrap(scene.windows.first(where: \.front))
        let epoch = try XCTUnwrap(front.displayEpoch,
                                  "the streamed window must carry its epoch")
        XCTAssertFalse(epoch.stale,
                       "nothing in this capture supersedes the settled frame")
        XCTAssertEqual(epoch.generation, 1)
        for other in scene.windows where !other.front {
            XCTAssertNil(other.displayEpoch, """
                \(other.title) has no content stream in this capture and \
                must say so with nil rather than with a stale epoch — a \
                window that is not streamed renders its semantics now.
                """)
        }
    }

    /// **The same capture always publishes the same frame.**
    ///
    /// The stability axis, made cheap: two independent planes fed the same
    /// bytes, and one plane fed them twice, must agree op for op. A
    /// renderer cannot be stable if the thing it renders is not.
    func testTheSameCapturePublishesTheSameFrameEveryTime() throws {
        let first = try composedFixture(drain: Self.finderDrain,
                                        scene: Self.finderScene)
        let second = try composedFixture(drain: Self.finderDrain,
                                         scene: Self.finderScene)
        let a = try XCTUnwrap(first.scene.windows.first(where: \.front)?.display)
        let b = try XCTUnwrap(second.scene.windows.first(where: \.front)?.display)
        XCTAssertEqual(a, b, "two planes, same bytes, different frames")

        // And again through the same plane: a re-drain of an unchanged ring
        // must not grow the frame.
        let again = first.plane.apply(first.raw, to: first.scene).scene
        let c = try XCTUnwrap(again.windows.first(where: \.front)?.display)
        XCTAssertEqual(spanningIndices(c, w: 404, h: 238).count, 1,
                       "a second drain of the same records re-concatenated "
                       + "the passes")
    }
}
