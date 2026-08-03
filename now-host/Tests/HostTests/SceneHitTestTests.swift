import XCTest
import MirrorKit

/// Aim at a control's own centre and get that control back.
///
/// ## Why this exists
///
/// `SceneIRDecodeTests` proves NOW's scene parses; `SceneRenderTests`
/// proves it draws. Both passed on a document whose controls were in the
/// **wrong coordinate space**, because a rect is four honest integers in
/// either space and nothing about the numbers says which one they are.
///
/// The consequence is not an error. `HitTester` converts a click into
/// content-relative coordinates and compares; hand it global rects and
/// every control is tested against a box displaced by its own window's
/// origin, so the click resolves to a NEIGHBOUR or to nothing. Measured
/// on a live Finder on 2026-08-02: a point aimed at one scrollbar in
/// About This Computer resolved to a different control ninety pixels
/// away. The render looked right the whole time.
///
/// That is what "the mirror is connected and the pane cannot click" is
/// made of, and it is the failure the archived port died on. So the gate
/// is a round trip through the consumer's own geometry: take the control
/// the producer described, compute where it says that control is on
/// screen, ask the hit tester what is there, and require the same
/// control back. Nothing else in this suite can fail on a space mismatch;
/// this cannot pass through one.
final class SceneHitTestTests: XCTestCase {

    private func scene() throws -> MirrorKit.Scene {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "now-scene-ir-v1",
                              withExtension: "json",
                              subdirectory: "Fixtures"))
        return try JSONDecoder().decode(MirrorKit.Scene.self,
                                        from: Data(contentsOf: url))
    }

    /// The control under a resolved hit, whichever shape the target took
    /// (a ranged control resolves to `.scrollbar`, a plain one to
    /// `.control`; both name the control, and this test is about WHICH
    /// control, not about which of the two).
    private func hitControl(_ t: HitTester.Target) -> MirrorKit.Scene.Control? {
        switch t {
        case .control(_, let c): return c
        case .scrollbar(_, let c, _, _, _): return c
        default: return nil
        }
    }

    func testAControlsOwnCentreHitsThatControl() throws {
        let scene = try scene()
        var checked = 0

        for win in scene.windows where win.visible {
            /* The producer's own claim about where this window's content
               begins - the same arithmetic HitTester does, which is the
               point: if the two disagree the round trip breaks. */
            let originX = win.rect.l
            let originY = win.rect.t + SceneBuilder.titleBarHeight

            for ctl in win.controls where ctl.visible {
                guard let r = ctl.rect, !ctl.ref.isEmpty else { continue }
                let x = originX + (r.l + r.r) / 2
                let y = originY + (r.t + r.b) / 2

                /* Genuine overlap is not a defect: an earlier control in
                   the chain legitimately wins the point, and the Finder
                   really does nest them. Skip those rather than assert a
                   z-order this document does not carry. */
                let occluders = win.controls.prefix { $0.ref != ctl.ref }
                    .filter { other in
                        guard other.visible, let o = other.rect else {
                            return false
                        }
                        let lx = x - originX, ly = y - originY
                        return lx >= o.l && lx < o.r && ly >= o.t && ly < o.b
                    }
                if !occluders.isEmpty { continue }

                let target = HitTester.hitTest(scene, x: x, y: y)
                let got = hitControl(target)
                let landed = got.map { "control \($0.ref)" } ?? "\(target)"
                XCTAssertEqual(got?.ref, ctl.ref, """
                    A point computed from control \(ctl.ref) in window \
                    "\(win.title)" - its own centre, at global (\(x),\(y)) - \
                    resolved to \(landed).

                    The producer and the hit tester disagree about the SPACE \
                    of Control.rect. IR v1 says content-relative; the guest \
                    walk (now-guest-ppc/src/scene/scene_walk.c) must subtract \
                    the window's content origin, because now_ax_read_control \
                    hands it globals for the act plane's benefit. A person \
                    driving this mirror would click one control and actuate \
                    another.
                    """)
                checked += 1
            }
        }

        XCTAssertGreaterThan(checked, 0,
                             "no visible control carried a rect and a ref, so "
                             + "this asserted nothing - recapture the fixture "
                             + "with a window that has controls")
    }

    /// The window box must be the FRAME, not the content region: the
    /// renderer draws a title bar in the top `titleBarHeight` of it, and
    /// `HitTester` treats anything above the content origin as title bar.
    /// A producer emitting the content rect here shifts every control by
    /// twenty pixels - the same failure, one layer up.
    func testAWindowBoxLeavesRoomForItsTitleBar() throws {
        let scene = try scene()

        for win in scene.windows where win.visible && win.kind != 2 {
            let controls = win.controls.compactMap(\.rect)
            guard let topmost = controls.map(\.t).min() else { continue }
            XCTAssertGreaterThanOrEqual(topmost, 0, """
                A control in "\(win.title)" sits at content-relative t=\
                \(topmost), above its own window's content origin. Either \
                the control rects are in another space, or `rect` on the \
                window is the CONTENT region where the IR wants the frame \
                (content grown up by \(SceneBuilder.titleBarHeight)).
                """)
        }
    }
}
