import XCTest
@testable import MirrorKitUI

/// **`IconAtlas.icon(forProcessSignature:)`** — the live-processes shelf's
/// real per-app icon, keyed off `Scene.ProcessRef.signature` (the creator
/// OSType, on the wire since IR v1 but never read on this side before
/// lane L7). A process is always an application, never a document, so this
/// is a narrower question than `icon(for:)` asks of a desktop item: one
/// key (`creator__APPL`), not two.
final class IconAtlasProcessTests: XCTestCase {
    /// A creator the extracted appicons pack actually carries
    /// (`ttxt__APPL.png` — SimpleText) resolves to a real image, not the
    /// monogram fallback's nil.
    func testAKnownCreatorResolvesToARealIcon() {
        XCTAssertNotNil(IconAtlas.icon(forProcessSignature: "ttxt"),
                        "ttxt__APPL.png ships in Resources/appicons; a nil "
                            + "here means the pack lookup or the bundle "
                            + "path broke, not that the icon is missing")
    }

    /// `signature == 0` on the wire — the guest's own "we could not read
    /// this process's creator" (`scene_json.c:put_signature`) — decodes to
    /// `""` (`SceneBuilder.swift`), and an empty creator must fall back to
    /// the monogram rather than this function inventing a key to look up.
    func testAnEmptySignatureFallsBackToTheMonogram() {
        XCTAssertNil(IconAtlas.icon(forProcessSignature: ""))
    }

    /// A creator the pack was never measured against (a real app this
    /// extraction never saw) is an honest nil, not a guessed icon.
    func testAnUnknownCreatorFallsBackToTheMonogram() {
        XCTAssertNil(IconAtlas.icon(forProcessSignature: "zzzz"))
    }

    /// A signature the wire escapes as unprintable (control bytes, a path
    /// separator) is refused by `cleanOSType` the same way `icon(for:)`
    /// refuses one for a desktop item — this is the SAME guard, reused
    /// rather than duplicated, so the two cannot drift into disagreeing
    /// about what counts as a usable key.
    func testAnUnprintableSignatureFallsBackToTheMonogram() {
        XCTAssertNil(IconAtlas.icon(forProcessSignature: "a/b"))
    }
}
