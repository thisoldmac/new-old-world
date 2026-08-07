import XCTest
@testable import MirrorKit
@testable import MirrorKitUI

/// **What an empty window interior is allowed to claim.**
///
/// P3 is a per-window spotlight — `qdtrace start` takes exactly one window
/// address and refuses an all-windows arm by name — so in any real scene most
/// windows have no interior. Until this distinction existed they all drew the
/// same hatch, captioned "Guest content not reported": a statement about the
/// machine, made over windows nobody had asked the machine about.
///
/// The consequence was not cosmetic. A screenshot of this product could not
/// separate a design limit from a defect, and four render sweeps' worth of
/// hatched interiors could not be attributed to either. See
/// docs/open-issues.md, "one window interior at a time".
@MainActor
final class AbsentContentCaptionTests: XCTestCase {
    private func window() -> MirrorKit.Scene.Window {
        MirrorKit.Scene.Window(
            id: "w1", app: "Finder", psn: "0.29949953",
            title: "Macintosh HD", kind: 0,
            rect: .init(l: 0, t: 0, r: 300, b: 200),
            front: true, z: 0, visible: true, controls: [])
    }

    func testAWindowThePlaneNeverLookedAtDoesNotBlameTheGuest() {
        var win = window()
        win.contentPlane = .notAttempted
        let caption = SceneRenderer.absentContentCaption(win)
        XCTAssertEqual(caption, "Interior not captured — one window at a time")
        XCTAssertFalse(caption.contains("Guest"),
                       "nothing was asked, so nothing about the guest follows")
    }

    func testAnArmedWindowWithNothingInItStillReportsTheGuest() {
        var win = window()
        win.contentPlane = .armed
        XCTAssertEqual(SceneRenderer.absentContentCaption(win),
                       "Guest content not reported")
    }

    /// No attention stamp at all is the case where NEITHER answer is
    /// available — a host with no content plane, or a window with no exact
    /// guest address, which cannot be armed and so was never declined.
    /// Inventing an answer there is the same mistake in the other direction.
    func testNoStampKeepsTheOlderSentenceRatherThanGuessing() {
        XCTAssertNil(window().contentPlane)
        XCTAssertEqual(SceneRenderer.absentContentCaption(window()),
                       "Guest content not reported")
    }

    /// The two captions must not converge. If a later edit made them equal
    /// the distinction would be gone with every test above still green — the
    /// exact way this defect shipped the first time.
    func testTheTwoAnswersAreDistinguishable() {
        var never = window(); never.contentPlane = .notAttempted
        var asked = window(); asked.contentPlane = .armed
        XCTAssertNotEqual(SceneRenderer.absentContentCaption(never),
                          SceneRenderer.absentContentCaption(asked))
    }
}
