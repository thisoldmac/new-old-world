import XCTest
import AppKit
@testable import MirrorKit
@testable import MirrorKitUI

/// **The arbitration `win.items` never had.**
///
/// `SceneRenderer` resolved the machine's display list against controls
/// (`semanticOwnsDisplay`) and against DITL rows (`dialogItemOwnsDisplay`).
/// The Finder roster had no equivalent, so a folder window holding both the
/// machine's ink and our icon roster drew both — which Michelle found by
/// driving, on 2026-08-07: *"I can actually see the icon being selected
/// underneath it. it looks like we're not only rendering the label twice,
/// we're rendering the whole icon twice."*
///
/// Each test below names the mutation it was watched to fail against. That
/// matters more than usual here: two render guards in this tree have already
/// passed the exact mutation they were written for, so a guard that was
/// watched against ONE mutation is not watched.
@MainActor
final class FinderItemArbitrationTests: XCTestCase {

    // MARK: - Fixtures

    /// The one fixture, used for every measurement and every assertion here.
    /// Re-deriving a second one for the "after" reading is how a before/after
    /// comes to compare two different pictures.
    static func item(_ name: String, x: Int, y: Int,
                     w: Int? = 32, h: Int? = 32,
                     kind: String = "folder",
                     placed: Bool = true,
                     invisible: Bool = false) -> Scene.DesktopItem {
        var i = Scene.DesktopItem(name: name, kind: kind, type: nil,
                                  creator: nil, x: x, y: y, placed: placed,
                                  alias: false, invisible: invisible)
        i.w = w
        i.h = h
        return i
    }

    static let frame = Rect(l: 100, t: 100, r: 420, b: 340)

    static var contentOrigin: (x: Int, y: Int) {
        (frame.l, frame.t + Int(Platinum.contentTop))
    }

    static func folder(items: [Scene.DesktopItem]?,
                       display: [DisplayOp]? = nil,
                       controls: [Scene.Control] = []) -> Scene.Window {
        Scene.Window(id: "1.0/Macintosh HD#0", app: "Finder", psn: "1.0",
                     title: "Macintosh HD", kind: 0, rect: frame, front: true,
                     z: 0, visible: true, controls: controls, text: nil,
                     items: items, display: display)
    }

    static func scene(_ windows: [Scene.Window]) -> Scene {
        Scene(version: 0, seq: 1, source: "mock", capturedAt: 0,
              screen: .init(w: 800, h: 600), apps: [], processes: nil,
              menubar: nil, windows: windows, desktopItems: nil,
              meta: .init(errors: []))
    }

    /// A CopyBits with no pixels — how the Finder's own icon reaches this
    /// side, and what the replay hatches when nobody has named the box.
    static func blit(_ rect: [Int]) -> DisplayOp {
        var op = DisplayOp(op: "bits", ticks: 1)
        op.src = rect
        op.dst = rect
        return op
    }

    /// A text run at `pen`, which is the baseline's left end.
    static func run(_ text: String, x: Int, y: Int) -> DisplayOp {
        var op = DisplayOp(op: "text", ticks: 2)
        op.text = text
        op.pen = [x, y]
        op.size = 9
        op.len = text.utf8.count
        op.fullLen = text.utf8.count
        return op
    }

    private func pixel(_ png: Data, x: Int, y: Int) -> (Int, Int, Int)? {
        guard let rep = NSBitmapImageRep(data: png),
              let colour = rep.colorAt(x: x, y: y) else { return nil }
        return (Int((colour.redComponent * 255).rounded()),
                Int((colour.greenComponent * 255).rounded()),
                Int((colour.blueComponent * 255).rounded()))
    }

    /// Every dark pixel in a band, as guest points. Sampling BYTES at render
    /// time rather than holding reps: `NSBitmapImageRep(cgImage:)` does not
    /// copy, so ten reps read at the end can all answer from one buffer and
    /// a render comparison silently becomes a tautology. `RenderShot.png`
    /// serialises, which is why every reading here goes through it.
    private func darkPixels(_ png: Data, in box: CGRect) -> Set<[Int]> {
        guard let rep = NSBitmapImageRep(data: png) else { return [] }
        var out: Set<[Int]> = []
        for y in Int(box.minY)..<Int(box.maxY) {
            for x in Int(box.minX)..<Int(box.maxX) {
                guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh,
                      let c = rep.colorAt(x: x, y: y) else { continue }
                if c.redComponent < 0.4 && c.greenComponent < 0.4
                    && c.blueComponent < 0.4 {
                    out.insert([x, y])
                }
            }
        }
        return out
    }

    /// How many pixels of `box` differ between two renders. Both readings
    /// are PNG bytes taken at render time, for the reason above.
    private func differences(_ a: Data, _ b: Data, in box: CGRect) -> Int {
        guard let ra = NSBitmapImageRep(data: a),
              let rb = NSBitmapImageRep(data: b) else { return -1 }
        var n = 0
        for y in Int(box.minY)..<Int(box.maxY) {
            for x in Int(box.minX)..<Int(box.maxX) {
                guard x >= 0, y >= 0, x < ra.pixelsWide, y < ra.pixelsHigh,
                      let ca = ra.colorAt(x: x, y: y),
                      let cb = rb.colorAt(x: x, y: y) else { continue }
                if abs(ca.redComponent - cb.redComponent) > 0.01
                    || abs(ca.greenComponent - cb.greenComponent) > 0.01
                    || abs(ca.blueComponent - cb.blueComponent) > 0.01 {
                    n += 1
                }
            }
        }
        return n
    }

    // MARK: - The predicate

    /// The sibling reads like its siblings: it says whether the roster has
    /// what that rectangle needs, and nothing else.
    ///
    /// **Watched to fail against three mutations**: returning `true`
    /// unconditionally, dropping the `placed` clause, and dropping the
    /// `invisible` clause.
    func testOnlyADrawableRosterItemClaimsAnything() {
        XCTAssertTrue(SceneRenderer.finderItemOwnsDisplay(
            Self.item("Docs", x: 40, y: 60)))
        XCTAssertFalse(
            SceneRenderer.finderItemOwnsDisplay(
                Self.item("Docs", x: 40, y: 60, placed: false)),
            "an unplaced item has no rectangle, so it may claim none")
        XCTAssertFalse(
            SceneRenderer.finderItemOwnsDisplay(
                Self.item("Docs", x: 40, y: 60, invisible: true)),
            "an item the Finder does not show is not drawn and claims nothing")
        XCTAssertFalse(
            SceneRenderer.finderItemOwnsDisplay(
                Self.item("", x: 40, y: 60)),
            "a claim without a drawing is the defect this sibling ends")
    }

    /// The box is the one the FINDER drew. A list row is 16×16 at a 19-point
    /// pitch; a constant 32 runs the icon through the row below it and over
    /// the columns the machine wrote — Michelle's "prints icons in a list on
    /// top of the list".
    ///
    /// **Watched to fail against**: restoring the constant `Self.iconSize`
    /// for both dimensions, and dropping the `min` cap.
    func testTheIconBoxIsTheBoxTheFinderDrew() {
        XCTAssertEqual(
            SceneRenderer.iconBoxSize(Self.item("Docs", x: 0, y: 0)),
            CGSize(width: 32, height: 32))
        XCTAssertEqual(
            SceneRenderer.iconBoxSize(
                Self.item("Docs", x: 0, y: 0, w: 16, h: 16)),
            CGSize(width: 16, height: 16),
            "a list row's icon is 16×16, and 32 covers the row below it")
        XCTAssertEqual(
            SceneRenderer.iconBoxSize(
                Self.item("Docs", x: 0, y: 0, w: nil, h: nil)),
            CGSize(width: 32, height: 32),
            "a record predating `bounds` can only mean the icon view's cell")
        XCTAssertEqual(
            SceneRenderer.iconBoxSize(
                Self.item("Docs", x: 0, y: 0, w: 900, h: 900)),
            CGSize(width: 32, height: 32),
            "an oversized report must not claim the window")
    }

    /// The state-proven OS 8.6 Finder target draws a default volume from
    /// y=47 through y=56 in an icon box beginning at y=27. The name begins at
    /// y=60. Pinning the internal face keeps the fallback from growing back
    /// into the full cell and pushing the label down by twelve pixels.
    ///
    /// **Watched to fail against**: restoring the old 2/7/4/12 insets.
    func testDefaultDiskFaceUsesTheMeasuredFinderGeometry() {
        XCTAssertEqual(
            SceneRenderer.diskBodyRect(
                CGRect(x: 736, y: 27, width: 32, height: 32)),
            CGRect(x: 736, y: 47, width: 32, height: 10))
    }

    /// A list row's NAME is a column the machine wrote, level with the row
    /// icon rather than under it. Ours is centred underneath, so drawing it
    /// there is a second name in the wrong place.
    ///
    /// **Watched to fail against**: returning `true` unconditionally, and
    /// inverting the comparison.
    func testAListRowDrawsNoLabelOfOurs() {
        XCTAssertTrue(SceneRenderer.itemDrawsItsOwnLabel(
            Self.item("Docs", x: 0, y: 0)))
        XCTAssertFalse(SceneRenderer.itemDrawsItsOwnLabel(
            Self.item("Docs", x: 0, y: 0, w: 16, h: 16)))
        XCTAssertTrue(SceneRenderer.itemDrawsItsOwnLabel(
            Self.item("Docs", x: 0, y: 0, w: nil, h: nil)),
            "no reported box means the icon view, which has a label")
    }

    // MARK: - The frames

    /// **Watched to fail against**: returning `[]`, returning the frames
    /// unclipped, and dropping the `finderItemOwnsDisplay` filter.
    func testTheRosterClaimsItsIconBoxesAndOnlyInsideTheIconField() {
        let content = CGRect(x: 0, y: 0, width: 320, height: 220)
        let plain = Self.folder(items: [
            Self.item("Docs", x: 40, y: 60),
            Self.item("Ghost", x: 90, y: 60, placed: false),
        ])
        XCTAssertEqual(
            SceneRenderer.finderItemFrames(plain, content: content),
            [CGRect(x: 40, y: 60, width: 32, height: 32)],
            "the placed item claims its box; the unplaced one claims nothing")

        XCTAssertEqual(
            SceneRenderer.finderItemFrames(Self.folder(items: nil),
                                           content: content),
            [],
            "a window with no roster claims nothing at all")

        /* A SCROLLED window reports positions that run off both ends of its
           content. An unclipped claim would punch a hole in the scrollbar
           and the info bar for an item nobody can see. */
        let scrolled = Self.folder(
            items: [Self.item("Above", x: 40, y: -400),
                    Self.item("Visible", x: 40, y: 60)],
            controls: [
                .init(ref: "vbar", role: "scrollbar", title: "",
                      rect: Rect(l: 304, t: 40, r: 320, b: 204),
                      enabled: true, visible: true),
                .init(ref: "hbar", role: "scrollbar", title: "",
                      rect: Rect(l: 0, t: 204, r: 304, b: 220),
                      enabled: true, visible: true),
            ])
        XCTAssertEqual(
            SceneRenderer.finderItemFrames(scrolled, content: content),
            [CGRect(x: 40, y: 60, width: 32, height: 32)],
            "an item scrolled out of the icon field claims nothing")
    }

    // MARK: - What a person sees

    /// **The window does not go blank.** This is arbitration, not
    /// suppression: a folder with a roster and no display list is the
    /// ordinary case, and the pixel islands' removal means there is nothing
    /// behind the roster to fall back on.
    ///
    /// **Watched to fail against**: making the roster yield whenever the
    /// window carries a display list at all, and against suppressing the
    /// roster outright.
    func testARosterWithNoInkStillDraws() throws {
        let win = Self.folder(items: [Self.item("Docs", x: 40, y: 60)])
        let png = try RenderShot.png(scene: Self.scene([win]))
        let o = Self.contentOrigin
        let box = CGRect(x: o.x + 40, y: o.y + 60, width: 32, height: 44)
        XCTAssertFalse(darkPixels(png, in: box).isEmpty,
                       "a roster-only folder window must still draw its icons")
    }

    func testNameViewDrawsTheSemanticNameBesideTheRowIcon() throws {
        var win = Self.folder(items: [
            Self.item("Documents", x: 40, y: 60, w: 16, h: 16),
        ])
        win.finder = .init(path: "Macintosh HD:", view: .name)
        let png = try RenderShot.png(scene: Self.scene([win]))
        let o = Self.contentOrigin
        let label = CGRect(x: o.x + 60, y: o.y + 60,
                           width: 90, height: 16)
        XCTAssertFalse(darkPixels(png, in: label).isEmpty,
                       "list view cannot depend on Finder P3 to supply names")
    }

    func testButtonViewDrawsTheRaisedWellAndLabelBelowIt() throws {
        var win = Self.folder(items: [
            Self.item("Documents", x: 40, y: 50, w: 48, h: 48),
        ])
        win.finder = .init(path: "Macintosh HD:", view: .button)
        let png = try RenderShot.png(scene: Self.scene([win]))
        var icon = win
        icon.finder?.view = .icon
        let iconPNG = try RenderShot.png(scene: Self.scene([icon]))
        let o = Self.contentOrigin
        XCTAssertGreaterThan(
            differences(png, iconPNG,
                        in: CGRect(x: o.x + 40, y: o.y + 50,
                                   width: 48, height: 48)),
            100, "Buttons must own a raised well, not reuse icon view")
        let label = CGRect(x: o.x, y: o.y + 90,
                           width: 150, height: 35)
        var unnamed = win
        unnamed.items?[0].name = ""
        let unnamedPNG = try RenderShot.png(scene: Self.scene([unnamed]))
        XCTAssertGreaterThan(differences(png, unnamedPNG, in: label), 0,
                             "Buttons has a centred label below the raised well")
    }

    func testListViewDrawsTheCountBarAndRuledFinderField() throws {
        var win = Self.folder(
            items: [Self.item("Documents", x: 26, y: 44, w: 16, h: 16)],
            controls: [
                .init(ref: "name", role: "control", title: "Name",
                      rect: Rect(l: 0, t: 23, r: 180, b: 43),
                      enabled: true, visible: true,
                      semantic: .init(knowledge: .known,
                                      kind: "columnHeader")),
                .init(ref: "v", role: "scrollbar", title: "",
                      rect: Rect(l: 304, t: 43, r: 320, b: 204),
                      enabled: true, visible: true),
                .init(ref: "h", role: "scrollbar", title: "",
                      rect: Rect(l: 0, t: 204, r: 304, b: 220),
                      enabled: true, visible: true),
            ])
        win.finder = .init(path: "Macintosh HD:", view: .name)
        let png = try RenderShot.png(scene: Self.scene([win]))
        let o = Self.contentOrigin
        let info = try XCTUnwrap(pixel(png, x: o.x + 8, y: o.y + 8))
        XCTAssertFalse(info.0 == 255 && info.1 == 255 && info.2 == 255,
                       "the item-count bar is Finder chrome, not bare paper")
        let field = try XCTUnwrap(pixel(png, x: o.x + 220, y: o.y + 50))
        XCTAssertTrue(field.0 == 238 && field.1 == 238 && field.2 == 238,
                      "the 8.6 list field is light grey")
        XCTAssertFalse(darkPixels(
            png, in: CGRect(x: o.x + 12, y: o.y + 47,
                            width: 8, height: 12)).isEmpty,
            "folder list rows carry disclosure triangles")
    }

    func testListViewDrawsCatalogMetadataInSemanticColumns() throws {
        var win = Self.folder(
            items: [Self.item("Read Me", x: 26, y: 44, w: 16, h: 16,
                              kind: "file")],
            controls: [
                .init(ref: "name", role: "control", title: "Name",
                      rect: Rect(l: 0, t: 23, r: 150, b: 43),
                      enabled: true, visible: true,
                      semantic: .init(knowledge: .known,
                                      kind: "columnHeader")),
                .init(ref: "date", role: "control", title: "Date Modified",
                      rect: Rect(l: 150, t: 23, r: 235, b: 43),
                      enabled: true, visible: true,
                      semantic: .init(knowledge: .known,
                                      kind: "columnHeader")),
                .init(ref: "size", role: "control", title: "Size",
                      rect: Rect(l: 235, t: 23, r: 275, b: 43),
                      enabled: true, visible: true,
                      semantic: .init(knowledge: .known,
                                      kind: "columnHeader")),
                .init(ref: "kind", role: "control", title: "Kind",
                      rect: Rect(l: 275, t: 23, r: 304, b: 43),
                      enabled: true, visible: true,
                      semantic: .init(knowledge: .known,
                                      kind: "columnHeader")),
                .init(ref: "v", role: "scrollbar", title: "",
                      rect: Rect(l: 304, t: 43, r: 320, b: 204),
                      enabled: true, visible: true),
                .init(ref: "h", role: "scrollbar", title: "",
                      rect: Rect(l: 0, t: 204, r: 304, b: 220),
                      enabled: true, visible: true),
            ])
        win.finder = .init(
            path: "Macintosh HD:", view: .name,
            itemMetadata: ["Read Me": .init(
                dataBytes: 2_048, rsrcBytes: 0, modified: 2_082_844_800)])
        var scene = Self.scene([win])
        scene.capturedAt = 0

        let png = try RenderShot.png(scene: scene)
        let o = Self.contentOrigin
        XCTAssertFalse(darkPixels(
            png, in: CGRect(x: o.x + 153, y: o.y + 44,
                            width: 78, height: 16)).isEmpty,
            "the modification date must reach its declared column")
        XCTAssertFalse(darkPixels(
            png, in: CGRect(x: o.x + 238, y: o.y + 44,
                            width: 34, height: 16)).isEmpty,
            "the two-fork size must reach its declared column")
        XCTAssertFalse(darkPixels(
            png, in: CGRect(x: o.x + 278, y: o.y + 44,
                            width: 24, height: 16)).isEmpty,
            "the item kind must reach its declared column")
    }

    func testFinderMetadataFormattingUsesClassicEpochAndForkTotal() {
        XCTAssertEqual(SceneRenderer.finderModifiedString(
            2_082_844_800, relativeTo: 0), "Today, 12:00 AM")
        XCTAssertEqual(SceneRenderer.finderSizeString(.init(
            dataBytes: 1_024, rsrcBytes: 1_025)), "3 K")
        XCTAssertNil(SceneRenderer.finderSizeString(.init()))
    }

    func testFinderSnapshotSelectionChangesTheSemanticRow() throws {
        var plain = Self.folder(items: [
            Self.item("Documents", x: 40, y: 60, w: 16, h: 16),
        ])
        plain.finder = .init(path: "Macintosh HD:", view: .name)
        var selected = plain
        selected.finder?.selectedNames = ["Documents"]
        let a = try RenderShot.png(scene: Self.scene([plain]))
        let b = try RenderShot.png(scene: Self.scene([selected]))
        let o = Self.contentOrigin
        XCTAssertGreaterThan(
            differences(a, b, in: CGRect(x: o.x + 40, y: o.y + 60,
                                         width: 112, height: 18)), 0)
    }

    /// Finder semantics now own the whole interior. Historical display ops
    /// must not alter a semantic render: accepting even the text subset would
    /// silently restore the same P3 path that crashes Finder on the PB1400c.
    func testHistoricalFinderDisplayCannotAlterTheSemanticInterior() throws {
        let o = Self.contentOrigin
        let ops = [Self.blit([40, 60, 72, 92]),
                   Self.run("Documents", x: 22, y: 103)]
        let semanticOnly = Self.folder(
            items: [Self.item("Documents", x: 40, y: 60)])
        let both = Self.folder(items: [Self.item("Documents", x: 40, y: 60)],
                               display: ops)
        let expected = try RenderShot.png(scene: Self.scene([semanticOnly]))
        let actual = try RenderShot.png(scene: Self.scene([both]))
        XCTAssertEqual(differences(expected, actual,
                                   in: CGRect(x: o.x, y: o.y,
                                              width: 320, height: 220)), 0)
    }

    /// **The yield is to WORDS, not to any ink at all** — and this is the
    /// half the first version of this file could not see. Written with only
    /// the test above, `textCovers` and `mostlyCovers` were
    /// indistinguishable: both yield to a run that fills the patch, so the
    /// widening mutation passed a guard that claimed to catch it. Recorded
    /// because a guard watched against one mutation is not watched.
    ///
    /// The case that separates them is a machine that painted the label
    /// band and wrote nothing in it — a selection band, a frame line, the
    /// window's own erase. `mostlyCovers` calls that covered and the name
    /// disappears; `textCovers` asks whether the machine wrote WORDS there,
    /// which it did not, so the roster's name is the only one anybody has
    /// and it draws. It is the same distinction that kept Date & Time's
    /// check boxes.
    ///
    /// **Watched to fail against**: widening the yield to `mostlyCovers`,
    /// and against yielding on `covers`.
    func testInkThatIsNotWordsDoesNotTakeTheName() throws {
        let o = Self.contentOrigin
        var band = DisplayOp(op: "rect", ticks: 1)
        band.verb = 1                                   // paint
        band.rect = [20, 90, 130, 108]
        let win = Self.folder(items: [Self.item("Documents", x: 40, y: 60)],
                              display: [band])
        let silent = Self.folder(items: nil, display: [band])

        let label = CGRect(x: o.x + 20, y: o.y + 92, width: 110, height: 16)
        let withRoster = try RenderShot.png(scene: Self.scene([win]))
        let without = try RenderShot.png(scene: Self.scene([silent]))
        XCTAssertGreaterThan(
            differences(without, withRoster, in: label), 0,
            "the machine painted this band and wrote nothing in it, so the "
            + "roster's name is the only one anybody has: it must draw")
    }

    /// Finder's display stream is categorically outside the interior now —
    /// before the first roster page as well as after it. A stale P3 frame must
    /// not briefly hatch the blank host surface and then disappear when icons
    /// arrive; that transition is the static-image ownership this boundary
    /// removes.
    func testFinderDisplayNeverOwnsTheInterior() throws {
        let o = Self.contentOrigin
        let hatched = Self.folder(items: nil,
                                  display: [Self.blit([40, 60, 72, 92])])
        let claimed = Self.folder(items: [Self.item("Docs", x: 40, y: 60)],
                                  display: [Self.blit([40, 60, 72, 92])])
        let box = CGRect(x: o.x + 40, y: o.y + 60, width: 32, height: 32)

        let bare = try RenderShot.png(
            scene: Self.scene([Self.folder(items: nil, display: [])]))
        let leakedBeforeRoster = differences(
            bare, try RenderShot.png(scene: Self.scene([hatched])), in: box)
        XCTAssertEqual(leakedBeforeRoster, 0,
                       "Finder P3 leaked before semantic items arrived")

        /* The roster's own art is drawn in the same box, so the reading that
           separates the two is the box with the roster present and the blit
           ABSENT: if the exclusion works, adding the blit back changes
           nothing inside the box. */
        let rosterOnly = try RenderShot.png(scene: Self.scene([
            Self.folder(items: [Self.item("Docs", x: 40, y: 60)],
                        display: [])]))
        let rosterOverBlit = try RenderShot.png(scene: Self.scene([claimed]))
        let leaked = differences(rosterOnly, rosterOverBlit, in: box)
        XCTAssertEqual(
            leaked, 0,
            "a blit the roster has claimed must leave no mark: \(leaked) "
            + "pixels of hatch showed through the icon drawn over it")
    }
}
