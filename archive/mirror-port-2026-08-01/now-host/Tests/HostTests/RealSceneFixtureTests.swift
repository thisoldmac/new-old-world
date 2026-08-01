import XCTest
import AppKit
import MirrorKit
import MirrorKitUI
import NOWAgentIntegration
@testable import Host

/// F2, end to end: a live guest capture through the wire decoder, the
/// document→IR adapter, and a real render — not a Swift literal this suite
/// builds and then parses itself.
///
/// `real-scene-mac99-20260801.json` is `docs/local/wave3-live-scene.json`
/// from the 2026-08-01 session (Mac OS 9.1, "mac99" in that session's own
/// notes), copied in unmodified. `MirrorSceneAdapterTests` in this same
/// directory already proves the adapter's own defaulting rules with
/// hand-built documents; this file proves the same rules survive a real
/// wire payload, and that what comes out the other end still rasterizes.
private extension CGImage {
    /// Byte-level comparison for two `IconAtlas` lookups: two DIFFERENT
    /// `CGImage` values can still be the same picture (re-decoded from the
    /// same file), so `===`/pointer identity is not the right check here.
    func pngBytes() -> Data? {
        NSBitmapImageRep(cgImage: self).representation(using: .png,
                                                        properties: [:])
    }
}

@MainActor
final class RealSceneFixtureTests: XCTestCase {

    private func fixtureData() throws -> Data {
        guard let dir = Bundle.module.url(forResource: "Fixtures",
                                          withExtension: nil) else {
            throw XCTSkip("Fixtures resource directory missing")
        }
        let url = dir.appendingPathComponent(
            "real-scene-mac99-20260801.json")
        return try Data(contentsOf: url)
    }

    /// The full production path: wire bytes → `NOWSceneCodec` (version gate,
    /// then `NOWSceneDocument`) → `MirrorSceneAdapter` → `MirrorKit.Scene`.
    private func decodeScene() throws -> MirrorKit.Scene {
        let data = try fixtureData()
        let doc = try NOWSceneCodec.decode(irVersion: 1, document: data)
        return MirrorSceneAdapter.scene(from: doc)
    }

    func testTheFullAdapterPathDecodesTheRealCaptureWithoutThrowing() throws {
        XCTAssertNoThrow(try decodeScene())
    }

    func testMenubarWindowControlAndDesktopPlanesAllCrossed() throws {
        let scene = try decodeScene()

        let menubar = try XCTUnwrap(scene.menubar)
        XCTAssertEqual(menubar.app, "Finder")
        XCTAssertEqual(menubar.menus.count, 8)

        let front = try XCTUnwrap(scene.windows.first { $0.front })
        XCTAssertEqual(front.title, "TimBotTu")

        // Never ASSERTED by NOW's walk (no defProc reading), but INFERRED:
        // this control's raw wire rect (410,89)-(426,273) is a 16×184 strip
        // hugging the window's own right content edge — real vertical
        // scrollbar shape, real vertical scrollbar position.
        let control = try XCTUnwrap(front.controls.first)
        XCTAssertEqual(control.role, "scrollbar",
                       "shape + edge, inferred — see MirrorSceneAdapter's "
                           + "own header for why this is not the same as "
                           + "asserting a defProc read NOW cannot make")
        XCTAssertEqual(control.rect, Rect(l: 395, t: 22, r: 411, b: 206),
                       "content-local: the wire's global (410,89)-(426,273) "
                           + "minus this window's content origin (15,67)")

        let items = try XCTUnwrap(scene.desktopItems)
        XCTAssertEqual(items.count, 18)
    }

    /// The window's SECOND control — its horizontal scrollbar — carries a
    /// degenerate range in this capture (`min == max == value == -64`, this
    /// window's content happening to fit horizontally): the wire's own
    /// analogue of the -52/-52/-52 measured elsewhere
    /// (`docs/open-issues.md`). Nothing above this test ever asserted on
    /// it — `testMenubarWindowControlAndDesktopPlanesAllCrossed` stops at
    /// `controls.first`, the vertical bar — so a role inference that only
    /// worked for a tall strip would have shipped invisibly.
    func testRealHorizontalScrollbarWithADegenerateRangeIsStillAScrollbar() throws {
        let scene = try decodeScene()
        let front = try XCTUnwrap(scene.windows.first { $0.front })
        XCTAssertEqual(front.controls.count, 3,
                       "vertical bar, horizontal bar, one hidden square control")
        let horizontal = front.controls[1]
        XCTAssertEqual(horizontal.role, "scrollbar",
                       "raw wire rect (20,272)-(411,288): a 391×16 strip "
                           + "hugging the window's own bottom content edge")
        XCTAssertEqual(horizontal.min, -64)
        XCTAssertEqual(horizontal.max, -64)
        XCTAssertFalse(Scrollbar.isLive(horizontal),
                       "min == max: this window's content fits, nothing to scroll")
    }

    // MARK: - desktop items: coordinate space and icon resolution (lanes 3, 4)

    /// Every PLACED item's position is inside the scene's own screen — the
    /// symptom this test rules out is an item rendered off in the wrong
    /// coordinate space entirely (global vs desktop-local vs some
    /// fit-transform), not merely "somewhere on an 800×600 canvas".
    /// `SceneRenderer.drawDesktopIcons` draws every placed item at exactly
    /// `(item.x, item.y)` with no further transform, so this is the same
    /// arithmetic the renderer itself uses.
    func testDesktopItemPositionsAreWithinTheScenesOwnScreen() throws {
        let scene = try decodeScene()
        let items = try XCTUnwrap(scene.desktopItems)
        for item in items where item.placed {
            XCTAssertGreaterThanOrEqual(item.x, 0, item.name)
            XCTAssertGreaterThanOrEqual(item.y, 0, item.name)
            XCTAssertLessThan(item.x, Int(scene.screen.w), item.name)
            XCTAssertLessThan(item.y, Int(scene.screen.h), item.name)
        }
    }

    /// The one item this producer never places itself: the boot volume. NOW's
    /// guest always reports it `placed:false, x:0, y:0`
    /// (`scene_desktop.c`) — a real position stacked top-right, at THIS
    /// scene's own screen size, is the adapter's job
    /// (`SceneGeometry.placeVolumes`), not a raw pass-through.
    func testTheUnplacedVolumeLandsTopRightRatherThanAtTheOriginItArrivedAt() throws {
        let scene = try decodeScene()
        let items = try XCTUnwrap(scene.desktopItems)
        let disk = try XCTUnwrap(items.first { $0.kind == "disk" })
        XCTAssertEqual(disk.name, "Macintosh HD")
        XCTAssertTrue(disk.placed)
        XCTAssertEqual(disk.x, Int(scene.screen.w) - 76)
        XCTAssertEqual(disk.y, 12)
    }

    /// `IconAtlas.icon(for:)` — the exact call `SceneRenderer.drawGenericIcon`
    /// makes before ever reaching the procedural fallback — resolves a REAL
    /// per-app icon (creator+type keyed) for four items this capture actually
    /// reported, three of them aliases (`adrp`, resolved through APPL because
    /// an alias shows the target app's own icon, never a generic alias glyph).
    /// A resolution failure here is a silent fallback to the generic box the
    /// task exists to catch — `nil` would pass every OTHER test in this file.
    func testRealDesktopItemsResolveToRealPerAppIconsNotTheGenericFallback() throws {
        let scene = try decodeScene()
        let items = try XCTUnwrap(scene.desktopItems)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })

        for name in ["Browse the Internet", "Mail", "QuickTime Player",
                     "Sherlock 2"] {
            let item = try XCTUnwrap(byName[name], name)
            XCTAssertTrue(item.alias, "\(name): this capture's own field")
            XCTAssertNotNil(IconAtlas.icon(for: item),
                            "\(name) (\(item.creator ?? "?")/\(item.type ?? "?")"
                                + ", alias) should resolve through APPL, not "
                                + "fall back to the generic application box")
        }

        // A real per-document icon too, not just app/alias icons: this
        // capture's own ttxt/TEXT file.
        let doc = try XCTUnwrap(byName["HELLO_CLAUDE.txt"])
        XCTAssertNotNil(IconAtlas.icon(for: doc),
                        "ttxt/TEXT is in the extracted appicons pack")

        // And the honest negative: `"????"` — this capture's own
        // "unknown creator" sentinel, not a rare edge case — must resolve
        // EXACTLY like no creator at all: the generic TEXT icon, never a
        // real per-app match by coincidence. Checked at first by asserting
        // `nil`, which was wrong on this file's own terms — `icon(for:)`
        // never returns `nil` for a `"file"` item, only for `"disk"` (see
        // its own doc comment); that assertion would have passed even for a
        // WRONG per-app match, which is the one failure mode worth ruling
        // out here. Compared by PNG bytes instead, against an item that is
        // identical except for having no `creator` at all: if `"????"` ever
        // started resolving through the `creator/type` keyed lookup instead
        // of falling through to the generic path, the two would stop
        // matching and this is what would catch it.
        let unknown = try XCTUnwrap(byName["harness.log"])
        XCTAssertEqual(unknown.creator, "????")
        var noCreator = unknown
        noCreator.creator = nil
        let unknownPNG = try XCTUnwrap(IconAtlas.icon(for: unknown))
            .pngBytes()
        let genericPNG = try XCTUnwrap(IconAtlas.icon(for: noCreator))
            .pngBytes()
        XCTAssertEqual(unknownPNG, genericPNG,
                       "\"????\" must resolve to the SAME generic icon as no "
                           + "creator at all, not a wildcard match off some "
                           + "unrelated real creator's file")
    }

    // MARK: - the render path (lane 4)

    /// Sample a scattered grid and require more than one colour: proof this
    /// is a real render of a populated desktop (menu bar, three Finder
    /// windows, seventeen desktop icons) rather than a blank or single-tone
    /// canvas — the failure mode a decode that silently produced an empty
    /// `Scene` would have produced too.
    func testDecodedRealSceneRendersANonTrivialImage() throws {
        let scene = try decodeScene()
        let png = try RenderShot.png(scene: scene)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(rep.pixelsWide, Int(scene.screen.w))
        XCTAssertEqual(rep.pixelsHigh, Int(scene.screen.h))

        var colors = Set<[Int]>()
        let xs = stride(from: 20, to: rep.pixelsWide - 20, by: 47)
        let ys = stride(from: 5, to: rep.pixelsHigh - 5, by: 37)
        for x in xs {
            for y in ys {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                colors.insert([Int((c.redComponent * 255).rounded()),
                               Int((c.greenComponent * 255).rounded()),
                               Int((c.blueComponent * 255).rounded())])
            }
        }
        XCTAssertGreaterThan(colors.count, 1,
                             "a real render of this desktop paints more than "
                                 + "one colour; a blank canvas would not")
    }

    // MARK: - folder items: joined onto a real window, proven to actually draw (lane 2)

    /// The same live-Finder `script` reply `MirrorFolderItemsJoinTests`
    /// captured verbatim, 2026-08-01, `mac99-os91` — reused here rather than
    /// re-transcribed, so this test's items are exactly the ones that suite's
    /// join-logic tests already trust.
    private static let realFinderScriptReply =
        "\"W|Macintosh HD|Macintosh HD:;;I|System Folder|34,25;;" +
        "I|TimBotTu|290,89;;I|Applications (Mac OS 9)|162,25;;" +
        "I|Documents|290,25;;I|Late Breaking News|34,89;;" +
        "I|Rumpus PRO 2.0|162,89;;I|TBT|34,153;;" +
        "I|TBT-paced-dev|162,153;;I|TBT-sndbuf-dev|290,153;;" +
        "I|TBTRunner|34,217;;W|TBTRunner|Macintosh HD:TBTRunner:;;" +
        "I|runner.debug|19,25;;I|runner.port|147,25;;\""

    private func scriptResult(_ raw: String) -> CommandResult {
        CommandResult(id: 1, ok: true, output: ["script": [["output", raw]]])
    }

    /// Traces a joined scene all the way through the renderer: real window
    /// geometry (this fixture's own "Macintosh HD"), real joined items (the
    /// capture above), and a real `RenderShot` — proving `win.items != nil`
    /// actually reaches pixels, not just that the model holds a value.
    ///
    /// The fixture's three Finder windows cascade and mostly overlap each
    /// other (`TimBotTu` covers nearly all of `Macintosh HD`'s own content
    /// area), which is real and correct but would make a pixel sample
    /// anywhere in the full composite ambiguous — a blank spot could mean
    /// "no icon drawn" or "another window drawn on top". This isolates
    /// `Macintosh HD` as the only window in its own copy of the scene so the
    /// sample can only mean one thing, without altering its rect, controls,
    /// or the items joined onto it.
    func testJoinedFolderItemsDrawAtTheirLivePositionInsideTheContentRect() throws {
        var scene = try decodeScene()
        let index = try XCTUnwrap(
            scene.windows.firstIndex { $0.title == "Macintosh HD" })
        scene.windows[index].front = true
        scene.windows = [scene.windows[index]]
        let win = scene.windows[0]

        let join = MirrorFolderItemsJoin(listener: GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host")))
        let (joined, outcome) = join.apply(
            scriptResult(Self.realFinderScriptReply), to: scene)
        guard case .joined(let windows, let items) = outcome else {
            return XCTFail("expected .joined, got \(outcome)")
        }
        XCTAssertEqual(windows, 1)
        XCTAssertEqual(items, 10)
        let placed = try XCTUnwrap(joined.windows[0].items)
        let systemFolder = try XCTUnwrap(placed.first { $0.name == "System Folder" })
        XCTAssertEqual(systemFolder.x, 34)
        XCTAssertEqual(systemFolder.y, 25)

        // The renderer's OWN content-origin arithmetic (SceneRenderer
        // .drawWindow: `content.minX/minY`, non-dialog) — not a second,
        // possibly-disagreeing formula for where the icon box should be.
        let size = CGSize(width: CGFloat(joined.screen.w),
                         height: CGFloat(joined.screen.h))
        let before = try RenderShot.png(scene: scene, size: size)
        let after = try RenderShot.png(scene: joined, size: size)
        let beforeRep = try XCTUnwrap(NSBitmapImageRep(data: before))
        let afterRep = try XCTUnwrap(NSBitmapImageRep(data: after))

        let contentMinX = Int(win.rect.l) + 1
        let contentMinY = Int(win.rect.t) + Int(Platinum.contentTop)
        let box = (x0: contentMinX + systemFolder.x,
                  y0: contentMinY + systemFolder.y,
                  x1: contentMinX + systemFolder.x + 32,
                  y1: contentMinY + systemFolder.y + 32)

        func color(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> [Int]? {
            guard let c = rep.colorAt(x: x, y: y) else { return nil }
            return [Int((c.redComponent * 255).rounded()),
                    Int((c.greenComponent * 255).rounded()),
                    Int((c.blueComponent * 255).rounded())]
        }

        var changedInsideBox = false
        for y in stride(from: box.y0, to: box.y1, by: 2) {
            for x in stride(from: box.x0, to: box.x1, by: 2) {
                if color(beforeRep, x, y) != color(afterRep, x, y) {
                    changedInsideBox = true
                }
            }
        }
        XCTAssertTrue(changedInsideBox,
                     "joining items changed nothing inside System Folder's "
                         + "own 32×32 icon box — items are not reaching "
                         + "pixels at their live position")

        // A patch of the SAME window's content well away from every joined
        // item (bottom-left corner of the content area, past every real
        // item's box) must be untouched — the change above is the icon
        // drawing, not some unrelated re-tint of the whole window.
        var changedFarFromAnyItem = false
        for y in stride(from: contentMinY + 208, to: contentMinY + 220, by: 1) {
            for x in stride(from: contentMinX + 2, to: contentMinX + 30, by: 2) {
                if color(beforeRep, x, y) != color(afterRep, x, y) {
                    changedFarFromAnyItem = true
                }
            }
        }
        XCTAssertFalse(changedFarFromAnyItem,
                       "a spot with no joined item nearby changed too — the "
                           + "join or the draw is doing something wider than "
                           + "placing the items it was given")
    }
}
