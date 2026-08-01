import Foundation
import CoreGraphics
import ImageIO
import MirrorKit

/// Real OS 9 generic icons from the extracted System-file icl8 set, keyed by
/// kind/type. These are the *generic* Finder icons (folder / application /
/// document / disk / System Folder) — the honest fallback until per-app custom
/// icons arrive (those live in the Finder Desktop Database, `PBDTGetIcon`,
/// which isn't in the Retro68 headers yet).
///
/// Provenance (platinum-pack System-file icl8, resource id):
///   folder = -3999 · application = -3968 · document = -4000
///   system-folder = -3982 · disk = -3998
/// (document is -4000 again now that the CLUT off-by-one is fixed — it
/// previously composited dark, so -16415 was a stand-in.)
public enum IconAtlas {
    private static var cache: [String: CGImage?] = [:]

    private static func image(_ name: String, subdir: String) -> CGImage? {
        let key = "\(subdir)/\(name)"
        if let cached = cache[key] { return cached }
        let img: CGImage? = {
            guard let url = Bundle.module.url(forResource: name,
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

    /// The best icon for a desktop/window item: the item's real per-app icon
    /// from the extracted appicons pack (keyed by creator+type) when we have
    /// one, else a generic bitmap by kind. nil → caller draws the procedural
    /// fallback.
    /// A generic icon by name from the extracted pack (`application`,
    /// `folder`, `document`). Used where there is no file to key on — the
    /// Application menu switcher's rows are `Scene.AppRef`, which carries no
    /// creator (only `Scene.ProcessRef`, the live-processes shelf's own
    /// type, does — see `icon(forProcessSignature:)`).
    public static func namedIcon(_ name: String) -> CGImage? {
        image(name, subdir: "icons")
    }

    /// The best icon for a RUNNING PROCESS: its creator's own icon from the
    /// extracted appicons pack, keyed `creator__APPL` — a process is always
    /// an application, never a document, so unlike `icon(for:)` there is no
    /// second type to consider. nil (an unreadable creator, e.g. `""` for
    /// `signature == 0`, or one the pack has no icon for) means the caller
    /// draws its monogram fallback — never a guessed icon for a creator
    /// this pack was not measured against.
    public static func icon(forProcessSignature signature: String) -> CGImage? {
        guard let creator = cleanOSType(signature) else { return nil }
        return image("\(creator)__APPL", subdir: "appicons")
    }

    public static func icon(for item: MirrorKit.Scene.DesktopItem) -> CGImage? {
        // Real app icon by (creator, type). An alias (adrp) or an app show the
        // owning app's icon (type APPL); a document shows its own type's icon.
        if let creator = cleanOSType(item.creator) {
            let type = (item.alias || item.type == "APPL")
                ? "APPL" : cleanOSType(item.type)
            if let type,
               let img = image("\(creator)__\(type)", subdir: "appicons") {
                return img
            }
        }
        // Generic by kind.
        if item.kind == "disk" { return nil }   // procedural hard-disk glyph
        if item.kind == "folder" {
            switch item.name {
            case "System Folder": return image("system-folder", subdir: "icons")
            default: return image("folder", subdir: "icons")
            }
        }
        if item.type == "APPL" { return image("application", subdir: "icons") }
        return image("document", subdir: "icons")
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
