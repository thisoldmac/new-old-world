import XCTest
import MirrorKit
@testable import MirrorKitUI

/// **The substitution must be answerable, and the answer must be the
/// renderer's own.**
///
/// Substituting Chicago for the guest's Charcoal is an accepted product
/// decision (Michelle, 2026-08-07). Doing it silently is not, and the
/// silence has already been paid for: group-box frames appeared to cross
/// their own labels, three people read it as a chrome defect, and it was
/// Chicago overrunning a band the machine had sized for a narrower face.
///
/// Every claim here is about the DECLARATION, not about the pixels — the
/// pixels are unchanged by this work and `RendererTextFidelityTests`
/// already owns them. What is asserted is that a reader can tell whose
/// glyphs and whose width they are looking at, and that the thing
/// telling them is derived from the renderer's own mapping rather than
/// from a second copy of it.
@MainActor
final class FontSubstitutionTests: XCTestCase {

    // MARK: - The mapping is stated once

    /// The load-bearing claim of the whole file. `DisplayReplay.strike`
    /// draws the pixels; `StrikeChoice` describes them. If those two
    /// carried separate switches the report would eventually describe a
    /// render nobody is looking at — which is this repository's most
    /// expensive recurring defect, and the reason the family preference
    /// list is a single function both go through.
    func testTheReportAndTheRendererAgreeOnEveryFontIDTheCorpusUses() {
        // 0 and 1 are roles, 3 is Geneva by number, 2002 is the
        // dynamically-assigned id the menu bar clock draws in, and 4 is
        // an ordinary family the pack does not carry.
        for id in [0, 1, 2, 3, 4, 2002] {
            for size in [0, 9, 10, 12, 14, 37] {
                let choice = StrikeChoice.choice(font: id, size: size)
                let drawn = DisplayReplay.strike(font: id, size: size)
                guard let drawn else {
                    XCTAssertNil(choice.servedSize,
                                 "the report named a strike for \(id)/\(size) "
                                 + "that the renderer could not find")
                    XCTAssertEqual(choice.fidelity, .unavailable)
                    continue
                }
                XCTAssertEqual(drawn.face.lowercased(),
                               choice.servedFamily.lowercased(),
                               "report and renderer disagree on the FACE "
                               + "for font \(id) at \(size)")
                XCTAssertEqual(drawn.pointSize, choice.servedSize,
                               "report and renderer disagree on the SIZE "
                               + "for font \(id) at \(size)")
            }
        }
    }

    /// `txSize` 0 is the port default of 12, not a zero-height strike —
    /// stated in both places and therefore worth pinning in one.
    func testASizeOfZeroIsTheTwelvePointPortDefault() {
        XCTAssertEqual(StrikeChoice.choice(font: 0, size: 0).requestedSize, 12)
        XCTAssertEqual(StrikeChoice.choice(font: 0, size: 12).requestedSize, 12)
    }

    /// The system font's preference order IS the substitution: Charcoal
    /// first because that is what the machine draws, Chicago behind it
    /// because that is what we fall back to. A change to either end of
    /// that list changes what the banner and the report mean.
    func testTheSystemFontPrefersCharcoalAndFallsBackToChicago() {
        XCTAssertEqual(StrikeChoice.preferredFamilies(forID: 0),
                       ["charcoal", "chicago"])
        for id in [1, 2, 3, 4, 2002] {
            XCTAssertEqual(StrikeChoice.preferredFamilies(forID: id),
                           ["geneva"], "font \(id)")
        }
    }

    // MARK: - The ladder

    /// A substituted run is NOT an unknown one, and the difference is
    /// the whole reason it has its own state: we can name both sides.
    func testASubstitutionNamesBothSidesRatherThanSayingUnknown() {
        let choice = StrikeChoice(
            requested: .systemFont, requestedSize: 12,
            intendedFamily: "charcoal", servedFamily: "chicago",
            servedSize: 12)
        XCTAssertEqual(choice.fidelity, .substituted)
        XCTAssertTrue(choice.described.contains("Charcoal"),
                      "a substitution must name what was ASKED for")
        XCTAssertTrue(choice.described.contains("chicago"),
                      "a substitution must name what was SERVED")
        XCTAssertTrue(choice.described.contains("SUBSTITUTED"))
    }

    /// Only the exact rung leaves the width to the machine. Every other
    /// state means a clipped run may lose its tail here and not there,
    /// which is the question a person looking at a truncated label asks.
    func testOnlyAnExactStrikeLeavesTheWidthToTheMachine() {
        XCTAssertFalse(StrikeFidelity.exact.widthIsOurs)
        for state in StrikeFidelity.allCases where state != .exact {
            XCTAssertTrue(state.widthIsOurs, "\(state.rawValue)")
        }
    }

    func testRightFaceWrongSizeIsResizedRatherThanSubstituted() {
        let rounded = StrikeChoice(
            requested: .geneva, requestedSize: 11,
            intendedFamily: "geneva", servedFamily: "geneva", servedSize: 10)
        XCTAssertEqual(rounded.fidelity, .resized)
        XCTAssertTrue(rounded.described.contains("width is ours"))

        let exact = StrikeChoice(
            requested: .geneva, requestedSize: 10,
            intendedFamily: "geneva", servedFamily: "geneva", servedSize: 10)
        XCTAssertEqual(exact.fidelity, .exact)
    }

    /// An id whose face this side cannot name is still a face we did not
    /// draw. Geneva answering for font 2002 is a substitution even
    /// though the report cannot say what 2002 is — and it must not
    /// pretend to, because ids at that magnitude are handed out by the
    /// Font Manager at run time and are not stable across machines.
    func testAnUnnameableFamilyIsASubstitutionAndIsNotGivenAName() {
        let choice = StrikeChoice(
            requested: .family(2002), requestedSize: 12,
            intendedFamily: "geneva", servedFamily: "geneva", servedSize: 12)
        XCTAssertEqual(choice.fidelity, .substituted)
        XCTAssertNil(RequestedFace.family(2002).faceName)
        XCTAssertTrue(choice.described.contains("2002"),
                      "the id is all this side may honestly say")
        XCTAssertFalse(choice.described.contains("Charcoal"),
                       "2002 is almost certainly Charcoal and that is "
                       + "exactly why it must not be written down as one")
    }

    /// No strike at all is the one state where the width is not merely
    /// ours but unmeasured — the caller falls through to a SwiftUI font
    /// nothing here has metrics for.
    func testNoStrikeAtAllSaysTheWidthIsNotEvenMeasured() {
        let none = StrikeChoice(
            requested: .systemFont, requestedSize: 12,
            intendedFamily: "charcoal", servedFamily: "charcoal",
            servedSize: nil)
        XCTAssertEqual(none.fidelity, .unavailable)
        XCTAssertTrue(none.described.contains("no bundled strike"))
    }

    // MARK: - The rounding rule is asked, never re-implemented

    /// `FontBook.nearestSize` exists so the report can say what a run
    /// will be drawn at without loading a strike. It is only worth
    /// having if it agrees with `nearest`, which is what actually picks.
    func testTheSizeTheReportNamesIsTheSizeTheRendererLoads() {
        for face in ["chicago", "geneva", "charcoal"] {
            for size in [1, 9, 10, 11, 12, 13, 24, 96] {
                let named = FontBook.nearestSize(face: face, size: size)
                let loaded = FontBook.nearest(face: face, size: size)
                XCTAssertEqual(named, loaded?.pointSize,
                               "\(face) at \(size)")
            }
        }
    }

    /// A face nothing carries has no nearest size. The report says
    /// `unavailable` rather than naming a strike that is not there.
    func testAFaceTheBundleDoesNotCarryHasNoNearestSize() {
        XCTAssertNil(FontBook.nearestSize(face: "no-such-face", size: 12))
    }

    // MARK: - The banner

    /// **Derived, never remembered.** The banner fires exactly when the
    /// system font would actually be drawn in something other than the
    /// system face on this desk — so it says nothing on a desk whose
    /// pack rasterises Charcoal, says so on one whose pack predates
    /// that, and needs no edit either way. A hard-coded "we substitute
    /// Chicago" would have shipped false: the Charcoal work landed the
    /// day before this was written.
    func testTheBannerAgreesWithWhatTheSystemFontIsActuallyDrawnIn() {
        let systemFont = StrikeChoice.choice(font: 0, size: 12)
        switch systemFont.fidelity {
        case .substituted:
            let banner = try? XCTUnwrap(FontSubstitution.bannerText)
            XCTAssertNotNil(banner, "the substitution is live and silent")
            XCTAssertTrue(banner?.contains(
                FontSubstitution.systemFaceName) ?? false,
                "the banner must name the face the machine uses")
            XCTAssertTrue(banner?.contains(
                systemFont.servedFamily.capitalized) ?? false,
                "the banner must name the face WE use")
        case .exact, .resized, .unavailable:
            XCTAssertNil(FontSubstitution.bannerText,
                         "the banner claims a substitution that is not "
                         + "happening on this desk (\(systemFont.described))")
        }
    }

    /// The banner is a legend ABOUT the picture, never in it. A render
    /// screenshot has to stay pixel-comparable across desks, and a
    /// legend painted into it would be the mirror talking about itself
    /// inside a picture of the machine.
    func testTheDeclarationIsNotPaintedIntoTheRender() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MirrorKitUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // MirrorKit
            .appendingPathComponent("Sources/MirrorKitUI")
        for file in ["SceneView.swift", "SceneRenderer.swift",
                     "DisplayReplay.swift"] {
            let text = try String(contentsOf:
                sources.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(text.contains("FontSubstitution.bannerText"),
                           "\(file) draws the render; the banner belongs "
                           + "beside it, not in it")
        }
        let live = try String(contentsOf:
            sources.appendingPathComponent("LiveMirror.swift"),
            encoding: .utf8)
        XCTAssertTrue(live.contains("FontSubstitution.bannerText"),
                      "nothing shows the declaration to a person")
    }

    // MARK: - The report

    private func textOp(_ s: String, font: Int, size: Int) -> DisplayOp {
        var op = DisplayOp(op: "text", ticks: 0)
        op.text = s
        op.font = font
        op.size = size
        op.pen = [0, 0]
        return op
    }

    /// The tally counts RUNS, not distinct faces. 251 of 266 runs in one
    /// state is a different fact from one of 266, and the proportion is
    /// the half that says whether a window is mostly ours.
    func testTheTallyCountsEveryRunAndTheListCountsEachFaceOnce() {
        let ops = [textOp("a", font: 3, size: 10),
                   textOp("b", font: 3, size: 10),
                   textOp("c", font: 0, size: 12),
                   { var o = DisplayOp(op: "rect", ticks: 0)
                     o.rect = [0, 0, 4, 4]; return o }()]
        let tally = FontSubstitution.tally(in: ops)
        XCTAssertEqual(tally.values.reduce(0, +), 3,
                       "only text runs are counted, and every one of them")
        XCTAssertEqual(FontSubstitution.choices(in: ops).count, 2,
                       "two distinct face+size requests")
    }

    /// An empty declaration for a window with no words in it. A report
    /// that says "0 substitutions" for every wordless window is noise
    /// that hides the windows with some.
    func testAWindowThatDrewNoTextDeclaresNothing() {
        var rect = DisplayOp(op: "rect", ticks: 0)
        rect.rect = [0, 0, 10, 10]
        XCTAssertEqual(FontSubstitution.report(for: [rect]), "")
        XCTAssertEqual(
            FontSubstitution.report(for: [textOp("", font: 0, size: 12)]), "",
            "an empty run is not a run; the renderer skips it too")
    }

    /// The report is stable across runs. A report that reorders itself
    /// cannot be diffed, and a report nobody can diff is one nobody
    /// checks — which is how a derived table goes stale unnoticed.
    func testTheReportIsOrderedAndSoCanBeDiffed() {
        let a = [textOp("x", font: 0, size: 12),
                 textOp("y", font: 3, size: 9),
                 textOp("z", font: 1, size: 10)]
        let b: [DisplayOp] = a.reversed()
        XCTAssertEqual(FontSubstitution.report(for: a),
                       FontSubstitution.report(for: b))
        XCTAssertTrue(FontSubstitution.report(for: a)
                        .contains("laid out at a width this host chose"))
    }

    /// The count of runs whose width this host chose is the number a
    /// person reading a render actually needs — and it must follow the
    /// ladder rather than being counted separately.
    func testTheReportCountsTheRunsWhoseWidthIsOurs() {
        let ops = [textOp("x", font: 2002, size: 12),
                   textOp("y", font: 3, size: 10)]
        let tally = FontSubstitution.tally(in: ops)
        let ours = tally.filter { $0.key.widthIsOurs }.values.reduce(0, +)
        let report = FontSubstitution.report(for: ops)
        XCTAssertTrue(report.contains("2 text run(s); \(ours) laid out"),
                      report)
    }
}
