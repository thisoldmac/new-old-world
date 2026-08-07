import XCTest
import AppKit
import SwiftUI
@testable import MirrorKit
@testable import MirrorKitUI

/// **The press, in pixels.**
///
/// The method is the one `UnknownVisualRenderTests` established and
/// `ProvisionalDragRenderTests` followed: render offscreen through the real
/// drawing path, then sample — because a palette asserted in source proves
/// nothing about what a person sees.
///
/// What these pin is narrower than "the press looks right", which is a human
/// judgement. They pin the claims the code makes that a later edit could
/// silently break: that the three states are three DIFFERENT pictures, that
/// the mark lands on the pressed button and no other, that the wait bar
/// tracks the deadline, and that the label stays readable underneath.
@MainActor
final class PressedRenderTests: XCTestCase {

    /// Two push buttons side by side, so "the right one lit up" is a
    /// question the pixels can answer. A single-button fixture would pass
    /// with a renderer that pressed everything.
    private func scene() -> MirrorKit.Scene {
        func button(_ ref: String, _ title: String, x: Int) -> MirrorKit.Scene.Control {
            MirrorKit.Scene.Control(ref: ref, role: "button", title: title,
                          rect: Rect(l: x, t: 40, r: x + 120, b: 60),
                          enabled: true, visible: true,
                          semantic: nil)
        }
        let window = MirrorKit.Scene.Window(
            id: "w1", app: "Fixture", psn: "0:1", title: "Fixture",
            rect: Rect(l: 20, t: 20, r: 340, b: 140),
            front: true, z: 0, visible: true,
            controls: [button("c.ok", "OK", x: 20),
                       button("c.cancel", "Cancel", x: 160)])
        return MirrorKit.Scene(version: 2, seq: 1, source: "fixture", capturedAt: 0,
                     screen: .init(w: 360, h: 160), apps: [],
                     processes: nil, menubar: nil, windows: [window],
                     desktopItems: nil, meta: .init(errors: []))
    }

    private func shot(_ pressed: SceneRenderer.PressedControl?) throws
        -> NSBitmapImageRep {
        let data = try RenderShot.png(scene: scene(), pressed: pressed)
        return try XCTUnwrap(NSBitmapImageRep(data: data))
    }

    private func control(_ ref: String, showsPressed: Bool = true,
                         showsSpinner: Bool = false,
                         progress: Double = 0)
        -> SceneRenderer.PressedControl {
        .init(ref: ref, frame: Rect(l: 0, t: 0, r: 0, b: 0),
              showsPressed: showsPressed, showsSpinner: showsSpinner,
              progress: progress)
    }

    /// Mean colour of a patch, as a cheap stable summary of "what is drawn
    /// here" that does not depend on where inside the button a given pixel
    /// falls.
    private func mean(_ rep: NSBitmapImageRep, _ r: CGRect) -> (Double, Double,
                                                                Double) {
        var rs = 0.0, gs = 0.0, bs = 0.0, n = 0.0
        for y in Int(r.minY)..<Int(r.maxY) {
            for x in Int(r.minX)..<Int(r.maxX) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                rs += c.redComponent; gs += c.greenComponent
                bs += c.blueComponent; n += 1
            }
        }
        return n == 0 ? (0, 0, 0) : (rs / n, gs / n, bs / n)
    }

    /// Scene coords → shot coords. Controls are content-relative; the window
    /// rect's top is the STRUCTURE top, one title bar above the content.
    private func onScreen(_ r: Rect) -> CGRect {
        CGRect(x: CGFloat(r.l + 20), y: CGFloat(r.t + 20 + 20),
               width: CGFloat(r.r - r.l), height: CGFloat(r.b - r.t))
    }
    private var okRect: CGRect { onScreen(Rect(l: 20, t: 40, r: 140, b: 60)) }
    private var cancelRect: CGRect {
        onScreen(Rect(l: 160, t: 40, r: 280, b: 60))
    }

    // MARK: - The three states are three pictures

    /// **The core claim.** Unpressed, pressed-and-waiting, and settled must
    /// not look the same, or the marking says nothing.
    ///
    /// Mutation: make `drawPressed` a no-op, or drop the `isPressed` call
    /// from `drawButton`. The press then never appears and the person gets
    /// the silence this whole slice exists to remove.
    func testPressedDoesNotLookLikeUnpressed() throws {
        let idle = try shot(nil)
        let down = try shot(control("c.ok"))
        XCTAssertNotEqual(mean(idle, okRect).0, mean(down, okRect).0,
                          accuracy: 0.0005,
                          "a pressed button must not be drawn identically to "
                          + "an unpressed one — the marking IS the feedback")
    }

    /// A settled press stops being drawn. `showsPressed` false must restore
    /// the ordinary button exactly.
    ///
    /// Mutation: have `isPressed` ignore `showsPressed` and match on `ref`
    /// alone. The button then stays down forever after the verdict — a press
    /// that is over, still asserting itself.
    func testASettledPressIsDrawnExactlyLikeAnUnpressedButton() throws {
        let idle = try RenderShot.png(scene: scene(), pressed: nil)
        let settled = try RenderShot.png(
            scene: scene(),
            pressed: control("c.ok", showsPressed: false))
        XCTAssertEqual(idle, settled,
                       "once the press has settled the button is just a "
                       + "button again, to the pixel")
    }

    // MARK: - The right button, and only the right button

    /// Mutation: match on `title` or on the rect instead of `ref` in
    /// `isPressed`, or drop the comparison so every control lights. Two
    /// buttons is the minimum fixture that catches it.
    func testOnlyThePressedControlIsMarked() throws {
        let idle = try shot(nil)
        let down = try shot(control("c.ok"))
        XCTAssertNotEqual(mean(idle, okRect).0, mean(down, okRect).0,
                          accuracy: 0.0005, "the pressed button changed")
        XCTAssertEqual(mean(idle, cancelRect).0, mean(down, cancelRect).0,
                       accuracy: 0.0001,
                       "the button NOBODY pressed must be untouched — a mark "
                       + "on the wrong control is worse than no mark")
    }

    // MARK: - The wait bar

    /// The spinner appears only while waiting, and tracks the deadline.
    ///
    /// Mutation: draw the bar unconditionally in `drawButton`. A press that
    /// has not been dispatched then shows a wait for a question never sent.
    func testTheWaitBarAppearsOnlyWhileWaiting() throws {
        let pressedOnly = try shot(control("c.ok", showsSpinner: false))
        let waiting = try shot(control("c.ok", showsSpinner: true,
                                       progress: 0.5))
        XCTAssertNotEqual(mean(pressedOnly, okRect).0, mean(waiting, okRect).0,
                          accuracy: 0.0005,
                          "the wait must be visible as something the plain "
                          + "pressed state is not")
    }

    /// **The bar fills.** A fuller bar must put more ink on the button than
    /// an emptier one, monotonically — that is the whole content of a
    /// determinate indicator.
    ///
    /// Mutation: ignore `progress` in `drawWait` and always fill the track
    /// (or never). The indicator becomes a barber's pole with extra steps —
    /// it says "working" and can never be wrong, which is exactly the
    /// instrument `PressSession.patience` exists to avoid.
    func testTheWaitBarFillsWithProgress() throws {
        var last = Double.greatestFiniteMagnitude
        for p in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let rep = try shot(control("c.ok", showsSpinner: true,
                                       progress: p))
            /* Darker ink = lower mean. Sampled over the bar's own band so
               the label's pixels do not swamp a 3px stripe. */
            let band = CGRect(x: okRect.minX, y: okRect.maxY - 6,
                              width: okRect.width, height: 5)
            let ink = mean(rep, band).0
            XCTAssertLessThanOrEqual(
                ink, last + 0.0001,
                "the bar must not get LIGHTER as the wait runs down "
                + "(progress \(p))")
            last = ink
        }
        let band = CGRect(x: okRect.minX, y: okRect.maxY - 6,
                          width: okRect.width, height: 5)
        let empty = try shot(control("c.ok", showsSpinner: true, progress: 0))
        let half = try shot(control("c.ok", showsSpinner: true, progress: 0.5))
        let full = try shot(control("c.ok", showsSpinner: true, progress: 1))
        XCTAssertLessThan(mean(full, band).0, mean(empty, band).0 - 0.02,
                          "a full bar must be visibly darker than an empty "
                          + "one, or the person cannot see the answer coming "
                          + "due")
        /* THE MIDPOINT, and it is the assertion that does the work. An
           earlier version of this test compared only 0 against 1 and a
           mutation that ignored `progress` entirely — always filling the
           whole track — PASSED IT, because `drawWait` returns early at
           progress 0 and so the empty case stayed empty by a different
           route. A half-full bar is the only sample that can tell a
           determinate indicator from a barber's pole. */
        XCTAssertGreaterThan(mean(half, band).0, mean(full, band).0 + 0.01,
                             "a half-run wait must be visibly LIGHTER than a "
                             + "finished one — a bar that is always full is "
                             + "an indeterminate indicator wearing a "
                             + "deadline's clothes")
        XCTAssertLessThan(mean(half, band).0, mean(empty, band).0 - 0.01,
                          "and visibly darker than one that has not started")
    }

    /// The bar must not swallow the label. A person who cannot read WHICH
    /// button is busy has been told less, not more.
    ///
    /// Mutation: centre the bar on `frame.midY` instead of its lower edge.
    /// It then crosses the title and the button becomes unreadable at
    /// exactly the moment it matters most.
    func testTheWaitBarDoesNotCoverTheLabel() throws {
        /* PRESSED-BUT-NOT-WAITING is the control, not the idle button.
           Comparing against idle folds in the WASH, which tints the whole
           face and moved this band by 0.11 — so the tolerance had to be
           loose enough to admit the wash, and a mutation that recentred the
           bar on `frame.midY`, straight through the title, slipped under it.
           Holding the wash constant and varying only the bar isolates the
           one thing this test is about, and needs no tolerance at all. */
        let washOnly = try shot(control("c.ok", showsSpinner: false))
        let waiting = try shot(control("c.ok", showsSpinner: true,
                                       progress: 1))
        let label = CGRect(x: okRect.minX + 4, y: okRect.minY + 3,
                           width: okRect.width - 8, height: 10)
        XCTAssertEqual(mean(washOnly, label).0, mean(waiting, label).0,
                       accuracy: 0.001,
                       "the wait indicator belongs inside the button's lower "
                       + "edge, not across its title — a full bar must leave "
                       + "the label's own band untouched")
    }

    // MARK: - The family

    /// **The vocabulary is shared on purpose, and this is what says so.**
    ///
    /// `PressedVisual` borrows `ProvisionalVisual`'s edge and mark ink and
    /// `UnknownVisual`'s stipple, because "we do not know", "not yet real"
    /// and "asked, still waiting" are one idea in three tenses. A later edit
    /// that gives the press its own palette "to make it stand out" is the
    /// drift this arc has merged away twice, and nothing else in either file
    /// would notice.
    func testThePressBorrowsTheProvisionalFamilysInkRatherThanItsOwn() {
        XCTAssertEqual(PressedVisual.edge, ProvisionalVisual.edge,
                       "one edge for one kind of doubt")
        XCTAssertEqual(PressedVisual.indicatorInk, ProvisionalVisual.markInk,
                       "the wait's ink is the provisional mark's ink")
        XCTAssertEqual(PressedVisual.indicatorTrack, UnknownVisual.stipple,
                       "and its track is the marked unknown's stipple — two "
                       + "vocabularies for one idea is the defect this arc "
                       + "has already merged away twice")
    }
}
