import XCTest
@testable import MirrorKitUI

/// The pack is a runtime dependency resolved by `AssetPack`, not
/// repository content. These are the claims that make that safe.
///
/// The one that matters is the last: absent must be a state the code
/// SAYS, not one it draws around. A missing dependency that looks like
/// working software is the failure this project has paid for most.
final class AssetPackTests: XCTestCase {

    /// Whatever the answer is, the search must produce one and it must
    /// be reportable. There is no third state.
    func testTheSearchAlwaysReachesAVerdict() {
        XCTAssertFalse(AssetPack.summaryLine.isEmpty)
        switch AssetPack.status {
        case let .resolved(url, via):
            XCTAssertFalse(via.isEmpty, "a resolved pack must say via what")
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: url.appendingPathComponent("manifest.json").path),
                "resolved to a directory with no manifest.json")
        case let .absent(searched):
            XCTAssertFalse(searched.isEmpty,
                           "absent must name where it looked, or the "
                               + "message cannot say where to put the pack")
        }
    }

    /// A directory is not a pack until the extractor has finished with
    /// it. `manifest.json` is written last, so a half-extracted
    /// directory must not resolve — otherwise a killed extraction reads
    /// as a present pack with most of its art missing, which is the
    /// silent-degradation case wearing a different hat.
    func testAHalfExtractedDirectoryIsNotAPack() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("assetpack-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("icons"),
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        XCTAssertFalse(AssetPack.isPack(tmp),
                       "a directory with art but no manifest resolved as "
                           + "a finished pack")
        // The manifest is the only difference between the two verdicts.
        try Data("{}".utf8).write(
            to: tmp.appendingPathComponent("manifest.json"))
        XCTAssertTrue(AssetPack.isPack(tmp))

        // And a file is not a directory, however it is named.
        let file = tmp.appendingPathComponent("manifest.json")
        XCTAssertFalse(AssetPack.isPack(file))
        XCTAssertFalse(AssetPack.isPack(
            tmp.appendingPathComponent("nope")))
    }

    /// The banner exists exactly when the pack does not, and it must
    /// name both the symptom and the cure — a warning that says only
    /// "missing" leaves the reader to guess whether the picture in
    /// front of them is the guest's art or a stand-in.
    func testAnAbsentPackSaysSoAndSaysWhatToDo() {
        switch AssetPack.status {
        case .resolved:
            XCTAssertNil(AssetPack.bannerText,
                         "a present pack has nothing to announce")
        case .absent:
            let text = AssetPack.bannerText ?? ""
            XCTAssertTrue(text.contains("not found"))
            XCTAssertTrue(text.contains("procedural"),
                          "the banner must say the art is a stand-in")
            XCTAssertTrue(text.contains(AssetPack.environmentKey))
            XCTAssertTrue(text.contains("extract-assets-offline"),
                          "the banner must name the way to regenerate")
        }
    }

    func testPackCatalogDiscoversOnlyFinishedPacksNewestFirst() throws {
        let store = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("assetpack-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: store) }
        for id in ["pack-2026-01", "pack-2026-02", "notes"] {
            try FileManager.default.createDirectory(
                at: store.appendingPathComponent(id)
                    .appendingPathComponent("Resources"),
                withIntermediateDirectories: true)
        }
        try Data("{}".utf8).write(to: store
            .appendingPathComponent("pack-2026-01/Resources/manifest.json"))
        try Data("{}".utf8).write(to: store
            .appendingPathComponent("pack-2026-02/Resources/manifest.json"))

        XCTAssertEqual(AssetPack.discover(in: store).map(\.id),
                       ["pack-2026-02", "pack-2026-01"])
    }
}

/// Shared by every test that needs the pack's actual bytes.
///
/// A skip is visible in the run output; a silently-passing assertion is
/// not. `NOW_REQUIRE_ASSET_PACK=1` turns the skip into a failure on a
/// machine that has the pack, which is where these gates are meant to
/// bite (`scripts/test-mirrorkit` sets it when one resolves).
func skipUnlessAssetPack() throws {
    guard !AssetPack.status.isPresent else { return }
    if AssetPack.isRequired {
        XCTFail("NOW_REQUIRE_ASSET_PACK is set and the pack is absent — "
                + (AssetPack.bannerText ?? ""))
        return
    }
    throw XCTSkip("Platinum asset pack absent. "
                  + (AssetPack.bannerText ?? ""))
}
