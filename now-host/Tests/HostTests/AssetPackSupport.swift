import XCTest
import MirrorKitUI

/// The Platinum asset pack is Apple's bitmaps: a runtime dependency
/// resolved by `AssetPack`, deliberately not in this repository
/// (docs/asset-pack.md). A test that needs its actual bytes calls this.
///
/// A skip appears in the run output by name; a test quietly rewritten to
/// pass without the pack does not, and that is the shape of gate this
/// project has been bitten by most. So the default on a machine with no
/// pack is a NAMED skip, and `NOW_REQUIRE_ASSET_PACK=1` — which
/// `scripts/test-host` sets whenever a pack actually resolves — turns
/// those skips back into failures where they can bite.
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
