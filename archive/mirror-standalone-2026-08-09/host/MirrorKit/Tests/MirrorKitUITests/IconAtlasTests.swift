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
final class IconAtlasTests: XCTestCase {

    func testEveryGenericIconShipsInBothSizes() throws {
        try skipUnlessAssetPack()
        for name in ["folder", "document", "application", "disk",
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

    /// Identity for a Finder ITEM stays unsolved (plan 015 G4). Until it is,
    /// an item with no creator must land on the generic bitmap for its kind
    /// — this pins the fallback so a later identity change is visible.
    func testAnItemWithoutACreatorStaysGenericByKind() throws {
        try skipUnlessAssetPack()
        let folder = MirrorKit.Scene.DesktopItem(
            name: "Documents", kind: "folder", type: nil, creator: nil,
            x: 0, y: 0, placed: false, alias: false, invisible: false)
        XCTAssertEqual(IconAtlas.icon(for: folder, size: .small)?.width, 16)
        XCTAssertEqual(IconAtlas.icon(for: folder, size: .large)?.width, 32)
    }
}
