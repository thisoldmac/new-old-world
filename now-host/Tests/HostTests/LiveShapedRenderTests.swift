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
}
