import XCTest
import SwiftUI
import MirrorKit
@testable import MirrorKitUI

/// The renderer-side text defects the 2026-08-06 fidelity sweep measured,
/// each gated over the SAME committed capture that exhibits it.
///
/// Every assertion here is a claim about a window somebody looked at beside
/// the machine's own pixels, and the number in it comes from those pixels
/// rather than from the renderer's own arithmetic — which is the whole
/// difference between a gate and a snapshot of current behaviour. Each was
/// watched to fail by putting the defect back.
@MainActor
final class RendererTextFidelityTests: XCTestCase {

    /// Every gate below asserts against the guest's own FONT STRIKES, so
    /// without the asset pack there is nothing to assert against and the
    /// failure would say "the renderer is broken" when it means "the
    /// dependency is absent".
    ///
    /// This mirrors `skipUnlessAssetPack()` in the MirrorKit package's own
    /// suite rather than sharing it: the two test targets do not see each
    /// other, and duplicating nine lines is cheaper than a shared test
    /// module. The contract is the same one `scripts/test-host` relies on —
    /// a visible skip when the pack is absent, and a FAILURE when
    /// `NOW_REQUIRE_ASSET_PACK` says a machine that has the pack should be
    /// biting on these.
    ///
    /// Found by merging two branches that were each green alone: the
    /// pack-absent pass and these gates were written in parallel, and only
    /// the merged tree runs one against the other.
    private func skipUnlessAssetPack() throws {
        guard !AssetPack.status.isPresent else { return }
        if AssetPack.isRequired {
            XCTFail("NOW_REQUIRE_ASSET_PACK is set and the pack is absent — "
                    + (AssetPack.bannerText ?? ""))
            return
        }
        throw XCTSkip("Platinum asset pack absent; this gate needs the "
                      + "guest's own font strikes. "
                      + (AssetPack.bannerText ?? ""))
    }

    private func ops(_ fixture: String) throws -> [[String: Any]] {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: fixture, withExtension: "json",
            subdirectory: "Fixtures"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as? [String: Any])
        return try XCTUnwrap(object["ops"] as? [[String: Any]])
    }

    private func textOps(_ fixture: String) throws -> [MirrorKit.DisplayOp] {
        try ops(fixture).compactMap(MirrorKit.DisplayOp.init(fetched:))
            .filter { $0.op == "text" }
    }

    // MARK: - R1, small system text rendered a third too large

    /// The Memory panel's body text is Geneva 9 ON THE MACHINE
    /// (`memory-guest.ppm`, the screendump taken while it was front), and
    /// 251 of its 266 text ops ask for it as font 1 — `applFont` — at size
    /// 9. The replay mapped `applFont` to the system face and threw the
    /// size away, so all 251 drew as Chicago 12.
    ///
    /// Both halves are asserted, because either alone passes the wrong fix:
    /// the right FACE at the wrong size still overruns, and the right size
    /// in the wrong face is not what the machine drew.
    func testTheMemoryPanelsBodyTextIsDrawnAsGenevaNine() throws {
        try skipUnlessAssetPack()
        let runs = try textOps("qdtrace-drain-sweep-memory")
            .filter { $0.font == 1 && $0.size == 9 }
        XCTAssertEqual(runs.count, 251,
                       "the capture stopped being the one this gate judges")
        let strike = try XCTUnwrap(DisplayReplay.strike(font: 1, size: 9))
        XCTAssertEqual(strike.face, "Geneva",
                       "applFont is Geneva on this machine, not the system face")
        XCTAssertEqual(strike.pointSize, 9,
                       "the op's own size was discarded")
    }

    /// And the consequence, measured against the guest's own arithmetic
    /// rather than the renderer's.
    ///
    /// The application clips each run to the box it laid the run out in,
    /// immediately before drawing it — so the clip rectangle IS the
    /// machine's statement of how wide that string is on that machine. A
    /// run measured wider than its own clip cannot render whole: the tail
    /// is cut mid-glyph, which is where "Check Disk" became "Check Disl"
    /// and "8/ 6/2026" became "8/ 6/202(" in the sweep's read of R6. That
    /// is the same defect as R1 seen from the other end, not a bad glyph
    /// mapping.
    ///
    /// Pen and clip are both port-local, so this needs no origin
    /// arithmetic and no rendering. 113 of the Memory panel's 251
    /// `applFont` runs overran their own clip at Chicago 12; none does at
    /// the size the op asked for.
    func testNoMemoryPanelLabelOverrunsTheClipTheGuestSetForIt() throws {
        try skipUnlessAssetPack()
        var clips: [String: [Int]] = [:]
        var overruns: [String] = []
        var measured = 0
        for op in try ops("qdtrace-drain-sweep-memory") {
            let port = (op["port"] as? String) ?? ""
            if (op["op"] as? String) == "state",
               (op["kind"] as? String) == "clip",
               let rect = op["rect"] as? [Int], rect.count == 4 {
                clips[port] = rect
            }
            guard (op["op"] as? String) == "text",
                  (op["font"] as? Int) == 1,
                  let text = op["text"] as? String,
                  !text.trimmingCharacters(in: .whitespaces).isEmpty,
                  let pen = op["pen"] as? [Int], pen.count == 2,
                  let clip = clips[port],
                  let strike = DisplayReplay.strike(
                    font: 1, size: (op["size"] as? Int) ?? 12)
            else { continue }
            measured += 1
            let right = pen[0] + strike.width(text)
            // One pixel of slack: the strike's advance includes the right
            // side bearing, and a run that ends exactly on its clip is fine.
            if right > clip[2] + 1 {
                overruns.append("\(text) ends at \(right), clipped at \(clip[2])")
            }
        }
        XCTAssertEqual(measured, 251,
                       "the capture stopped being the one this gate judges")
        XCTAssertEqual(overruns, [],
                       "runs are measured wider than the machine laid them out")
    }

    /// What the book does when the pack has no strike at the wanted size,
    /// pinned so the rounding rule cannot drift into the other direction.
    /// A tie goes SMALL: too wide overruns the control, too narrow does not.
    func testAnAbsentSizeRoundsToTheNearestBundledStrikeTiesSmall() throws {
        try skipUnlessAssetPack()
        XCTAssertEqual(FontBook.nearest(face: "geneva", size: 11)?.pointSize,
                       10, "a tie must round down")
        XCTAssertEqual(FontBook.nearest(face: "geneva", size: 13)?.pointSize,
                       12, "a tie must round down")
        XCTAssertEqual(FontBook.nearest(face: "geneva", size: 16)?.pointSize,
                       14, "16 is nearer 14 than 18 — no tie, no rounding down")
        XCTAssertEqual(FontBook.nearest(face: "geneva", size: 9)?.pointSize, 9)
        // Chicago ships one strike, so every Chicago request answers at 12.
        XCTAssertEqual(FontBook.nearest(face: "chicago", size: 9)?.pointSize,
                       12)
    }

    /// The table of bundled sizes must describe the bundle. A row that
    /// names a strike nobody shipped rounds a request onto a nil.
    func testEveryBundledSizeInTheTableIsActuallyBundled() throws {
        try skipUnlessAssetPack()
        for (face, sizes) in FontBook.bundledSizes {
            for size in sizes {
                XCTAssertNotNil(FontBook.font("\(face)-\(size)"),
                                "\(face)-\(size) is in the table, not the bundle")
            }
        }
    }

    // MARK: - R2, a declared truncation was silent at the glass

    /// The guest declares its own truncation and the host dropped the
    /// declaration on the floor. Appearance's description arrives as 64 of
    /// 69 bytes with `trunc: true`; nothing on this side read either field,
    /// so 64 characters rendered as though they were the string.
    func testADeclaredTruncationSurvivesTheDecode() throws {
        let truncated = try textOps("qdtrace-drain-sweep-appearance")
            .filter { $0.trunc == true }
        XCTAssertFalse(truncated.isEmpty,
                       "the capture that declares a truncation stopped doing so")
        let run = try XCTUnwrap(truncated.first {
            $0.text?.hasPrefix("To create a new theme") == true
        })
        XCTAssertEqual(run.len, 64)
        XCTAssertEqual(run.fullLen, 69,
                       "fullLen must reach whatever could use it")
        XCTAssertGreaterThan(try XCTUnwrap(run.fullLen),
                             try XCTUnwrap(run.len))
    }

    /// And it must be VISIBLE. The rendered run carries a mark the
    /// untruncated run does not, and the mark is one the strike can draw —
    /// an ellipsis an ASCII-only strike renders as blank space would be the
    /// same silence with more ceremony.
    func testATruncatedRunIsDrawnWithAMarkTheStrikeCanRender() throws {
        try skipUnlessAssetPack()
        let strike = try XCTUnwrap(DisplayReplay.strike(font: 3, size: 10))
        let whole = DisplayReplay.shownText("Save Theme", truncated: false,
                                            in: strike)
        let cut = DisplayReplay.shownText("Save Theme", truncated: true,
                                          in: strike)
        XCTAssertEqual(whole, "Save Theme", "an untruncated run is untouched")
        XCTAssertNotEqual(cut, whole, "the truncation is still silent")
        XCTAssertGreaterThan(strike.width(cut), strike.width(whole),
                             "the mark occupies no pixels — nobody can see it")
        for character in cut where !strike.has(character) {
            XCTFail("the truncation mark uses \(character), which this "
                    + "strike draws as blank")
        }
    }

    // MARK: - R6, MacRoman punctuation dropped silently

    /// Every character the sweep's thirteen captures actually draw must
    /// exist in the strike that would draw it.
    ///
    /// The extracted strikes carried ASCII 0x20..0x7E and nothing else,
    /// because the extractor's default range stopped at 127 — so `…` in
    /// five button titles, `•` in all five Scrapbook bullets and the
    /// apostrophe in "user's guide" all drew as blank space, the
    /// consumer's substitute for a character it has no glyph for. The
    /// glyphs were in the NFNT the whole time and were never asked for.
    ///
    /// This gate reads the CORPUS rather than a list of characters
    /// somebody thought of: a capture that starts drawing a new one fails
    /// it, which is the only version of this that keeps working.
    func testEveryCharacterTheGuestDrawsHasAGlyphToDrawItWith() throws {
        try skipUnlessAssetPack()
        let captures = [
            "appearance", "date-and-time", "memory", "sound", "sound-1pass",
            "general-controls", "finder", "finder-selected", "note-pad",
            "stickies", "scrapbook", "sherlock-2", "key-caps",
        ]
        var missing: Set<String> = []
        var seen = 0
        for capture in captures {
            for run in try textOps("qdtrace-drain-sweep-\(capture)") {
                guard let text = run.text,
                      let strike = DisplayReplay.strike(font: run.font ?? 3,
                                                        size: run.size ?? 12)
                else { continue }
                for character in text {
                    // Control characters are the guest's own layout marks
                    // (Key Caps labels its modifier keys with them, and
                    // Memory ends a wrapped line with a carriage return);
                    // no strike has ever carried a glyph for those.
                    guard !character.isASCII
                            || character.asciiValue.map({ $0 >= 0x20 }) == true
                    else { continue }
                    seen += 1
                    if !strike.has(character) {
                        missing.insert("\(strike.face) \(strike.pointSize): "
                                       + "\(character)")
                    }
                }
            }
        }
        XCTAssertGreaterThan(seen, 10_000, "the corpus stopped being read")
        XCTAssertEqual(missing.sorted(), [],
                       "these draw as blank space, silently")
    }

    /// And the strikes must carry the MacRoman range under the characters
    /// the guest's JSON decodes to — not under the Unicode characters
    /// those byte values happen to name. Keying 0xC9 as `É` rather than
    /// `…` would file every high glyph under the wrong name and produce a
    /// WRONG glyph, which is worse than a missing one.
    func testTheStrikesAreKeyedByMacRomanNotByByteValue() throws {
        try skipUnlessAssetPack()
        let strike = try XCTUnwrap(FontBook.font("geneva-10"))
        // MacRoman 0xC9 is an ellipsis and 0xA5 a bullet; the Unicode
        // characters at those code points are É and ¥, which the strike
        // also carries — at 0x83 and 0xB4 — so both must be present AND
        // different, or the table is keyed by the byte.
        XCTAssertTrue(strike.has("…"), "no ellipsis glyph")
        XCTAssertTrue(strike.has("•"), "no bullet glyph")
        XCTAssertTrue(strike.has("É"), "no É glyph")
        XCTAssertTrue(strike.has("¥"), "no ¥ glyph")
        XCTAssertNotEqual(strike.width("…"), strike.width("É"),
                          "the ellipsis and É are the same glyph — the "
                          + "table is keyed by byte value, not by MacRoman")
    }

    // MARK: - Charcoal, the system font, standing in as Chicago

    /// Font id 0 means "the system font", and on Mac OS 8.5 and later that
    /// is **Charcoal** — not Chicago, which is System 7's. The pack had no
    /// Charcoal because Charcoal ships no bitmap strike anywhere on the
    /// guest; it is rasterised from TrueType at run time by the machine and,
    /// since 2026-08-07, by the extractor too.
    func testTheSystemFontIsCharcoalAndNotChicago() throws {
        try skipUnlessAssetPack()
        let strike = try XCTUnwrap(DisplayReplay.strike(font: 0, size: 0))
        XCTAssertEqual(strike.face, "Charcoal",
                       "font 0 is the system font, and Chicago is System 7's")
        XCTAssertEqual(strike.pointSize, 12,
                       "txSize 0 is the port default, which QuickDraw "
                       + "resolves to 12 — not a zero-height strike")
        XCTAssertEqual(FontBook.system?.face, "Charcoal",
                       "the host draws its own menus and titles in the "
                       + "system font too")
    }

    /// **The guest's own numbers, string by string.**
    ///
    /// Before it draws a group-box title the CDEF erases a band out of the
    /// frame it has just drawn and clips to it — so the band's width IS
    /// that machine's statement of how wide that string is in that face at
    /// that size. Nine such bands sit in the committed captures, and they
    /// are the only oracle this needs: no VM, no screendump, no judgement.
    ///
    /// Chicago overran every one of them, by +1 to +7 px, monotonically
    /// with length — a per-glyph advance difference, which is what a face
    /// substitution looks like from the arithmetic end. And because the
    /// guest leaves the frame line standing on either side of the band,
    /// the overrun is not clipped away: it is drawn ON the frame, which is
    /// what "the group boxes are stroked through their own labels" was.
    ///
    /// Apple's `hdmx` table answers all nine EXACTLY.
    func testAGroupTitleIsExactlyAsWideAsTheBandTheGuestErasedForIt() throws {
        try skipUnlessAssetPack()
        // (fixture, title, the band the guest cleared out of its own frame)
        let bands: [(String, String, Int)] = [
            ("date-and-time", "Current Date", 80),
            ("date-and-time", "Current Time", 81),
            ("date-and-time", "Time Zone", 64),
            ("general-controls", "Desktop", 51),
            ("general-controls", "Menu Blinking", 89),
            ("general-controls", "Insertion Point Blinking", 148),
            ("general-controls", "Documents", 71),
            ("general-controls", "Check Disk", 66),
        ]
        let strike = try XCTUnwrap(DisplayReplay.strike(font: 0, size: 0))
        var wrong: [String] = []
        for (fixture, title, band) in bands {
            // The band is only an oracle if the capture still draws that
            // title as font 0; a fixture that changed underneath must fail
            // here rather than let the width assertion pass on nothing.
            let drawn = try textOps("qdtrace-drain-sweep-\(fixture)")
                .contains { $0.font == 0 && $0.text == title }
            XCTAssertTrue(drawn, "\(fixture) no longer draws \(title) as "
                          + "the system font")
            let measured = strike.width(title)
            if measured != band {
                wrong.append("\(title): \(strike.face) says \(measured), "
                             + "the guest erased \(band)")
            }
        }
        XCTAssertEqual(wrong, [],
                       "the strike disagrees with the machine's own layout")
    }

    /// The same defect from the clipped end, and the string the sweep
    /// reported: Date & Time draws "Use a Network Time Server" at pen x 40
    /// under `clip [40,195,210,217]`, so it has 170 px. Chicago wants 177
    /// and the final "r" — 7 px of it — falls outside, which is why the
    /// mirror rendered "Use a Network Time Serve".
    ///
    /// Generalised over the whole corpus rather than that one string,
    /// because the same arithmetic governs every font-0 run the guest
    /// clipped, and a gate that names one string cannot notice the next.
    /// This is `testNoMemoryPanelLabelOverrunsTheClipTheGuestSetForIt` for
    /// the system font.
    func testNoSystemFontRunOverrunsTheClipTheGuestSetForIt() throws {
        try skipUnlessAssetPack()
        let captures = [
            "appearance", "date-and-time", "memory", "sound", "sound-1pass",
            "general-controls", "finder", "finder-selected", "note-pad",
            "stickies", "scrapbook", "sherlock-2", "key-caps",
        ]
        var overruns: [String] = []
        var measured = 0
        var sawTheSweepsOwnString = false
        for capture in captures {
            var clips: [String: [Int]] = [:]
            for op in try ops("qdtrace-drain-sweep-\(capture)") {
                let port = (op["port"] as? String) ?? ""
                if (op["op"] as? String) == "state",
                   (op["kind"] as? String) == "clip",
                   let rect = op["rect"] as? [Int], rect.count == 4 {
                    clips[port] = rect
                }
                guard (op["op"] as? String) == "text",
                      (op["font"] as? Int) == 0,
                      let text = op["text"] as? String,
                      !text.trimmingCharacters(in: .whitespaces).isEmpty,
                      let pen = op["pen"] as? [Int], pen.count == 2,
                      let clip = clips[port],
                      let strike = DisplayReplay.strike(
                        font: 0, size: (op["size"] as? Int) ?? 12)
                else { continue }
                measured += 1
                if text == "Use a Network Time Server" {
                    sawTheSweepsOwnString = true
                }
                // The same one pixel of slack the applFont gate allows: a
                // run ending exactly on its clip is laid out, not overrun.
                let right = pen[0] + strike.width(text)
                if right > clip[2] + 1 {
                    overruns.append("\(capture): \"\(text)\" ends at "
                                    + "\(right), clipped at \(clip[2])")
                }
            }
        }
        XCTAssertGreaterThan(measured, 500, "the corpus stopped being read")
        XCTAssertTrue(sawTheSweepsOwnString,
                      "the capture that lost its \"r\" stopped drawing it")
        XCTAssertEqual(overruns, [],
                       "system-font runs are measured wider than the "
                       + "machine laid them out")
    }

    /// The strikes the pack rasterises rather than lifts must SAY so, in
    /// the metrics the consumer reads. A width whose provenance is a
    /// rasteriser's guess and a width that is Apple's own device metric
    /// are not the same claim, and the file is where that distinction
    /// survives the trip out of the extractor.
    func testACharcoalStrikeDeclaresWhereItsWidthsCameFrom() throws {
        try skipUnlessAssetPack()
        let url = try XCTUnwrap(AssetPack.url(forResource: "charcoal-12",
                                              withExtension: "json",
                                              subdirectory: "fonts"))
        let meta = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(meta["widthSource"] as? String, "hdmx",
                       "a rasterised strike whose advances did not come "
                       + "from the font's own device metrics is a guess")
        XCTAssertEqual(meta["rasterisedFrom"] as? String, "sfnt")
        XCTAssertEqual(meta["face"] as? String, "Charcoal")
    }

    // MARK: - R8, a selected label rendered as a solid black bar

    /// The Finder paints a selected label's background and writes the text
    /// over it in the inverse colour. The paint crosses; the inverse does
    /// not — so the replay drew black on black and "System Folder" came out
    /// as a solid bar with the label swallowed inside it. The machine's own
    /// pixels for that moment (`finder-guest.ppm`) are WHITE text on the
    /// black bar.
    ///
    /// The rectangle and the pen below are the capture's own, quoted from
    /// `qdtrace-drain-sweep-finder-selected` rather than invented.
    func testTextPaintedIntoItsOwnHighlightIsDrawnInTheInverse() throws {
        let highlight = CGRect(x: 13, y: 57, width: 73, height: 13)
        let pen = CGPoint(x: 15, y: 67)
        let ink = DisplayReplay.textInk(
            fg: .black, bg: .white, at: pen,
            lastFill: (rect: highlight, color: .black))
        XCTAssertEqual(ink, Color.white,
                       "the label is still drawn black on black")
    }

    /// And the rule must stay narrow: ordinary text over an ordinary fill
    /// keeps the foreground colour it was given. Nine of the ten labels in
    /// that same capture are drawn this way and none of them is selected.
    func testOrdinaryTextKeepsItsForegroundColour() throws {
        let elsewhere = CGRect(x: 200, y: 100, width: 60, height: 13)
        XCTAssertEqual(
            DisplayReplay.textInk(fg: .black, bg: .white,
                                  at: CGPoint(x: 15, y: 67),
                                  lastFill: (rect: elsewhere, color: .black)),
            Color.black, "a fill somewhere else must not tint this run")
        XCTAssertEqual(
            DisplayReplay.textInk(fg: .black, bg: .white,
                                  at: CGPoint(x: 15, y: 67),
                                  lastFill: (rect: CGRect(x: 13, y: 57,
                                                          width: 73,
                                                          height: 13),
                                             color: .white)),
            Color.black, "black text on a white fill is perfectly legible")
        XCTAssertEqual(
            DisplayReplay.textInk(fg: .black, bg: .white,
                                  at: CGPoint(x: 15, y: 67), lastFill: nil),
            Color.black)
    }

    /// The capture this gate stands on still carries the painted highlight
    /// and the label inside it. If the Finder stops painting and starts
    /// inverting, this fails and says the baseline moved — the same service
    /// `testTheFindersSelectionNeverReachesTheCapture` performs for invert.
    func testTheSelectedLabelsHighlightIsStillAPaintedRect() throws {
        let all = try ops("qdtrace-drain-sweep-finder-selected")
        let painted = all.filter {
            ($0["op"] as? String) == "rect" && ($0["verb"] as? Int) == 1
                && ($0["rect"] as? [Int]) == [13, 57, 86, 70]
        }
        XCTAssertFalse(painted.isEmpty,
                       "the selected label's background is no longer painted")
        XCTAssertTrue(all.contains {
            ($0["text"] as? String) == "System Folder"
                && ($0["pen"] as? [Int]) == [15, 67]
        }, "the label no longer lands inside that rectangle")
    }
}
