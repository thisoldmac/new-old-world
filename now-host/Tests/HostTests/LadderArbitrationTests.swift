import XCTest
import AppKit
import MirrorKit
import MirrorKitUI
@testable import Host

/// **Two producers of one answer must not both draw it.**
///
/// Fidelity sweep B (2026-08-07) found the Memory panel unreadable: every
/// string in it printed twice, a few points apart, and every static label
/// carried a spurious vertical stroke merged into its first glyph
/// ("Ⅱirtual Memory"). Integration round 4 found the same question in two
/// more places on the same day — Appearance's root user pane erasing all
/// six tabs, and Date & Time's newly classified group boxes being skipped
/// in favour of dialog items that knew nothing.
///
/// **None of the four was a renderer regression.** Sweep A's capture
/// through the same renderer is clean. What changed underneath it was the
/// SCENE: dialog-item titles became real strings, and the CDEF route began
/// naming 71 of 73 controls. The arbitration was never exercised while one
/// side of it was garbage, and the moment both sides became correct they
/// drew at once.
///
/// So these are ladder gates, not pixel-diff gates. Each asks the ladder's
/// own question about a rectangle — *did the machine already answer this?*
/// — and every one of them is a difference measurement against the same
/// scene with its semantic plane removed. An absolute pixel assertion
/// would break on a font or a pack; a difference cannot, because both
/// sides of it move together.
@MainActor
final class LadderArbitrationTests: XCTestCase {

    private static let scene = "now-scene-sweepb-memory"
    private static let drain = "qdtrace-drain-sweepb-memory"

    /// The Memory panel as the app draws it: sweep B's own capture on
    /// sweep B's own scene, controls and dialog items intact.
    private func memory() throws -> MirrorKit.Scene {
        let sceneURL = try XCTUnwrap(Bundle.module.url(
            forResource: Self.scene, withExtension: "json",
            subdirectory: "Fixtures"))
        let scene = try NOWMirrorSceneDecoder.decode(
            irVersion: 2, document: Data(contentsOf: sceneURL))
        let drainURL = try XCTUnwrap(Bundle.module.url(
            forResource: Self.drain, withExtension: "json",
            subdirectory: "Fixtures"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: drainURL)) as? [String: Any])
        let drain = try XCTUnwrap(QDTraceDecode.drain(object))
        let plane = NOWMirrorContentPlane(listener: GuestListener(
            identity: .init(version: "test", name: "Test Host")))
        return plane.apply(drain, to: scene).scene
    }

    /// **Sweep B's own mutation, as the reference.**
    ///
    /// The same scene with every semantic WORD taken away — dialog-item
    /// titles, control titles, `semantic.value` — and nothing else
    /// touched. Backgrounds still draw, furniture still draws, the
    /// exclusion rectangles are still computed; the only thing that
    /// cannot reach the canvas is a string the semantic plane supplied.
    ///
    /// That is deliberately not "remove the controls and the dialog
    /// items". A scene stripped of both draws a different BACKGROUND,
    /// and comparing against it measures the panel's face rather than
    /// the arbitration. Sweep B blanked the titles for exactly this
    /// reason and its `x4` render is what proved R1.
    private func withoutSemanticWords(_ scene: MirrorKit.Scene)
        -> MirrorKit.Scene {
        var out = scene
        for w in out.windows.indices {
            for c in out.windows[w].controls.indices {
                out.windows[w].controls[c].title = ""
                out.windows[w].controls[c].semantic?.value = nil
            }
            for d in (out.windows[w].dialogItems ?? []).indices {
                out.windows[w].dialogItems?[d].title = ""
                out.windows[w].dialogItems?[d].semantic.value = nil
            }
        }
        return out
    }

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

    private func differing(_ a: [UInt8], _ b: [UInt8]) -> Int {
        zip(a, b).filter { $0 != $1 }.count
    }

    /// The panel's window is at (80,60); its content starts one frame and
    /// one title bar in, which is what the renderer computes. These are
    /// the four rectangles sweep B named, taken generously in mirror
    /// space and compared against themselves rather than measured
    /// absolutely.
    private static let labels: [(String, CGRect)] = [
        ("Disk Cache", CGRect(x: 140, y: 82, width: 115, height: 16)),
        ("the Disk Cache paragraph",
         CGRect(x: 248, y: 92, width: 180, height: 46)),
        ("Virtual Memory", CGRect(x: 140, y: 167, width: 115, height: 16)),
        ("Available for use on disk",
         CGRect(x: 248, y: 184, width: 175, height: 16)),
    ]

    /// **R1 AND R2 TOGETHER: a string the machine drew is drawn ONCE, by
    /// the machine.**
    ///
    /// Where the guest's own run is on the canvas, the semantic plane
    /// must add nothing at all — not a second copy of the words, not a
    /// numeric `semantic.value` rendered as a glyph, not a pill. So the
    /// render WITH semantics and the render with rung 1 alone must agree
    /// over these rectangles.
    ///
    /// Watched failing by mutation, both defects separately:
    /// - `Coverage.textCovers` returning false restores R1 and this
    ///   fails on all four rows (the DITL title lands beside the run).
    /// - `SceneRenderer.semanticText` returning `semantic.value`
    ///   unconditionally restores R2 and this fails on "Virtual Memory"
    ///   and "Available for use on disk", whose derived controls carry
    ///   `value: "0"`.
    func testAStringTheMachineDrewIsNotDrawnAgainBySemantics() throws {
        try skipUnlessAssetPack()
        let drawn = try memory()
        let ink = withoutSemanticWords(drawn)
        for (name, box) in Self.labels {
            let a = try pixels(drawn, in: box)
            let b = try pixels(ink, in: box)
            XCTAssertEqual(a.count, b.count)
            XCTAssertLessThanOrEqual(differing(a, b), a.count / 200, """
                \(name) differs in \(differing(a, b)) of \(a.count) pixels \
                between the render and the guest's own drawing alone. The \
                machine drew that string and the semantics plane drew \
                something on top of it — a second copy of the words \
                (sweep B R1), or a control's numeric value as text \
                (sweep B R2). Rung 1 beats rung 2; see \
                DisplayReplay.Coverage.textCovers and \
                SceneRenderer.semanticText.
                """)
        }
    }

    /// **And the capture must still be the one that exhibits it.** A gate
    /// whose fixture was quietly replaced by a clean capture proves
    /// nothing, so this asserts the two conditions that made sweep B's
    /// scene different from sweep A's: real DITL titles, and CDEF-derived
    /// controls carrying a numeric value.
    func testTheFixtureIsStillTheSceneThatBrokeTheRender() throws {
        let scene = try memory()
        let window = try XCTUnwrap(scene.windows.first(where: \.front))
        XCTAssertEqual(window.title, "Memory")
        let titles = (window.dialogItems ?? []).map(\.title)
        XCTAssertTrue(titles.contains("Virtual Memory"),
                      "the pointer-title defect is fixed in this capture "
                      + "and that is the whole reason it broke the render")
        XCTAssertTrue(titles.contains(where: { $0.contains("^1") }),
                      "the paragraph must still carry its ParamText "
                      + "template, which is what R1's second half is about")
        let derived = window.controls.filter {
            $0.semantic?.knowledge == .derived
        }
        XCTAssertGreaterThan(derived.count, 20,
                             "this scene is the point: the CDEF route "
                             + "classified it")
    }

    /// **A ParamText template is not a string anything displayed.**
    ///
    /// `^1` is filled at draw time from four strings the Dialog Manager
    /// holds; the resource keeps the template forever. Drawing it asserts
    /// a sentence nobody saw, and the only producer holding the
    /// substituted value is the machine's own run.
    ///
    /// Watched failing by mutation: dropping the `holdsParamText` clause
    /// from `displayableTitle` puts "^1K." back on the canvas whenever
    /// the machine's paragraph is absent, and this fails.
    func testAParamTextTemplateIsNotADisplayableTitle() throws {
        let scene = try memory()
        let window = try XCTUnwrap(scene.windows.first(where: \.front))
        let template = try XCTUnwrap((window.dialogItems ?? [])
            .map(\.title).first { $0.contains("^1") })
        XCTAssertNil(SceneRenderer.displayableTitle(template), """
            "\(template)" is a template. The machine substituted ^1 and \
            this host cannot, so drawing it is a confident wrong answer \
            and silencing the drawing beneath it is worse.
            """)
        XCTAssertNotNil(SceneRenderer.displayableTitle("Virtual Memory"),
                        "an ordinary label must still be displayable")
        XCTAssertNotNil(SceneRenderer.displayableTitle("Size: 100% ^ up"),
                        "a caret that is not a placeholder is just a caret")
    }

    /// **A CDEF ID NAMES A KIND AND SAYS NOTHING ABOUT CONTENTS.**
    ///
    /// Stated as a predicate as well as in pixels, because the two fixes
    /// mask each other: once the label yields to the machine's own run,
    /// a wrongly-read `semantic.value` has nowhere left to land in THIS
    /// capture, and a gate that only measures Memory's pixels would go
    /// green with R2 fully restored. The producer stopped emitting it
    /// (`scene_json.c`, 019-integration-4); this is the receiver's half,
    /// and it has to be able to fail on its own.
    ///
    /// Watched failing by mutation: dropping the `knowledge == .known`
    /// clause from `semanticText` fails the first assertion, naming "0".
    func testADerivedControlCarriesNoWords() throws {
        let window = try XCTUnwrap(try memory().windows.first(where: \.front))
        let derived = window.controls.filter {
            $0.semantic?.knowledge == .derived && $0.semantic?.value != nil
        }
        for control in derived {
            XCTAssertNil(SceneRenderer.semanticText(control.semantic), """
                a \(control.semantic?.kind ?? "?") classified by CDEF id                 came back carrying \(control.semantic?.value ?? "") as its                 WORDS. That is GetControlValue under another meaning, and                 the renderer draws it: Memory printed a 0 against the                 machine's own first glyph on every static label, and its                 disk popup printed the menu index over "Macintosh HD".
                """)
        }
        XCTAssertNotNil(SceneRenderer.semanticText(
            MirrorKit.Scene.Semantics(knowledge: .known, kind: "staticText",
                                      value: "Macintosh HD")),
            "a control that answered about ITSELF still carries its words")
    }

    /// **GROUND GOES DOWN FIRST, even when it arrives last.**
    ///
    /// Memory's root `userPane` covers the entire content rect and is the
    /// last control in the chain — the same shape as Appearance's, which
    /// erased all six tabs (integration round 4). The armed case is
    /// answered by coverage; this is the UNARMED one, where there is no
    /// ink to yield to and order is the only thing that saves the
    /// controls drawn before it.
    ///
    /// Watched failing by mutation: moving the ground pass back after the
    /// control loop makes the pane's plate bury the button and this
    /// fails.
    func testAGroundControlDoesNotBuryTheChainAboveIt() throws {
        try skipUnlessAssetPack()
        var unarmed = try memory()
        for index in unarmed.windows.indices {
            unarmed.windows[index].display = nil
        }
        let front = try XCTUnwrap(unarmed.windows.firstIndex(where: \.front))
        let pane = try XCTUnwrap(unarmed.windows[front].controls.first {
            $0.semantic?.kind == "userPane"
        })
        let paneRect = try XCTUnwrap(pane.rect)
        XCTAssertGreaterThan(paneRect.r - paneRect.l, 300,
                             "this gate needs the WHOLE-CONTENT pane; a "
                             + "small one proves nothing about burial")

        var withoutPane = unarmed
        withoutPane.windows[front].controls.removeAll {
            $0.semantic?.kind == "userPane"
        }

        // "Use Defaults", the panel's one unmistakable button, sits well
        // inside the pane.
        let button = CGRect(x: 273, y: 354, width: 98, height: 18)
        let a = try pixels(unarmed, in: button)
        let b = try pixels(withoutPane, in: button)
        XCTAssertEqual(a.count, b.count)
        XCTAssertLessThanOrEqual(differing(a, b), a.count / 100, """
            the root user pane changes \(differing(a, b)) of \(a.count) \
            pixels over a button that is not its business. A pane fills a \
            rectangle and says nothing about what is in it, so it is \
            ground: it draws BEFORE the chain above it, exactly as the \
            four background DITL kinds do. See \
            SceneRenderer.controlIsGround.
            """)
    }

    /// **A CLASSIFIED CONTROL BEATS A DIALOG ITEM THAT KNOWS NOTHING —
    /// AND ONLY THAT ONE.**
    ///
    /// A DITL row and its live `ControlRecord` share a reference because
    /// they are one object seen twice, so exactly one of them may draw.
    /// The tie used to be broken by asking the CONTROL alone for
    /// `knowledge == .known`; the CDEF route answers `derived`, so every
    /// newly classified control lost to an item carrying `kind: null`.
    /// That is why Date & Time has had no group boxes in any sweep and
    /// why the Charcoal strike could not be seen in their titles.
    ///
    /// The alert this rule was originally written for has the OPPOSITE
    /// shape — `unknown` controls beside `known pushButton` items — and
    /// must keep working, so it is asserted here beside its counterpart
    /// rather than trusted to a comment.
    ///
    /// Watched failing by mutation: `semanticOutranks` reduced to
    /// `semanticSupersedesResource` fails the first half; letting a
    /// derived control win unconditionally fails the second.
    func testADerivedControlOutranksAnItemWithNoKindAndNothingElse() throws {
        let memoryWindow = try XCTUnwrap(
            try memory().windows.first(where: \.front))
        let items: [String: MirrorKit.Scene.DialogItem] =
            (memoryWindow.dialogItems ?? []).reduce(into: [:]) {
                if let ref = $1.ref { $0[ref] = $1 }
            }
        let classified = memoryWindow.controls.filter {
            $0.semantic?.knowledge == .derived && $0.semantic?.kind != nil
                && items[$0.ref] != nil
        }
        XCTAssertGreaterThan(classified.count, 10,
                             "this fixture is the point: classified "
                             + "controls sharing a ref with a DITL row")
        var outranked = 0, yielded = 0
        for control in classified {
            let item = items[control.ref]
            /* AND THE CONVERSE, IN THE SAME PANEL. Where the item DOES
               carry a kind — "Disk Cache" is a `staticText` row with a
               real title beside a titleless derived control — the item
               knows more and keeps the rectangle. Asserted here so
               "derived always wins" is a failing mutation rather than
               an untested direction. */
            if item?.semantic.kind != nil {
                yielded += 1
                XCTAssertFalse(
                    SceneRenderer.semanticOutranks(control, item), """
                    the dialog item at \(control.ref) carries                     \(item?.semantic.kind ?? "?") and the control sharing                     its reference is one remove weaker, yet the control                     took the rectangle.
                    """)
                continue
            }
            outranked += 1
            XCTAssertTrue(
                SceneRenderer.semanticOutranks(control, item), """
                the \(control.semantic?.kind ?? "?") at \(control.ref) is                 classified and the dialog item sharing its reference                 carries no kind at all, yet the item is the one that                 draws. That suppression is why Date & Time has had no                 group boxes.
                """)
        }
        XCTAssertGreaterThan(outranked, 5, "the 3b population")
        XCTAssertGreaterThan(yielded, 0, "and its counterweight")

        // The case the old blunt rule existed for, asserted rather than
        // assumed: Internet Explorer's alert, where the ITEM knows more.
        let alertURL = try XCTUnwrap(Bundle.module.url(
            forResource: "scene-ie-error-alert", withExtension: "json",
            subdirectory: "Fixtures"))
        let alert = try NOWMirrorSceneDecoder.decode(
            irVersion: 2, document: Data(contentsOf: alertURL))
        let error = try XCTUnwrap(alert.windows.first { $0.title == "Error" })
        let alertItems: [String: MirrorKit.Scene.DialogItem] =
            (error.dialogItems ?? []).reduce(into: [:]) {
                if let ref = $1.ref { $0[ref] = $1 }
            }
        var checked = 0
        for control in error.controls where alertItems[control.ref] != nil {
            checked += 1
            XCTAssertFalse(
                SceneRenderer.semanticOutranks(control,
                                               alertItems[control.ref]), """
                the alert's \(control.ref) is an UNKNOWN control beside a                 known pushButton item, and the item must keep the                 rectangle. Letting the control win here is what the old                 rule was guarding against.
                """)
        }
        XCTAssertEqual(checked, 3, "the alert's three buttons")
    }

    /// **AND THE DIALOG-ITEM PLANE'S BUTTON BRANCH ASKS THE SAME
    /// QUESTION.** (`claude/019-integration-5`, 2026-08-07.)
    ///
    /// `019-sweepb-regressions` taught `drawControl` to consult
    /// `Coverage` and left the identical hole standing in its twin: every
    /// other branch of `drawDialogItem` has yielded to the replay since
    /// 2026-08-06, and `pushButton` alone drew unconditionally. A filled
    /// Platinum pill REPLACES its rectangle, so a DITL row classified
    /// `pushButton` over ink the machine already laid down is rung 2
    /// painting over rung 1 — the defect the whole ladder exists to stop,
    /// surviving one plane over because nobody asked there.
    ///
    /// The measurement is the real capture against itself with ONE
    /// classification changed: "Virtual Memory" is a `staticText` row
    /// whose words the machine demonstrably drew (the R1/R2 gate above
    /// measures that same rectangle), promoted to `pushButton` and
    /// nothing else touched. The correct render is identical either way,
    /// because both branches yield. No scene is constructed here — the
    /// coverage side is sweep B's own drain.
    ///
    /// Watched failing by mutation: deleting the `guard !words(frame)`
    /// from `drawDialogItem`'s `pushButton` branch puts the pill back and
    /// this fails.
    func testADialogItemButtonDoesNotPaintOverTheMachinesOwnInk() throws {
        try skipUnlessAssetPack()
        let plain = try memory()
        var promoted = plain
        let front = try XCTUnwrap(promoted.windows.firstIndex(where: \.front))
        let row = try XCTUnwrap((promoted.windows[front].dialogItems ?? [])
            .firstIndex { $0.title == "Virtual Memory" })
        XCTAssertEqual(
            promoted.windows[front].dialogItems?[row].semantic.kind,
            "staticText",
            "the row this promotes must start as the label the machine drew")
        promoted.windows[front].dialogItems?[row].semantic.kind = "pushButton"

        let box = try XCTUnwrap(Self.labels.first { $0.0 == "Virtual Memory" })
                      .1
        let a = try pixels(plain, in: box)
        let b = try pixels(promoted, in: box)
        XCTAssertEqual(a.count, b.count)
        XCTAssertLessThanOrEqual(differing(a, b), a.count / 200, """
            classifying one DITL row `pushButton` changed \(differing(a, b)) \
            of \(a.count) pixels over a rectangle the machine had already \
            drawn. A button fills its rectangle, so that branch must yield \
            to the replay exactly as every other branch here does — and as \
            drawControl's own pushButton branch does since sweep B. This \
            is also the shape the radio-CDEF misclassification arrives in: \
            OS 9 hands a radio back in the button family, and a pill over \
            the machine's own radio is a confident wrong answer.
            """)
    }
}
