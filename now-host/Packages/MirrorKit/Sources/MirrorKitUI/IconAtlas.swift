import Foundation
import CoreGraphics
import ImageIO
import MirrorKit

/// Real OS 9 icons from the extracted pack, keyed by kind/type.
///
/// The pack is resolved at runtime by ``AssetPack`` and is NOT in this
/// repository — see that type for why and for the recovery procedure.
/// Every entry point here already returns nil for "the pack has no icon
/// for this", which a complete pack does for any third-party
/// application, so an absent pack degrades down the same path rather
/// than a new one: the caller draws its procedural fallback. What makes
/// that honest rather than silent is ``AssetPack/bannerText``, which the
/// UI shows so nobody mistakes a stand-in for the guest's own art.
///
/// Two families. The *generic* Finder icons (folder / application /
/// document / disk / System Folder) are the honest fallback wherever the
/// mirror does not know which item it is looking at — icons arrive down
/// the wire as bits with no identity, and resolving that is a separate
/// problem (PlotIconSuite interception). The *per-application* icons are
/// keyed by the creator+type the guest actually reported, so they are not
/// a guess.
///
/// Provenance (platinum-pack System-file icl8, resource id):
///   folder = -3999 · application = -3968 · document = -4000
///   system-folder = -3982 · disk = -3998
/// (document is -4000 again now that the CLUT off-by-one is fixed — it
/// previously composited dark, so -16415 was a stand-in.)
///
/// **Both sizes are real art.** OS 9 draws a list row or a menu-bar slot
/// from the 16×16 `ics8` resource, NOT from the 32×32 `icl8` scaled down —
/// a hand-tuned small icon is a different drawing, and downsampling one
/// produces a blur the machine never shows. The pack therefore carries a
/// `-16` file beside every 32, and callers pass the box they are drawing
/// into so the right one is picked.
@MainActor
public enum IconAtlas {
    /// The size of an extracted icon: `ics8` art or `icl8` art.
    public enum Size {
        case small, large

        /// The size OS 9 would draw into this box. 16×16 art is used up to
        /// 20pt — above that the large icon is the closer fit even before
        /// any scaling.
        public static func fitting(_ box: CGRect) -> Size {
            max(box.width, box.height) <= 20 ? .small : .large
        }

        var suffix: String { self == .small ? "-16" : "" }
    }

    private static var cache: [String: CGImage?] = [:]

    private static func image(_ name: String, subdir: String) -> CGImage? {
        let key = "\(subdir)/\(name)"
        if let cached = cache[key] { return cached }
        let img: CGImage? = {
            guard let url = AssetPack.url(forResource: name,
                                          withExtension: "png",
                                          subdirectory: subdir),
                  let data = try? Data(contentsOf: url),
                  let src = CGImageSourceCreateWithData(data as CFData, nil)
            else { return nil }
            return CGImageSourceCreateImageAtIndex(src, 0, nil)
        }()
        cache[key] = img
        return img
    }

    /// A generic icon by name from the extracted pack (`application`,
    /// `folder`, `document`, `disk`, `system-folder`). Used where there is
    /// no file to key on.
    ///
    /// `size` picks between the `icl8` and `ics8` art. It falls back to the
    /// other size rather than returning nil, so a name that exists at only
    /// one size still draws.
    public static func namedIcon(_ name: String, size: Size = .large) -> CGImage? {
        image(name + size.suffix, subdir: "icons")
            ?? image(name + Size.large.suffix, subdir: "icons")
    }

    /// The app's own icon, by the creator signature the guest reported for a
    /// running process. This is not inference: the signature comes off the
    /// wire with the process, so `fndf` really is Sherlock. nil when the
    /// pack has no icon for that signature (a third-party app, say).
    public static func processIcon(signature: String?,
                                   size: Size = .large) -> CGImage? {
        guard let creator = cleanOSType(signature) else { return nil }
        return image("\(creator)__APPL" + size.suffix, subdir: "appicons")
            ?? image("\(creator)__APPL", subdir: "appicons")
    }

    /// The best icon for a desktop/window item: the item's real per-app icon
    /// from the extracted appicons pack (keyed by creator+type) when we have
    /// one, else a generic bitmap by kind. nil → caller draws the procedural
    /// fallback.
    public static func icon(for item: MirrorKit.Scene.DesktopItem,
                            size: Size = .large) -> CGImage? {
        // Real app icon by (creator, type). An alias (adrp) or an app show the
        // owning app's icon (type APPL); a document shows its own type's icon.
        if let creator = cleanOSType(item.creator) {
            let type = (item.alias || item.type == "APPL")
                ? "APPL" : cleanOSType(item.type)
            if let type {
                let key = "\(creator)__\(type)"
                if let img = image(key + size.suffix, subdir: "appicons")
                    ?? image(key, subdir: "appicons") {
                    return img
                }
            }
        }
        // Generic by kind.
        if item.kind == "disk" { return nil }   // procedural hard-disk glyph
        if item.kind == "folder" {
            switch item.name {
            case "System Folder": return namedIcon("system-folder", size: size)
            default: return namedIcon("folder", size: size)
            }
        }
        if item.type == "APPL" { return namedIcon("application", size: size) }
        return namedIcon("document", size: size)
    }

    /// An OSType usable as an appicons filename key: 1–4 printable ASCII chars,
    /// no path separators (matches the extractor's `ostype_key`). Non-printable
    /// creators (which the wire escapes) fall through to generic.
    private static func cleanOSType(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        let ok = s.unicodeScalars.allSatisfy {
            $0.value > 32 && $0.value < 127 && !"/\\:".unicodeScalars.contains($0)
        }
        return ok ? s : nil
    }
}
