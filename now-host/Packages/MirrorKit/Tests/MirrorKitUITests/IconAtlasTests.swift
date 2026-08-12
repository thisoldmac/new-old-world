import XCTest
import CoreGraphics
@testable import MirrorKit
@testable import MirrorKitUI

/// The pack is built offline by `tools/extract-assets-offline` and resolved
/// at run time by `AssetPack` — it is NOT in this repository. These are the
/// claims the renderer makes about it: that both sizes exist as their own
/// art, and that a reported creator signature reaches a real per-application
/// icon rather than a generic one.
///
/// A missing FILE inside a present pack makes `IconAtlas` return nil
/// silently, which draws a procedural fallback and reads on screen as "the
/// mirror is a bit rough" rather than "the pack did not ship". These fail
/// instead.
///
/// A missing PACK is a different thing and gets different treatment: the
/// tests that need its bytes skip by name (`skipUnlessAssetPack`) so a
/// fresh clone is honest rather than red, and a machine that has the pack
/// sets `NOW_REQUIRE_ASSET_PACK=1` to turn those skips back into failures.
/// The tests that assert pure LOGIC — size fitting, junk-signature
/// rejection — need no pack and are not guarded.
@MainActor
final class IconAtlasTests: XCTestCase {

    func testEveryGenericIconShipsInBothSizes() throws {
        try skipUnlessAssetPack()
        for name in ["folder", "document", "application", "disk", "trash",
                     "system-folder"] {
            guard let large = IconAtlas.namedIcon(name, size: .large),
                  let small = IconAtlas.namedIcon(name, size: .small) else {
                XCTFail("generic icon '\(name)' missing from the pack")
                continue
            }
            XCTAssertEqual(large.width, 32, "\(name) large is not icl8-sized")
            XCTAssertEqual(small.width, 16, "\(name) small is not ics8-sized")
        }
    }

    /// The point of shipping the small art at all: it is a DIFFERENT
    /// drawing, not the large one resampled. If these ever became the same
    /// bitmap scaled, the size parameter would be decoration.
    func testSmallArtIsItsOwnDrawing() throws {
        try skipUnlessAssetPack()
        let large = IconAtlas.namedIcon("document", size: .large)
        let small = IconAtlas.namedIcon("document", size: .small)
        XCTAssertNotNil(large)
        XCTAssertNotNil(small)
        XCTAssertNotEqual(large?.width, small?.width)
    }

    func testSizeFittingPicksSmallArtForAListRow() {
        XCTAssertEqual(IconAtlas.Size.fitting(
            CGRect(x: 0, y: 0, width: 16, height: 16)), .small)
        XCTAssertEqual(IconAtlas.Size.fitting(
            CGRect(x: 0, y: 0, width: 32, height: 32)), .large)
    }

    /// `fndf` is Sherlock 2's own creator, read from its own BNDL on the
    /// disk image. A reported signature is identity, not a guess — unlike a
    /// Finder item's icon bits, which carry none.
    func testAReportedSignatureReachesTheApplicationsOwnIcon() throws {
        try skipUnlessAssetPack()
        XCTAssertNotNil(IconAtlas.processIcon(signature: "fndf", size: .large))
        XCTAssertEqual(
            IconAtlas.processIcon(signature: "fndf", size: .small)?.width, 16)
    }

    func testAnUnknownOrJunkSignatureFallsThroughRatherThanGuessing() {
        XCTAssertNil(IconAtlas.processIcon(signature: nil))
        XCTAssertNil(IconAtlas.processIcon(signature: ""))
        XCTAssertNil(IconAtlas.processIcon(signature: "zzzz"))
        // A creator the wire had to escape must not become a filename.
        XCTAssertNil(IconAtlas.processIcon(signature: "a/b:"))
    }

    /// An alias file reports its own `adrp/aplt` identity, but Finder draws
    /// what the resolved target represents. The target may be a document
    /// type—not every alias is coerced to APPL. Watched to fail by restoring
    /// the old `item.alias ? "APPL" : item.type` selection.
    func testAnAliasUsesItsSemanticTargetsExactCreatorAndType() {
        let target = MirrorKit.Scene.DesktopItem.AliasTarget(
            name: "Get QuickTime Pro", kind: "file",
            type: "MooV", creator: "TVOD")
        let alias = MirrorKit.Scene.DesktopItem(
            name: "QuickTime", kind: "application",
            type: "adrp", creator: "aplt", x: 0, y: 0,
            placed: true, alias: true, invisible: false,
            aliasTarget: target)
        XCTAssertEqual(IconAtlas.assetKey(for: alias), "TVOD__MooV")

        var unresolved = alias
        unresolved.aliasTarget = nil
        XCTAssertNil(IconAtlas.assetKey(for: unresolved),
                     "an alias file's own identity is not its visible art")
    }

    func testANonAliasDocumentKeepsItsOwnCreatorAndType() {
        let movie = MirrorKit.Scene.DesktopItem(
            name: "Get QuickTime Pro", kind: "file",
            type: "MooV", creator: "TVOD", x: 0, y: 0,
            placed: true, alias: false, invisible: false)
        XCTAssertEqual(IconAtlas.assetKey(for: movie), "TVOD__MooV")
    }

    /// The OS 8.6 Desktop Folder aliases carry custom art in their own
    /// resource forks. A present pack must retain that path-addressed suite;
    /// otherwise the renderer silently falls back despite extraction having
    /// read the strongest available source.
    func testDesktopFileCustomIconSurvivesThePack() throws {
        try skipUnlessAssetPack()
        XCTAssertEqual(IconAtlas.fileIcon(
            path: "Desktop Folder:Browse the Internet", size: .large)?.width,
            32)
        XCTAssertEqual(IconAtlas.fileIcon(
            path: "Desktop Folder:Browse the Internet", size: .small)?.width,
            16)

        let item = MirrorKit.Scene.DesktopItem(
            name: "Browse the Internet", kind: "application",
            type: "adrp", creator: "aplt", x: 0, y: 0,
            placed: true, alias: true, invisible: false)
        let custom = try XCTUnwrap(IconAtlas.fileIcon(
            path: "Desktop Folder:Browse the Internet", size: .large))
        let selected = try XCTUnwrap(IconAtlas.icon(
            for: item, size: .large, container: "Desktop Folder"))
        XCTAssertTrue(selected === custom,
                      "the desktop route ignored stronger file-owned art")
    }

    func testLargeAliasChromeComesFromTheProfilePackOnly() throws {
        try skipUnlessAssetPack()
        XCTAssertEqual(IconAtlas.aliasBadge(size: .large)?.width, 32)
        XCTAssertEqual(IconAtlas.aliasBadge(size: .large)?.height, 32)
        XCTAssertNil(IconAtlas.aliasBadge(size: .small),
                     "large desktop proof cannot define list-view chrome")
    }

    /// The state-proven target uses Geneva 10 for both routes and synthesizes
    /// the alias slant at draw time. Watched to fail by restoring either
    /// Geneva 9 strike.
    func testDesktopLabelsUseTheExtractedGeneva10Strike() throws {
        try skipUnlessAssetPack()
        let alias = MirrorKit.Scene.DesktopItem(
            name: "Mail", kind: "application", type: "adrp", creator: "aplt",
            x: 0, y: 0, placed: true, alias: true, invisible: false)
        let plain = MirrorKit.Scene.DesktopItem(
            name: "Get QuickTime Pro", kind: "file",
            type: "MooV", creator: "TVOD", x: 0, y: 0,
            placed: true, alias: false, invisible: false)
        XCTAssertEqual(SceneRenderer.desktopLabelFont(alias)?.face.lowercased(),
                       "geneva")
        XCTAssertEqual(SceneRenderer.desktopLabelFont(alias)?.pointSize, 10)
        XCTAssertEqual(SceneRenderer.desktopLabelFont(alias)?.style, 0)
        XCTAssertEqual(SceneRenderer.desktopLabelFont(plain)?.pointSize, 10)
        XCTAssertEqual(SceneRenderer.desktopLabelFont(plain)?.style, 0)
    }

    func testDesktopLabelGeometryUsesFinderIntegerPlacement() {
        let box = CGRect(x: 736, y: 220, width: 32, height: 32)
        XCTAssertEqual(SceneRenderer.desktopLabelTextX(
            box, width: 97, alias: true), 702)
        XCTAssertEqual(SceneRenderer.desktopLabelTextX(
            box, width: 90, alias: false), 707)
        XCTAssertEqual(SceneRenderer.desktopLabelY(box, kind: "file"), 252)
        XCTAssertEqual(SceneRenderer.desktopLabelY(box, kind: "disk"), 253)
    }

    func testQuickDrawSyntheticItalicShearsTopRowsFurthest() {
        XCTAssertEqual(BitmapFont.syntheticItalicShift(row: 2, height: 12), 5)
        XCTAssertEqual(BitmapFont.syntheticItalicShift(row: 3, height: 12), 4)
        XCTAssertEqual(BitmapFont.syntheticItalicShift(row: 10, height: 12), 1)
        XCTAssertEqual(BitmapFont.syntheticItalicShift(row: 11, height: 12), 0)
    }

    func testDesktopTrashUsesItsNamedSystemResource() throws {
        try skipUnlessAssetPack()
        let trash = MirrorKit.Scene.DesktopItem(
            name: "Trash", kind: "folder", type: nil, creator: nil,
            x: 0, y: 0, placed: true, alias: false, invisible: false)
        let selected = try XCTUnwrap(IconAtlas.icon(
            for: trash, size: .large, container: "Desktop Folder"))
        let named = try XCTUnwrap(IconAtlas.namedIcon("trash", size: .large))
        XCTAssertTrue(selected === named)
    }

    /// An ordinary Finder item with no creator and no exact-path custom art
    /// must land on the generic bitmap for its kind. This pins the honest
    /// fallback even though target and file-owned identities are now usable.
    func testAnItemWithoutACreatorStaysGenericByKind() throws {
        try skipUnlessAssetPack()
        let folder = MirrorKit.Scene.DesktopItem(
            name: "Documents", kind: "folder", type: nil, creator: nil,
            x: 0, y: 0, placed: false, alias: false, invisible: false)
        XCTAssertEqual(IconAtlas.icon(for: folder, size: .small)?.width, 16)
        XCTAssertEqual(IconAtlas.icon(for: folder, size: .large)?.width, 32)
    }
}
