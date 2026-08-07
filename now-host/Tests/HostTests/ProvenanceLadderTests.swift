import XCTest
import AppKit
import MirrorKit
import MirrorKitUI
@testable import Host

/// **The ladder, rung by rung, on captures that carry all four.**
///
/// Plan 018 slice 2 replaced five predicates with one ordered resolution.
/// A resolution is only worth having if every rung can be pointed at, so
/// each test here names ONE rung and the rectangle that must land on it —
/// and each was watched failing by mutation before it was kept. The
/// mutation is recorded in the test's own doc comment, because a mutation
/// nobody wrote down is a claim that the test works.
@MainActor
final class ProvenanceLadderTests: XCTestCase {

    private func scene(_ name: String) throws -> MirrorKit.Scene {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try NOWMirrorSceneDecoder.decode(
            irVersion: 2, document: Data(contentsOf: url))
    }

    private func window(_ sceneName: String, titled: String) throws
        -> MirrorKit.Scene.Window {
        let all = try scene(sceneName).windows
        return try XCTUnwrap(all.first { $0.title == titled },
                             "\(sceneName) has no window titled \(titled)")
    }

    /// The ladder in window-local coordinates: `content` at the origin, so
    /// a fixture's own rects are the rects asserted on.
    private func ladder(_ win: MirrorKit.Scene.Window,
                        owning: [CGRect] = []) -> ProvenanceLadder {
        SceneRenderer.ladder(for: win, content: .zero, owning: owning)
    }

    private func box(_ l: Int, _ t: Int, _ r: Int, _ b: Int) -> CGRect {
        CGRect(x: l, y: t, width: r - l, height: b - t)
    }

    // MARK: - Rung 3: art addressed by identity

    /// **A DITL row typed `icon` NAMES its rectangle, and that is the only
    /// thing on this ladder that may put art there.**
    ///
    /// The IE TLS alert's stop sign is a 32×32 blit at (23,13)-(55,45) and
    /// the guest types the row `icon`. It gets the generic stub — the guest
    /// said an icon is there and did not say which, so a stub is the honest
    /// maximum and a hatch would be a false claim.
    ///
    /// Watched failing by mutation: dropping the `kind == "icon"` arm from
    /// `SceneRenderer.ladder` makes `art(at:)` nil and this fails naming
    /// the rectangle.
    func testATypedIconRowNamesItsRectangle() throws {
        let alert = try window("scene-ie-error-alert", titled: "Error")
        let ladder = ladder(alert)
        XCTAssertEqual(ladder.art(at: box(23, 13, 55, 45)), .icon,
                       "the alert's icon row must name its own rectangle")
        XCTAssertEqual(ladder.owner(ofUnjoinedBlit: box(23, 13, 55, 45)),
                       .namedArt)
    }

    /// **A typed control NAMES its rectangle; the plate is drawn because
    /// P2 said "control", not because the blit was 68 points wide.**
    ///
    /// Watched failing by mutation: relaxing the `knowledge == .known`
    /// guard to accept unknown controls makes the Finder's untyped scroll
    /// bar name its arrows, and `testAScrollArrowIsNeverADocument` fails
    /// instead — which is the pair of tests doing its job.
    func testATypedControlNamesItsRectangle() throws {
        let alert = try window("scene-ie-error-alert", titled: "Error")
        // The OK button, a known pushButton.
        XCTAssertEqual(ladder(alert).art(at: box(336, 84, 404, 104)),
                       .control)
    }

    /// **Backgrounds name nothing.**
    ///
    /// A `panel`, `placard`, `selectionBand`, `groupBox` or `userItem`
    /// routinely wraps most of a window. Letting one name every blit inside
    /// it would be the `dialogItemOwnsDisplay` defect wearing a third hat —
    /// the same mistake that took Date & Time's date, its time and both its
    /// group boxes on 2026-08-06.
    ///
    /// The alert's two `userItem` rows are the default-button outline slots
    /// and they sit ON TOP of buttons, which is why this matters here
    /// rather than in the abstract.
    ///
    /// Watched failing by mutation: deleting `userItem` from
    /// `isBackgroundKind` makes the slot at (113,80)-(201,108) name a
    /// rectangle it only overlaps, and this fails.
    func testABackgroundRowNamesNothing() throws {
        let alert = try window("scene-ie-error-alert", titled: "Error")
        let l = ladder(alert)
        // A rectangle inside the second user-item slot, and nowhere near a
        // typed control.
        XCTAssertNil(l.art(at: box(120, 88, 136, 104)),
                     "a user-item background named a blit inside it")
    }

    // MARK: - Rung 4: the marked unknown

    /// **A scroll arrow is never a document. Michelle's complaint #5, as a
    /// gate.**
    ///
    /// The Finder's `Macintosh HD` window emits its scroll arrows as 16×16
    /// CopyBits — `[389,173,405,189]` and `[389,188,405,204]` for the
    /// vertical bar, `[359,203,375,219]` and `[374,203,390,219]` for the
    /// horizontal — and its scroll bars arrive with `role: "unknown"` and
    /// no semantic kind. Under the retired `iconSized` rule every one of
    /// them was painted as a generic page icon: a confident wrong answer,
    /// which rule 1 of plan 018 forbids outright.
    ///
    /// Watched failing by mutation: restoring the old rule (any near-square
    /// blit → `IconAtlas.namedIcon("document")`) makes `art(at:)` answer
    /// `.icon` for all four and this fails naming each one.
    func testAScrollArrowIsNeverADocument() throws {
        let finder = try window("now-scene-sweep18a-finder-icon",
                                titled: "Macintosh HD")
        let l = ladder(finder)
        for arrow in [box(389, 173, 405, 189), box(389, 188, 405, 204),
                      box(359, 203, 375, 219), box(374, 203, 390, 219)] {
            XCTAssertNil(l.art(at: arrow), """
                \(arrow) is a scroll arrow. Nothing in this scene names it \
                — the scroll bars arrive untyped — so it is an UNKNOWN. A \
                16×16 blit is not evidence of a document; sweep A found \
                that claim wrong every time it fired.
                """)
            XCTAssertEqual(l.owner(ofUnjoinedBlit: arrow), .unknown)
        }
    }

    /// **The Finder's interior is an unknown, and the ladder can say why.**
    ///
    /// This is the exit criterion in its honest form. The Finder composites
    /// its icon view into an offscreen GWorld and blits the whole thing in
    /// one op (measured three ways upstream, `docs/toolbox-and-gworld.md`
    /// §5a). In this capture that world was born before the hook was armed,
    /// so no `blitsrc` names it and no ops were held for it — the blit
    /// cannot join. The scene carries no `finderItems` either.
    ///
    /// So there is nothing on rungs 1, 2 or 3 for that rectangle, and the
    /// render must be a marked gap rather than a guess. What the ladder
    /// adds is that the gap is now EXPLAINED: exactly one rectangle, the
    /// composite's own, and it is unknown for a reason that can be stated.
    ///
    /// When the world IS hooked at birth the same rectangle joins and
    /// becomes rung 1 — `NOWMirrorContentCoverageTests` holds that case on
    /// `qdtrace-drain-blitsrc-finder`.
    func testTheFindersInteriorIsOneExplainedGap() throws {
        let finder = try window("now-scene-sweep18a-finder-icon",
                                titled: "Macintosh HD")
        let interior = box(0, 0, 404, 218)
        XCTAssertEqual(ladder(finder).owner(ofUnjoinedBlit: interior),
                       .unknown, """
            the Finder's composite blit resolved to something other than \
            the marked unknown. Nothing in this capture can account for \
            that rectangle: the world was not hooked, so the blit did not \
            join, and the scene carries no finderItems.
            """)
        XCTAssertNil(finder.items,
                     "if this scene gained finderItems the gate above is "
                     + "measuring the wrong thing — rung 2 would answer")
    }

    // MARK: - Rung 2 over rung 3, and rung 1 over both

    /// **A row that OWNS its display outranks a name.**
    ///
    /// `owning` and `named` can both cover a rectangle — a known
    /// `pushButton` is in both — and the ladder must not let rung 3 draw a
    /// plate under a button rung 2 is going to draw properly. Owning
    /// rectangles are excluded from the replay entirely, which is the
    /// mechanism; this asserts the ordering that mechanism implements.
    func testOwningOutranksNaming() throws {
        let alert = try window("scene-ie-error-alert", titled: "Error")
        let ok = box(336, 84, 404, 104)
        let l = ladder(alert, owning: [ok])
        XCTAssertTrue(l.owning.contains { $0.contains(ok) })
        XCTAssertGreaterThan(ProvenanceLadder.Rung.semantics,
                             ProvenanceLadder.Rung.namedArt)
        XCTAssertGreaterThan(ProvenanceLadder.Rung.ink,
                             ProvenanceLadder.Rung.semantics)
    }

    /// **Ink from a superseded epoch stops outranking semantics.**
    ///
    /// The pixels are still the last coherent frame and are still drawn.
    /// What they lose is the right to speak for the window, so a window
    /// caught mid-view-switch shows what P2 knows rather than what P3 drew
    /// for a view that is gone.
    ///
    /// Watched failing by mutation: hard-coding `inkIsCurrent: true` in
    /// `SceneRenderer.ladder` makes the second assertion fail.
    func testASupersededFrameStopsSpeakingForTheWindow() throws {
        var finder = try window("now-scene-sweep18a-finder-icon",
                                titled: "Macintosh HD")
        finder.displayEpoch = DisplayEpoch(generation: 1, epoch: 12,
                                           sceneSequence: 1, stale: false)
        XCTAssertTrue(ladder(finder).inkIsCurrent)
        finder.displayEpoch = DisplayEpoch(generation: 1, epoch: 12,
                                           sceneSequence: 1, stale: true)
        XCTAssertFalse(ladder(finder).inkIsCurrent)
    }

    /// **A window with NO stream is not waiting for one.**
    ///
    /// The degradation rule, at the ladder. `displayEpoch == nil` means
    /// this window has no content plane — record mode off, the application
    /// never armed, no plane at all — and its ink is trivially current
    /// because there is none. Anything else would make "hold the last
    /// coherent frame" mean "hold forever".
    func testAWindowWithNoStreamRendersNow() throws {
        var finder = try window("now-scene-sweep18a-finder-icon",
                                titled: "Macintosh HD")
        finder.displayEpoch = nil
        XCTAssertTrue(ladder(finder).inkIsCurrent,
                      "a window with no content stream must render its "
                      + "semantics immediately, not wait for a plane that "
                      + "is not coming")
    }

}

/// **The desktop is a rectangle on the same ladder, and it is the biggest
/// one in the picture.**
///
/// It used to be two guesses: tile `ppat` 16 across the screen, and fill a
/// hard-coded purple when the pack had none. Lane C measured the first as
/// wrong on the image we run — `ppat` 16 is a shipped DEFAULT, not a
/// setting, and the guest's actual desktop is the 800×600 picture "Indigo
/// Foam", drawn once at the origin (p50 delta 2 against sweep A's own
/// screendump).
@MainActor
final class DesktopProvenanceTests: XCTestCase {

    /// **A size mismatch is an unknown, not a crop.**
    ///
    /// Mac OS 9 ships desktop pictures at 800×600, 1024×768 AND 832×624,
    /// and the alignment field that says what to do with a mismatch is
    /// `null` on the offline route. Drawing at the origin would crop
    /// silently and read as a render bug; scaling would read as a different
    /// picture. Neither is a fact.
    ///
    /// Watched failing by mutation: dropping the size equality guard from
    /// `DesktopPattern.answer` makes an 800×600 picture answer `.picture`
    /// for a 1024×768 screen and this fails.
    func testAPictureThatIsNotTheScreenSizeIsAnUnknown() throws {
        try XCTSkipIf(MirrorKitUI.AssetPack.root == nil,
                      "no asset pack; nothing to resolve against")
        let wrong = DesktopPattern.answer(
            screen: CGSize(width: 1024, height: 768))
        guard case .unknown = wrong else {
            return XCTFail("""
                a desktop picture whose size is not this screen's resolved \
                to \(wrong). The alignment that would say how to place it \
                was not readable, so there is no honest answer but the mark.
                """)
        }
    }

    /// **And the right size resolves to the picture, or the pack cannot
    /// say — never to a tiled default.**
    ///
    /// Both outcomes are acceptable and one of them is not: whatever this
    /// answers, it must never be a pattern the manifest did not name. That
    /// is the deletion this test protects.
    func testTheDesktopIsNeverAnUnnamedDefault() throws {
        try XCTSkipIf(MirrorKitUI.AssetPack.root == nil,
                      "no asset pack; nothing to resolve against")
        switch DesktopPattern.answer(screen: CGSize(width: 800, height: 600)) {
        case .picture, .unknown:
            break
        case .pattern:
            // Legitimate only if the manifest actually says `pattern`.
            XCTFail("resolved to a tiled pattern on a pack whose manifest "
                    + "records a picture — this is the ppat 16 guess back")
        }
    }
}
