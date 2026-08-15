import XCTest
@testable import MirrorKit
@testable import MirrorKitUI

/// **Who said what the desktop is — and the cases where nobody may.**
///
/// The guest has been able to answer this since slice 9 (`GetTheme` with
/// the Mac OS 9 desktop tags, served as the `desktop` command) and nothing
/// on this side ever read it. The renderer filled the largest rectangle in
/// the picture from the offline asset pack's `manifest.json`: a record of
/// the disk image the pack was extracted from, correct for a guest booted
/// from that image and unchanged since, and byte-identical to the truth
/// whether that still held or not.
///
/// `DesktopPattern.resolve(scene:screen:)` is the seam. These tests pin the
/// half of its behaviour that does NOT depend on which pack is installed on
/// the machine running them — deliberately, because a gate whose verdict
/// moves with a runtime dependency is not a gate. Every claim below holds
/// with a full pack, an empty pack, or no pack at all.
@MainActor
final class DesktopProvenanceTests: XCTestCase {

    private func scene(_ desktop: Scene.Desktop?) -> Scene {
        Scene(version: 2, seq: 1, source: "mock", capturedAt: 0,
              screen: .init(w: 800, h: 600), apps: [], processes: nil,
              menubar: nil, windows: [], desktopItems: nil,
              meta: .init(errors: [], desktop: desktop))
    }

    private let screen = CGSize(width: 800, height: 600)

    // MARK: - The one that matters

    /// **A measured "I do not know" is never converted back into a
    /// picture.** `source: unknown` means the machine WAS asked and would
    /// not say. Consulting the pack there would take the most expensive
    /// thing the guest can tell us — a positive refusal — and launder it
    /// into a confident answer, which is the exact substitution this whole
    /// seam exists to stop.
    ///
    /// Watched failing by mutation 2026-08-07: routing the `"unknown"` case
    /// to `answer(screen:)` like the nil case makes this draw the pack's
    /// picture and report `.assetPack`; both assertions name it.
    func testAskedAndRefusedIsNeverFilledFromThePack() {
        let r = DesktopPattern.resolve(
            scene: scene(.init(source: "unknown", hasPattern: false,
                               hasPicture: false)),
            screen: screen)
        XCTAssertEqual(r.provenance, .none,
                       "a refusal is not a licence for a fallback")
        guard case .unknown = r.answer else {
            return XCTFail("a refused ask must render as the marked unknown, "
                           + "got \(r.answer)")
        }
    }

    /// **A named pattern the pack does not hold is unknown, not a different
    /// pattern.** The machine is on record naming this one; drawing another
    /// would be a confident wrong answer with the producer contradicting it
    /// in the same document.
    func testANamedPatternThePackLacksIsUnknownRatherThanSubstituted() {
        let name = "A Pattern No Pack Has 8e1f2c"
        let r = DesktopPattern.resolve(
            scene: scene(.init(source: "pattern", hasPattern: true,
                               hasPicture: false, patternBytes: 32,
                               patternName: name)),
            screen: screen)
        XCTAssertEqual(r.provenance, .none)
        guard case .unknown(let why) = r.answer else {
            return XCTFail("expected the marked unknown, got \(r.answer)")
        }
        XCTAssertTrue(why.contains(name),
                      "the unknown must name the pattern the machine chose, "
                      + "so a reader can tell a missing asset from a missing "
                      + "answer; got \(why)")
    }

    /// **`machine` is a claim about the guest, so a silent guest can never
    /// produce it.** With no `meta.desktop` the pack may stand in — that is
    /// the one state where it may — but it stands in under its own name.
    func testASilentGuestNeverYieldsMachineProvenance() {
        let r = DesktopPattern.resolve(scene: scene(nil), screen: screen)
        XCTAssertNotEqual(r.provenance, .machine,
                          "nothing said this desktop came from the machine")
        XCTAssertTrue(r.provenance == .assetPack || r.provenance == .none)
        XCTAssertFalse(r.why.isEmpty, "a substitution must be able to say so")
    }

    /// A source word this renderer has never heard of is an unknown, not a
    /// default. The IR is accretive and a newer guest may say something
    /// this build cannot interpret; guessing would be worse than saying so.
    func testAnUnrecognisedSourceIsUnknownRatherThanADefault() {
        let r = DesktopPattern.resolve(
            scene: scene(.init(source: "hologram", hasPattern: true,
                               hasPicture: false)),
            screen: screen)
        XCTAssertEqual(r.provenance, .none)
        guard case .unknown = r.answer else {
            return XCTFail("expected the marked unknown, got \(r.answer)")
        }
    }

    /// **A disagreement is not resolved in the pack's favour.** When the
    /// machine names one picture and the pack holds another, the honest
    /// answer is that we do not know what is on that screen — a pack this
    /// stale about the desktop is not evidence about anything.
    func testTwoDifferentPictureNamesRenderUnknown() {
        let r = DesktopPattern.resolve(
            scene: scene(.init(source: "picture", hasPattern: true,
                               hasPicture: true,
                               pictureName: "Not The Packs Picture 4d7a")),
            screen: screen)
        /* Only assertable when the pack actually names a picture to
           disagree WITH; with no pack the kind test upstream answers first
           and this case is unreachable. Both outcomes are `.none`, which is
           what is being pinned. */
        XCTAssertEqual(r.provenance, .none)
    }

    /// The OS 8.6 pack proves its default tile against native framebuffer
    /// pixels and records the file explicitly. A live guest naming that same
    /// pattern must therefore promote the render from pack fallback to
    /// machine provenance. This also protects the name→sanitized-filename
    /// manifest join (`Mac OS Default` is stored as `desktop.png`).
    func testAProvenDefaultPatternNamedByTheGuestIsMachineProvenance() throws {
        try skipUnlessAssetPack()
        let root = try XCTUnwrap(AssetPack.root,
                                 "no asset pack; profile acceptance not armed")
        let data = try Data(contentsOf: root.appendingPathComponent(
            "manifest.json"))
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let desktop = try XCTUnwrap(manifest["desktop"] as? [String: Any])
        try XCTSkipUnless(desktop["kind"] as? String == "pattern",
                          "selected pack does not declare a pattern desktop")
        let name = try XCTUnwrap(desktop["name"] as? String)

        let r = DesktopPattern.resolve(
            scene: scene(.init(source: "pattern", hasPattern: true,
                               hasPicture: false, patternName: name)),
            screen: screen)
        XCTAssertEqual(r.provenance, .machine)
        guard case .pattern = r.answer else {
            return XCTFail("proved and named pattern did not resolve: \(r.answer)")
        }
    }

    // MARK: - The wire half

    /// The guest omits `meta.desktop` when it never asked, and that has to
    /// survive decoding as nil rather than as a default-constructed answer.
    func testAnAbsentDesktopDecodesAsNotAsked() throws {
        let json = #"""
        {"version":2,"seq":1,"source":"peek","capturedAt":0,
         "screen":{"w":800,"h":600},"apps":[],"windows":[],
         "meta":{"errors":[]}}
        """#
        let s = try JSONDecoder().decode(Scene.self,
                                         from: Data(json.utf8))
        XCTAssertNil(s.meta.desktop)
    }

    /// And the guest's own shape decodes into the typed answer, including
    /// the keys it omits when a tag was absent.
    func testTheGuestsDesktopShapeDecodes() throws {
        let json = #"""
        {"version":2,"seq":1,"source":"peek","capturedAt":0,
         "screen":{"w":800,"h":600},"apps":[],"windows":[],
         "meta":{"errors":[],"desktop":{"source":"pattern",
           "hasPattern":true,"hasPicture":false,"patternBytes":0,
           "patternName":"Bubbles"}}}
        """#
        let s = try JSONDecoder().decode(Scene.self, from: Data(json.utf8))
        let d = try XCTUnwrap(s.meta.desktop)
        XCTAssertEqual(d.source, "pattern")
        XCTAssertTrue(d.hasPattern)
        XCTAssertFalse(d.hasPicture)
        /* Zero is a MEASURED length and must survive as one; nil would say
           the guest could not read the pattern at all. */
        XCTAssertEqual(d.patternBytes, 0)
        XCTAssertEqual(d.patternName, "Bubbles")
        /* An absent tag, not a nameless picture. */
        XCTAssertNil(d.pictureName)
    }
}
