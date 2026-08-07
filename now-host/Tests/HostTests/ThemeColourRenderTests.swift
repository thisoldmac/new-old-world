import XCTest
import AppKit
import SwiftUI
import MirrorKit
import MirrorKitUI
@testable import Host

/// **The face is the one the guest reported, not the one we wrote down.**
///
/// `PanelFaceRenderTests` pinned that a Dialog Manager window renders in
/// the dialog grey rather than white, against a constant counted off a
/// screendump. That constant is right for the shipped Platinum theme and
/// silently wrong for any other — the same defect as tiling a factory
/// `ppat` in place of the real desktop, and worse in a colour, because
/// nothing ever looks broken.
///
/// So these tests do the one thing a fidelity score cannot: they render
/// scenes whose declared theme is NOT Platinum and check the pixels moved.
/// A renderer still reaching for its own constant passes every similarity
/// comparison in this repository and fails every assertion below.
///
/// The colours are deliberately absurd (a saturated blue face). A theme
/// that differed from Platinum by a few greys would let a test pass on a
/// rounding accident.
@MainActor
final class ThemeColourRenderTests: XCTestCase {

    /// Built the same way `Color(hex:)` builds one, so the comparison is
    /// against the value the resolver would actually produce.
    static let black = Color(red: 0, green: 0, blue: 0)

    private func scene() throws -> MirrorKit.Scene {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "now-scene-019-date-and-time",
            withExtension: "json", subdirectory: "Fixtures"))
        return try NOWMirrorSceneDecoder.decode(
            irVersion: 2, document: Data(contentsOf: url))
    }

    /// The dominant 8-bit RGB triple of the front window's interior, and
    /// how many of the sampled pixels it is. Same sampling as
    /// `PanelFaceRenderTests` — the stored bytes, not `colorAt`, which
    /// re-converts through a colour space and reads 0xDD back as 228.
    private func dominantInterior(_ scene: MirrorKit.Scene) throws
        -> (String, Int, Int) {
        let win = try XCTUnwrap(scene.windows.first(where: \.front))
        let box = CGRect(x: CGFloat(win.rect.l) + 8,
                         y: CGFloat(win.rect.t) + 30,
                         width: CGFloat(win.rect.r - win.rect.l) - 16,
                         height: CGFloat(win.rect.b - win.rect.t) - 40)
        let png = try RenderShot.png(scene: scene)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
        let bytes = try XCTUnwrap(rep.bitmapData)
        let stride = rep.bytesPerRow
        let sample = rep.bitsPerPixel / 8
        var counts: [String: Int] = [:]
        var total = 0
        for y in Int(box.minY)..<Int(box.maxY) {
            for x in Int(box.minX)..<Int(box.maxX) {
                let o = y * stride + x * sample
                counts["\(bytes[o]),\(bytes[o + 1]),\(bytes[o + 2])",
                       default: 0] += 1
                total += 1
            }
        }
        let (top, n) = try XCTUnwrap(counts.max { $0.value < $1.value })
        return (top, n, total)
    }

    // MARK: - the render follows the wire

    /// **A theme that is not Platinum moves the pixels.**
    ///
    /// The mutation this exists to catch is the whole arc's signature: go
    /// back to `Platinum.dialogFace` at the decision point and the panel
    /// renders 221,221,221 against a guest that said 0x336699. Watched
    /// failing 2026-08-07.
    func testTheDialogFaceComesFromTheGuestsOwnBrush() throws {
        var scene = try scene()
        XCTAssertEqual(scene.windows.first(where: \.front)?.kind, 2,
                       "this fixture is only interesting because the guest "
                       + "reported windowKind 2 for it")
        scene.meta.theme = .init(dialogBackground: "#336699", depth: 32)

        let (top, n, total) = try dominantInterior(scene)
        XCTAssertEqual(top, "51,102,153", """
            the guest said its dialog brush is #336699 and the panel \
            rendered \(top) (\(n) of \(total) px). A renderer that still \
            reaches for Platinum.dialogFace passes every similarity score \
            in this repository and is wrong on any machine not running the \
            shipped theme.
            """)
    }

    /// **An application-defined panel is a document face, and now a theme
    /// can move it.**
    ///
    /// windowKind 2000 kept literal white no matter what, because the face
    /// was a two-way branch on `kind == 2` between two constants. The
    /// Appearance control panel is exactly that kind.
    func testAnApplicationDefinedPanelTakesTheDocumentBrush() throws {
        var scene = try scene()
        let index = try XCTUnwrap(scene.windows.firstIndex(where: \.front))
        scene.windows[index].kind = 2000
        scene.meta.theme = .init(dialogBackground: "#336699",
                                 documentBackground: "#996633", depth: 32)

        let (top, n, total) = try dominantInterior(scene)
        XCTAssertEqual(top, "153,102,51", """
            a kind-2000 window rendered \(top) (\(n) of \(total) px). It \
            must take the DOCUMENT brush - not the dialog brush, and not \
            the hardcoded white it took before meta.theme existed.
            """)
    }

    // MARK: - what absence means, in both of its forms

    /// **No `meta.theme` at all: this producer did not ask.** The Platinum
    /// constants stand in, and the resolver says they did.
    func testASceneWithNoThemeFallsBackAndSaysSo() throws {
        var scene = try scene()
        scene.meta.theme = nil
        let theme = SceneTheme(scene)

        XCTAssertEqual(theme.dialogFace, Platinum.dialogFace)
        XCTAssertEqual(theme.documentFace, Platinum.documentFace)
        XCTAssertEqual(theme.provenance["dialogBackground"], .fallback)
        XCTAssertNil(theme.depth)

        let (top, _, _) = try dominantInterior(scene)
        XCTAssertEqual(top, "221,221,221",
                       "an old scene must render exactly as it did before "
                       + "the field existed")
    }

    /// **A present `theme` with an absent key: the machine was asked and
    /// refused.** Different fact, same fallback colour — and the
    /// provenance is what keeps them apart. It must never come out black:
    /// 0x000000 is a legal colour and so is the one value that cannot
    /// double as "unknown".
    func testARefusedBrushIsAFallbackAndNeverBlack() throws {
        let theme = SceneTheme(MirrorKit.Scene.Theme(highlight: "#CCCCFF",
                                                     depth: 8))
        XCTAssertEqual(theme.dialogFace, Platinum.dialogFace)
        XCTAssertNotEqual(theme.dialogFace, ThemeColourRenderTests.black)
        XCTAssertEqual(theme.provenance["dialogBackground"], .fallback)
        XCTAssertEqual(theme.provenance["highlight"], .machine)
        XCTAssertEqual(theme.depth, 8,
                       "the depth the brushes were asked at rides along, or "
                       + "no colour here can be checked against a capture")
    }

    /// **Black is a colour and must survive the round trip.** If the
    /// resolver treated 0x000000 as falsy then "the machine said black"
    /// and "nobody asked" would collapse into one state, which is the
    /// defect this whole field removes.
    func testBlackIsAnAnswerNotAnAbsence() throws {
        let theme = SceneTheme(
            MirrorKit.Scene.Theme(dialogBackground: "#000000"))
        XCTAssertEqual(theme.dialogFace, ThemeColourRenderTests.black)
        XCTAssertEqual(theme.provenance["dialogBackground"], .machine)
    }

    /// **A malformed value is refused, not coerced.** A half-parsed colour
    /// is the one outcome worse than a fallback, because it would be
    /// published as `machine`.
    func testAMalformedColourIsRefusedRatherThanSalvaged() throws {
        for bad in ["#GGGGGG", "#FFF", "336699ff", "", "#33669"] {
            let theme = SceneTheme(
                MirrorKit.Scene.Theme(dialogBackground: bad))
            XCTAssertEqual(theme.dialogFace, Platinum.dialogFace,
                           "\(bad) must not become a colour")
            XCTAssertEqual(theme.provenance["dialogBackground"], .fallback,
                           "\(bad) must not be published as machine-sourced")
        }
        // ...and the well-formed neighbour of every one of those parses,
        // so the test is not passing because the parser rejects everything.
        XCTAssertEqual(SceneTheme(
            MirrorKit.Scene.Theme(dialogBackground: "#336699"))
                .provenance["dialogBackground"], .machine)
    }

    // MARK: - the wire

    /// The decoder carries the key end to end. A field the guest emits and
    /// this side has never heard of is this project's most expensive defect
    /// class (`two-halves-never-met-in-a-test`), so the assertion is made
    /// against a document rather than against a constructed struct.
    func testTheDecoderCarriesMetaTheme() throws {
        let doc = """
            {"version":2,"seq":1,"capturedAt":0.0,"source":"peek",
             "screen":{"w":640,"h":480},"apps":[],"processes":[],
             "windows":[],
             "meta":{"errors":[],"theme":{"dialogBackground":"#DDDDDD",
             "alertBackground":"#EEEEEE","documentBackground":"#FFFFFF",
             "highlight":"#CCCCFF","depth":32}}}
            """
        let scene = try NOWMirrorSceneDecoder.decode(
            irVersion: 2, document: Data(doc.utf8))
        let theme = try XCTUnwrap(scene.meta.theme)
        XCTAssertEqual(theme.dialogBackground, "#DDDDDD")
        XCTAssertEqual(theme.alertBackground, "#EEEEEE")
        XCTAssertEqual(theme.documentBackground, "#FFFFFF")
        XCTAssertEqual(theme.highlight, "#CCCCFF")
        XCTAssertEqual(theme.depth, 32)

        let resolved = SceneTheme(scene)
        XCTAssertEqual(resolved.provenance.values.filter { $0 == .machine }
                        .count, 4)
    }
}
