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
/// Three families. A Finder item's own custom icon is keyed by exact classic
/// path and extracted from that file's resource fork. Per-application icons
/// are keyed by the creator+type the guest reported (or an alias's resolved
/// target reported), so neither route guesses. Generic Finder icons (folder /
/// application / document / System Folder) remain the honest fallback when
/// neither identity is available.
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

    private static let fileIconItems: [String: [String: Any]] = {
        guard let root = AssetPack.root,
              let data = try? Data(contentsOf: root
                .appendingPathComponent("fileicons/manifest.json")),
              let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any],
              let items = object["items"] as? [String: [String: Any]]
        else { return [:] }
        return items
    }()

    private static func image(relativePath: String) -> CGImage? {
        let components = relativePath.split(separator: "/")
        guard !relativePath.hasPrefix("/"), !components.contains(".."),
              let root = AssetPack.root else { return nil }
        if let cached = cache[relativePath] { return cached }
        let url = root.appendingPathComponent(relativePath)
        let img: CGImage? = {
            guard let data = try? Data(contentsOf: url),
                  let src = CGImageSourceCreateWithData(data as CFData, nil)
            else { return nil }
            return CGImageSourceCreateImageAtIndex(src, 0, nil)
        }()
        cache[relativePath] = img
        return img
    }

    private static func image(_ name: String, subdir: String) -> CGImage? {
        image(relativePath: "\(subdir)/\(name).png")
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

    /// Finder's profile-scoped large-icon alias transform, derived only when
    /// independent attributed icons leave one identical framebuffer residual.
    /// Small/list-view alias chrome remains a separate oracle question.
    static func aliasBadge(size: Size) -> CGImage? {
        size == .large
            ? image(relativePath: "chrome/alias-badge.png")
            : nil
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

    /// An Apple-menu row icon from an explicit host-side identity join.
    /// Unlike `processIcon`, desk accessories and control-panel documents
    /// need their real file type as well as their creator signature.
    static func menuIcon(_ identity: MirrorKit.Scene.MenuItem.IconIdentity?,
                         size: Size = .small) -> CGImage? {
        guard let identity else { return nil }
        if let id = identity.systemIconID,
           let image = image(relativePath: "icons/ics8_\(id)_16.png")
                ?? image(relativePath: "icons/icl8_\(id)_32.png") {
            return image
        }
        if let creator = cleanOSType(identity.creator),
           let type = cleanOSType(identity.type),
           let image = image("\(creator)__\(type)" + size.suffix,
                             subdir: "appicons")
                ?? image("\(creator)__\(type)", subdir: "appicons") {
            return image
        }
        if let generic = identity.generic {
            return namedIcon(generic, size: size)
        }
        return nil
    }

    /// One Finder-owned custom icon from the pack, by exact classic path.
    /// The manifest—not a sanitized filename reconstruction—owns the join.
    /// This is the same path identity a future connected acquisition adapter
    /// will publish after pulling the item's resource fork.
    static func fileIcon(path: String, size: Size = .large) -> CGImage? {
        guard let row = fileIconItems[path] else { return nil }
        let preferred = size == .small ? "small" : "large"
        let fallback = size == .small ? "large" : "small"
        guard let relative = row[preferred] as? String
                ?? row[fallback] as? String else { return nil }
        return image(relativePath: relative)
    }

    /// The creator/type resource key represented by an item. An alias's own
    /// `adrp/aplt` identity describes the alias FILE, not what Finder draws;
    /// use the semantically resolved target when one exists, and do not guess
    /// when it does not. A non-alias uses its own catalog identity unchanged.
    static func assetKey(for item: MirrorKit.Scene.DesktopItem) -> String? {
        let creator: String?
        let type: String?
        if item.alias {
            guard let target = item.aliasTarget else { return nil }
            creator = target.creator
            type = target.type
        } else {
            creator = item.creator
            type = item.type
        }
        guard let creator = cleanOSType(creator),
              let type = cleanOSType(type) else { return nil }
        return "\(creator)__\(type)"
    }

    /// The best icon for a desktop/window item: exact-path custom Finder art,
    /// then creator+type application art, then a generic bitmap by represented
    /// kind. nil → caller draws the procedural fallback.
    public static func icon(for item: MirrorKit.Scene.DesktopItem,
                            size: Size = .large,
                            container: String? = nil) -> CGImage? {
        if let container,
           let img = fileIcon(path: "\(container):\(item.name)", size: size) {
            return img
        }
        if let key = assetKey(for: item),
           let img = image(key + size.suffix, subdir: "appicons")
                ?? image(key, subdir: "appicons") {
            return img
        }

        let representedKind = item.aliasTarget?.kind ?? item.kind
        let representedType = item.aliasTarget?.type ?? item.type
        // Generic by kind.
        if representedKind == "disk" { return nil } // procedural hard disk
        if representedKind == "folder" {
            switch item.name {
            case "Trash" where container == "Desktop Folder":
                return namedIcon("trash", size: size)
            case "System Folder": return namedIcon("system-folder", size: size)
            default: return namedIcon("folder", size: size)
            }
        }
        if representedKind == "application" || representedType == "APPL" {
            return namedIcon("application", size: size)
        }
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
